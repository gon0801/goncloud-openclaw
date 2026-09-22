# Evidencia del cutover del runtime — plantilla (instanciar por fecha)

Copiar a `docs/evidence/openclaw-runtime-cutover-<fecha>.md` y llenar
durante la operacion 16.8. Solo evidencia REDACTADA entra al repo: sin
credenciales, valores `.env`, material de pairing, contenido de memoria
ni salidas sin redactar. Cada recibo se cita por ruta + `sha256`, no
pegado entero si trae observaciones largas.

- `authorization_ref`:
- SHA de merge autorizado:
- CI / lector fresco / revisor / Codex / lead (SHA + veredicto + fecha):
- Operador y ventana (inicio/fin, zona `America/New_York`):

## 1. Preflight

| Dato | Valor |
|---|---|
| `git --version` / `gh --version` | |
| `$PSVersionTable` | |
| OpenClaw (exigido 2026.9.5) | |
| Sleep AC (`0`) | |
| Usuario/sesion durable | |
| Espacio libre (backup+restore+snapshots+modelo) | |
| `OpenClaw Gateway` / Watchdog / `GoncloudRepoSync` (State) | |
| `/startupz` / `/readyz` iniciales | |
| `(Get-Culture).Name` (exigido en-US) | |
| Paradas encontradas (ninguna para seguir) | |

## 2. Bootstrap fuente

| Dato | Valor |
|---|---|
| `remote -v` | |
| `HEAD` (== merge-SHA) | |
| `status --porcelain` (vacio) | |
| Hashes de artefactos verificados | |
| Sync viejo tocado (siempre NO) | |

## 3. Tareas (XML antes/despues) y backup

| Tarea | XML respaldo (sha) | Read-back accion |
|---|---|---|
| `OpenClaw Gateway` | | |
| `OpenClaw Gateway Watchdog` | | |
| `OpenClaw Node` / `OpenClaw CUA Node` | | |
| `GoncloudRepoSync` | | |
| `OpenClaw Cutover` / `... DeadMan` | | |

| Backup | Valor |
|---|---|
| `generation` / recibo (sha) / terminal | |
| Backup verificado + restore a staging + manifiesto | |
| Bundle fuente, XMLs, launchers, inventario | |

## 4. Corte fuente/sync

| Dato | Valor |
|---|---|
| merge-SHA == `origin/main` == `HEAD` (antes de deploy) | |
| Deploy reporte + `-Apply` (recibo, sha) | |
| Vigia v3 instalado; read-back == versionado (diff vacio) | |
| Ciclo 1: 4 repos + marcador + exit 0 | |
| Fuente en `origin/main` limpio; runtime sin `.git` principal | |
| Ciclo 2 sin cambios (sin escrituras ni PRs) | |

## 5. `.git` a cuarentena

| Dato | Valor |
|---|---|
| Inventario pre-move (sha) | |
| Destino + hashes destino == registrados | |
| Rollback disponible (XML + ruta/hash) | |

## 6. Ollama y memoria

| Dato | Valor |
|---|---|
| Firma/hash/bind/`/api/embed` vs politica | |
| `nomic-embed-text`, embedding no vacio | |
| Por agente: snapshot, solo-busqueda, read-back, reindex | |
| Consulta semantica no literal (query + hit) | |
| Eventos 3033/3077 nuevos (cero) | |
| Recibo migracion (sha); rollback disponible | |

## 7. Nodo aislado

| Dato | Valor |
|---|---|
| Pair foreground (codigo NO persistido) | |
| Allowlist exacta 8 comandos aprobada | |
| Duplicado exportado y eliminado | |
| Tarea oficial reiniciada; conectado + 2026.9.5 | |
| Recibo (sha) | |

## 8. Soak 15 min

| Minuto | `/readyz` | Nodo | Nota |
|---|---|---|---|
| 0-15 (uno por fila, o rango verde) | | | |

## 9. Cuarentena y reversa

| Dato | Valor |
|---|---|
| Elegibles movidos (inventario + hashes) | |
| Restore de ensayo (candidato + verificado) | |
| Borrados permanentes (cero) | |

## 10. Terminales y cierre

| Transaccion (gen) | Estado | Recibo (sha) | Resultado |
|---|---|---|---|
| backup | | | |
| (otras) | | | |

- Aceptacion final (CI + recibos + sync + semantica + nodo + soak +
  cero CI nuevos + cero borrados):
- PR de cierre:
- Ledger terminal por fila:
