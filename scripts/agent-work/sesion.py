"""Qué va a lanzar el host para un encargo: la cabecera del brief, la carpeta validada, la ruta
certificada y el plan que las junta con un modelo permitido."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from contracts import RunDir
from modelos import (Catalog, DefaultModel, ExactModel, MalformedHeader, ModelId, PermittedModel, ProviderPolicy,
                     Refusal, RouteNotCertified, WorkspaceRefused, authorize)

LAUNCH_SCHEMA = "agent-work.launch.v1"
HEADER_END = "---"
MAX_HEADER_LINES = 16
ROUTE_FORM = "run-per-task"
MAX_SHOWN = 200
COVERAGE_FILE = Path("docs/evidence/agent-work/coverage.json")

ALLOWED_ROOT = Path("/Users/dn/dev")
"""David, P10866: "2. cualquiera". Cualquier repo bajo `~/dev`."""


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

    @staticmethod
    def parse(brief: bytes) -> "LaunchHeader | MalformedHeader":
        first, _, rest = brief.partition(b"\n")
        if first != LAUNCH_SCHEMA.encode():
            # Una línea de esquema con un espacio o un CR de más no corre el modelo por omisión en silencio.
            if first.strip() == LAUNCH_SCHEMA.encode():
                return MalformedHeader(f"la primera línea no es exactamente {LAUNCH_SCHEMA}")
            return LaunchHeader(None)
        model: ModelId | None = None
        lines = rest.split(b"\n", MAX_HEADER_LINES)
        for index, raw in enumerate(lines[:MAX_HEADER_LINES]):
            try:
                line = raw.decode("utf-8")
            except UnicodeDecodeError:
                return MalformedHeader("la cabecera no es UTF-8")
            if line == HEADER_END:
                return LaunchHeader(model)
            if index == len(lines) - 1:
                break
            key, colon, value = line.partition(": ")
            if key != "model" or not colon:
                return MalformedHeader(f"línea que este host no entiende: {line!r}")
            if model is not None:
                return MalformedHeader("model aparece dos veces")
            parsed = ModelId.parse(value)
            if not isinstance(parsed, ModelId):
                return MalformedHeader(f"model no es <proveedor>/<modelo>: {value!r}")
            model = parsed
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
        """`input_revision` llega de R sin validar: lo que no es una revisión `code` o `artifact` se rechaza."""
        kind = input_revision.get("kind") if isinstance(input_revision, dict) else None
        if kind == "artifact":
            work = run.path / "work"
            work.mkdir(mode=0o700, exist_ok=True)
            return Workspace(work)
        if kind != "code":
            return WorkspaceRefused(str(input_revision)[:MAX_SHOWN], "invalid")
        return Workspace.for_repository(input_revision.get("repository"), allowed_root=allowed_root)


@dataclass(frozen=True)
class Route:
    """Lo que se certifica una vez: host, CLI, forma de lanzamiento y versiones medidas del CLI."""
    host_id: str
    adapter_id: Literal["opencode"]
    form: Literal["run-per-task"]
    status: str
    certified_cli_versions: frozenset[str]

    @staticmethod
    def load(coverage: object, host_id: str) -> "Route":
        """De coverage.json, sin lanzar con ninguna forma de archivo. La ruta existe solo si
        hostAdapterRoute declara para ese host una entrada `opencode` de forma `run-per-task`: recién
        entonces vale el estado de hostAdapterCoverage, que sin esa entrada certifica otra ruta, la de la
        sesión adoptada. Lo que falta o está mal escrito es una ruta ausente, sin versiones."""
        def at(*keys: str) -> object:
            value = coverage
            for key in keys:
                value = value.get(key) if isinstance(value, dict) else None
            return value
        entry, status = at("hostAdapterRoute", host_id, "opencode"), at("hostAdapterCoverage", host_id, "opencode")
        if not isinstance(entry, dict) or entry.get("form") != ROUTE_FORM or not isinstance(status, str):
            return Route(host_id, "opencode", ROUTE_FORM, "absent", frozenset())
        measured = entry.get("certifiedCliVersions")
        versions = (key for key in measured if isinstance(key, str)) if isinstance(measured, dict) else ()
        return Route(host_id, "opencode", ROUTE_FORM, status, frozenset(versions))

    def open_for(self, cli_version: str, *, canary: bool) -> "None | RouteNotCertified":
        """Abierta si el estado es `certified` y la versión está medida. Con canary también abre para una
        versión nueva o un estado `sandbox-tested-uncertified`: así se recertifica la ruta."""
        if canary and self.status in ("certified", "sandbox-tested-uncertified"):
            return None
        if self.status == "certified" and cli_version in self.certified_cli_versions:
            return None
        return RouteNotCertified(cli_version, tuple(sorted(self.certified_cli_versions)))


@dataclass(frozen=True)
class LaunchSpec:
    """Todo lo que hace falta para lanzar, ya validado. No se puede construir con un modelo sin permiso."""
    model: PermittedModel
    workspace: Workspace
    run: RunDir
    record: Path
    session: str


def plan_launch(assignment: object, brief: bytes, *, policy: ProviderPolicy, catalog: Catalog, route: Route,
                cli_version: str, allowed_root: Path, run: RunDir, record: Path, operation: str,
                canary: bool = False) -> "LaunchSpec | Refusal":
    """La frontera donde lo que llegó de R (JSON y bytes) se vuelve tipos del dominio. El primer rechazo
    corta. Un brief sin cabecera pide el modelo por omisión, que también pasa por authorize."""
    closed = route.open_for(cli_version, canary=canary)
    if closed is not None:
        return closed
    header = LaunchHeader.parse(brief)
    if isinstance(header, MalformedHeader):
        return header
    model = authorize(ExactModel(header.model) if header.model else DefaultModel(), policy, catalog)
    if not isinstance(model, PermittedModel):
        return model
    revision = assignment.get("inputRevision") if isinstance(assignment, dict) else None
    workspace = Workspace.for_revision(revision, allowed_root=allowed_root, run=run)
    if not isinstance(workspace, Workspace):
        return workspace
    # El nombre sale de la operación: una repetición del mismo lanzamiento reserva la misma sesión.
    return LaunchSpec(model, workspace, run, record, f"enc-{operation[:12]}")
