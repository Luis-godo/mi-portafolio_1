-- =====================================================================
-- Módulo de producción — 05: integridad y vistas de control
-- Ejecutar conectado como INV, después de compilar PRWK_PRODUCCION.
--
-- Los triggers NO mueven stock ni costo: solo impiden modificar a mano
-- documentos confirmados o anulados. Los cambios que hace el paquete
-- pasan porque PRWK_PRODUCCION.EN_PROCESO devuelve verdadero mientras
-- confirma o anula.
-- =====================================================================
whenever sqlerror exit failure rollback

-- ---------------------------------------------------------------------
-- Conversiones
-- ---------------------------------------------------------------------
create or replace trigger prw_conversiones_cab_biud
   before insert or update or delete on prw_conversiones_cab
   for each row
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   if inserting and :new.estado != 'P' then
      raise_application_error(-20200, 'Las conversiones se crean pendientes; se confirman con el botón Confirmar.');
   elsif updating and (:old.estado != 'P' or :new.estado != 'P') then
      raise_application_error(-20200, 'La conversión ' || :old.nro_comprobante || ' está '
                                      || case :old.estado when 'C' then 'confirmada' else 'anulada' end
                                      || ': no se modifica. Anúlela si hace falta corregirla.');
   elsif deleting and :old.estado != 'P' then
      raise_application_error(-20200, 'Solo se borran conversiones pendientes.');
   end if;
   if updating then
      :new.cod_usu_modif := substr(coalesce(sys_context('APEX$SESSION', 'APP_USER'), user), 1, 15);
      :new.fec_modif := sysdate;
   end if;
end;
/

create or replace trigger prw_conversiones_ing_biud
   before insert or update or delete on prw_conversiones_ing
   for each row
declare
   e_mutante exception;
   pragma exception_init(e_mutante, -4091);
   l_estado prw_conversiones_cab.estado%type;
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   select c.estado into l_estado from prw_conversiones_cab c where c.id = coalesce(:new.id_conversion, :old.id_conversion);
   if l_estado != 'P' then
      raise_application_error(-20201, 'La conversión no está pendiente: sus insumos no se modifican.');
   end if;
exception
   when e_mutante then
      null;   -- borrado en cascada desde una cabecera pendiente
   when no_data_found then
      null;
end;
/

create or replace trigger prw_conversion_res_biud
   before insert or update or delete on prw_conversion_res
   for each row
declare
   e_mutante exception;
   pragma exception_init(e_mutante, -4091);
   l_estado prw_conversiones_cab.estado%type;
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   select c.estado into l_estado from prw_conversiones_cab c where c.id = coalesce(:new.id_conversion, :old.id_conversion);
   if l_estado != 'P' then
      raise_application_error(-20201, 'La conversión no está pendiente: sus resultados no se modifican.');
   end if;
exception
   when e_mutante then
      null;
   when no_data_found then
      null;
end;
/

-- ---------------------------------------------------------------------
-- Transferencias
-- ---------------------------------------------------------------------
create or replace trigger prw_transferencia_cab_biud
   before insert or update or delete on prw_transferencia_cab
   for each row
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   if inserting and :new.estado != 'P' then
      raise_application_error(-20200, 'Las transferencias se crean pendientes; se confirman con el botón Confirmar.');
   elsif updating and (:old.estado != 'P' or :new.estado != 'P') then
      raise_application_error(-20200, 'La transferencia ' || :old.nro_comprobante
                                      || ' no está pendiente: no se modifica.');
   elsif deleting and :old.estado != 'P' then
      raise_application_error(-20200, 'Solo se borran transferencias pendientes.');
   end if;
   if updating then
      :new.cod_usu_modif := substr(coalesce(sys_context('APEX$SESSION', 'APP_USER'), user), 1, 15);
      :new.fec_modif := sysdate;
   end if;
end;
/

create or replace trigger prw_transferencia_det_biud
   before insert or update or delete on prw_transferencia_det
   for each row
declare
   e_mutante exception;
   pragma exception_init(e_mutante, -4091);
   l_estado prw_transferencia_cab.estado%type;
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   select c.estado into l_estado from prw_transferencia_cab c
    where c.id = coalesce(:new.id_transferencia, :old.id_transferencia);
   if l_estado != 'P' then
      raise_application_error(-20201, 'La transferencia no está pendiente: sus líneas no se modifican.');
   end if;
exception
   when e_mutante then
      null;
   when no_data_found then
      null;
end;
/

-- ---------------------------------------------------------------------
-- Producción: el detalle de una orden confirmada o anulada no se toca
-- a mano, y la orden no cambia de estado fuera del paquete.
-- ---------------------------------------------------------------------
create or replace trigger pdw_produccion_cab_protege
   before update or delete on pdw_produccion_cab
   for each row
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   if nvl(:old.estado, 'P') = 'C' or nvl(:old.anulado, 'N') = 'S' then
      if deleting
         or nvl(:new.estado, 'P') != nvl(:old.estado, 'P')
         or nvl(:new.anulado, 'N') != nvl(:old.anulado, 'N')
         or nvl(:new.fec_produccion, date '1900-01-01') != nvl(:old.fec_produccion, date '1900-01-01')
         or nvl(:new.id_sucursal, '-') != nvl(:old.id_sucursal, '-')
      then
         raise_application_error(-20202, 'La orden de producción ' || :old.nro_produccion
                                         || ' está confirmada o anulada: use los botones Confirmar / Anular.');
      end if;
   elsif updating and nvl(:new.estado, 'P') = 'C' then
      raise_application_error(-20202, 'Las órdenes se confirman con el botón Confirmar, no cambiando el estado.');
   end if;
end;
/

create or replace trigger pdw_produccion_det_protege
   before insert or update or delete on pdw_produccion_det
   for each row
declare
   e_mutante exception;
   pragma exception_init(e_mutante, -4091);
   l_estado varchar2(1);
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   l_estado := prwk_produccion.estado_produccion(coalesce(:new.id_produccion_cab, :old.id_produccion_cab));
   if l_estado in ('C', 'A') then
      raise_application_error(-20203, 'La orden de producción está confirmada o anulada: sus insumos no se modifican.');
   end if;
exception
   when e_mutante then
      null;
end;
/

create or replace trigger pdw_produccion_prod_protege
   before insert or update or delete on pdw_produccion_producido
   for each row
declare
   e_mutante exception;
   pragma exception_init(e_mutante, -4091);
   l_estado varchar2(1);
begin
   if prwk_produccion.en_proceso then
      return;
   end if;
   l_estado := prwk_produccion.estado_produccion(coalesce(:new.id_produccion_cab, :old.id_produccion_cab));
   if l_estado in ('C', 'A') then
      raise_application_error(-20203, 'La orden de producción está confirmada o anulada: sus producidos no se modifican.');
   end if;
exception
   when e_mutante then
      null;
end;
/

-- Una fórmula usada en producciones no se borra: el detalle de la orden
-- la referencia (PDW_PRODUCCION_DET.ID_FORMULA es obligatorio)
create or replace trigger pdw_formula_cab_protege
   before delete on pdw_formula_cab
   for each row
declare
   l_cuenta pls_integer;
begin
   select count(*)
     into l_cuenta
     from pdw_produccion_producido p
    where p.id_formula = :old.id;
   if l_cuenta > 0 then
      raise_application_error(-20204, 'La fórmula ' || :old.cod_formula || ' se usó en ' || l_cuenta
                                      || ' producciones: no se borra. Desactívela.');
   end if;
end;
/

-- =====================================================================
-- Vistas de control
-- =====================================================================

-- Artículos marcados para producción que no son genérico ni marca
create or replace view prwv_art_produccion_sin_compuesto as
select a.id_empresa, a.id id_articulo, a.cod_articulo, a.descripcion
  from stw_articulos a
 where a.ind_produccion = 'S'
   and nvl(a.estado, 'N') = 'S'
   and not exists (select null from prw_compuestos_cabecera c where c.id_producto = a.id)
   and not exists (select null from prw_compuestos_detalle d where d.id_producto = a.id);

-- Compuestos con problemas de configuración
create or replace view prwv_compuestos_con_errores as
select c.id_empresa, c.id id_compuesto, a.cod_articulo, a.descripcion,
       prwk_produccion.errores_compuesto(c.id) errores
  from prw_compuestos_cabecera c
  join stw_articulos a on a.id = c.id_producto
 where c.estado = 'A'
   and prwk_produccion.errores_compuesto(c.id) is not null;

-- Compras confirmadas con marcas de compuestos y sin conversión
create or replace view prwv_compras_pend_conversion as
select c.id_empresa, c.id id_compra_cab, c.id_sucursal, c.tip_comprobante, c.ser_comprobante,
       c.nro_comprobante, c.fec_comprobante, d.id_articulo, a.cod_articulo, a.descripcion,
       d.cantidad_ub, prwk_produccion.factor_marca(c.id_empresa, d.id_articulo) factor_ub,
       d.cantidad_ub * prwk_produccion.factor_marca(c.id_empresa, d.id_articulo) cantidad_generico,
       prwk_produccion.generico_de(c.id_empresa, d.id_articulo, c.id_sucursal) id_generico
  from cmw_compras_cabecera c
  join cmw_compras_detalle d on d.id_compras_cab = c.id
  join stw_articulos a on a.id = d.id_articulo
 where c.estado = 'C'
   and nvl(d.ind_stock, 'S') = 'S'
   and prwk_produccion.generico_de(c.id_empresa, d.id_articulo, c.id_sucursal) is not null
   and not exists (select null
                     from prw_conversiones_cab v
                    where v.id_compra_cab = c.id
                      and v.estado != 'A');

-- Órdenes de compra de los últimos 180 días que no respetan la regla de producción
create or replace view prwv_oc_produccion_errores as
select c.id_empresa, c.id id_pedido_cab, c.id_sucursal, c.tip_comprobante, c.ser_comprobante,
       c.nro_comprobante, c.fec_comprobante, c.ind_produccion,
       prwk_produccion.errores_orden_compra(c.id) errores
  from cmw_pedidos_cabecera c
 where nvl(c.anulado, 'N') = 'N'
   and c.fec_comprobante >= trunc(sysdate) - 180
   and prwk_produccion.errores_orden_compra(c.id) is not null;

-- Fórmulas activas incompletas o mal referenciadas
create or replace view prwv_formulas_incompletas as
select f.id_empresa, f.id id_formula, f.cod_formula, f.comentario, a.cod_articulo, a.descripcion,
       'Sin ingredientes' problema
  from pdw_formula_cab f
  join stw_articulos a on a.id = f.id_articulo
 where f.estado = 'S'
   and not exists (select null from pdw_formula_det d where d.id_formula_cab = f.id)
union all
select f.id_empresa, f.id, f.cod_formula, f.comentario, a.cod_articulo, a.descripcion,
       'Sin productos resultantes'
  from pdw_formula_cab f
  join stw_articulos a on a.id = f.id_articulo
 where f.estado = 'S'
   and not exists (select null from pdw_formula_producidos p where p.id_formula = f.id)
union all
select f.id_empresa, f.id, f.cod_formula, f.comentario, a.cod_articulo, a.descripcion,
       'Sin cantidad de referencia'
  from pdw_formula_cab f
  join stw_articulos a on a.id = f.id_articulo
 where f.estado = 'S'
   and nvl(f.cantidad_ub, 0) <= 0
union all
select f.id_empresa, f.id, f.cod_formula, f.comentario, i.cod_articulo, i.descripcion,
       'Usa la marca en lugar del genérico'
  from pdw_formula_cab f
  join pdw_formula_det d on d.id_formula_cab = f.id
  join stw_articulos i on i.id = d.id_articulo
 where f.estado = 'S'
   and exists (select null from prw_compuestos_detalle x where x.id_producto = d.id_articulo and x.estado = 'A')
union all
select f.id_empresa, f.id, f.cod_formula, f.comentario, i.cod_articulo, i.descripcion,
       'Ingrediente inactivo'
  from pdw_formula_cab f
  join pdw_formula_det d on d.id_formula_cab = f.id
  join stw_articulos i on i.id = d.id_articulo
 where f.estado = 'S'
   and nvl(i.estado, 'N') != 'S';

-- Rendimiento por producido: planificado contra real
create or replace view prwv_rendimiento_produccion as
select to_number(c.id_empresa) id_empresa, c.id id_produccion, c.ser_produccion, c.nro_produccion,
       c.fec_produccion,
       case when nvl(c.anulado, 'N') = 'S' then 'A' else nvl(c.estado, 'P') end estado,
       f.cod_formula, a.cod_articulo, a.descripcion,
       p.cantidad cantidad_teorica, nvl(p.cant_procesada, 0) cantidad_real,
       nvl(p.cant_procesada, 0) - p.cantidad desvio,
       case when p.cantidad > 0 then round((nvl(p.cant_procesada, 0) - p.cantidad) / p.cantidad * 100, 2) end desvio_porc,
       nvl(f.tolerancia_porc, to_number(w_busca_parametro('PD', 'PRW_TOLERANCIA_PORC'))) tolerancia_porc,
       case when p.cantidad > 0
             and abs((nvl(p.cant_procesada, 0) - p.cantidad) / p.cantidad * 100)
                 > nvl(f.tolerancia_porc, to_number(w_busca_parametro('PD', 'PRW_TOLERANCIA_PORC')))
            then 'S' else 'N' end fuera_tolerancia,
       p.costo, case when p.cantidad_ub > 0 then round(p.costo / p.cantidad_ub, 2) end costo_unitario,
       c.motivo_desvio
  from pdw_produccion_cab c
  join pdw_produccion_producido p on p.id_produccion_cab = c.id
  join pdw_formula_cab f on f.id = p.id_formula
  join stw_articulos a on a.id = p.id_articulo;

-- Costo unitario de cada producción confirmada frente a la anterior del
-- mismo artículo: detecta saltos de costo
create or replace view prwv_costos_produccion as
select r.*,
       lag(r.costo_unitario) over (partition by r.id_empresa, r.cod_articulo order by r.fec_produccion, r.id_produccion) costo_unitario_anterior,
       case when lag(r.costo_unitario) over (partition by r.id_empresa, r.cod_articulo order by r.fec_produccion, r.id_produccion) > 0
            then round((r.costo_unitario
                        / lag(r.costo_unitario) over (partition by r.id_empresa, r.cod_articulo order by r.fec_produccion, r.id_produccion)
                        - 1) * 100, 2)
       end variacion_porc
  from prwv_rendimiento_produccion r
 where r.estado = 'C';

-- Documentos del módulo y los ajustes de stock que generaron
create or replace view prwv_movimientos_modulo as
select c.id_empresa, c.tip_referencia tipo_documento, c.id_referencia id_documento,
       c.num_referencia nro_documento,
       case c.ser_referencia when 'CONF' then 'Confirmación' when 'ANUL' then 'Anulación' end operacion,
       c.id id_entsal_cab, c.ser_ent_sal || '-' || c.num_ent_sal nro_ajuste, c.fec_ent_sal,
       c.id_sucursal, m.ind_ent_sal, m.descripcion motivo,
       d.id_articulo, a.cod_articulo, a.descripcion, d.id_lote, d.nro_lote, d.fec_venc,
       d.cantidad, d.cantidad_ub, d.costo costo_unitario, d.total_costo,
       c.cod_usuario_aud usuario
  from stw_entsal_cab c
  join stw_motivo_ent_sal m on m.id = c.id_motivo_ent_sal
  join stw_entsal_det d on d.id_entsal_cab = c.id
  join stw_articulos a on a.id = d.id_articulo
 where c.tip_referencia in ('CNV', 'TRF', 'PRO')
   and c.ser_referencia in ('CONF', 'ANUL');

-- Documentos confirmados sin movimientos, o con movimientos y no confirmados
create or replace view prwv_documentos_inconsistentes as
select x.id_empresa, x.tipo_documento, x.id_documento, x.nro_documento, x.estado, x.problema
  from (select c.id_empresa, 'CNV' tipo_documento, c.id id_documento, c.nro_comprobante nro_documento, c.estado,
               case when c.estado = 'C' and not exists (select null from stw_entsal_cab e
                                                         where e.tip_referencia = 'CNV' and e.id_referencia = c.id
                                                           and e.ser_referencia = 'CONF')
                         then 'Confirmada sin movimientos de stock'
                    when c.estado = 'P' and exists (select null from stw_entsal_cab e
                                                     where e.tip_referencia = 'CNV' and e.id_referencia = c.id)
                         then 'Pendiente con movimientos de stock'
                    when c.estado = 'A' and not exists (select null from stw_entsal_cab e
                                                         where e.tip_referencia = 'CNV' and e.id_referencia = c.id
                                                           and e.ser_referencia = 'ANUL')
                         then 'Anulada sin reversión'
               end problema
          from prw_conversiones_cab c
        union all
        select t.id_empresa, 'TRF', t.id, t.nro_comprobante, t.estado,
               case when t.estado = 'C' and not exists (select null from stw_entsal_cab e
                                                         where e.tip_referencia = 'TRF' and e.id_referencia = t.id
                                                           and e.ser_referencia = 'CONF')
                         then 'Confirmada sin movimientos de stock'
                    when t.estado = 'P' and exists (select null from stw_entsal_cab e
                                                     where e.tip_referencia = 'TRF' and e.id_referencia = t.id)
                         then 'Pendiente con movimientos de stock'
                    when t.estado = 'A' and not exists (select null from stw_entsal_cab e
                                                         where e.tip_referencia = 'TRF' and e.id_referencia = t.id
                                                           and e.ser_referencia = 'ANUL')
                         then 'Anulada sin reversión'
               end
          from prw_transferencia_cab t
        union all
        select to_number(p.id_empresa), 'PRO', p.id, p.nro_produccion,
               case when nvl(p.anulado, 'N') = 'S' then 'A' else nvl(p.estado, 'P') end,
               case when nvl(p.estado, 'P') = 'C' and nvl(p.anulado, 'N') = 'N'
                         and p.fec_confir is not null
                         and not exists (select null from stw_entsal_cab e
                                          where e.tip_referencia = 'PRO' and e.id_referencia = p.id
                                            and e.ser_referencia = 'CONF')
                         then 'Confirmada sin movimientos de stock'
                    when nvl(p.estado, 'P') = 'C' and p.fec_confir is null
                         then 'Confirmada fuera del módulo (triggers legados)'
                    when nvl(p.estado, 'P') = 'P'
                         and exists (select null from stw_entsal_cab e where e.id_produccion = p.id)
                         then 'Pendiente con ajustes de stock generados'
               end
          from pdw_produccion_cab p) x
 where x.problema is not null;
