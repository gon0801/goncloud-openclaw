# Implementar progreso durable por ronda

[Diseño](../specs/2026-09-30-progress-events-design.md).

El [plan de recuperación](2026-09-30-progress-import-recovery.md) cubre una
importación interrumpida cuando cambian los carriles remotos. La prueba de
B3 seguido por B4 reprodujo el rechazo original. La recuperación pasa las
pruebas focalizadas del cliente, productor y tablero. Una primera revisión
detectó una carrera entre dos publicadores. Tres pruebas cubren la corrección
y una segunda revisión no encontró bloqueantes. `d506ffc` pasó los tres shards, el
contrato y el gate de Quality en la corrida 36797045197. El gateway real de
fase 19 devuelve B1, B2 y B3 mergeados con avance 100, igual que el JSON y
`estado.md` locales de U3a.

- [x] Reproducir con prueba focalizada el porcentaje inmóvil y el overwrite de
      un snapshot posterior por `set`.
- [x] Implementar contrato de eventos, reductor y cálculo de estimación para
      cualquier corrida/carril.
- [x] Implementar almacenamiento durable, revisiones, deduplicación, reparación
      tras fallo y guardia de escrituras completas.
- [x] Exponer RPC de escritura e historial; hacer que get/list/HTML lean la
      misma proyección y distingan estimación visual de entrega verificada.
- [x] Incorporar la publicación común a los productores Mac, con evidencia
      local LISTO/VEREDICTO y reintento tras caída de red.
- [x] Reconciliar U3a con el gateway y actualizar las guías de creación de
      runbooks futuros. U3a ya cerró: se conserva como histórico sin importar
      una secuencia de rondas que no quedó registrada en archivos.
- [x] Ejecutar pruebas focalizadas por cambio, hooks de pre-commit, revisión
      agrupada y batería completa una sola vez sobre el último SHA de código en CI.
- [x] Verificar lectura real del gateway y estado local antes de pedir la
      aprobación final de despliegue/integración.
- [ ] Dividir el shard 3 de Quality: en el SHA `cd0afe1` tardó 21 minutos;
      `test-simulacro-fase9.sh` consumió 654 segundos por sí sola. Mantener
      la unión exacta de la batería al cambiar el reparto.
- [ ] Validar el objeto completo de `part.added` antes de proyectarlo; una
      lista `tareas` malformada hoy devuelve un error de tipo genérico.
- [ ] Actualizar el candado de la skill para exigir `runbook.progress.event`
      en runbooks nuevos y reservar `runbook.progress.set` para históricos.
- [ ] Reducir escrituras de reparación del snapshot que solo difieren en
      formato y comprobar el límite del log antes de calcular la proyección.
- [ ] Distinguir los rechazos definitivos de `runbook.progress.event` de los
      fallos transitorios antes de decidir si un evento sale de `queue/`.
      Conservar evento, motivo y evidencia; comprobar qué ocurre con un evento
      válido posterior a un rechazo permanente.
- [ ] Reintentar la adquisición del lock de progreso si otro proceso lo borra
      durante la inspección y `statSync` devuelve `ENOENT`.
