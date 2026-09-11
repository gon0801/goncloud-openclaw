---
name: Regression red verify
description: Cuando un test de regresion nuevo debe demostrarse en ROJO sin su proteccion (regla 9 de Orbit, verificacion de discriminacion por mutaciones, de borrado o de debilitamiento). Produce una tabla mutacion -> test rojo con restauracion verificada.
---

# Regression red verify

Probar que cada test de regresion DISCRIMINA: quitada su proteccion, se
pone rojo. Un test que sigue verde sin el fix no protege nada.

## Pasos

1. Commitea el fix ANTES de correr el driver: la restauracion se verifica
   con `git diff --quiet <modulo>` y un fix sin commitear ensucia el diff
   aunque la restauracion sea perfecta.
2. Corre el archivo de tests enfocado y registra la linea base (passed).
   Todo verde ANTES de mutar. La base corre con el MISMO entorno (PATH
   incluido) que el verde final; un rojo ambiental preexistente (p. ej.
   `timeout` ausente en el PATH restringido) se declara y se excluye por
   evidencia, no se arregla fuera de alcance.
3. Escribe UN driver que, por cada proteccion documentada del modulo,
   aplique UNA mutacion que simule revertirla o DEBILITARLA (piso de
   longitud, guarda reducida, forma del reemplazo), sobre el archivo REAL
   (nunca una copia: mutar una copia deja la suite verde y produce la
   conclusion falsa de que nada se tumba):
   - Sustituye la linea protegida por un no-op con sintaxis valida
     (`pass  # mutacion: ...`). Nunca borres la unica linea de un bloque
     `if`: el modulo queda roto de importacion, pytest reporta ERROR de
     coleccion y corre CERO tests.
   - Nombra cada mutacion por la proteccion que revierte y el test que
     deberia ponerse rojo.
   - Si lo mutado es un GENERADOR/escritor que declina sobreescribir un
     artefacto presente ("ya hay..., no se escribe"): borra el artefacto
     previo antes de correr el mutado, o la asercion leera salida vieja
     y reportara que la mutacion no quito nada (medido con el workflow
     de saikit-ci-minimo).
   - Relee el archivo mutado y afirma que su sha cambio antes de correr:
     la mutacion debe estar EN DISCO al importar pytest.
4. Clasifica cada corrida DENTRO del driver (no a mano despues) por el
   CONTADOR del resumen (`N failed`), nunca por las lineas `FAILED`
   capturadas: con `--tb=line` hay lineas resumen `FAILED <ruta>` sin
   mensaje detras y una regex con espacio final (`^FAILED (\S+?) `) las
   pierde (14 falsos "no roja" medidos en Orbit ronda 2). Los nombres
   para la tabla van con `^FAILED (\S+)`, sin espacio final.
   - `N failed >= 1` Y passed+failed igual a la linea base -> roja: bien.
   - resumen solo "N passed" -> se quedo verde: ALERTA, ese test no
     protege.
   - errores de coleccion / cero tests corridos / passed+failed != base
     -> NO VERIFICADO (la mutacion rompio sintaxis): repetir con mutacion
     valida. Cero corridas NO es verde.
5. Restaura los bytes originales en un `finally` tras cada corrida y
   verifica la restauracion ANTES de la siguiente mutacion (sha identico
   + `git diff --quiet <modulo>`); al final el archivo enfocado vuelve a
   estar verde.
6. Reporta la tabla mutacion -> test rojo y declara toda mutacion que
   necesito un segundo intento; el falso verde del driver es evidencia
   del chequeo, no ruido que ocultar.

## Criterio de cierre

Una corrida del driver con TODAS las mutaciones rojas (o sus alertas
explicadas una por una), collected igual a la base en cada corrida y
restauracion verificada del modulo.
