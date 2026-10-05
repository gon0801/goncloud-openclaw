# Política común para agentes OpenClaw y trabajadores CLI

Fecha: 2026-10-04. Estado: diseño contrastado; prototipo e implementación inicial
en desarrollo. Este documento no acredita instalación en el gateway.

## Problema

Una especialidad, un modelo y un ejecutor son decisiones distintas. Claw debe
asignar tareas a sus agentes especializados o a las CLI sin perder poteto-mode,
la especialidad, la evidencia ni el propietario del encargo. Las versiones de
modelos deben renovarse automáticamente para trabajo nuevo. Un agente recién
creado debe incorporarse al circuito y aparecer con su estado real.

La configuración viva es la autoridad sobre agentes y acceso. El repositorio
contiene política y código; sus JSON históricos no reconstruyen el gateway.
Los encargos nativos conservan admisión, hijos, consumo y presupuesto. Las
corridas conservan los adaptadores de CLI. Esta ampliación no crea otra cola.

## Uso desde el coordinador

Estas interfaces son el contrato propuesto, no comandos instalados:

```python
# El mantenimiento existente descubre y prepara una generación de configuración.
report = fleet.reconcile(observed, policy, evidence)
# Los propietarios actuales aplican las proyecciones y acreditan su lectura.

# Un pedido dirigido a Amazon conserva la identidad Amazon durante un fallback.
contract = fleet.contract(target=NativeAgent("amazon"), task=task, now=now)
native_owner.submit(task, contract)

# Ingeniería puede encargar un carril a una CLI mediante la corrida existente.
worker = existing_selector.select(request, health, history)
contract = fleet.contract(target=ExternalCli(worker.id), task=task, now=now)
corrida_owner.start(task, contract)
```

El resultado de `contract` es una asignación preparada o una razón concreta por
la que falta preparación. No sustituye a un especialista por otro sin registrar
una nueva decisión de delegación. Un relevo de modelo conserva la especialidad.

## Forma del dominio

```text
ExecutionTarget = NativeAgent(gateway, agentId)
                | ExternalCli(host, workerId)

Specialty = purpose + acceptedTaskKinds + excludedScope
          + tools + skillRefs + authoritativeSources + reviewedRevision

ModelEvidence = runtime + accountRef + provider + exactModelId + family
              + stableReleaseEvidence + successorOrder + capabilityProbe
              + runtimeRevision + observedAt + validUntil

InstructionBundle = canonicalPotetoDigest + platformMappingDigest
                  + specialtyDigest + taskRelevantSkills + deliveryEvidence

Assignment = target + taskId + exactModelId + generation
           + instructionDigest + acceptance + authorityRef

DiscoveredExecutor = Ready | NeedsProfile | NeedsAccess | NeedsInstructions
                   | NeedsRuntimeVerification

ReconcileReport = nativeProjection + cliProjection + perRuntimeStatus + gaps
```

Los adaptadores validan los datos externos. La política de promoción es pura.
Cada tarea fija modelo, generación y contrato al admitirse. Reanudar conserva
esa identidad; cambiarla requiere un relevo explícito con evidencia del runtime.
Un comando que anuncia una versión distinta de la que ejecuta es inválido.

La interfaz pública oculta interpretación de catálogos, preparación del contexto
y comprobación de generaciones. El llamador conserva el lanzamiento y ciclo de
vida porque ya tiene esas responsabilidades. La implementación de política no
necesita conocer SQLite interna, sesiones tmux ni detalles del transporte RPC.

## Decisión de la comparación

Se compararon dos diseños completos. A introduce una política común en cada
despacho nativo y CLI. B reconcilia política en configuraciones y contratos que
consumen los propietarios existentes. La revisión independiente puntuó B 26/30
y A 25/30. B es la base por conservar el selector y reducir las integraciones.

Se incorporan de A la cobertura de turnos nativos directos, la identidad fija
del especialista, el vínculo de modelo y contexto por intento y la visibilidad
de todos los agentes descubiertos. Se rechazan un nuevo orquestador y el uso de
un binario ficticio para representar agentes nativos.

Dos modelos alternativos no pudieron arrancar por capacidad del servicio. Los
candidatos finales y el contraste usaron el modelo disponible. La diversidad
de diseño es real; la diversidad de modelos fue reducida.

## Modelos que se renuevan sin cambiar tareas activas

El inventario se obtiene por runtime y cuenta. Acceso mediante una suscripción
CLI no demuestra acceso al mismo proveedor desde OpenClaw. El catálogo admite
cualquier familia descubierta; cada adaptador declara qué evidencia entiende.

Una promoción exige sucesión estable acreditada, acceso, herramientas y prueba
de la especialidad. Se compara orden de versiones documentado por el adaptador,
nunca números flotantes ni orden alfabético. Un alias `latest` no acredita una
versión inmutable. Si faltan estabilidad u orden, el candidato queda visible
con esa carencia y se conserva el último modelo verificado.

La promoción cambia tanto la configuración efectiva nativa como el comando
efectivo CLI según corresponda. Se registran los IDs anterior y nuevo, evidencia
y motivo. No se hacen parches independientes en cada turno ni se reinicia un
gateway ocupado para cambiar modelos. Se usa revisión de configuración,
dry-run, aplicación agrupada y lectura posterior por el mecanismo existente.

La renovación automática requiere conectar la reconciliación al propietario de
mantenimiento real. El primer prototipo no prueba ese cableado. Fase F.2 debe
identificar su entrada y demostrar una promoción sin editar versiones a mano.

## Agentes nuevos conectados

Se compara el inventario configurado, el inventario publicado y los destinos
admitidos del despachador. Ningún agente desaparece del informe por carecer de
perfil. Un agente nuevo recibe estado y causa; un perfil válido, herramientas
disponibles y entrega comprobada permiten integrarlo automáticamente.

La reconciliación prepara solo las aristas de delegación declaradas por el
perfil. Descubrir un agente no concede acceso a todos los demás. El alta incluye
una prueba de despacho y retorno por la ruta correspondiente. Los encargos
gestionados conservan su cobertura certificada y no se activan por inferencia.

## Poteto obligatorio y especialización limpia

Cada ejecutor recibe poteto-mode canónico, su adaptación y las skills requeridas
por el playbook y dominio. Las skills adicionales se cargan bajo demanda. Una
tarea de correo no hereda toda la conversación de main ni instrucciones de
deploy. Las herramientas exigidas por el playbook deben existir en ese runtime.

Se comprueba la entrega en turno directo, spawn nativo, encargo gestionado,
arranque CLI, reanudación y subagentes CLI. Encontrar el nombre de la skill en
un archivo no acredita esa cobertura. Un adaptador sin prueba de herencia no
anuncia que sus hijos cumplen poteto. La comprobación demuestra entrega y
ejecución observable, no obediencia infalible del modelo.

Cada especialidad conserva fuentes con revisión y caducidad. Al cambiar una
fuente se reevalúa solo el contexto afectado. Los archivos generados tienen
propietario y digest. La limpieza retira únicamente contenido administrado
obsoleto; no elimina memorias, instrucciones del usuario ni historial vivo.
La ausencia o caducidad de evidencia bloquea nuevas promociones, sin impedir
que el operador repare la flota con las herramientas administrativas existentes.

## Propiedad, publicación y recuperación

- `scripts/mac/corrida_worker/` conserva validación y selección CLI.
- El contrato de encargos existente conserva admisión y estado nativos.
- La política común calcula proyecciones y motivos; no ejecuta trabajo de negocio.
- El adaptador de gateway lee configuración viva y escribe solo campos administrados.
- Cada runtime tiene generación activa y recibo propios. Un fallo de publicación
  nativa no se declara resuelto porque el registro CLI sí se escribió.
- La allowlist de sync seguro no se amplía de forma implícita. Publicar contexto
  para agentes adicionales exige incorporar explícitamente esos destinos al
  mecanismo de publicación y probar aislamiento y preservación de archivos.

## Evidencia y dudas que requieren prototipo

La lectura viva posterior confirmó 19 agentes y las 19 aristas de main. La
primera lectura devolvió ocho. No se reprodujo un fallo persistente del listado;
no se atribuye esa diferencia a caché o recarga sin evidencia adicional.

La muestra de cinco especialistas y main tiene AGENTS.md y SOUL.md, sin mención
de poteto/pstack. Además, `skills.status` devuelve `disabled=true` y
`eligible=false` para `Poteto Mode` en los seis. La configuración contiene
`skills.entries["Poteto Mode"].enabled=false`. La skill existente está bajo
`skills/grok/pstack/poteto-mode`; no se asume equivalente a la versión canónica
local ni compatible con herramientas nativas sin revisar su contenido. Falta
observar el prompt efectivo. Los documentos de los especialistas muestreados
son cortos; no se justifica borrarlos por tamaño.

El inventario de modelos observado devuelve 82 filas con ID, nombre, entrada,
contexto, disponibilidad y etiquetas. No trae campos explícitos de fecha de
publicación, estabilidad u orden de sucesión. El adaptador debe obtener esa
evidencia antes de promover; el prototipo la recibe como dato comprobable.

Experimentos de aceptación:

1. Introducir un sucesor estable verificado cambia primary y argv de trabajo
   nuevo; las reanudaciones conservan el modelo anterior.
2. Un modelo preview, sin acceso, de otra cuenta o con prueba vencida no se promueve.
3. Un agente añadido después de la primera generación aparece en el informe;
   con perfil válido queda conectado, sin perfil muestra la carencia.
4. El contexto entregado contiene poteto y la especialidad correcta, sin skills
   ajenas. Una fuente vencida invalida solo el contexto afectado.
5. Dos reconciliaciones equivalentes no producen cambios adicionales.
6. Un fallo entre aplicación y lectura no activa una generación no acreditada.
7. Turno directo, spawn, encargo y reanudación prueban entrega efectiva del contrato.

## Próximo cambio

Corregir primero la discrepancia verificable entre modelo declarado y argv CLI,
con una prueba de regresión. Usar el prototipo para fijar los contratos antes de
conectar renovación, contexto y publicación a los propietarios vivos.
