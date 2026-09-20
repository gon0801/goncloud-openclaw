#!/bin/bash
# 13.1 (Fase 13): declarar qué texto sostiene un candado.
#
# Los tests de scripts/tests/ anclan frases concretas de agents/** y
# docs/agent-skills/** (un grep de presencia que pone el repo en rojo si la
# frase se pierde). Hasta ahora esa ancla era invisible: quien editaba la skill
# no sabía que había una frase que no podía tocar, y el prompt del Skill
# Workshop pide exactamente esta evidencia para conservar una regla ("keep
# decision-changing requirements and intentional policies unless evidence
# supports changing them"). La marca <!-- candado: <test> --> junto a la frase
# ES esa evidencia; no es una orden (el prompt del Workshop trata los archivos
# como material, no como instrucciones).
#
# Este test afirma la ida y la vuelta:
#  - IDA: toda frase anclada por un test tiene su marca a <=2 líneas de la
#    frase (la región se extiende al bloque cercado o al frontmatter que la
#    contiene, porque adentro no se puede insertar un comentario).
#  - VUELTA: toda marca apunta a un test que existe en scripts/tests/ y que de
#    verdad afirma esa frase en ese archivo (una copia byte-idéntica de la
#    skill cubre también: browser-cli-claw-profile va igual en tres agentes y
#    saikit-cierre-pr en dos, y esos tests exigen la igualdad).
#
# La lista de frases ancladas NO está escrita a mano acá: sale de recorrer los
# tests de scripts/tests/ y extraer sus aserciones de presencia (grep directo,
# helper tiene(), pipes de cat/head/git show, delimitadores awk de sección, y
# la allowlist dinámica de summa-gate/lib.ts que test-merge-allowlist recorre).
# Si un test nuevo ancla una frase, este candado la exige sin tocar este
# archivo; si deja de anclarse, la marca sobrante la vuelve a poner en rojo.
#
# Convención de escape: si el nombre del test no puede escribirse literal en el
# archivo (test-agent-dispatch-no-merge.sh exige que agent-dispatch/SKILL.md no
# contenga "merge", y su propio nombre lo trae), la marca lo nombra con una
# clase de un carácter: test-agent-dispatch-no-[m]erge.sh. La vuelta resuelve
# [c] -> c antes de buscar el archivo; es el idioma clásico de grep -v.
#
# Uso: bash scripts/tests/test-candados-declarados.sh
#      CANDADOS_INVENTARIO_JSON=<ruta> bash scripts/tests/test-candados-declarados.sh
#      (el modo inventario solo vuelca la lista derivada de los tests y sale 0)
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v python3 >/dev/null 2>&1 || { echo "FAIL: hace falta python3"; exit 1; }

# --- auto-prueba de regresión (r2) -------------------------------------------
# El reconocimiento de anclas con ruta literal vive en un regex: si se rompe,
# nada más lo atrapa (medido en r1: el repro se borró y quedó sin cobertura).
# Esta prueba levanta una caja de arena (mktemp, FUERA del repo: no queda
# ningún archivo temporal commiteable) con una skill sintética y un test
# sintético por estilo de ruta (pelada, ./, comillas simples, comillas
# dobles) y corre ESTE MISMO script contra ella con CANDADOS_RAIZ: sin
# marcas, tiene que ponerse rojo nombrando a cada estilo; con las marcas, en
# verde. Se salta cuando CANDADOS_RAIZ ya está (somos la caja de arena).
auto_prueba_regresion() {
  local T SK out estilo rc
  T=$(mktemp -d) || { echo "FAIL auto-prueba: mktemp"; return 1; }
  if ! mkdir -p "$T/scripts/tests" "$T/agents/sintetico/agent/workshop-skills/skill-s"; then
    rm -rf "$T"; echo "FAIL auto-prueba: mkdir"; return 1
  fi
  SK="$T/agents/sintetico/agent/workshop-skills/skill-s/SKILL.md"
  printf '%s\n' 'frase sintetica bare' 'frase sintetica dot' \
    'frase sintetica una' 'frase sintetica dos' > "$SK"
  printf '%s\n' '#!/usr/bin/env bash' \
    "grep -qF 'frase sintetica bare' agents/sintetico/agent/workshop-skills/skill-s/SKILL.md || exit 1" \
    > "$T/scripts/tests/test-sintetico-bare.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    "grep -qF 'frase sintetica dot' ./agents/sintetico/agent/workshop-skills/skill-s/SKILL.md || exit 1" \
    > "$T/scripts/tests/test-sintetico-dot.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    "grep -qF 'frase sintetica una' 'agents/sintetico/agent/workshop-skills/skill-s/SKILL.md' || exit 1" \
    > "$T/scripts/tests/test-sintetico-una.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'grep -qF "frase sintetica dos" "agents/sintetico/agent/workshop-skills/skill-s/SKILL.md" || exit 1' \
    > "$T/scripts/tests/test-sintetico-dos.sh"

  out=$(CANDADOS_RAIZ="$T" bash "$0" 2>&1)
  for estilo in bare dot una dos; do
    if ! printf '%s\n' "$out" | grep -qF "test-sintetico-$estilo.sh no marca 'frase sintetica $estilo'"; then
      rm -rf "$T"
      echo "FAIL auto-prueba: el parser no detecta el ancla con ruta literal estilo $estilo"
      printf '%s\n' "$out" | sed 's/^/  /'
      return 1
    fi
  done

  printf '%s\n' 'frase sintetica bare' '<!-- candado: test-sintetico-bare.sh -->' \
    'frase sintetica dot' '<!-- candado: test-sintetico-dot.sh -->' \
    'frase sintetica una' '<!-- candado: test-sintetico-una.sh -->' \
    'frase sintetica dos' '<!-- candado: test-sintetico-dos.sh -->' > "$SK"
  out=$(CANDADOS_RAIZ="$T" bash "$0" 2>&1); rc=$?
  rm -rf "$T"
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -q 'TODO VERDE'; then
    echo "FAIL auto-prueba: con las marcas puestas, la caja de arena no cierra en verde"
    printf '%s\n' "$out" | sed 's/^/  /'
    return 1
  fi
  echo "ok auto-prueba: los 4 estilos de ruta literal se detectan y exigen su marca"
}

if [ -z "${CANDADOS_RAIZ:-}" ]; then
  auto_prueba_regresion || exit 1
fi

python3 - <<'PY'
import filecmp
import json
import os
import re
import subprocess
import sys

TESTS_DIR = "scripts/tests"
# Raíz configurable: la auto-prueba de regresión corre este mismo script
# contra una caja de arena (CANDADOS_RAIZ) sin tocar el repo.
ROOT = os.environ.get("CANDADOS_RAIZ", os.getcwd())


def rp(path):
    return path if os.path.isabs(path) else os.path.join(ROOT, path)
SELF = "test-candados-declarados.sh"
WINDOW = 2  # líneas de la marca a la frase (región extendida)


def in_scope(p):
    return p.startswith("agents/") or p.startswith("docs/agent-skills/")


def unq(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        inner = v[1:-1]
        if v[0] == '"':
            # comillas dobles de shell: \$ -> $, \" -> ", \` -> `, \\ -> \
            inner = re.sub(r"\\([$\"`\\])", r"\1", inner)
        return inner
    return v


def read(path):
    with open(rp(path), encoding="utf-8", errors="replace") as f:
        return f.read()


# ---------------------------------------------------------------- inventario
# allowlist dinámica de test-merge-allowlist-cierre-pr.sh: la saca de
# summa-gate/lib.ts, igual que el test que la recorre.
allow = []
if os.path.isfile(rp("summa-gate/lib.ts")):
    m = re.search(
        r"MERGE_AGENT_ALLOWLIST\s*=\s*new Set\(\[([^\]]*)\]\)",
        read(rp("summa-gate/lib.ts")),
    )
    if m:
        allow = re.findall(r"""['"]([^'"]+)['"]""", m.group(1))


def parse_test(path):
    """Extrae (entradas, negativos) de un test. Entrada = el test afirma que
    esta frase existe en este destino; negativo = exige que NO exista."""
    name = os.path.basename(path)
    raw = read(path)
    joined = re.sub(r"\\\s*\n", " ", raw)  # une continuaciones de línea
    lines = [l for l in joined.split("\n")]

    pathvars, pathtpl, strvars, forloops = {}, {}, {}, {}
    contentvars = {}  # var -> conjunto de destinos (texto leído de esos paths)
    entries, negatives = [], []

    # funciones: NAME() { ... }  (se busca el cuerpo por balance de llaves)
    funcs = {}
    flines = raw.split("\n")
    i = 0
    while i < len(flines):
        m = re.match(r"\s*(\w+)\s*\(\)\s*\{", flines[i])
        if m:
            depth = flines[i].count("{") - flines[i].count("}")
            body = [flines[i][m.end():]]
            j = i + 1
            while j < len(flines) and depth > 0:
                depth += flines[j].count("{") - flines[j].count("}")
                body.append(flines[j])
                j += 1
            funcs[m.group(1)] = "\n".join(body)
            i = j
        else:
            i += 1

    def resolve_sources(src):
        """Destinos posibles de una variable usada como fuente de texto: por
        su nombre (pathvars/pathtpl) o por los valores que tomó en un for."""
        out = set()
        for v in forloops.get(src) or [src]:
            v = unq(v) if isinstance(v, str) else v
            if v in pathvars:
                out.add(pathvars[v])
            elif v in pathtpl:
                out.update(pathtpl[v])
            elif in_scope(v):
                out.add(v)
        return out

    # asignaciones simples y encabezados de for
    for line in lines:
        m = re.match(r"\s*(?:local\s+)?([A-Za-z_]\w*)=(.*)$", line)
        if m:
            var, val = m.group(1), m.group(2).strip()
            m_st = re.match(r'\$\(\s*skill_texto\s+"\$?(\w+)"?\s*\)', val)
            m_fn = re.match(r'\$\(\s*(\w+)\s+"\$(\w+)"\s*\)', val)
            m_cat = re.match(r'\$\(cat "?\$?(\w+)"?[^)]*\)', val)
            m_git = re.match(r'\$\(git show "\$\w+:(\$?\w+)"[^)]*\)', val)
            if m_st:
                # T=$(skill_texto "$D"): el texto de esa skill (carpeta)
                contentvars.setdefault(var, set()).update(
                    resolve_sources(m_st.group(1))
                )
            elif m_fn and m_fn.group(1) in funcs and 'cat "$1"' in funcs[m_fn.group(1)]:
                # s=$(seccion "$f"): una función cuyo cuerpo hace cat "$1"/*.md
                contentvars.setdefault(var, set()).update(
                    resolve_sources(m_fn.group(2))
                )
            elif m_cat:
                contentvars.setdefault(var, set()).update(
                    resolve_sources(m_cat.group(1))
                )
            elif m_git:
                contentvars.setdefault(var, set()).update(
                    resolve_sources(m_git.group(1).lstrip("$"))
                )
            else:
                u = unq(val)
                if re.fullmatch(r"'[^']*'", val):
                    # comillas simples: todo literal, aunque traiga $PATH
                    strvars[var] = u
                elif re.fullmatch(r'"[^"$]*"', val) and "$" not in u:
                    strvars[var] = u
                elif "$" not in u and in_scope(u):
                    pathvars[var] = u
                elif "${agent}" in u and allow:
                    # skill="agents/${agent}/..." (allowlist de summa-gate)
                    pathtpl[var] = [u.replace("${agent}", a) for a in allow]
                elif "$" in u and "${agent}" not in u:
                    # REF=agents/.../$SK/SKILL.md: ruta con nombre de skill
                    exp = u
                    for vm in re.finditer(r"\$(\w+)", u):
                        if vm.group(1) in strvars:
                            exp = exp.replace(
                                "$" + vm.group(1), strvars[vm.group(1)]
                            )
                    if "$" not in exp and in_scope(exp):
                        pathvars[var] = exp
                elif re.fullmatch(r"[A-Za-z0-9_.][A-Za-z0-9_./-]*", val):
                    strvars[var] = u  # literal sin comillas (SK=nombre-de-skill)

        fm = re.match(r"\s*for\s+(\w+)\s+in\s+([^;]+);", line)
        if fm:
            var, items = fm.group(1), fm.group(2)
            vals = []
            for it in re.findall(r'"[^"]*"|\'[^\']*\'|\S+', items):
                vm = re.fullmatch(r'"?\$(\w+)"?', it)
                if vm:
                    v = vm.group(1)
                    if v in pathvars:
                        vals.append(pathvars[v])
                    elif v in strvars:
                        vals.append(strvars[v])
                    elif v in pathtpl:
                        vals.extend(pathtpl[v])
                    elif v in forloops:
                        vals.extend(forloops[v])
                else:
                    vals.append(unq(it))
            forloops[var] = vals

    def pattern_values(pat):
        """Expande el patrón: literal, var de cadena o interpolación de loop."""
        vm = re.fullmatch(r"\$(\w+)", pat)
        if vm:
            v = vm.group(1)
            if v in strvars:
                return [strvars[v]]
            if v in forloops:
                return forloops[v]
            return []
        out = [pat]
        for vm in re.finditer(r"\$(\w+)", pat):
            v = vm.group(1)
            if v in forloops and not strvars.get(v):
                out = [o.replace("$" + v, rep) for rep in forloops[v] for o in out]
        return out

    def flag_mode(flags):
        f = flags.replace("--", "")
        return ("F" if "F" in f else "E" if "E" in f else "B", "i" in f)

    def add_entries(pats, targets, mode, ci):
        for t in targets:
            if not in_scope(t):
                continue
            for p in pats:
                entries.append(
                    {"test": name, "target": t, "pattern": p, "mode": mode, "ci": ci}
                )

    grep_re = re.compile(
        r"\bgrep\s+((?:-{1,2}[A-Za-z][\w-]*\s+|--\s+)*)"
        r"('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|\$\w+)"
        # destino: variable ("$F", $F) o RUTA LITERAL bajo agents/ o
        # docs/agent-skills/, con comillas simples o dobles (o sin comillas)
        # y ./ opcional delante (r2: ./ y comillas simples tampoco se veían).
        r'\s+("?\$(\w+)"?|["\']?\.?/?(?:agents|docs/agent-skills)/[^\s"\'`;&|)]+["\']?)'
    )

    for line in lines:
        # (a) grep directo: grep -qF 'frase' "$DESTINO" || fail
        #                    grep -qF 'frase' agents/.../SKILL.md || exit 1
        for m in grep_re.finditer(line):
            flags, pat, token = m.group(1) or "", m.group(2), m.group(3) or ""
            rest = line[m.end():]
            mode, ci = flag_mode(flags)
            targets = []
            if m.group(4):  # "$DESTINO"
                if m.group(4) in pathvars:
                    targets.append(pathvars[m.group(4)])
                elif m.group(4) in pathtpl:
                    targets.extend(pathtpl[m.group(4)])
            else:  # ruta literal en la misma línea
                lit = token.strip('"').strip("'")
                if lit.startswith("./"):
                    lit = lit[2:]
                if in_scope(lit):
                    targets.append(lit)
            if not targets:
                continue
            pats = pattern_values(unq(pat))
            if "||" in rest:
                add_entries(pats, targets, mode, ci)
            else:
                for t in targets:
                    for p in pats:
                        negatives.append({"target": t, "pattern": p, "ci": ci})

        # (b) helper tiene "$TEXTO" 'frase' || fail  (grep -qF sobre la skill)
        for m in re.finditer(
            r'\btiene\s+"\$\((?:skill_texto\s+)?"?\$?(\w+)"?\)"?\s+'
            r"('(?:[^']*)'|\"(?:[^\"]*)\"|\$\w+)",
            line,
        ):
            if "||" not in line[m.end():]:
                continue
            src, pat = m.group(1), m.group(2)
            targets = set()
            if src in pathvars:
                targets.add(pathvars[src])
            targets.update(pathtpl.get(src, []))
            add_entries(pattern_values(unq(pat)), targets, "F", False)
        for m in re.finditer(
            r"\btiene\s+\"?\$?(\w+)\"?\s+('(?:[^']*)'|\"(?:[^\"]*)\"|\$\w+)", line
        ):
            if "||" not in line[m.end():]:
                continue
            src, pat = m.group(1), m.group(2)
            targets = set(contentvars.get(src, []))
            if src in pathvars:
                targets.add(pathvars[src])
            targets.update(pathtpl.get(src, []))
            add_entries(pattern_values(unq(pat)), targets, "F", False)

        # (c) pipes: head -1 "$REPO" | grep -q '^---$' || fail
        #              printf '%s\n' "$s" | grep -q -- '-f id=' || fail
        #     (el patrón del pipe se arma aparte, después del bucle (b))
        pipe_re = re.compile(
            r"\|\s*grep\s+((?:-{1,2}[A-Za-z][\w-]*\s+|--\s+)*)"
            r"('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|\$\w+)"
        )

    for line in lines:
        pm = pipe_re.search(line)
        if not pm:
            continue
        left = line[: pm.start()]
        lvars = re.findall(r"\$(\w+)", left)
        targets = set()
        for v in lvars:
            targets.update(contentvars.get(v, []))
            if v in pathvars:
                targets.add(pathvars[v])
            targets.update(pathtpl.get(v, []))
        if not targets:
            continue
        flags, pat = pm.group(1) or "", pm.group(2)
        mode, ci = flag_mode(flags)
        pats = pattern_values(unq(pat))
        if "||" in line[pm.end():]:
            add_entries(pats, targets, mode, ci)
        else:
            for t in targets:
                for p in pats:
                    negatives.append({"target": t, "pattern": p, "ci": ci})

    # (d) delimitadores awk de sección: /encabezado/{f=1} ... /corte/{f=0}.
    #     Si el encabezado cambia, el recorte se rompe: es un ancla más.
    folder_targets = {
        p
        for coll in (pathvars.values(),)
        for p in coll
        if os.path.isdir(p)
    }
    for coll in pathtpl.values():
        folder_targets.update(p for p in coll if os.path.isdir(p))
    for coll in contentvars.values():
        folder_targets.update(p for p in coll if os.path.isdir(p))
    if folder_targets:
        for m in re.finditer(r"/((?:[^/\\]|\\.)+)/\s*\{[^}]*\bf=(?:1|0)", joined):
            add_entries([m.group(1)], folder_targets, "E", False)

    return entries, negatives


tests = sorted(
    f for f in os.listdir(rp(TESTS_DIR)) if f.endswith(".sh") and f != SELF
)
inventory, negatives = [], []
for t in tests:
    e, n = parse_test(rp(os.path.join(TESTS_DIR, t)))
    inventory.extend(e)
    negatives.extend(n)

if not inventory:
    print("FAIL: el recorrido de scripts/tests/ no encontró ninguna frase "
          "anclada en agents/** ni docs/agent-skills/**; el parser se rompió")
    sys.exit(1)

# ------------------------------------------------------------ lectura de archivos
_lines_cache = {}


def file_lines(path):
    if path not in _lines_cache:
        try:
            _lines_cache[path] = read(path).split("\n")
        except OSError:
            _lines_cache[path] = None
    return _lines_cache[path]


_norm_cache = {}


def normalized(path):
    """Texto con saltos apretados a un espacio (como skill_texto de los tests)
    y mapa de cada posición -> línea original."""
    if path not in _norm_cache:
        lines = file_lines(path) or []
        chars, lineof = [], []
        for i, ln in enumerate(lines):
            if MARK_RE.search(ln):
                continue  # las marcas no son texto de la skill
            for ch in ln.replace("\t", " "):
                chars.append(ch)
                lineof.append(i)
            chars.append(" ")
            lineof.append(i)
        norm, norm_lineof = [], []
        for ch, lo in zip(chars, lineof):
            if norm and norm[-1] == " " and ch == " ":
                continue
            norm.append(ch)
            norm_lineof.append(lo)
        _norm_cache[path] = ("".join(norm), norm_lineof)
    return _norm_cache[path]


def translate_bre(p):
    r"""BRE de grep a regex de python. En BRE, ( ) + ? | { } son literales y $
    solo ancla al final (p.ej. app.bak-predeploy-$(date ...)); en python hay
    que escaparlos. Las secuencias \X del BRE (\( \. \{) significan literal,
    igual que en python, y pasan como están."""
    out = []
    i = 0
    while i < len(p):
        c = p[i]
        if c == "\\" and i + 1 < len(p):
            out.append(c + p[i + 1])
            i += 2
            continue
        if c in "()+?|{}":
            out.append("\\" + c)
        elif c == "$" and i != len(p) - 1:
            out.append("\\$")
        else:
            out.append(c)
        i += 1
    return "".join(out)


MARK_RE = re.compile(r"<!--\s*candado:\s*(.+?)\s*-->")


def find_matches(entry, path):
    """Líneas (inicio, fin) donde el patrón del test matchea este archivo.
    Las líneas que SON marca no cuentan: una marca no ancla frases por sí
    misma (si no, cualquier marca nombraría su propio test y la vuelta
    quedaría en verde por arte de magia)."""
    lines = file_lines(path)
    if lines is None:
        return []
    pat, mode, ci = entry["pattern"], entry["mode"], entry["ci"]
    out = []
    if mode == "F":
        for i, ln in enumerate(lines):
            if MARK_RE.search(ln):
                continue
            if pat in ln:
                out.append((i, i))
        norm, lineof = normalized(path)
        idx = norm.find(pat)
        if idx >= 0:
            out.append((lineof[idx], lineof[min(idx + len(pat) - 1, len(lineof) - 1)]))
    else:
        flags = re.IGNORECASE if ci else 0
        try:
            rx = re.compile(translate_bre(pat) if mode == "B" else pat, flags)
        except re.error:
            return []
        for i, ln in enumerate(lines):
            if MARK_RE.search(ln):
                continue
            if rx.search(ln):
                out.append((i, i))
    return sorted(set(out))


def fences_and_frontmatter(lines):
    fm = None
    if lines and lines[0].strip() == "---":
        for j in range(1, len(lines)):
            if lines[j].strip() == "---":
                fm = (0, j)
                break
    fences = []
    inside = None
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("```"):
            if inside is None:
                inside = i
            else:
                fences.append((inside, i))
                inside = None
    return fences, fm


_regions_cache = {}


def extend_region(path, match):
    """La marca no puede ir dentro de un bloque cercado ni del frontmatter:
    la región anclada se extiende al bloque que contiene la frase."""
    key = (path, match)
    if key in _regions_cache:
        return _regions_cache[key]
    lines = file_lines(path)
    fences, fm = (
        fences_and_frontmatter(lines) if lines is not None else ([], None)
    )
    s, e = match
    region = match
    if fm and s <= fm[1]:
        region = fm
    for a, b in fences:
        if a <= s and e <= b:
            region = (a, b)
            break
    _regions_cache[key] = region
    return region


_marks_cache = {}


def marks_of(path):
    if path not in _marks_cache:
        marks = []
        lines = file_lines(path)
        if lines:
            for i, ln in enumerate(lines):
                m = MARK_RE.search(ln)
                if m:
                    marks.append((i, m.group(1)))
        _marks_cache[path] = marks
    return _marks_cache[path]


def resolve_ref(ref):
    base = os.path.basename(re.sub(r"\[(.)\]", r"\1", ref.strip()))
    return base if base in set(tests) else None


def target_files(target):
    if os.path.isfile(rp(target)):
        return [target]
    if os.path.isdir(rp(target)):
        out = []
        for root, dirs, files in os.walk(rp(target)):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in sorted(files):
                if f.endswith(".md"):
                    out.append(os.path.join(root, f))
        return sorted(out)
    return []


_dir_eq_cache = {}


def target_covers(target, path):
    if target == path:
        return True
    if os.path.isdir(rp(target)) and path.startswith(target + os.sep):
        return True
    if os.path.isfile(rp(target)) and filecmp.cmp(rp(target), rp(path), shallow=False):
        return True
    parent = os.path.dirname(path)
    if os.path.isdir(rp(target)) and os.path.isdir(rp(parent)) and target != parent:
        key = (target, parent)
        if key not in _dir_eq_cache:
            r = subprocess.run(
                ["diff", "-r", rp(target), rp(parent)], capture_output=True
            )
            _dir_eq_cache[key] = r.returncode == 0
        return _dir_eq_cache[key]
    return False


# ------------------------------------------------------------ modo inventario
if os.environ.get("CANDADOS_INVENTARIO_JSON"):
    dump = []
    for e in inventory:
        files = []
        for p in target_files(e["target"]):
            files.append({"file": p, "matches": find_matches(e, p)})
        dump.append({**e, "files": files})
    with open(os.environ["CANDADOS_INVENTARIO_JSON"], "w", encoding="utf-8") as f:
        json.dump(
            {"entradas": dump, "negativos": negatives}, f, ensure_ascii=False, indent=1
        )
    print(
        "inventario volcado: %d frases ancladas por %d tests -> %s"
        % (len(inventory), len({e["test"] for e in inventory}),
           os.environ["CANDADOS_INVENTARIO_JSON"])
    )
    sys.exit(0)

# ---------------------------------------------------------------------- checks
fails = 0

# IDA: toda frase anclada por un test tiene su marca junto a la frase.
ida_faltan = []
for e in inventory:
    for path in target_files(e["target"]):
        if file_lines(path) is None:
            continue
        matches = find_matches(e, path)
        if not matches:
            continue  # eso lo rojo el test hermano, no este candado
        if not any(
            resolve_ref(ref) == e["test"]
            and rs - WINDOW <= ml <= re_ + WINDOW
            for ml, ref in marks_of(path)
            for rs, re_ in (extend_region(path, m) for m in matches)
        ):
            ida_faltan.append((e["test"], path, e["pattern"]))
if ida_faltan:
    fails += len(ida_faltan)
    print("FAIL ida: %d frase(s) anclada(s) sin marca junto a la frase:" % len(ida_faltan))
    for t, p, pat in ida_faltan[:20]:
        print("  %s no marca %r en %s" % (t, pat[:60], p))
    if len(ida_faltan) > 20:
        print("  ... y %d más" % (len(ida_faltan) - 20))
else:
    per_test = {}
    for e in inventory:
        per_test.setdefault(e["test"], 0)
        per_test[e["test"]] += 1
    print(
        "ok ida: las %d frases ancladas por %d test(s) tienen su marca"
        % (len(inventory), len(per_test))
    )

# VUELTA: toda marca apunta a un test que existe y que afirma esa frase ahí.
md_files = []
for base in ("agents", os.path.join("docs", "agent-skills")):
    for root, dirs, files in os.walk(rp(base)):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in sorted(files):
            if f.endswith(".md"):
                md_files.append(os.path.join(root, f))

vuelta_sobran = []
total_marks = 0
for path in md_files:
    for ml, ref in marks_of(path):
        total_marks += 1
        t = resolve_ref(ref)
        if t is None:
            vuelta_sobran.append((path, ml + 1, ref, "no es un test de %s/" % TESTS_DIR))
            continue
        ok = False
        for e in inventory:
            if e["test"] != t or not target_covers(e["target"], path):
                continue
            for m in find_matches(e, path):
                rs, re_ = extend_region(path, m)
                if rs - WINDOW <= ml <= re_ + WINDOW:
                    ok = True
                    break
            if ok:
                break
        if not ok:
            vuelta_sobran.append(
                (path, ml + 1, ref, "ese test no afirma ninguna frase junto a esta marca")
            )
if vuelta_sobran:
    fails += len(vuelta_sobran)
    print("FAIL vuelta: %d marca(s) que no sostiene su test:" % len(vuelta_sobran))
    for p, ln, ref, why in vuelta_sobran[:20]:
        print("  %s:%d <!-- candado: %s --> — %s" % (p, ln, ref, why))
    if len(vuelta_sobran) > 20:
        print("  ... y %d más" % (len(vuelta_sobran) - 20))
else:
    print(
        "ok vuelta: las %d marca(s) de agents/** y docs/agent-skills/** "
        "apuntan a tests que existen y afirman su frase" % total_marks
    )

if fails:
    print("ROJO: %d problema(s) con los candados declarados" % fails)
    sys.exit(1)
print("TODO VERDE: candados declarados (%d frases, %d marcas)" % (len(inventory), total_marks))
PY
