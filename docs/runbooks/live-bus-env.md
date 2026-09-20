# Live bus — env en el host OpenClaw

Tras cada `runbook.progress.set` exitoso, `tablero-runbook` hace un POST
fire-and-forget al BFF de Gonserver:

```
POST ${LIVE_BUS_URL}/sync/progress/${fase}
Authorization: Bearer ${LIVE_WRITE_TOKEN}
```

Variables (opcionales; **sin token = no-op**):

| Variable | Default | Notas |
|---|---|---|
| `LIVE_BUS_URL` | `http://127.0.0.1:8787` | En Tailscale hacia Gonserver: `http://100.127.167.103:8787` |
| `LIVE_WRITE_TOKEN` | (unset) | Secret del BFF. **No versionar.** |

Ponerlas en el env del servicio OpenClaw (gateway/node LaunchAgent o
`service-env`), no en el repo. Timeout ~2 s; fallo de red no afecta set/get
ni el HTML del tablero.
