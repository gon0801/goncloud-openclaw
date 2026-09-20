#!/bin/bash
# Prueba de mutantes de 7.3: parchea lib.ts, corre la bateria, exige ROJO, restaura.
# La DoD de Plans 7.3: cada mutante listado debe dejar la bateria en rojo.
set -u
cd "$(dirname "$0")/../../.." || exit 1
LIB=tablero-runbook/lib.ts
cp "$LIB" /tmp/lib-73-original.ts

mutar() { # description, node-replacement-script
  local desc="$1" script="$2"
  node -e "$script" || { echo "MUTANTE[$desc]: fallo al parchear"; return 2; }
  if (cd tablero-runbook && node --test >/tmp/mut.txt 2>&1); then
    echo "MUTANTE[$desc]: SOBREVIVIO en verde (MAL)"
  else
    local n
    n=$(grep -c '^✖\|not ok' /tmp/mut.txt || true)
    echo "MUTANTE[$desc]: ROJO ok"
    grep -E '^# (pass|fail) ' /tmp/mut.txt | sed 's/^/    /'
  fi
  cp /tmp/lib-73-original.ts "$LIB"
}

echo "=== mutantes 7.3 ==="
mutar "quitar esc() (script en titulo/repo/check aparece literal)" '
  const fs=require("fs"); const p="tablero-runbook/lib.ts";
  let s=fs.readFileSync(p,"utf8");
  const a=`return s.replace(/[&<>\"\x27]/g, (ch) => ESC_MAP[ch] ?? ch);`;
  if(!s.includes(a)){console.error("ancla no encontrada: esc");process.exit(1)}
  fs.writeFileSync(p,s.replace(a,"return s;"));'

mutar "invertir truncar/escapar (entidad cortada)" '
  const fs=require("fs"); const p="tablero-runbook/lib.ts";
  let s=fs.readFileSync(p,"utf8");
  const a="return esc(truncar(s, max));";
  if(!s.includes(a)){console.error("ancla no encontrada: t()");process.exit(1)}
  fs.writeFileSync(p,s.replace(a,"return truncar(esc(s), max);"));'

mutar "quitar el truncado" '
  const fs=require("fs"); const p="tablero-runbook/lib.ts";
  let s=fs.readFileSync(p,"utf8");
  const a="return esc(truncar(s, max));";
  if(!s.includes(a)){console.error("ancla no encontrada: t()");process.exit(1)}
  fs.writeFileSync(p,s.replace(a,"return esc(s);"));'

mutar "aceptar un estado fuera de lista" '
  const fs=require("fs"); const p="tablero-runbook/lib.ts";
  let s=fs.readFileSync(p,"utf8");
  const a="if (!(CARRIL_ESTADOS as readonly string[]).includes(o[\"estado\"] as string)) {";
  if(!s.includes(a)){console.error("ancla no encontrada: estado");process.exit(1)}
  fs.writeFileSync(p,s.replace(a,"if (false) {"));'

mutar "aceptar fase con / o .." '
  const fs=require("fs"); const p="tablero-runbook/lib.ts";
  let s=fs.readFileSync(p,"utf8");
  const a="return typeof s === \"string\" && FASE_RE.test(s);";
  if(!s.includes(a)){console.error("ancla no encontrada: validarFase");process.exit(1)}
  fs.writeFileSync(p,s.replace(a,"return typeof s === \"string\";"));'

mutar "aceptar repo con ; o que empiece con -" '
  const fs=require("fs"); const p="tablero-runbook/lib.ts";
  let s=fs.readFileSync(p,"utf8");
  const a="if (typeof o[\"repo\"] !== \"string\" || !REPO_RE.test(o[\"repo\"])) {";
  if(!s.includes(a)){console.error("ancla no encontrada: repo");process.exit(1)}
  fs.writeFileSync(p,s.replace(a,"if (false) {"));'

mutar "perder eventos previos al fusionar" '
  const fs=require("fs"); const p="tablero-runbook/lib.ts";
  let s=fs.readFileSync(p,"utf8");
  const a="const fusion = [...(Array.isArray(previo) ? previo : [])];";
  if(!s.includes(a)){console.error("ancla no encontrada: fusion");process.exit(1)}
  fs.writeFileSync(p,s.replace(a,"const fusion = [];"));'

echo "=== restauracion ==="
cp /tmp/lib-73-original.ts "$LIB"
if (cd tablero-runbook && node --test >/tmp/verde.txt 2>&1); then
  grep -E '^# (pass|fail) ' /tmp/verde.txt | sed 's/^/    /'
  echo "VERDE restaurado"
else
  echo "ERROR: la restauracion no quedo verde"
  exit 1
fi
