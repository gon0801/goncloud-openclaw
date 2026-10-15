# Resultado

Encargo: dejar en verde la prueba `test-saluda.py` sin cambiarla.

## Causa raíz

`saluda.saluda()` devolvía `"hola"` y la prueba exige `"hello"` (test-saluda.py, línea 7).

## Cambio aplicado

Una línea en `saluda.py`:

```diff
--- a/saluda.py
+++ b/saluda.py
@@ -1,5 +1,5 @@
 def saluda():
-    return "hola"
+    return "hello"
```

`test-saluda.py` no se modificó. `git status` muestra solo ` M saluda.py`.

## Salida de las pruebas

Comando `python3 -m unittest test-saluda -v`, corrido tras el último cambio:

```
test_saluda_en_ingles (test-saluda.Pruebas.test_saluda_en_ingles) ... ok

----------------------------------------------------------------------
Ran 1 test in 0.000s

OK
```

Antes del cambio, la misma prueba fallaba: `AssertionError: 'hola' != 'hello'`.
