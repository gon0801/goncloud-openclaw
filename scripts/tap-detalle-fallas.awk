# Extrae, de un reporte TAP de `node --test --test-reporter tap`, el nombre de cada caso
# que fallo y su mensaje de error real — incluidos los subtests anidados.
#
# Por que no un grep: los subtests anidados van indentados ("    not ok 17 - ..."), asi
# que un `grep '^not ok '` solo ve el resumen de la suite exterior (que no dice nada
# util). Y el mensaje de error real viaja en un bloque YAML `error: |-` cuyo texto esta
# en las lineas SIGUIENTES, mas indentadas — no en la linea `error:` misma.
#
# Uso: node --test --test-reporter tap ... | awk -f scripts/tap-detalle-fallas.awk
{
  line = $0
  match(line, /^[ ]*/)
  indent = RLENGTH
  content = substr(line, indent + 1)

  if (collecting) {
    if (indent > err_indent) { print line; next }
    collecting = 0
  }

  if (content ~ /^not ok /) { print line; next }
  if (content ~ /^error: /) {
    val = substr(content, 8)
    if (val == "|-" || val == "|") { collecting = 1; err_indent = indent; next }
    print line; next
  }
}
