#!/usr/bin/env bash
# Runner del repo, en la ruta que el kit reconoce.
#
# POR QUE EXISTE. El gate de integracion del kit (`saikit-merge.sh`) exige que el
# comando declarado en el `blast` del veredicto aparezca como linea `verified:` en el
# registro de evidencia de la sesion que sello. Quien escribe esa linea es el arnes, y
# solo acredita como verificacion al runner propio del repo en `tests/run.sh` o a los
# runners de paquete conocidos (npm/pnpm/yarn/bun/deno test, vitest, jest, playwright).
# Ninguno de los scripts de `scripts/tests/` coincide con ese patron.
#
# Consecuencia medida el 2026-09-18, cerrando la Fase 7: la bateria completa corrio en
# verde muchas veces y el gate siguio diciendo "el comando del blast no aparece con
# exito en harness-evidence.log". No era el trabajo ni la revision: era que este repo
# nunca corrio el paso 1 de la ruta de merge del kit (`saikit-setup-autopilot.sh
# --wrap-runner si`), que es justo el que genera este archivo. Sin el, ninguna prueba de
# este repo cuenta como evidencia, y ningun PR puede integrarse por la ruta oficial.
#
# QUE HACE. Delega en la bateria real del repo, sin agregar ni quitar nada. Todo lo que
# se corre de verdad vive en `scripts/run-checks.sh`; este archivo solo le da el nombre
# que el arnes sabe leer. Se usa `exec` a proposito: el codigo de salida de la bateria
# tiene que llegar intacto a quien invoca. Un `bash ... || true`, o un `exit 0` al final,
# convertiria este envoltorio en un falso verde para todo el repo.
#
# Uso: bash tests/run.sh [argumentos que pasan tal cual a scripts/run-checks.sh]
set -u
cd "$(dirname "$0")/.." || exit 1
exec bash scripts/run-checks.sh "$@"
