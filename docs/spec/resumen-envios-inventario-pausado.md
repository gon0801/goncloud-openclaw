# Inventario pausado de resúmenes de envíos

Estado: inventario en solo lectura para la propuesta. No se activó, editó o ejecutó ningún trabajo. Los seis trabajos originales tenían `enabled_db = 0` y `enabled_json = false` al comprobarlos. La evidencia estructurada está en `docs/evidence/resumen-envios-inventario-pausado.json`.

## Trabajos y ejecución real

| Trabajo | ID | Programación cruda | Última ejecución observada |
| --- | --- | --- | --- |
| `packing-digest-faseA-censo` | `f4b33b14-8af2-487c-82d8-10fa103ca9a3` | `0 20 * * 0-4`, `America/Mexico_City` | 02:00:00Z a 02:44:55Z |
| `packing-digest-faseB-armado` | `3feb7c34-3fba-42f3-96db-c770ff5abd60` | `15 20 * * 0-4`, `America/Mexico_City` | 02:15:00Z a 02:44:55Z |
| `packing-digest-faseC-envio` | `7ad289a8-6c80-44f0-8bc4-220ba5e051e3` | `30 20 * * 0-4`, `America/Mexico_City` | 02:30:00Z a 02:52:44Z |
| `packing-extras-7h` | `7bb5fac4-a1bb-4b85-b4ed-7ceeb187cbc3` | `0 7 * * 1-5`, `America/Mexico_City` | 13:00:00Z a 13:04:22Z |
| `packing-extras-11h` | `9386486d-37d6-4ae1-bf7b-12892527f2d9` | `0 11 * * 1-5`, `America/Mexico_City` | 17:00:00Z a 17:01:25Z |
| `verif-digest-20h` | `0aa73c30-19b4-4f06-ac8e-6661a7e1dfb3` | `35 21 * * 0-4`, `America/Mexico_City` | 03:35:00Z a 03:35:22Z |

La conversión debe usar `America/Vancouver` directamente. `zoneinfo` y `/usr/sbin/zdump` del host confirman PST UTC−08 en noviembre de 2025, PDT UTC−07 desde el 8 de marzo de 2026 y MST UTC−07 desde el 1 de noviembre de 2026. Un offset fijo o una conversión mediante Ciudad de México no representa esas reglas.

Los recibos de A, B y C muestran que B y C esperaron el artefacto completo de A. El envío terminó 22 minutos después de su inicio y más tarde del corte funcional previsto. Esto describe esas corridas; no mide todavía el diseño propuesto.

## Sistemas y propietarios actuales

- Seller Central y Seller Flex se leen mediante el perfil de navegador `claw`. Una sola sesión puede manejarlo, por lo que el nuevo coordinador debe serializar también las lecturas y Gmail.
- Mercado Libre dispone de un censo mediante API. Odoo interviene en equivalencias y en infraestructura de credenciales del censo anterior; no debe convertirse en fuente de elegibilidad.
- `build_faseb_v7.py` arma HTML y partes desde los artefactos de fase A. El ensayo aislado con datos ficticios reprodujo dos diferencias frente al encargo: un pedido ML «por confirmar» se cuenta pero no se muestra, y un `ship-by` ilegible se sustituye por la fecha del corte.
- Gmail comprueba Enviados y borradores. El cierre del compose no es un recibo.
- El helper instalado de Telegram envía a David e Isabel y obtiene `message_id`, pero no selecciona destinatario. El helper instalado de fotos usa `flock` y recibos parciales por índice; difiere de la versión del repositorio y no debe sobrescribirse.
- El vigía y las fases antiguas no representan «Resumen parcial» ni cobertura por destinatario y parte. No son una base suficiente para el cierre nuevo.

## Registros que se conservan

- `workspace-operaciones/envios-del-dia/`: 179 archivos observados. Sirven como evidencia histórica, no como recibo fiable por destinatario.
- `workspace-operaciones/packing/tmp/faseC_marcas/`: 60 marcas por fecha y canal.
- `gonserver:/home/claw/packing/personalizadas-sent.json`: 71 entradas con tres formas históricas. Se importará como evidencia sin reescribir el archivo.
- `openclaw.sqlite`, incluidos `cron_jobs`, `cron_run_receipts` y `cron_job_scratch`.
- No existía `workspace-operaciones/packing/estado`; no se creó durante el inventario.

Cuando una evidencia histórica no prueba pedido, destinatario, parte y línea, la propuesta la marca ambigua o pendiente de conciliación. No la convierte en confirmación ni la reenvía como si fuera nueva.

## Destinatarios para cotejar antes de una activación

Se conservan como alias, sin publicar identificadores de chat:

| Parte | Operación por correo | David | Isabel | Jorge |
| --- | --- | --- | --- | --- |
| Principal con pedidos | Sí | Resumen | Resumen | No |
| Principal completo sin pedidos | No | Aviso corto | Aviso corto | No |
| Repaso con extras Amazon | Sí | Resumen | Resumen | No |
| Repaso con extras solo ML | No | Resumen | Resumen | No |
| Repaso completo sin extras | No | No | No | No |
| Fotos personalizadas | No | Foto | Foto | Foto |
| Revisión incompleta sin pedidos comprobados | Propuesta: no | Propuesta: aviso | Propuesta: aviso | No |

La última fila requiere aprobación explícita porque la configuración pausada solo alertaba a David y ese comportamiento no satisface el nuevo aviso operativo.

## Retorno mínimo

La propuesta no cambia la configuración en vivo. Si una activación futura autorizada necesita deshacerse, se detienen las rutinas nuevas y se mantienen o dejan en `enabled = 0` los seis trabajos originales juntos. Se conservan sin truncar `envios-del-dia`, `faseC_marcas`, `personalizadas-sent.json` y `openclaw.sqlite`. No hay otro procedimiento de restauración en esta propuesta.

## Evidencia todavía faltante

No se consultaron pedidos actuales durante el inventario arquitectónico. Los artefactos históricos permiten construir adaptadores y fixtures anonimizados, no certificar el estado presente de las plataformas.

Tampoco hay tiempos reales suficientes de preparación y recolección para recomendar 09:00 o 11:00 como demostrado. La propuesta debe medir ambos márgenes sin envíos y dejar la elección final al propietario si falta evidencia.
