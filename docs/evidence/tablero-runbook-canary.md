# Canary tablero-runbook 7.6 — opcion (a) del dueno

Fecha: 2026-09-17 (21:13 PDT / 2026-09-18T01:13:48Z).
Rama: fase7/cierre (PR 69 abierto, no mergeado).
Gateway: vivo, runtimeVersion 2026.9.3 (status responde).
Plugins: tablero-runbook enabled true state enabled v0.1.0; summa-gate enabled true state enabled v0.1.0 (salida filtrada de plugins.list, verbatim abajo).
Alcance de esta evidencia (opcion (a)): canary RPC que guarda y devuelve avance de fase (primer canary, github.enabled false). No incluye segundo canary (github.enabled true), ni timestamps de cron, ni la prueba de bloqueo de fusion: esos quedan fuera de la opcion (a) y se declaran como no corridos aqui.

Sustitucion declarada (runbook autopilot-fase7 Q3): toda la evidencia del HTML sale por RPC, sin peticion autenticada. El doc de runbook.progress.get es el cuerpo que la DoD llama GET /runbook/progress/6.json.

## 1. runbook.progress.set (guarda)

Comando (runbook Q3, desde la Mac):

```
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat tablero-runbook/fixtures/fase6-en-curso.json)" --timeout 30000
```

Salida verbatim:

```
Gateway call: runbook.progress.set
{
  "ok": true
}
```

## 2. runbook.progress.get (devuelve)

Comando:

```
~/.openclaw/bin/openclaw gateway call runbook.progress.get --params '{"fase":"6"}' --timeout 30000
```

Salida verbatim (encabezado + claves; doc completo en el gateway, extracto abajo; salida integra de 14605 bytes guardada en /tmp/canary-get.json de la Mac durante la corrida):

```
Gateway call: runbook.progress.get
{
  "ok": true,
  "doc": {
    "schema": "runbook-progress.v1",
    "runbook": "docs/runbooks/autopilot-fase6.md",
    "fase": "6",
    "titulo": "Autopilot de la Fase 6",
    "siguiente_paso": "Esperando la ventana 19:16-21:05 para mergear ingenieria; operaciones entra a revision cruzada y G queda declarado."
  },
  "derivado": {
    "totalCarriles": 7,
    "mergeados": 1,
    "porcentajeMergeado": 14,
    "carrilesAtorados": ["G"],
    "colaAtorada": [],
    "siguienteCola": {"id": "Q1", "estado": "pendiente", "prs": 0},
    "minutosDesdeUltimoEvento": 1833
  },
  "html": "<!doctype html>... (7318 caracteres; ver primeras 30 lineas abajo)"
}
```

Campos que prueban el guardado (verbatim del doc devuelto):

- titulo: Autopilot de la Fase 6
- fase: 6
- siguiente_paso: Esperando la ventana 19:16-21:05 para mergear ingenieria; operaciones entra a revision cruzada y G queda declarado.
- derivado.carrilesAtorados: ["G"], derivado.porcentajeMergeado: 14

Primeras 30 lineas del html (verbatim):

```
01: <!doctype html>
02: <html lang="es">
03: <head>
04: <meta charset="utf-8">
05: <meta name="viewport" content="width=device-width, initial-scale=1">
06: <title>Autopilot de la Fase 6</title>
07: <style>:root{color-scheme:light dark}
08: *{box-sizing:border-box}
09: body{font:14px/1.45 sans-serif;margin:0;padding:24px;background:#f6f7f9;color:#1c2430}
10: main{max-width:1080px;margin:0 auto}
11: h1{font-size:22px;margin:0 0 4px}
12: h2{font-size:15px;margin:28px 0 8px;text-transform:uppercase;letter-spacing:.06em;color:#5b6675}
13: .atencion{background:#8a1c1c;color:#fff;padding:12px 16px;border-radius:8px;margin:0 0 16px;font-weight:600}
14: .siguiente{font-size:17px;margin:8px 0 20px;padding:10px 14px;background:#eef3fb;border-left:4px solid #2b5cb8;border-radius:6px}
15: .resumen{display:flex;flex-wrap:wrap;gap:12px;margin:0 0 8px}
16: .resumen div{background:#fff;border:1px solid #dde3ea;border-radius:8px;padding:8px 14px}
17: .resumen .num{font-size:20px;font-weight:700;display:block}
18: .barra{height:8px;background:#dde3ea;border-radius:4px;overflow:hidden;margin:6px 0 2px}
19: .barra i{display:block;height:100%;background:#2f9e44}
20: table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #dde3ea;border-radius:8px}
21: th,td{text-align:left;padding:7px 10px;border-top:1px solid #e6eaf0;vertical-align:top;font-size:13px}
22: th{border-top:0;background:#eef1f5;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
23: .estado{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;background:#e5e8ec}
24: .estado.mergeado{background:#d9f0dd}.estado.atorado{background:#f6d7d7}
25: .gh{display:inline-block;margin-top:3px;font-size:12px;padding:1px 7px;border-radius:8px}
26: .gh-off{background:#e5e8ec;color:#444}.gh-ok{background:#dce8f8}.gh-unk{background:#f0e0d0}
27: .mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
28: ul.res{margin:0;padding-left:16px}
29: .eventos li{margin:4px 0}
30: footer{margin-top:28px;color:#5b6675;font-size:12px;border-top:1px solid #ccd4dd;padding-top:10px}
```

Rotulo GitHub (verbatim, lineas del html donde aparece; prueba del primer canary con cruce apagado):

```
45: <div><span class="num" style="font-size:14px">GitHub: sin verificar</span>cruce apagado</div>
53: <td>gon0801/goncloud-workspace-main <span class="mono">#15</span><div><span class="gh gh-off">GitHub: sin verificar</span></div></td>
62: <td>gon0801/goncloud-workspace-ingenieria <span class="mono">#8</span><div><span class="gh gh-off">GitHub: sin verificar</span></div></td>
```

Comprobaciones: titulo (Autopilot de la Fase 6) presente en html = si; GitHub: sin verificar presente = si; GitHub presente = si.

## 3. plugins.list (los dos habilitados)

Salida verbatim filtrada a los dos plugins:

```
{"id": "summa-gate", "enabled": true, "state": "enabled", "version": "0.1.0"}
{"id": "tablero-runbook", "enabled": true, "state": "enabled", "version": "0.1.0"}
```

## Que prueba

Que el plugin guarda (set hacia ok:true) y devuelve (get hacia doc, derivado, html) el avance de una fase; que el html lo construye el plugin (titulo del fixture y rotulo GitHub: sin verificar con cruce apagado); y que convive con summa-gate (los dos habilitados).

## Veredicto

PASS para guardar y devolver avance de fase (opcion (a)): set ok, get ok con doc/derivado/html, titulo y GitHub: sin verificar presentes en el html.

## Restauracion de la Fase 6 (hallazgo, no verde)

Tras el canary se intento devolver la Fase 6 a su estado real versionado (runbook Q3):

```
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/fase6.json)" --timeout 30000
```

Salida verbatim:

```
Gateway call: runbook.progress.set
{
  "ok": false,
  "razones": [
    "cierre.resumen: debe ser texto acotado o null"
  ]
}
```

Causa medida: .saikit/progress/fase6.json trae cierre.resumen de 340 caracteres y el validador (tablero-runbook/lib.ts, TEXTO_MAX = 300) lo rechaza. No se escribio ningun truncado por cuenta propia: el gateway conserva el fixture fase6-en-curso.json hasta que el resumen real se acote o el validador se ajuste. Queda como residual declarado.

## Telegram al dueno (pendiente del turno de cierre)

El aviso a David con el enlace al tablero sale en el turno de cierre; no lo manda este paso.

- Enlace: http://100.80.179.76:18789/runbook/tablero/7
- message_id: se envia despues del merge de cierre; queda en el progreso vivo (sitio marcado; lo pone el lead).
