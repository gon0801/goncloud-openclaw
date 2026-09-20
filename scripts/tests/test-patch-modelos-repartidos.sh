#!/bin/bash
# Prueba del incidente 2026-09-15 (corrida nocturna de claw): los 8 agentes colgaban de
# la misma llave `opencode-go` y una cuota agotada frenó toda la flota de 10 min a 24 h,
# mientras `docs/patches/modelos-cadena-go-zen.json` decía otra cosa que lo vivo.
# Verifica sobre `docs/patches/modelos-primaries-repartidos.json5`: (a) ningún proveedor
# es primary de más de 2 agentes; (b) `main`/`operaciones` (negocio) no comparten primary
# con ningún agente de pipeline (b1) y ningún primer fallback de pipeline drena un
# primary de negocio (b2); (c) ninguna cadena repite proveedor entre primary y
# primer fallback (c1), ninguna cadena es idéntica a otra (c2), ningún par comparte
# el prefijo de proveedores (primary, primer fallback) (c3) y el primer fallback no
# concentra más de 3 agentes en un proveedor (d); (e) FASE B: cadena con proveedores
# distintos, runtime nativo (sin `openai`, sin codex) y Anthropic al fondo (último
# fallback de cada cadena); (f) cada id existe en las cadenas vivas (`models list`
# no lo da este gateway).
# Proveedor = prefijo antes de `/` (`opencode-go` y `opencode` son dominios de cuota
# distintos: pago vs free). Parseo con `scripts/tests/json5sutil.py` (stdlib, sin
# dependencia json5). Un fallo de parseo es rojo (exit != 0), nunca verde falso.
# Discrimina con fixtures malos. Uso: bash scripts/tests/test-patch-modelos-repartidos.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

PATCH=docs/patches/modelos-primaries-repartidos.json5
VIVOS=docs/patches/modelos-vivos-2026-09-15.json5
UTIL=scripts/tests/json5sutil.py
[ -f "$PATCH" ] || fail "falta $PATCH (la propuesta de primaries repartidos)"
[ -f "$VIVOS" ] || fail "falta $VIVOS (las cadenas vivas contra las que se cruza)"
[ -f "$UTIL" ] || fail "falta $UTIL (parseo json5 compartido)"

# Revisa un json5 y devuelve las violaciones (a)-(d) por stdout (vacío = verde).
revisar() {
  python3 - "$1" <<'PY'
import json
import sys
from collections import Counter
sys.path.insert(0, 'scripts/tests')  # el test siempre corre desde la raiz
import json5sutil
try:
    d = json5sutil.cargar(sys.argv[1])
except Exception as e:
    print(f"no parsea como json5: {e}")
    sys.exit(2)
try:
    entries = d['agents']['entries']
except (KeyError, TypeError):
    print("sin agents.entries (el archivo parsea pero no trae cadenas)")
    sys.exit(2)
def prov(x):
    return x.split('/')[0]
viol = []
primaries = {}
cadenas = {}
primer_fb = {}
for agente, e in entries.items():
    m = (e or {}).get('model') or {}
    p = m.get('primary', '')
    fb = m.get('fallbacks') or []
    if '/' not in p:
        viol.append(f"{agente}: primary sin proveedor: {p!r}")
        continue
    primaries[agente] = p
    cadena = [p] + fb
    cadenas[agente] = list(cadena)
    for x in fb:
        if '/' not in x:
            viol.append(f"{agente}: fallback mal formado (sin proveedor): {x!r}")
    if len(fb) and '/' in fb[0] and prov(fb[0]) == prov(p):
        viol.append(f"{agente}: (c1) repite proveedor entre primary y primer fallback ({prov(p)})")
    primer_fb[agente] = fb[0] if fb and '/' in fb[0] else ''
    provs = [prov(x) for x in cadena if '/' in x]
    if len(set(provs)) != len(provs):
        viol.append(f"{agente}: FASE B: proveedor repetido en la cadena {provs}")
    malos = [x for x in cadena if 'openai' in x or 'codex' in x]
    if malos:
        viol.append(f"{agente}: FASE B: fuera de runtime nativo: {malos}")
    if not fb or '/' not in fb[-1] or prov(fb[-1]) != 'anthropic':
        viol.append(f"{agente}: FASE B: Anthropic no va al fondo: {fb[-1:]!r}")
# (a) tope de primaries por proveedor
for prv, n in sorted(Counter(prov(p) for p in primaries.values()).items()):
    if n > 2:
        viol.append(f"proveedor {prv} es primary de {n} agentes (>2)")
# (b) negocio separado del pipeline, en primary y en primer fallback: ningún fb1
# de pipeline drena directo un primary de negocio. Comparación por proveedor en
# ambos (dominio de cuota, no id exacto). main/operaciones deben existir: sin
# ellos el aislamiento no se verifica y eso también es rojo
# main/operaciones deben existir EN primaries: el chequeo per-agente rechaza con
# continue (antes de insertar) cualquier primary sin '/', así que toda clave
# presente trae proveedor sí o sí; la presencia basta
if 'main' not in primaries or 'operaciones' not in primaries:
    viol.append("(b) main/operaciones ausentes: el aislamiento no se verifica")
# (b0) La propuesta cubre a la flota entera: si le falta un agente, ese agente se
# queda con su primary viejo (todos en opencode-go) y el reparto no reparte nada.
ESPERADOS = {'main', 'operaciones', 'implementer', 'reviewer', 'adversary',
             'verifier', 'ingenieria', 'scout'}
faltantes = sorted(ESPERADOS - set(entries))
if faltantes:
    viol.append(f"(b0) la propuesta no cubre a la flota: faltan {', '.join(faltantes)}")
negocio = {primaries.get('main'), primaries.get('operaciones')}
negocio_prov = {prov(p) for p in negocio if p and '/' in p}
tuberia = {a: p for a, p in primaries.items() if a not in ('main', 'operaciones')}
for a, p in sorted(tuberia.items()):
    if prov(p) in negocio_prov:
        viol.append(f"{a} (b1) comparte dominio de cuota con negocio: {p}")
    f1 = primer_fb.get(a, '')
    if f1 and prov(f1) in negocio_prov:
        viol.append(f"{a} (b2) drena un primary de negocio en su primer fallback: {f1}")
# (a2) tope primario+fb1 por proveedor: que una sola llave no cargue con media
# flota en los dos primeros saltos (cota 4: documenta el peor caso aceptado)
for prv, n in sorted((Counter([prov(p) for p in primaries.values()]) +
                      Counter(prov(x) for x in primer_fb.values() if x)).items()):
    if n > 4:
        viol.append(f"(a2) {prv} carga con {n} agentes en primary+fb1 (>4)")
# (c) sin cadenas idénticas ni prefijos compartidos: dos agentes con el mismo
# par de proveedores (primary, primer fallback) caen juntos en los dos primeros
# saltos, que es donde importa; la comparación es por proveedor, no por id
vistas = {}
prefijos = {}
for a, c in sorted(cadenas.items()):
    clave = json.dumps(c)
    if clave in vistas:
        viol.append(f"{a} (c2) repite la cadena de {vistas[clave]}: cae junto ante la misma cuota")
    else:
        vistas[clave] = a
    fb1 = primer_fb.get(a, '')
    pre = (prov(c[0]), prov(fb1)) if fb1 else (prov(c[0]), '')
    if pre in prefijos:
        viol.append(f"{a} (c3) comparte prefijo {pre} con {prefijos[pre]}: caen juntos dos saltos")
    else:
        prefijos[pre] = a
# (d) primer fallback repartido: tope 3 por proveedor. Más laxo que (a) a propósito:
# el fallback es segunda capa y la llave free es el colchón común por diseño
for prv, n in sorted(Counter(prov(x) for x in primer_fb.values() if x).items()):
    if n > 3:
        caidos = sorted(a for a, x in primer_fb.items() if x and prov(x) == prv)
        viol.append(f"(d) primer fallback {prv} concentra a {n} agentes ({', '.join(caidos)}): >3")
print("\n".join(viol))
PY
}

# Cada id de la propuesta existe en las cadenas vivas (criterio estricto y
# deliberado: solo ids ya probados en una cadena viva; ver README).
cruzar_vivos() {
  python3 - "$1" "$2" <<'PY'
import sys
sys.path.insert(0, 'scripts/tests')  # el test siempre corre desde la raiz
import json5sutil
try:
    prop = json5sutil.cargar(sys.argv[1])
    vivos = json5sutil.cargar(sys.argv[2])
    hay = set()
    for e in vivos['agents']['entries'].values():
        m = (e or {}).get('model') or {}
        hay.add(m.get('primary', ''))
        hay.update(m.get('fallbacks') or [])
    dm = (vivos['agents'].get('defaults') or {}).get('model') or {}
    hay.add(dm.get('primary', ''))
    hay.update(dm.get('fallbacks') or [])
    hay.discard('')
    prop_ids = set()
    for e in prop['agents']['entries'].values():
        m = (e or {}).get('model') or {}
        prop_ids.add(m.get('primary', ''))
        prop_ids.update(m.get('fallbacks') or [])
    prop_ids.discard('')
    faltan = sorted(prop_ids - hay)
except Exception as e:
    print(f"no parsea como json5: {e}")
    sys.exit(2)
print("\n".join(f"sin cadena viva: {i}" for i in faltan))
PY
}

# (1) La propuesta cumple (el exit != 0 también es rojo).
out=$(revisar "$PATCH"); rc=$?
[ "$rc" -eq 0 ] || fail "revisar() falló sobre $PATCH (rc=$rc):
$out"
[ -z "$out" ] || fail "la propuesta viola sus reglas:
$out"
out=$(cruzar_vivos "$PATCH" "$VIVOS"); rc=$?
[ "$rc" -eq 0 ] || fail "cruzar_vivos() falló (rc=$rc):
$out"
[ -z "$out" ] || fail "la propuesta trae ids fuera de lo vivo:
$out"
echo "ok (1): primaries repartidos (máx 2 por proveedor, negocio separado, cadenas FASE B, ids en lo vivo)"

# (2) Discrimina con fixtures malos.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
cat > "$T/malo.json5" <<'EOF'
{ agents: { entries: {
  // zai en 3 primaries + main comparte con implementer + reviewer repite zai al inicio + scout con id inventado
  main:        { model: { primary: "zai/glm-5.3", fallbacks: ["kimi/k3", "xai/grok-4.6"] } },
  operaciones: { model: { primary: "kimi/k3",     fallbacks: ["zai/glm-5.3", "xai/grok-4.6"] } },
  implementer: { model: { primary: "zai/glm-5.3", fallbacks: ["opencode/glm-5.3-flash", "kimi/k3"] } },
  reviewer:    { model: { primary: "zai/glm-5.3", fallbacks: ["zai/otro", "kimi/k3"] } },
  scout:       { model: { primary: "invento/fantasma-1", fallbacks: ["kimi/k3", "invento/fantasma-2"] } },
} } }
EOF
out=$(revisar "$T/malo.json5"); rc=$?
[ "$rc" -eq 0 ] || fail "revisar() falló sobre el fixture malo (rc=$rc, se esperaba verde-con-hallazgos):
$out"
[ -n "$out" ] || fail "el revisor NO marca el fixture malo (la prueba no discrimina)"
echo "$out" | grep -q 'zai es primary de 3' || fail "no detecta proveedor con >2 primaries: $out"
echo "$out" | grep -q '(b1) comparte dominio de cuota con negocio' || fail "no detecta negocio compartido (b1): $out"
echo "$out" | grep -q '(b2) drena un primary de negocio' || fail "no detecta drenaje a negocio (b2): $out"
echo "$out" | grep -q 'primer fallback' || fail "no detecta repetición en primer fallback: $out"
out=$(cruzar_vivos "$T/malo.json5" "$VIVOS"); rc=$?
[ "$rc" -eq 0 ] || fail "cruzar_vivos() falló sobre el fixture malo (rc=$rc):
$out"
echo "$out" | grep -q 'sin cadena viva: invento/fantasma-1' || fail "no detecta primary fuera de lo vivo: $out"
echo "$out" | grep -q 'sin cadena viva: invento/fantasma-2' || fail "no detecta fallback fuera de lo vivo: $out"
cat > "$T/malo2.json5" <<'EOF'
{ agents: { entries: {
  // Anthropic no al fondo + codex + reviewer/adversary mismo prefijo distinta cadena + sondas idénticas + kimi concentra 4 primer-fallbacks
  main:        { model: { primary: "zai/glm-5.3", fallbacks: ["kimi/k3", "anthropic/claude-sonnet-5", "xai/grok-4.6"] } },
  operaciones: { model: { primary: "kimi/k3",     fallbacks: ["zai/glm-5.3", "codex/cli", "anthropic/claude-sonnet-5"] } },
  implementer: { model: { primary: "opencode-go/i", fallbacks: ["kimi/k3", "zai/glm-5.3", "anthropic/claude-sonnet-5"] } },
  reviewer:    { model: { primary: "zzz/a", fallbacks: ["kimi/k3", "yyy/b", "anthropic/claude-sonnet-5"] } },
  adversary:   { model: { primary: "zzz/a", fallbacks: ["kimi/k9", "www/c", "anthropic/claude-sonnet-5"] } },
  sonda:       { model: { primary: "qqq/e", fallbacks: ["www/g", "yyy/h", "anthropic/claude-sonnet-5"] } },
  sonda2:      { model: { primary: "qqq/e", fallbacks: ["www/g", "yyy/h", "anthropic/claude-sonnet-5"] } },
} } }
EOF
out=$(revisar "$T/malo2.json5"); rc=$?
[ "$rc" -eq 0 ] || fail "revisar() falló sobre el fixture malo2 (rc=$rc):
$out"
echo "$out" | grep -q 'Anthropic no va al fondo' || fail "no detecta Anthropic fuera del fondo: $out"
echo "$out" | grep -q 'fuera de runtime nativo' || fail "no detecta codex en la cadena: $out"
echo "$out" | grep -q 'repite la cadena de' || fail "no detecta cadenas idénticas (c2): $out"
echo "$out" | grep -q "comparte prefijo ('zzz', 'kimi')" || fail "no detecta prefijo compartido con distinto id (c3): $out"
echo "$out" | grep -q 'primer fallback kimi concentra a 4' || fail "no detecta concentración del primer fallback (d): $out"
echo "$out" | grep -q '(a2) kimi carga con 5 agentes' || fail "no detecta carga primary+fb1 (a2): $out"
cat > "$T/malo3.json5" <<'EOF'
{ agents: { entries: {
  // Sin operaciones: el aislamiento negocio/pipeline no se verifica
  main:        { model: { primary: "zai/glm-5.3", fallbacks: ["kimi/k3", "xai/grok-4.6", "anthropic/claude-sonnet-5"] } },
  implementer: { model: { primary: "opencode-go/i", fallbacks: ["kimi/k3", "zai/glm-5.3", "anthropic/claude-sonnet-5"] } },
} } }
EOF
out=$(revisar "$T/malo3.json5"); rc=$?
[ "$rc" -eq 0 ] || fail "revisar() falló sobre el fixture malo3 (rc=$rc):
$out"
echo "$out" | grep -qxF '(b) main/operaciones ausentes: el aislamiento no se verifica' || fail "no detecta negocio incompleto (b): $out"
echo "$out" | grep -q '(b0) la propuesta no cubre a la flota: faltan adversary, ingenieria, operaciones, reviewer, scout, verifier' || fail "no detecta agentes faltantes (b0): $out"
echo "$out" | grep -q 'primary sin proveedor' && fail "malo3 no debe traer violación per-agente (es el caso solo-ausencia): $out"
cat > "$T/malo3b.json5" <<'EOF'
{ agents: { entries: {
  // operaciones con primary sin proveedor: el per-agente lo excluye de primaries
  // con continue, así que el guard (b) lo ve como ausencia; un valor presente sin
  // '/' es inalcanzable desde JSON5 y no tiene negativo propio
  main:        { model: { primary: "zai/glm-5.3", fallbacks: ["kimi/k3", "xai/grok-4.6", "anthropic/claude-sonnet-5"] } },
  operaciones: { model: { primary: "k3", fallbacks: ["zai/glm-5.3", "xai/grok-4.6", "anthropic/claude-sonnet-5"] } },
} } }
EOF
out=$(revisar "$T/malo3b.json5"); rc=$?
[ "$rc" -eq 0 ] || fail "revisar() falló sobre el fixture malo3b (rc=$rc):
$out"
echo "$out" | grep -qxF '(b) main/operaciones ausentes: el aislamiento no se verifica' || fail "no detecta negocio sin proveedor (b): $out"
echo "$out" | grep -q "operaciones: primary sin proveedor: 'k3'" || fail "el per-agente no nombra agente y valor: $out"
cat > "$T/malo4.json5" <<'EOF'
{ agents: { entries: {
  main: { model: { primary: "zai/glm-5.3", fallbacks: ["kimi/k3", "anthropic/claude-sonnet-5"] } },
} } } /* comentario que nadie cerro
EOF
out=$(revisar "$T/malo4.json5"); rc=$?
[ "$rc" -ne 0 ] || fail "un json5 con comentario de bloque sin cerrar NO puede salir verde: $out"
echo "$out" | grep -q 'no parsea como json5' || fail "el fallo de parseo no se nombra: $out"
echo "$out" | grep -q 'sin cerrar' || fail "el fallo no dice que el comentario quedo sin cerrar: $out"
echo "ok (2): el revisor marca >2 primaries, negocio compartido/ausente (b1/b2), repetición al inicio, Anthropic fuera del fondo, codex, cadenas idénticas, prefijo compartido, primer fallback concentrado, carga primary+fb1 e ids fuera de lo vivo"
echo "TODO VERDE: patch de modelos repartidos"
