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

## La debilidad real del detector 2.1 (matriz recalculada por el operador)

Sobre el corpus citado (22 verbatim), agrupando segun la etiqueta esperada:

| Esperado | Citado | Atrapados (correcto) | No atrapados / sobre-marcados (incorrecto) |
|---|---:|---:|---:|
| DEBEN detectarse (A + B) | 16 | **16** | 0 |
| LEGITIMOS (C) | 6 | 5 (sobre-marcados) | **1** (bien ignorado) |

Lectura: el detector 2.1 **no se le escapa nada de lo que debe atrapar**
(16/16) y **sobre-marca 5 de 6 textos legitimos** (83%). Los 5
sobre-marcados del grupo C son los reportes de scout/reviewer/main que
el PR #15 ya rechazaba; el observer 2.1 hereda esa misma superficie y los
escribe al jsonl igual. La limpieza ocurre aguas abajo cuando 2.2 mira
`tools` (los legitimos suelen venir acompanados de counts de read / write
/ grep / sessions_send; las rendiciones reales suelen venir solas).

El unico verbatim que el detector **bien ignora** es:

```
Resumen del 09-12: el agente dijo que no puede tipear en ttys001.
```

Es un recap en pasado de la incapacidad de otro agente; no contiene la
frase disparadora (`no hay`, `sin herramienta`, `fuera de`, etc.) ni un
token incidental, asi que INCAPACITY_RE no lo toma. **No es un costo del
detector, es el unico acierto del grupo C.** Esta fila NO debe leerse
como debilidad del detector: si una PR futura intentara ampliar
INCAPACITY_RE para cubrirla, estaria rompiendo el unico caso donde el
lado-C sale bien, y la matriz 16/16 + 5/6 pasaria a peor.

Politica del corpus: NO se mueven filas esperadas de C a A para "bajar
la tasa de miss". La matriz se declara como esta; el trade-off
(sobre-registro recuperable por `tools` en la siguiente fase) es la
decision del operador y NO se invierte desde el detector.

## Politica

- **Citar verbatim** lo que esta escrito en el finding — el round-trip texto -> TSV -> regla del detector debe poderse rehacer a ojo, sin acceso al `probe.mjs` desaparecido.
- **No incluir parafrasis** de lo que el adversario pudo haber querido decir.
- **Discrepancias se reportan aqui** y se alinean con la seccion "Trade-offs" del PR #22 body, no se ocultan en el corpus.

## Como se regenera el corpus

> **CAMINO MUERTO, no lo sigas.** El TSV se renderizo ejecutando `node /tmp/render-corpus-tsv.ts` desde el worktree `_wt-fase2` con el branch `fase2/3.2-corpus`. La clasificacion (`detected`/`missed`) se calculo contra `INCAPACITY_RE` **importado directamente** desde `summa-gate/observer.ts` (post-rename de `readSkill->hadRead`), no contra un regex copiado a mano. Esto hace que la migracion del regex en una PR futura se pueda auditar re-corriendo el mismo script contra el nuevo branch.
>
> Ese archivo vive en `/tmp` y se borra al reiniciar. La reproduccion buena es `node summa-gate/verify-corpus.mjs` (mas abajo), que usa solo el TSV y el detector, ambos en el repo.

## Como reproducir este corpus (sin depender de nada efimero)

```sh
node summa-gate/verify-corpus.mjs
```

Recalcula la columna `verdict_2_1` de cada fila contra el detector vivo
(`buildRecord` en `summa-gate/observer.ts`) y falla si alguna no coincide. Tambien
imprime la matriz de arriba. Las dos piezas que necesita viven en el repo: el TSV y el
detector.

El PR original apuntaba a `/tmp/render-corpus-tsv.ts`, que se borra con el reinicio de la
maquina — el mismo defecto que este documento le reprocha a `probe.mjs` unas lineas mas
arriba. Anotado aqui a proposito: el artefacto re-derivable es el criterio de la Fase 3,
y es facil violarlo sin darse cuenta.
