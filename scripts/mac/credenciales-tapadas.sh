#!/usr/bin/env bash
# Lista credenciales tapadas en ~/.openclaw: valores solo asteriscos, vacíos o archivos UTF-16.
# Imprime solo "ruta<TAB>clave<TAB>motivo", nunca un valor. `--resumen` imprime el conteo y sale 0.
# Sin --resumen sale 1 si hay alguna. OPENCLAW_HOME cambia la raíz (pruebas).
set -u
HOME_OC="${OPENCLAW_HOME:-$HOME/.openclaw}"
RESUMEN=0
[ "${1:-}" = "--resumen" ] && RESUMEN=1

escanear() { OC="$HOME_OC" python3 -I - <<'PY'
import glob, os, re
oc = os.environ["OC"]
files = sorted(glob.glob(oc + "/credentials/*")) + [oc + "/.env", oc + "/openclaw.json"] \
    + sorted(glob.glob(oc + "/workspace-*/.env"))
SECRETISH = re.compile(r"token|key|secret|pass|auth", re.I)
for p in files:
    if not os.path.isfile(p):
        continue
    raw = open(p, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff") or (b"\x00" in raw[:200] and len(raw) > 1):
        print(f"{p}\t-\tutf16")
        continue
    text = raw.decode("utf-8", "replace")
    isjson = p.endswith(".json")
    found = False
    if isjson:
        for m in re.finditer(r'["\']?([A-Za-z0-9_.\-]+)["\']?\s*:\s*(?:"([^"\n]*)"|\'([^\'\n]*)\')', text):
            k, v = m.group(1), m.group(2) if m.group(2) is not None else m.group(3)
            if v.strip() and set(v.strip()) <= {"*"}:
                print(f"{p}\t{k}\ttapada")
            elif not v.strip() and SECRETISH.search(k):
                print(f"{p}\t{k}\tvacia")
        continue
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", s)
        if m:
            found = True
            k, v = m.group(1), m.group(2).strip().strip("'\"").strip()
            if v and set(v) <= {"*"}:
                print(f"{p}\t{k}\ttapada")
            elif not v:
                print(f"{p}\t{k}\tvacia")
    if not found and p.startswith(oc + "/credentials/"):
        v = text.strip()
        k = os.path.basename(p)
        if not v:
            print(f"{p}\t{k}\tvacia")
        elif set(v) <= {"*"}:
            print(f"{p}\t{k}\ttapada")
PY
}
out=$(escanear)
n=0
[ -n "$out" ] && n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
if [ "$RESUMEN" = 1 ]; then echo "credenciales tapadas: $n"; exit 0; fi
[ "$n" -gt 0 ] && printf '%s\n' "$out"
[ "$n" -eq 0 ] && echo "sin credenciales tapadas"
[ "$n" -eq 0 ]
