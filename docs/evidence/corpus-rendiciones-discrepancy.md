# corpus-rendiciones — discrepancia contra el plan

El plan establecia **23 entradas detectables + 8 legitimas no detectables** como corpus objetivo para la Fase 2 / 3.2. El conteo real de `corpus-rendiciones.tsv` es **22 entradas citadas (de 42 probadas)**, con este desglose:

| Grupo | Significado | Citado | claimed_count (probado) | Detectadas 2.1 | Missed 2.1 |
|---:|---|---:|---:|---:|---:|
| A | incapacidad real (deberian detectarse) | 8 | 23 | 8 | 0 |
| B | escape via `JUDGMENT_REFUSAL_RE` (deberian detectarse, escapan por la pre-excepcion) | 8 | 11 | 8 | 0 |
| C | legitimos bloqueados por `INCAPACITY_RE` del PR #15 (no deberian detectarse) | 6 | 8 | 5 | 1 |

Total: **22 citadas / 42 probadas**, **21 detectadas**, **1 missed**.

## Por que no aparecen las 20 que faltan

El corpus debe ser reconstruible a partir de un finding escrito por el adversario. El unico finding disponible es `.saikit/findings/adversary-20260912T175152Z.json` (1x13 300 bytes), y dentro de el las listas de textos son **demostrativas** (los 23 probados, los 8 legitimos) — el adversario cita los ejemplos mas claros pero no transcribe el corpus completo. La diferencia es:

- Grupo A: `finding[3].trigger` cita 8 ejemplos de los 23 probados (`probe.mjs — seccion A: 23 de 23 renglones`). Los 15 faltantes no aparecen verbatim en el finding y no son reconstruibles sin `probe.mjs`. **No los invento.**
- Grupo B: `finding[2].evidence` lista 8 escapes de los 11 probados (`probe.mjs — seccion B, 11 de 11`). Los 3 faltantes estan en el mismo limbo.
- Grupo C: `finding[0].evidence` lista 5 BLOCK + 1 pass = 6 de 8. Los 2 faltantes tampoco estan verbatim en el finding.

## El `missed` (1)

Unico verbatim que el regex 2.1 NO detecta y figura como legitimate-but-blocked:

```
Resumen del 09-12: el agente dijo que no puede tipear en ttys001.
```

Diagnostico: el regex (`INCAPACITY_RE` en `summa-gate/observer.ts:67+`) requiere una **formula de la lista cerrada** o un token incidental. La frase usa `no puede` en futuro informal, **sin combinacion de palabras claves** (`no hay`, `sin herramienta`, `fuera de`, etc.), por lo que se filtra. Esto es exactamente el costado del trade-off declarado en el PR #22: detector sobre-registra, **no se optimiza para cubrir todas las reformulaciones**. Cubrir este caso agregaria ruido (atraparia tambien recaps reales que NO son rendiciones), asi que se deja pasar y el guard queda `detected=false` — el costo es una reincidencia no registrada, no una falsa aceptacion.

## Politica

- **Citar verbatim** lo que esta escrito en el finding — el round-trip texto -> TSV -> regla del detector debe poderse rehacer a ojo, sin acceso al `probe.mjs` desaparecido.
- **No incluir parafrasis** de lo que el adversario pudo haber querido decir.
- **Discrepancias se reportan aqui** y se alinean con la seccion "Trade-offs" del PR #22 body, no se ocultan en el corpus.

## Como se regenera el corpus

El TSV se renderizo ejecutando `node /tmp/render-corpus-tsv.ts` desde el worktree `_wt-fase2` con el branch `fase2/3.2-corpus`. La clasificacion (`detected`/`missed`) se calculo contra `INCAPACITY_RE` **importado directamente** desde `summa-gate/observer.ts` (post-rename de `readSkill->hadRead`), no contra un regex copiado a mano. Esto hace que la migracion del regex en una PR futura se pueda auditar re-corriendo el mismo script contra el nuevo branch.
