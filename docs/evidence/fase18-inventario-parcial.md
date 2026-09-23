# Fase 18.0: inventario parcial, sin acceso al gateway

Estado entre 2026-09-23 02:11 y 02:12 UTC: **18.0 en curso, no aceptada**. Este archivo
solo registra comprobaciones de lectura desde la Mac y referencias fechadas.
No contiene la configuración viva de Windows, credenciales, sesiones ni
transcripciones. No autoriza respaldo, desinstalación, corte o deploy.

## Fuentes y observaciones

| Dato | Fuente y método | Resultado |
|---|---|---|
| Ocho IDs y cadenas ordenadas históricas | `docs/patches/modelos-vivos-2026-09-15.json5`, contado con `jq` el 2026-09-23 02:11–02:12 UTC | La foto del 16 de septiembre declara `main`, `operaciones`, `ingenieria`, `implementer`, `reviewer`, `adversary`, `verifier` y `scout`, cada uno con un primary y siete fallbacks; incluye `agents.defaults.model`. No acredita el estado actual. |
| Referencia posterior | Captura aportada por David, 2026-09-19 | Muestra una cadena distinta de la foto anterior en varios agentes. No es exportación viva ni muestra todos los valores con fidelidad suficiente para aplicarlos. |
| Presencia del equipo | `tailscale status --json`, 2026-09-23 02:11–02:12 UTC | El peer configurado para el gateway aparece `online=true` y `active=true`. Esto no prueba que OpenClaw esté funcionando. |
| API del gateway | `openclaw gateway call health --json --timeout 10000` y prueba TCP de 3 s, 2026-09-23 02:11–02:12 UTC | La llamada no devolvió salud positiva y el puerto configurado no aceptó conexión. No se pudo consultar `config.get`. |
| SSH del equipo | Prueba TCP de 2 s y dos intentos `ssh -o BatchMode=yes` de solo lectura, 2026-09-23 02:11–02:12 UTC | El puerto acepta conexión, pero la autenticación de esta sesión fue rechazada. No se ejecutó ningún comando en Windows. |
| CLI en esta Mac | `openclaw gateway --help`, 2026-09-23 02:11–02:12 UTC | Versión local `2026.9.4`; no informa la versión instalada en Windows. |

## Datos que siguen `unknown`

- Versión, instalador dueño y ubicación reales de OpenClaw en Windows.
- Directorios de estado, configuración, agentes y workspaces; ediciones únicas
  fuera de Git; base compartida y bases por agente.
- Ocho cadenas vivas en orden, modelo por defecto, roles y disponibilidad real
  de cada proveedor. La foto histórica y la captura no sustituyen esta lectura.
- Servicios, tareas programadas, sync, canales, skills únicas y existencia de
  perfiles de autenticación. No se necesitan los valores de las credenciales.

## Para completar 18.0

Restablecer una vía de consulta de solo lectura al Windows vivo. Después,
exportar únicamente `agents.entries.*.model` y `agents.defaults.model` de
`config.get`, inventariar rutas, instalador, servicios, tareas, sync y archivos
únicos sin abrir secretos, y guardar el manifiesto detallado en un destino
privado. Comparar los ocho arreglos ordenados con ambas referencias fechadas.
Publicar aquí solo el recibo redactado con origen, hora y método de cada dato.
Las diferencias de modelos se presentan a David antes de cambiar el host.
Hasta entonces 18.0 sigue en curso y 18.1–18.5 no se inician.
