# Transiciones del recorrido completo (19.2-r1)

Fecha: 2026-09-30. Bloque B3 (cierre de U3a), ronda r1. Encargo:
`encargo-19.2-r1.md`. Base: `a1840b2` (main, incluye 19.1 via `be65298`).
Medicion viva en ESTA Mac; arnes: `arnes/medir-19.2.sh` (cadena),
`arnes/resumen-19.2.py` (tabla), `arnes/casos-19.2.sh` (casos aparte).
Sin push (el push lo hace claw tras el APROBADO).

## Que es una transicion

El trabajador k (CLI del anillo zcode->codex->kimi->grok->claude) termina su
turno con requisitos cumplidos (resultado-k.txt completo; el reloj arranca
ahi, con `--solo-archivo`: la entrega es el archivo) -> la maquinaria real lo
entrega (vigia + aviso durable fin-turno + atender; el propio despertar del
emitir le teclea al lead `corrida.sh avisos atender`, ruta real de 19.1,
medida en vivo) -> el brazo mecanico del dueno (declarado: anillo
pre-planificado, sin red ni esperas humanas) lanza al trabajador k+1 -> la
transicion cierra cuando k+1 muestra sesion viva (actividad como
corroboracion). Umbral de la DoD: 30 s. Reloj monotono del mismo host para
fin e inicio.

## Resultado: 20/20 transiciones, todas bajo 30 s

- transiciones con datos: **20/20**
- cumplen (<30 s): **20/20**
- **mediana 14.67 s**, **maximo 17.98 s**, minimo 2.56 s
- fallos ocultos: ninguno (no hubo FALLO de guarda ni TARDIO en esta corrida;
  las rondas previas del arnes y sus correcciones quedan en `brazo.log` de las
  estampas anteriores)

| # | de | a | duracion_s | veredicto |
|---|---|---|---|---|
| 1 | zcode | codex | 14.46 | OK |
| 2 | codex | kimi | 16.01 | OK |
| 3 | kimi | grok | 17.05 | OK |
| 4 | grok | claude | 3.64 | OK |
| 5 | claude | zcode | 10.76 | OK |
| 6 | zcode | codex | 14.92 | OK |
| 7 | codex | kimi | 15.76 | OK |
| 8 | kimi | grok | 17.55 | OK |
| 9 | grok | claude | 2.56 | OK |
| 10 | claude | zcode | 11.29 | OK |
| 11 | zcode | codex | 15.44 | OK |
| 12 | codex | kimi | 14.88 | OK |
| 13 | kimi | grok | 16.91 | OK |
| 14 | grok | claude | 5.14 | OK |
| 15 | claude | zcode | 10.36 | OK |
| 16 | zcode | codex | 14.94 | OK |
| 17 | codex | kimi | 14.36 | OK |
| 18 | kimi | grok | 17.98 | OK |
| 19 | grok | claude | 3.55 | OK |
| 20 | claude | zcode | 12.81 | OK |

## Cobertura del inventario

- finalizaciones por CLI: zcode 4, codex 4, kimi 4, grok 4, claude 4
  (>= 2 por CLI habilitada: CUMPLE)
- cada CLI como destino: zcode 4, codex 4, kimi 4, grok 4, claude 4
  (>= 1: CUMPLE)
- Muse -> Claude y Claude -> siguiente: claude participo como destino (4) y
  como origen (4); Muse no esta habilitada en el inventario (fila con
  unknown), queda fuera por diseno del inventario.

## Casos aparte (salidas/19-2-casos/)

- **Perdida de aviso**: observado con causa. Borrar el pendiente tras
  emitirse pierde la senal (el pendiente ES la garantia durable); el
  recordatorio no la recupero en la ventana observada porque el despertar al
  lead (que corre atender y cambia el panel) reinicia el reloj de silencio
  del trabajador. `salidas/19-2-casos/A-*/veredicto` = SIN-RECUPERACION.
  **PENDIENTE**: remediar (no reiniciar el reloj por el wake propio o ventana
  de recordatorio por session) y medir la recuperacion.
- **Caida recuperable**: OK. Vigia muerto antes del fin; medido desde su
  relanzamiento (gateway y dueno disponibles): **14.8 s < 60 s**, 1 solo
  lanzamiento del sucesor, sin duplicados (`caso-B.json`).
- **Reversa del seguimiento**: OK. Con `CORRIDA_AVISOS=0` en el entorno del
  servidor sandbox (la heredan el vigia Y el hook de la sesion, los dos
  emisores): **0 pendientes**; quitada la reversa, los pendientes vuelven
  (`caso-C.json`). La reversa es por emisor via entorno, documentada en
  `docs/spec/corrida-aviso.v1.md`.

## SHA leido de vuelta

Instalado `~/bin` contra HEAD `a1840b2` con la ruta existente
(`instalar-mac.sh`): **todos los archivos que el instalador gestiona
coinciden** (31 verificados; detalle en
`arnes/salidas/19-2/sha-leido-de-vuelta.txt`). Dos artefactos de desarrollo
(`corrida/simulacro-fase9.sh`, `corrida/smoke-native-harnesses.sh`) son
copias viejas sin rol en la maquinaria instalada y fuera del alcance del
instalador; se declaran, no se tocan.

## Prueba focalizada y mutacion

`arnes/test-resumen-19.2.sh`: TODO VERDE (tabla, mediana/maximo/cumplen y
cobertura sobre fixture). Mutacion que discrimina: bajar el umbral del
resumidor 30 -> 5 voltea la transicion frontera del fixture a TARDIO y la
prueba cae en ROJO (`cumplen: 0` vs 2); restaurada, VERDE. Rojo y verde
anotados en la misma corrida del test.

## Estado de los criterios

| Criterio | Estado |
|---|---|
| >= 20 transiciones < 30 s | CUMPLE (20/20; mediana 14.67, max 17.98) |
| 2 finalizaciones por CLI y cada CLI destino | CUMPLE (4 y 4 por CLI) |
| mediana/maximo/conteo publicados sin ocultar | CUMPLE (tabla completa arriba) |
| recuperacion < 60 s sin duplicados | CUMPLE (14.8 s, 1 lanzamiento) |
| perdida de aviso | OBSERVADO con causa; **PENDIENTE** la recuperacion medida |
| SHA leido de vuelta | CUMPLE (lo instalado coincide; 2 artefactos de dev declarados) |
| reversa probada | CUMPLE (0 pendientes con reversa; regresan sin ella) |
