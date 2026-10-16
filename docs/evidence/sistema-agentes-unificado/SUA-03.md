# SUA-03, recibo del bloque: los trabajadores

Bloque SUA-03 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md), hecho según su
[diseño](../../superpowers/specs/2026-10-14-sua-03-trabajadores-design.md). Las
mediciones viven en [SUA-03-mediciones.md](SUA-03-mediciones.md). R es el checkout de
integración de OpenClaw (`feat/agent-work-integration`). G es este repo.

## Qué entregó

Un encargo ya trae su trabajador puesto. El brief lleva `profile: <id>` en su
cabecera, el host lo admite o lo rechaza antes de lanzar, y cada corrida corre con
el paquete de poteto de su generación: sus skills, su adaptación y su bloque. En la
ruta por CLI el host lanza un proceso de opencode por encargo, con el repo o el clon
que el perfil manda. En las rutas nativas el paquete se publica en los agentes de la
Mini y el trabajo lo lanza OpenClaw.

## Estado por invariante

| Invariante | Estado | Dónde está la evidencia |
|---|---|---|
| I08 en la ruta por CLI y en el hijo de una CLI | **Cumplido.** Una generación sin certificar cierra la ruta (`generacion-no-certificada`) y una competence sin pasar cierra el perfil, salvo canario | `coverage.json` (`hostAdapterRoute` y `routes`) y SUA-03-mediciones.md, M-16 de las dos generaciones |
| I08 en las tres rutas nativas | **Aplazado a SUA-04, por diseño** (4.11, conflicto 4). La entrega y la conducta quedan medidas (M-17c y las 10 sondas de competencia), sin certificar; la ausencia no impide admitir la ruta en SUA-03 | Este recibo, la fila de followups de la competence por diseño y SUA-03-mediciones.md, M-17c |
| I09 | **Cumplido en lo que pide el diseño para SUA-03.** Cada perfil admite por ruta y por contrato, y una fuente vencida lo deja sin admitir sin tocar a los demás | `perfiles.v1.json` y las pruebas de contexto |
| I11 | **Cumplido.** Un bloque editado a mano es conflicto y no se pisa; una edición entre leer y aplicar es conflicto; revertir nunca deshace una edición posterior | Las pruebas de publicar-contexto y la ventana de publicación (gen1 y gen2 sin conflictos) |

## Las rutas

`coverage.json` registra las cinco rutas del diseño en `routes`, cada una con su
generación de contexto y su evidencia. `certified` solo es verdadero en las dos de
CLI. La sesión adoptada por el operador salió de `routes`: su fila quedó en
`migration` como retirada, en el formato de las filas que ya había.

## Los PR

| PR | SHA de merge | Qué trajo |
|---|---|---|
| #306 | `04bc0a0b` | G4: publicador nativo, perfiles en encargo-cli y hallazgos de #305 |
| #307 | `e5efd03e` | G5a: conducta nativa, extractor de la Mini y pendientes de G4 |
| #308 | `8c7b4835` | G5b: typedPayload validado en el host, banco como main y Minor de #307 |
| #309 | `f3143690` | G5c: M-16 completa y generación 1 de la ruta por CLI certificada |
| #312 | `7295d49e` | G5d: generación 2 (adaptación nativa) certificada y pendientes de #309 |
| #313 | `d7c0fab5` | G5e: medición nativa con herramientas de tool_search |

## Las mediciones

Todas en SUA-03-mediciones.md.

- **M-13** (sección M-13): la ruta por CLI con el paquete, antes de certificar
  generación alguna.
- **M-15** (control nativo): el control sin paquete, en rojo.
- **M-16, generación 1** (sección M-16): diez casos en dos corridas (corrida 5 +
  corrida 8), verde.
- **M-16, generación 2** (sección M-16, generación 2): diez casos en dos corridas,
  verde.
- **M-17** (generación 1): dos sondas rojas. Leían poteto, pero no el playbook ni
  `progress_card`. Eso motivó la generación 2.
- **M-17c** (generación 2): lee poteto, poteto-openclaw y
  `playbooks/bug-fix.md`, busca `progress_card` con `tool_search` y la usa, y el
  hijo corre y cita las pruebas. Su única razón roja es el paso 1 resumido, que el
  coordinador aceptó y quedó anotado. Su fixture es
  `scripts/tests/fixtures/conducta/m17c-ingenieria-nativo.jsonl`.

## Las sondas de competencia nativas

Las 10 sondas (cinco perfiles, positiva y negativa) salieron verdes, con 0
entregas y la memoria igual. La negativa de operaciones contestó FUERA-DE-PERFIL
pero investigó de más (26 `exec` fuera de perfil): quedó su fila en followups.

## La ventana en vivo

La ventana de publicación de las generaciones 1 y 2
(`ventana-gen1-aplicar.json` y `ventana-gen2-aplicar.json`): 0 conflictos, 19
`AGENTS.md`, y memoria, `USER.md` y `SOUL.md` iguales en los 19 workspaces. La
ventana dejó `brief.py` nuevo en la Mini y el host movido a `main`.

## agent-dispatch

Al publicar encargo-cli, `t12-skills-main-1.sh` pisó la copia viva de
`agent-dispatch` de `main` con la del repo. David la restauró a mano en la Mini
(sha256 `8aa19727ad9dc2b255b5c32a8e5bf0fc9d47fa67d56b2dd776a8e658163f7d01`) y
esa copia entró al repo en #312. Su fila quedó en followups.

## El canario A

Sí se ejecutó, el 2026-10-16. Un pedido a `main` con dos encargos en
`~/dev/canario-encargos`, mandado sin `--deliver`. Por CLI corrió entero:
`main` leyó encargo-cli, preparó con `--perfil ingenieria`, submitió y admitió, y
el host cerró en `acknowledged|AbsenceVerified` con su commit y su revisión. El
nativo entró por `sessions_spawn` con `agentId=ingenieria` y no como tarea
gestionada con `target.kind=agent`, que es la fila del diseño "Encargo nativo a
un agente": ese es el hallazgo del canario y pasa a SUA-04, con su fila en
followups. De avisos a David llegó 1 por Telegram; el segundo quedó como
respuesta sin canal, porque el pedido entró sin `--deliver`.

## Lo que no se hizo

- **La competence por diseño en nativo no se lee en nativo.** Es la decisión del
  diseño (4.4, 4.5 y 4.11, conflicto 4): la compuerta que la lea es el selector de
  SUA-04.
- **El rechazo por encargo en las rutas nativas** pide un cambio en R y queda para
  SUA-09O (4.11, conflicto 4).
