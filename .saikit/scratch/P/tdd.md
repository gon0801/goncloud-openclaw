# TDD del carril P (Fase 7) — rojos pegados

## 7.1 — rojo primero, sin validador

Commit 929ed08: `progress.test.ts` se commitea ANTES de que exista `lib.ts`.
Salida verbatim (`71-rojo.txt`, recorte):

```
✖ progress.test.ts (44.88ms)
  code: 'ERR_MODULE_NOT_FOUND',
  url: 'file:///Users/dn/dev/wt-f7-P/tablero-runbook/lib.ts'
ℹ pass 0
ℹ fail 1
```

## 7.3 — mutantes (todos ROJO; batería 32 pass en ese commit)

Ejecutado por `73-mutantes.sh`, salida en `73-mutantes.txt`:

| Mutante | Resultado |
|---|---|
| quitar `esc()` (script en titulo/repo/check aparece literal) | ROJO |
| invertir truncar/escapar (entidad cortada) | ROJO |
| quitar el truncado | ROJO |
| aceptar un `estado` fuera de lista | ROJO |
| aceptar `fase` con `/` o `..` | ROJO |
| aceptar `repo` con `;` o que empiece con `-` | ROJO |
| perder eventos previos al fusionar | ROJO |

Detalle del discriminante del orden truncar/escapar (mutante invertir):

```
✖ ninguna entidad queda cortada: truncar PRIMERO, escapar después (mutante invertir orden)
ℹ pass 31
ℹ fail 1
```

## 7.5 — mutantes (todos ROJO; batería 60 pass en ese commit)

Ejecutado por `75-mutantes.sh`, salida en `75-mutantes.txt`:

| Mutante | Resultado |
|---|---|
| quitar el flag `enabled` | ROJO (pass 58 / fail 2) |
| aceptar repo envenenado (`a/b; calc.exe`, `--template x`) | ROJO (pass 58 / fail 2) |
| aceptar `ghPath` en `.cmd` | ROJO (pass 59 / fail 1) |
| quitar el kill por llamada (timeout/SIGKILL de execFile) | ROJO (pass 59 / fail 1) |
| sin NINGÚN kill (ni por llamada ni verdugo) | ROJO (pass 57 / fail 1, cae por timeout) |

## VERIFY final (HEAD 28e8c9b)

- `bash scripts/run-checks.sh` → `TODO VERDE`, exit 0 (`verify-run-checks.txt`).
- `cd tablero-runbook && node --test` → `ℹ tests 60 · pass 60 · fail 0` (`verify-node-test.txt`).

## 9.6 — rojo primero (carril P, Fase 9)

Batería `scripts/tests/test-corrida-responder.sh` commiteada ANTES de que exista
`scripts/mac/corrida/responder.sh`. Salida verbatim:

```
FAIL: falta scripts/mac/corrida/responder.sh
```

Y el despachador del núcleo todavía no lo carga:

```
$ bash scripts/mac/corrida.sh responder r0
subcomando desconocido: responder   (rc=2)
```

Casos de la batería (resumen): nace apagado (1), confianza.txt => acepta (2),
lista dura push a main y rm -rf con fila Aprobado => escala (3), Aprobado/Negado/
sin fila (4), límite de uso => conserva modelo + marca cuota (5), confianza con
ruta propia/ajena (6), sesión sin registro jamás se toca (7), patrón ancho =>
rechazado al cargar (8), pantalla cambiada entre lectura y envío => no manda
nada (9), tres diálogos en 10 min => cambio de modo (10), tecla unknown =>
escala (11).

## 9.6 — mutantes (ambos ROJO; batería verde en el commit)

Ejecutado por `96-mutantes.sh`, salida en `96-mutantes.txt`:

| Mutante | Resultado |
|---|---|
| sin relectura TOCTOU (resp_relee siempre "intacta") | ROJO (caso 9: pantalla cambiada ⇒ tecla) |
| sin lista dura (el comando cae directo a la tabla) | ROJO (caso 3: push a main Aprobado ⇒ tecla) |

Verde final (bash y /bin/bash 3.2): TODO VERDE en corrida-responder,
tmux-activity-watch, corrida-nucleo, corrida-preflight y cli-modos;
`git diff --numstat origin/main -- scripts/tests/test-tmux-activity-watch.sh`
=> `80	0` (solo agregados).

## 9.6 · BRIEF-r1 — rojo del endurecimiento PB

Caso (4d) agregado antes de la corrección: transcript con `rm -rf /tmp/viejo`
arriba y el diálogo real (`echo hola`, fila Aprobado) abajo. Salida verbatim:

```
FAIL: (4d) debía decidir sobre el comando del diálogo (echo hola, Aprobado)
```

Con la política de "primera línea tipo comando" el responder elegía el rm -rf
viejo del transcript, caía en la lista dura y escalaba: la decisión se tomaba
sobre el texto equivocado.

Corrección aplicada (resp_comando prefiere la ÚLTIMA línea tipo comando):
caso (4d) verde en `bash` y `/bin/bash`; las cinco baterías en TODO VERDE;
numstat de la batería del vigilante 102/0.

## 9.6 · BRIEF-r1 — PA y PC (sin rojo propio: cambios de una línea)

PA: `run_once` fija `CORRIDA_BIN` a una ruta inexistente por defecto; caso
(2k) comprueba que sin `CORRIDA_BIN` explícito el diálogo produce el evento
como hoy. PC: línea de `CORRIDA_BIN` en el bloque Env del header del
vigilante. PD (python3 ausente ⇒ eventos.jsonl malformado) queda anotado, sin
acción, como pide el encargo.

## 9.6 · BRIEF-r2 — rojos (QA Major y QB), pegados antes de sus correcciones

QA (vigilante): el stub de política devuelve 0 pero NO consume la tecla (el
prompt sigue en pantalla) — hoy el vigilante suprime la escalada:

```
FAIL: (2j-QA) la politica devolvio 0 pero el prompt SIGUE: la escalada debe salir en el mismo ciclo; hubo 0
```

QB (responder): tercer diálogo de lista dura en 10 min — la ráfaga corre antes
de la política y manda el cambio de modo:

```
FAIL: (10c) el tercer diálogo de lista dura no se contesta, ni con tecla ni con modo
```

QE (vigilante): journal como directorio (todo append falla) — hoy el fallo pasa
en silencio y la notificación sigue su curso sin rastro:

```
FAIL: (2m) el fallo del journal debe quedar dicho en el log
```

QC (responder): el envío del cambio de modo falla (stub send-keys rc 1) y la
ráfaga igual devuelve éxito:

```
FAIL: (10d) el fallo del envío de modo no es éxito
```

QD (responder): con el validador caído, "limpio" se viste de "no casa" (el
registro sintético era SIEMPRE inválido, rc 1 por cualquier motivo):

```
FAIL: (12) contrato de resp_lista_dura: 0=dura 1=limpio 2=sin comprobar; salió: 0 1 1
```

Correcciones aplicadas: (2j-QA) dialog_gone re-sondea la pantalla (ausente en
dos capturas seguidas) antes de suprimir la escalada; (10c) la ráfaga va
DESPUÉS de la política; (10d) los send-keys del modo se comprueban y su fallo
escala; (12) resp_lista_dura con registro sintético válido y contrato 0/1/2 (el
llamador trata el 2 como escala). Verde final: las cinco baterías en TODO VERDE
con bash y /bin/bash 3.2; numstat del vigilante 64/0 y de su batería 145/0;
los dos mutantes del DoD siguen ROJO (96-mutantes actualizado a la nueva forma
de la llamada a resp_lista_dura).
