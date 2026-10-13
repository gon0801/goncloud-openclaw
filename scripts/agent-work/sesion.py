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
from pathlib import Path
from typing import Callable, Literal

from contracts import RunDir, SessionRecord
from host import delivery_line
from modelos import (Catalog, DefaultModel, ExactModel, MalformedHeader, ModelId, PermittedModel, ProviderPolicy,
                     Refusal, RouteNotCertified, WorkspaceRefused, authorize)
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
        entonces vale el estado de hostAdapterCoverage. Lo que falta o está mal escrito es una ruta ausente,
        sin versiones."""
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
        if self.status != "certified":
            # Las versiones medidas de una ruta sin certificar todavía no certifican nada.
            return RouteNotCertified(cli_version, ())
        if cli_version in self.certified_cli_versions:
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


def session_name(operation: str) -> str:
    """El nombre sale de la operación: una repetición del mismo lanzamiento reserva la misma sesión."""
    return f"enc-{operation[:12]}"


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
    return LaunchSpec(model, workspace, run, record, session_name(operation))


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
    return {
        "PWD": str(spec.workspace.root),
        "TMPDIR": str(spec.run.scratch),
        "OPENCODE_DISABLE_AUTOUPDATE": "1",
        "AGENT_WORK_MANAGED": "1",
        "OPENCODE_CONFIG_CONTENT": json.dumps({
            "permission": {"external_directory": {"*": "deny", f"{spec.run.path}/**": "allow"}},
            "enabled_providers": [model.provider],
            "small_model": str(model),
        }, separators=(",", ":")),
    }


EXIT_NO_SCRATCH = 96
EXIT_NO_WORKSPACE = 97
EXIT_OUTSIDE_GROUP = 98
"""Códigos con que launch.sh sale antes de llegar a opencode."""


def launch_script(spec: LaunchSpec, argv: tuple[str, ...], env: dict[str, str], gid: int) -> str:
    """Lo que lee el shell de newgrp. El entorno se fija aquí, justo antes del exec, y no con `tmux -e`: ni
    tmux ni ese shell pueden dejar otro PWD. newgrp corre el shell aunque no logre cambiar de grupo, así
    que la primera línea lo comprueba: un proceso fuera del grupo quedaría fuera de la frontera."""
    record = SessionRecord(spec.record)
    return "\n".join([
        f'[ "$(/usr/bin/id -rg)" = {gid} ] || exit {EXIT_OUTSIDE_GROUP}',
        f"cd -- {shlex.quote(str(spec.workspace.root))} || exit {EXIT_NO_WORKSPACE}",
        f"/bin/mkdir -p -m 700 -- {shlex.quote(str(spec.run.scratch))} || exit {EXIT_NO_SCRATCH}",
        *(f"export {name}={shlex.quote(value)}" for name, value in env.items()),
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
                    continue
                fields = _log_fields(line)
                if fields.get("message") == "evaluated" and fields.get("action.action") == "deny":
                    denied.append(PermissionDenied(fields.get("permission", ""), fields.get("pattern", "")))
                    continue
                opened = opened or _created_in(fields)
                if fields.get("message") == "stream" and fields.get("providerID"):
                    providers.append(fields["providerID"])
                if fields.get("level") == "ERROR":
                    log_errors.append(line.rstrip("\n"))
                    log_error = fields.get("error") or log_error
                    log_cause = log_cause or fields.get("cause") or fields.get("message")
    except OSError:
        return None
    return RunEvents(first_at, tuple(dict.fromkeys(denied or rejected)), log_error or log_cause or flow_error, opened,
                     tuple(dict.fromkeys(providers)), tuple(tail), tuple(log_errors))


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
