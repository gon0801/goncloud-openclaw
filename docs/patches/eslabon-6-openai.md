# Eslabon 6 — OpenAI (documentado, no aplicar)

OpenAI no es cola de cadena todavia. No es solo la cuota `prolite` al 100 % hasta 2026-09-15.

## Por que

Los modelos OpenAI por OAuth corren en el harness `codex`. El resto de la flota corre nativo. Cuando un fallback cruza esa frontera a media corrida, el intento muere con `prepared model runtime plugin generation was superseded`. Eso mato 4 corridas de `ingenieria` (7 `model-fallback/decision` en 90 s en el diagnostico).

Una cadena nativa → OpenAI-OAuth mezcla runtimes. Mientras el rescate no se pruebe de punta a punta, OpenAI-OAuth es un eslabon que se ve vivo y mata la corrida.

## Condicion para ponerlo

1. Forzar una corrida donde los eslabones nativos fallen.
2. Verificar que el rescate a OpenAI **completa** en vez de morir por cambio de runtime.
3. Solo entonces agregar un eslabon OpenAI (preferible API key, que corre nativo, no OAuth).

## Alternativa

API key de OpenAI (no OAuth) en el provider. Corre nativo y no cruza a codex.

## Estado

`not_observed`: no se forzo el fallo de eslabones nativos ni se midio un rescate OpenAI completo en esta entrega.
