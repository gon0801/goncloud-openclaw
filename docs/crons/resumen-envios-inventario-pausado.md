# Inventario de la configuración pausada de resúmenes de envíos y plan de retorno

Estado verificado en solo lectura el 2026-11-18 sobre `Gons-Mac-Mini` y `gonserver`. Los seis trabajos programados de empaque siguen desactivados (`enabled = 0`) desde `2026-11-19T01:11:37Z` hasta `2026-11-19T01:11:50Z`. Este documento registra horarios, fuentes, destinatarios, reglas vigentes al pausar, defectos medidos, procedimiento de retorno sin pérdida de recibos y evaluación de la propuesta pendiente en el PR 386.

La huella completa de archivos y trabajos queda en `docs/evidence/packing-configuracion-pausada-2026-11-18.json`.

## 1. Horarios y trabajos pausados en el gateway

Todos los trabajos estaban programados en `America/Mexico_City` (UTC-6 fijo todo el año). Esa zona coincide con `18:00`, `18:15`, `18:30`, `05:00` y `09:00` de `America/Vancouver` únicamente durante el horario estándar de invierno (PST, UTC-8). Durante el horario de verano en Vancouver (PDT, UTC-7, de marzo a noviembre), los cortes corrían una hora tarde respecto de Vancouver (`19:00`, `19:15`, `19:30`, `06:00` y `10:00`). El gateway ya soporta `tz: "America/Vancouver"` de forma nativa en `cron_jobs` (verificado en `aviso-diario-resurtido`).

| Nombre en `cron_jobs` | `job_id` | Estado | Agente | Expresión actual (`America/Mexico_City`) | Equivalente en invierno (`America/Vancouver`) | Tope (s) | Última corrida medida |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `packing-digest-faseA-censo` | `f4b33b14-8af2-487c-82d8-10fa103ca9a3` | `0` | `operaciones` | `0 20 * * 0-4` | Dom a jue `18:00` | `3000` | `2026-11-18T02:00:00Z` (`2695.3 s`) |
| `packing-digest-faseB-armado` | `3feb7c34-3fba-42f3-96db-c770ff5abd60` | `0` | `operaciones` | `15 20 * * 0-4` | Dom a jue `18:15` | `3300` | `2026-11-18T02:15:00Z` (`1795.5 s`, espera hasta `02:44:55Z`) |
| `packing-digest-faseC-envio` | `7ad289a8-6c80-44f0-8bc4-220ba5e051e3` | `0` | `operaciones` | `30 20 * * 0-4` | Dom a jue `18:30` | `3600` | `2026-11-18T02:30:00Z` (`1364.1 s`, cierra `02:52:44Z`) |
| `packing-extras-7h` | `7bb5fac4-a1bb-4b85-b4ed-7ceeb187cbc3` | `0` | `operaciones` | `0 7 * * 1-5` | Lun a vie `05:00` | `3600` | `2026-11-18T13:00:00Z` (`262.7 s`) |
| `packing-extras-11h` | `9386486d-37d6-4ae1-bf7b-12892527f2d9` | `0` | `operaciones` | `0 11 * * 1-5` | Lun a vie `09:00` | `3600` | `2026-11-18T17:00:00Z` (`85.0 s`) |
| `verif-digest-20h` | `0aa73c30-19b4-4f06-ac8e-6661a7e1dfb3` | `0` | `main` | `35 21 * * 0-4` | Dom a jue `19:35` | `600` | `2026-11-18T03:35:00Z` (`21.6 s`) |

### Causa medida del retraso en el corte principal

En las dos últimas corridas nocturnas registradas en `cron_run_receipts`, `packing-digest-faseA-censo` tardó `2760.4 s` el 16 de noviembre y `2695.3 s` el 17 de noviembre. Las marcas de tiempo en `workspace-operaciones/packing/tmp/` para `D=2026-11-18` muestran dónde se consumió ese tiempo:

- `meli_census_2026-11-18.raw.txt` terminó en `1 min` (`02:01Z`).
- `census_v2_2026-11-18.raw.txt` terminó en `2 min` (`02:02Z`).
- `census_sc_2026-11-18_20h.json` tardó `11 min` leyendo las colas del navegador (`02:13Z`).
- `details_2026-11-18_20h.json` tardó `30 min` adicionales abriendo de forma secuencial el detalle de cada pedido en Seller Central y Seller Flex (`02:43Z`).
- `faseA_2026-11-18.json` se marcó con `completo: true` recién a las `02:44:16Z` (`18:44` de Vancouver). Como `fase_wait_artefacto.sh` bloqueaba las fases B y C hasta ver `completo: true`, el resumen no pudo armarse a las `18:15` ni enviarse a las `18:30`.

## 2. Fuentes, rutinas y agentes existentes

### Fuentes consultadas por la configuración pausada

- **Corte principal (`faseA` + `faseB`):** leía seis colas `unshipped` y `pending` de Seller Central (`MX Easy Ship`, `MX Self Ship`, `US Self Ship`) y el panel `sellerflex.amazon.com.mx` con el perfil de navegador `claw`. No abría la vista `orders-v3/mfn/shipped/easyship`; dependía de la sección `Q3` de `census_v2_pipe.sh` en PostgreSQL de Odoo para descubrir órdenes Easy Ship con guía ya comprada. Para Mercado Libre ejecutaba `meli_census_directo.py` contra la API oficial, aunque obtenía y rotaba su token leyendo y escribiendo `res_company` en la base de Odoo. Para traducir SKUs internos consultaba `sale_order_line` en Odoo mediante `decode_run_<D>.sh`.
- **Repasos (`packing-extras-7h` v16 y `packing-extras-11h` v16):** seguían ejecutando `census_v2_pipe.sh` (`Q1`, `Q2`, `Q2b` y `Q3` en Odoo) como fuente decisoria tanto para Mercado Libre como para el cruce de Amazon Easy Ship, en contradicción con la regla del propio `RUNBOOK-20h.md`.

### Rutinas y agentes disponibles para reutilizar

- **Agentes configurados en `openclaw.json`:** `operaciones` (`anthropic/claude-sonnet-5-5` con cadena de respaldo), `amazon`, `meli`, `odoo`, `pers`, `mail` y `main` (`anthropic/claude-opus-5-5`). Sus latidos periódicos (`heartbeat-*`) están desactivados (`enabled = 0`).
- **Helpers de transporte en `gonserver`:** `/home/claw/send_sales_digest.sh` (`2335` bytes, idéntico a `scripts/gonserver/send_sales_digest.sh` en `main`) envía texto HTML hasta `4096` caracteres a David e Isabel verificando `ok: true` y `message_id`. `/home/claw/packing/send_pers_photo.sh` corre en versión `v3` (`5751` bytes, frente a `v2` de `4714` bytes en `main`), protege con `flock` sobre `personalizadas-sent.lock`, soporta `PERS_DRYRUN=1` y reintenta solo los índices faltantes en `partial`.
- **Skills operativas en `agents/operaciones/agent/workshop-skills/`:** `browser-cli-claw-profile` (uso exclusivo de `--browser-profile claw` sin concurrencia sobre la misma sesión), `gmail-compose-rich-mail` (inyección TrustedTypes y verificación en `#drafts` y `#sent`), `telegram-send-gonserver` y `sellercentral-browser-census/customization-capture.md` (descarga inmediata del preview presignado de S3 en fragmentos dentro de la ventana de 60 segundos).

## 3. Destinatarios y reglas vigentes al pausar

| Situación | Correo (`ehventasmx@gmail.com`) | Telegram David (`TELEGRAM_CHAT_ID`) | Telegram Isabel (`TELEGRAM_CHAT_ID_2`) | Telegram Jorge (`TELEGRAM_CHAT_ID_CUSTOM`) |
| --- | --- | --- | --- | --- |
| Principal con pedidos | 1 correo HTML combinado (Amazon y ML) | Partes `1..N` (`N <= 50`) | Partes `1..N` (`N <= 50`) | No recibe resumen general |
| Principal completo con 0 pedidos | Sin correo | Aviso corto de 1 parte (`Sin pedidos por empacar para <día y fecha>`) | Aviso corto de 1 parte | No recibe nada |
| Repaso (`05:00` o `09:00`) con extras Amazon (con o sin ML) | 1 correo HTML con los extras | Digest de extras | Digest de extras | No recibe resumen general |
| Repaso con extras solo de Mercado Libre | Sin correo | Digest de extras | Digest de extras | No recibe resumen general |
| Repaso completo con 0 extras | Sin correo | Silencio total | Silencio total | No recibe nada |
| Fotos de personalizadas Amazon | No aplica | `sendPhoto` 5 min después del resumen | `sendPhoto` 5 min después del resumen | `sendPhoto` 5 min después del resumen |

### Brechas y defectos verificados frente al pedido

1. **Sin resúmenes parciales ante fallo o lentitud:** cualquier error o demora en una fuente marcaba `abort: true` o `FASE_TIMEOUT` y detenía todo el envío, en lugar de entregar lo comprobado con aviso de `Resumen parcial` o avisar revisión incompleta cuando había cero pedidos comprobados.
2. **Bloqueo de repasos cuando falta el corte principal:** `packing-extras-7h` y `packing-extras-11h` abortaban en el paso 0 si no existía el par `<D>-amazon.html` y `<D>-meli.html` con fecha de hoy.
3. **Omisión de `MERCADO LIBRE - POR CONFIRMAR ENVÍO` en el armado nocturno:** `build_faseb_v7.py` contabilizaba `meli_resumen.por_confirmar` en el pie, pero solo iteraba `A["meli_por_empacar"]` y nunca agregaba las ventas por confirmar envío al resumen ni al HTML.
4. **Falta de filtrado por plazo y colisión de cuenta norteamericana:** en `faseA_2026-11-18.json` y `faseB_2026-11-18.json` entraron como pedidos del 18 de noviembre la orden Easy Ship `702-8735850-8955443` con `shipby = 2026-11-20`, dos órdenes Flex en pago pendiente con espera del `19 Nov` y `20 Nov`, y el pedido estadounidense `113-2115206-6486654` (`canal = Amazon.com`, `shipby = null`) clasificado por error en `AMAZON SELF SHIP MX` con fecha adivinada `mié 18-nov`.
5. **Pérdida de líneas múltiples, cantidades y SKU de plataforma:** `build_faseb_v7.py` usaba `dec.setdefault(order, sku)`, descartando segundas líneas y cantidades. Cuando Odoo aún no tenía el pedido o la equivalencia (por ejemplo en pago pendiente o ventas recientes `113-2115206-6486654`, `2000019620933784` y `2000019623411400`), imprimía `SKU: pendiente de decode` ocultando el SKU real de la plataforma (`BV-ZFT8-7LO8`).
6. **Repetición de atrasados ya comunicados y marcas gruesas de entrega:** en el principal se volvían a listar ventas de Mercado Libre ya comunicadas en noches previas con la etiqueta `(atrasado)`. En `faseC_marca.sh` solo se guardaban tres banderas globales por día (`telegram`, `mail`, `fotos`), sin distinguir destinatario, parte ni pedido, y en `personalizadas-sent.json` una orden con dos artículos personalizados exigió crear a mano la clave `702-2506388-8128230-marco2`.
7. **Límite de 50 partes sin salida controlada:** `build_faseb_v7.py` ejecutaba `assert len(parts) <= 50`, abortando con excepción en vez de enviar hasta 50 partes sin cortar bloques y señalar los pedidos restantes como pendientes.

## 4. Cómo volver a la configuración pausada sin perder el registro de entregas

### Registros vivos que nunca deben sobrescribirse ni borrarse

1. `/Users/gon/.openclaw/workspace-operaciones/envios-del-dia/<D>-amazon.html` y `<D>-meli.html` (pares base nocturnos, con comentario `<!-- meli_order_id=<id_interno> -->` en cada tarjeta de Mercado Libre).
2. `/Users/gon/.openclaw/workspace-operaciones/envios-del-dia/<D>-extras-amazon.html`, `<D>-extras-meli.html`, `<D>-extras11-amazon.html` y `<D>-extras11-meli.html` (historial de repasos matutinos).
3. `/Users/gon/.openclaw/workspace-operaciones/packing/tmp/faseC_marcas/<D>_{telegram,mail,fotos}.done` (marcas horarias e identificadores de mensaje del corte principal).
4. `gonserver:/home/claw/packing/personalizadas-sent.json` y su cerrojo `personalizadas-sent.lock` (71 envíos confirmados al `2026-11-18T02:52:30Z`).
5. `/Users/gon/.openclaw/state/openclaw.sqlite`, tablas `cron_jobs`, `cron_run_receipts` y `cron_job_scratch`.

### Reglas de coexistencia y procedimiento de retorno

1. **Aislamiento durante ensayos y operación nueva:** los ensayos escriben únicamente en directorios de prueba o vista previa fuera de `envios-del-dia/`, `faseC_marcas/` y `personalizadas-sent.json`. Cuando en una futura activación autorizada corra el nuevo coordinador, su bitácora transaccional vivirá en un archivo propio por fecha (`packing/estado/<D>-ledger.json`) sin borrar los HTML ni `personalizadas-sent.json`.
2. **Puente de compatibilidad hacia atrás:** cualquier entrega real que confirme la versión nueva después de su futura aprobación deberá reflejar también los bloques confirmados en los artefactos legados (`<D>-amazon.html`, `<D>-meli.html` o `<D>-extras*.html` con `<!-- meli_order_id=... -->`) y las fotos confirmadas a los tres destinatarios en `personalizadas-sent.json` bajo `flock`.
3. **Pasos exactos para revertir a la configuración pausada si fuera necesario tras una activación futura:**
   - Paso 1. Poner `enabled = 0` en las rutinas nuevas propuestas y verificar que no haya corridas en curso en `cron_run_receipts`.
   - Paso 2. Respaldar `packing/estado/<D>-ledger.json`, `envios-del-dia/` y `gonserver:/home/claw/packing/personalizadas-sent.json` con marca de tiempo sin truncar nada.
   - Paso 3. Conciliar el día en curso `D` exportando desde `packing/estado/<D>-ledger.json` únicamente los pedidos cuya entrega ya esté confirmada en todos los canales previstos hacia `<D>-amazon.html`, `<D>-meli.html` o `<D>-extras*.html`, y dejando documentada cualquier diferencia por destinatario individual antes de reanudar.
   - Paso 4. Verificar que los seis trabajos originales conservan sus `job_id` y `message_sha256` registrados en `docs/evidence/packing-configuracion-pausada-2026-11-18.json` y que `/home/claw/send_sales_digest.sh` y `/home/claw/packing/send_pers_photo.sh` mantienen compatibilidad con llamadores sin variables nuevas (`TG_SOLO_CHATS` vacío conserva el envío dual clásico).
   - Paso 5. Rehabilitar únicamente los trabajos originales que el propietario indique (`f4b33b14-8af2-487c-82d8-10fa103ca9a3`, `3feb7c34-3fba-42f3-96db-c770ff5abd60`, `7ad289a8-6c80-44f0-8bc4-220ba5e051e3`, `7bb5fac4-a1bb-4b85-b4ed-7ceeb187cbc3`, `9386486d-37d6-4ae1-bf7b-12892527f2d9`, `0aa73c30-19b4-4f06-ac8e-6661a7e1dfb3`).

## 5. Revisión de la corrección pendiente del repaso de las 09:00 (PR 386)

Se inspeccionó en solo lectura la rama `origin/encargo/enc_4d384e148abccc69` (PR 386, commit `1890868f3f0313fe6b72f3c149d1672e86bdd622`). El PR sigue abierto, no está integrado en `main` y no está aplicado en el gateway (`packing-extras-11h` sigue en `v16` pausado) ni en `gonserver` (`send_sales_digest.sh` sigue en `2335` bytes). No se modifica el PR 386 ni se importa su contenido en bloque.

### Qué se reutiliza en nuestra propuesta

1. **Cobertura directa de Easy Ship con guía generada:** consultar en Seller Central `orders-v3/mfn/shipped/easyship?shipByDate=all&page=1` con paginación completa, incluir solo los pedidos que sigan pendientes de recolección o entrega a paquetería (`Waiting for Pick Up` o `Pending Drop off`) dentro del plazo del corte, indicar cuál de las dos acciones pide Amazon y excluir `Picked Up`, `Dropped off`, entregados y cancelados.
2. **Envío selectivo por destinatario en Telegram (`TG_SOLO_CHATS`):** extender el envío por chat individual de forma retrocompatible para que cuando David y correo ya recibieron `A` e Isabel no, al llegar `B` se envíe solo `B` a David y correo mientras Isabel recibe `A` y `B`.
3. **Recibos vinculados a contenido y bloqueo de estados inciertos:** asociar cada recibo a los identificadores estables y huellas efectivamente entregados a cada destinatario, e impedir cualquier reenvío automático cuando un intento quedó `en_curso` o `indeterminado` hasta verificar si llegó o dejarlo pendiente de conciliación.

### Qué se descarta del PR 386 y cómo se resuelve

| Aspecto en el PR 386 | Por qué no cumple el pedido actual | Solución en nuestra propuesta |
| --- | --- | --- |
| Prohibición total de consultar Odoo incluso para decodificar SKU | El pedido reserva a las plataformas la elegibilidad, plazos y estados, pero autoriza usar Odoo para cotejar la equivalencia del SKU interno | Consultar Odoo en solo lectura únicamente para mapear `SKU de plataforma -> SKU interno`, mostrando el SKU de plataforma y `SKU interno por confirmar` cuando no haya equivalencia confirmada |
| Aborto (`FALLO_EXPLICITO`) cuando falta el par nocturno `<D>-amazon.html` / `<D>-meli.html` | El pedido exige que los repasos recuperen pedidos aunque falte la lista del corte principal | Permitir a los repasos recuperar pedidos elegibles sin par principal; si tampoco se puede comprobar qué se entregó antes, marcar `pendiente de conciliación` sin reenviar a ciegas |
| Rechazo de envíos parciales si falla una fuente | El pedido permite enviar la parte comprobada con aviso visible de `Resumen parcial` y aviso de revisión incompleta si hay 0 pedidos comprobados | Modelar cada fuente como `completa_con_pedidos`, `completa_sin_pedidos` o `incompleta` (con alcance verificado, faltante y motivo), emitir `Resumen parcial` cuando proceda y nunca marcar completo un corte parcial |
| Detención del pedido personalizado si falta la imagen previa | El pedido ordena incluir el pedido en la lista con `Personalización incompleta: falta imagen` y mandar después solo la foto recuperada | Separar la comunicación del bloque del pedido y la obligación de cada foto personalizada para recuperar luego únicamente la imagen faltante sin repetir el pedido |
| Un solo intento/recibo de personalizada por `order_id` y sin seguimiento de partes `1..50` | Un pedido puede traer varias líneas personalizadas (`702-2506388-8128230` en producción) y un resumen largo se divide en hasta 50 partes sin cortar bloques | Identificar cada línea personalizada como `(plataforma, cuenta, pedido, linea)` y registrar confirmación por destinatario, parte (`1..50`) y foto bajo cerrojo de ejecución única |
| Prueba de texto `test-packing-extras-11h.sh` con 46 expresiones regulares sobre el prompt | Las reglas del repositorio prohíben baterías de texto sobre prompts y piden comprobar comportamiento real | Comprobar en la siguiente fase el comportamiento ejecutable de los cortes, entregas diferenciales y modos de fallo sin envíos reales |
