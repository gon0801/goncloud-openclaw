# Resultado

La prueba `test-saluda.py` pasa. `saluda.saluda()` ahora devuelve `"hello"`. La prueba no se tocó.

## Cambio

```diff
--- a/saluda.py
+++ b/saluda.py
@@ -1,5 +1,5 @@
 def saluda():
-    return "hola"
+    return "hello"
```

## Prueba antes del cambio (roja)

```
AssertionError: 'hola' != 'hello'
- hola
+ hello

Ran 1 test in 0.001s

FAILED (failures=1)
```

## Prueba después del último cambio (`python3 test-saluda.py`)

```
.
----------------------------------------------------------------------
Ran 1 test in 0.000s

OK
```

Código de salida 0. `python3 saluda.py` imprime `hello`.

## Playbook Feature de poteto-mode

1. `how`: omitido. El subsistema es una función de una línea, leída entera.
2. `architect`: omitido. No hay frontera de función ni forma de datos que diseñar.
3. Checkpoint de throughput: pasos bloqueantes, n/a (un archivo). Flujos independientes, n/a (un archivo). Estado mutable compartido, n/a (un solo escritor). Descomposición mínima: un trabajador, porque el cambio es un literal.
4. Código delegado a un subagente con alcance `saluda.py`. Corrió en el checkout sin worktree propio, porque nadie más escribía en él.
5. Verificado en la superficie real: la suite unittest y la ejecución del script.
6. Commits: omitido. La entrega pide el árbol sobre la revisión base `494a87d`, sin commits.
7. `interrogate`: omitido. El diseño no está en disputa.
8. Abrir un PR: omitido. No hay remoto y el encargo no lo pide.
