# Avisos claros: mutantes

Cada fila rompe una regla del cambio a propósito y anota qué prueba lo detecta.
Los de `tablero-runbook/` se corrieron con `node --test <archivo de prueba>` y el del
latido con `bash scripts/tests/test-corrida-latido.sh`; todos se revirtieron.

| Mutante | Archivo | Prueba que falla |
| --- | --- | --- |
| La lista ignora que la corrida de un archivo de fase ya cerró | `seguimiento.ts` | las dos de "a phase file naming a corrida … closed" |
| El aviso inmediato vuelve a mandar todo el paquete | `seguimiento-clock.ts` | "when one pending item changes its text, only that one is sent" |
| El corte sale aunque no haya novedad | `seguimiento-clock.ts` | "without news a due tick stays silent; the heartbeat goes out four hours after the last cut" |
| No se quita el código inicial de una parte | `seguimiento-render.ts` | "renders the real 60-line case in six plain lines, byte for byte" |
| El trabajo rancio se firma con su fecha | `seguimiento-clock.ts` | "a stale job is asked once while it stays stale, whatever its date says" |
| La novedad ignora las partes atoradas | `seguimiento-clock.ts` | "a part getting stuck or unstuck is news" |
| Se listan todas las partes pendientes | `seguimiento-render.ts` | "with several pending parts names only the next one" |
| Un scratch viejo no cuenta su paquete como avisado | `seguimiento-clock.ts` | "a scratch saved before per-item signatures counts its whole bundle as already sent" |
| Otro aviso confirmado borra la lista de pendientes ya avisados | `seguimiento-clock.ts` | "another immediate notice confirmed in between keeps the items already delivered" |
| La novedad ignora que el avance dejó de ser verificable | `seguimiento-clock.ts` | "an advance that stops being verifiable, or becomes verifiable again, is news" |
| El vigilante de silencio conserva el umbral de 25 minutos | `scripts/mac/corrida/latido.sh` | caso "callado 1900" de `scripts/tests/test-corrida-latido.sh` |
| El umbral de silencio queda por debajo del plazo del latido | `scripts/mac/corrida/latido.sh` | caso "callado 14160" de `scripts/tests/test-corrida-latido.sh` |
