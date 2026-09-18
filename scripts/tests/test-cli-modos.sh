#!/bin/bash
# 9.1 Contratos: validadores de corrida.v1 / seguimiento.v1 y cobertura de cli-modos.tsv.
# Las funciones validar_registro / validar_mensaje son la referencia que 9.2 reusa en
# scripts/mac/corrida/lib.sh (misma regla, sin duplicar criterio).
# Uso: bash scripts/tests/test-cli-modos.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

FX=scripts/tests/fixtures/corrida
TSV=scripts/mac/cli-modos.tsv
ZSH=scripts/mac/agent-tmux-shell.zsh

# --- validadores (referencia 9.1) ---
validar_registro() { # $1: json del registro; 0 = valido
  local j="$1" v
  v=$(python3 -c "
import sys,json
try:
  d=json.load(open('$j'))
except Exception:
  print('ROTO:no es json'); raise SystemExit
e=[]
if d.get('vigia') not in ('claw','hermes'): e.append('vigia fuera del conjunto')
ss=d.get('sesiones')
if not isinstance(ss,list) or not ss: e.append('sin sesiones')
else:
  for s in ss:
    for c in ('nombre','rol','cli','dueno'):
      if not (isinstance(s,dict) and s.get(c)): e.append('sesion sin '+c); break
    if isinstance(s,dict) and s.get('rol') not in (None,'lead','carril'):
      e.append('rol fuera del conjunto')
for x in e: print('ROTO:'+x)
" 2>/dev/null) || fail "el registro no es json: $1"
  [ -z "$v" ]
}

validar_mensaje() { # $1: txt; 0 = valido (seguimiento.v1, lenguaje de usuario)
  local m="$1"
  [ -f "$m" ] || return 1
  [ "$(wc -l < "$m")" -eq 4 ] || return 1
  head -1 "$m" | grep -qE '^\[(AVANZA|DETENIDA|NECESITO TU RESPUESTA|CERRADA)\] ' || return 1
  jerga_en_mensaje "$m" && return 1
  return 0
}

jerga_en_mensaje() { # 0 = trae jerga (acento, ruta, flag, sha, lista negra)
  local m="$1"
  grep -q '`' "$m" && return 0
  grep -qE '/[A-Za-z0-9_.-]' "$m" && return 0
  grep -qE '(^|[[:space:]])--[A-Za-z]' "$m" && return 0
  grep -qE '\b[0-9a-f]{7,40}\b' "$m" && return 0
  grep -qiE '\b(commit|merge|pr|worktree|branch|ci|hook|script)\b' "$m" && return 0
  return 1
}

# --- casos ---
[ -f "$TSV" ] || fail "falta $TSV"
validar_registro "$FX/registro-valido.json" || fail "el registro valido no pasa"
validar_registro "$FX/registro-vigia-malo.json" 2>/dev/null && fail "vigia fuera del conjunto pasa"
validar_registro "$FX/registro-sesion-sin-rol.json" 2>/dev/null && fail "sesion sin rol pasa"
validar_mensaje "$FX/mensaje-valido.txt" || fail "el mensaje valido no pasa"
validar_mensaje "$FX/mensaje-etiqueta-mala.txt" 2>/dev/null && fail "etiqueta desconocida pasa"
for j in palabra ruta flag sha tilde; do
  validar_mensaje "$FX/mensaje-jerga-$j.txt" 2>/dev/null && fail "jerga ($j) pasa"
done

# Cobertura: cada CLI de AGENT_TMUX_TOOLS tiene fila en cli-modos.tsv.
clis=$(grep -E '^AGENT_TMUX_TOOLS=\(' "$ZSH" | sed 's/.*(\(.*\)).*/\1/')
[ -n "$clis" ] || fail "no se pudo leer AGENT_TMUX_TOOLS de $ZSH"
for c in $clis; do
  grep -qE "^${c}	" "$TSV" || fail "$TSV: sin fila para $c"
done

echo "TODO VERDE: test-cli-modos"
