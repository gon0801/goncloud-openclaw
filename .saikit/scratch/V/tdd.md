# TDD — Carril V (glm) · Fase 13 · tareas 13.3 y 13.4

Worktree /Users/dn/dev/wt-f13-V, rama fase13/verify, HEAD = origin/main (9e291ad) al
arrancar. Rojo primero corrido contra ese árbol sin tocar (el único archivo nuevo es el
propio test, que es el candado, no la cosa bajo prueba).

## 13.3 — ROJO PRIMERO (contra origin/main sin tocar)

Comando: `bash scripts/tests/test-skill-verify.sh` → exit 1

```
(a) comparadas: 7 cadena(s) citada(s) contra 9 blockReason real(es)
FAIL (a) mapa incompleto o cita inexacta: el guard "merge-guard mutación GraphQL" emite una cadena que features/ no cita exactamente → "Merge bloqueado por summa-gate: la mutación GraphQL de merge y las rutas de merge de api.g"...
FAIL (a) mapa incompleto o cita inexacta: el guard "confinamiento adversary redirección" emite una cadena que features/ no cita exactamente → "Confinamiento adversary (summa-gate): redirección fuera de zona permitida (solo workspace,"...
FAIL (a) mapa incompleto o cita inexacta: el guard "confinamiento adversary cd + relativo" emite una cadena que features/ no cita exactamente → "Confinamiento adversary (summa-gate): el comando cambia de directorio, asi que un destino "...
FAIL (a) mapa incompleto o cita inexacta: el guard "canal entre agentes" emite una cadena que features/ no cita exactamente → "Envio bloqueado por summa-gate: la respuesta de un sessions_send de Claw a otro agente se "...
FAIL (a) mapa incompleto o cita inexacta: el guard "cierre con evidencia" emite una cadena que features/ no cita exactamente → "Cierre rechazado por summa-gate. Falta para cerrar la ceremonia:\n- el bloque `SUMMONAIKIT "...
(b) guards: SKILL.md lista 0, index.ts declara 8
FAIL (b) SKILL.md no tiene la sección ## Guards que enumera los guards
FAIL (b) el guard "Merge-guard" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) el guard "Canal entre agentes" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) el guard "Confinamiento adversary" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) el guard "Sentinel + standing rules" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) el guard "Evidencia post-tool" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) el guard "Gate de cierre" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) el guard "Tracking de subagentes" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) el guard "Observador de rendiciones" (// -- N. de index.ts) falta en la lista de SKILL.md
FAIL (b) SKILL.md cuenta hooks ("eight hooks"): los conteos se pudren; la lista de arriba es el candado
(c) excluida `C:\Users\ehven\.openclaw`: ruta del host gateway (Windows); la batería corre en ubuntu-latest
(c) excluida `~/.openclaw/bin/openclaw`: instalación local del host; no existe en ubuntu-latest
(c) excluida `.claude/skills/verify`: symlink machine-local bajo .claude/ (gitignored); la skill trae la receta para recrearlo
(c) excluida `.claude/`: symlink machine-local bajo .claude/ (gitignored); la skill trae la receta para recrearlo
(c) resueltas: 11 ruta(s) relativa(s) al repo citada(s) con backticks
ROJO: 15 problema(s) con la skill verify
```

Las cinco frases falsas de (a), una por línea:

1. **merge-guard · mutación GraphQL** — el mapa no lista la cadena de la mutación
   (`lib.ts:199`); solo citaba las otras tres reglas de merge.
2. **confinamiento adversary · redirección** — el mapa citaba «redirección **a path
   absoluto** fuera de zona permitida…»; el guard real dice «redirección fuera de zona
   permitida…» (`index.ts:497`) desde que los destinos relativos también se validan.
3. **confinamiento adversary · cd + relativo** — la tercera cadena de adversary
   (`index.ts:491`), la que el mapa no lista.
4. **canal entre agentes** — el mapa citaba solo el opening («Match the opening»); con
   la regla de truncado, la cita determinista llega hasta `agentId=<agente>`.
5. **cierre con evidencia** — citaba solo la primera línea; la cadena determinista
   completa llega hasta `<rol>`.

## 13.3 — VERDE DESPUÉS

Corregidas las cinco frases (features/merge-guard.md suma la cerca GraphQL,
features/confinamiento-adversary.md corrige la cita de redirección y suma la
tercera cadena, features/canal-entre-agentes.md y features/cierre-con-evidencia.md
citán la cadena completa hasta el primer placeholder) y SKILL.md reescrito sin
conteos (sección `## Guards` con la lista de los ocho `// -- N.`).

Comando: `bash scripts/tests/test-skill-verify.sh` → exit 0

```
(a) comparadas: 9 cadena(s) citada(s) contra 9 blockReason real(es)
(b) guards: SKILL.md lista 8, index.ts declara 8
(c) excluida `C:\Users\ehven\.openclaw`: ruta del host gateway (Windows); la batería corre en ubuntu-latest
(c) excluida `~/.openclaw/bin/openclaw`: instalación local del host; no existe en ubuntu-latest
(c) excluida `.claude/skills/verify`: symlink machine-local bajo .claude/ (gitignored); la skill trae la receta para recrearlo
(c) excluida `.claude/`: symlink machine-local bajo .claude/ (gitignored); la skill trae la receta para recrearlo
(c) resueltas: 13 ruta(s) relativa(s) al repo citada(s) con backticks
TODO VERDE: la skill verify dice lo que el plugin hace
```

## 13.3 — MUTANTES (cada uno revertido; el árbol queda como el verde de arriba)

### Mutante 1 — una letra de un `blockReason` en `summa-gate/index.ts`

Sustitución: `redirección fuera de zona permitida` → `redirección fuera de zona permetida`
(en index.ts, cadena del blockReason de redirección). Salida:

```
FAIL (a) mapa incompleto o cita inexacta: el guard "confinamiento adversary redirección" emite una cadena que features/ no cita exactamente → "Confinamiento adversary (summa-gate): redirección fuera de zona permetida (solo workspace,"...
ROJO: 1 problema(s) con la skill verify
```

### Mutante 2 — guard numerado nuevo sin ponerlo en la lista

Sustitución: agregar al final de `summa-gate/index.ts` la línea
`    // -- 10. Guard de prueba (mutante)`. Salida:

```
(b) guards: SKILL.md lista 8, index.ts declara 9
FAIL (b) el guard "Guard de prueba" (// -- N. de index.ts) falta en la lista de SKILL.md
ROJO: 1 problema(s) con la skill verify
```

### Mutante 3 — una ruta `/Users/dn/` citada con backticks en SKILL.md (DoD: «deja rojo en CI»)

Sustitución: insertar en SKILL.md la línea de prosa
``El checkout principal vive en `/Users/dn/dev/goncloud-openclaw/summa-gate`.``
Dos corridas:

(a) Con una ruta que EXISTE en el Mac del desarrollo (el checkout principal sí
está ahí): el test queda VERDE en esta máquina —

```
(c) resueltas: 14 ruta(s) relativa(s) al repo citada(s) con backticks
TODO VERDE: la skill verify dice lo que el plugin hace
```

— que es exactamente por lo que el DoD dice «deja rojo **en CI**»: en
ubuntu-latest `/Users/dn` no existe y la misma cita cae en la rama de abajo.

(b) Con la misma familia de ruta apuntando a un archivo que no existe en
ninguna máquina (`.../summa-gate/no-existe.ts`), el rojo aparece ya en el Mac:

```
FAIL (c) la cita absoluta `/Users/dn/dev/goncloud-openclaw/summa-gate/no-existe.ts` no existe en esta máquina (la batería corre en ubuntu-latest: citá la ruta relativa al repo)
ROJO: 1 problema(s) con la skill verify
```

El resolutor de (c) resuelve las citas absolutas POSIX al pie de la letra en
lugar de saltearlas en silencio; las familias de host (letra de unidad Windows,
`$HOME/`, `~/`) y el symlink `.claude/` quedan excluidas con la razón escrita
en el propio test. La corrida que vale es la de CI cuando el lead abra el PR.
