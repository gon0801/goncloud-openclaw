# Ensayo de adopción de encargos

Estado: preparación de T11. B4 sigue abierto y no existe todavía un paquete nativo final comprobado. `cutover.py` funciona solo con `--simulation`; no instala un binario, modifica cron ni habla con un Gateway. El operador debe completar T11 con el artefacto y los comandos reales de T0 antes de pedir autorización para T12.

## Contrato del ensayo

El manifiesto de prueba fija `sourceSha`, ruta absoluta y SHA-256 del paquete y `schemaCompatibility`. `prepare` comprueba ese paquete, exige admisión congelada y captura activa, y fija el digest del manifiesto junto con la siguiente generación. `inspect` muestra el estado guardado. `apply` exige un registro de autorización que coincida con digest, alcance, generación y operación. Rechaza dos emisores, admisión incierta, cron no suspendido, turnos de cron en vuelo y peticiones del cron después de suspenderlo. Al transferir, conserva sesiones y resultados pendientes. `rollback` congela primero la admisión. Solo cambia binario y configuración de la simulación si el esquema sigue siendo legible por el binario anterior. Conserva la captura y el cron suspendido incluso tras una reversa satisfactoria.

El JSON de simulación es una observación inyectada, no un mecanismo de control para servicios reales. La prueba de dos emisores representa una anomalía que impide transferir la propiedad. En producción se necesita una lectura independiente del estado de cron, los emisores y las admisiones, más una operación real de suspensión y drenaje. No basta con editar el JSON.

## Ensayo ejecutable

Desde la raíz de G:

```sh
bash scripts/tests/test-agent-work-cutover.sh
bash scripts/tests/test-instalar-mac.sh
```

La primera prueba usa archivos temporales como dobles de paquete, estado y autorización. Espera `6` casos en verde. Comprueba el cron antiguo suspendido sin turnos en vuelo ni peticiones posteriores, un solo propietario, resultados capturados, sesión intacta, admisión incierta, hash alterado y dos fallos de reversa. La segunda prueba instala los archivos de host en un `HOME` temporal y verifica su contenido. Espera `OK test-instalar-mac`. Tiempo máximo previsto para ambas en el host de ensayo: 60 segundos. Si falla cualquiera, detén la preparación y conserva los temporales de reproducción con datos no privados; no avances a T12.

## Condiciones pendientes para operación real

B4 debe cerrar con SHA limpios de G y R, paquete construido desde el SHA revisado, hashes y migraciones comprobadas. El manifiesto final debe fijar esas versiones, compatibilidad de esquema y comandos verificados. `limits.json` conserva `productionProfile: null` y `productionAdmissionEnabled: false`; no se habilita admisión hasta medir y registrar límites finitos. Después se ensaya instalación y reversa del binario y configuración sobre un entorno aislado que ejecute el Gateway real. La reversa incompatible conserva el binario nuevo, admisión congelada y resultados pendientes. Ningún procedimiento reactiva el cron antiguo automáticamente.
