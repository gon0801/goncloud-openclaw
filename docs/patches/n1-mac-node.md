# N1 — Nodo Mac (investigacion; no aplicado)

## N1.1 — Origen de `tools.exec.pathPrepend is ignored for host=node`

**Hallazgo (measured).** El warning no viene de config. `openclaw.json` no contiene `pathPrepend`. `tools.exec` solo trae `mode`, `safeBins`, `safeBinProfiles`, `safeBinTrustedDirs`.

El gateway materializa un shim CLI en `~/.openclaw/tmp/agent-cli` y lo inyecta siempre via `mergeGatewayAgentCliPath` (`dist/openclaw-cli-shim-CX2iomGE.mjs`). Ese array no vacio llega como `defaultPathPrepend`. En host=node, `bash-tools-D7K7O7ip.mjs:2958` emite el warning incondicionalmente:

```text
if (params.host === "node" && params.defaultPathPrepend.length > 0)
  params.warnings.push("Warning: tools.exec.pathPrepend is ignored for host=node. ...");
```

**Implication.** Quitar un `pathPrepend` de config no silencia el warning mientras el shim CLI siga activo. Fix real: upstream (no warn cuando el unico prepend es el shim), o no pasar `defaultPathPrepend` a host=node.

## N1.2 — PATH del servicio del nodo

**Observed hoy.** LaunchAgent `~/Library/LaunchAgents/ai.openclaw.node.plist` carga `/Users/dn/.openclaw/service-env/ai.openclaw.node.env`, cuyo PATH actual es:

```text
/Users/dn/.openclaw/tools/node-v24.19.0/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

El brief asumia PATH minimo `/usr/bin:/bin:/usr/sbin:/sbin`. Eso **ya no es el estado actual** en esta Mac. Homebrew ya esta.

**Cambio propuesto (NO aplicar sin ventana).** Si hace falta ampliar (p.ej. `~/.local/bin`):

1. Editar `/Users/dn/.openclaw/service-env/ai.openclaw.node.env` (archivo generado; un edit manual puede ser pisado al reinstalar el servicio).
2. O regenerar el servicio con la doc de OpenClaw node install y PATH deseado.
3. Reiniciar: `launchctl kickstart -k gui/$(id -u)/ai.openclaw.node` — **desconecta agentes a media corrida**.

## N1.3 — `scripts/mac/shot.sh`

Wrapper Edge headless con stderr silenciado. Evidencia local:

```text
SHOT_OK /tmp/openclaw-shot-ok.png 4255 1280x720
```

(Correr de nuevo: `scripts/mac/shot.sh /tmp/openclaw-shot-ok.png about:blank`.)

## N1.4 — file_fetch / dir_fetch / view_image

**file_fetch / dir_fetch.** Plugin `file-transfer` esta enabled pero `plugins.entries.file-transfer.config` es `{}`. Sin allowlist/approvals, `evaluateFilePolicy` deniega con `NO_POLICY` (`node-invoke-policy-BM935Mhk.mjs`). Docs: `openclaw file-transfer approvals migrate` y approvals por path exacto o wildcard.

Propuesta (lead, interactivo en gateway):

```bash
openclaw file-transfer approvals migrate --dry-run
# luego interactivo: permitir paths absolutos del nodo, p.ej. /Users/dn/..., /tmp/...
```

Tambien revisar `gateway.nodes.commands.allow` si hace falta ampliar comandos de invoke.

**view_image + IPs privadas.** `view_image` acepta http(s); el fetch pasa por guard SSRF (`fetch-guard-*.mjs`) que bloquea rangos privados/CGNAT salvo allow explicito. Tailscale `100.x` cuenta como privado. Preferir path local de archivo (PNG en disco del nodo) o `mac-node-file-transfer` skill en vez de `http://100.x/...`.

Propuesta de config (no aplicada; confirmar schema exacto en vivo antes):

```json5
// Solo si el lead necesita URLs LAN en view_image — riesgo SSRF.
// Preferible: paths locales. Exact key not_observed en schema de media;
// el allowPrivateNetwork documentado hoy es de models.providers.*.request.
```

`not_observed`: clave de config especifica para permitir IPs privadas en `view_image` (distinta de model-provider allowPrivateNetwork). No se encontro un toggle dedicado con evidencia clara en schema; el workaround seguro es path local.
