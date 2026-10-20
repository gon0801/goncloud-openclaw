#!/usr/bin/env python3
"""El merge del head exacto (SUA-05, 4.4 y 4.5): cinco compuertas contra un solo SHA.

`listo` congela una vista del PR (pr view, check-runs y status del SHA, hilos
GraphQL, comentarios en línea REST y permisos de quienes adjudican) y decide con
cinco compuertas puras que se evalúan todas: `faltan` es el diagnóstico completo.
`mergear` corre la misma evaluación y solo con `listo` true ordena
`gh pr merge --squash --match-head-commit` y relee que quedó MERGED; `reintentar`
re-corre una sola vez el job de infraestructura cuya firma está en la receta.
Tras el merge borra la rama del PR (no bases de la receta, `main`, `master`,
`feat/hermes-team`, `feat/jev-hermes` ni forks, solo si la punta no se movió).

Por qué AUTORES_BOT trae dos grafías: los marcadores del bot son texto que
cualquiera puede escribir, así que la compuerta exige el autor. `gh pr view`
(GraphQL) reporta la app como "github-actions" y REST como "github-actions[bot]";
la fuente elegida es `gh pr view` (una sola llamada trae draft, head, estado y
comentarios) y las dos grafías son logins reservados que nadie más puede tener.

Por qué el tope del reintento es run_attempt y no un ledger local: GitHub ya
mantiene ese estado en el run; anotarlo en un archivo sería una copia que miente
si la máquina cambia.

Desde 2026-10-20 CodeRabbit no es obligatorio (decisión de David): la compuerta
solo corre si la receta lo lista; si comenta, sus hilos Major/Critical se adjudican igual.

Por qué la revisión incompleta del bot ya no frena (David, orden
G-sin-candados 2026-10-19): el gate solo niega un hallazgo BLOQUEANTE sin
adjudicar — High/Critical, o uno marcado de seguridad, datos, credenciales o
pérdida de datos por su título — y el CI rojo. Un Medium/Low abierto sin
adjudicar y la "revision-parcial" del bot (sin completion, parcial, o sin bloque
legible) son avisos que no frenan: un candado solo se queda si protege dinero,
datos, credenciales o una decisión explícita de David, y una revisión parcial no
lo es.

Solo biblioteca estándar; standalone como avisar.py y reporte.py.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

# --- constantes-tabla: lo que otro repo decide distinto es dato, no rama -----

REPO_POR_DEFECTO = "gon0801/goncloud-openclaw"
RECETA_POR_DEFECTO = (
    Path(__file__).resolve().parents[2] / "docs/evidence/agent-work/recetas-repos.json"
)
SCHEMA_RECETA = "agent-work.recetas.v1"
CAMPOS_PR = "number,isDraft,headRefOid,state,comments"
CONSULTA_THREADS = (
    "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name)"
    "{pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage}nodes{isResolved"
    " comments(first:100){nodes{author{login}body}}}}}}}"
)
AUTORES_BOT = frozenset({"github-actions", "github-actions[bot]"})
CONTEXTO_CODERABBIT = "CodeRabbit"
TEXTO_RATE_LIMITED = "Review rate limited"
AUTOR_CR = "coderabbitai"
MARCA_STICKY = "<!-- ai-review:sticky -->"
SEVERIDADES_BOT_QUE_FRENAN = frozenset({"Critical", "High"})
"""Lo BLOQUEANTE del bot sin adjudicar (David, orden G-sin-candados 2026-10-19). Medium/Low pasan
a avisos: ver compuerta_hallazgos."""
SEVERIDADES_BOT_MENORES = frozenset({"Medium", "Low"})
MARCA_BLOQUEANTE = re.compile(
    r"seguridad|security|credencial|credential|contrase[ñn]a|password|secreto|secret|"
    r"token|api[ -]?key|inyecci[óo]n|datos personales|datos sensibles|pii|"
    r"p[ée]rdida de datos|se pierden|data loss|corrupt|corrupci[óo]n|overwrite",
    re.IGNORECASE,
)
"""Lo que vuelve BLOQUEANTE a un hallazgo de severidad menor: marcado de seguridad, datos o
credenciales en su título (G-sin-candados), y también la pérdida, corrupción o pisado de datos,
en español y en inglés (r2, cr:4311182158 — un Medium «Pérdida de datos al guardar sesiones» no
podía quedar en aviso). El título es lo único que el hallazgos.v1 del bot trae para marcarlo; la
tabla vive aquí arriba con el resto de los datos, que otro repo decide distinto."""
SEVERIDADES_CR_QUE_FRENAN = frozenset({"Major", "Critical"})
SEVERIDADES_CR_MENORES = frozenset({"Minor", "Low"})
MARCAS_CR = (("🔴 Critical", "Critical"), ("🟠 Major", "Major"), ("🟡 Minor", "Minor"))
CONCLUSIONES_MALAS = frozenset({"failure", "cancelled", "timed_out"})
PERMISOS_DE_ESCRITURA = frozenset({"admin", "write", "maintain"})
RE_COMPLETION = re.compile(r"<!-- ai-review:completion=([0-9a-f]{40}):(complete|partial) -->")
RE_FINDINGS = re.compile(r"<!-- ai-review:findings=(\{.*?\}) -->", re.DOTALL)
RE_ADJUDICACION = re.compile(
    r"^adjudicado (?P<ref>F\d+|cr:hilo-\d+|cr:\d+) @(?P<head>[0-9a-f]{7,40}): "
    r"(?P<veredicto>no-bloqueante|no-aplica) — .+$",
    re.MULTILINE,
)
RE_SHA = re.compile(r"[0-9a-f]{7,40}")
RAMAS_PROTEGIDAS = frozenset({"main", "master", "feat/hermes-team", "feat/jev-hermes"})
"""Ramas que nunca se borran tras un merge: feat/jev-hermes la usan las cadenas de Hermes."""


def canonico(documento) -> str:
    return json.dumps(documento, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


class Falla(Exception):
    pass


# --- dominio -----------------------------------------------------------------


@dataclass(frozen=True)
class Receta:
    repo: str
    base: str
    metodo: str
    checks: tuple[str, ...]
    bots: tuple[str, ...]
    nace_draft: bool
    traer_base: str
    firmas_infra: tuple[str, ...]


@dataclass(frozen=True)
class Corrida:
    nombre: str
    conclusion: str | None
    inicio: str


@dataclass(frozen=True)
class Comentario:
    autor: str
    cuerpo: str


@dataclass(frozen=True)
class HallazgoBot:
    fid: str
    severidad: str
    estado: str
    titulo: str = ""
    """El título del hallazgo: lo que MARCA_BLOQUEANTE mira para seguridad, datos o credenciales."""


@dataclass(frozen=True)
class MarcaBot:
    sha: str | None
    estado: str | None
    hallazgos: tuple[HallazgoBot, ...]
    bloque_valido: bool


@dataclass(frozen=True)
class HiloCR:
    resuelto: bool
    autor: str
    cuerpo: str
    severidad: str | None
    ref: str


@dataclass(frozen=True)
class Adjudicacion:
    ref: str
    autor: str
    permiso: str
    veredicto: str


@dataclass(frozen=True)
class VistaPR:
    numero: int
    repo: str
    head: str
    es_draft: bool
    head_real: str
    estado: str
    corridas: dict[str, Corrida]
    cr_status: str | None
    cr_descripcion: str
    marca_bot: MarcaBot | None
    hilos_cr: tuple[HiloCR, ...]
    adjudicaciones: tuple[Adjudicacion, ...]


# --- parsers puros ------------------------------------------------------------


def deduplicar_corridas(check_runs) -> dict[str, Corrida]:
    """La última corrida por nombre: gana started_at máximo (ISO Zulu, que
    compara lexicográfico). Un job re-ejecutado deja la fallida vieja en el
    mismo SHA; la que manda es la nueva."""
    ultimas: dict[str, Corrida] = {}
    for run in check_runs:
        nombre = run.get("name") or ""
        inicio = run.get("started_at") or ""
        conclusion = (run.get("conclusion") or "").lower() or None
        actual = ultimas.get(nombre)
        if actual is None or inicio >= actual.inicio:
            ultimas[nombre] = Corrida(nombre, conclusion, inicio)
    return ultimas


def parsear_bot(cuerpo: str) -> MarcaBot:
    completion = RE_COMPLETION.search(cuerpo)
    sha, estado = (completion.group(1), completion.group(2)) if completion else (None, None)
    hallazgos: list[HallazgoBot] = []
    bloque_valido = False
    bloque = RE_FINDINGS.search(cuerpo)
    if bloque:
        try:
            datos = json.loads(bloque.group(1))
        except ValueError:
            datos = None
        if (
            isinstance(datos, dict)
            and datos.get("schema") == 3
            and isinstance(datos.get("findings"), list)
        ):
            parsed = []
            completo = True
            for hallazgo in datos["findings"]:
                try:
                    parsed.append(
                        HallazgoBot(
                            str(hallazgo["id"]),
                            str(hallazgo["severity"]),
                            str(hallazgo["status"]["kind"]),
                            str(hallazgo.get("title") or ""),
                        )
                    )
                except (KeyError, TypeError):
                    completo = False
                    break
            if completo:
                hallazgos = parsed
                bloque_valido = True
    return MarcaBot(sha, estado, tuple(hallazgos), bloque_valido)


def severidad_cr(cuerpo: str) -> str | None:
    for marca, nombre in MARCAS_CR:
        if marca in cuerpo:
            return nombre
    return None


def correlacionar(nodos, inline) -> tuple[HiloCR, ...]:
    """Hilos de revisión con su gemelo REST: la correlación es por cuerpo
    literal (GraphQL no trae el id del comentario en línea)."""
    por_cuerpo = {c.get("body"): c.get("id") for c in inline if isinstance(c, dict)}
    hilos = []
    for indice, nodo in enumerate(nodos):
        comentarios = ((nodo.get("comments") or {}).get("nodes")) or []
        primero = comentarios[0] if comentarios else {}
        autor = ((primero.get("author") or {}).get("login")) or ""
        cuerpo = primero.get("body") or ""
        cid = por_cuerpo.get(cuerpo)
        ref = f"cr:{cid}" if cid is not None else f"cr:hilo-{indice}"
        hilos.append(HiloCR(bool(nodo.get("isResolved")), autor, cuerpo, severidad_cr(cuerpo), ref))
    return tuple(hilos)


def adjudicaciones_crudas(comentarios, head: str):
    """Las líneas de adjudicación que nombran este head: (ref, autor, veredicto).
    Una adjudicación de un push anterior (head que no es prefijo del pedido) no vale."""
    crudas = []
    for comentario in comentarios:
        for marca in RE_ADJUDICACION.finditer(comentario.cuerpo):
            if head.startswith(marca.group("head")):
                crudas.append((marca.group("ref"), comentario.autor, marca.group("veredicto")))
    return crudas


def _sin_repetidos(secuencia):
    vistos = set()
    salida = []
    for elemento in secuencia:
        if elemento not in vistos:
            vistos.add(elemento)
            salida.append(elemento)
    return salida


# --- compuertas puras: (vista, receta, head) -> (faltan, avisos) ---------------


def compuerta_draft_head(vista, receta, head):
    faltan = []
    if vista.es_draft:
        faltan.append("es-draft")
    if vista.head_real != head:
        faltan.append("head-movido")
    return faltan, []


def compuerta_ci(vista, receta, head):
    faltan = []
    for nombre in receta.checks:
        corrida = vista.corridas.get(nombre)
        if corrida is None:
            faltan.append(f"ci-falta:{nombre}")
        elif corrida.conclusion is None:
            faltan.append(f"ci-pendiente:{nombre}")
        elif corrida.conclusion != "success":
            # Un requerido skipped tampoco autoriza: solo success deja pasar.
            faltan.append(f"ci-rojo:{nombre}")
    # Barrido: cualquier check del SHA con su última corrida roja, requerido o no.
    # Los shards no se piden por nombre; gate verde cubre ambos carriles.
    for nombre, corrida in vista.corridas.items():
        if corrida.conclusion in CONCLUSIONES_MALAS:
            faltan.append(f"ci-rojo:{nombre}")
    return faltan, []


def compuerta_coderabbit(vista, receta, head):
    if "coderabbit" not in receta.bots:
        return [], []
    if vista.cr_status is None:
        return ["coderabbit-ausente"], []
    if vista.cr_status != "success":
        return [f"coderabbit-rojo:{vista.cr_status}"], []
    if TEXTO_RATE_LIMITED in vista.cr_descripcion:
        return [], ["coderabbit-rate-limited"]
    return [], []


def compuerta_bot(vista, receta, head):
    """La revisión incompleta del bot avisa y no frena (David, orden G-sin-candados 2026-10-19):
    una marca sin completion, parcial o sin bloque legible deja el PR pasar con su aviso. Lo que
    sigue frenando aquí: que el bot no haya dicho nada (bot-ausente) y que la única evidencia sea
    de otro head — sin revisión de este head no hay hallazgos honestos que mirar."""
    if "ai-review" not in receta.bots:
        return [], []
    marca = vista.marca_bot
    if marca is None:
        return ["bot-ausente"], []
    if marca.sha is None:
        return [], ["revision-parcial"]
    if not head.startswith(marca.sha):
        return ["evidencia-de-otro-head"], []
    if marca.estado != "complete" or not marca.bloque_valido:
        return [], ["revision-parcial"]
    return [], []


def pendientes(vista):
    """Lo que frena: F<n> del bot open BLOQUEANTE (High/Critical, o marcado de seguridad, datos o
    credenciales por su título) y cr:<id> de hilos Major/Critical sin resolver (los menores van a
    avisos, no aquí)."""
    refs = []
    marca = vista.marca_bot
    if marca is not None and marca.bloque_valido:
        refs += [
            h.fid
            for h in marca.hallazgos
            if h.estado == "open"
            and (h.severidad in SEVERIDADES_BOT_QUE_FRENAN or MARCA_BLOQUEANTE.search(h.titulo))
        ]
    refs += [
        h.ref
        for h in vista.hilos_cr
        if h.autor.startswith(AUTOR_CR)
        and not h.resuelto
        and h.severidad in SEVERIDADES_CR_QUE_FRENAN
    ]
    return refs


def compuerta_hallazgos(vista, receta, head):
    validas = {a.ref for a in vista.adjudicaciones if a.permiso in PERMISOS_DE_ESCRITURA}
    frenan = pendientes(vista)
    faltan = [f"hallazgo-sin-adjudicar:{ref}" for ref in frenan if ref not in validas]
    avisos = [
        f"adjudicacion-sin-permiso:{a.autor}"
        for a in vista.adjudicaciones
        if a.permiso not in PERMISOS_DE_ESCRITURA
    ]
    avisos += [
        f"hilo-menor-sin-resolver:{h.ref}"
        for h in vista.hilos_cr
        if h.autor.startswith(AUTOR_CR) and not h.resuelto and h.severidad in SEVERIDADES_CR_MENORES
    ]
    # Medium/Low del bot sin adjudicar avisan y no frenan (David, orden G-sin-candados 2026-10-19).
    marca = vista.marca_bot
    if marca is not None and marca.bloque_valido:
        avisos += [
            f"hallazgo-menor-sin-adjudicar:{h.fid}"
            for h in marca.hallazgos
            if h.estado == "open"
            and h.severidad in SEVERIDADES_BOT_MENORES
            and h.fid not in validas
            and h.fid not in frenan
        ]
    return faltan, avisos


COMPUERTAS = (
    ("draft-head", compuerta_draft_head),
    ("ci", compuerta_ci),
    ("coderabbit", compuerta_coderabbit),
    ("bot", compuerta_bot),
    ("hallazgos", compuerta_hallazgos),
)


def evaluar(vista, receta) -> dict:
    """{"listo": bool, "faltan": [...], "avisos": [...]}: la unión de todas las
    compuertas, que se evalúan siempre (sin cortocircuito) para que faltan sea
    el diagnóstico completo de una sola pasada."""
    faltan: list[str] = []
    avisos: list[str] = []
    for _, compuerta in COMPUERTAS:
        f, a = compuerta(vista, receta, vista.head)
        faltan.extend(f)
        avisos.extend(a)
    faltan = _sin_repetidos(faltan)
    avisos = _sin_repetidos(avisos)
    return {"listo": not faltan, "faltan": faltan, "avisos": avisos}


def faltan_por_rollup(rollup, checks_requeridos):
    """La vía barata de M-25: el mismo vocabulario de la compuerta CI pero
    contra statusCheckRollup (que ya trae la última corrida por nombre y las
    conclusiones en MAYÚSCULAS, normalizadas aquí). evaluar NO usa esta vía:
    lee los check-runs REST completos del SHA; esta función es el mínimo si
    algo solo puede pagarse una llamada `gh pr view`."""
    ultimas = {}
    for entrada in rollup or ():
        if entrada.get("__typename") != "CheckRun":
            continue
        nombre = entrada.get("name")
        if nombre:
            ultimas[nombre] = (entrada.get("conclusion") or "").lower() or None
    faltan = []
    for nombre in checks_requeridos:
        conclusion = ultimas.get(nombre)
        if nombre not in ultimas:
            faltan.append(f"ci-falta:{nombre}")
        elif conclusion is None:
            faltan.append(f"ci-pendiente:{nombre}")
        elif conclusion != "success":
            faltan.append(f"ci-rojo:{nombre}")
    for nombre, conclusion in ultimas.items():
        if conclusion in CONCLUSIONES_MALAS:
            faltan.append(f"ci-rojo:{nombre}")
    return _sin_repetidos(faltan)


# --- la receta: validación en el borde ------------------------------------------


def cargar_receta(ruta, repo: str) -> Receta:
    try:
        datos = json.loads(Path(ruta).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Falla(f"receta ilegible ({ruta}): {error}") from error
    if (
        not isinstance(datos, dict)
        or datos.get("schema") != SCHEMA_RECETA
        or not isinstance(datos.get("repos"), dict)
    ):
        raise Falla(f"receta inválida ({ruta}): no es {SCHEMA_RECETA}")
    entrada = datos["repos"].get(repo)
    if not isinstance(entrada, dict):
        raise Falla(f"repo-sin-receta: {repo} no tiene entrada en {ruta}")
    for campo in ("base", "metodo", "traerBase"):
        if not isinstance(entrada.get(campo), str):
            raise Falla(f"receta inválida: {repo}.{campo} no es texto")
    if type(entrada.get("naceDraft")) is not bool:
        raise Falla(f"receta inválida: {repo}.naceDraft no es booleano")
    for campo in ("checks", "bots", "firmasInfra"):
        valor = entrada.get(campo)
        if not isinstance(valor, list) or not all(isinstance(x, str) for x in valor):
            raise Falla(f"receta inválida: {repo}.{campo} no es una lista de textos")
    return Receta(
        repo=repo,
        base=entrada["base"],
        metodo=entrada["metodo"],
        checks=tuple(entrada["checks"]),
        bots=tuple(entrada["bots"]),
        nace_draft=entrada["naceDraft"],
        traer_base=entrada["traerBase"],
        firmas_infra=tuple(entrada["firmasInfra"]),
    )


# --- transporte: el único punto de subprocess ------------------------------------


def llamar(gh_bin, args) -> str:
    try:
        hecho = subprocess.run(
            [str(gh_bin), *(str(a) for a in args)],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Falla(f"gh no corrió: {error}") from error
    if hecho.returncode != 0:
        raise Falla(f"gh salió {hecho.returncode}: {hecho.stderr.strip()[:200]}")
    return hecho.stdout


def json_de(texto: str, contexto: str):
    try:
        return json.loads(texto)
    except ValueError as error:
        raise Falla(f"{contexto}: json inmundo: {str(error)}; {texto[:200]}") from error


def pagina(gh_bin, url: str, clave: str) -> list:
    """Página tras página mientras vengan llenas (100), hasta total_count si lo trae."""
    filas = []
    numero = 1
    while True:
        datos = json_de(llamar(gh_bin, ["api", f"{url}?per_page=100&page={numero}"]), url)
        if not isinstance(datos, dict):
            raise Falla(f"{url}: se esperaba un objeto con {clave}")
        chunk = datos.get(clave) or []
        if not isinstance(chunk, list):
            raise Falla(f"{url}: {clave} no es una lista")
        filas.extend(chunk)
        total = datos.get("total_count")
        if len(chunk) < 100 or (isinstance(total, int) and len(filas) >= total):
            return filas
        numero += 1


def pagina_plana(gh_bin, url: str) -> list:
    """Paginación de los endpoints que devuelven una lista pelada."""
    filas = []
    numero = 1
    while True:
        datos = json_de(llamar(gh_bin, ["api", f"{url}?per_page=100&page={numero}"]), url)
        if not isinstance(datos, list):
            raise Falla(f"{url}: se esperaba una lista")
        filas.extend(datos)
        if len(datos) < 100:
            return filas
        numero += 1


def permiso_de(gh_bin, repo: str, login: str) -> str:
    datos = json_de(
        llamar(gh_bin, ["api", f"repos/{repo}/collaborators/{login}/permission"]),
        f"permission de {login}",
    )
    if not isinstance(datos, dict):
        return ""
    return datos.get("permission") or ""


def recolectar(gh_bin, repo: str, numero: int, head: str) -> VistaPR:
    """Toda la I/O en una sola pasada; las compuertas no ven el cable."""
    owner, _, name = repo.partition("/")
    pr = json_de(
        llamar(
            gh_bin,
            ["pr", "view", str(numero), "--repo", repo, "--json", CAMPOS_PR],
        ),
        f"pr view {numero}",
    )
    campos = {"number", "isDraft", "headRefOid", "state", "comments"}
    if not isinstance(pr, dict) or not campos <= set(pr):
        raise Falla(f"pr view {numero} sin la forma esperada")
    comentarios = tuple(
        Comentario((c.get("author") or {}).get("login") or "", c.get("body") or "")
        for c in pr["comments"]
    )
    corridas = deduplicar_corridas(
        pagina(gh_bin, f"repos/{repo}/commits/{head}/check-runs", "check_runs")
    )
    status = json_de(
        llamar(gh_bin, ["api", f"repos/{repo}/commits/{head}/status"]), f"status de {head}"
    )
    cr_status, cr_descripcion = None, ""
    for entrada in (status.get("statuses") or []) if isinstance(status, dict) else []:
        if entrada.get("context") == CONTEXTO_CODERABBIT:
            cr_status = entrada.get("state")
            cr_descripcion = entrada.get("description") or ""
    threads = json_de(
        llamar(
            gh_bin,
            [
                "api",
                "graphql",
                "-f",
                f"query={CONSULTA_THREADS}",
                "-f",
                f"owner={owner}",
                "-f",
                f"name={name}",
                "-F",
                f"number={numero}",
            ],
        ),
        "reviewThreads",
    )
    try:
        hilos = threads["data"]["repository"]["pullRequest"]["reviewThreads"]
        nodos = hilos["nodes"]
        mas = bool((hilos.get("pageInfo") or {}).get("hasNextPage"))
    except (KeyError, TypeError, AttributeError) as error:
        raise Falla("reviewThreads sin la forma esperada") from error
    if mas:
        # Falla cerrada (DeepSeek F7 y CodeRabbit en #330): un hilo sin resolver después del
        # 100 no puede quedar sin mirar. Con más de 100 hilos, el merge se decide a mano.
        raise Falla("el PR tiene más de 100 hilos de revisión: listo no los mira todos")
    inline = pagina_plana(gh_bin, f"repos/{repo}/pulls/{numero}/comments")
    sticky = [c for c in comentarios if MARCA_STICKY in c.cuerpo and c.autor in AUTORES_BOT]
    marca = parsear_bot(sticky[-1].cuerpo) if sticky else None
    crudas = adjudicaciones_crudas(comentarios, head)
    permisos: dict[str, str] = {}
    for _, autor, _ in crudas:
        if autor and autor not in permisos:
            permisos[autor] = permiso_de(gh_bin, repo, autor)
    return VistaPR(
        numero=pr["number"],
        repo=repo,
        head=head,
        es_draft=pr["isDraft"],
        head_real=pr["headRefOid"],
        estado=pr["state"],
        corridas=corridas,
        cr_status=cr_status,
        cr_descripcion=cr_descripcion,
        marca_bot=marca,
        hilos_cr=correlacionar(nodos, inline),
        adjudicaciones=tuple(
            Adjudicacion(ref, autor, permisos.get(autor, ""), veredicto)
            for ref, autor, veredicto in crudas
        ),
    )


# --- acciones delgadas -------------------------------------------------------------


def releer_merge(gh_bin, repo: str, numero: int):
    datos = json_de(
        llamar(gh_bin, ["pr", "view", str(numero), "--repo", repo, "--json", "state,mergeCommit"]),
        f"pr view {numero}",
    )
    if not isinstance(datos, dict):
        raise Falla(f"pr view {numero} sin la forma esperada")
    return datos.get("state"), (datos.get("mergeCommit") or {}).get("oid")


def cmd_listo(gh_bin, receta, numero: int, head: str) -> int:
    veredicto = evaluar(recolectar(gh_bin, receta.repo, numero, head), receta)
    print(canonico(veredicto))
    return 0 if veredicto["listo"] else 1


def borrar_rama_tras_merge(gh_bin, receta, numero: int, head: str):
    """Borra la rama del PR ya mergeado: (ramaBorrada, None) si la borró, o
    (None, "rama-no-borrada:<motivo>") si no. Un fallo de gh es aviso, nunca Falla:
    el merge ya quedó confirmado y no se convierte en fallo por no poder borrar."""
    try:
        datos = json_de(
            llamar(
                gh_bin,
                [
                    "pr",
                    "view",
                    str(numero),
                    "--repo",
                    receta.repo,
                    "--json",
                    "headRefName,isCrossRepository",
                ],
            ),
            f"pr view {numero}",
        )
        if (
            not isinstance(datos, dict)
            or not isinstance(datos.get("headRefName"), str)
            or not datos.get("headRefName")
            or not isinstance(datos.get("isCrossRepository"), bool)
        ):
            raise Falla(f"pr view {numero} sin headRefName/isCrossRepository")
        rama = datos["headRefName"]
        if datos["isCrossRepository"]:
            return None, "rama-no-borrada:fork"
        if rama == receta.base or rama in RAMAS_PROTEGIDAS:
            return None, "rama-no-borrada:protegida"
        rama_url = quote(rama, safe="/")
        ref = json_de(
            llamar(gh_bin, ["api", f"repos/{receta.repo}/git/ref/heads/{rama_url}"]),
            f"ref de {rama}",
        )
        objeto = ref.get("object") if isinstance(ref, dict) else None
        if not isinstance(objeto, dict):
            return None, "rama-no-borrada:punta-ilegible"
        if objeto.get("sha") != head:
            return None, "rama-no-borrada:punta-movida"
        llamar(gh_bin, ["api", "-X", "DELETE", f"repos/{receta.repo}/git/refs/heads/{rama_url}"])
        return rama, None
    except Falla as error:
        return None, f"rama-no-borrada:{error}"


def cmd_mergear(gh_bin, receta, numero: int, head: str) -> int:
    if receta.metodo != "squash":
        raise Falla(f"la receta de {receta.repo} no trae metodo squash: {receta.metodo}")
    vista = recolectar(gh_bin, receta.repo, numero, head)
    if vista.estado == "MERGED":
        if vista.head_real != head:
            # DeepSeek F1 en #330: un PR mergeado con otro head no certifica el pedido.
            print(canonico({"mergeado": False, "faltan": ["head-movido"]}))
            return 1
        estado, oid = releer_merge(gh_bin, receta.repo, numero)
        if estado != "MERGED":
            raise Falla(f"el PR {numero} dejó de estar MERGED en la relectura: {estado}")
        print(canonico({"mergeado": True, "ya-estaba": True, "mergeCommit": oid}))
        return 0
    veredicto = evaluar(vista, receta)
    if not veredicto["listo"]:
        print(
            canonico(
                {
                    "mergeado": False,
                    "faltan": veredicto["faltan"],
                    "avisos": veredicto["avisos"],
                }
            )
        )
        return 1
    # --match-head-commit es la guardia de carrera del servidor: si el head se
    # movió entre la evaluación y esta orden, gh sale distinto de cero.
    llamar(
        gh_bin,
        [
            "pr",
            "merge",
            str(numero),
            "--repo",
            receta.repo,
            "--squash",
            "--match-head-commit",
            head,
        ],
    )
    estado, oid = releer_merge(gh_bin, receta.repo, numero)
    if estado != "MERGED":
        raise Falla(f"merge sin confirmar: el PR {numero} quedó en {estado}")
    rama_borrada, aviso_borrado = borrar_rama_tras_merge(gh_bin, receta, numero, head)
    avisos = list(veredicto["avisos"])
    if aviso_borrado is not None:
        avisos.append(aviso_borrado)
    recibo = {
        "mergeado": True,
        "mergeCommit": oid,
        "adjudicaciones": [
            {
                "ref": a.ref,
                "autor": a.autor,
                "permiso": a.permiso,
                "veredicto": a.veredicto,
            }
            for a in vista.adjudicaciones
            if a.permiso in PERMISOS_DE_ESCRITURA
        ],
        "avisos": avisos,
    }
    if rama_borrada is not None:
        recibo["ramaBorrada"] = rama_borrada
    print(canonico(recibo))
    return 0


def _runs_fallidos_ultimos(runs) -> list:
    """Los runs fallidos con la última corrida por nombre (gana run_attempt)."""
    indices: dict[str, int] = {}
    elegidos = []
    for run in runs:
        if not isinstance(run, dict) or run.get("conclusion") != "failure":
            continue
        nombre = run.get("name") or ""
        if nombre in indices:
            posicion = indices[nombre]
            if (run.get("run_attempt") or 0) >= (elegidos[posicion].get("run_attempt") or 0):
                elegidos[posicion] = run
        else:
            indices[nombre] = len(elegidos)
            elegidos.append(run)
    return elegidos


def cmd_reintentar(gh_bin, receta, numero: int, head: str) -> int:
    datos = json_de(
        llamar(
            gh_bin,
            [
                "api",
                f"repos/{receta.repo}/actions/runs?head_sha={head}&status=failure&per_page=100",
            ],
        ),
        "actions/runs",
    )
    runs = datos.get("workflow_runs") or [] if isinstance(datos, dict) else []
    fallidos = _runs_fallidos_ultimos(runs)
    if not fallidos:
        print(canonico({"reintentado": False, "causa": "sin-falla-que-reintentar"}))
        return 1
    # Primero se buscan los runs con firma y después se re-corre el primero que
    # aún no quemó su reintento: un run agotado no tapa a otro que puede reintentarse.
    con_firma = []
    for run in fallidos:
        log = llamar(
            gh_bin, ["run", "view", str(run.get("id")), "--repo", receta.repo, "--log-failed"]
        )
        firma = next((f for f in receta.firmas_infra if f in log), None)
        if firma is not None:
            con_firma.append((run, firma))
    for run, firma in con_firma:
        if (run.get("run_attempt") or 1) < 2:
            llamar(gh_bin, ["run", "rerun", str(run.get("id")), "--repo", receta.repo, "--failed"])
            print(canonico({"reintentado": True, "run": run.get("id"), "firma": firma}))
            return 0
    if con_firma:
        agotado = con_firma[0][0].get("id")
        print(canonico({"reintentado": False, "causa": f"reintento-agotado:{agotado}"}))
        return 1
    print(canonico({"reintentado": False, "causa": f"fallo-real:{fallidos[0].get('id')}"}))
    return 1


# --- cli ----------------------------------------------------------------------------


def main(argv=None, gh_bin: str = "gh") -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcomandos = parser.add_subparsers(dest="comando", required=True)
    for nombre in ("listo", "mergear", "reintentar"):
        sub = subcomandos.add_parser(nombre)
        sub.add_argument("pr", type=int)
        sub.add_argument("--sha", required=True)
        sub.add_argument("--repo", default=REPO_POR_DEFECTO)
        sub.add_argument("--receta", type=Path, default=RECETA_POR_DEFECTO)
        sub.add_argument("--gh", default=None, help="binario gh; las pruebas inyectan el juguete")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        print(f"merge: --sha tiene que ser el sha completo de 40 hex: {args.sha}", file=sys.stderr)
        return 3
    gh = args.gh or gh_bin
    try:
        receta = cargar_receta(args.receta, args.repo)
        if args.comando == "listo":
            return cmd_listo(gh, receta, args.pr, args.sha)
        if args.comando == "mergear":
            return cmd_mergear(gh, receta, args.pr, args.sha)
        return cmd_reintentar(gh, receta, args.pr, args.sha)
    except (Falla, OSError) as error:
        print(f"merge: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
