# Fase 9 — Celdas abiertas (qué queda para la Mac, -saikit:autopilot)

Estado al cerrar este turno gateway: la rama `fase9/fase9-arranque-gateway` deja el arranque
**documentado y revalidado**, no ejecutado en la Mac. Ningún carril se lanzó desde aquí (los
implementadores viven en tmux de la Mac; este host no los alcanza).

| Celda del plan | Estado | Dónde sigue |
|---|---|---|
| 0.0 precondiciones (lado Mac) | Parcial: lado gateway verde (ver `0-precondiciones.md`); `gateway`, `vigilante_vivo`, `kit` los confirma el lead | lead, `wt-f9-lead`, §0.0 |
| 0.1 leer Fase 9 + loop | Hecho en este turno (runbook 474 líneas + loop + plan 13 filas) | lead lo repite en su sesión |
| 0.2 marcarse (`OPENCLAW_WATCH`, nombre `*-wt-f9-lead`, en tmux) | **Abierta** (solo Mac) | lead |
| 0.3 progreso `9.json` + `9-sesiones.txt` + espejo | **Abierta** (solo Mac/gateway con `openclaw`) | lead |
| 0.4 seguimiento: leer `CHAT`, mensaje `AVANZA`, crons `corrida-vigia-9` + `corrida-empuje-9` | **Abierta** (requiere `openclaw cron` + gateway vivo) | lead |
| 0.5 abrir worktree N + lanzarlo | **Abierta** (Mac) | lead + implementador N |
| 0.6 spike 9.0 (`docs/evidence/fase9-spike.md`, 6 veredictos) | **Abierta** (Mac, solo lectura) | lead |
| 9.1–9.3 carril N (`fase9/nucleo`) | **Abierta** — encargo listo: `encargo-n.md` | implementador N |
| 9.4/9.5/9.8 carril M (`fase9/mensajes`) | **Abierta** — encargo listo: `encargo-m.md` | implementador M (tras merge N) |
| 9.6 carril P (`fase9/politica`) | **Abierta** — encargo listo: `encargo-p.md` | implementador P (tras merge N) |
| 9.7 carril D (`fase9/docs`) | **Abierta** — encargo listo: `encargo-d.md` | implementador D (tras M y P) |
| 9.10 instalador Mac | Fuera del runbook; el plan la exige — el lead decide carril | lead |
| 9.11 agente `usuario` | Fuera del runbook; el plan la exige — el lead decide carril | lead |
| 9.12 cierre-de-fase + promesas observables | Fuera del runbook; el plan la exige — el lead decide carril | lead |
| Q1–Q5 (cola de merge, Q4 instalación+simulacro, Q5 cierre) | **Abiertas** (Mac + kit) | lead |
| Desviación plan 10→13 | Declarada aquí y en `0-precondiciones.md`; repetir en PR de cierre | lead |

Verificación de este turno (evidencia real, sin repetir batería): `test-runbooks-no-contradicen-entorno.sh`
TODO VERDE + `test-loop-autopilot.sh` TODO VERDE, corridos una vez con git-bash sobre el SHA base
`7a83ee6` (salidas completas en el log del turno). El resto de la batería corre en CI del PR.
No se mergea (el merge va por `saikit-merge-route` con `--confirmado`, lo decide el lead).
