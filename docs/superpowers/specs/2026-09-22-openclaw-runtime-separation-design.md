# Separación y limpieza del runtime de OpenClaw

Fecha: 2026-09-22
Estado: corregido tras la revisión cruzada de Grok
Propietario: David

## Propósito

Separar el código versionado del estado vivo de OpenClaw en Windows. La
migración debe restaurar la memoria semántica local, mantener el nodo Windows
conectado y devolver `GoncloudRepoSync` a servicio sin permitir que Git
sobrescriba bases, credenciales o launchers generados.

Este diseño responde al incidente del 21 de septiembre de 2026. No sustituye
el gateway ni reinstala los agentes desde cero.

## Estado observado

El host Windows tiene estas condiciones confirmadas:

- OpenClaw `2026.9.5 (ec9c1a1)` ejecuta el gateway en el puerto 18789.
- El gateway responde en `/startupz` y `/readyz`.
- El watchdog espera 90 segundos y termina sus ciclos con código 0.
- `C:\Users\ehven\.openclaw` es al mismo tiempo el directorio de estado vivo
  y un checkout de `goncloud-openclaw`.
- El checkout de Windows está atrasado respecto de `origin/main` y tiene
  cambios en launchers que OpenClaw regeneró durante la actualización.
- `GoncloudRepoSync` está deshabilitado para impedir otro rollback.
- La tarea duplicada `OpenClaw CUA Node` está deshabilitada.
- La tarea oficial `OpenClaw Node` está habilitada, pero detenida.
- El nodo y el gateway leen la misma base
  `C:\Users\ehven\.openclaw\state\openclaw.sqlite`.
- El nodo aborta cuando no obtiene una copia estable de esa base en diez
  intentos.
- Windows Code Integrity rechaza `llama-server-impl.dll` con los eventos
  3033 y 3077. El paquete de `llama.cpp` no tiene firma Authenticode válida.

Los datos no observados siguen siendo desconocidos. En particular, no está
confirmado qué cambio de Windows activó o endureció la política que bloquea
`llama.cpp`.

## Objetivos

La migración debe cumplir estas condiciones:

1. El estado vivo no contiene un directorio `.git` del repo
   `goncloud-openclaw`.
2. Git no rastrea launchers que genera OpenClaw.
3. El sync despliega solo archivos versionados y nunca añade todo el estado
   vivo con `git add -A`.
4. La memoria semántica usa un proceso local que Windows permite ejecutar.
5. El nodo Windows usa un directorio de estado distinto del gateway.
6. El nodo oficial queda habilitado, en ejecución y conectado después de un
   reinicio de la tarea.
7. Ninguna fase desactiva o relaja Windows Code Integrity.
8. Cada fase tiene una reversa que no depende de Git dentro del estado vivo.

## Fuera de alcance

Este trabajo no cambia modelos de conversación, cadenas de fallback,
credenciales de proveedores ni permisos de agentes. Tampoco parchea archivos
de `openclaw/dist`, modifica la política de Code Integrity ni borra bases de
datos, sesiones, memorias o credenciales.

La migración de los tres repos de workspace fuera de `.openclaw` queda fuera
de este cambio. `workspace`, `workspace-ingenieria` y `workspace-operaciones`
conservan sus checkouts y su mecanismo actual. El nuevo sync debe tratarlos
como repos separados y no incluirlos en el despliegue de
`goncloud-openclaw`.

## Disposición de directorios

La estructura final será:

```text
C:\Users\ehven\.openclaw\
  Estado vivo del gateway, agentes, sesiones, credenciales, logs y herramientas.
  No contiene el .git de goncloud-openclaw.

C:\Users\ehven\.openclaw-node\
  Estado, identidad, aprobaciones, configuración y logs del nodo Windows.

C:\Users\ehven\src\goncloud-openclaw\
  Checkout dedicado de origin/main. No lo usa el gateway como estado.
```

Los repos de workspace conservan sus ubicaciones actuales durante esta
migración.

## Propiedad de los archivos

Cada ruta tendrá un solo propietario:

| Clase | Propietario | Tratamiento |
|---|---|---|
| Configuración y plugins versionados | repo fuente | El deploy los copia al estado vivo después de validar. |
| Bases SQLite, credenciales, sesiones y `.env` | OpenClaw | El deploy nunca los lee, copia, añade a Git ni borra. |
| `gateway.cmd`, `gateway.vbs`, `node.cmd`, `node.vbs` | instalador de OpenClaw | Git deja de rastrearlos y el deploy los excluye. |
| `gateway-watchdog.ps1` | repo fuente | El deploy lo actualiza de forma atómica. |
| Logs, cachés, herramientas y modelos | OpenClaw | El deploy los excluye. La limpieza aplica reglas específicas. |
| Skills autónomas bajo `agents/*/agent/workshop-skills` | runtime y revisión humana | El capturador crea una rama y un PR. Nunca empuja directo a `main`. |

## Respaldo y recuperación

La primera fase no borra archivos. Debe crear y verificar estas copias:

1. Un backup de OpenClaw creado con `openclaw backup create --verify` mientras
   el gateway está detenido según el procedimiento oficial.
2. Un `git bundle` del checkout vivo, incluidas sus referencias locales.
3. Una copia de los launchers activos y de la definición XML de las tareas
   `OpenClaw Gateway`, `OpenClaw Gateway Watchdog`, `OpenClaw Node`,
   `OpenClaw CUA Node` y `GoncloudRepoSync`.
4. Un inventario con ruta, tamaño y hash de cada candidato de limpieza.

El backup se restaura a un directorio de staging. La prueba debe leer su
manifiesto y confirmar que contiene la base compartida, las bases de agentes,
las credenciales y los workspaces declarados. No se acepta un archivo de
backup solo porque existe.

Esta interfaz está confirmada en OpenClaw `2026.9.5`: `openclaw backup create
--verify` incluye configuración, credenciales, sesiones y workspaces, salvo
que el operador pase `--no-include-workspace`.

Si la verificación del backup falla, la migración se detiene antes de mover o
borrar cualquier archivo.

## Sincronización y despliegue

`GoncloudRepoSync` dejará de ejecutar Git dentro del estado vivo para el repo
principal. El ciclo nuevo tendrá este orden:

1. Capturar cambios autónomos permitidos del estado vivo en un worktree
   temporal.
2. Registrar como protegidas las rutas capturadas mientras su PR siga
   pendiente.
3. Actualizar el checkout dedicado contra `origin/main`.
4. Preparar un árbol de staging con los archivos desplegables.
5. Excluir del staging las rutas protegidas y verificar que sus bytes vivos no
   cambien.
6. Validar la configuración y los contratos del árbol de staging.
7. Copiar el árbol validado al estado vivo mediante reemplazos atómicos por
   archivo.
8. Ejecutar las sondas de salud.
9. Registrar el SHA desplegado y el resultado del ciclo.

El script conserva el bucle sobre los cuatro repos actuales. Un fallo en
`goncloud-openclaw` se registra y no impide que `workspace`,
`workspace-ingenieria` y `workspace-operaciones` completen sus ciclos. Cada
repo conserva su propio resultado y el marcador final se escribe después de
procesar los cuatro.

### Captura de cambios autónomos

La captura usa una lista permitida. La primera versión admite únicamente:

```text
agents/*/agent/workshop-skills/**
```

El capturador compara el estado vivo con `origin/main`. Si encuentra un
cambio permitido, crea un worktree temporal desde `origin/main`, abre una rama
`auto/skills/<fecha-hora>-<agente>`, copia solo las rutas permitidas, hace
commit, push y abre un PR. Después elimina el worktree temporal. El checkout
dedicado permanece en `main`, sin commits locales ni cambio de rama. El
capturador no mergea el PR y no empuja a `main`.

El ciclo guarda ruta, hash vivo, rama y PR de cada captura pendiente. El
deploy no toca esas rutas mientras el PR permanezca abierto. Cuando el PR
llega a `main`, el siguiente ciclo despliega la versión mergeada y elimina la
protección solo después de comprobar el hash resultante. Si el PR se cierra
sin mergear, el sync conserva el archivo vivo, registra el conflicto y espera
una decisión del propietario.

Un cambio fuera de la lista permitida queda en el estado vivo y produce una
alerta. El sync no lo añade, no lo borra y no lo sobrescribe.

### Contrato del log y del vigía

El ciclo conserva los tokens que consume `verif-sync-repos`:

```text
FALLO
CONFLICTO
---- ciclo terminado
```

Una captura nueva escribe `SKILLS_PR`, el agente, las rutas y el número del
PR. No escribe `SKILLS`, porque el cambio todavía no está en `main`. El vigía
sube a una versión que reconoce `SKILLS_PR` y dice que el cambio espera
revisión. Solo una línea de despliegue posterior puede afirmar que el cambio
llegó a `main`.

El cambio del script y el cambio del vigía se despliegan como una sola unidad.
`GoncloudRepoSync` no se habilita hasta que el vigía nuevo esté activo y su
read-back coincida con la copia versionada. Las pruebas existentes de
`scripts/tests/test-sync-avisa-skills.sh` se actualizan para rechazar el texto
anterior cuando el PR siga abierto.

### Manifiesto de despliegue

Un manifiesto versionado define qué archivos del repo pueden llegar al estado
vivo. El manifiesto excluye al menos:

```text
.git/**
.env
state/**
agents/*/agent/*.sqlite*
credentials/**
sessions/**
logs/**
cache/**
tools/**
models/**
workspace/.git/**
workspace-ingenieria/.git/**
workspace-operaciones/.git/**
gateway.cmd
gateway.vbs
node.cmd
node.vbs
```

El implementador debe derivar la lista positiva a partir de los archivos
versionados y aplicar las exclusiones. No debe recorrer el estado vivo para
decidir qué subir.

### Validación y reversa

El deploy prepara cada archivo fuera de su destino. Antes de publicar ejecuta
`openclaw config validate` contra la configuración de staging y las pruebas
contractuales del repo que correspondan a los archivos cambiados.

El deploy conserva una copia de los archivos que reemplazará. Si una sonda
posterior falla, restaura solo esos archivos. Nunca ejecuta
`git reset --hard` contra el estado vivo.

Antes del primer deploy, el script exige que `origin/main` contenga
`$httpTimeoutSec = 90` en `gateway-watchdog.ps1`. El PR #122 ya dejó ese valor
en `origin/main`. La compuerta evita que una base equivocada restaure el valor
de 10 segundos.

Un ciclo exitoso prueba:

- el checkout dedicado termina exactamente en `origin/main`;
- no quedan commits locales ni archivos modificados en ese checkout;
- `/startupz` responde 200 y reporta la versión esperada;
- `/readyz` responde 200;
- el log no contiene `CONFLICTO`, `FALLO` ni una reversa silenciosa.

## Memoria local con Ollama

La política de Code Integrity permanece activa. La migración no crea una
excepción para `llama.cpp`.

La instalación de Ollama sigue estas compuertas:

1. Descargar el instalador desde `https://ollama.com/download/windows`.
2. Calcular y registrar su SHA-256.
3. Exigir una firma Authenticode válida antes de ejecutarlo.
4. Instalarlo sin cambiar las cadenas de modelos de conversación.
5. Confirmar que el servicio escucha solo en el endpoint local configurado.
6. Descargar `nomic-embed-text`, el modelo predeterminado de embeddings de
   Ollama en OpenClaw.
7. Probar `/api/embed` con una entrada controlada y exigir un vector no vacío.

Si el instalador o los binarios instalados no cumplen Code Integrity, la fase
se detiene. El sistema no cambia automáticamente a un proveedor remoto.

Después de la prueba local, la configuración cambia únicamente estos campos:

```json5
memory: {
  search: {
    provider: "ollama",
    model: "nomic-embed-text",
    fallback: "none",
  },
}
```

El cambio se aplica a la configuración viva, que no forma parte del
manifiesto de deploy. Antes de reiniciar, `openclaw config validate --json`
debe aceptar el archivo y `openclaw config get memory.search` debe devolver
`ollama`, `nomic-embed-text` y `none`. OpenClaw `2026.9.5` admite esos campos
en `memory.search`; la implementación no usa la forma antigua
`agents.defaults.memorySearch`.

El cambio de proveedor invalida la identidad de los índices vectoriales. La
migración reconstruye el índice de cada agente de forma explícita. No mezcla
vectores creados por `llama.cpp` con vectores creados por Ollama.

Antes de reconstruir, la migración crea y verifica un snapshot SQLite de cada
base de agente. El recibo relaciona cada agente con su snapshot y con la
identidad del proveedor anterior.

La verificación hace una consulta cuyo resultado semántico no dependa de una
coincidencia literal. También confirma que no aparecen eventos nuevos 3033 o
3077 para `llama-server` después del cambio.

El directorio de `llama.cpp` se mueve al archivo de cuarentena después de que
la memoria funcione con Ollama. No se borra durante la misma fase.

Si Ollama falla antes del cambio de configuración, la fase termina sin tocar
la configuración ni los índices. Si falla después del cambio, la reversa
detiene el gateway, restaura los snapshots de las bases de agentes y configura
`memory.search.provider` como `none`. Ese modo conserva la búsqueda léxica y
no intenta ejecutar `llama.cpp`. La reversa nunca devuelve la configuración a
`provider: "local"` mientras Code Integrity bloquee el binario.

## Nodo Windows aislado

El nodo usará `C:\Users\ehven\.openclaw-node` como
`OPENCLAW_STATE_DIR`. No copiará la base SQLite del gateway.

El alta tendrá estos pasos:

1. Crear el directorio con permisos para el usuario `ehven` y sin acceso de
   escritura para otros usuarios locales.
2. Crear una configuración mínima. Debe deshabilitar la publicación de skills
   y la inferencia local si esas capacidades no forman parte de la lista de
   comandos aprobada.
3. Generar un código de emparejamiento de un solo uso desde el gateway.
4. Instalar `OpenClaw Node` con `--pair` bajo el estado aislado.
5. Aprobar únicamente la lista de comandos que requiera CUA en Windows.
6. Confirmar que la acción de la tarea conserva el estado aislado después de
   cerrar la terminal que hizo la instalación.

La lista inicial de comandos será:

```text
browser.proxy
browser.proxy.upload.v1
computer.act
screen.snapshot
system.run
system.run.prepare
system.which
fs.listDir
```

Las capacidades de archivo adicionales requieren una decisión posterior. La
migración no habilita `file.write` ni hosting de sesiones por defecto.

La tarea duplicada `OpenClaw CUA Node` se exporta a XML y luego se elimina. La
tarea oficial queda habilitada y configurada para iniciar con la sesión del
usuario. La prueba reinicia la tarea, espera por condición y exige que
`openclaw nodes status --json` reporte el nodo Windows como conectado y en
versión `2026.9.5`.

La prueba mantiene carga normal en el gateway durante quince minutos. El nodo
debe continuar conectado y `/readyz` debe permanecer en 200. Un proceso vivo
sin conexión no cumple la prueba.

## Limpieza

La limpieza ocurre después de que el sync, la memoria y el nodo hayan pasado
sus pruebas. Cada candidato se clasifica antes de moverlo.

Se pueden archivar:

- launchers `.bak` que ninguna tarea referencia;
- configuraciones rotas guardadas durante incidentes;
- logs que superen la retención acordada;
- temporales que ningún proceso tenga abiertos;
- el paquete bloqueado de `llama.cpp` después de validar Ollama;
- worktrees de corridas cerradas sin ramas ni procesos activos.

No se borran:

- bases SQLite, archivos WAL o SHM;
- credenciales, `.env` o tokens de emparejamiento;
- sesiones, memoria o archivos de usuario;
- launchers que referencie una tarea habilitada;
- evidencia necesaria para explicar o revertir el incidente.

La primera pasada mueve candidatos a un archivo de cuarentena fuera del
estado vivo. Una segunda tarea podrá borrar ese archivo después de siete días
y una nueva verificación. Este diseño no autoriza el borrado definitivo.

## Orden de implementación

Las fases se ejecutan en este orden:

1. Crear y verificar los respaldos.
2. Añadir las pruebas de regresión del sync y del manifiesto.
3. Separar el checkout fuente y desplegar desde staging.
4. Ejecutar un ciclo real de sync y conservar su recibo.
5. Instalar y verificar Ollama.
6. Cambiar el proveedor de memoria y reconstruir los índices.
7. Crear y emparejar el estado aislado del nodo.
8. Eliminar la tarea duplicada después de exportarla.
9. Ejecutar las pruebas integrales.
10. Mover los artefactos confirmados a cuarentena.

Una fase no comienza si la anterior no tiene su recibo. El rollback devuelve
el sistema al último recibo verde, no al inicio completo de la migración.

## Pruebas y criterios de aceptación

Las pruebas automatizadas deben cubrir estos fallos:

- un launcher generado nunca entra al índice de Git;
- un archivo fuera de la lista de captura no produce un commit;
- un cambio de skill crea una rama y un PR, no un push a `main`;
- un cambio de skill pendiente conserva sus bytes vivos durante el deploy;
- un PR de skill cerrado sin mergear queda protegido y genera conflicto;
- un fallo de validación no cambia el estado vivo;
- una sonda fallida restaura solo los archivos del deploy;
- el manifiesto nunca incluye bases, credenciales, logs o herramientas;
- un ciclo repetido sin cambios no modifica archivos ni crea commits;
- un ciclo interrumpido converge al mismo resultado cuando se repite.
- un fallo del repo principal no impide procesar los tres workspaces;
- el log conserva el marcador final y distingue `SKILLS_PR` de un despliegue
  que ya llegó a `main`.

La aceptación operativa exige evidencia fresca de:

```text
backup verificado
checkout fuente limpio y en origin/main
sync habilitado y último resultado 0
gateway /startupz = 200
gateway /readyz = 200
Ollama /api/embed devuelve un vector
memory_search devuelve un resultado semántico esperado
nodo Windows connected = true, version = 2026.9.5
sin eventos nuevos de Code Integrity para llama-server
```

Durante el desarrollo se ejecutan solo las pruebas focalizadas. El SHA final
se publica en una rama creada desde `origin/main`, abre un PR y consume una
sola batería completa en CI. Los hooks de pre-commit se ejecutan sin
`--no-verify`.

## Seguridad

Los logs y la evidencia no incluyen valores de `.env`, credenciales, tokens de
emparejamiento ni contenido de memoria. Los hashes de instaladores sí pueden
versionarse.

El deploy usa listas positivas y rutas canónicas. Rechaza `..`, enlaces
simbólicos y destinos fuera de `C:\Users\ehven\.openclaw`. La captura aplica
las mismas reglas antes de leer un archivo del estado vivo.

El merge y el despliegue requieren autorización explícita del propietario de
acuerdo con `docs/spec/00-project-spec.md`. La petición actual autoriza el
diseño y la revisión cruzada. No autoriza todavía el merge ni el despliegue de
la implementación.

## Reversas

Cada componente tiene una reversa independiente:

- Sync: deshabilitar `GoncloudRepoSync` y restaurar la versión anterior del
  script desde la copia operativa.
- Deploy: restaurar los archivos reemplazados desde el staging del ciclo.
- Memoria: restaurar los snapshots previos de las bases de agentes y usar
  `provider: "none"` para búsqueda léxica. La reversa no vuelve al
  `llama.cpp` bloqueado.
- Nodo: detener `OpenClaw Node` y restaurar su XML anterior. El gateway no
  depende del nodo para responder mensajes.
- Limpieza: mover el artefacto desde cuarentena a su ruta registrada.

Ninguna reversa usa `git reset --hard` dentro del estado vivo.

## Resultado de la revisión cruzada

Grok revisó el commit `bf2b513` con
`/Users/dn/quality-kit/cross-review.ps1`. La revisión produjo estas
decisiones:

- Aceptado: el deploy pisaba una skill capturada pero todavía no mergeada. El
  diseño ahora protege las rutas pendientes y usa un worktree temporal.
- Aceptado: la reversa de memoria volvía al `llama.cpp` bloqueado y mezclaba
  identidades de índice. Ahora restaura snapshots y cae a búsqueda léxica.
- Aceptado: el diseño omitía el contrato del log, el vigía y el aislamiento de
  fallos de los otros tres repos. Ahora los conserva y versiona el cambio del
  vigía junto con el script.
- Rechazado como bloqueante reproducible: `origin/main` no conserva el timeout
  de 10 segundos. La lectura directa confirma `$httpTimeoutSec = 90`. Se añadió
  una compuerta para detectar una base futura equivocada.
- Verificado: OpenClaw `2026.9.5` ofrece `backup create --verify` con config,
  credenciales, sesiones y workspaces.
- Verificado: la configuración viva usa `memory.search`, y la versión instalada
  admite `provider`, `model` y `fallback`. El diseño añade validación y
  read-back antes del reinicio.

## Decisiones posteriores

Después de estabilizar este host, un diseño separado podrá migrar los tres
repos de workspace fuera de `.openclaw`. También podrá decidir si el archivo
de cuarentena se elimina o se conserva como backup offline. Ninguna de esas
decisiones bloquea este trabajo.
