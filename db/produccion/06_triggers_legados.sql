-- =====================================================================
-- Módulo de producción — 06: desactivar los triggers legados
-- Ejecutar conectado como INV, en el mismo despliegue que el paquete y
-- la versión nueva de la página 741.
--
-- Estos triggers mueven stock y costo por su cuenta cuando una orden
-- pasa a estado C. Con ellos activos, la confirmación central duplicaría
-- todos los movimientos. Defectos comprobados (docs/produccion/01):
--   ACTUALIZA_PRODUCCION_DET     descuenta insumos x cant_producir, sin
--                                dividir por la cantidad de referencia
--   ACTUALIZA_STOCK_UTILIZADOS   vuelve a descontar los mismos insumos
--   ACTUALIZA_STOCK_PRODUCIDO    suma el producido por fuera del log
--   ACTUALIZA_COSTO_PRODUCCION   borra TODO el historial de costos del
--                                artículo y no pondera el promedio
--   ACTUALIZA_DETALLE_PRODUCCION propaga el estado y borra el detalle
--   ACTUALIZA_ANULACION_PRODUCCION propaga la anulación
-- Los triggers de auditoría (AUD_*) y de ID (SEQ_*) quedan activos.
--
-- No se borran: se desactivan, y 90_rollback.sql los reactiva.
-- =====================================================================
whenever sqlerror exit failure rollback
set serveroutput on

-- Estado previo, para el registro del despliegue
select trigger_name, table_name, status
  from user_triggers
 where trigger_name in ('ACTUALIZA_PRODUCCION_DET', 'ACTUALIZA_STOCK_UTILIZADOS',
                        'ACTUALIZA_STOCK_PRODUCIDO', 'ACTUALIZA_COSTO_PRODUCCION',
                        'ACTUALIZA_DETALLE_PRODUCCION', 'ACTUALIZA_ANULACION_PRODUCCION')
 order by table_name, trigger_name;

-- Órdenes que ya pasaron por los triggers legados: hay que conciliarlas
-- (pendiente P-04) antes o después, pero no se tocan desde acá
select c.id, c.ser_produccion || '-' || c.nro_produccion nro, c.estado, c.anulado, c.fec_produccion,
       (select count(*) from stw_entsal_cab e where e.id_produccion = c.id) ajustes_generados
  from pdw_produccion_cab c
 where nvl(c.estado, 'P') = 'C'
    or exists (select null from stw_entsal_cab e where e.id_produccion = c.id)
 order by c.id;

alter trigger actualiza_produccion_det       disable;
alter trigger actualiza_stock_utilizados     disable;
alter trigger actualiza_stock_producido      disable;
alter trigger actualiza_costo_produccion     disable;
alter trigger actualiza_detalle_produccion   disable;
alter trigger actualiza_anulacion_produccion disable;

select trigger_name, status
  from user_triggers
 where trigger_name in ('ACTUALIZA_PRODUCCION_DET', 'ACTUALIZA_STOCK_UTILIZADOS',
                        'ACTUALIZA_STOCK_PRODUCIDO', 'ACTUALIZA_COSTO_PRODUCCION',
                        'ACTUALIZA_DETALLE_PRODUCCION', 'ACTUALIZA_ANULACION_PRODUCCION');
