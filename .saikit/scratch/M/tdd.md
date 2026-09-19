# Carril M — TDD (rojo inicial por tarea)

## 9.4 estado (2026-09-19)
Rojo inicial (limpio): sin `corrida/estado.sh`, el despachador dice `subcomando
desconocido: estado` y la prueba muere en `FAIL: estado fallo en avanza:
subcomando desconocido: estado` (rc=1), con solo la prueba y los fixtures en el
arbol. Verde tras implementar: `TODO VERDE: test-corrida-estado`.
Cosas que la prueba pega: los seis escenarios byte a byte contra
`scripts/tests/fixtures/estado/<esc>/esperado.txt`; el mensaje (lineas 1-4) pasa
`mensaje_valido` en los seis; `--solo-mensaje` da solo las cuatro lineas; id con
`../`, corrida sin registro y registro fuera de contrato se rechazan; con gh de
mentira "GitHub: una propuesta abierta" / "GitHub: 2 propuestas abiertas"; panel
con escapes, CR y una linea de 6000 caracteres sale limpio y recortado a 5000
(sangria incluida); dos corridas con reloj inyectado dan los mismos bytes.

## 9.5 latido (2026-09-19)
Rojo inicial (limpio): sin el LaunchAgent la prueba muere en `FAIL: falta el
LaunchAgent del latido` (rc=1); con el plist presente pero sin
`corrida/latido.sh` el despachador daria `subcomando desconocido: latido`.
Verde tras implementar latido.sh + plist: `TODO VERDE: test-corrida-latido`.
Lo que la prueba pega: sin corridas abiertas (y con dirs sin registro valido o
cerrados) cero llamadas; primer tick un AVANZA silencioso anotado en
mensajes.jsonl y eventos.jsonl; dos ticks seguidos no duplican; 59 min sin
cambio 0 mensajes y a los 60 uno (mutacion sin latido por hora muere); un
cambio a menos de 15 min del ultimo mensaje no sale (mutacion sin tope);
carril callado 31 min => DETENIDA + system event al vigia con la accion y el
parte; dialogo de 10 min => NECESITO sonora pese al tope y sin duplicar al
tick siguiente (mutacion sin escalamiento muere); dialogo joven sin cobertura
de politica => NECESITO inmediato; vigia hermes deja linea en eventos.jsonl y
cero system event; con el evento al vigia cayendo el mensaje igual sale (y no
se duplica al tick siguiente), y con el envio cayendo el evento igual sale y
mensajes.jsonl anota ok:false honesto.
Mutaciones verificadas muriendo (archivo restaurado tras cada una, con cmp):
sin latido por hora (la rama de los 60 min), sin escalamiento a NECESITO (la
etiqueta deja de ser especial), sin tope de 15 min (todo cambio sale solo).
Incidente propio del diseno, atrapado por la prueba: el NECESITO que bypassaba
el tope bypassaba tambien la deduplicacion por firma y se remandaba cada tick;
ahora solo bypassa el tope cuando la firma cambio (o lleva 15 min sin
contestacion).

## 9.8 CI rojo (2026-09-19)
Rojo inicial (limpio): con el latido de 9.5 corriendo pero sin el chequeo de
CI, `FAIL: CI rojo: salieron 1 mensajes (debia 2: el parte y el aviso)` (rc=1).
Verde tras el chequeo en el tick: `TODO VERDE: test-corrida-latido`.
Lo que la prueba pega: CI de la rama por defecto en fallo => un DETENIDA en
lenguaje de usuario (pasa mensaje_valido, sin shas dentro) y ci-rojo.json en el
directorio de la corrida con sha, autor y archivos; el mismo sha al tick
siguiente => cero mensajes (mutacion sin memoria del sha: un aviso por tick,
muere aqui); CI verde => cero; gh caido => cero avisos de rojo y el latido
sigue lateando (el parte de la corrida sale igual).
Mutacion verificada muriendo (con cmp de restauracion): sin la memoria del sha
avisado, el mismo sha rojo avisa en cada tick y la prueba muere en el caso
"mismo sha => cero".

## Ronda 1 de revision cruzada (2026-09-19)

### MA (bloqueante): gh caido no discriminaba
La seccion de "gh caido" contaba un AVANZA que con GH_CI por defecto verde
nada probaba: ni un estado que con gh vivo SIBA avisado, ni || fail en el tick.
Rework: corrida propia (lat-gh), GH_CI=rojo GH_SHA fijados + GH_CAIDO=1, todo
tick con || fail, y asserts de cero avisos, cero ci-rojo.json y parte AVANZA.
Rojo pegado (mutacion: gh caido tratado como rojo, con el payload fabricado):
`FAIL: con gh caido salio mas que el parte (msgs=2)` (rc=1); restaurado y en
verde. Ademas: todos los tick de la prueba llevan || fail (auditoria grep).

### fix(9.5) no bloqueantes
MI: evento_jsonl colaba EVT_DIR (ruta absoluta) y EVT_AT duplicado en cada
linea (evidencia: lineas con "DIR": "/var/.../lat-her" y "AT" junto a "at");
excluidos del dict. MJ: para hermes la linea de eventos.jsonl ES el aviso; su
escritura ahora decide firma_vigia (caso 9b: eventos.jsonl como directorio,
dos ticks, no se marca enviada). MK: lat_escribir con rc honrado: escritura
caida tras un envio exitoso avisa a stderr y el tick sale rojo (caso 9c).
MD: declarado no-materializado con prueba minima: lib.sh fija TMUX_BIN al
cargarse (command -v tmux con fallback a /opt/homebrew/bin/tmux) y el
despachador carga lib antes que el subcomando; la prueba (0) lo aserta.
ML: confirmado y corregido: este repo es goncloud-openclaw (git remote
get-url origin); el REPO_DIR del plist apuntaba a goncloud-workspace-main
(otro repo: 9.8 hubiera vigilado el CI equivocado). La prueba (0) compara
el origen del plist contra el del repo.

### fix(9.4) no bloqueantes
MB: singulares ("trabaja 1 sesion", "queda 1 hora", "1 minuto") y
"menos de un minuto" para lo recien nacido (casos 1c de la prueba: sesion
unica, hora unica, dialogo de 30 s). MC: approval_since ausente o en 0 ya no
produce la cifra de 29 millones de minutos: escala (edad eterna) y el texto
dice "mucho rato" (caso 1b). ME: dialogo_cubierto casa el patron en la zona
del dialogo (ultimas 5 lineas no vacias), no en salida vieja. Hallazgo 1 de
la seleccion: iso_a_epoch ahora respeta la zona del ISO
(datetime.strptime+timestamp; timegm ignoraba el offset y la ventana salia
descalzada con inicio fuera de UTC). MH: el caso de determinismo tambien
muestra inyectabilidad (reloj +1 h => "3 horas y 58 minutos"); y la nota del
5000/5002 de arriba se corrige: el tope del recorte es 5000 bytes y la prueba
tolera 5002 contando los 2 de sangria. Incidente propio de la ronda: mis
casos nuevos pisaban watch-avanza/paneles-avanza que el caso --solo-mensaje
reusa; ahora usan directorios propios (pan-mb2/wat-mb2, pan-mb3/wat-mb3).
