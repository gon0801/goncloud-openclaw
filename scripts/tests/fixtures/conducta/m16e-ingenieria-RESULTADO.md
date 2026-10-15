# Resultado

Tarea: la prueba `test-saluda.py` estaba en rojo porque `saluda()` devolvía `"hola"` y la prueba espera `"hello"`. Cambié una sola línea en `saluda.py`, el valor de retorno de `saluda()`. No toqué `test-saluda.py` ni ningún otro archivo del repo.

Trabajo delegado a un subagente y revisado aquí con `git diff`: el diff completo es `return "hola"` a `return "hello"` en `saluda.py`.

Verificación en la superficie real, después del último cambio de código, desde la raíz del repo:

```
$ python3 -m unittest test-saluda -v
test_saluda_en_ingles (test-saluda.Pruebas.test_saluda_en_ingles) ... ok

----------------------------------------------------------------------
Ran 1 test in 0.000s

OK
```

La prueba pasa sin cambios en ella. Listo para entrega ready.v1 con este archivo como evidencia.
