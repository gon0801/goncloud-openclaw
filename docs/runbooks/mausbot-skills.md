# Skills de MausBot

Este runbook arma el archivo de equipo de OpenMausBot 0.1.148 de la PC de Hermes (`gwpc`, usuario
`ehven`) con las skills de los perfiles de Hermes y el paquete de poteto del repo. La app y la PC
solo se leen hasta que el director corre el paso de aplicación. Nada de esto se versiona.

## Qué cambia

- Cada bot con un perfil de Hermes del mismo nombre recibe todas las skills de ese perfil, también
  las anidadas. Quedan fuera las skills que no sirven en esta PC y cada exclusión se imprime con su
  motivo. Ejemplos: las de `apple/` porque dependen de macOS, las de Hermes porque usan su CLI
  interno, y las que el paquete común ya trae.
- Todos los bots reciben `poteto-mode`, todos los `principle-*` y `poteto-mausbot`. El paquete sale
  del manifiesto de `scripts/agent-work/contexto` y se verifica archivo por archivo.
- Solo MausBot e ingeniería llevan `motor` encendida. En los demás bots la skill queda con
  `enabled: false`, incluido Implementer.
- Cada bot queda con `computer: local`. Una corrida sin pantalla no pregunta qué computadora usar.
- `model`, `effort`, `approval` y `soul` se copian del export. El generador no los cambia.
- La salida y su respaldo heredan los permisos de su carpeta padre: en Windows MausBot y cualquier
  proceso sin elevar pueden leer `equipo.json` sin un `icacls salida /reset /T` después de generar,
  y en POSIX la carpeta queda como una hecha con `mkdir` (respeta el umask).
- La segunda aplicación no cambia nada. El paso de aplicación nunca usa `--prune` ni
  `--rotate-secrets`.

## Requisitos

- El checkout del repo en la PC. El medido es `C:\Users\ehven\motor-config\claw`.
- El Python del motor, `C:\Users\ehven\motor-runtime\cpython-3.11.16-windows-x86_64-none\python.exe`.
- La fuente de poteto que coincide con el manifiesto. En la PC está en
  `C:\Users\ehven\.motor-encargos\politica\poteto` y tiene `skills\poteto-mode` y los
  `skills\principle-*`.
- La app OpenMausBot en `C:\Users\ehven\AppData\Local\Programs\openmausbot`.

## Volver a generarlo cuando cambien las skills

Corre desde el checkout del repo en la PC. La salida va fuera del repo.

```cmd
cd /d C:\Users\ehven\motor-config\claw
set ELECTRON_RUN_AS_NODE=1
"C:\Users\ehven\AppData\Local\Programs\openmausbot\OpenMausBot.exe" "C:\Users\ehven\AppData\Local\Programs\openmausbot\resources\server\openmausbot.js" team export --out C:\Users\ehven\mausbot-equipo\export.yaml
"C:\Users\ehven\motor-runtime\cpython-3.11.16-windows-x86_64-none\python.exe" scripts\mausbot\equipo.py generar --export C:\Users\ehven\mausbot-equipo\export.yaml --perfiles "%LOCALAPPDATA%\hermes\profiles" --salida C:\Users\ehven\mausbot-equipo\salida --poteto-fuente C:\Users\ehven\.motor-encargos\politica\poteto --force
```

El generador imprime el total de bots y skills y la lista de excluidas con su motivo. Antes de
escribir revisa que ninguna skill copiada ni el archivo de equipo lleven una llave o un token. Si
encuentra uno, se detiene y no deja salida.

`--force` reemplaza la salida anterior. Sin `--force` el generador se niega a escribir sobre una
carpeta que ya existe.

## Mostrar el plan y aplicar

El paso de aplicación usa `--dry-run` por omisión. Muestra el plan y no toca la app. La salida de
la app llega por tubería y se imprime completa; si una corrida (`--dry-run` o `--aplicar`) sale
bien pero no trae una línea `Plan:`, el paso termina con error en vez de parecer que no cambió
nada. Lo mismo si la app no termina dentro del tope de tiempo.

```cmd
"C:\Users\ehven\motor-runtime\cpython-3.11.16-windows-x86_64-none\python.exe" scripts\mausbot\equipo.py aplicar --equipo C:\Users\ehven\mausbot-equipo\salida\equipo.json
```

Para aplicar, después de leer el plan:

```cmd
"C:\Users\ehven\motor-runtime\cpython-3.11.16-windows-x86_64-none\python.exe" scripts\mausbot\equipo.py aplicar --equipo C:\Users\ehven\mausbot-equipo\salida\equipo.json --aplicar
```

Con `--aplicar` el paso corre primero el `--dry-run`, lo imprime, y solo si sale bien corre la
aplicación real. Una segunda corrida seguida de `--dry-run` dice `0 to create, 0 to change`.

## Dónde se genera

`C:\Users\ehven\mausbot-equipo` queda fuera del repo. Sus archivos y `equipo.json` no se versionan.
Si se usa una salida dentro del repo, `.gitignore` cubre `mausbot-equipo/` y
`scripts/mausbot/salida/`.

## Qué revisar si algo falla

- Una skill excluida con motivo de Hermes que sí debería servir: revisa el nombre y el cuerpo. El
  generador excluye las que usan rutas como `~/.hermes/.../skills/`, `cronjob(...)`, o que
  invocan el CLI de Hermes (`hermes cron`, `hermes config` y similares) dos o más veces. Una ruta
  de scratch como `~/.hermes/cache/scratch` no excluye.
- Una skill de macOS que no se excluyó: su cabecera debe declarar `platforms: [macos]` o vivir bajo
  `apple/`.
- Una fuente de poteto que no coincide: apunta `--poteto-fuente` a la carpeta que tenga los mismos
  archivos que `scripts/agent-work/contexto/poteto.v1.json`.
- Un `soul` que el export escribe plegado (`>-`), con indicador de sangría (`|2-`) o como escalar de
  varias líneas: el generador se detiene con rc 3 y no deja salida, en vez de copiar un texto
  cortado. Escribe ese `soul` en un bloque literal (`|-`) o en una sola línea y vuelve a generar.
- Un `Access is denied` leyendo `equipo.json` con una salida vieja de antes del arreglo: esa
  carpeta conserva los permisos solo de administradores de la corrida defectuosa. Ya no hace falta
  arreglarlo a mano después de cada generación: bórrala y genera de nuevo, o resetéalos una vez
  con `icacls salida /reset /T`. Las corridas nuevas ya heredan los permisos del padre.
- Un cambio de `poteto.v1.json`: sube la generación en `generaciones.json` y vuelve a fijar el
  digest. Las pruebas de `scripts/tests/test-agent-work-contexto.py` lo comprueban.
