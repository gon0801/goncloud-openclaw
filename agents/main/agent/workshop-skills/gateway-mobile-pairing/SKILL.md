---
name: gateway-mobile-pairing
description: Reach the gateway from the owner's phone — pair the OpenClaw mobile app over his WireGuard tunnel (his standing choice), or over Tailscale Serve for a client that can run Tailscale. Use when he wants the mobile app connected, when `openclaw qr` refuses for lack of a secure URL, when `tailscale serve` answers "Serve is not enabled on your tailnet", when the phone's VPN connects but the app stays mute, or when the app needs full access and holds only the reduced `ws://` grant.
---

# Gateway Mobile Pairing

Get the owner's phone to the gateway. Each route needs one owner action. Verified 2026-09-16 on the Windows gateway host (WireGuard server 65.109.4.81:51820, net 10.13.13.x; tailnet IP 100.80.179.76). The device app is OpenClaw — he corrects "Hermes", so use his name for it.

**His standing constraint:** on his iPhone only one VPN can be active and it is WireGuard; he does not use Tailscale there and will delete it. When he names WireGuard, do not re-litigate Tailscale — proposing it cost five repetitions on 2026-09-16.

## Reachability facts (read before changing anything)

- What the gateway exposes comes from `gateway.bind`, so check it first: `openclaw config get gateway.bind`.
  - `lan` → the literal `0.0.0.0`: ONE listener answers on every address the host has — the tunnel IP, the tailnet IP, `127.0.0.1`, and the host's LAN address (auth stays `token`). Verified: `HTTP 200` on all of them with a single listener.
  - `tailnet` → the tailnet IP plus loopback only, which is why a phone that reaches the VPN server still cannot reach the gateway.
- Do NOT narrow it with `custom` + `customBindHost: <tunnel-ip>`: that resolves to `[<tunnel-ip>, 127.0.0.1]` and **drops the tailnet listener**, cutting off the Mac node. Code: `resolveGatewayBindHost` in `dist/net-*.mjs`. `lan` is the only mode that covers all three without loss.
- `tailscale status --self` gives the tailnet IP and the machine list; `tailscale serve status` says whether Serve is on.

## Route 1 — WireGuard tunnel to the gateway PC (his route)

1. The server is authoritative: per-device client configs live at `/etc/wireguard/clients/<name>.conf`, and `ssh gonserver "sudo -n wg show wg0 allowed-ips"` maps peer keys to tunnel addresses. The gateway PC may already be a registered peer (2026-09-16: `pc1` = 10.13.13.4, connected) — check before creating anything. Read-only on the server: never restart `wg0` and never disturb the other peers' handshakes.
   - Completion: you know the gateway PC's tunnel address and whether it is already a peer.
2. Handing the PC the tunnel needs admin: `wireguard.exe /installtunnelservice <conf>` fails "Access is denied" from agent exec, and `elevated: true` is policy-denied for chat-sourced sessions. Write the `.conf` somewhere the owner can reach and have him import it in the WireGuard GUI (Add Tunnel → import from file → Activate).
   - Completion: `Get-NetIPAddress` shows the tunnel address and `ping <server-tunnel-ip>` answers.
3. Make the gateway answer at that address — this is the step that completes the route: set `gateway.bind` to `lan` (see Reachability facts) and let the gateway restart itself. Do **not** build a port proxy or a firewall rule for this; `lan` makes the existing listener answer on the tunnel IP.
   - Completion: `curl.exe -sS -o NUL -w "%{http_code}" --max-time 8 http://<tunnel-ip>:18789/` returns 200.
4. Pair the phone against the **tunnel** URL: `openclaw qr --url ws://<tunnel-ip>:18789 --setup-code-only`. To deliver it as an image, render the code yourself with `renderQrPngBase64` from `dist/extensions/device-pair/qr-image.js` (the CLI's own QR encodes the raw setup code — verified against `dist/qr-cli-*.mjs`) and send that PNG. The code expires in ~10 minutes; if it lapses, regenerate both.
   - Completion: `openclaw devices list` shows the device with `remoteIp` = the phone's tunnel IP, `approvedVia: bootstrap`, roles `node`+`operator`.
5. A pending device does not pair itself — approve it (`openclaw devices approve <requestId>`). The phone's traffic now really rides the tunnel, so confirm it at the socket level: `netstat -ano | Select-String "<phone-tunnel-ip>"` shows ESTABLISHED pairs to `<tunnel-ip>:18789`.
   - Completion: the device is approved and its connections appear on the tunnel address.

## Reduced access on a plaintext URL (branch)

With `ws://` the setup code is deliberately downgraded (`accessDowngraded: true`, `LIMITED_TRANSPORT_WARNING`) and the device lands without `operator.admin`. If the app then refuses something that needs full access, the cause is the plaintext transport, not the device.
`gateway.tls.enabled=true` would give full access over `wss://<tunnel-ip>:18789` **without Tailscale** — but the Mac node and the Control UI speak `ws://100.80.179.76:18789` and must be re-pointed to `wss://` in the same change or they drop; with a self-signed certificate iOS/CFNetwork may reject it outright. High risk of leaving the Mac disconnected: treat it as a separate decision with a simultaneous migration plan, never a casual flip. (Analysis only, 2026-09-16; not applied.)

## Full access over WireGuard: real certificate (stable fix)

Verified 2026-09-18 (Windows gateway host, Cloudflare DNS, Let's Encrypt). Use when the owner asks for full app access over WireGuard — self-signed is explicitly the patch, not the fix.

- DNS: A record `<name> → <tunnel-ip>`, DNS-only. Cloudflare shows "DNS only - reserved IP" for RFC1918 targets — that means already correct, nothing to switch.
- Secret timing (verified recovery): a token saved to the secrets store mid-run is invisible to gateway-host exec (`$env:NAME` reads empty — the run's store snapshot predates the save). Do not ask the owner to re-paste; use manual DNS-01 below instead.
- Automated path (only when exec can already see the token): lego with the Cloudflare DNS plugin. lego v5 moved flags to the subcommand: `lego run --dns cloudflare --path <dir> -m <email> -d <name> -a` (global `--email`/`--dns` are rejected).
- Manual path (verified): lego `--dns manual` does NOT wait in non-interactive exec — stdin EOF kills the authorization immediately. Use Posh-ACME instead: `Install-PackageProvider NuGet -Scope CurrentUser` first (admin install fails), then `Install-Module Posh-ACME -Scope CurrentUser`; `New-PAOrder <name>` → `(Get-PAOrder)|Get-PAAuthorizations` gives the token; TXT value = base64url(sha256(token + "." + account-JWK-thumbprint)) with JWK members in order crv,kty,x,y from `acct.json`; hand the TXT to the owner for Cloudflare, then `Submit-ChallengeValidation` + `New-PACertificate`.
  - Completion: `New-PACertificate` returns the cert; files land under the Posh-ACME store.
- The flip itself (`gateway.tls` certPath/keyPath + simultaneous Mac/UI re-point to `wss://` + renewal task) stays a planned daytime migration with the owner present — write the plan, do not execute at night. Unexecuted.

## Route 2 — Tailscale Serve + QR

For a client that can run Tailscale. Not the owner's phone.

1. `openclaw qr` refuses a plain `ws://` gateway and names the fix: a secure (wss://) URL or Tailscale Serve/Funnel. It resolves the URL from `gateway.bind`, so with `bind=tailnet` it simply fails.
2. `tailscale serve --bg --https=443 http://127.0.0.1:18789`. On a tailnet where Serve was never enabled it stops with "Serve is not enabled on your tailnet" plus a `https://login.tailscale.com/f/serve?node=<id>` link — that click is the owner's and nothing proceeds without it. After the click the same command prints `https://<node>.<tailnet>.ts.net/`.
   - Completion: `tailscale serve status` shows the proxy to 127.0.0.1:18789.
3. The config coupling, and the trap: `gateway.tailscale.mode=serve` is accepted only while `gateway.bind` resolves to loopback, and the reverse write (`bind=tailnet` while mode=serve) is rejected by validation. **`bind=loopback` also removes the raw tailnet-IP listener the Mac's agent sessions use**, so never make that switch casually. To back out, order matters: mode→off first, then bind→tailnet.
4. No-restart alternative, **unverified**: setting `plugins.entries.device-pair.config.publicUrl` to the `https://<node>.<tailnet>.ts.net` URL (applies on a gateway restart). The write was accepted here but the QR was never re-run against it — present it as a candidate, not a fix.
5. The app's password is the gateway auth token, which the owner reads himself with `openclaw gateway auth-token --show` in an interactive terminal (the CLI refuses to print it elsewhere). Never print or paste it.

## Pitfalls

- "No conecta" with an app that stays mute is usually a wrong address, not a broken app: confirm the address the phone dials belongs to the machine the gateway actually listens on before touching either VPN.
- **A paired phone whose upgrade dies with `code=1006` while the app reports "refused"/"timeout" is usually the gateway, not the tunnel.** If the tunnel is proven (fresh handshakes both ends, large packets pass) and the device is paired, stop rebuilding the VPN and diagnose the gateway with `gateway-stability-diagnosis`.
- No gateway restart for any of this without checking `openclaw cron list --all` for a running job first; a restart kills in-flight runs, and the browser profile registration can come back missing (see `browser-cli-claw-profile`).
