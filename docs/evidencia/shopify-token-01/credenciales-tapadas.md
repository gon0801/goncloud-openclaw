# Credenciales tapadas en la Mini

Corrida de `scripts/mac/credenciales-tapadas.sh` sobre `~/.openclaw` (2026-10-21). Solo rutas y nombres, sin valores.

Resultado: `credenciales tapadas: 0` — no salió ninguna ruta ni clave.

Se revisaron `~/.openclaw/credentials/*` (browser-extension-relay.secret → relay de la extensión del navegador; shopify_app.json y shopify_token.txt → Shopify), `~/.openclaw/.env` (Telegram, GitHub, Tavily, etc.), `~/.openclaw/openclaw.json` y los `.env` de `workspace-*`.

Nota: una primera corrida marcó `openclaw.json` → `accountId` (`"*"` en un binding de Telegram). Es un comodín de enrutamiento, no una credencial, así que el script ya no marca asteriscos en claves que no parecen secretos.

Aviso final: no hay más credenciales tapadas.

Rerun tras el intento 5 (archivos ilegibles se listan como `ilegible`, `CLAVE=` sola en credentials/ se detecta, formas ambiguas salen como `línea N` + `vacia?` sin texto): `credenciales tapadas: 0`.

Rerun tras el intento 6 (el texto a la izquierda de `=` solo se trata como clave si tiene forma clara de nombre de variable —`export` o TODO MAYÚSCULAS con `_`—; un base64url con `_` y `=` final ya no se imprime): `credenciales tapadas: 0`.

Lista de rutas y claves que salieron en esta corrida: ninguna. Se visitaron 5 archivos reales (`~/.openclaw/credentials/browser-extension-relay.secret` → relay de la extensión del navegador; `~/.openclaw/credentials/shopify_app.json` y `~/.openclaw/credentials/shopify_token.txt` → Shopify; `~/.openclaw/.env` → Telegram, GitHub, Tavily, etc.; `~/.openclaw/openclaw.json`). No hay `.env` en `workspace-*` en esta Mini.

Aviso final: no hay más credenciales tapadas; nada que arreglar en este plan.
