---
name: mac-node-file-transfer
description: Get a file (screenshot, log, report) off the Mac node to the gateway. Use when a Mac file must be attached in chat and node file fetch (file_fetch/dir_fetch) is blocked by the macOS allowlist. Produces the file on the gateway filesystem, ready for the message tool.
---

# Mac Node File Transfer

Move a file from the paired Mac node ("David's MacBook Pro") to the gateway filesystem when the node's file-fetch commands are unavailable. Verified 2026-09-10 (screen of the deployed UI delivered to chat).

`exec host=node` reaches the Mac's shell, but `file_fetch`/`dir_fetch` can be denied (`node command not allowed: "file.fetch" is not in the allowlist for platform "macOS ..."`). `view_image` rejects private/LAN URLs and the gateway browser blocks LAN URLs, so neither fetches node files.

## Steps

1. Confirm the file on the Mac, read-only: `exec host=node` runs `ls -la <mac-path>`.
   - Completion: exact Mac path and a non-zero size.

2. Try `file_fetch` (node + path). If it returns the file, stop.
   - If it is denied by the allowlist, use step 3 or step 4.

3. Relay through the goncloud server. Both the Mac and the gateway have an `ssh gonserver` alias:
   - On the Mac (exec host=node): `scp <mac-path> gonserver:/tmp/<name>`.
   - On the gateway: `scp gonserver:/tmp/<name> "<local-path>"` (e.g. under `...\.openclaw\workspace\media\`).
   - Completion: local file exists with the same non-zero size.

4. Fallback when scp is unavailable — serve from the node, pull from the gateway:
   - On the Mac: start a background HTTP server over the file's directory (`python3 -m http.server <port> --directory <dir>`).
   - On the gateway: `curl.exe -s --max-time 25 http://<mac-lan-ip>:<port>/<name> -o "<local-path>"`.
   - Stop the node server afterwards (confirm the port has no listener).
   - Completion: local file exists with a non-zero size.

5. Attach it: `message` action=send with `media="<gateway-local-path>"` (the gateway path, not the node path).

## Pitfalls

- Once `file.fetch` is denied, the gateway cannot pull node files itself; the transfer must be pushed from the node (scp) or served by the node.
- The gateway cannot reach the node's LAN URL through the browser or `view_image` — only `curl` from the gateway reaches it.
- Transfer data files only; never copy credential files.
- If the operator later enables `file.fetch`/`dir.list` for the node, prefer `file_fetch` (step 2).
