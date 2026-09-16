---
name: gateway-mobile-pairing
description: Reach the gateway from the owner's phone — native QR pairing over Tailscale Serve, or a WireGuard tunnel route to the gateway PC. Use when he wants the mobile app connected, when `openclaw qr` refuses for lack of a secure URL, when `tailscale serve` answers "Serve is not enabled on your tailnet", or when the phone's VPN connects but the app stays mute.
---

# Gateway Mobile Pairing

Get the owner's phone to the gateway. Two routes, each needing one owner action. Verified 2026-09-16 on the Windows gateway host (tailnet IP 100.80.179.76; WireGuard server 65.109.4.81:51820, net 10.13.13.x). The device app is OpenClaw — he corrects "Hermes", so use his name for it.

## Reachability facts (read before changing anything)

- `netstat -ano | Select-String ":18789"` — the gateway listens on its **tailnet IP and 127.0.0.1 only**, never on a WireGuard address. A phone that reaches the VPN server over WireGuard therefore still cannot reach the gateway.
- `tailscale status --self` gives the tailnet IP and the machine list; `tailscale serve status` says whether Serve is on.

## Route 1 — QR pairing (native app)

1. `openclaw qr` refuses a plain `ws://` gateway and names the fix: a secure (wss://) URL or Tailscale Serve/Funnel. It resolves the URL from `gateway.bind`, so with `bind=tailnet` it simply fails.
2. `tailscale serve --bg --https=443 http://127.0.0.1:18789`. On a tailnet where Serve was never enabled it stops with "Serve is not enabled on your tailnet" plus a `https://login.tailscale.com/f/serve?node=<id>` link — that click is the owner's and nothing proceeds without it. After the click the same command prints `https://<node>.<tailnet>.ts.net/`.
   - Completion: `tailscale serve status` shows the proxy to 127.0.0.1:18789.
3. The config coupling, and the trap: `gateway.tailscale.mode=serve` is accepted only while `gateway.bind` resolves to loopback, and the reverse write (`bind=tailnet` while mode=serve) is rejected by validation. **`bind=loopback` also removes the raw tailnet-IP listener the Mac's agent sessions use**, so never make that switch casually. To back out, order matters: mode→off first, then bind→tailnet.
4. No-restart alternative, **unverified**: setting `plugins.entries.device-pair.config.publicUrl` to the `https://<node>.<tailnet>.ts.net` URL (applies on a gateway restart). The write was accepted here but the QR was never re-run against it — present it as a candidate, not a fix.
5. The app's password is the gateway auth token, which the owner reads himself with `openclaw gateway auth-token --show` in an interactive terminal (the CLI refuses to print it elsewhere). Never print or paste it.

## Route 2 — WireGuard tunnel to the gateway PC

1. The server is authoritative: per-device client configs live at `/etc/wireguard/clients/<name>.conf`, and `ssh gonserver "sudo -n wg show wg0 allowed-ips"` maps peer keys to tunnel addresses. The gateway PC may already be a registered peer (2026-09-16: `pc1` = 10.13.13.4, connected) — check before creating anything.
2. Handing the PC the tunnel needs admin: `wireguard.exe /installtunnelservice <conf>` fails "Access is denied" from agent exec, and `elevated: true` is policy-denied for chat-sourced sessions. Write the `.conf` somewhere the owner can reach and have him import it in the WireGuard GUI (Add Tunnel → import from file → Activate).
   - Completion: `Get-NetIPAddress` shows the tunnel address and `ping <server-tunnel-ip>` answers (verified: 10.13.13.4, 178 ms).
3. The tunnel alone is not enough (see Reachability facts): the phone now reaches the PC, but the gateway still answers only on its own addresses. Candidate fix without restarting the gateway — a port proxy from the tunnel address to the loopback listener plus a firewall rule; **unverified here**, the owner never ran it.
4. Adding a peer on the server touches the shared tunnel: get the owner's explicit OK, keep the other peers' handshakes undisturbed, and do not restart the tunnel.

## Pitfalls

- A device that appears as pending does not pair itself — it still needs approval (`openclaw devices approve`).
- "No conecta" with an app that stays mute is usually a wrong address, not a broken app: confirm the address the phone dials belongs to the machine the gateway actually listens on before touching either VPN.
- No gateway restart for any of this without checking `openclaw cron list --all` for a running job first; a restart kills in-flight runs, and the browser profile registration can come back missing (see `browser-cli-claw-profile`).
