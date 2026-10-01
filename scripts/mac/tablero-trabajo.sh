#!/bin/bash
# scripts/mac/tablero-trabajo.sh: registra en el tablero-runbook un trabajo que
# claw lleva a mano (encargo directo de David, sin corrida.sh), para que el
# tick sin modelo de avance-tareas lo reporte y lo deje de reportar al cerrar.
# Instalado vive en ~/bin/tablero-trabajo.sh. Habla con el gateway por el CLI
# de openclaw (runbook.progress.get/event); el documento lleva `corrida` para
# vivir bajo su propia clave y `fase` 0, que ninguna fase real usa, y
# `plan: null` para que el tablero cuente
# sus partes en vez de tratarlo como una fase cuyo plan no pudo cruzar.
# Uso:
#   tablero-trabajo.sh abrir <id> "<titulo>" "<parte1>" ["<parte2>" ...] [--siguiente "..."] [--repo owner/repo]
#   tablero-trabajo.sh agregar <id> "<parte>"
#   tablero-trabajo.sh paso <id> <parte> <estado> "<que paso>" [--siguiente "..."] [--pr N]
#   tablero-trabajo.sh atencion <id> "<que necesito de David>" | --resuelta
#   tablero-trabajo.sh cerrar <id> "<resumen de una linea>"
#   tablero-trabajo.sh ver <id>
# <parte> es el numero (1, 2, ...) o el id (p1, p2, ...). Sale 0 solo si el
# gateway contesto "ok": true; si no, imprime sus razones y sale 1.
# Env: OPENCLAW_BIN, PROGRESS_EVENTS_BIN, PROGRESS_EVENTS_STATE_DIR,
# TABLERO_TOPE_SEG (def. 60).
set -u
export OPENCLAW_BIN="${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}"
export PROGRESS_EVENTS_BIN="${PROGRESS_EVENTS_BIN:-$(dirname "$0")/progress-events.py}"
exec python3 - "$@" <<'PY'
import datetime, hashlib, json, os, pathlib, re, subprocess, sys, tempfile, uuid

ESTADOS = ["pendiente", "implementando", "revision-cruzada", "coderabbit", "auditoria-lead",
           "en-cola", "mergeado", "atorado", "revertido", "omitido"]
CORRIDA_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9._-]{1,100}$")
FASE = "0"
REPO_DEF = "gon0801/goncloud-openclaw"
# Los mismos marcadores reservados que validarMensajeV1 y corrida_encabezado.
MARCADOR_RE = re.compile(r"Comando: |(Que cambio|Qué cambió): |(Que sigue|Qué sigue): |(Que necesito de ti|Qué necesito de ti): ")
USO = "uso: tablero-trabajo.sh abrir|agregar|paso|atencion|cerrar|ver <id> ..."


def morir(msg, rc=1):
    print(f"tablero-trabajo: {msg}", file=sys.stderr)
    sys.exit(rc)


def ahora():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def texto(s, tope, campo):
    s = re.sub(r"\s+", " ", s or "").strip()
    if not s:
        morir(f"{campo} vacio", 2)
    return s if len(s) <= tope else s[: tope - 1] + "…"


def tope():
    v = os.environ.get("TABLERO_TOPE_SEG", "60")
    if not (v.isascii() and v.isdigit()) or int(v) < 1:
        morir(f"TABLERO_TOPE_SEG invalido {v!r}: segundos, entero positivo", 2)
    return int(v)


def llamar(metodo, params):
    cmd = [os.environ["OPENCLAW_BIN"], "gateway", "call", metodo, "--params", json.dumps(params, ensure_ascii=False),
           "--json", "--timeout", "30000"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=tope())
    except (OSError, subprocess.TimeoutExpired) as e:
        morir(f"{metodo}: el CLI de openclaw no contesto ({e.__class__.__name__})")
    # El CLI puede anteponer avisos de config: se parsea desde la primera linea que abre un objeto.
    m = re.search(r"^\{", r.stdout, re.M)
    try:
        d = json.loads(r.stdout[m.start():]) if m else None
    except ValueError:
        d = None
    if not isinstance(d, dict):
        morir(f"{metodo}: respuesta sin JSON (rc {r.returncode}): {(r.stdout + r.stderr).strip()[:400]}")
    return d


REVISION = {}


def leer(id_, imported=False):
    d = llamar("runbook.progress.get", {"corrida": id_})
    if d.get("ok") is True and isinstance(d.get("doc"), dict):
        if not isinstance(d.get("revision"), int):
            if imported:
                morir("el gateway no devolvio revision tras importar el trabajo")
            importar_legacy(id_, d["doc"])
            return leer(id_, imported=True)
        REVISION[id_] = d["revision"]
        return d["doc"]
    if (d.get("razon") or d.get("reason")) == "desconocida":
        REVISION[id_] = 0
        return None
    morir(f"runbook.progress.get: {d.get('razon') or d.get('reason') or d}")


def estado_local():
    return pathlib.Path(os.environ.get("PROGRESS_EVENTS_STATE_DIR", str(pathlib.Path.home() / ".local/state/runbook-progress-events")))


def cliente(*args):
    cmd = [sys.executable, os.environ["PROGRESS_EVENTS_BIN"], "--state-dir", str(estado_local()),
           "--openclaw-bin", os.environ["OPENCLAW_BIN"], *args]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=tope() + 10)
    except (OSError, subprocess.TimeoutExpired) as e:
        morir(f"progress-events: no contesto ({e.__class__.__name__})")


def encolar(comando):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".json", delete=False) as f:
        json.dump(comando, f, ensure_ascii=False)
        path = f.name
    try:
        r = cliente("queue-event", "--event-json", path)
    finally:
        os.unlink(path)
    if r.returncode:
        morir("no se pudo guardar el evento: " + r.stderr.strip())


def pendientes(id_):
    cola = estado_local() / "runs" / id_ / "queue"
    if not cola.is_dir():
        return []
    try:
        return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(cola.glob("*.json"))]
    except (OSError, ValueError) as e:
        morir(f"cola local ilegible: {e}")


def publicar_cola(id_, event_id=None):
    for _ in range(3):
        r = cliente("publish", "--corrida", id_)
        if r.returncode == 0:
            return True
        if event_id and (estado_local() / "runs" / id_ / "rejected" / (event_id + ".conflict.json")).exists():
            return False
    morir("no se pudo publicar el evento; quedo en la cola: " + r.stderr.strip())


def importar_legacy(id_, doc):
    if doc.get("corrida") != id_:
        morir("el documento legacy no corresponde a la corrida")
    raw = json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    identifier = "import-manual-" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]
    comando = {"kind": "run.opened", "id": identifier, "corrida": id_,
               "at": doc.get("lead", {}).get("inicio") or ahora(), "source": "manual-import",
               "doc": doc, "roundBudget": {}, "importLegacy": True}
    encolar(comando)
    publicar_cola(id_)


def coincide(event, firma):
    if event.get("source") != "manual":
        return False
    for k, v in firma.items():
        actual = event.get(k)
        if isinstance(v, dict):
            if not isinstance(actual, dict) or any(actual.get(clave) != valor for clave, valor in v.items()):
                return False
        elif actual != v:
            return False
    return True


def publicar(id_, construir, firma):
    queued = pendientes(id_)
    matched = next((e for e in queued if coincide(e, firma)), None)
    if queued:
        if publicar_cola(id_, matched["id"] if matched else None):
            if matched:
                print(resumen(leer(id_)))
                return
        elif matched and firma["kind"] == "part.status":
            leer(id_)
            morir("el tablero cambio mientras se publicaba el paso; revisa el estado actual antes de repetirlo")
    for _ in range(3):
        doc = abierto(id_)
        t = ahora()
        comando = {"kind": None, "id": uuid.uuid4().hex, "corrida": id_, "at": t,
                   "expectedRevision": REVISION[id_], "source": "manual"}
        comando.update(construir(doc, t))
        encolar(comando)
        if publicar_cola(id_, comando["id"]):
            nuevo = leer(id_)
            if nuevo is None:
                morir("el gateway acepto el evento pero no devuelve el trabajo")
            print(resumen(nuevo))
            return
        if firma["kind"] == "part.status":
            leer(id_)
            morir("el tablero cambio mientras se publicaba el paso; revisa el estado actual antes de repetirlo")
    morir("el tablero cambio durante la operacion; vuelve a intentarlo")


def abierto(id_):
    doc = leer(id_)
    if doc is None:
        morir(f"no hay trabajo {id_} en el tablero; abrelo con: tablero-trabajo.sh abrir {id_} ...")
    if doc.get("cierre", {}).get("at"):
        morir(f"el trabajo {id_} ya esta cerrado ({doc['cierre']['at']})")
    return doc


def evento(doc, t, que, carril=None):
    doc["eventos"].append({"at": t, "carril": carril, "que": que, "situacion": None})
    doc["lead"]["actualizado"] = t


def carril_nuevo(n, nombre, repo):
    return {"id": f"p{n}", "nombre": texto(nombre, 300, "parte"), "repo": repo, "rama": None, "tareas": [],
            "estado": "pendiente", "paso_loop": 0, "pr": None, "head": None, "approve_lead": None,
            "ci": "pendiente", "coderabbit": "pendiente", "residuales": [], "detenido_por": None,
            "ultimo_evento": None}


def resumen(doc):
    hechas = sum(1 for c in doc["carriles"] if c["estado"] == "mergeado")
    lineas = [f"{doc['corrida']}: {doc['titulo']} ({hechas} de {len(doc['carriles'])} partes terminadas)"]
    lineas += [f"  {c['id']} [{c['estado']}] {c['nombre']}" for c in doc["carriles"]]
    lineas.append(f"  sigue: {doc['siguiente_paso']}")
    if doc["atencion_requerida"]["necesaria"]:
        lineas.append(f"  necesita a David: {doc['atencion_requerida']['motivo']}")
    if doc["cierre"]["at"]:
        lineas.append(f"  cerrado {doc['cierre']['at']}: {doc['cierre']['resumen']}")
    return "\n".join(lineas)


def opciones(args, conocidas):
    pos, ops = [], {}
    i = 0
    while i < len(args):
        a = args[i]
        if a in conocidas:
            if i + 1 >= len(args):
                morir(f"{a} sin valor", 2)
            ops[a] = args[i + 1]
            i += 2
        elif a.startswith("--") and a != "--resuelta":
            morir(f"opcion desconocida {a}", 2)
        else:
            pos.append(a)
            i += 1
    return pos, ops


def sin_marcador(s, campo):
    m = MARCADOR_RE.search(s)
    if m:
        morir(f"{campo} no puede traer {m.group(0)!r}: los avisos a David lo leen como parte del mensaje", 2)


def validar_id(id_):
    if not CORRIDA_RE.match(id_ or ""):
        morir(f"id invalido {id_!r}: minusculas, numeros y guiones, hasta 41 (ej. migrar-correo)", 2)


def cmd_abrir(args):
    pos, ops = opciones(args, {"--siguiente", "--repo"})
    if len(pos) < 3:
        morir('abrir <id> "<titulo>" "<parte1>" ["<parte2>" ...] [--siguiente "..."] [--repo owner/repo]', 2)
    id_, titulo, partes = pos[0], pos[1], pos[2:]
    validar_id(id_)
    sin_marcador(titulo, "el titulo")
    titulo = texto(titulo, 300, "titulo")
    partes = [texto(p, 300, "parte") for p in partes]
    repo = ops.get("--repo", REPO_DEF)
    if not REPO_RE.match(repo):
        morir(f"--repo invalido {repo!r}: owner/repo", 2)
    queued = pendientes(id_)
    if queued:
        same = any(e.get("kind") == "run.opened" and e.get("source") == "manual"
                   and e.get("doc", {}).get("titulo") == titulo
                   and [c.get("nombre") for c in e.get("doc", {}).get("carriles", [])] == partes
                   and all(c.get("repo") == repo for c in e.get("doc", {}).get("carriles", [])) for e in queued)
        if not same:
            morir(f"hay otra apertura pendiente para {id_}; publicala antes de cambiar sus datos")
        publicar_cola(id_)
    previo = leer(id_)
    if previo is not None:
        if previo.get("cierre", {}).get("at"):
            morir(f"el id {id_} ya se uso y esta cerrado; abre el trabajo nuevo con otro id")
        print("ya estaba abierto; no se toca:")
        print(resumen(previo))
        return
    t = ahora()
    carriles = [carril_nuevo(n, p, repo) for n, p in enumerate(partes, 1)]
    carriles[0]["estado"] = "implementando"
    carriles[0]["ultimo_evento"] = {"at": t, "que": "arranca"}
    doc = {
        "schema": "runbook-progress.v1",
        "runbook": "encargo directo de David a claw (sin runbook)",
        "fase": FASE,
        "corrida": id_,
        "plan": None,
        "titulo": texto(titulo, 300, "titulo"),
        "lead": {"agente": "claw", "inicio": t, "actualizado": t},
        "atencion_requerida": {"necesaria": False, "motivo": None, "desde": None},
        "siguiente_paso": texto(ops.get("--siguiente") or carriles[0]["nombre"], 160, "siguiente"),
        "carriles": carriles,
        "cola": [],
        "eventos": [],
        "cierre": {"at": None, "telegram_message_id": None, "resumen": None},
    }
    evento(doc, t, texto(f"abierto: {titulo}", 300, "titulo"))
    comando = {"kind": "run.opened", "id": uuid.uuid4().hex, "corrida": id_, "at": t,
               "source": "manual", "doc": doc, "roundBudget": {}}
    encolar(comando)
    publicar_cola(id_)
    print(resumen(leer(id_)))


def buscar_carril(doc, ref):
    cs = doc["carriles"]
    if ref.isdigit() and 1 <= int(ref) <= len(cs):
        return cs[int(ref) - 1]
    for c in cs:
        if c["id"] == ref:
            return c
    morir(f"no hay parte {ref!r}; partes: " + ", ".join(f"{i} ({c['id']}) {c['nombre']}" for i, c in enumerate(cs, 1)), 2)


def cmd_agregar(args):
    pos, _ = opciones(args, set())
    if len(pos) != 2:
        morir('agregar <id> "<parte>"', 2)
    nombre = texto(pos[1], 300, "parte")
    def construir(doc, _):
        repo = doc["carriles"][-1]["repo"] if doc["carriles"] else REPO_DEF
        c = carril_nuevo(len(doc["carriles"]) + 1, nombre, repo)
        return {"kind": "part.added", "carril": c}
    publicar(pos[0], construir, {"kind": "part.added", "carril": {"nombre": nombre}})


def cmd_paso(args):
    pos, ops = opciones(args, {"--siguiente", "--pr"})
    if len(pos) != 4:
        morir('paso <id> <parte> <estado> "<que paso>" [--siguiente "..."] [--pr N]', 2)
    id_, ref, estado, que = pos
    if estado not in ESTADOS:
        morir(f"estado {estado!r} fuera de la lista: {', '.join(ESTADOS)}", 2)
    que = texto(que, 300, "que paso")
    pr = None
    if "--pr" in ops:
        if not ops["--pr"].isdigit() or int(ops["--pr"]) < 1:
            morir(f"--pr invalido {ops['--pr']!r}", 2)
        pr = int(ops["--pr"])
    siguiente = None
    if "--siguiente" in ops:
        siguiente = texto(ops["--siguiente"], 160, "siguiente")
    def construir(doc, _):
        c = buscar_carril(doc, ref)
        result = {"kind": "part.status", "carril": c["id"], "estado": estado, "que": que}
        if pr is not None:
            result["pr"] = pr
        if siguiente is not None:
            result["nextStep"] = siguiente
        return result
    carril_id = f"p{int(ref)}" if ref.isdigit() else ref
    firma = {"kind": "part.status", "carril": carril_id, "estado": estado, "que": que}
    if pr is not None:
        firma["pr"] = pr
    if siguiente is not None:
        firma["nextStep"] = siguiente
    publicar(id_, construir, firma)


def cmd_atencion(args):
    pos, _ = opciones(args, set())
    if len(pos) != 2:
        morir('atencion <id> "<que necesito de David>"  |  atencion <id> --resuelta', 2)
    if pos[1] == "--resuelta":
        payload = {"kind": "attention.changed", "necesaria": False, "motivo": None}
    else:
        motivo = texto(pos[1], 300, "motivo")
        sin_marcador(motivo, "el motivo")
        payload = {"kind": "attention.changed", "necesaria": True, "motivo": motivo}
    publicar(pos[0], lambda _doc, _t: payload, payload)


def cmd_cerrar(args):
    pos, _ = opciones(args, set())
    if len(pos) != 2:
        morir('cerrar <id> "<resumen de una linea>"', 2)
    if pendientes(pos[0]):
        publicar_cola(pos[0])
    doc = leer(pos[0])
    if doc is None:
        morir(f"no hay trabajo {pos[0]} en el tablero")
    if doc["cierre"]["at"]:
        print("ya estaba cerrado; no se toca:")
        print(resumen(doc))
        return
    r = texto(pos[1], 300, "resumen")
    payload = {"kind": "run.closed", "resumen": r}
    publicar(pos[0], lambda _doc, _t: payload, payload)


def cmd_ver(args):
    if len(args) != 1:
        morir("ver <id>", 2)
    doc = leer(args[0])
    if doc is None:
        morir(f"no hay trabajo {args[0]} en el tablero")
    print(resumen(doc))


CMDS = {"abrir": cmd_abrir, "agregar": cmd_agregar, "paso": cmd_paso, "atencion": cmd_atencion,
        "cerrar": cmd_cerrar, "ver": cmd_ver}
argv = sys.argv[1:]
if not argv or argv[0] not in CMDS:
    morir(USO, 2)
if argv[0] != "abrir" and len(argv) > 1:
    validar_id(argv[1])
CMDS[argv[0]](argv[1:])
PY
