-- =====================================================================
-- Módulo de producción — reversión del despliegue
-- Ejecutar conectado como INV.
--
-- Deja la base como estaba antes de 01..06, SALVO los datos: si ya se
-- confirmaron documentos con el módulo, sus ajustes de stock y costos
-- quedan registrados (STW_ENTSAL_*, STW_HIST_COSTOS_ART) y no se borran.
-- Por eso el script se detiene si encuentra documentos confirmados.
-- La aplicación se revierte aparte, reimportando la versión anterior.
-- =====================================================================
whenever sqlerror exit failure rollback
set serveroutput on

declare
   l_confirmados pls_integer;
begin
   select (select count(*) from prw_conversiones_cab where estado != 'P')
        + (select count(*) from prw_transferencia_cab where estado != 'P')
        + (select count(*) from pdw_produccion_cab where fec_confir is not null)
     into l_confirmados
     from dual;
   if l_confirmados > 0 then
      raise_application_error(-20000, 'Hay ' || l_confirmados || ' documentos confirmados o anulados con el '
                                      || 'módulo nuevo. Revertir ahora dejaría movimientos sin documento. '
                                      || 'Revisar con el responsable antes de seguir.');
   end if;
end;
/

-- 06: triggers legados
alter trigger actualiza_produccion_det       enable;
alter trigger actualiza_stock_utilizados     enable;
alter trigger actualiza_stock_producido      enable;
alter trigger actualiza_costo_produccion     enable;
alter trigger actualiza_detalle_produccion   enable;
alter trigger actualiza_anulacion_produccion enable;

-- 05: integridad y vistas
drop trigger prw_conversiones_cab_biud;
drop trigger prw_conversiones_ing_biud;
drop trigger prw_conversion_res_biud;
drop trigger prw_transferencia_cab_biud;
drop trigger prw_transferencia_det_biud;
drop trigger pdw_produccion_cab_protege;
drop trigger pdw_produccion_det_protege;
drop trigger pdw_produccion_prod_protege;
drop trigger pdw_formula_cab_protege;
drop view prwv_art_produccion_sin_compuesto;
drop view prwv_compuestos_con_errores;
drop view prwv_compras_pend_conversion;
drop view prwv_oc_produccion_errores;
drop view prwv_formulas_incompletas;
drop view prwv_costos_produccion;
drop view prwv_rendimiento_produccion;
drop view prwv_movimientos_modulo;
drop view prwv_documentos_inconsistentes;

-- 03/04: paquete
drop package prwk_produccion;

-- 02: menú y permisos de las páginas nuevas (los motivos y parámetros
-- se dejan: no molestan y pueden estar referenciados por ajustes)
delete from bsw_acceso_por_grupos_apex
 where pagina_id in (select nav_id from bsw_formas_paginas
                      where page_no in ('1700', '1701', '1702', '1703', '1704', '1705', '1706', '1707'));
delete from bsw_formas_paginas
 where page_no in ('1700', '1701', '1702', '1703', '1704', '1705', '1706', '1707');

-- 01: columnas agregadas (las tablas PRW_* nuevas quedan; para volver al
-- DDL original hay que recrearlas con el script con que se crearon)
alter table pdw_formula_cab drop (tolerancia_porc);
alter table pdw_produccion_det drop (cantidad_real);
alter table pdw_produccion_cab drop (cod_usu_confir, fec_confir, cod_usu_anula,
                                     fec_anulacion, motivo_anulacion, motivo_desvio);

commit;
