#!/usr/bin/env python3
"""Coloca las marcas <!-- candado: <test> --> junto a cada frase anclada.

Entrada: el inventario JSON que produce
  CANDADOS_INVENTARIO_JSON=/tmp/inv.json bash scripts/tests/test-candados-declarados.sh

Modelo: una marca vive en una FRONTERA entre dos líneas originales (los slots
de esa frontera, en orden de inserción). Agregar es append-only: nada de lo
ya cubierto se invalida, así que cada frase se cubre a lo sumo una vez y no
hay ciclos. Mientras haya una frase sin ninguna marca de su test a <=2 líneas
(región extendida a fence/frontmatter), se agrega una marca en la frontera
más cercana que la cubra. Al final, un barrido quita las marcas que sobran:
cada marca que queda es necesaria, y borrar cualquiera deja el candado en
rojo. Los archivos byte-idénticos (browser-cli-claw-profile en tres agentes,
saikit-cierre-pr en dos) forman un grupo: unión de frases, mismas marcas,
porque sus tests exigen la igualdad.
"""
import hashlib
import json
import os
import re
from collections import defaultdict

WINDOW = 2
INV = "/tmp/inv.json"
MARK_RE = re.compile(r"<!--\s*candado:\s*(.+?)\s*-->")


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


inv = json.load(open(INV))
entries = inv["entradas"]
negatives = inv["negativos"]


def blocks(lines):
    fm = None
    if lines and lines[0].strip() == "---":
        for j in range(1, len(lines)):
            if lines[j].strip() == "---":
                fm = (0, j)
                break
    fences, inside = [], None
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("```"):
            if inside is None:
                inside = i
            else:
                fences.append((inside, i))
                inside = None
    return fm, fences


def bre_to_py(p):
    out, i = [], 0
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


def matches_of(e, lines):
    pat, mode, ci = e["pattern"], e["mode"], e.get("ci", False)
    out = []
    if mode == "F":
        for i, ln in enumerate(lines):
            if MARK_RE.search(ln):
                continue  # una marca no ancla frases: cuenta el texto real
            if pat in ln:
                out.append((i, i))
    else:
        try:
            rx = re.compile(
                bre_to_py(pat) if mode == "B" else pat,
                re.IGNORECASE if ci else 0,
            )
        except re.error:
            return out
        for i, ln in enumerate(lines):
            if MARK_RE.search(ln):
                continue
            if rx.search(ln):
                out.append((i, i))
    return sorted(set(out))


def region_of(fm, fences, m):
    s, e = m
    if fm and s <= fm[1]:
        return fm
    for a, b in fences:
        if a <= s and e <= b:
            return (a, b)
    return m


def forbidden_for(path):
    out = []
    for n in negatives:
        t = n["target"]
        if t == path or path.startswith(t + "/"):
            out.append((n["pattern"], n.get("ci", False)))
    return out


def escaped_name(test, path):
    name = test
    for pat, ci in forbidden_for(path):
        if re.search(r"[\\^$.*+?()\[\]{}|]", pat):
            continue
        rx = re.compile(re.escape(pat), re.IGNORECASE if ci else 0)
        name = rx.sub(lambda m: "[" + m.group(0)[0] + "]" + m.group(0)[1:], name)
    return name


# grupos de archivos idénticos (pre-marcado)
all_md = []
for base in ("agents", "docs/agent-skills"):
    for root, dirs, fnames in os.walk(base):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fn in fnames:
            if fn.endswith(".md"):
                all_md.append(os.path.join(root, fn))
pre_hash = {p: hashlib.sha1(read(p).encode()).hexdigest() for p in all_md}
members = defaultdict(list)
for p in all_md:
    members[pre_hash[p]].append(p)

# (test, representante) -> entradas
work = {}
for e in entries:
    for f in e["files"]:
        if not f["matches"]:
            continue
        rep = sorted(members[pre_hash[f["file"]]])[0]
        work.setdefault((e["test"], rep), []).append(
            {"pattern": e["pattern"], "mode": e["mode"], "ci": e.get("ci", False)}
        )

orig = {rep: read(rep).split("\n") for (_, rep) in work}
slots = {rep: defaultdict(list) for (_, rep) in work}  # frontera -> [marcas]

# matches y regiones viven en coordenadas ORIGINALES (las líneas originales
# nunca cambian; las marcas solo se intercalan)
static = {}
for (test, rep), phrs in work.items():
    fm, fences = blocks(orig[rep])
    for e in phrs:
        ms = matches_of(e, orig[rep])
        regions = [region_of(fm, fences, m) for m in ms]
        static[(test, rep, e["pattern"], e["mode"], e.get("ci", False))] = regions


def key_of(rep, test, e):
    return (test, rep, e["pattern"], e["mode"], e.get("ci", False))


def rebuild(rep):
    """(líneas finales, origen de cada línea: índice original o None=marca)."""
    out, src = [], []
    for k, ln in enumerate(orig[rep]):
        out.append(ln)
        src.append(k)
        for m in slots[rep][k]:
            out.append(m)
            src.append(None)
    for m in slots[rep][len(orig[rep]) - 1]:  # frontera tras la última línea
        out.append(m)
        src.append(None)
    return out, src


def legal_boundary(rep, fm, fences, b):
    if b < (fm[1] if fm else 0):
        return False  # dentro del frontmatter
    return not any(a <= b < c for a, c in fences)


def covered(rep, test, e):
    lines, src = rebuild(rep)
    markline = "<!-- candado: %s -->" % escaped_name(test, rep)
    marks_at = [i for i, ln in enumerate(lines) if ln.strip() == markline]
    pos_of = {}
    for i, s in enumerate(src):
        if s is not None:
            pos_of[s] = i
    for rs, re_ in static[key_of(rep, test, e)]:
        fs, fe = pos_of[rs], pos_of[re_]
        if any(fs - WINDOW <= i <= fe + WINDOW for i in marks_at):
            return True
    return False


total = 0
for _ in range(2000):
    target = None
    for (test, rep), phrs in sorted(work.items()):
        for e in phrs:
            if not static[key_of(rep, test, e)]:
                continue
            if not covered(rep, test, e):
                target = (test, rep, e)
                break
        if target:
            break
    if target is None:
        break
    test, rep, e = target
    # la última región suele ser la sección sustantiva, no el resumen
    rs, re_ = static[key_of(rep, test, e)][-1]
    fm, fences = blocks(orig[rep])
    markline = "<!-- candado: %s -->" % escaped_name(test, rep)
    done = False
    for b in (re_, rs - 1, re_ + 1, rs - 2, re_ + 2, rs - 3, re_ + 3):
        if b < 0 or b >= len(orig[rep]):
            continue
        if not legal_boundary(rep, fm, fences, b):
            continue
        slots[rep][b].append(markline)
        if covered(rep, test, e):
            total += 1
            done = True
            break
        slots[rep][b].pop()
    if not done:
        print("SIN FRONTERA para %r en %s" % (e["pattern"][:40], rep))
        break

# minimizar: quitar marcas cuya ausencia no rompe la cobertura
for (test, rep) in list(work):
    changed = True
    while changed:
        changed = False
        for b in list(slots[rep]):
            for j in range(len(slots[rep][b])):
                saved = slots[rep][b].pop(j)
                if all(
                    covered(rep, t, e)
                    for (t, r), phrs in work.items()
                    if r == rep
                    for e in phrs
                    if static[key_of(rep, t, e)]
                ):
                    changed = True
                    break
                slots[rep][b].insert(j, saved)
            if changed:
                break

for rep in orig:
    final_lines, _ = rebuild(rep)
    marked = "\n".join(final_lines)
    for q in members[pre_hash[rep]]:
        with open(q, "w", encoding="utf-8") as f:
            f.write(marked)
    n = sum(1 for ln in final_lines if MARK_RE.search(ln))
    print(
        "%3d marcas en %s (grupo de %d)"
        % (n, rep, len(members[pre_hash[rep]]))
    )
print("total marcas: %d" % total)
