# Ronda 2 — cerrar los hallazgos del adversary sobre `redaction`

Repo: `goncloud-Orbit` (`/Users/dn/dev/goncloud-Orbit`). PR a extender: **#252**.
**PRIMER PASO OBLIGATORIO:** `git switch test/redaccion-cobertura`. El arbol quedo en `eval/redaccion`; commitear ahi NO extiende la #252 y la instruccion falla en silencio.
**Armar con `-saikit`** (lane full: implementer → verifier → reviewer).

> Este brief fue revisado antes de despacharse: 12 hallazgos, 2 bloqueantes, todos aplicados. Las correcciones estan marcadas donde importan porque varias nacieron de un error mio que habria hecho la tarea insatisfacible.

## GOAL

Las 13 pruebas de la ronda 1 detectan que **borres** una proteccion, no que la **debilites**. El adversary demostro 5 mutaciones de debilitamiento que dejan la suite entera en verde mientras el secreto se filtra. Cerrar esos 5 huecos **y** la unica fuga viva que encontro en el modulo.

## CONTEXT

Artefacto de origen: `.saikit/findings/adversary-20260910T204715Z.json` — **9 hallazgos**. Destino de cada uno:

| # | Hallazgo | Destino |
|---|---|---|
| 1 | `SecretScrubFilter.filter` es fail-open (severidad alta, `confirmed`) | **EN SCOPE — fuga viva, ver hueco 6** |
| 2 | Piso de longitud sin discriminar | EN SCOPE (hueco 1) |
| 3 | Password corta en userinfo de `redact_url` | EN SCOPE (hueco 2) |
| 4 | Orden de reemplazo en `scrub` | EN SCOPE (hueco 3) |
| 5 | Rama `netloc` de la guarda de URL malformada | EN SCOPE (hueco 4) |
| 6 | Asserts de forma en vez de igualdad | EN SCOPE (hueco 5) |
| 7 | `_secrets` global sin `reset` | DIFERIDO — pertinente porque el hueco 1 mete un fixture de 1 caracter en ese registro global; abrir ticket propio |
| 8 | Comentario de `redaction.py:26-28` atribuye mal la tolerancia al espacio | DIFERIDO — comentario que engana al proximo lector, fuera de scope |
| 9 | Fuga de cobertura entre modulos de test | DIFERIDO |

**La causa comun de los huecos 1-5:** los fixtures son demasiado largos y los asserts demasiado laxos.

**Correccion de un error del brief anterior:** `register_secret` **no tiene piso minimo** (`app/redaction.py:48-49` es `if not value: return`, y su docstring lo dice explicito). El "piso de 8" venia de la mutacion M01 de la ronda 1, que *introducia* uno. Regla general que hay que entender antes de elegir cualquier fixture: **un fixture de N caracteres solo discrimina pisos mayores que N.** Por eso `c0rt4!` (6) atrapa un piso de 8 y no atrapa uno de 2.

## SCOPE

`tests/test_redaction.py` y — solo para el hueco 6 — `app/redaction.py`.

**Hueco 1 — piso de longitud.** Mutacion: introduce `len(value) < 2`, que solo descarta secretos de **1 caracter**. Fixture obligatorio: **exactamente 1 caracter, no alfanumerico**, elegido de modo que no aparezca en ningun texto que la suite entera pase por `scrub()` o `redact_*` — el registro es global de proceso y no se limpia. El reviewer midio que `~` funciona (bateria completa: 2131 passed). Demostrar la eleccion corriendo la bateria completa en una sola invocacion.

**Hueco 2 — password corta en el userinfo.** Mutacion: `len(password) > 3` antes de `register_secret`. **Assert discriminante obligatorio: `scrub()` sobre un texto que contenga la password corta.** La URL devuelta es identica con y sin mutacion (`redact_url("https://u:ab@h.example/p")` da `"https://h.example/p"` en ambos casos): una prueba que solo afirme el retorno pasa verde y no protege nada.

**Hueco 3 — orden de reemplazo en `scrub`.** Mutacion: quitar `sorted(..., key=len, reverse=True)`. **Assert discriminante obligatorio: registrar el secreto CORTO primero.** Medido por el reviewer: si se registra el largo primero, `list(_secrets)` ya reemplaza el largo primero y la mutacion sobrevive verde. Solo con el corto primero aparece el residuo `***REDACTED***-extendido-9999`.

**Hueco 4 — rama `netloc` de la guarda de URL malformada.** **La rama ES alcanzable; no hay bifurcacion.** Un scheme sin host la dispara: `urlsplit("mailto:u:pw@host.example")` da `scheme='mailto'`, `netloc=''` (verificado; tambien `postgresql:///db` y `https:///p`). Con la mutacion aplicada, `redact_url` devuelve la URL entera con la password dentro. Prueba obligatoria: `redact_url("mailto:u:<pw>@host.example") == "<url-malformada>"`.
*Nota:* el brief anterior decia que el adversary "no logro construir la URL". Lo tergiversaba: el adversary no pudo instanciar **el dano** (el `ValueError` de `urlsplit`), no la URL de entrada.

**Hueco 5 — asserts de forma en vez de igualdad.** `"password=***" in resultado` sobrevive si la funcion devolviera `password=***REDACTED***`. Convertir a **igualdad exacta sobre la cadena completa** donde el retorno sea determinista.

**Hueco 6 — el fail-open de `SecretScrubFilter` (NUEVO, severidad alta).** Es el unico hallazgo que es una **fuga real del modulo hoy**, no una debilidad de prueba:
```python
try:
    message = record.getMessage()
except Exception:
    return True          # <-- deja record.msg crudo y record.args intactos
```
Si `getMessage()` levanta (args mal formados — la forma real del fallo LWA que ya se prueba en `tests/test_spapi_salud.py:648`), logging imprime el secreto a stderr. Arreglarlo con **cambio minimo**, declarando la postura de fallo elegida, y con su prueba: un `LogRecord` cuyos args revienten al formatear no debe dejar el secreto visible.

## ACCEPTANCE

- Las **5 mutaciones de debilitamiento** del apendice ponen en rojo al menos una prueba cada una. **Cada prueba nueva debe nombrar cual se pone roja bajo *su* mutacion**; si la roja es otra, la nueva no discrimina.
- Por cada mutacion, ademas del rojo: **`collected == N` igual que en la corrida base**. Una mutacion mal aplicada da `IndentationError` → "no tests collected, 1 error", que parece rojo y no lo es. Es la leccion que la ronda 1 ya dejo escrita en su blast.
- Restauracion verificada con `git diff --quiet app/redaction.py` **antes de pasar a la siguiente**.
- Las **13** mutaciones de borrado de la ronda 1 (M01-M13) siguen en rojo. La tabla esta en `.saikit/findings/blast-orbit-redaccion-cobertura.json`; el instrumento vivia en `/tmp/orbit_verify/mutate.py` (volatil) con copia en `.saikit/scratch/adversary/20260910T203716Z/mutate_adversary.py`. **Rematerializarlo bajo `.saikit/scratch/` del repo**, no en `/tmp`.
- Hueco 6 arreglado con su prueba y la postura de fallo declarada.
- Bateria completa verde.

## VERIFY

Agrupar en una sola invocacion por checkpoint. Trampas medidas de este repo:

- `pytest` necesita `PYTHONPATH=.` o `python -m pytest` desde la raiz; sin eso, `ModuleNotFoundError: No module named 'app'`. El CI usa `PYTHONPATH=.` con `uv run --frozen`.
- `-p no:randomly` **no existe** aca. No lo usen.
- Candados de commit de Orbit, obligatorios: `ruff check --fix . && ruff format .` y `pre-commit run --all-files`. **Jamas `--no-verify`.**

Una corrida de la bateria completa al final.

## Quien hace que

- **implementer**: escribe las pruebas y el fix del hueco 6, y corre las 5 mutaciones en rojo-primero (regla 9 del `AGENTS.md` de Orbit: toda prueba de regresion se demuestra fallando contra el codigo anterior).
- **verifier**: revalida las 5 mutaciones y las 13 de la ronda 1, mas `collected == N` y el arbol limpio.
- **reviewer**: revisa el diff final.
- No hay adversary en este carril.

## TIMEBOX

Una ronda. Sin excepciones por hueco: la bifurcacion del hueco 4 se elimino porque la rama es alcanzable.

## FORBIDDEN

- Tocar produccion, contenedores, crons, o archivos fuera de `tests/test_redaction.py` y `app/redaction.py`. **Excepcion explicita:** edicion **temporal** de `app/redaction.py` en el arbol de trabajo para aplicar cada mutacion, con respaldo previo, restauracion verificada despues de cada una, y **jamas commiteada**. Las mutaciones se **aplican** sobre el archivo real (no "se revierten", y no sobre un archivo copiado aparte: mutar una copia deja la suite verde y produce la conclusion falsa de que la mutacion no tumba nada).
- Inventar un fix. El unico cambio de modulo autorizado es el hueco 6.
- Secretos reales en fixtures: inventados, cortos y distintivos.
- Mergear.
- Sin acentos en codigo, fixtures ni comentarios nuevos (convencion de Orbit).

## REPORT

En lenguaje llano:

1. Las 5 mutaciones y cual prueba tumba cada una, con su `collected`.
2. El hueco 6: que se cambio y que postura de fallo se eligio.
3. **Si algun subagente fallo o no respondio, decirlo.** En la ronda 1 hubo 5 corridas fallidas que no llegaron al reporte; es el unico criterio que la ronda 1 no aprobo.
4. Obstaculos del brief mal escritos. El anterior tenia 12; este puede tener otros.
5. Registro en AppFlowy (`In progress` / `Done`) si aplica, por convencion de Orbit.

## Apendice: las 5 mutaciones, aplicables tal cual

Fragmentos copiados textuales de `app/redaction.py` (commit `a5de0f0`). Cada mutacion es el reemplazo EXACTO de "antes" por "despues" - aplicable con sed/replace sin ambiguedad. Se aplican una por una, en copia local, para confirmar que tumban al menos una prueba; nunca las 5 juntas y nunca commiteadas.

### Mutacion 1 - piso de longitud de `register_secret`

Por que: hoy `register_secret` no tiene piso minimo (redacta cualquier valor no vacio). La mutacion INTRODUCE un piso bajo (`< 2`) que deja pasar sin registrar un secreto de 1 caracter - indistinguible de "sin piso" para las 13 pruebas actuales porque ninguna usa un fixture de 1 caracter.

Antes:
```python
    if not value:
        return
```

Despues:
```python
    if not value or len(value) < 2:
        return
```

### Mutacion 2 - condicion de longitud antes de registrar la password del userinfo en `redact_url`

Por que: agrega una condicion de longitud (`> 3`) que las 13 pruebas no ejercitan porque ninguna usa una password de userinfo de 3 caracteres o menos. Una password corta nunca se registra, `scrub()` no la toca, y queda viva en el texto.

Antes:
```python
        if colon and password:
            register_secret(password)
```

Despues:
```python
        if colon and password and len(password) > 3:
            register_secret(password)
```

### Mutacion 3 - quitar el orden por longitud en `scrub`

Por que: sin ordenar los secretos de mas largo a mas corto antes de reemplazar, un secreto que es substring de otro (ej. `abc` dentro de `abc-extendido-9999`) se reemplaza primero por el corto, dejando un residuo del secreto largo sin redactar (`***REDACTED***-extendido-9999`). Las 13 pruebas no registran nunca dos secretos donde uno contenga al otro, asi que no lo detectan.

Antes:
```python
        secrets = sorted(_secrets, key=len, reverse=True)
```

Despues:
```python
        secrets = list(_secrets)
```

### Mutacion 4 - reducir la guarda de URL malformada

Por que: la guarda actual exige `scheme` Y `netloc`. Reducirla a solo `scheme` deja sin cubrir la rama en la que `netloc` viene vacio (por ejemplo, un `scheme` valido pero sin host) - si esa rama es alcanzable, el userinfo con password podria colarse en el texto que sigue procesandose en vez de devolver `<url-malformada>`. Las 13 pruebas no construyen ese caso.

Antes:
```python
    if not parsed.scheme or not parsed.netloc:
```

Despues:
```python
    if not parsed.scheme:
```

### Mutacion 5 - forma del reemplazo en el conninfo

Por que: la prueba actual del conninfo hace `assert "password=***" in resultado`, que es un assert de forma (substring), no de igualdad. Si la funcion devolviera `password=***REDACTED***` en vez de `password=***`, ese assert sigue pasando porque `"password=***"` sigue siendo substring de `"password=***REDACTED***"`.

Antes:
```python
        return f"{m.group(1)}=***"
```

Despues:
```python
        return f"{m.group(1)}=***REDACTED***"
```
