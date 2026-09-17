#!/bin/bash
# Prueba de mutantes de 7.5: parchea, corre la bateria CON tope de tiempo (el
# mutante "sin kill" cuelga por diseño y debe caer por timeout, no colgar la
# corrida), exige ROJO, restaura.
set -u
cd "$(dirname "$0")/../../.." || exit 1

correr() { # $1 archivo salida
  (cd tablero-runbook && node --test --test-timeout=8000 >/tmp/mut75.txt 2>&1)
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "ROJO ok"
  else
    echo "SOBREVIVIO en verde (MAL)"
  fi
  grep -E 'ℹ (pass|fail) ' /tmp/mut75.txt | sed 's/^/    /'
}

mutar_archivo() { # $1 archivo, $2 ancla, $3 reemplazo, $4 desc
  local archivo="$1" ancla="$2" reemplazo="$3" desc="$4"
  cp "$archivo" "/tmp/mut75-original.ts"
  node -e '
    const fs = require("fs");
    const [archivo, ancla, reemplazo] = process.argv.slice(1);
    let s = fs.readFileSync(archivo, "utf8");
    if (!s.includes(ancla)) { console.error("ancla no encontrada en " + archivo + ": " + ancla.slice(0, 60)); process.exit(1); }
    fs.writeFileSync(archivo, s.replace(ancla, reemplazo));
  ' "$archivo" "$ancla" "$reemplazo" || { echo "MUTANTE[$desc]: fallo al parchear"; return 2; }
  echo -n "MUTANTE[$desc]: "
  correr
  cp "/tmp/mut75-original.ts" "$archivo"
}

echo "=== mutantes 7.5 ==="

mutar_archivo tablero-runbook/index.ts \
  'cfgGithub.enabled && validarProgreso(doc).ok' \
  'validarProgreso(doc).ok' \
  'quitar el flag enabled'

mutar_archivo tablero-runbook/github.ts \
  'REPO_RE.test(repo)' \
  'true' \
  'aceptar repo envenenado (calc.exe / --template)'

mutar_archivo tablero-runbook/github.ts \
  'cfg.ghPath.endsWith(".exe")' \
  'true' \
  'aceptar ghPath .cmd'

mutar_archivo tablero-runbook/github.ts \
  '{ shell: false, timeout: Math.max(200, restante), killSignal: "SIGKILL", windowsHide: true }' \
  '{ shell: false, windowsHide: true }' \
  'quitar el kill por llamada'

echo "=== mutante compuesto: sin kill por llamada NI verdugo ==="
cp tablero-runbook/github.ts /tmp/mut75-gh.ts
node -e '
  const fs = require("fs");
  let s = fs.readFileSync("tablero-runbook/github.ts", "utf8");
  const a = "{ shell: false, timeout: Math.max(200, restante), killSignal: \"SIGKILL\", windowsHide: true }";
  if (!s.includes(a)) { console.error("ancla exec no encontrada"); process.exit(1); }
  s = s.replace(a, "{ shell: false, windowsHide: true }");
  const b = "child.kill(\"SIGKILL\");";
  if (!s.includes(b)) { console.error("ancla verdugo no encontrada"); process.exit(1); }
  s = s.replace(b, "void child;");
  fs.writeFileSync("tablero-runbook/github.ts", s);
'
echo -n "MUTANTE[sin ningun kill]: "
correr
cp /tmp/mut75-gh.ts tablero-runbook/github.ts

echo "=== restauracion ==="
(cd tablero-runbook && node --test >/tmp/verde75.txt 2>&1) && grep -E 'ℹ (pass|fail) ' /tmp/verde75.txt | sed 's/^/    /' && echo "VERDE restaurado" || { echo "ERROR: restauracion no verde"; exit 1; }
