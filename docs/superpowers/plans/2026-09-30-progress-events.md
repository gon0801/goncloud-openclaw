# Implementar progreso durable por ronda

[Diseño](../specs/2026-09-30-progress-events-design.md).

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
- [ ] Ejecutar pruebas focalizadas por cambio, hooks de pre-commit, revisión
      agrupada y batería completa una sola vez sobre el SHA final en CI.
- [ ] Verificar lectura real del gateway y estado local antes de pedir la
      aprobación final de despliegue/integración.
