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
| I08 en las tres rutas nativas | **Aplazado a SUA-04, por diseño** (4.11, conflicto 4). Entrega y conducta quedan certificadas; la ausencia no impide admitir la ruta en SUA-03 | Este recibo, la fila de followups de la competence por diseño y SUA-03-mediciones.md, M-17c |
| I09 | **Cumplido en lo que pide el diseño para SUA-03.** Cada perfil admite por ruta y por contrato, y una fuente vencida lo deja sin admitir sin tocar a los demás | `perfiles.v1.json` y las pruebas de contexto |
| I11 | **Cumplido.** Un bloque editado a mano es conflicto y no se pisa; una edición entre leer y aplicar es conflicto; revertir nunca deshace una edición posterior | Las pruebas de publicar-contexto y la ventana de publicación (gen1 y gen2 sin conflictos) |

## Las rutas

`coverage.json` registra las cinco rutas del diseño en `routes`, cada una con su
generación de contexto y su evidencia. `certified` solo es verdadero en las dos de
CLI. La sesión adoptada por el operador salió de `routes`: su fila quedó en
`migration` como retirada, en el formato de las filas que ya había.

## Lo que no se hizo

- **El canario A no se ejecutó** (sección 5, con su aviso a David). Queda registrado
  aquí y en followups. I08 no se da por cumplido fuera de la ruta por CLI y el hijo
  de una CLI.
- **La competence por diseño en nativo no se lee en nativo.** Es la decisión del
  diseño (4.4, 4.5 y 4.11, conflicto 4): la compuerta que la lea es el selector de
  SUA-04.
- **El rechazo por encargo en las rutas nativas** pide un cambio en R y queda para
  SUA-09O (4.11, conflicto 4).
