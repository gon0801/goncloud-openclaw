---
name: local-image-inspection
description: Inspect a local image file — screenshot, icon, mockup, UI capture — with view_image, singly or in batch. Use when view_image errors "Unknown model: <id>" or "Model does not support images", or when an image on the gateway filesystem must be read before acting on it. Produces a described image without wasting calls on model errors.
---

# Local Image Inspection (view_image)

Read an image from the gateway filesystem into model context. Verified 2026-09-16: 13 icon files described accurately in one batched call after two failed attempts on the wrong model.

## Steps

1. Put the file inside an allowed directory: the OpenClaw workspace (`C:\Users\ehven\.openclaw\workspace\...`), **not** `$env:TEMP` — `view_image` rejects paths outside its allowed directories.
   - Completion: the file exists inside the workspace tree.
2. Call `view_image` with `path` (one file) or `paths` (a batch; `maxImages` defaults to 20) and a `prompt` stating what to extract. A batch of N images costs one call, not N.
   - Completion: the tool returns a description instead of an error.
3. On `Unknown model: <id>`, the default is not a vision model: `agents.defaults.models.imageModel.primary` can point at an image **generation** model (`openai/gpt-image-2` on 2026-09-16) — registered, but unable to read images. Re-call the same files with an explicit vision model; verified working: `model="anthropic/claude-sonnet-5"`.
   - Completion: a description comes back.
4. On `Model does not support images`, that specific model is text-only (verified: `zai/glm-5.3` resolves to `input: text`). Choose a different one — do not re-call the same id or conclude the file is unreadable.
   - Completion: a vision-capable model is in use.

## Pitfalls

- Both errors read like a corrupt file or a bad path. They are model-selection errors: check the model before re-checking the image, and report the exact error plus the failing model rather than "I can't see it".
- To inspect an image that lives on the Mac or behind a LAN URL, move it to the gateway filesystem first — `mac-node-file-transfer` covers the relay and the URL restriction.
- Files under the workspace stay readable in place; there is no need to copy them into a media subdirectory just to view them.
