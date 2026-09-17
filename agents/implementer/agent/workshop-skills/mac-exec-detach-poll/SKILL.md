---
name: Mac exec detach poll
description: Cuando un comando largo en el nodo Mac (exec host=node) muere con COMPANION_APP_UNAVAILABLE, un binario comun (rg, timeout, uv, gh, corepack) falta en el exec, o un CLI lanzado en tmux muere al instante sin error. Relanza despegado con nohup, vigila con comandos cortos y usa las rutas del PATH restringido.
---

# Mac exec detach poll

En el nodo Mac los comandos exec de minutos (baterias de pytest, builds)
mueren intermitentemente con `COMPANION_APP_UNAVAILABLE` y la salida se
pierde; los comandos cortos siguen pasando. No repitas la corrida a
ciegas.

## Pasos

1. Diagnostica antes de reintentar: `pgrep -fl "<proceso>"` para ver si
   algo sobrevivio. Si vive, vigilalo; no lo relances.
2. Relanza DESPEGADO de la sesion exec, con salida a archivo y el exit
   code registrado al final:

   `nohup sh -c 'PYTHONPATH=. <cmd> > /tmp/<tarea>.log 2>&1; echo "EXIT=$?" >> /tmp/<tarea>.log' >/dev/null 2>&1 & echo lanzada`

3. Vigila con comandos CORTOS (sobreviven a las caidas del companion):

   `tail -3 /tmp/<tarea>.log; pgrep -fl "<proceso>" >/dev/null && echo SIGUE || echo TERMINO`

   Espacia las consultas: la bateria de Orbit (~2100 tests) tarda ~90 s;
   cada encuesta avanza pocos puntos de progreso.
4. El resultado valido es el del log (`EXIT=` + resumen), nunca la sola
   ausencia de proceso. Un EXIT distinto de 0 va al reporte tal cual.

## Entorno del exec (PATH restringido)

Regla: el exec del nodo sanea el PATH y **`pathPrepend` se ignora**; todo comando lleva `export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH;` al frente, o ruta absoluta.

El exec del nodo corre con `PATH=/usr/bin:/bin:/usr/sbin:/sbin` y
`tools.exec.pathPrepend` se ignora en host=node. Ausencias medidas y su
reemplazo:

- `rg` no esta: usa `grep -n -E`. `uv` no esta: `<repo>/.venv/bin/python -m pytest`.
- `timeout` no existe en macOS: antepone `/opt/homebrew/bin:$PATH` en la
  corrida (ahi viven timeout y gtimeout); sin eso, casos preexistentes
  que lo usan enrojecen por ambiente y no por tu cambio.
- `python` no existe (solo `python3` en `/usr/bin` y `/opt/homebrew/bin`): los hooks con `entry: python tools/...py` y `language: system` fallan con `Executable `python` not found` aunque el repo este sano (medido en goncloud-MCP-2). Recuperacion verificada (2026-09-16): shim sin tocar el repo — `mkdir -p /tmp/pyshim && ln -sf /opt/homebrew/bin/python3.14 /tmp/pyshim/python` y `export PATH="/tmp/pyshim:$PATH"` antepuesto al `git commit` / `git push`; los hooks de commit pasan (ruff check + import-linter Passed medidos) y el commit sale SIN `--no-verify`. Reserva `--no-verify` para el hook pre-push de suite completa cuando falle ambiental (python del sistema sin deps de Docker: tablas sqlite inexistentes, fastapi/uvicorn ausentes — mismos fallos sobre `origin/main` o con `git stash`, que se declaran preexistentes y no se arreglan): verifica a mano (ruff con el select del CI + tests enfocados) y deja la bateria completa al CI del PR.
- `gh` no esta en el PATH pero existe por ruta absoluta
  `/opt/homebrew/bin/gh` en la Mac del operador (medido lane saikit
  2026-09-13 y PRs #292/#2833 del 2026-09-16): usala asi; solo si falta del todo, el PR va por API
  (skill pr-sin-gh). `pre-commit` no esta como comando: los candados de
  commit corren igual via el shim de `.git/hooks/`.
- Todo ejecutable con shebang `env node` (tarballs, `corepack`/`npm`,
  lanzadores como `~/bin/glm`) muere si el PATH del llamante no trae
  node: por ruta absoluta falla con exit 127, y en
  `tmux new-session` la sesion desaparece en segundos con rc=0 y sin
  error visible. Firma medida (Fase 7, 2026-09-17): `new-session`
  rc=0 pero `has-session` dice `can't find session`; al correr el
  binario directo (`/Users/dn/bin/glm --help`) sale
  `env: node: No such file or directory`. Recuperacion verificada:
  embeber el PATH en el comando de la sesion —
  `new-session -d -s <s> -c <dir> "PATH=/opt/homebrew/bin:<bins>:$PATH <bin>"`
  (node vive en `/opt/homebrew/bin`; para un tarball antepone
  `<dir>/bin`). Diagnostica siempre corriendo el binario directo
  primero; no reintentes el `new-session` a ciegas.

## Criterio de cierre

Log con `EXIT=` registrado y el resumen leido del archivo, o bloqueo
declarado si ni el lanzamiento despegado sobrevive.
