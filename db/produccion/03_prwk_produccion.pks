create or replace package prwk_produccion
as
   -- ==================================================================
   -- Módulo de producción: artículos compuestos, conversiones,
   -- transferencias entre artículos, producción y control de compras.
   --
   -- Reglas comunes:
   -- * Ningún procedimiento hace COMMIT. El límite de la transacción lo
   --   pone quien llama (el proceso APEX al terminar la petición). Las
   --   confirmaciones y anulaciones abren un SAVEPOINT y vuelven a él si
   --   algo falla, así no quedan movimientos parciales.
   -- * El stock se mueve solo generando ajustes STW_ENTSAL_CAB/DET, que
   --   el trigger STWT_ENTSAL_DET_PROCESA_STOCK pasa por
   --   STWK_EXISTENCIA (mecanismo oficial, con log y reversión). Cada
   --   movimiento verifica la existencia antes y después: si el delta no
   --   es el esperado, se revierte todo.
   -- * El costo promedio se recalcula con un único criterio, ponderado y
   --   en unidad base, sobre todas las sucursales que manejan stock
   --   (el mismo que usa la confirmación de compras).
   -- * Errores de negocio: ORA-20100 a ORA-20199, con un mensaje que
   --   dice qué falta y cómo corregirlo.
   -- ==================================================================

   -- Verdadero mientras el paquete modifica documentos. Los triggers de
   -- integridad lo consultan para dejar pasar solo los cambios hechos
   -- por la confirmación o la anulación.
   function en_proceso return boolean;

   -- ---------------- Unidades y compuestos ----------------
   -- Cantidad expresada en la unidad base del artículo
   function a_unidad_base(p_id_articulo      in number,
                          p_id_unidad_medida in number,
                          p_cantidad         in number)
      return number;

   -- Genérico al que pertenece una marca, habilitado en la sucursal.
   -- Nulo si la marca no pertenece a ningún compuesto activo.
   function generico_de(p_id_empresa  in number,
                        p_id_marca    in number,
                        p_id_sucursal in number)
      return number;

   -- Unidades base del genérico por unidad base de la marca
   function factor_marca(p_id_empresa in number,
                         p_id_marca   in number)
      return number;

   -- 'S' si el artículo es marca de algún compuesto activo
   function es_marca(p_id_empresa  in number,
                     p_id_articulo in number)
      return varchar2;

   -- Valida un compuesto completo. Devuelve los errores separados por
   -- salto de línea, o nulo si está bien.
   function errores_compuesto(p_id_compuesto in number)
      return varchar2;

   -- ---------------- Conversiones ----------------
   -- Calcula cantidades en unidad base, costos de insumos y su
   -- distribución entre los resultados. Solo en estado P (vista previa).
   procedure calcular_conversion(p_id_conversion in number);

   procedure confirmar_conversion(p_id_conversion in number);

   procedure anular_conversion(p_id_conversion in number,
                               p_motivo        in varchar2);

   -- Genera una conversión pendiente marca -> genérico a partir de una
   -- factura de compra confirmada.
   procedure generar_conversion_compra(p_id_compra_cab in  number,
                                       p_id_conversion out number);

   -- ---------------- Transferencias ----------------
   procedure confirmar_transferencia(p_id_transferencia in number);

   procedure anular_transferencia(p_id_transferencia in number,
                                  p_motivo           in varchar2);

   -- ---------------- Producción ----------------
   -- Regenera los insumos (PDW_PRODUCCION_DET, INDICE = 'M') desde las
   -- fórmulas, para la cantidad procesada de cada producido (o la
   -- planificada si todavía no hay procesada). Conserva el consumo real
   -- ya cargado para el mismo artículo, fórmula y sucursal.
   procedure calcular_insumos_produccion(p_id_produccion in number);

   -- Desvíos de rendimiento fuera de tolerancia, uno por línea.
   -- Nulo si todo está dentro de tolerancia.
   function desvios_produccion(p_id_produccion in number)
      return varchar2;

   procedure confirmar_produccion(p_id_produccion in number,
                                  p_forzar_desvio in varchar2 default 'N',
                                  p_motivo_desvio in varchar2 default null);

   procedure anular_produccion(p_id_produccion in number,
                               p_motivo        in varchar2);

   -- Crea una orden de producción pendiente con un producido por
   -- fórmula. Si p_id_produccion viene informado, agrega a esa orden.
   procedure agregar_a_orden(p_id_empresa    in     number,
                             p_id_sucursal   in     number,
                             p_fecha         in     date,
                             p_id_formula    in     number,
                             p_cantidad      in     number,
                             p_id_produccion in out number);

   -- 'P' pendiente, 'C' confirmada, 'A' anulada
   function estado_produccion(p_id_produccion in number)
      return varchar2;

   -- ---------------- Compras ----------------
   -- Errores de producción de una orden de compra (decisión D-1), o
   -- nulo si está bien.
   function errores_orden_compra(p_id_pedido_cab in number)
      return varchar2;
end prwk_produccion;
/
