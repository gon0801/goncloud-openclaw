# SUA-00: mutaciones del validador del contrato

Fecha: 2026-10-13. Módulo: `scripts/sistema_agentes/contrato.py` en el commit `f82488d8`.
Prueba: `scripts/tests/test-sistema-agentes-contrato.py`. Contrato:
[sistema-agentes.v1](../../spec/sistema-agentes.v1.md).

## Qué demuestra

Cada guarda del validador tiene un caso que se pone rojo cuando la guarda se quita.
Son 62 mutaciones. Ninguna sobrevive.

## Método

Cada mutación cambia un solo punto del módulo. Después corre la prueba completa. Después
restaura el archivo. Antes de correr, cada mutación nombra el caso que debe ponerse rojo.
Si ese caso no se pone rojo, la mutación cuenta como viva.

El comando de cada corrida:

```
LANG=en_US.UTF-8 PROGRESS_EVENTS_STATE_DIR=$(mktemp -d) python3 scripts/tests/test-sistema-agentes-contrato.py
```

Python de la corrida: 3.14.7. El script que aplica las mutaciones no vive en
el repo. Cada fila trae el cambio literal para repetirlo a mano.

La columna "Rojos" cuenta todos los casos que fallaron con esa mutación. La columna "Caso"
es el que la mutación nombró de antemano. La línea del fallo es la que imprime `unittest`
para ese caso.

Las mutaciones 15, 33, 34, 45, 56 no dan una aserción. Dan una excepción. Esas guardas
existen para que una entrada torcida no reviente el validador, así que la excepción es el
fallo esperado.

Las guardas de forma se mutan por clase: tipo, enum, mínimo, máximo, requerido, cerrado.
No hay una mutación por cada fila de `ESQUEMAS`. Las filas que pidió SUA-00 sí tienen la
suya: el enum de `resultContract`, el mínimo de `renoticeAfterMs` y el cierre de la proyección.

## Mutaciones

| # | Guarda | Mutación | Rojos | Caso que se puso rojo | Línea literal del fallo |
|---|---|---|---|---|---|
| 1 | plan: `schema`, literal no admitido | `hallazgos = [_roto("schema", f"literal no admitido: {literal!r}")]` pasa a `hallazgos = []`. | 24 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/schema-ajeno.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'schema')]` |
| 2 | plan: `id-duplicado`, `unitId` y `criterionId` | `if identificador in vistos:` pasa a `if False:`. | 5 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/id-duplicado.json', validador='validar'` | `AssertionError: Lists differ: [] != [('id-duplicado', 'plan.units[1].unitId')]` |
| 3 | plan: `id-duplicado`, solo `criterionId` | En `_ids_duplicados`, `enumerate(unidad["criteria"])` pasa a `enumerate([])`. | 2 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/criterio-duplicado.json', validador='validar'` | `AssertionError: Lists differ: [] != [('id-duplicado', 'plan.units[1].criteria[0].criterionId')]` |
| 4 | plan: `dependencia-faltante` | `if dependencia not in existentes:` pasa a `if False:`. | 3 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/dependencia-faltante.json', validador='validar'` | `AssertionError: Lists differ: [] != [('dependencia-faltante', 'plan.units[1].dependsOn[0]')]` |
| 5 | plan: `ciclo` | `if estado[destino] == en_camino:` pasa a `if False:`. | 6 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/ciclo.json', validador='validar'` | `AssertionError: Lists differ: [] != [('ciclo', 'plan.units[1].dependsOn[0]')]` |
| 6 | plan: `criterio-faltante` | `if not unidad["criteria"]:` pasa a `if False:`. | 3 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/criterio-faltante.json', validador='validar'` | `AssertionError: Lists differ: [] != [('criterio-faltante', 'plan.units[0].criteria')]` |
| 7 | plan: `campo-prohibido` | `if razon is not None:` pasa a `if False:`. | 4 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/campo-prohibido.json', validador='validar'` | `AssertionError: Lists differ: [] != [('campo-prohibido', 'plan.units[0].session_key')]` |
| 8 | plan: `campo-prohibido` dentro de una lista | `yield from _campos_prohibidos(hijo, f"{ruta}[{indice}]")` pasa a `pass`. | 3 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='planes/invalidos/campo-prohibido.json', validador='validar'` | `AssertionError: Lists differ: [] != [('campo-prohibido', 'plan.units[0].session_key')]` |
| 9 | plan: orden de las reglas | `(_ids_duplicados, _dependencias_faltantes, _ciclos, _criterios_faltantes)` pasa a `(_criterios_faltantes, _ciclos, _dependencias_faltantes, _ids_duplicados)`. | 1 fallo | `Plan.test_un_plan_con_todos_los_defectos_los_reporta_en_el_orden_del_contrato` | `AssertionError: Lists differ: [('criterio-faltante', 'plan.units[1].criter[188 chars]en')] != [('id-duplicado', 'plan.units[3].unitId'), ([188 chars]en')]` |
| 10 | plan: una forma rota calla las reglas de plan | `if not hallazgos and literal in _REGLAS_PROPIAS:` pasa a `if literal in _REGLAS_PROPIAS:`. | 1 fallo | `Plan.test_una_forma_rota_va_primero_y_calla_las_reglas_de_plan` | `AssertionError: Lists differ: [('ciclo', 'plan.units[1].dependsOn[0]'), ('campo-prohibido', 'api_token')] != [('schema', 'createdAt'), ('campo-prohibido', 'api_token')]` |
| 11 | `validar_plan` solo admite meta | `return _validar(meta, {META: ESQUEMAS[META]})` pasa a `return _validar(meta, ESQUEMAS)`. | 1 fallo | `Plan.test_validar_plan_rechaza_un_documento_valido_de_otro_esquema` | `AssertionError: Lists differ: [] != [Hallazgo(regla='schema', ruta='schema', d[57 chars]1'")]` |
| 12 | autoridad: `autoridad-vencida` | `return plazo is not None and _instante(ahora) > _instante(plazo)` pasa a `return False`. | 3 fallos | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='autoridad vencida'` | `AssertionError: None != 'autoridad-vencida'` |
| 13 | autoridad: el plazo exacto todavía no vence | `_instante(ahora) > _instante(plazo)` pasa a `_instante(ahora) >= _instante(plazo)`. | 1 fallo | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='en el instante del plazo'` | `AssertionError: 'autoridad-vencida' != None` |
| 14 | autoridad: la fracción de segundo cuenta | `micros = int((fraccion or "")[:6].ljust(6, "0"))` pasa a `micros = 0`. | 1 fallo | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='vencida por un milisegundo'` | `AssertionError: None != 'autoridad-vencida'` |
| 15 | autoridad: `deadline` null no vence | `return plazo is not None and _instante(ahora)` pasa a `return _instante(ahora)`. | 2 errores | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='sin plazo no vence'` | `TypeError: expected string or bytes-like object, got 'NoneType'` |
| 16 | autoridad: `accion-fuera-de-autoridad` | `return efecto["action"] not in autoridad["actions"]` pasa a `return False`. | 2 fallos | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='accion fuera'` | `AssertionError: None != 'accion-fuera-de-autoridad'` |
| 17 | autoridad: `repo-fuera-de-autoridad` | `return efecto["repo"] not in autoridad["repos"]` pasa a `return False`. | 1 fallo | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='repo fuera'` | `AssertionError: None != 'repo-fuera-de-autoridad'` |
| 18 | autoridad: `destino-fuera-de-autoridad` | `return destino is not None and destino not in autoridad["destinations"]` pasa a `return False`. | 1 fallo | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='destino fuera'` | `AssertionError: None != 'destino-fuera-de-autoridad'` |
| 19 | autoridad: el destino solo cuenta si el efecto lo trae | `return destino is not None and destino not in autoridad["destinations"]` pasa a `return destino not in autoridad["destinations"]`. | 5 fallos | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='admisible sin destino y con modo menor'` | `AssertionError: 'destino-fuera-de-autoridad' != None` |
| 20 | autoridad: `modo-fuera-de-autoridad` | `return rango > _RANGO_DE_MODO[autoridad["mode"]]` pasa a `return False`. | 2 fallos | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='modo publish contra autoridad implement'` | `AssertionError: None != 'modo-fuera-de-autoridad'` |
| 21 | autoridad: un modo desconocido queda fuera | `_RANGO_DE_MODO.get(efecto["mode"], len(MODOS))` pasa a `_RANGO_DE_MODO.get(efecto["mode"], 0)`. | 1 fallo | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='modo que el contrato no conoce'` | `AssertionError: None != 'modo-fuera-de-autoridad'` |
| 22 | autoridad: orden de las razones | En `_RECHAZOS`, `accion-fuera-de-autoridad` sube antes de `autoridad-vencida`. | 1 fallo | `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` con `efecto='vencida gana a accion fuera'` | `AssertionError: 'accion-fuera-de-autoridad' != 'autoridad-vencida'` |
| 23 | forma: enum de `resultContract` | `"resultContract": _uno_de("review.v1", "ready.v1"),` pasa a `"resultContract": TEXTO,`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='resultados/invalido-contrato-desconocido.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'resultContract')]` |
| 24 | forma: enum, la guarda general | `if campo.enum and valor not in campo.enum:` pasa a `if False:`. | 6 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='evidencia/invalida-outcome-fuera-del-enum.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'outcome')]` |
| 25 | forma: mínimo de `renoticeAfterMs` | `"renoticeAfterMs": _entero(minimo=3_600_000),` pasa a `"renoticeAfterMs": _entero(),`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='excepcion/invalida-reaviso-corto.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'renoticeAfterMs')]` |
| 26 | forma: mínimo, la guarda general | `if campo.minimo is not None and valor < campo.minimo:` pasa a `if False:`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='excepcion/invalida-reaviso-corto.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'renoticeAfterMs')]` |
| 27 | forma: máximo | `if campo.maximo is not None and valor > campo.maximo:` pasa a `if False:`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='proyeccion/invalida-progreso-mayor-a-100.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'progress.declared')]` |
| 28 | forma: campo extra en la proyección | La raíz de `_PROYECCION` pierde `cerrado=True`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='proyeccion/invalida-campo-extra-argv.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'argv')]` |
| 29 | forma: objeto cerrado, la guarda general | `if campo.cerrado:` pasa a `if False:`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='proyeccion/invalida-campo-extra-argv.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'argv')]` |
| 30 | forma: campo requerido | `elif descrito.requerido:` pasa a `elif False:`. | 4 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='resultados/invalido-sin-result-digest.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'resultDigest')]` |
| 31 | forma: campos que dependen de un hermano | `campos.update(variantes.get(elegido, {}))` pasa a `pass`. | 2 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='resultados/invalido-changes-sin-findings.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'payload.findingsRef')]` |
| 32 | forma: hermano ausente no elige variante | `elegido = valor.get(hermano, _AUSENTE)` pasa a `elegido = valor.get(hermano)`. | 1 fallo | `Plan.test_un_documento_torcido_se_rechaza_sin_reventar` con `caso='el modelo no trae id'` | `AssertionError: Lists differ: [('schema', 'model.id'), ('schema', 'model.reason')] != [('schema', 'model.id')]` |
| 33 | forma: hermano que no sirve de llave | `if not isinstance(elegido, (list, dict)):` pasa a `if True:`. | 1 error | `Plan.test_un_documento_torcido_se_rechaza_sin_reventar` con `caso='el hermano que elige la variante es una lista'` | `TypeError: cannot use 'list' as a dict key (unhashable type: 'list')` |
| 34 | forma: literal `schema` que no es texto | `forma = esquemas.get(literal) if isinstance(literal, str) else None` pasa a `forma = esquemas.get(literal)`. | 1 error | `Plan.test_un_documento_torcido_se_rechaza_sin_reventar` con `caso='el literal es una lista'` | `TypeError: cannot use 'list' as a dict key (unhashable type: 'list')` |
| 35 | forma: lista no vacía | `if campo.no_vacia and not valor:` pasa a `if False:`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='excepcion/invalida-sin-opciones.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'options')]` |
| 36 | forma: null no permitido | `return [] if campo.nulo else [_roto(ruta, "null no permitido")]` pasa a `return []`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='evidencia/invalida-procedimiento-null.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'procedure')]` |
| 37 | forma: tipo del escalar | `if not isinstance(valor, tipo) or not cumple(valor):` pasa a `if not cumple(valor):`. | 1 fallo y 1 error | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='evidencia/invalida-version-numerica.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'environment.versions.node')]` |
| 38 | forma: `true` no es entero | `"entero": (int, "entero", lambda valor: not isinstance(valor, bool)),` pasa a `"entero": (int, "entero", lambda valor: True),`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='flota/invalida-generacion-booleana.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'generation')]` |
| 39 | forma: fecha ISO 8601 en UTC con Z | `"fecha": (str, "fecha ISO 8601 en UTC con Z", _es_fecha),` pasa a `"fecha": (str, "fecha ISO 8601 en UTC con Z", lambda valor: True),`. | 2 fallos | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='evidencia/invalida-fecha-sin-z.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'at')]` |
| 40 | forma: digest `sha256:<64 hex>` | `lambda valor: _DIGEST.fullmatch(valor) is not None),` pasa a `lambda valor: True),`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='flota/invalida-digest-corto.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'attestations[0].digest')]` |
| 41 | forma: repo `owner/nombre` | `lambda valor: _REPO.fullmatch(valor) is not None),` pasa a `lambda valor: True),`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='autoridad/invalida-repo-sin-owner.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'repos[0]')]` |
| 42 | forma: identificador no vacío | `lambda valor: valor != ""),` pasa a `lambda valor: True),`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='unidad/invalida-unit-id-vacio.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'unitId')]` |
| 43 | forma: objeto donde va un objeto | `_forma_de_objeto` pierde su guarda `if not isinstance(valor, dict)`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='unidad/invalida-asignacion-en-texto.json', validador='validar'` | `AssertionError: Lists differ: [('sc[13 chars]nment.target'), ('schema', 'assignment.instruc[85 chars]on')] != [('sc[13 chars]nment')]` |
| 44 | forma: lista donde va una lista | `_forma_de_lista` pierde su guarda `if not isinstance(valor, list)`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='excepcion/invalida-opciones-en-texto.json', validador='validar'` | `AssertionError: Lists differ: [('schema', 'options[0]'), ('schema', 'options[1]'), ('schema[90 chars]5]')] != [('schema', 'options')]` |
| 45 | forma: mapa donde va un mapa | `_forma_de_mapa` pierde su guarda `if not isinstance(valor, dict)`. | 1 error | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='evidencia/invalida-versiones-en-lista.json', validador='validar'` | `AttributeError: 'list' object has no attribute 'items'` |
| 46 | forma: valores del mapa `versions` | `"versions": Campo("mapa", elementos=TEXTO)` pasa a `"versions": _objeto({})`. | 1 fallo | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` con `archivo='evidencia/invalida-version-numerica.json', validador='validar'` | `AssertionError: Lists differ: [] != [('schema', 'environment.versions.node')]` |
| 47 | nombres: lista exacta, un nombre menos | La lista exacta pierde `"session"`. | 1 fallo | `Nombres.test_cada_nombre_pasa_o_dice_por_que_esta_prohibido` con `nombre='session'` | `AssertionError: None != 'nombre exacto session'` |
| 48 | nombres: lista exacta, la guarda | `if exacto is not None:` pasa a `if False:`. | 26 fallos | `Nombres.test_cada_nombre_pasa_o_dice_por_que_esta_prohibido` con `nombre='key'` | `AssertionError: None != 'nombre exacto key'` |
| 49 | nombres: sufijo, la guarda | `if sufijo is not None:` pasa a `if False:`. | 12 fallos | `Nombres.test_cada_nombre_pasa_o_dice_por_que_esta_prohibido` con `nombre='idempotency_key'` | `AssertionError: None != 'sufijo _key'` |
| 50 | nombres: sufijo, una palabra menos | `(?:key\|token\|secret\|password\|passwd)$` pasa a `(?:key\|token\|secret\|password)$`. | 1 fallo | `Nombres.test_cada_nombre_pasa_o_dice_por_que_esta_prohibido` con `nombre='root-passwd'` | `AssertionError: None != 'sufijo -passwd'` |
| 51 | nombres: sufijo, un separador menos | `r"[_-](?:key` pasa a `r"[_](?:key`. | 3 fallos | `Nombres.test_cada_nombre_pasa_o_dice_por_que_esta_prohibido` con `nombre='x-key'` | `AssertionError: None != 'sufijo -key'` |
| 52 | transición: `reported → accepted` | `"reported": frozenset({"accepted", "failed", "cancelled"}),` pasa a `"reported": frozenset({"failed", "cancelled"}),`. | 1 fallo | `Unidad.test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada` con `desde='reported', hasta='accepted'` | `AssertionError: False is not True` |
| 53 | transición: un estado terminal no cambia | `"accepted": frozenset(),` pasa a `"accepted": frozenset({"running"}),`. | 1 fallo | `Unidad.test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada` con `desde='accepted', hasta='running'` | `AssertionError: True is not False` |
| 54 | transición: `cancelled` no revive | `"cancelled": frozenset(),` pasa a `"cancelled": frozenset({"ready"}),`. | 1 fallo | `Unidad.test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada` con `desde='cancelled', hasta='ready'` | `AssertionError: True is not False` |
| 55 | transición: `pending → ready` | `"pending": frozenset({"ready", "cancelled"}),` pasa a `"pending": frozenset({"cancelled"}),`. | 2 fallos | `Unidad.test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada` con `desde='pending', hasta='ready'` | `AssertionError: False is not True` |
| 56 | transición: estado desconocido | `TRANSICIONES.get(estado_desde, frozenset())` pasa a `TRANSICIONES[estado_desde]`. | 1 error | `Unidad.test_un_estado_que_el_contrato_no_conoce_no_transita` | `KeyError: 'waiting'` |

## Las funciones cambiadas por dobles vacíos

Las cinco funciones puras (`validar`, `validar_plan`, `nombre_de_campo_prohibido`,
`efecto_admisible`, `transicion_permitida`) se cambian por un doble. Primero uno que
devuelve `[]`. Después uno que devuelve `None`. `cargar_json` queda intacta.

| Prueba | Doble `[]` | Doble `None` |
|---|---|---|
| `Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon` | rojo | rojo |
| `Ensayos.test_cada_caso_esta_citado_por_su_ensayo` | verde | verde |
| `Ensayos.test_cada_ensayo_copia_el_texto_de_la_tabla_del_plan` | verde | verde |
| `Ensayos.test_el_manifiesto_trae_los_24_ensayos_especificados_con_bloque_y_fixtures_reales` | verde | verde |
| `Fixtures.test_cada_esquema_del_contrato_tiene_fixture_valido_e_invalido` | verde | verde |
| `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` | rojo | rojo |
| `Fixtures.test_cada_fixture_valido_pasa_y_con_un_literal_ajeno_se_rechaza` | rojo | rojo |
| `Fixtures.test_no_hay_fixtures_huerfanos` | verde | verde |
| `Nombres.test_cada_nombre_pasa_o_dice_por_que_esta_prohibido` | rojo | rojo |
| `Plan.test_el_ciclo_se_nombra_en_el_detalle` | rojo | rojo |
| `Plan.test_un_documento_torcido_se_rechaza_sin_reventar` | rojo | rojo |
| `Plan.test_un_plan_con_todos_los_defectos_los_reporta_en_el_orden_del_contrato` | rojo | rojo |
| `Plan.test_una_forma_rota_va_primero_y_calla_las_reglas_de_plan` | rojo | rojo |
| `Plan.test_validar_plan_rechaza_un_documento_valido_de_otro_esquema` | rojo | rojo |
| `Unidad.test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada` | rojo | rojo |
| `Unidad.test_un_estado_que_el_contrato_no_conoce_no_transita` | rojo | rojo |

Última línea con el doble `[]`: `FAILED (failures=196)`.
Última línea con el doble `None`: `FAILED (failures=129, errors=46)`.

Quedan verdes 5 pruebas: `Ensayos.test_cada_caso_esta_citado_por_su_ensayo`, `Ensayos.test_cada_ensayo_copia_el_texto_de_la_tabla_del_plan`, `Ensayos.test_el_manifiesto_trae_los_24_ensayos_especificados_con_bloque_y_fixtures_reales`, `Fixtures.test_cada_esquema_del_contrato_tiene_fixture_valido_e_invalido`, `Fixtures.test_no_hay_fixtures_huerfanos`. Ninguna llama al validador.
Comparan tablas entre sí: el árbol de fixtures contra `casos.json`, `casos.json` contra
`manifiesto-ensayos.json`, y ese manifiesto contra la tabla del plan.

## Corrida verde completa

Con el módulo restaurado. `git status --short` no reporta cambios en el módulo.

```
$ LANG=en_US.UTF-8 PROGRESS_EVENTS_STATE_DIR=$(mktemp -d) python3 scripts/tests/test-sistema-agentes-contrato.py -v
test_cada_efecto_es_admisible_o_da_su_primera_razon (__main__.Autoridad.test_cada_efecto_es_admisible_o_da_su_primera_razon) ... ok
test_cada_caso_esta_citado_por_su_ensayo (__main__.Ensayos.test_cada_caso_esta_citado_por_su_ensayo) ... ok
test_cada_ensayo_copia_el_texto_de_la_tabla_del_plan (__main__.Ensayos.test_cada_ensayo_copia_el_texto_de_la_tabla_del_plan) ... ok
test_el_manifiesto_trae_los_24_ensayos_especificados_con_bloque_y_fixtures_reales (__main__.Ensayos.test_el_manifiesto_trae_los_24_ensayos_especificados_con_bloque_y_fixtures_reales) ... ok
test_cada_esquema_del_contrato_tiene_fixture_valido_e_invalido (__main__.Fixtures.test_cada_esquema_del_contrato_tiene_fixture_valido_e_invalido) ... ok
test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta (__main__.Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta) ... ok
test_cada_fixture_valido_pasa_y_con_un_literal_ajeno_se_rechaza (__main__.Fixtures.test_cada_fixture_valido_pasa_y_con_un_literal_ajeno_se_rechaza) ... ok
test_no_hay_fixtures_huerfanos (__main__.Fixtures.test_no_hay_fixtures_huerfanos) ... ok
test_cada_nombre_pasa_o_dice_por_que_esta_prohibido (__main__.Nombres.test_cada_nombre_pasa_o_dice_por_que_esta_prohibido) ... ok
test_el_ciclo_se_nombra_en_el_detalle (__main__.Plan.test_el_ciclo_se_nombra_en_el_detalle) ... ok
test_un_documento_torcido_se_rechaza_sin_reventar (__main__.Plan.test_un_documento_torcido_se_rechaza_sin_reventar) ... ok
test_un_plan_con_todos_los_defectos_los_reporta_en_el_orden_del_contrato (__main__.Plan.test_un_plan_con_todos_los_defectos_los_reporta_en_el_orden_del_contrato) ... ok
test_una_forma_rota_va_primero_y_calla_las_reglas_de_plan (__main__.Plan.test_una_forma_rota_va_primero_y_calla_las_reglas_de_plan) ... ok
test_validar_plan_rechaza_un_documento_valido_de_otro_esquema (__main__.Plan.test_validar_plan_rechaza_un_documento_valido_de_otro_esquema) ... ok
test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada (__main__.Unidad.test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada) ... ok
test_un_estado_que_el_contrato_no_conoce_no_transita (__main__.Unidad.test_un_estado_que_el_contrato_no_conoce_no_transita) ... ok

----------------------------------------------------------------------
Ran 16 tests in 0.006s

OK
```

La misma prueba con Python 3.9.6, el Python del sistema:

```
$ LANG=en_US.UTF-8 PROGRESS_EVENTS_STATE_DIR=$(mktemp -d) /usr/bin/python3 scripts/tests/test-sistema-agentes-contrato.py
................
----------------------------------------------------------------------
Ran 16 tests in 0.008s

OK
```

## Mutaciones de la revisión del lead (2026-10-13)

Después de traer los tres commits del delegado a `sua/00-inventario`, el lead agregó
`running → failed` a `TRANSICIONES` (el host cierra un intento sin resultado con
`launch-failed` o `session-closed`, medido en `B22-canarios.md`) y la clase `Inventario`
de la prueba, que valida `SUA-00-inventario.json`. Cinco mutaciones más, con el mismo
comando. Ninguna sobrevive.

| # | Guarda | Mutación | Caso que se puso rojo | Línea literal del fallo |
|---|---|---|---|---|
| 57 | transición: `running → failed` | `"running": frozenset({"reported", "failed", "cancelled"})` pasa a `frozenset({"reported", "cancelled"})`. | `Unidad.test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada` con `desde='running', hasta='failed'` | `AssertionError: False is not True` |
| 58 | inventario: capacidad fuera del enum | `rutas[3].instalado.capacidad` pasa de `passed` a `ok`. | `Inventario.test_cada_ruta_trae_las_tres_columnas_con_capacidad_del_enum` | `AssertionError: Lists differ: [('cli.encargo.run-per-task', 'instalado', 'ok')] != []` |
| 59 | inventario: un `unknown` sin razón ni comando | `rutas[2].aceptadoEnVivo` pierde `razon` y `comando`. | `Inventario.test_un_unknown_dice_su_razon_o_el_comando_que_lo_contesta` | `AssertionError: Lists differ: [('nativo.encargo', 'aceptadoEnVivo')] != []` |
| 60 | inventario: falta una pieza que el plan pide | Se quita la pieza `ProgressPublisher`. | `Inventario.test_las_piezas_que_pide_el_plan_estan` | `AssertionError: Items in the first set but not the second:` |
| 61 | inventario: id de ruta repetido | `rutas[1].id` pasa a ser el de `rutas[0]`. | `Inventario.test_los_ids_no_se_repiten_y_las_piezas_dicen_su_estado_tras_b22` | `AssertionError: Lists differ: ['cli[354 chars]ativo.encargo', 'nativo.turno', 'orbit.deploy'] != ['cli[354 chars]ativo.encargo', 'nativo.turno', 'nativo.turno', 'orbit.deploy']` |
| 62 | excepción: la respuesta elige una opción ofrecida | `respuesta["optionId"] in ofrecidas` pasa a `True`. | `Fixtures.test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta` | `AssertionError: Lists differ: [] != [('opcion-no-ofrecida', 'response.optionId')]` |

Corrida verde después de restaurar:

```
$ LANG=en_US.UTF-8 PROGRESS_EVENTS_STATE_DIR=$(mktemp -d) python3 scripts/tests/test-sistema-agentes-contrato.py
Ran 21 tests in 0.006s
OK
```

## Alcance del lint

Corrido por el lead sobre el árbol completo de `sua/00-inventario`, el 2026-10-13.

```
$ ruff check --show-files . | sort
/Users/dn/dev/wt/sua-00/scripts/sistema_agentes/__init__.py
/Users/dn/dev/wt/sua-00/scripts/sistema_agentes/contrato.py
/Users/dn/dev/wt/sua-00/scripts/tests/test-sistema-agentes-contrato.py
$ pre-commit run --all-files ruff-check
ruff check...............................................................Passed
$ pre-commit run --all-files ruff-format
ruff format..............................................................Passed
$ git status --short
(sin cambios en archivos fuera de SUA)
```

Tres archivos de los 80 `.py` del repo entran al alcance. Ningún archivo legado se
reformateó.
