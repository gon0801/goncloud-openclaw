# Cron `verif-sync-repos` — vigia del sync de repos

Vive en el gateway: agente `main`, cron `40 */2 * * *` (America/New_York), tools `exec,message,automations`.

Copia versionada de su mensaje. Sin esto el diseno existe solo dentro del cron del gateway
y se pierde si alguien lo borra — la misma disciplina del artefacto re-derivable que este
repo le exige a los agentes.

Para probarlo sin que mande nada: crear una copia one-shot con `--tools exec`. No hay
"modo prueba" por texto; el 2026-09-12 una version con MODO PRUEBA al inicio mando el
Telegram igual porque la prohibicion estaba al final del mensaje.

```
VIGIA SYNC REPOS v1 (job verif-sync-repos; corre cada 2 h; vigila la tarea programada GoncloudRepoSync del host Windows, que sincroniza los 4 repos goncloud cada PT2H y escribe C:\Users\ehven\.openclaw\logs\sync-repos.log). PROPOSITO: el 2026-09-12 el sync quedo roto 1 hora sin que nadie se enterara: el pull fallaba con "cannot pull with rebase: You have unstaged changes", el script lo logueaba y salia con exit 0 igual (correcto: no debe abortar los otros 3 repos por uno). El sintoma que llego a David fue "mergee el PR y el gateway sigue con el codigo viejo". Este job convierte ese fallo silencioso en un aviso. SOLO LECTURA + AVISO: NUNCA correr el sync, NUNCA hacer git pull/push/commit/checkout/reset en ningun repo, NUNCA tocar configuracion ni reiniciar nada. Si crees que hace falta arreglar algo, se lo dices a David y paras.

(PASO 1) Leer la cola del log con exec en el host gateway: tail -40 /c/Users/ehven/.openclaw/logs/sync-repos.log

(PASO 2) Aislar el ULTIMO ciclo: es el bloque de lineas que va desde despues del penultimo "---- ciclo terminado" hasta el ultimo "---- ciclo terminado". Anotar su fecha/hora (la del ultimo "ciclo terminado"). OJO CON EL RELOJ, y NO lo calcules de cabeza: el log usa la hora local del host Windows (America/New_York). NO restes horas a mano — el diferencial con CDMX cambia con el horario de verano de EEUU y CDMX ya no tiene DST, asi que la cuenta mental se equivoca. Verificado el 2026-09-12: son 2 h, no 1 (gateway 20:05 EDT = 18:05 CDMX), y una version anterior de este mismo job decia 1 h y convertia mal. Pedile las dos horas al sistema en un solo exec y usa esa salida: node -e "const d=new Date();console.log('NY',d.toLocaleString('sv-SE',{timeZone:'America/New_York'}),'CDMX',d.toLocaleString('sv-SE',{timeZone:'America/Mexico_City'}))" . Con esas dos referencias del MISMO instante ya podes ubicar cualquier linea del log en CDMX sin restar nada.

(PASO 3) Clasificar en exactamente UNO de tres casos.

CASO A OK: el ultimo ciclo termino hace menos de 3 horas Y ninguna de sus lineas contiene "FALLO" ni "CONFLICTO".

CASO B SIN DATOS: el log no existe, esta vacio, o no tiene ningun "---- ciclo terminado". Tratar como CASO C con causa "no se pudo leer el log del sync".

CASO C FALLA, cualquiera de estas dos, que son problemas distintos y hay que decir cual es:
  C1 EL SYNC FALLA: alguna linea del ultimo ciclo dice "FALLO" o "CONFLICTO". Anotar el nombre del repo y el motivo textual que trae la linea.
  C2 EL SYNC NO ESTA CORRIENDO: el ultimo ciclo termino hace mas de 3 horas. Eso significa que la tarea GoncloudRepoSync dejo de dispararse, que es igual de grave y hoy no lo vigila nada. Anotar hace cuanto fue el ultimo ciclo.

(PASO 4) Antidupliado, obligatorio antes de avisar. Leer el scratch de este job (tool de automations, accion scratch, lectura). Si el scratch guarda el mismo marcador que ibas a reportar, NO avises otra vez: termina con la linea VIGIA SYNC YA AVISADO marcador=<marcador>. El marcador es: para C1, "C1|<fecha-hora del ciclo>|<repo>"; para C2, "C2|<fecha-hora del ultimo ciclo>". Cuando SI avises, escribir ese marcador en el scratch. Un conflicto que dura dias tiene que avisar una vez, no doce veces por dia.

(PASO 5) Actuar segun el caso.

CASO A: no enviar NADA a nadie; el silencio es el resultado correcto. Terminar con una sola linea: VIGIA SYNC OK ciclo=<fecha-hora CDMX>.

CASO C: respetar el silencio de 23:00 a 08:00 CDMX, con UNA excepcion: si el problema lleva mas de 6 horas, avisar igual (a esa altura ya se perdieron 3 ciclos). Si estas en la franja de silencio y no aplica la excepcion, no avises y termina con: VIGIA SYNC DIFERIDO marcador=<marcador>.
Si corresponde avisar: UN solo mensaje por Telegram a David con la tool message (channel telegram, target 6470689715), maximo 6 lineas, sin jerga tecnica, con:
  (1) para C1: "El sync de los repos con el gateway esta fallando"; para C2: "El sync de los repos dejo de correr".
  (2) desde cuando, en hora CDMX.
  (3) que significa en una linea: "hasta que se arregle, lo que mergees en GitHub NO le llega al gateway; los agentes siguen con el codigo viejo".
  (4) el motivo textual del log, una linea, tal cual lo dice (no lo interpretes).
  (5) la pregunta literal: "Lo reviso ahora? Responde SI y lo veo."
No ejecutar nada mas. Terminar con la linea: VIGIA SYNC FALLA tipo=<C1|C2> causa=<causa corta>.

REGLAS: no inventar evidencia. Si exec falla, tratarlo como CASO C con causa "verificacion incompleta: exec". No propongas el arreglo en el Telegram, solo el hecho y la pregunta. PARA PROBAR ESTE JOB no existe un "modo prueba" por texto: se prueba creando una copia one-shot con la allow-list de tools reducida a exec, asi el aviso es fisicamente imposible en vez de depender de que leas una regla. Verificado el 2026-09-12: una version con "MODO PRUEBA" al inicio del mensaje mando el Telegram igual, porque la prohibicion estaba al final y actue antes de llegar a ella. Toda salida en ASCII, una sola linea final.
```
