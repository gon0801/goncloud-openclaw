#!/usr/bin/env python3
"""Qué modelo pide un encargo "por CLI" y si puede correr: permisos y cierres del operador, catálogo de
opencode, autorización y la tabla de frases con que se explica un rechazo."""
from __future__ import annotations

import difflib
import hashlib
import json
import os
import re
import signal
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import lineas
from types import MappingProxyType
from typing import Callable, Literal, Mapping, NewType, Union

ProviderId = NewType("ProviderId", str)
"""El prefijo de `opencode models`, por ejemplo `zai-coding-plan`."""

Billing = Literal["subscription", "per-token"]
"""Cómo cobra un proveedor. Lo dice el operador en cada permiso; el código no lo comprueba."""

SUCESSION_FILE = "sucesion.json"
SUCESSION_SCHEMA = "agent-work.succession.v1"
"""El estado de la sucesión (SUA-04, 4.3): vive en <state_root>/sucesion.json y lo escribe G3.
Aquí solo se lee: el «actual» de una línea, si es válido, es el modelo por omisión efectivo."""

POLICY_FILE = Path("docs/evidence/agent-work/proveedores-permitidos.json")
POLICY_SCHEMA = "agent-work.provider-policy.v1"
UNVERIFIED_REF = "sin-cotejar"
"""Lo que lleva, en lugar de un número de prompt, un cierre de emergencia que nadie cotejó con el operador."""
CATALOG_SCHEMA = "agent-work.catalog.v1"
OPENCODE_TIMEOUT_SECONDS = 20.0

PROVIDER = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
MODEL_NAME = re.compile(r"[A-Za-z0-9._:@/-]{1,128}")
MODEL_PATTERN = re.compile(r"[A-Za-z0-9._:@/*-]{1,128}")
ISO_DATE = re.compile(r"\d{4}-\d\d-\d\d")
CLI_VERSION = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+-]{0,63}")

# Reportado el 2026-10-12, sin medir aquí: opencode 1.18.35 solo ofrece llave de API para Anthropic, y
# David tiene plan Max y no va a usar llave. `opencode auth login` no lo arregla, así que la frase no lo pide.
SUBSCRIPTION_NOT_IN_OPENCODE = frozenset({"anthropic"})


@dataclass(frozen=True)
class ModelId:
    """Un id `<proveedor>/<modelo>` bien formado. No dice que exista ni que esté permitido."""
    provider: ProviderId
    name: str

    @staticmethod
    def parse(text: str) -> "ModelId | MalformedModel":
        provider, slash, name = text.partition("/")
        if not slash or not PROVIDER.fullmatch(provider) or not MODEL_NAME.fullmatch(name):
            return MalformedModel(text)
        return ModelId(ProviderId(provider), name)

    def __str__(self) -> str:
        return f"{self.provider}/{self.name}"


@dataclass(frozen=True)
class OperatorCitation:
    """Palabras del operador, con fecha. Nunca el resumen de un agente."""
    by: str
    on: str
    ref: str
    quote: str

    @staticmethod
    def parse(raw: object) -> "OperatorCitation | str":
        """La cita, o la razón por la que no vale."""
        if not isinstance(raw, dict) or set(raw) != {"by", "on", "ref", "quote"}:
            return "la cita lleva exactamente by, on, ref y quote"
        for key in ("by", "on", "ref", "quote"):
            if not isinstance(raw[key], str) or not raw[key].strip():
                return f"la cita no trae {key}"
        try:
            dated = ISO_DATE.fullmatch(raw["on"]) and date.fromisoformat(raw["on"])
        except ValueError:
            dated = None
        if not dated:
            return f"la fecha de la cita no es AAAA-MM-DD: {raw['on']}"
        return OperatorCitation(raw["by"], raw["on"], raw["ref"], raw["quote"])


@dataclass(frozen=True)
class ModelFilter:
    """Qué modelos de su proveedor cubre un permiso, cuando el operador no los quiere todos. Los patrones
    se comparan con la parte del id que sigue a `<proveedor>/`, y `*` vale por cualquier tramo. Un modelo
    entra si casa con algún `include` y con ningún `exclude`."""
    include: tuple[str, ...]
    exclude: tuple[str, ...]
    decision: OperatorCitation

    @staticmethod
    def parse(raw: object) -> "ModelFilter | str":
        if not isinstance(raw, dict) or not {"include", "decision"} <= set(raw) <= {"include", "exclude", "decision"}:
            return "el filtro de modelos lleva include, decision y, si hace falta, exclude"
        include, exclude = raw["include"], raw.get("exclude", [])
        if not isinstance(include, list) or not include or not isinstance(exclude, list):
            return "include es una lista con al menos un patrón y exclude es una lista"
        for pattern in include + exclude:
            if not isinstance(pattern, str) or not MODEL_PATTERN.fullmatch(pattern):
                return f"patrón de modelos inválido: {pattern!r}"
        decision = OperatorCitation.parse(raw["decision"])
        if isinstance(decision, str):
            return f"{decision}, en el filtro de modelos"
        return ModelFilter(tuple(include), tuple(exclude), decision)

    def admits(self, name: str) -> bool:
        def matches(pattern: str) -> bool:
            return re.fullmatch(".*".join(re.escape(part) for part in pattern.split("*")), name) is not None
        return any(map(matches, self.include)) and not any(map(matches, self.exclude))


@dataclass(frozen=True)
class ProviderDefault:
    """El modelo por omisión de un permiso (SUA-04, 4.2): su línea y el id desde el que la sucesión
    parte. Ningún id nuevo se escribe a mano en la política: la línea no cambia con las versiones."""
    line: str
    since: ModelId


@dataclass(frozen=True)
class ProviderGrant:
    """Un proveedor que el operador permitió para encargos. `name` es la palabra con la que lo nombra y
    `provider` el id con el que opencode lo lista. Con `provider` en None el permiso existe y no autoriza
    nada: el id se liga cuando opencode lo liste. Sin `models` cubre todos los modelos del proveedor."""
    name: str
    provider: ProviderId | None
    billing: Billing
    decision: OperatorCitation
    models: ModelFilter | None = None
    default: ProviderDefault | None = None

    def admits(self, model: ModelId) -> bool:
        return model.provider == self.provider and (self.models is None or self.models.admits(model.name))


@dataclass(frozen=True)
class ProviderClosure:
    """Un proveedor que el operador cerró, con sus palabras. No decide nada, porque lo que no tiene
    permiso ya está negado. Impide que `permitir` lo abra sin una frase nueva y le da su cita al rechazo."""
    provider: ProviderId
    decision: OperatorCitation


def _label(entry: object, key: str, index: int) -> str:
    return entry[key] if isinstance(entry, dict) and isinstance(entry.get(key), str) else f"#{index + 1}"


def _parse_default(entry: dict, provider: "ProviderId | None", where: str) -> "ProviderDefault | str":
    raw = entry["default"]
    if not isinstance(raw, dict) or set(raw) != {"line", "since"}:
        return f"un default lleva exactamente line y since ({where})"
    if provider is None:
        return f"un permiso sin id ligado no lleva default ({where})"
    if not isinstance(raw["line"], str) or not raw["line"].startswith(f"{provider}/") or raw["line"].count("{}") != 1:
        return f"la línea del default no es de su proveedor ({where})"
    since = ModelId.parse(raw["since"]) if isinstance(raw["since"], str) else MalformedModel(str(raw["since"]))
    if not isinstance(since, ModelId):
        return f"el since del default no es un id ({where})"
    parsed = lineas.parse(str(since))
    if parsed is None or parsed[0] != raw["line"]:
        return f"el since del default no parsea a su línea ({where})"
    return ProviderDefault(raw["line"], since)


def _parse_policy(raw: bytes) -> "tuple[tuple[ProviderGrant, ...], dict[ProviderId, ProviderClosure], str | None, str | None] | str":
    try:
        document = json.loads(raw)
    except (ValueError, RecursionError) as exc:
        return f"no es JSON: {exc}"
    if not isinstance(document, dict) or not {"schema", "providers", "closed"} <= set(document) <= {"schema", "providers", "closed", "defaultGrant", "ownerTelegramChat"}:
        return "el archivo lleva schema, providers, closed y, si hace falta, defaultGrant y ownerTelegramChat"
    if document["schema"] != POLICY_SCHEMA:
        return f"schema desconocido: {document['schema']!r}"
    if not isinstance(document["providers"], list) or not isinstance(document["closed"], list):
        return "providers y closed son listas"
    grants: list[ProviderGrant] = []
    for index, entry in enumerate(document["providers"]):
        where = f"en el permiso {_label(entry, 'name', index)}"
        required = {"name", "provider", "billing", "decision"}
        if not isinstance(entry, dict) or not required <= set(entry) <= required | {"models", "default"}:
            return f"un permiso lleva name, provider, billing, decision y, si hace falta, models y default ({where})"
        if not isinstance(entry["name"], str) or not PROVIDER.fullmatch(entry["name"]):
            return f"nombre inválido {where}"
        provider = entry["provider"]
        if provider is not None and (not isinstance(provider, str) or not PROVIDER.fullmatch(provider)):
            return f"id de proveedor inválido {where}"
        if entry["billing"] not in ("subscription", "per-token"):
            return f"billing fuera de subscription y per-token {where}"
        decision = OperatorCitation.parse(entry["decision"])
        if isinstance(decision, str):
            return f"{decision} ({where})"
        models = ModelFilter.parse(entry["models"]) if "models" in entry else None
        if isinstance(models, str):
            return f"{models} ({where})"
        if any(grant.name == entry["name"] for grant in grants):
            return f"dos permisos se llaman {entry['name']}"
        if provider is not None and any(grant.provider == provider for grant in grants):
            return f"dos permisos ligan el id {provider} ({where})"
        default = _parse_default(entry, provider and ProviderId(provider), where) if "default" in entry else None
        if isinstance(default, str):
            return default
        grants.append(ProviderGrant(entry["name"], provider and ProviderId(provider), entry["billing"], decision,
                                    models, default))
    closed: dict[ProviderId, ProviderClosure] = {}
    for index, entry in enumerate(document["closed"]):
        where = f"en el cierre {_label(entry, 'provider', index)}"
        if not isinstance(entry, dict) or set(entry) != {"provider", "decision"}:
            return f"un cierre lleva exactamente provider y decision ({where})"
        if not isinstance(entry["provider"], str) or not PROVIDER.fullmatch(entry["provider"]):
            return f"id de proveedor inválido {where}"
        decision = OperatorCitation.parse(entry["decision"])
        if isinstance(decision, str):
            return f"{decision} ({where})"
        if entry["provider"] in closed:
            return f"dos cierres nombran {entry['provider']}"
        if any(grant.provider == entry["provider"] for grant in grants):
            return f"{entry['provider']} está permitido y cerrado a la vez"
        closed[ProviderId(entry["provider"])] = ProviderClosure(ProviderId(entry["provider"]), decision)
    owner_chat = document.get("ownerTelegramChat")
    if owner_chat is not None and not (isinstance(owner_chat, str) and re.fullmatch(r"[0-9]{5,20}", owner_chat)):
        return f"ownerTelegramChat no es un chat de dígitos: {owner_chat!r}"
    default_grant = document.get("defaultGrant")
    if default_grant is not None:
        named = next((grant for grant in grants if grant.name == default_grant), None)
        if not isinstance(default_grant, str) or named is None or named.default is None:
            return f"defaultGrant no nombra un permiso con default: {default_grant!r}"
    return tuple(grants), closed, default_grant, owner_chat


@dataclass(frozen=True)
class ProviderPolicy:
    """La decisión del operador. Única fuente: POLICY_FILE en el checkout.

    Lo que no tiene un permiso con `provider` ligado está negado. Un archivo ausente o con una sola entrada
    mala deja `grants` vacío y `unreadable` con la causa y el nombre de la entrada: nada corre."""
    grants: tuple[ProviderGrant, ...]
    closed: Mapping[ProviderId, ProviderClosure]
    digest: str | None
    unreadable: str | None
    default_grant: str | None = None
    """El permiso cuyo modelo por omisión usa un encargo sin modelo (SUA-04, 4.2)."""
    owner_telegram_chat: str | None = None
    """El chat de Telegram del dueño (SUA-04, 4.8): lo leen los avisos y el cotejo de tg:."""

    @staticmethod
    def load(path: Path) -> "ProviderPolicy":
        """Nunca lanza."""
        try:
            raw = Path(path).read_bytes()
        except OSError as exc:
            return ProviderPolicy((), MappingProxyType({}), None, f"no se pudo leer {path}: {exc.strerror or exc}")
        return ProviderPolicy.parse(raw, path.name)

    @staticmethod
    def parse(raw: bytes, name: str) -> "ProviderPolicy":
        """La política que dicen esos bytes. `name` es el archivo que nombra `unreadable`."""
        digest = hashlib.sha256(raw).hexdigest()
        parsed = _parse_policy(raw)
        if isinstance(parsed, str):
            return ProviderPolicy((), MappingProxyType({}), digest, f"{name}: {parsed}")
        return ProviderPolicy(parsed[0], MappingProxyType(parsed[1]), digest, None, parsed[2], parsed[3])

    def grant_for(self, provider: ProviderId) -> ProviderGrant | None:
        """El permiso cuyo id ligado es ese proveedor. Un permiso sin id nunca sale de aquí."""
        return next((grant for grant in self.grants if grant.provider == provider), None)


def policy_document(grants: "tuple[ProviderGrant, ...]", closed: "Mapping[ProviderId, ProviderClosure]",
                    default_grant: "str | None" = None,
                    owner_telegram_chat: "str | None" = None) -> bytes:
    """El archivo de política en su formato canónico, el único que escriben `permitir` y `cerrar`."""
    def cite(decision: OperatorCitation) -> dict:
        return {"by": decision.by, "on": decision.on, "ref": decision.ref, "quote": decision.quote}
    def entry(grant: ProviderGrant) -> dict:
        models = grant.models and {"models": {
            "include": list(grant.models.include),
            **({"exclude": list(grant.models.exclude)} if grant.models.exclude else {}),
            "decision": cite(grant.models.decision)}}
        default = grant.default and {"default": {"line": grant.default.line, "since": str(grant.default.since)}}
        return {"name": grant.name, "provider": grant.provider, "billing": grant.billing, **(models or {}),
                **(default or {}), "decision": cite(grant.decision)}
    document = {
        "schema": POLICY_SCHEMA,
        "providers": [entry(grant) for grant in grants],
        "closed": [{"provider": closure.provider, "decision": cite(closure.decision)}
                   for closure in closed.values()],
        **({"defaultGrant": default_grant} if default_grant is not None else {}),
        **({"ownerTelegramChat": owner_telegram_chat} if owner_telegram_chat is not None else {}),
    }
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode()


def succession_actual(state_root: Path, line: str) -> "tuple[ModelId | None, str | None]":
    """El «actual» de una línea en <state_root>/sucesion.json, y la causa si no se pudo usar.

    Solo lectura (lo escribe G3). Un archivo ausente no es una causa: la línea parte de su
    `since`. Uno ilegible, con otro schema o con un actual que no parsea a esa línea sí lo es,
    y quien resuelve cae a `since` sin romper.
    """
    path = Path(state_root) / SUCESSION_FILE
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError:
        return None, None
    except ValueError:
        return None, f"{SUCESSION_FILE} no es JSON: se usa el since de la política"
    if not isinstance(document, dict) or document.get("schema") != SUCESSION_SCHEMA \
            or not isinstance(document.get("lines"), dict):
        return None, f"{SUCESSION_FILE} no trae el schema {SUCESSION_SCHEMA}: se usa el since de la política"
    entry = document["lines"].get(line)
    if entry is None:
        return None, None
    actual = entry.get("actual") if isinstance(entry, dict) else None
    parsed = ModelId.parse(actual) if isinstance(actual, str) else MalformedModel(str(actual))
    if not isinstance(parsed, ModelId) or lineas.parse(str(parsed)) is None \
            or lineas.parse(str(parsed))[0] != line:
        return None, f"el actual de {line} en {SUCESSION_FILE} no parsea a esa línea: se usa el since"
    return parsed, None


def effective_default(policy: ProviderPolicy, state_root: "Path | None") -> "tuple[ModelId, str | None] | SinModeloPorOmision":
    """El modelo por omisión efectivo (SUA-04, 4.2): el actual promovido de la línea del permiso
    que nombra `defaultGrant`, o su `since`. La causa de un sucesion.json ilegible viaja con el
    modelo para que `proveedores` la muestre; no cambia qué modelo corre."""
    grant = next((item for item in policy.grants if item.name == policy.default_grant), None)
    if grant is None or grant.default is None:
        return SinModeloPorOmision()
    if state_root is not None:
        actual, causa = succession_actual(state_root, grant.default.line)
        if actual is not None:
            return actual, "promovido desde sucesion.json"
        if causa is not None:
            return grant.default.since, causa
    return grant.default.since, None


@dataclass(frozen=True)
class Catalog:
    """Lo que `opencode models` listó en esta Mac con esta versión del CLI."""
    cli_version: str
    models: frozenset[ModelId]
    listed_at: float

    @staticmethod
    def from_listing(listing: str, *, cli_version: str, listed_at: float) -> "Catalog":
        parsed = (ModelId.parse(line.strip()) for line in listing.splitlines() if line.strip())
        return Catalog(cli_version, frozenset(model for model in parsed if isinstance(model, ModelId)), listed_at)

    def of(self, provider: ProviderId) -> frozenset[ModelId]:
        """Vacío significa que opencode en esta Mac no tiene ese proveedor: falta `opencode auth login`."""
        return frozenset(model for model in self.models if model.provider == provider)


class CatalogUnavailable(RuntimeError):
    """opencode no contestó su versión o su lista de modelos."""


class CatalogStore:
    """Frontera con el CLI. Guarda <state_root>/catalogo.json con escritura atómica. Solo ejecuta
    `opencode --version` y `opencode models`, por ruta absoluta, sin stdin y con tope de tiempo."""

    def __init__(self, opencode_bin: Path, state_root: Path, *, budget_seconds: float | None = None):
        """`budget_seconds` es el tope de todo lo que este objeto puede esperar a opencode, entre todas sus
        llamadas. Sin él, cada llamada tiene solo su tope propio."""
        if not Path(opencode_bin).is_absolute():
            raise ValueError(f"opencode va con ruta absoluta: {opencode_bin}")
        self.opencode_bin = Path(opencode_bin)
        self.path = Path(state_root) / "catalogo.json"
        self.deadline = None if budget_seconds is None else time.monotonic() + budget_seconds

    def current(self, *, max_age_seconds: float = 6 * 3600) -> Catalog:
        """Relee con `opencode models` si el archivo falta, envejeció o `opencode --version` cambió."""
        version = self._version()
        cached = self._cached()
        if cached is not None and cached.cli_version == version and time.time() - cached.listed_at < max_age_seconds:
            return cached
        return self._list(version, upstream=False)

    def refresh(self, *, upstream: bool = False) -> Catalog:
        """Con `upstream` le pide a opencode que vuelva a bajar su lista (`opencode models --refresh`)."""
        return self._list(self._version(), upstream=upstream)

    def _run(self, *args: str) -> str:
        command = f"{self.opencode_bin} {' '.join(args)}"
        timeout = OPENCODE_TIMEOUT_SECONDS
        if self.deadline is not None:
            timeout = min(timeout, self.deadline - time.monotonic())
        if timeout <= 0:
            raise CatalogUnavailable(f"{command}: se agotó el tope de tiempo del comando antes de llamarlo")
        # Listar no debe actualizar el CLI: una versión nueva cierra la ruta certificada.
        env = {**os.environ, "OPENCODE_DISABLE_AUTOUPDATE": "1"}
        try:
            # Sesión propia: al vencer el tope se mata el grupo entero. Un hijo de opencode que siga vivo
            # con la tubería abierta dejaría esta llamada esperando su salida más allá del tope.
            process = subprocess.Popen([str(self.opencode_bin), *args], stdin=subprocess.DEVNULL, text=True, env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        except OSError as exc:
            raise CatalogUnavailable(f"{command}: {exc}") from exc
        try:
            stdout, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise CatalogUnavailable(f"{command}: no contestó dentro del tope de {timeout:.0f} s") from exc
        if process.returncode != 0:
            raise CatalogUnavailable(f"{command} salió con {process.returncode}")
        return stdout

    def _version(self) -> str:
        version = self._run("--version").strip()
        if not CLI_VERSION.fullmatch(version):
            raise CatalogUnavailable(f"{self.opencode_bin} --version no contestó una versión")
        return version

    def _list(self, version: str, *, upstream: bool) -> Catalog:
        listing = self._run("models", *(("--refresh",) if upstream else ()))
        lines = [line.strip() for line in listing.splitlines() if line.strip()]
        # Una salida vacía o con otra forma no es "ese proveedor no tiene sesión": es opencode sin contestar
        # lo que se le pidió. No se guarda, para que la siguiente llamada vuelva a preguntar.
        stray = next((line for line in lines if not isinstance(ModelId.parse(line), ModelId)), None)
        if stray is not None:
            raise CatalogUnavailable(f"{self.opencode_bin} models contestó una línea que no es un id: {stray[:80]!r}")
        if not lines:
            raise CatalogUnavailable(f"{self.opencode_bin} models no listó ningún modelo")
        catalog = Catalog.from_listing(listing, cli_version=version, listed_at=time.time())
        document = {"schema": CATALOG_SCHEMA, "cliVersion": catalog.cli_version, "listedAt": catalog.listed_at,
                    "models": sorted(str(model) for model in catalog.models)}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, pending = tempfile.mkstemp(prefix=".catalogo-", dir=self.path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(document, stream)
            os.replace(pending, self.path)
        finally:
            if os.path.exists(pending):
                os.unlink(pending)
        return catalog

    def _cached(self) -> Catalog | None:
        try:
            document = json.loads(self.path.read_text(encoding="utf-8"))
            if document["schema"] != CATALOG_SCHEMA:
                return None
            cached = Catalog.from_listing("\n".join(document["models"]), cli_version=str(document["cliVersion"]),
                                          listed_at=float(document["listedAt"]))
        except (OSError, ValueError, KeyError, TypeError):
            return None
        return cached if cached.models else None


@dataclass(frozen=True)
class DefaultModel:
    """El pedido no nombró modelo."""


@dataclass(frozen=True)
class ExactModel:
    model: ModelId


@dataclass(frozen=True)
class ByName:
    """Las palabras del operador, por ejemplo "glm 5.3 highspeed". Solo existe del lado de `preparar`: la
    cabecera del brief no puede expresarlo, así que el host nunca resuelve un apodo."""
    words: str


ModelRequest = Union[DefaultModel, ExactModel, ByName]

@dataclass(frozen=True, init=False)
class PermittedModel:
    """Prueba de que authorize dijo que sí. Solo authorize lo construye, y es lo único que acepta el
    lanzador: un modelo de un proveedor sin permiso no tiene otro camino hacia `opencode -m`.

    No tiene constructor: llamarlo, o pasar por `dataclasses.replace`, lanza TypeError."""
    model: ModelId
    billing: Billing
    policy_digest: str
    cli_version: str

    def __init__(self, *args: object, **kwargs: object) -> None:
        raise TypeError("PermittedModel solo sale de authorize")


def _permit(model: ModelId, billing: Billing, policy_digest: str, cli_version: str) -> PermittedModel:
    permitted = object.__new__(PermittedModel)
    for name, value in (("model", model), ("billing", billing), ("policy_digest", policy_digest),
                        ("cli_version", cli_version)):
        object.__setattr__(permitted, name, value)
    return permitted


@dataclass(frozen=True)
class MalformedModel:
    text: str


@dataclass(frozen=True)
class PolicyUnreadable:
    why: str


@dataclass(frozen=True)
class SinModeloPorOmision:
    """La política carga y no nombra un modelo por omisión (SUA-04 G2, F1): el permiso que lo
    daba se cerró o se re-ligó. No es una política ilegible: el encargo se pide con --modelo."""


@dataclass(frozen=True)
class ProviderNotAllowed:
    """`models` trae uno para un id exacto o para el modelo por omisión, y todas las coincidencias en
    proveedores sin permiso para un nombre. `closures` trae la cita de cada proveedor cerrado que aparece
    en `models`. `awaiting_login` son los permisos que todavía no listan modelos."""
    models: tuple[ModelId, ...]
    allowed: tuple[str, ...]
    closures: tuple[ProviderClosure, ...]
    awaiting_login: tuple[str, ...]


@dataclass(frozen=True)
class ProviderNotConfigured:
    """El operador permitió el proveedor y opencode en esta Mac no lista ningún modelo suyo: falta iniciar
    sesión. Con `provider` en None falta además ligar su id."""
    name: str
    provider: ProviderId | None
    asked: str


@dataclass(frozen=True)
class ModelNotListed:
    """El proveedor está permitido y lista modelos, pero no este."""
    model: ModelId
    similar: tuple[ModelId, ...]


@dataclass(frozen=True)
class ModelOutsideGrant:
    """opencode lista el modelo y su proveedor tiene permiso, pero el filtro de ese permiso no lo cubre.
    `grants` trae el permiso de cada proveedor que aparece en `models`."""
    models: tuple[ModelId, ...]
    grants: tuple[ProviderGrant, ...]


@dataclass(frozen=True)
class NameMatchesNothing:
    words: str
    allowed_models: tuple[ModelId, ...]
    awaiting_login: tuple[str, ...]


@dataclass(frozen=True)
class NameIsAmbiguous:
    """`billing` trae el cobro de cada proveedor que aparece en `candidates`: el mismo nombre puede existir
    en un proveedor por token y en uno por suscripción, y quien elige tiene que verlo."""
    words: str
    candidates: tuple[ModelId, ...]
    billing: tuple[tuple[ProviderId, Billing], ...]


@dataclass(frozen=True)
class MalformedHeader:
    why: str


@dataclass(frozen=True)
class WorkspaceRefused:
    path: str
    why: Literal["not-absolute", "outside-root", "not-a-git-toplevel", "missing", "no-commit", "invalid"]


@dataclass(frozen=True)
class RouteNotCertified:
    cli_version: str
    certified_versions: tuple[str, ...]


@dataclass(frozen=True)
class GenerationNotCertified:
    """La ruta está abierta para opencode, pero no para el paquete de poteto de esa generación (SUA-03,
    4.5): coverage.json no la certifica todavía."""
    generation: int
    certified: tuple[int, ...]


@dataclass(frozen=True)
class ContextoIncompleto:
    """El paquete de poteto del checkout no coincide con su manifiesto, o el manifiesto no está (SUA-03,
    4.5). Lo contestan las dos fronteras con disco: quien planea, que lee la fuente, y el paso de
    lanzamiento, que copia y relee."""
    why: str


@dataclass(frozen=True)
class PerfilRechazado:
    """Lo que la admisión del perfil contestó (SUA-03, 4.4): la causa ya tiene nombre propio
    (perfil-ausente, perfil-desconocido, perfil-no-atiende-ruta, perfil-no-admite-contrato,
    perfil-sin-competencia, herramienta-negada, revisor-con-escritura) y su frase nombra al perfil."""
    causa: str
    frase: str


Refusal = Union[MalformedModel, PolicyUnreadable, SinModeloPorOmision, ProviderNotAllowed, ProviderNotConfigured,
                ModelNotListed, ModelOutsideGrant, NameMatchesNothing, NameIsAmbiguous, MalformedHeader,
                WorkspaceRefused, RouteNotCertified, GenerationNotCertified, ContextoIncompleto, PerfilRechazado]


@dataclass(frozen=True)
class HostDown:
    beat_age_seconds: float | None
    """None: nunca hubo host.json."""


@dataclass(frozen=True)
class HostMismatch:
    """El host vivo no va a decidir con lo mismo que este comando."""
    what: Literal["checkout", "policy", "cli-version"]
    host: str
    local: str


@dataclass(frozen=True)
class SlotBlocked:
    """El grupo del slot tiene procesos que no son de ningún encargo."""
    processes: tuple[str, ...]


def pedido(texto: str | None) -> "ModelRequest | MalformedModel":
    """Lo que escribió quien pide, como pedido de modelo. Una sola palabra con diagonal es un id exacto."""
    if texto is None:
        return DefaultModel()
    words = texto.split()
    if len(words) == 1 and "/" in words[0]:
        model = ModelId.parse(words[0])
        return ExactModel(model) if isinstance(model, ModelId) else model
    return ByName(" ".join(words))


def _awaiting_login(policy: ProviderPolicy, catalog: Catalog) -> tuple[str, ...]:
    return tuple(grant.name for grant in policy.grants
                 if grant.provider is None or not catalog.of(grant.provider))


def _not_allowed(models: "tuple[ModelId, ...]", policy: ProviderPolicy, catalog: Catalog) -> ProviderNotAllowed:
    providers = dict.fromkeys(model.provider for model in models)
    return ProviderNotAllowed(models, tuple(grant.name for grant in policy.grants),
                              tuple(policy.closed[provider] for provider in providers if provider in policy.closed),
                              _awaiting_login(policy, catalog))


def _admitted(policy: ProviderPolicy, catalog: Catalog) -> tuple[ModelId, ...]:
    """Los modelos listados que algún permiso cubre, en orden de id."""
    return tuple(model for model in sorted(catalog.models, key=str)
                 if any(grant.admits(model) for grant in policy.grants))


def _outside_grant(models: "tuple[ModelId, ...]", policy: ProviderPolicy) -> ModelOutsideGrant:
    providers = dict.fromkeys(model.provider for model in models)
    return ModelOutsideGrant(models, tuple(policy.grant_for(provider) for provider in providers))


def _by_name(request: ByName, policy: ProviderPolicy, catalog: Catalog) -> "ModelId | Refusal":
    words = tuple(request.words.lower().split())
    permitted = _admitted(policy, catalog)
    matching = tuple(model for model in sorted(catalog.models, key=str)
                     if words and all(word in str(model).lower() for word in words))
    candidates = tuple(model for model in matching if model in permitted)
    if len(candidates) == 1:
        return candidates[0]
    if candidates:
        identical = [model for model in candidates if model.name.lower() == "-".join(words)]
        if len(identical) == 1:
            return identical[0]
        providers = dict.fromkeys(model.provider for model in candidates)
        return NameIsAmbiguous(request.words, candidates,
                               tuple((provider, policy.grant_for(provider).billing) for provider in providers))
    for grant in policy.grants:
        if grant.name in words and (grant.provider is None or not catalog.of(grant.provider)):
            return ProviderNotConfigured(grant.name, grant.provider, request.words)
    filtered = tuple(model for model in matching if policy.grant_for(model.provider) is not None)
    if filtered:
        return _outside_grant(filtered, policy)
    if matching:
        return _not_allowed(matching, policy, catalog)
    return NameMatchesNothing(request.words, permitted, _awaiting_login(policy, catalog))


def authorize(request: "ModelRequest | MalformedModel", policy: ProviderPolicy,
              catalog: Catalog, state_root: "Path | None" = None) -> "PermittedModel | Refusal":
    """Pura, salvo la lectura de sucesion.json cuando el pedido es sin modelo y el llamador pasa
    `state_root` (SUA-04, 4.2). La llaman `preparar` (aviso en el mismo turno) y el host (la que
    manda). El proveedor se revisa antes que el catálogo: uno sin permiso se rechaza aunque el
    modelo exista.

    Acepta lo que devuelve `pedido`, así que un pedido mal formado sale tal cual. Cualquier otra cosa es
    un error del llamador y lanza TypeError: nada que no sea DefaultModel pide el modelo por omisión."""
    if isinstance(request, MalformedModel):
        return request
    if not isinstance(request, (DefaultModel, ExactModel, ByName)):
        raise TypeError(f"authorize no conoce un pedido {type(request).__name__}")
    if policy.unreadable is not None or policy.digest is None:
        return PolicyUnreadable(policy.unreadable or "sin digest")
    if isinstance(request, ByName):
        candidate = _by_name(request, policy, catalog)
    elif isinstance(request, ExactModel):
        candidate = request.model
    else:
        effective = effective_default(policy, state_root)
        if isinstance(effective, SinModeloPorOmision):
            return effective
        candidate = effective[0]
    if not isinstance(candidate, ModelId):
        return candidate
    grant = policy.grant_for(candidate.provider)
    if grant is None:
        return _not_allowed((candidate,), policy, catalog)
    listed = catalog.of(candidate.provider)
    if not listed:
        asked = request.words if isinstance(request, ByName) else str(candidate)
        return ProviderNotConfigured(grant.name, grant.provider, asked)
    if candidate not in listed:
        names = {model.name: model for model in listed if grant.admits(model)}
        return ModelNotListed(candidate, tuple(names[name] for name in
                                               difflib.get_close_matches(candidate.name, sorted(names), n=3)))
    if not grant.admits(candidate):
        return _outside_grant((candidate,), policy)
    return _permit(candidate, grant.billing, policy.digest, catalog.cli_version)


@dataclass(frozen=True)
class Explicacion:
    causa: str
    frase: str
    accion: Literal["no-registrar", "preguntar-a-david", "cancelar", "cerrar", "esperar"]
    candidatos: tuple[str, ...] = ()
    """Ids exactos, solo con "preguntar-a-david"."""


def _ids(models: "tuple[ModelId, ...]") -> tuple[str, ...]:
    return tuple(str(model) for model in models)


def _lista(names: "tuple[str, ...]") -> str:
    return ", ".join(names)


def _frase_no_permitido(caso: ProviderNotAllowed) -> tuple[str, tuple[str, ...]]:
    cited = {closure.provider: closure.decision for closure in caso.closures}
    partes = []
    for provider in dict.fromkeys(model.provider for model in caso.models):
        decision = cited.get(provider)
        if decision is None:
            partes.append(f"{provider} no tiene permiso para encargos.")
            continue
        marker = f", {UNVERIFIED_REF}" if decision.ref == UNVERIFIED_REF else ""
        partes.append(f"{provider} está cerrado para encargos. {decision.by}, {decision.on}{marker}: "
                      f"«{decision.quote}».")
    con_sesion = tuple(name for name in caso.allowed if name not in caso.awaiting_login)
    if con_sesion:
        partes.append(f"Permitidos con sesión: {_lista(con_sesion)}.")
    if caso.awaiting_login:
        partes.append(f"Permitidos sin sesión todavía: {_lista(caso.awaiting_login)}.")
    return " ".join(partes), ()


def _frase_sin_sesion(caso: ProviderNotConfigured) -> tuple[str, tuple[str, ...]]:
    if caso.provider is None:
        return (f"{caso.name} está permitido, pero falta iniciar sesión con opencode auth login y ligar su id "
                f"con encargo.py permitir {caso.name} --proveedor <id>."), ()
    if caso.provider in SUBSCRIPTION_NOT_IN_OPENCODE:
        return (f"{caso.name} está permitido, pero su suscripción no entra por opencode, que de {caso.provider} "
                "solo acepta llave de API. Su ruta propia está pendiente (fila B22-S5 de followups.md)."), ()
    return (f"{caso.name} está permitido, pero opencode en la Mac no lista ningún modelo de {caso.provider}. "
            "Falta correr opencode auth login."), ()


def _frase_no_listado(caso: ModelNotListed) -> tuple[str, tuple[str, ...]]:
    frase = f"{caso.model} no existe: opencode no lista ese modelo de {caso.model.provider}."
    if caso.similar:
        frase += f" Parecidos: {_lista(_ids(caso.similar))}."
    return frase, _ids(caso.similar)


def _frase_fuera_del_permiso(caso: ModelOutsideGrant) -> tuple[str, tuple[str, ...]]:
    partes = []
    for grant in caso.grants:
        suyos = tuple(model for model in caso.models if model.provider == grant.provider)
        solo = _lista(grant.models.include)
        salvo = f", salvo {_lista(grant.models.exclude)}" if grant.models.exclude else ""
        partes.append(f"opencode lista {_lista(_ids(suyos))}, pero {'quedan' if len(suyos) > 1 else 'queda'} "
                      f"fuera del permiso de {grant.name}. De {grant.provider} solo entran {solo}{salvo}.")
    return " ".join(partes), ()


def _frase_sin_coincidencia(caso: NameMatchesNothing) -> tuple[str, tuple[str, ...]]:
    frase = f"Ningún modelo permitido coincide con «{caso.words}»."
    if caso.allowed_models:
        providers = dict.fromkeys(model.provider for model in caso.allowed_models)
        counts = (f"{provider} ({sum(model.provider == provider for model in caso.allowed_models)})"
                  for provider in providers)
        frase += f" Hay modelos permitidos de {_lista(tuple(counts))}."
    if caso.awaiting_login:
        frase += f" Permitidos sin sesión todavía: {_lista(caso.awaiting_login)}."
    return frase, ()


_CARPETA = {
    "not-absolute": "no es una ruta absoluta",
    "outside-root": "está fuera de la carpeta de repos permitida",
    "not-a-git-toplevel": "no es la raíz de un repo git",
    "missing": "no existe",
    "no-commit": "es un repo git sin ningún commit",
    "invalid": "no es una carpeta de encargo válida",
}

_DESFASE = {"checkout": "otro checkout", "policy": "otra política", "cli-version": "otra versión de opencode"}


_COBRO = {"subscription": "por suscripción", "per-token": "por token"}


def _frase_ambiguo(caso: NameIsAmbiguous) -> tuple[str, tuple[str, ...]]:
    partes = [f"«{caso.words}» coincide con {len(caso.candidates)} modelos permitidos."]
    for provider, billing in caso.billing:
        suyos = tuple(model for model in caso.candidates if model.provider == provider)
        partes.append(f"De {provider}, {_COBRO[billing]}: {_lista(_ids(suyos))}.")
    partes.append("Falta saber cuál.")
    return " ".join(partes), _ids(caso.candidates)


def _frase_ruta(caso: RouteNotCertified) -> tuple[str, tuple[str, ...]]:
    if caso.certified_versions:
        return (f"Ruta certificada para {_lista(caso.certified_versions)}, la Mac tiene opencode {caso.cli_version}.",
                ())
    return ("La ruta de encargos por opencode todavía no está certificada. "
            f"La Mac tiene opencode {caso.cli_version}."), ()


def _frase_generacion(caso: GenerationNotCertified) -> tuple[str, tuple[str, ...]]:
    certificadas = _lista([str(generation) for generation in caso.certified]) or "ninguna"
    return (f"El paquete de poteto de la generación {caso.generation} no está certificado para encargos; "
            f"certificadas: {certificadas}."), ()


def _frase_sin_host(caso: HostDown) -> tuple[str, tuple[str, ...]]:
    if caso.beat_age_seconds is None:
        return "El host de encargos nunca corrió en esta Mac.", ()
    return f"El host de encargos no corre desde hace {int(caso.beat_age_seconds // 60)} min.", ()


_RECHAZOS: "dict[type, tuple[str, Callable[..., tuple[str, tuple[str, ...]]]]]" = {
    PolicyUnreadable: ("politica-ilegible", lambda caso: (
        f"La política de proveedores no se puede leer ({caso.why}). No corre ningún encargo hasta arreglarla.", ())),
    SinModeloPorOmision: ("sin-modelo-por-omision", lambda caso: (
        "no hay modelo por omisión: el permiso que lo daba se cerró; pide el encargo con --modelo", ())),
    MalformedModel: ("modelo-mal-formado", lambda caso: (
        f"«{caso.text}» no es un modelo bien formado. Va como <proveedor>/<modelo>.", ())),
    ProviderNotAllowed: ("proveedor-no-permitido", _frase_no_permitido),
    ProviderNotConfigured: ("proveedor-sin-sesion", _frase_sin_sesion),
    ModelNotListed: ("modelo-no-existe", _frase_no_listado),
    ModelOutsideGrant: ("modelo-fuera-del-permiso", _frase_fuera_del_permiso),
    NameMatchesNothing: ("nombre-sin-coincidencia", _frase_sin_coincidencia),
    NameIsAmbiguous: ("nombre-ambiguo", _frase_ambiguo),
    MalformedHeader: ("cabecera-mal-formada", lambda caso: (
        f"La cabecera de lanzamiento del brief está mal formada: {caso.why}.", ())),
    WorkspaceRefused: ("carpeta-no-permitida", lambda caso: (f"{caso.path} {_CARPETA[caso.why]}.", ())),
    RouteNotCertified: ("ruta-no-certificada", _frase_ruta),
    GenerationNotCertified: ("generacion-no-certificada", _frase_generacion),
    ContextoIncompleto: ("contexto-incompleto", lambda caso: (
        f"El paquete de poteto no coincide con su manifiesto: {caso.why}. No se lanza nada.", ())),
    HostDown: ("sin-host", _frase_sin_host),
    HostMismatch: ("host-desfasado", lambda caso: (
        f"El host de encargos corre con {_DESFASE[caso.what]}: el host tiene {caso.host} y aquí hay {caso.local}.",
        ())),
    SlotBlocked: ("slot-bloqueado", lambda caso: (
        f"El slot de encargos tiene procesos que no son de ningún encargo: {'; '.join(caso.processes)}.", ())),
}

_EPISODIOS = {
    "launch-refused": "El host rechazó el encargo antes de lanzarlo.",
    "launch-failed": "opencode salió sin acusar recibo.",
    "delivery-unaccepted": "El modelo no acusó recibo dentro del plazo.",
    "session-closed": "La sesión terminó sin entregar resultado.",
    "invalid-result": "El resultado llegó mal formado.",
    "deadline": "El modelo acusó recibo y no entregó dentro del plazo.",
    "permission-required": "La sesión pide un permiso en pantalla y el host no lo aprueba.",
    "reviewer-wrote-source": "El revisor dejó cambiado el repo del encargo, y el host no aceptó su resultado.",
}


def _causa_de_opencode(eventos: object) -> str:
    if eventos.denied:
        return "".join(f" opencode negó {denied.permission} sobre {denied.pattern}." for denied in eventos.denied)
    if eventos.error:
        return f" opencode dijo: {eventos.error}."
    if eventos.session_directory:
        return f" La sesión abrió en {eventos.session_directory}."
    return ""


def explicar(caso: "Refusal | str | HostDown | HostMismatch | SlotBlocked", *, registrado: bool = False,
             eventos: object | None = None) -> Explicacion:
    """Única tabla de frases de `preparar` y `estado`. `caso` es un rechazo, el estado del host o el
    episodio de una incidencia.

    Antes de registrar, la acción es `no-registrar` o `preguntar-a-david`. Un episodio, o un rechazo con
    `registrado=True`, ya tiene tarea en R y la acción es `cancelar`. `eventos` es lo que opencode dejó
    dicho en la corrida (`denied`, `error` y `session_directory`): con él, la frase de `launch-failed` y de
    `session-closed` nombra esa causa."""
    if isinstance(caso, str):
        if caso not in _EPISODIOS:
            raise ValueError(f"episodio desconocido: {caso}")
        frase = _EPISODIOS[caso]
        if eventos is not None and caso in ("launch-failed", "session-closed"):
            frase += _causa_de_opencode(eventos)
        return Explicacion(caso, frase, "cancelar")
    if isinstance(caso, PerfilRechazado):
        # La admisión del perfil ya trae su causa con nombre propio y su frase (SUA-03, 4.4).
        return Explicacion(caso.causa, caso.frase, "cancelar" if registrado else "no-registrar")
    if type(caso) not in _RECHAZOS:
        raise TypeError(f"explicar no conoce {type(caso).__name__}")
    causa, redactar = _RECHAZOS[type(caso)]
    frase, candidatos = redactar(caso)
    if registrado:
        return Explicacion(causa, frase, "cancelar")
    # Sin modelo por omisión, quien pide tiene que nombrar uno: es preguntar-a-david aunque
    # no haya candidatos que listar (F1 de SUA04-G2).
    pregunta = bool(candidatos) or isinstance(caso, SinModeloPorOmision)
    return Explicacion(causa, frase, "preguntar-a-david" if pregunta else "no-registrar", candidatos)
