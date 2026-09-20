# Monday Board Group → Excel (over CDP)

Export one board group to Excel on the gateway's default-profile Edge, after the CDP setup in `gateway-edge-cdp` steps 2–3 (puppeteer-core connected). Verified 2026-09-12: group "Agosto 2026" (116 elementos) on board "Pedidos Arras Mx" exported and downloaded.

## Procedure

1. Confirm the session and board tab: `browser.pages()` → find the tab whose URL matches `monday.com/boards`. The board's groups may not all be in the DOM at load — groups render as you scroll.
   - Completion: the board tab exists and the page text shows the board name.
2. Locate the target group header: `span.group-name` elements after scrolling the scrollable containers (`d.scrollTop += 1500` in a loop, collecting group names until the target appears). Group headers can be collapsed ("116 Elementos") and still export.
   - Completion: a `span.group-name` whose text contains the group name; `scrollIntoView({ block: 'center' })` it.
3. Arm the download capture BEFORE clicking anything: `const cdp = await p.createCDPSession(); await cdp.send('Browser.setDownloadBehavior', { behavior: 'allowAndName', downloadPath: DL, eventsEnabled: true })`, and collect `Browser.downloadWillBegin` events (they carry `suggestedFilename`).
   - Completion: listeners registered.
4. Open the group menu: hover the group title (`mouse.move` over it), then click the "…" that appears left of the title (measured x ≈ 285 at viewport width 1600). Then find the menu item by exact text and click it by real mouse coordinates (`getBoundingClientRect` center), not `.click()` — synthetic clicks no-op silently on this menu.
   - Menu items to expect: "Expandir este grupo", "Seleccionar todos los elementos del grupo", "Duplicar este grupo", **"Exportar a Excel"**, "Eliminar grupo", "Archivar grupo" (Spanish UI; each rendered twice in the DOM).
   - The menu may not open on the first hover/click (no feedback in the DOM); retry the hover+click up to ~4 times and re-probe for the item. Escape closes a stray menu.
   - Completion: the item's bounding box is found.
5. Confirm the dialog. Clicking "Exportar a Excel" opens a confirmation dialog ("El enlace de descarga estará activo durante 60 minutos…"), it does not download directly. Click its "Exportar" button (exact text match on `button`/`[role="button"]`).
   - Completion: dialog button clicked.
6. Wait for the download: poll the `Browser.downloadWillBegin` events up to ~60 s, then wait ~8 s more for the file to land. The file is saved under the `downloadPath` as a **GUID without extension** (e.g. `305db69a-…`, 13 KB) — `downloadWillBegin`'s `suggestedFilename` (e.g. `Pedidos_Arras_Mx_Agosto_2026_1789269062.xlsx`) is the real name; copy the GUID file to it before attaching or sending anywhere.
   - Completion: a non-zero file exists and is renamed to the suggested filename.

## Pitfalls

- Both "Exportar a Excel" (menu) and "Exportar" (dialog) must be clicked — the first click alone produces nothing.
- No download event + empty download dir after the dialog confirm means the click no-op'd; redo step 4–5 rather than waiting longer.
- To view a captured screenshot yourself, save it under the OpenClaw workspace (e.g. `...\.openclaw\workspace\`), not `$env:TEMP` — `view_image` rejects paths outside its allowed directories.
