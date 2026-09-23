# Fase 14: guía de ejecución pendiente de Fases 15 y 9

> **NO LANZAR CON EL CORTE VIEJO.** Fase 15 ya está cerrada, pero U1/U2 de
> `Plans.md` siguen pendientes. El sync Windows anterior está deshabilitado;
> cualquier canary o merge vivo debe usar el nuevo deploy selectivo y un SHA
> instalado leído de vuelta.

Para el lead que Claw asigne. Plan: `docs/superpowers/plans/2026-09-19-native-harness-orchestration.md`; diseño: `docs/superpowers/specs/2026-09-19-native-harness-orchestration-design.md`. Esta revisión corrige el plan; no lanza la fase. Tablero previsto: `/runbook/tablero/c/fase14-harness`.

El primer comando de una futura corrida crea el estado observable antes de tocar un carril:

```bash
mkdir -p .saikit/progress
PROGRESS_PATH=${PROGRESS_PATH:-.saikit/progress/14.json}
export PROGRESS_PATH
/usr/bin/python3 - <<'PY'
import datetime
import json
import os
import pathlib

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def lane(id_, name, branch, task):
    return {
        "id": id_, "nombre": name, "repo": "gon0801/goncloud-openclaw",
        "rama": branch, "tareas": [task], "estado": "pendiente", "paso_loop": 0,
        "pr": None, "head": None, "approve_lead": None, "ci": "pendiente",
        "coderabbit": "pendiente", "residuales": [], "detenido_por": None,
    }


def queue(id_):
    return {
        "id": id_, "prs": [], "estado": "pendiente", "ventana": None,
        "merge_commits": [], "verificado": None, "detenido_por": None, "avance": 0,
    }


doc = {
    "schema": "runbook-progress.v1",
    "runbook": "docs/runbooks/autopilot-fase14.md",
    "fase": "14",
    "corrida": "fase14-harness",
    "proyecto": "openclaw",
    "titulo": "Fase 14: orquestación autónoma con harnesses nativos",
    "plan": {"repo": "gon0801/goncloud-openclaw", "ruta": "Plans.md", "seccion": "Fase 14"},
    "lead": {"agente": os.environ.get("CORRIDA_HOST", "unknown"), "inicio": now, "actualizado": now},
    "atencion_requerida": {"necesaria": False, "motivo": None, "desde": None},
    "siguiente_paso": "Validar dependencias; después iniciar B1.",
    "carriles": [
        lane("R", "Registro y selector", "fase14/registro-adaptadores", "14.1"),
        lane("A", "Adaptadores y aislamiento", "fase14/registro-adaptadores", "14.2"),
        lane("T", "Tablero", "fase14/tablero-direccion", "14.3"),
        lane("M", "Autoridad de merge", "fase14/estado-entrega", "14.4"),
        lane("E", "Estado y compuertas", "fase14/estado-entrega", "14.5"),
        lane("S", "Skill de main", "fase14/tablero-direccion", "14.6"),
        lane("L", "Humo y entrega", "fase14/rollout", "14.7"),
    ],
    "cola": [queue("B1"), queue("B2"), queue("B3"), queue("B4"), queue("cierre")],
    "eventos": [],
    "cierre": {"at": None, "telegram_message_id": None, "resumen": None},
}
pathlib.Path(os.environ["PROGRESS_PATH"]).write_text(json.dumps(doc, ensure_ascii=False) + "\n")
PY
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat "$PROGRESS_PATH")" --timeout 30000
```

## Arranque y precedencia

Hereda `docs/runbooks/base-openclaw.md` y `docs/runbooks/loop-autopilot.md` una vez alineados por entrega-sin-sello C. Ante instrucciones antiguas de sellar, cambiar el reloj o esperar cuota, no ejecutar esa copia: falta integrar la dependencia. Las decisiones específicas de esta revisión están en “Execution prerequisites and ownership” del plan.

Orden: entrega-sin-sello A/B/C integrado y kit instalado; Fase 15 terminada; Fase 9 terminada e instalada; después Fase 14. Fase 23 es independiente, sus tareas recomendadas pendientes no son requisito. El lead registra los SHA reales y comprueba el recibo `saikit-entrega.v1`, el manifiesto de instalación de Fase 9 y el alta real de `usuario`.

Lecturas iniciales desde el repo OpenClaw: `git fetch origin`, `git show origin/main:Plans.md`, `git show origin/main:docs/spec/corrida.v2.md`, `git show origin/main:docs/spec/seguimiento.v2.md`. GitHub: `gh pr list --repo gon0801/goncloud-openclaw --state open`. Una fila pendiente no cuenta como cierre; guardar enlaces de evidencia e integración. No lanzar en bucle si falta una dependencia.

Antes de activar el lanzamiento por frase, validar `bash scripts/lanzar-fase.sh 14 --dry-run -- <cli> <flag>` con la CLI y el flag verificados en el base instalado. Hasta pasar ese check no anunciar “lista para ejecutar”. El primer efecto de la corrida registra `fase14-harness` y las siete tareas pendientes en el tablero mediante el mecanismo instalado de Fase 9.

El lead usa `corrida.sh lanzar-sesion` para abrir cada worker después de reservar su carril; esa ruta registra y marca la sesión antes de entregar el brief.

## Roles y alcance

Claw asigna el lead por disponibilidad. El implementador escribe en su worktree; verifier y reviewer son independientes de todos los autores. `main` dirige y registra, `implementer` o `ingenieria` ejecutan merge/deploy mediante el kit. `usuario`, instalado en Fase 9, recibe solo promesa y recorrido visible.

Esta guía conserva el alcance previamente autorizado para la futura implementación: ramas/worktrees de Fase 14, PRs, merge por kit, pruebas con CLIs, instalación local prevista y canary de bajo riesgo con rollback. Corregir este documento no ejecuta esas operaciones. Configuración/reinicio del gateway, lectura de secretos, compras de cuota, push directo a main y borrados recursivos quedan fuera.

## Preaprobaciones del dueño

Esta tabla es la autorización versionada de la fase; la corrida guarda su ruta como `authorization_ref`. Un recibo técnico o una CI verde sin esta referencia no autorizan un merge.

| Operación | Alcance | Estado |
|---|---|---|
| Push y apertura de PR | ramas `fase14/*` de los cuatro bloques | Aprobado |
| Merge por la ruta del kit en ventana segura | PRs de los cuatro bloques y el PR único de cierre | Aprobado |
| Instalación, seis smokes y canary con reversa acotada | artefactos y repos desechables de Fase 14 | Aprobado |
| `runbook.progress.set\|get` | corrida `fase14-harness` | Aprobado |

## Bloques, archivos y cola

Default OpenClaw: `origin/main`. Default SummonAIKit: `origin/master`, solo lectura durante esta fase. Cada bloque nace desde el remoto actualizado después de integrar su predecesor. No se usa la rama histórica `docs/native-harness-orchestration` para implementar.

| Bloque / rama | Tasks / filas | Puede tocar | No toca |
|---|---|---|---|
| B1 `fase14/registro-adaptadores` | 1–4 / 14.1–14.2 | Registro, selector, adaptadores, aislamiento, Terminal y tests listados por Task | Gates, tablero, kit, CI |
| B2 `fase14/estado-entrega` | 5–7 / 14.5 y 14.4 | Estado, compuertas, consumidores del recibo, copias de autoridad y tests listados | Implementación del hook/kit, CI, tablero |
| B3 `fase14/tablero-direccion` | 8–9 / 14.3 y 14.6 | Tablero, skill, extensión del único instalador de Fase 9 y tests listados | Segundo instalador, relojes, hook, CI |
| B4 `fase14/rollout` | 10 / 14.7 | Driver de smokes, test falso y guía de rollout | Código fuera del Task sin hallazgo reproducible |
| Cierre `docs/fase14-cierre` | Evidencia y estados | `Plans.md`, `.saikit/progress/14.json`, evidencia redactada de Fase 14 | Código, fases ajenas |

Las DoD y comandos focalizados son los Steps de los Tasks. Orden de merge B1 → B2 → B3 → B4. Task 7 consume Task 6, nunca arranca antes. Después se instala desde el SHA integrado, se mide y se publica un único PR de cierre. Los cambios a `corrida.sh`, `lib.sh` y `corrida-worker.py` se serializan.

## Entrega y revisiones

Seguir el loop canónico actualizado, con la política del plan: revisión agrupada antes del primer PR de código, CodeRabbit una vez, corrección local y revisión del delta antes del siguiente push al mismo PR. Solo un bloqueante reproducible abre ronda, revisor distinto; el mismo bloqueante dos veces detiene el carril y requiere decisión del operador. Residuales no bloqueantes no abren ronda.

Pruebas focalizadas durante implementación. Batería completa una vez por SHA final en CI al abrir PR, verificar que la unión de jobs cubre todo. Reutilizar resultados del mismo SHA; respetar hooks sin `--no-verify`. Si CI no cubre todo, completar la batería donde pueda ejecutarse. No lanzar manualmente otra batería después del resultado íntegro.

El recibo vive en el PR; reiniciar el lead no exige otra revisión. Merge usa el kit y `expectedHeadOid`. Guardar head revisado, merge commit y artefacto instalado: un squash puede cambiar el hash. La guía de rollout del Task 10 concretará comandos de instalación/canary/rollback sobre el instalador entregado por Fase 9.

## Seguimiento

En cada cambio de estado el lead actualiza el tablero por RPC del gateway y manda a David un Telegram conforme a `seguimiento.v2`. Mientras exista trabajo activo, claw o Hermes envía seguimiento al menos cada 30 minutos, como máximo cada 30 minutos sin novedad. Canal: Telegram, con el destino resuelto por la configuración instalada y nunca pegado en el repo.

Tick interno global de 15 minutos más eventos tmux; Telegram consolidado cada 30 minutos con porcentajes derivados según `seguimiento.v2`. `AVANZA` se acumula; avisos inmediatos usan `seguimiento.v1`. No crear cron por worker ni activar otro `corrida-latido`. Al cerrar, liberar solo marcas de esta fase y conservar el reloj si otro trabajo sigue.

### Recuperación

| Situación | Acción |
|---|---|
| Falta integración de Fase 9/15 o kit sin recibos | Declarar dependencia pendiente una vez; no lanzar implementadores |
| Cuota/auth/binario de worker falla | Descartar candidato; confirmar escritor anterior detenido; relevar al siguiente compatible conservando worktree/diff/commits |
| Caída ordinaria | Una reanudación; luego relevo registrado |
| Ningún candidato compatible | Detener solo ese carril con evidencia; continuar independientes |
| CI pendiente | Continuar trabajo independiente y leer finalización; sin watch bloqueante |
| CodeRabbit sin cuota | Declararlo en PR; recibo/revisiones/CI siguen exigidos; no llamarlo aprobación |
| CodeRabbit pending/unknown | Una reconsulta tras un máximo de 20 min, sin espera bloqueante; persistente sigue política de indisponibilidad del plan |
| Check obligatorio de GitHub impide merge | Informar requisito externo; no saltar protección |
| Smoke de un host sin cuota | Dejarlo pendiente y deshabilitado; avanzar otros; no cerrar seis-host como completo |
| Smoke con defecto de comportamiento | Reproducción y corrección focalizada del propietario |
| Terminal denegada | Trabajo continúa en tmux; tablero muestra degraded y attach |
| Lead reinicia | Leer registro, worktree, PR/recibo, CI y efectos reales antes de repetir una acción |
| Canary o rollback falla | Rollback documentado y verificación; si falla la reversa, atención requerida con evidencia |

## Clases de comando

| Clase | Uso |
|---|---|
| `gh` | Estado, PR, comentarios, CI y ruta de merge autorizada |
| `red externa` | Proveedores de CLIs y GitHub, sin leer secretos |

## Cierre

Siete filas, diez Tasks, cuatro PRs de código y uno de cierre. Se conservan seis contratos falsos y seis smokes reales requeridos. Rollout parcial solo con hosts probados y al menos un revisor independiente; los no medidos siguen pendientes. `usuario` confirma el recorrido real. El cierre completo exige evidencias, filas resueltas y una ejecución verde de `bash scripts/cierre-de-fase.sh 14`. No hay otro ciclo de revisión de todo el código por actualizar el ledger.
