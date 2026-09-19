# Entorno del exec en el nodo Mac (PATH restringido)

Leer solo cuando un binario común falta en el exec del nodo Mac
(`rg`, `timeout`, `uv`, `gh`, `corepack`, `python`), un `sed`/`bash` se
comporta distinto al de Linux, o un CLI lanzado en tmux muere al
instante sin error. Para comandos largos que mueren con
`COMPANION_APP_UNAVAILABLE`, el procedimiento vive en SKILL.md.

Regla: el exec del nodo sanea el PATH y **`pathPrepend` se ignora**;
todo comando lleva
`export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH;`
al frente, o ruta absoluta.

El exec del nodo corre con `PATH=/usr/bin:/bin:/usr/sbin:/sbin` y
`tools.exec.pathPrepend` se ignora en host=node. Ausencias medidas y su
reemplazo:

- `rg` no esta: usa `grep -n -E`. `uv` no esta:
  `<repo>/.venv/bin/python -m pytest`.
- `timeout` no existe en macOS: antepone `/opt/homebrew/bin:$PATH` en la
  corrida (ahi viven timeout y gtimeout); sin eso, casos preexistentes
  que lo usan enrojecen por ambiente y no por tu cambio.
- El shell por defecto del exec es `/bin/sh`: no hay sustitucion de
  procesos `<(...)` (`syntax error near unexpected token '<'`, medido
  2026-09-17). Recuperacion verificada: dividir en dos llamadas — la
  primera imprime los valores, la segunda los usa literales.
- El `sed` de macOS es BSD: `sed -i` exige argumento (`sed -i '' ...`);
  la forma GNU `sed -i 's/.../.../'` falla con `extra characters at the
  end of d command` (medido 2026-09-17: rompio el editor de secuencia
  de un `git rebase -i`; recuperacion: dropear con `git rebase --onto`,
  sin editor).
- El bash 3.2 de macOS no cierra `$(... <<'HEREDOC' ...)`: aunque valido
  en bash 4+, `bash -n` dice `unexpected EOF while looking for
  matching ')'` (los parentesis del cuerpo confunden su parser; medido
  2026-09-17 en test-merge-allowlist-cierre-pr.sh, verde en bash nuevo).
  Recuperacion verificada: heredoc a temporal fuera de la sustitucion —
  `tmp=$(mktemp); cat > "$tmp" <<'EOF' ... EOF; var=$(cmd "$tmp");
  rc=$?; rm -f "$tmp"`. `bash -n` reproduce sin ejecutar; un minimo con
  parentesis balanceados si pasa, asi que el fallo depende del contenido,
  no de la forma.
- `python` no existe (solo `python3` en `/usr/bin` y `/opt/homebrew/bin`):
  los hooks con `entry: python tools/...py` y `language: system` fallan
  con `Executable 'python' not found` aunque el repo este sano (medido en
  goncloud-MCP-2). Recuperacion verificada (2026-09-16): shim sin tocar
  el repo — `mkdir -p /tmp/pyshim && ln -sf /opt/homebrew/bin/python3.14
  /tmp/pyshim/python` y `export PATH="/tmp/pyshim:$PATH"` antepuesto al
  `git commit` / `git push`; los hooks de commit pasan (ruff check +
  import-linter Passed medidos) y el commit sale SIN `--no-verify`.
  Reserva `--no-verify` para el hook pre-push de suite completa cuando
  falle ambiental (python del sistema sin deps de Docker: tablas sqlite
  inexistentes, fastapi/uvicorn ausentes — mismos fallos sobre
  `origin/main` o con `git stash`, que se declaran preexistentes y no se
  arreglan): verifica a mano (ruff con el select del CI + tests
  enfocados) y deja la bateria completa al CI del PR.
- `gh` no esta en el PATH pero existe por ruta absoluta
  `/opt/homebrew/bin/gh` en la Mac del operador (medido lane saikit
  2026-09-13 y PRs #292/#2833 del 2026-09-16): usala asi; solo si falta
  del todo, el PR va por API (skill pr-sin-gh). `pre-commit` no esta como
  comando: los candados de commit corren igual via el shim de
  `.git/hooks/`.
- Todo ejecutable con shebang `env node` (tarballs, `corepack`/`npm`,
  lanzadores como `~/bin/glm`) muere si el PATH del llamante no trae
  node: por ruta absoluta falla con exit 127, y en
  `/opt/homebrew/bin/tmux new-session` la sesion desaparece en segundos
  con rc=0 y sin error visible. Firma medida (Fase 7, 2026-09-17):
  `/opt/homebrew/bin/tmux new-session` rc=0 pero
  `/opt/homebrew/bin/tmux has-session` dice `can't find session`; al
  correr el binario directo (`/Users/dn/bin/glm --help`) sale
  `env: node: No such file or directory`. Recuperacion verificada:
  embeber el PATH en el comando de la sesion —
  `/opt/homebrew/bin/tmux new-session -d -s <s> -c <dir>
  "PATH=/opt/homebrew/bin:<bins>:$PATH <bin>"` (node vive en
  `/opt/homebrew/bin`; para un tarball antepone `<dir>/bin`).
  Diagnostica siempre corriendo el binario directo primero; no reintentes
  el `/opt/homebrew/bin/tmux new-session` a ciegas.
  Rama tests que generan ejecutables: un `gh` falso (o fixture ejecutable)
  que tus tests escriben con `#!/usr/bin/env node` muere igual cuando el
  runner no trae node en PATH — firma medida (2026-09-17): `node --test`
  con el node24 fijo de run-checks.sh daba 58/60 con justo `exito ...
  SIGKILL` y `kill REAL` en rojo, mientras con node26 en PATH todo verde.
  Recuperacion verificada: generar el shebang como
  `#!${process.execPath}`; 60/60 con el mismo node24 sin tocar el PATH.
