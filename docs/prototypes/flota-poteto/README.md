# Prototipo de reconciliación de la flota

Experimento ejecutable de la arquitectura de
[flota poteto](../../superpowers/specs/2026-10-04-flota-poteto-design.md).
No se importa desde el runtime ni modifica el gateway.

```sh
python3 -m unittest discover -s docs/prototypes/flota-poteto -v
```

`fleet.py` calcula proyecciones nativas y CLI, contratos, diferencias y carencias.
`test_fleet.py` contiene nueve pruebas de comportamiento. La promoción de
versión `(1, 9)` a `(1, 10)` modifica el primary nativo y el modelo y argv CLI.
`projection-evidence.json` contiene las salidas del experimento.

Las pruebas cubren incorporación posterior de agentes, perfiles ausentes,
contexto de especialidad, evidencia vencida, repetición sin diferencias,
modelo fijado por sesión y fallo de activación nativa independiente de CLI.

## Qué demuestra

Una política puede producir configuraciones distintas para los dos runtimes
sin convertir al agente nativo en una CLI ficticia. Los recibos separados
permiten representar activación parcial. Un único modelo resuelto puede
generar metadatos y argumentos consistentes.

## Qué no demuestra

- Los formatos son estructuras normalizadas de prueba, no el esquema de
  configuración de OpenClaw ni el registro de producción `workers.v1`.
- Poteto y las adaptaciones son cadenas de prueba. Se prueba su propagación,
  no la resolución de la skill canónica ni sus dependencias reales.
- El catálogo, orden de versiones y pruebas de acceso son datos simulados.
  No hay consulta automática a proveedores ni validación de credenciales.
- La aplicación y la lectura posterior ocurren en memoria. No hay escritura
  RPC, concurrencia, recuperación de disco ni comprobación de recarga segura.
- Los recibos se confían al llamador. El despacho real debe acreditar entrega
  en turnos directos, hijos, arranques y reanudaciones.
- La renovación del prototipo no tiene un propietario periódico conectado.
- Duplicados, rutas ambiguas, plantillas maliciosas y varias cuentas con el
  mismo ID necesitan validación en los adaptadores de producción.
- Los contratos vencidos detienen también la reanudación del experimento.
  La política de recuperación viva debe conservar acceso administrativo.

Estos límites son trabajo pendiente de integración. Un resultado verde aquí
no acredita que la flota viva aplique poteto o renueve modelos automáticamente.
