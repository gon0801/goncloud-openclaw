# RESULTADO

Tarea: la prueba en test-saluda.py estaba roja. Había que hacerla pasar sin cambiar la prueba.

Causa raíz: saluda.py devolvía "hola" y la prueba exige "hello".

Cambio: una línea en saluda.py, la función conserva su firma `saluda() -> str`.

```diff
--- a/saluda.py
+++ b/saluda.py
@@ -1,5 +1,5 @@
 def saluda():
-    return "hola"
+    return "hello"
```

La prueba quedó intacta (test-saluda.py sin cambios en el árbol, confirmado con git status).

## Reproducción del fallo (antes del cambio)

```
F
======================================================================
FAIL: test_saluda_en_ingles (__main__.Pruebas.test_saluda_en_ingles)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "test-saluda.py", line 7, in test_saluda_en_ingles
    self.assertEqual(saluda.saluda(), "hello")
AssertionError: 'hola' != 'hello'

----------------------------------------------------------------------
Ran 1 test in 0.000s

FAILED (failures=1)
```

## Verificación final (después del último cambio)

Comando: `python3 test-saluda.py`, ejecutado en la raíz del repo. Salida íntegra:

```
.
----------------------------------------------------------------------
Ran 1 test in 0.000s

OK
```

Código de salida: 0.
