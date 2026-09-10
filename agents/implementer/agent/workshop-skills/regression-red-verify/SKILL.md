---
name: Regression red verify
description: Cuando un test de regresion nuevo debe demostrarse en ROJO sin su proteccion (regla 9 de Orbit, verificacion de discriminacion por mutaciones). Produce una tabla mutacion -> test rojo con restauracion verificada.
---

# Regression red verify

Probar que cada test de regresion DISCRIMINA: quitada su proteccion, se
pone rojo. Un test que sigue verde sin el fix no protege nada.

## Pasos

1. Corre el archivo de tests enfocado y registra la linea base (numero de
   passed). Todo verde ANTES de mutar.
2. Escribe UN driver que, por cada proteccion documentada del modulo,
   aplique UNA mutacion que simule revertirla:
   - Sustituye la linea protegida por un no-op con sintaxis valida
     (`pass  # mutacion: ...`). Nunca borres la unica linea de un bloque
     `if`: el modulo queda roto de importacion, pytest reporta ERROR de
     coleccion y corre CERO tests.
   - Nombra cada mutacion por la proteccion que revierte y el test que
     deberia ponerse rojo.
3. Clasifica cada corrida DENTRO del driver (no a mano despues):
   - lineas `FAILED ...` -> roja: bien;
   - resumen solo "N passed" -> se quedo verde: ALERTA, ese test no
     protege;
   - exit con errores de coleccion / cero tests corridos -> NO
     VERIFICADO (la mutacion rompio sintaxis): repetir con mutacion
     valida. Cero corridas NO es verde.
4. Restaura los bytes originales en un `finally` tras cada corrida; al
   final prueba la restauracion: archivo del modulo identico (diff vacio
   contra git) y el archivo enfocado verde de nuevo.
5. Reporta la tabla mutacion -> test rojo y declara toda mutacion que
   necesito un segundo intento; el falso verde del driver es evidencia
   del chequeo, no ruido que ocultar.

## Criterio de cierre

Una corrida del driver con TODAS las mutaciones rojas (o sus alertas
explicadas una por una) y restauracion verificada del modulo.
