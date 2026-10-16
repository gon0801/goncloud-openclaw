"""La vida de un proceso opencode para un encargo: el plan (cabecera del brief, carpeta validada, ruta
certificada, modelo permitido), el lanzamiento dentro del grupo del slot, lo que el proceso dijo, su
salida y el cierre probado por la frontera de ese grupo."""
from __future__ import annotations

import grp
import json
import os
import pwd
import re
import shlex
import signal
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Literal

import contexto
from contracts import RunDir, SessionRecord
from host import delivery_line
from modelos import (CLAUDE_ALIASES, Catalog, DefaultModel, ExactModel, GenerationNotCertified, MalformedHeader,
                     ModelId, PerfilRechazado, PermittedModel, ProviderPolicy, Refusal, RouteNotCertified,
                     WorkspaceRefused, authorize)
from resources import BoundaryBusy, TmuxBackend, _ps
from spool import atomic_json

LAUNCH_SCHEMA = "agent-work.launch.v1"
HEADER_END = "---"
MAX_HEADER_LINES = 16
ROUTE_FORM = "run-per-task"
MAX_SHOWN = 200
COVERAGE_FILE = Path("docs/evidence/agent-work/coverage.json")

ALLOWED_ROOT = Path("/Users/dn/dev")
"""David, P10866: "2. cualquiera". Cualquier repo bajo `~/dev`."""

PROFILE_ID = re.compile(r"[a-z][a-z0-9-]{0,31}")
"""El id de un perfil de trabajador. Copia la forma de `brief.py --perfil`, que no puede importar esto;
test-agent-work-routing.py compara las dos."""

LOCAL_AGENTS = ("comment-sicko", "panel-glm47", "panel-glm52", "panel-glm53", "panel-glm5turbo",
                "poteto-agent", "poteto-agent-rapido")
"""Los siete agentes locales de opencode (diseño de SUA-03, 4.6). M-13 midió que
`agent.<nombre>.model` aplica desde OPENCODE_CONFIG_CONTENT, y que sin él un `task` a poteto-agent
pide el modelo fijado en el archivo del agente a un proveedor que la corrida no tiene
(ProviderModelNotFoundError): el hijo entero fallaría en todo encargo que no sea GLM."""


@dataclass(frozen=True)
class LaunchHeader:
    """Parámetros del adaptador que viajan dentro del brief, cubiertos por instructionRef.digest.

        agent-work.launch.v1
        model: zai-coding-plan/glm-5.3
        ---
        <prosa del encargo>

    Un brief sin esa primera línea no tiene cabecera y corre el modelo por omisión. Con cabecera, una
    llave desconocida es MalformedHeader: un host viejo no ignora un parámetro que no entiende."""
    model: ModelId | None
    profile: str | None = None
    """El perfil de trabajador que el brief pide (SUA-03, 4.5). `brief.py --perfil` lo escribe."""

    @staticmethod
    def parse(brief: bytes) -> "LaunchHeader | MalformedHeader":
        first, _, rest = brief.partition(b"\n")
        if first != LAUNCH_SCHEMA.encode():
            # Una línea de esquema con un espacio o un CR de más no corre el modelo por omisión en silencio.
            if first.strip() == LAUNCH_SCHEMA.encode():
                return MalformedHeader(f"la primera línea no es exactamente {LAUNCH_SCHEMA}")
            return LaunchHeader(None)
        model: ModelId | None = None
        profile: str | None = None
        lines = rest.split(b"\n", MAX_HEADER_LINES)
        for index, raw in enumerate(lines[:MAX_HEADER_LINES]):
            try:
                line = raw.decode("utf-8")
            except UnicodeDecodeError:
                return MalformedHeader("la cabecera no es UTF-8")
            if line == HEADER_END:
                return LaunchHeader(model, profile)
            if index == len(lines) - 1:
                break
            key, colon, value = line.partition(": ")
            if not colon or key not in ("model", "profile"):
                return MalformedHeader(f"línea que este host no entiende: {line!r}")
            if key == "model":
                if model is not None:
                    return MalformedHeader("model aparece dos veces")
                parsed = ModelId.parse(value)
                if not isinstance(parsed, ModelId):
                    return MalformedHeader(f"model no es <proveedor>/<modelo>: {value!r}")
                model = parsed
            else:
                if profile is not None:
                    return MalformedHeader("profile aparece dos veces")
                if not PROFILE_ID.fullmatch(value):
                    return MalformedHeader(f"profile no es un id de perfil: {value!r}")
                profile = value
        return MalformedHeader(f"la cabecera no cierra con {HEADER_END}")


@dataclass(frozen=True)
class Workspace:
    """Una carpeta en la que el host acepta abrir opencode: ruta real, raíz de un repo git, bajo la raíz
    del operador. Un encargo sin repo trabaja en la carpeta nueva <run>/work."""
    root: Path

    @staticmethod
    def for_repository(repository: object, *, allowed_root: Path) -> "Workspace | WorkspaceRefused":
        if not isinstance(repository, str):
            return WorkspaceRefused(str(repository)[:MAX_SHOWN], "invalid")
        if not Path(repository).is_absolute():
            return WorkspaceRefused(repository, "not-absolute")
        try:
            real = Path(repository).resolve()
            inside = Path(allowed_root).resolve() in real.parents
            # pathlib lanza ValueError con un NUL en la ruta, y RuntimeError con un bucle de enlaces hasta
            # Python 3.12. Desde 3.13 el bucle cuenta como ruta que no existe.
            folder, toplevel = real.is_dir(), (real / ".git").exists()
        except (OSError, RuntimeError, ValueError):
            return WorkspaceRefused(repository, "invalid")
        if not inside:
            return WorkspaceRefused(repository, "outside-root")
        if not folder:
            return WorkspaceRefused(repository, "missing")
        if not toplevel:
            return WorkspaceRefused(repository, "not-a-git-toplevel")
        return Workspace(real)

    @staticmethod
    def for_revision(input_revision: object, *, allowed_root: Path, run: RunDir) -> "Workspace | WorkspaceRefused":
        """`input_revision` llega de R sin validar: lo que no es una revisión `code` con su sha, o
        `artifact`, se rechaza. Sin sha usable, el paso de lanzamiento no tiene a qué hacer detach."""
        kind = input_revision.get("kind") if isinstance(input_revision, dict) else None
        if kind == "artifact":
            work = run.path / "work"
            work.mkdir(mode=0o700, exist_ok=True)
            return Workspace(work)
        if kind != "code":
            return WorkspaceRefused(str(input_revision)[:MAX_SHOWN], "invalid")
        sha = input_revision.get("sha")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40,64}", sha):
            return WorkspaceRefused(str(input_revision)[:MAX_SHOWN], "invalid")
        return Workspace.for_repository(input_revision.get("repository"), allowed_root=allowed_root)


@dataclass(frozen=True)
class Route:
    """Lo que se certifica una vez: host, CLI, forma de lanzamiento y versiones medidas del CLI, y las
    generaciones del paquete de poteto certificadas para encargos (SUA-03, 4.5)."""
    host_id: str
    adapter_id: str
    form: Literal["run-per-task"]
    status: str
    certified_cli_versions: frozenset[str]
    certified_context_generations: frozenset[str] = frozenset()

    @staticmethod
    def load(coverage: object, host_id: str, adapter_id: str = "opencode") -> "Route":
        """De coverage.json, sin lanzar con ninguna forma de archivo. La ruta existe solo si
        hostAdapterRoute declara para ese host una entrada de ese adaptador de forma `run-per-task`:
        recién entonces vale el estado de hostAdapterCoverage. Lo que falta o está mal escrito es
        una ruta ausente, sin versiones."""
        def at(*keys: str) -> object:
            value = coverage
            for key in keys:
                value = value.get(key) if isinstance(value, dict) else None
            return value
        entry, status = at("hostAdapterRoute", host_id, adapter_id), at("hostAdapterCoverage", host_id, adapter_id)
        if not isinstance(entry, dict) or entry.get("form") != ROUTE_FORM or not isinstance(status, str):
            return Route(host_id, adapter_id, ROUTE_FORM, "absent", frozenset())
        measured = entry.get("certifiedCliVersions")
        versions = (key for key in measured if isinstance(key, str)) if isinstance(measured, dict) else ()
        contexts = entry.get("contextGenerations")
        generations = (key for key in contexts if isinstance(key, str)) if isinstance(contexts, dict) else ()
        return Route(host_id, adapter_id, ROUTE_FORM, status, frozenset(versions), frozenset(generations))

    def open_for(self, cli_version: str, generation: int | None = None, *, canary: bool
                 ) -> "None | RouteNotCertified | GenerationNotCertified":
        """Abierta si el estado es `certified`, la versión está medida y, cuando la corrida lleva paquete,
        su generación está certificada. Con canary también abre para una versión nueva, un estado
        `sandbox-tested-uncertified` o una generación sin certificar: así se recertifica la ruta."""
        if canary and self.status in ("certified", "sandbox-tested-uncertified"):
            return None
        if self.status != "certified":
            # Las versiones medidas de una ruta sin certificar todavía no certifican nada.
            return RouteNotCertified(cli_version, ())
        if cli_version not in self.certified_cli_versions:
            return RouteNotCertified(cli_version, tuple(sorted(self.certified_cli_versions)))
        if generation is not None and str(generation) not in self.certified_context_generations:
            certified = tuple(sorted(int(key) for key in self.certified_context_generations if key.isdigit()))
            return GenerationNotCertified(generation, certified)
        return None


@dataclass(frozen=True)
class Package:
    """El paquete de poteto del checkout, ya leído y con su manifiesto íntegro (SUA-03, 4.5). Lo lee
    quien planea y lo que recibe `plan_launch`: la admisión del perfil decide con estos datos, sin
    tocar el disco. Un brief sin `profile` no lleva paquete y corre como hoy."""
    manifest: dict
    profiles: dict
    source: Path
    """La carpeta de la fuente fijada, de donde el paso de lanzamiento copia los archivos."""


@dataclass(frozen=True)
class LaunchSpec:
    """Todo lo que hace falta para lanzar, ya validado. No se puede construir con un modelo sin permiso."""
    model: PermittedModel
    workspace: Workspace
    run: RunDir
    record: Path
    session: str
    perfil: dict | None = None
    """El perfil admitido de esta corrida. None: un encargo de hoy, sin paquete."""
    config: dict | None = None
    """El OPENCODE_CONFIG_CONTENT que el lanzador va a pasar. None: el de toda la vida."""
    package: Package | None = None
    """El paquete que este plan leyó: el paso de lanzamiento copia de su fuente y relee su digest."""
    adapter_id: str = "opencode"
    """El adaptador que lanza esta corrida (SUA-04, 4.7): opencode o claude."""
    herramientas: tuple[str, ...] = ()
    """Las herramientas del perfil para el adaptador que pregunta por ellas (claude:
    --allowed-tools). opencode las lleva en su configuración y no mira esta lista."""


def session_name(operation: str) -> str:
    """El nombre sale de la operación: una repetición del mismo lanzamiento reserva la misma sesión."""
    return f"enc-{operation[:12]}"


def run_config(run: RunDir, model: ModelId, *, writes: bool) -> dict:
    """El OPENCODE_CONFIG_CONTENT de una corrida con paquete (diseño de SUA-03, 4.3 y 4.6), medido en
    M-13 (docs/evidence/sistema-agentes-unificado/SUA-03-mediciones.md): `instructions` y `skills.paths`
    apuntan dentro de la corrida, y `agent.<nombre>.model` fija el modelo del encargo para los siete
    agentes locales, porque sin él un hijo de `task` pide el modelo de su archivo a un proveedor que la
    corrida no tiene. Un perfil que no escribe fuente no recibe la herramienta de editar: M-13 midió que
    con `permission.edit: "deny"` opencode 1.18.35 se la quita al modelo.
    Limitación medida (M-13, punto b): una skill del paquete con el mismo nombre que una de
    `~/.agents/skills` o `~/.claude/skills` pierde contra la global. Lo declara coverage.json, y
    `opencode_env` la mitiga desde G4 apagando las skills externas en toda corrida con paquete."""
    permission: dict = {"external_directory": {"*": "deny", f"{run.path}/**": "allow"}}
    if not writes:
        permission["edit"] = "deny"
    return {
        "permission": permission,
        "enabled_providers": [model.provider],
        "small_model": str(model),
        "instructions": [str(run.context / "AGENTS.md")],
        "skills": {"paths": [str(run.context / "skills")]},
        "agent": {name: {"model": str(model)} for name in LOCAL_AGENTS},
    }


def _admits_tools(perfil: dict, config: dict) -> PerfilRechazado | None:
    """La configuración que el host va a pasar no niega ninguna herramienta del procedimiento (4.5)."""
    negadas = [tool for tool in perfil["requiredTools"].get("opencode", ())
               if config["permission"].get(tool) == "deny"]
    if negadas:
        return PerfilRechazado(
            "herramienta-negada",
            f"la configuración de la corrida niega {', '.join(negadas)} y el perfil {perfil['id']} la exige")
    return None


def _may_not_write(perfil: dict, config: dict) -> PerfilRechazado | None:
    """Un perfil que no escribe fuente llega solo si la configuración se la quita de verdad (4.5)."""
    if not perfil["writesSource"] and config["permission"].get("edit") != "deny":
        return PerfilRechazado(
            "revisor-con-escritura",
            f"el perfil {perfil['id']} no escribe fuente y la configuración de la corrida no niega edit")
    return None


def plan_launch(assignment: object, brief: bytes, *, policy: ProviderPolicy, catalog: Catalog, route: Route,
                cli_version: str, allowed_root: Path, run: RunDir, record: Path, operation: str,
                canary: bool = False, package: Package | None = None,
                now: "datetime | None" = None, state_root: "Path | None" = None) -> "LaunchSpec | Refusal":
    """La frontera donde lo que llegó de R (JSON y bytes) se vuelve tipos del dominio. El primer rechazo
    corta. Un brief sin cabecera pide el modelo por omisión, que también pasa por authorize.

    Con paquete (un brief que pide perfil), antes de tocar nada se admite al perfil (SUA-03, 4.5): la
    ruta abre para su generación, el id existe, atiende esta ruta, admite el contrato del encargo, tiene
    competencia vigente y fuentes sin vencer, y la configuración de la corrida le da sus herramientas
    sin darle el teclado a un revisor. La admisión exige el reloj del llamador (`now`): sin él, una
    fuente o una competencia vencida no vence nunca. Un encargo de hoy, sin paquete, corre como siempre
    y no mira el reloj."""
    if package is not None and now is None:
        raise TypeError("un plan con paquete exige el reloj del host (now)")
    closed = route.open_for(cli_version, package.manifest["generation"] if package else None, canary=canary)
    if closed is not None:
        return closed
    header = LaunchHeader.parse(brief)
    if isinstance(header, MalformedHeader):
        return header
    perfil: dict | None = None
    if package is not None:
        if header.profile is None:
            return PerfilRechazado("perfil-ausente", "el brief no trae perfil y la corrida lleva paquete")
        try:
            perfil = contexto.perfil(package.profiles, header.profile)
        except KeyError:
            return PerfilRechazado("perfil-desconocido", f"ningún perfil se llama {header.profile}")
        # El adaptador claude no es una ruta nueva del perfil (4.7 solo suma
        # requiredTools.claude al paquete): su admisión se juzga por la ruta CLI
        # del host, que en el perfil se llama opencode.
        executor = "opencode" if route.adapter_id == "claude" else route.adapter_id
        admitted = contexto.admite(perfil, {"host": route.host_id, "executor": executor, "agentId": None},
                                   assignment.get("resultContract") if isinstance(assignment, dict) else None,
                                   ahora=now, canario=canary)
        if admitted.causa is not None:
            return PerfilRechazado(admitted.causa, admitted.frase)
    model = authorize(ExactModel(header.model) if header.model else DefaultModel(), policy, catalog,
                      state_root=state_root)
    if not isinstance(model, PermittedModel):
        return model
    config: dict | None = None
    herramientas: tuple[str, ...] = ()
    if route.adapter_id == "claude":
        # claude no lee la configuración de opencode: sus herramientas van en
        # --allowed-tools y su encierro es el sandbox (M-23). Sin perfil, solo lee.
        herramientas = (
            tuple(perfil["requiredTools"].get("claude", ())) if perfil is not None else ("Read",)
        )
        if perfil is not None and not perfil["writesSource"] and (
            "Edit" in herramientas or "Write" in herramientas
        ):
            return PerfilRechazado(
                "revisor-con-escritura",
                f"el perfil {perfil['id']} no escribe fuente y sus herramientas de claude "
                "incluyen Edit o Write",
            )
    elif perfil is not None:
        # Las dos comprobaciones miran la configuración que este plan va a pasar, con el modelo ya admitido.
        config = run_config(run, model.model, writes=perfil["writesSource"])
        negada = _admits_tools(perfil, config)
        if negada is not None:
            return negada
        escritor = _may_not_write(perfil, config)
        if escritor is not None:
            return escritor
    revision = assignment.get("inputRevision") if isinstance(assignment, dict) else None
    workspace = Workspace.for_revision(revision, allowed_root=allowed_root, run=run)
    if not isinstance(workspace, Workspace):
        return workspace
    if perfil is not None and not perfil["writesSource"] and isinstance(revision, dict) \
            and revision.get("kind") == "code":
        # El revisor trabaja en un clon desechable dentro de la corrida (4.8), que arma el paso de
        # lanzamiento: plan_launch se queda puro y solo señala la carpeta.
        workspace = Workspace(run.repo)
    return LaunchSpec(model, workspace, run, record, session_name(operation), perfil, config, package,
                      route.adapter_id, herramientas)


SCRATCH_RULE = (" Keep every helper script and scratch file inside the directory that holds acceptRef, and touch "
                "nothing in /tmp or any other path outside it and workspaceRef: the CLI denies those commands.")
"""Va en el encargo y no solo en la asignación, para que el modelo no gaste pasos en comandos que opencode
va a negar. opencode 1.18.35 negó `rm /tmp/x` y dejó pasar `cat > /tmp/x` y `python3 /tmp/x`: la regla
cubre las herramientas de archivo y las rutas que reconoce en un comando, no confina el shell."""


def opencode_argv(spec: LaunchSpec, opencode_bin: Path, *, task_id: str) -> tuple[str, ...]:
    """El encargo viaja como un argumento, con stdin en /dev/null: no existe un teclado por el que alguien
    apruebe un permiso. Nunca lleva `--auto` ni `-i`: medido en opencode 1.18.35 (B22-fase0.md, M2 y M6),
    sin `--auto` niega cada permiso "ask" y termina. `--print-logs` manda a stderr la causa de un error, la
    carpeta de la sesión y el proveedor de cada llamada, que el flujo JSON no trae (M3)."""
    if task_id.startswith("-"):
        raise ValueError(f"un taskId no empieza con guion: {task_id!r}")
    return (str(opencode_bin), "run", "-m", str(spec.model.model), "--format", "json", "--print-logs",
            "--log-level", "INFO", "--title", task_id, delivery_line(str(spec.run.assignment)) + SCRATCH_RULE)


def opencode_env(spec: LaunchSpec) -> dict[str, str]:
    """El único sitio que arma el entorno de opencode.

    PWD es una guarda de seguridad: opencode 1.18.35 abre la sesión en la carpeta que dice PWD, no en el
    cwd real (B22-fase0.md, "PWD"), y el host corre desde su checkout, con la política adentro. La única
    carpeta externa permitida es la de esta corrida. `enabled_providers` y `small_model` cierran lo que el
    `-m` no cubre: opencode elige por su cuenta el modelo de títulos y el de sus subagentes (M3).

    `external_directory` lleva dos reglas y su orden importa: opencode aplica la última que coincide. Lo de
    fuera va con "deny" explícito y no con el "ask" por omisión: medido en 1.18.35 (B22-canarios.md, M7),
    un "ask" sin nadie que conteste termina la sesión, y un "deny" le devuelve el error al modelo, que
    sigue. Así murieron dos encargos con el trabajo hecho: `rm /tmp/x` (tarea bc3fd7b9) y la lectura de un
    archivo que nombra el AGENTS.md global de opencode (tarea 730557f4). TMPDIR apunta dentro de la corrida
    para que el modelo tenga dónde dejar sus archivos temporales."""
    model = spec.model.model
    config = spec.config if spec.config is not None else {
        "permission": {"external_directory": {"*": "deny", f"{spec.run.path}/**": "allow"}},
        "enabled_providers": [model.provider],
        "small_model": str(model),
    }
    env = {
        "PWD": str(spec.workspace.root),
        "TMPDIR": str(spec.run.scratch),
        "OPENCODE_DISABLE_AUTOUPDATE": "1",
        "AGENT_WORK_MANAGED": "1",
        "OPENCODE_CONFIG_CONTENT": json.dumps(config, separators=(",", ":")),
    }
    if spec.config is not None:
        # Medición del 2026-10-15 (SUA-03-mediciones.md, nota del punto b): la variable deja fuera
        # ~/.agents/skills y ~/.claude/skills a la vez, y con skills.paths del paquete quedan solo
        # las del paquete. Solo en una corrida con paquete: un encargo sin perfil queda igual.
        env["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
    return env


CLAUDE_SANDBOX_SETTINGS = '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'
"""El encierro de Bash de claude (M-23): con el sandbox, Bash escribe en el cwd y en las
carpetas de --add-dir, y en cualquier otro lado recibe `operation not permitted` del
sistema operativo. Es el equivalente de `external_directory: deny` de opencode."""


def claude_argv(spec: LaunchSpec, claude_bin: Path, *, task_id: str) -> tuple[str, ...]:
    """El argv de claude por su CLI (SUA-04, 4.7; medido en M-21/M-23).

    El modelo de la cabecera es `anthropic/<id>` y `--model` recibe el id sin el
    prefijo del proveedor: su --help acepta un alias (opus, sonnet) o el nombre
    completo. dontAsk con --permission-prompts none niega y sigue (M-21, punto 3);
    --add-dir lleva la carpeta de la corrida, la única fuera del cwd donde el
    sandbox deja escribir (M-23). `--restricted --strict-mcp-config --tools` deja
    en pie solo las herramientas del perfil (M-24): con `--setting-sources
    project`, el settings del repo     de trabajo corría sus hooks, sumaba permisos
    y traía los conectores de la cuenta. `--allowed-tools` lleva la misma lista.

    B3 de G7-r4: con perfil (paquete presente), `--append-system-prompt-file` lleva
    el AGENTS.md de la corrida, el mismo archivo que opencode recibe en
    `instructions` (run_config): sin él, claude no lee la skill ni el playbook del
    paquete y conducta sale roja (banco-r3). Sin perfil no hay paquete y no se suma
    nada. La ayuda de claude 2.1.301 lo lista como `--append-system-prompt[-file]`,
    vía de contexto junto a `--add-dir` y `--plugin-dir`; las skills del paquete se
    leen con Read por su ruta, como pide el bloque del AGENTS.md."""
    if task_id.startswith("-"):
        raise ValueError(f"un taskId no empieza con guion: {task_id!r}")
    herramientas = ",".join(spec.herramientas)
    argv = [
        str(claude_bin),
        "-p",
        delivery_line(str(spec.run.assignment)) + SCRATCH_RULE,
        "--model",
        spec.model.model.name,
        "--output-format",
        "stream-json",
        "--verbose",
        "--permission-mode",
        "dontAsk",
        "--permission-prompts",
        "none",
        "--restricted",
        "--strict-mcp-config",
        "--tools",
        herramientas,
        "--no-session-persistence",
        "--allowed-tools",
        herramientas,
        "--add-dir",
        str(spec.run.path),
        "--settings",
        CLAUDE_SANDBOX_SETTINGS,
    ]
    if spec.perfil is not None:
        argv += ["--append-system-prompt-file", str(spec.run.context / "AGENTS.md")]
    return tuple(argv)


def claude_env(spec: LaunchSpec) -> "dict[str, str | None]":
    """El entorno de claude. Sin ANTHROPIC_API_KEY (4.7): la suscripción entra por la
    sesión de David (M-21), y una llave en el entorno la taparía; el None es la marca
    de `unset` en el script de lanzamiento. La carpeta la fija el `cd` del lanzador
    (M-21, punto 2: claude usa el cwd del proceso, no PWD); PWD va igual al workspace
    para que ningún hijo lea el del host."""
    return {
        "PWD": str(spec.workspace.root),
        "TMPDIR": str(spec.run.scratch),
        "AGENT_WORK_MANAGED": "1",
        "ANTHROPIC_API_KEY": None,
    }


def claude_events(record: Path) -> "RunEvents | None":
    """Lo que claude dejó en su stream-json (M-21, punto 4): el cwd y el modelo de
    system/init, cada tool_use, y el result con modelUsage y permission_denials.
    None si el archivo no se puede leer, como read_events."""
    files = SessionRecord(record)
    first_at, error, opened = None, None, None
    denied, calls, tail = [], [], deque(maxlen=TAIL_LINES)
    usos: list = []
    ids_negados: set = set()
    negaciones: list = []
    used: list[str] = []
    try:
        with files.events.open(encoding="utf-8", errors="replace") as flow:
            for line in flow:
                tail.append(line.rstrip("\n"))
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                stamp = event.get("timestamp")
                if first_at is None and isinstance(stamp, str):
                    try:
                        first_at = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
                    except ValueError:
                        pass
                if event.get("type") == "system" and event.get("subtype") == "init":
                    opened = event.get("cwd") if isinstance(event.get("cwd"), str) else opened
                    if isinstance(event.get("model"), str):
                        used.append(event["model"])
                message = event.get("message") if isinstance(event.get("message"), dict) else {}
                if event.get("type") == "assistant" and isinstance(message.get("model"), str):
                    modelo = message["model"]
                    if modelo not in used:
                        used.append(modelo)
                    agente = "build" if event.get("parent_tool_use_id") is None else "task"
                    call = ModelCall(agente, f"anthropic/{modelo}", False)
                    if call not in calls:
                        calls.append(call)
                    for bloque in message.get("content") or ():
                        if isinstance(bloque, dict) and bloque.get("type") == "tool_use":
                            usos.append((str(bloque.get("name")), bloque.get("id")))
                if event.get("type") == "result":
                    for negado in event.get("permission_denials") or ():
                        if not isinstance(negado, dict):
                            continue
                        herramienta = str(negado.get("tool_name") or "")
                        entrada = negado.get("tool_input")
                        patron = (
                            str(entrada.get("file_path"))
                            if isinstance(entrada, dict) and entrada.get("file_path")
                            else json.dumps(entrada, ensure_ascii=False, sort_keys=True)
                            if entrada is not None
                            else ""
                        )
                        denied.append(PermissionDenied(herramienta, patron))
                        if isinstance(negado.get("tool_use_id"), str):
                            ids_negados.add(negado["tool_use_id"])
                        negaciones.append(f"{herramienta}:deny")
                    if not calls:
                        for modelo in (event.get("modelUsage") or {}):
                            calls.append(ModelCall("build", f"anthropic/{modelo}", False))
                            if modelo not in used:
                                used.append(modelo)
                    if event.get("is_error") or event.get("subtype") != "success":
                        error = str(event.get("result") or event.get("subtype") or "claude salió con error")
    except OSError:
        return None
    # Una herramienta negada no queda también como :allow (LOW de G7-r2): su
    # tool_use existe en el stream, pero permission_denials manda sobre él.
    evaluations = [f"{nombre}:allow" for nombre, uso_id in usos if uso_id not in ids_negados]
    evaluations += negaciones
    return RunEvents(first_at, tuple(dict.fromkeys(denied)), error, opened,
                     ("anthropic",) if used else (), tuple(tail), (), tuple(calls),
                     tuple(dict.fromkeys(evaluations)))


def claude_model_in_use(events: "RunEvents | None", requested: "str | None") -> "tuple[str | None, str | None]":
    """El modelo que claude corrió, de su stream, comparado con lo pedido (M1 de
    G7-r2). Lo pedido es un alias de CLAUDE_ALIASES o un nombre completo, con o sin
    el prefijo anthropic/: el alias tiene que aparecer como palabra en el usado
    (opus en claude-opus-5-5) y el nombre completo tiene que ser igual. Si corrió
    otro, se dice, como model_in_use de opencode."""
    if events is None:
        return None, "no se pueden leer los eventos de claude"
    used = list(dict.fromkeys(call.model for call in events.calls if call.agent == "build" and not call.small))
    if not used:
        return None, "claude no registró ninguna llamada"
    if requested is None:
        return None, f"claude usó {', '.join(used)} y no se sabe qué se pidió"
    pedido = requested.removeprefix("anthropic/")

    def es_lo_pedido(usado: str) -> bool:
        nombre = usado.removeprefix("anthropic/")
        if pedido in CLAUDE_ALIASES:
            return pedido in nombre.split("-")
        return nombre == pedido

    if not all(es_lo_pedido(usado) for usado in used):
        return None, f"claude usó {', '.join(used)} y se pidió {requested}"
    return used[0], None


EXIT_NO_SCRATCH = 96
EXIT_NO_WORKSPACE = 97
EXIT_OUTSIDE_GROUP = 98
"""Códigos con que launch.sh sale antes de llegar a opencode."""


def launch_script(spec: LaunchSpec, argv: tuple[str, ...], env: "dict[str, str | None]", gid: int) -> str:
    """Lo que lee el shell de newgrp. El entorno se fija aquí, justo antes del exec, y no con `tmux -e`: ni
    tmux ni ese shell pueden dejar otro PWD. newgrp corre el shell aunque no logre cambiar de grupo, así
    que la primera línea lo comprueba: un proceso fuera del grupo quedaría fuera de la frontera."""
    record = SessionRecord(spec.record)
    return "\n".join([
        f'[ "$(/usr/bin/id -rg)" = {gid} ] || exit {EXIT_OUTSIDE_GROUP}',
        f"cd -- {shlex.quote(str(adaptador(spec.adapter_id).carpeta(spec)))} || exit {EXIT_NO_WORKSPACE}",
        f"/bin/mkdir -p -m 700 -- {shlex.quote(str(spec.run.scratch))} || exit {EXIT_NO_SCRATCH}",
        *((f"export {name}={shlex.quote(value)}" if value is not None else f"unset {name}")
          for name, value in env.items()),
        f"exec {' '.join(map(shlex.quote, argv))} </dev/null >>{shlex.quote(str(record.events))} "
        f"2>>{shlex.quote(str(record.stderr))}",
    ]) + "\n"


REJECTED_TOOL_CALL = "The user rejected permission to use this specific tool call."
DENIED_BY_RULE = "The user has specified a rule which prevents you from using this specific tool call."
DENIED_LINE = re.compile(r"permission requested: (\S+) \((.*)\); auto-rejecting")
LOG_FIELD = re.compile(r'([A-Za-z_][\w.]*)=("(?:[^"\\]|\\.)*"|\S*)')
COLOUR = re.compile(r"\x1b\[[0-9;]*m")
TAIL_LINES = 40
SESSION_HEAD_LINES = 400


@dataclass(frozen=True)
class PermissionDenied:
    """Un permiso que opencode negó. Sale de stderr, de una de dos líneas:
        permission requested: <permission> (<pattern>); auto-rejecting
        … message=evaluated permission=<permission> pattern=<pattern> … action.action=deny
    La primera es un "ask" sin nadie que conteste, y termina la sesión. La segunda es una regla "deny": el
    modelo recibe el error y sigue. Si el flujo trae un `tool_use` negado y stderr no trae ninguna,
    `permission` es "tool:<herramienta>" y `pattern` queda vacío."""
    permission: str
    pattern: str


@dataclass(frozen=True)
class RunEvents:
    """Lo que el proceso dijo: el flujo de `--format json` y los logs que `--print-logs` manda a stderr.
    No tiene "esperando un permiso": `opencode run` no espera, niega y sale con 0 (M6). Un permiso negado
    se ve por la salida del proceso, y esto solo le pone causa."""
    first_at: float | None
    denied: tuple[PermissionDenied, ...]
    error: str | None
    session_directory: str | None
    providers_called: tuple[str, ...]
    tail: tuple[str, ...]
    """Las últimas líneas del flujo."""
    log_errors: tuple[str, ...]
    """Las últimas líneas level=ERROR de los logs."""
    calls: tuple["ModelCall", ...] = ()
    """Cada llamada al modelo que opencode registró, en orden."""
    evaluations: tuple[str, ...] = ()
    """Cada permiso que opencode evaluó, como "<permiso>:<acción>" y sin repetir: las reglas allow y
    deny (`message=evaluated`) y los ask que nadie contestó ("<permiso>:ask"). Vacío quiere decir que
    opencode no evaluó nada, no que no hubo permisos."""


@dataclass(frozen=True)
class ModelCall:
    """Una línea `message=stream`: qué agente de opencode llamó a qué modelo. `small` es el modelo
    pequeño que pone títulos; `agent` es `build` para la sesión del encargo, `title` para el título y
    el nombre del agente para un hijo de `task` (B22-fase0.md, M1)."""
    agent: str
    model: str
    small: bool


def _log_fields(line: str) -> dict[str, str]:
    fields = {}
    for name, value in LOG_FIELD.findall(line):
        if value.startswith('"'):
            try:
                value = json.loads(value)
            except ValueError:
                value = value[1:-1]
        fields[name] = value
    return fields


def _created_in(fields: dict[str, str]) -> str | None:
    if fields.get("message") == "created" and fields.get("id", "").startswith("ses_"):
        return fields.get("directory")
    return None


def session_directory(record: Path) -> str | None:
    """La carpeta en que opencode abrió la sesión, leída del principio de sus logs. None si todavía no la
    dice."""
    try:
        with SessionRecord(record).stderr.open(encoding="utf-8", errors="replace") as log:
            for _, line in zip(range(SESSION_HEAD_LINES), log):
                opened = _created_in(_log_fields(line))
                if opened is not None:
                    return opened
    except OSError:
        return None
    return None


def read_events(record: Path) -> RunEvents | None:
    """Frontera con lo que escribe opencode. None si los archivos no se pueden leer. Una línea que no es
    JSON, un evento desconocido o una línea de log con otra forma no fallan: no aportan y ya. Las formas
    son las medidas en opencode 1.18.35 (B22-fase0.md); una versión nueva cierra la ruta antes."""
    files = SessionRecord(record)
    first_at, flow_error, rejected, tail = None, None, [], deque(maxlen=TAIL_LINES)
    denied, log_error, log_cause, opened, providers = [], None, None, None, []
    calls, evaluations = [], []
    log_errors = deque(maxlen=TAIL_LINES)
    try:
        with files.events.open(encoding="utf-8", errors="replace") as flow:
            for line in flow:
                tail.append(line.rstrip("\n"))
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                stamp = event.get("timestamp")
                if first_at is None and isinstance(stamp, (int, float)) and not isinstance(stamp, bool):
                    first_at = stamp / 1000
                part = event.get("part") if isinstance(event.get("part"), dict) else {}
                state = part.get("state") if isinstance(part.get("state"), dict) else {}
                if event.get("type") == "tool_use" and str(state.get("error")).startswith(
                        (REJECTED_TOOL_CALL, DENIED_BY_RULE)):
                    rejected.append(PermissionDenied(f"tool:{part.get('tool')}", ""))
                failure = event.get("error") if event.get("type") == "error" else None
                if isinstance(failure, dict):
                    data = failure.get("data") if isinstance(failure.get("data"), dict) else {}
                    flow_error = str(data.get("message") or failure.get("name") or flow_error)
        with files.stderr.open(encoding="utf-8", errors="replace") as log:
            for line in log:
                line = COLOUR.sub("", line)
                asked = DENIED_LINE.search(line)
                if asked:
                    denied.append(PermissionDenied(asked[1], asked[2]))
                    evaluations.append(f"{asked[1]}:ask")
                    continue
                fields = _log_fields(line)
                if fields.get("message") == "evaluated" and fields.get("action.action"):
                    evaluations.append(f"{fields.get('permission', '')}:{fields['action.action']}")
                if fields.get("message") == "evaluated" and fields.get("action.action") == "deny":
                    denied.append(PermissionDenied(fields.get("permission", ""), fields.get("pattern", "")))
                    continue
                opened = opened or _created_in(fields)
                if fields.get("message") == "stream" and fields.get("providerID"):
                    providers.append(fields["providerID"])
                    if fields.get("modelID"):
                        calls.append(ModelCall(fields.get("agent", ""), f"{fields['providerID']}/{fields['modelID']}",
                                               fields.get("small") == "true"))
                if fields.get("level") == "ERROR":
                    log_errors.append(line.rstrip("\n"))
                    log_error = fields.get("error") or log_error
                    log_cause = log_cause or fields.get("cause") or fields.get("message")
    except OSError:
        return None
    return RunEvents(first_at, tuple(dict.fromkeys(denied or rejected)), log_error or log_cause or flow_error, opened,
                     tuple(dict.fromkeys(providers)), tuple(tail), tuple(log_errors), tuple(calls),
                     tuple(dict.fromkeys(evaluations)))


def model_in_use(events: RunEvents | None, requested: str | None) -> tuple[str | None, str | None]:
    """El modelo que corrió el encargo y, si no se sabe, por qué (diseño de SUA-03, 4.7). Cuenta las
    llamadas de la sesión del encargo (`agent=build`, `small=false`) y las compara con el `-m` pedido."""
    if events is None:
        return None, "no se pueden leer los logs de opencode"
    used = list(dict.fromkeys(call.model for call in events.calls if call.agent == "build" and not call.small))
    if not used:
        return None, "opencode no registró ninguna llamada"
    if requested is None:
        return None, f"opencode usó {', '.join(used)} y no se sabe qué se pidió"
    other = [model for model in used if model != requested]
    if other:
        return None, f"opencode usó {', '.join(other)} y se pidió {requested}"
    return requested, None


class Adaptador:
    """Un CLI que el host lanza por encargo (SUA-04, 4.7): su id, su argv, su entorno,
    la carpeta de la corrida y cómo se leen sus eventos. opencode es la primera
    implementación y su comportamiento no cambia; claude es la segunda."""

    id: str = ""

    def argv(self, spec: LaunchSpec, bin_path: Path, *, task_id: str) -> tuple[str, ...]:
        raise NotImplementedError

    def env(self, spec: LaunchSpec) -> "dict[str, str | None]":
        raise NotImplementedError

    def carpeta(self, spec: LaunchSpec) -> Path:
        """La carpeta de trabajo de la corrida: el lanzador hace cd a ella y no se
        fía de PWD (M-21, punto 2, al revés que opencode)."""
        return spec.workspace.root

    def leer_eventos(self, record: Path) -> "RunEvents | None":
        raise NotImplementedError

    def directorio_sesion(self, record: Path) -> "str | None":
        eventos = self.leer_eventos(record)
        return eventos.session_directory if eventos else None

    def modelo_en_uso(self, events: "RunEvents | None", requested: "str | None"):
        raise NotImplementedError


class AdaptadorOpencode(Adaptador):
    id = "opencode"

    def argv(self, spec, bin_path, *, task_id):
        return opencode_argv(spec, bin_path, task_id=task_id)

    def env(self, spec):
        return opencode_env(spec)

    def leer_eventos(self, record):
        return read_events(record)

    def directorio_sesion(self, record):
        return session_directory(record)

    def modelo_en_uso(self, events, requested):
        return model_in_use(events, requested)


class AdaptadorClaude(Adaptador):
    id = "claude"

    def argv(self, spec, bin_path, *, task_id):
        return claude_argv(spec, bin_path, task_id=task_id)

    def env(self, spec):
        return claude_env(spec)

    def leer_eventos(self, record):
        return claude_events(record)

    def modelo_en_uso(self, events, requested):
        return claude_model_in_use(events, requested)


ADAPTADORES: "dict[str, Adaptador]" = {a.id: a for a in (AdaptadorOpencode(), AdaptadorClaude())}
"""Los adaptadores que este host sabe lanzar, por id de ruta (coverage.json)."""


def adaptador(adapter_id: str) -> Adaptador:
    """El adaptador de ese id, o ValueError: una ruta que el host no implementa no se lanza."""
    try:
        return ADAPTADORES[adapter_id]
    except KeyError:
        raise ValueError(f"el host no implementa el adaptador {adapter_id!r}") from None


@dataclass(frozen=True)
class SessionExit:
    """El código 0 no dice que el encargo salió bien: tras negar un permiso, opencode sale con 0 (M2). Lo
    que cuenta es si hay acuse y resultado. `code` es None cuando la sesión ya no existe y su estado de
    salida no se puede leer."""
    code: int | None


@dataclass(frozen=True)
class ClosureProof:
    """Evidencia de un cierre. Su digest viaja a R en managedTasks.host.close."""
    pane_gone: bool
    session_gone: bool
    boundary_before: tuple[str, ...]
    signals: tuple[str, ...]
    boundary_after: tuple[str, ...]

    @property
    def absent(self) -> bool:
        return self.pane_gone and self.session_gone and not self.boundary_after


@dataclass(frozen=True)
class BoundaryProcess:
    pid: int
    lstart: str
    command: str

    def __str__(self) -> str:
        return f"{self.pid} {self.lstart} {self.command}"


NEWGRP = "/usr/bin/newgrp"
PS_ROW = re.compile(r"\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})(?:\s(.*))?")
COMMAND_SHOWN = 200
KILL_WAIT_SECONDS = 2.0


def parse_boundary(table: str, uid: int, gid: int) -> tuple[BoundaryProcess, ...]:
    """Las filas `uid rgid pid lstart command` de ese usuario y ese grupo real. ps imprime un salto de
    línea del argv tal cual, así que una línea que no es una fila completa es parte del comando anterior.
    Una fila falsa escrita así solo puede agregar un proceso a la frontera, nunca esconder uno."""
    found: list[BoundaryProcess] = []
    for line in table.splitlines():
        row = PS_ROW.fullmatch(line)
        if row is None:
            continue
        if int(row[1]) == uid and int(row[2]) == gid:
            found.append(BoundaryProcess(int(row[3]), " ".join(row[4].split()),
                                         (row[5] or "").strip()[:COMMAND_SHOWN]))
    return tuple(found)


def read_process_table() -> str:
    done = _ps("-A", "-ww", "-o", "uid=,rgid=,pid=,lstart=,command=")
    if done.returncode != 0:
        raise OSError("process table unreadable")
    return done.stdout


def read_process(pid: int) -> str:
    """La fila de un solo pid, leída del kernel: una fila falsa en el argv de otro proceso no llega aquí."""
    return _ps("-o", "uid=,rgid=,pid=,lstart=,command=", "-p", str(pid)).stdout


class GroupBoundaryBackend(TmuxBackend):
    """Backend TaskCreated que corre el pane con un grupo primario dedicado al slot, en la cuenta del
    operador. La frontera es (uid, rgid): el rgid se hereda por fork, exec, setsid y doble fork, `ps` lo
    muestra para cualquier binario y un proceso sin privilegios no puede cambiarlo. Medido en macOS 26.7
    con `newgrp agent-work-enc1` dentro de tmux (B22-fase0.md, M4). Los archivos nuevos no heredan ese
    grupo: toman el de su carpeta.

    Escapa quien llame a un binario setuid que cambia de grupo (newgrp, su) o quien le pida el trabajo a
    launchd (`open`, `launchctl`). Es el límite declarado de la prueba (coverage.json)."""
    FORMAT = "#{pid}|#{session_id}|#{pane_id}|#{pane_pid}|#{@agent_work_resource_nonce}|#{session_created}"

    def __init__(self, tmux_bin: str, socket: str, group: str, boot_id: str | None = None, *,
                 grace_seconds: float = 5.0, gid: int | None = None,
                 table: Callable[[], str] = read_process_table, process: Callable[[int], str] = read_process,
                 kill: Callable[[int, int], None] = os.kill, sleep: Callable[[float], None] = time.sleep):
        super().__init__(tmux_bin, socket, boot_id)
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,63}", group):
            raise ValueError("invalid slot group")
        self.group = group
        self.uid = os.getuid()
        if gid is None:
            try:
                entry = grp.getgrnam(group)
            except KeyError as exc:
                raise ValueError(f"slot group {group} does not exist") from exc
            if pwd.getpwuid(self.uid).pw_name not in entry.gr_mem:
                raise ValueError(f"this user is not a member of the slot group {group}")
            gid = entry.gr_gid
        if gid == os.getgid():
            raise ValueError("the slot group cannot be the host's own group: the boundary would hold the host")
        self.gid = gid
        self.grace_seconds = grace_seconds
        self._table, self._process, self._kill, self._sleep = table, process, kill, sleep
        self.last_closure: ClosureProof | None = None

    def boundary(self) -> tuple[BoundaryProcess, ...]:
        return parse_boundary(self._table(), self.uid, self.gid)

    def launch(self, spec: LaunchSpec, nonce: str, argv: tuple[str, ...], env: dict[str, str]) -> None:
        """Una sesión nueva cuyo pane entra al grupo del slot y lee launch.sh. Un solo comando tmux deja la
        sesión con su nonce y con remain-on-exit, así un proceso que sale en menos de un segundo sigue
        siendo la sesión de este recurso."""
        busy = self.boundary()
        if busy:
            raise BoundaryBusy(busy)
        record = SessionRecord(spec.record)
        record.path.mkdir(mode=0o700, parents=True, exist_ok=True)
        atomic_json(record.argv, list(argv))
        descriptor = os.open(record.launch, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as script:
            script.write(launch_script(spec, argv, env, self.gid))
        target = f"={spec.session}:"
        done = self._tmux(
            "new-session", "-d", "-s", spec.session, "-x", "200", "-y", "50", "-c", str(spec.workspace.root),
            f"exec {NEWGRP} {shlex.quote(self.group)} < {shlex.quote(str(record.launch))}",
            ";", "set-option", "-t", target, self.NONCE_OPTION, nonce,
            ";", "set-option", "-t", target, "remain-on-exit", "on")
        if done.returncode:
            raise OSError(f"tmux could not launch {spec.session}: {done.stderr.strip()}")

    def observe(self, session: str) -> dict | None:
        """La identidad de la sesión, viva o con el pane muerto: el proceso de esta ruta termina solo, y la
        identidad no cambia cuando lo hace. Lleva la hora en que tmux creó la sesión en lugar de la hora de
        inicio del proceso, que deja de poder leerse cuando sale."""
        if not session or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
                              for c in session):
            raise ValueError("invalid tmux session")
        shown = self._tmux("display-message", "-p", "-t", f"={session}:", self.FORMAT)
        parts = shown.stdout.strip().split("|")
        if shown.returncode or len(parts) != 6:
            return None
        server_pid, session_id, pane_id, pane_pid, nonce, created = parts
        server_start = self._start(server_pid)
        if not server_start or not pane_pid.isdigit():
            return None
        return {"bootId": self.boot_id, "nonce": nonce, "socket": self.socket, "sessionName": session,
                "serverPid": int(server_pid), "serverStart": server_start, "sessionId": session_id,
                "paneId": pane_id, "panePid": int(pane_pid), "sessionCreated": created}

    def exit_of(self, identity: dict) -> SessionExit | None:
        """None mientras el pane vive. Una sesión que ya no existe salió, con código desconocido."""
        if self.observe(identity["sessionName"]) != identity:
            return SessionExit(None)
        shown = self._tmux("display-message", "-p", "-t", identity["paneId"], "#{pane_dead}|#{pane_dead_status}")
        dead, _, status = shown.stdout.strip().partition("|")
        if shown.returncode:
            return SessionExit(None)
        if dead != "1":
            return None
        return SessionExit(int(status) if status.isdigit() else None)

    def _confirmed(self, target: BoundaryProcess) -> bool:
        return target in parse_boundary(self._process(target.pid), self.uid, self.gid)

    def _sweep(self) -> tuple[tuple[BoundaryProcess, ...], tuple[str, ...], tuple[BoundaryProcess, ...]]:
        """TERM a lo que hay en la frontera, gracia, KILL a lo que quede, relectura. Cada señal va a un pid
        cuyo uid, rgid y hora de inicio se confirmaron justo antes, nunca a un nombre."""
        before = self.boundary()
        signals = []
        for sent, wait in ((signal.SIGTERM, self.grace_seconds), (signal.SIGKILL, KILL_WAIT_SECONDS)):
            targets = [target for target in self.boundary() if self._confirmed(target)]
            if not targets:
                break
            for target in targets:
                try:
                    self._kill(target.pid, sent)
                except ProcessLookupError:
                    continue
                except PermissionError:
                    signals.append(f"{sent.name} {target.pid} EPERM")
                    continue
                signals.append(f"{sent.name} {target.pid}")
            waited = 0.0
            while waited < wait and set(targets) & set(self.boundary()):
                self._sleep(0.1)
                waited += 0.1
        return before, tuple(signals), self.boundary()

    def prove_absent(self, identity: dict) -> bool:
        """Mata la sesión y barre la frontera. True solo si la sesión ya no existe y la frontera quedó
        vacía; lo que encontró queda en last_closure."""
        self.last_closure = None
        if self.observe(identity["sessionName"]) == identity:
            self.stop(identity)
        session_gone = self.observe(identity["sessionName"]) != identity
        before, signals, after = self._sweep()
        self.last_closure = ClosureProof(identity["panePid"] not in {process.pid for process in after}, session_gone,
                                         tuple(map(str, before)), signals, tuple(map(str, after)))
        return self.last_closure.absent

    def prove_slot_empty(self) -> bool:
        """El cierre de un lanzamiento que no dejó sesión con su nonce: no hay pane que matar, y la frontera
        vacía prueba que no dejó nada vivo."""
        self.last_closure = None
        before, signals, after = self._sweep()
        self.last_closure = ClosureProof(True, True, tuple(map(str, before)), signals, tuple(map(str, after)))
        return self.last_closure.absent
