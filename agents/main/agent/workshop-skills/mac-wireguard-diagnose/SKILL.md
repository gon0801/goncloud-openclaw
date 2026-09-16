---
name: mac-wireguard-diagnose
description: Diagnose WireGuard problems on David's Mac when his iPhone (Screens, Tailscale-adjacent VPN) stops connecting. Find the tunnel log fast, check tunnel liveness, and decide Mac-side vs iPhone-side.
---

# WireGuard Diagnosis (David's MacBook Pro)

David connects to the Mac from his iPhone via the Screens app over WireGuard (server 65.109.4.81:51820, tunnel net 10.13.13.x, Mac is 10.13.13.8). When he reports "no conecta", work Mac-side first with read-only commands. Verified 2026-09-14: the config-hunting cost four failed `find`/`ls` attempts before the real location was found.

## Steps

1. Check the tunnel interface and listener in one read-only shot:
   `ifconfig | grep -A3 utun3` (expect `inet 10.13.13.8`), `lsof -nP -i UDP | grep -i wireguard` (app listens on a dynamic port, e.g. 51633 — not 51820).
   `sudo` is passwordless on the goncloud server but NOT on this Mac; never block on `sudo wg show`.
   - Completion: tunnel interface state and listener port known.

2. Read the tunnel log at the only place it lives — these paths do NOT exist:
   - ✅ `/Users/dn/Library/Group Containers/L82V4Y2P3C.group.com.wireguard.macos/tunnel-log.bin`
   Read the tail: `tail -c 8000 <path> | strings | tail -40`.
   - Completion: recent log lines visible; errors identified.

3. Interpret the common log error `sendto: network is unreachable` toward 65.109.4.81:51820:
   It appears right after `[NET] Network change detected` and is transient (sleep/wake, WiFi change). Confirm the current reality before treating it as the cause: `ping -c 3 65.109.4.81` (direct, via en0) and a liveness ping inside the tunnel: `ping -c 3 -b utun3 10.13.13.1`.
   - Completion: verdict names the interface each result rides on (`route get 65.109.4.81` shows it).
4. Decide for the user:
   - Ping to server OK + inside-tunnel ping OK ⇒ **Mac is healthy**; the problem is iPhone-side or carrier/UDP blocking. Tell him to toggle the iPhone VPN, test both WiFi and cellular, and check "Latest handshake" rx/tx in the iPhone WireGuard app.
   - Inside-tunnel ping failing while direct ping works ⇒ Mac-side tunnel problem: have him deactivate/reactivate the tunnel in the Mac WireGuard app (gui re-activation, not taskkill).
   - Completion: the user's next action is stated, not just the diagnosis.

## Pitfalls

- A route-table `default` via utun3 alongside en0's default is normal for this full-tunnel setup — not by itself a fault.
- Log files under `~/Library/Application Support/WireGuard/` do not exist on this install; only the Group Containers path above is real. Window-truth questions during such diagnosis go to the app's own AppleScript, not `System Events` process entries (see `mac-input-control` pitfalls).
- This skill is about the **Mac's** tunnel. If the app that must answer is the OpenClaw app on the phone rather than Screens to the Mac, the diagnosis is different: the gateway listens only on its tailnet address and 127.0.0.1, so reaching the VPN server proves nothing about reaching the gateway — use `gateway-mobile-pairing`.
