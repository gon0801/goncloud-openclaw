# Aplicar la regla de ahorro de CI en un repo nuevo (5 min)

Regla global: el CI corre solo donde sea necesario. Tres frenos: cancela
corridas viejas, pausa la bateria en borradores, deja solo una marca minima
en verde.

## Pasos

1. Copia `quality-ahorro.yml` a `.github/workflows/quality.yml` del repo
   nuevo (crea la carpeta si no existe).
2. Reemplaza los pasos de ejemplo ("TU BATERIA AQUI") por los comandos
   reales del repo (pytest, npm test, pre-commit, etc.).
3. Si el repo tiene mas de un job caro (matrices, suites paralelas,
   servicios como Postgres/Docker), repite en CADA uno la linea `if:` del
   ejemplo y agrega su nombre al `needs: [...]` del `gate` (con su
   `R_NOMBRE` en el `env` y su `"nombre=$R_NOMBRE"` en el `for`).
4. Si el repo tiene jobs PROGRAMADOS (nocturnos) en el mismo archivo, pon
   el `concurrency` a nivel de JOB (no top-level) para no cancelarlos:
   ```yaml
   jobs:
     mi-job-caro:
       concurrency:
         group: mi-job-${{ github.event.pull_request.number || github.ref }}
         cancel-in-progress: true
   ```
5. Valida el YAML antes de subir (ej: `ruby -ryaml -e "YAML.load_file(...)"`).
6. Sube en rama nueva y abre el PR **en borrador**: con esta plantilla, el
   borrador solo corre el `gate` (~0 costo) y la bateria arranca al marcar
   listo para revision.
7. Marca el `gate` como check requerido en la proteccion de la rama (es el
   unico status que hay que mirar).

## Lo que NO se toca

Codigo, secrets, billing, visibilidad del repo, ni los nocturnos
programados: siguen corriendo igual.
