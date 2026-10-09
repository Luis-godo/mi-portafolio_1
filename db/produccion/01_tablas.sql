-- =====================================================================
-- Módulo de producción — 01: estructura
-- Ejecutar conectado como INV.
--
-- 1. Recrea las tablas PRW_* (creadas el 2026-10-09, vacías y sin uso)
--    con el modelo del resto del esquema: IDs numéricos, FK, UK, CHECK
--    de estados y secuencias. Aborta si alguna tiene filas.
-- 2. Agrega a las tablas PDW_* existentes las columnas que necesita la
--    confirmación central (tolerancia, consumo real, auditoría).
-- 3. Triggers de integridad: protegen los documentos confirmados.
--
-- Estados de los documentos PRW: P pendiente, C confirmado, A anulado.
-- =====================================================================
whenever sqlerror exit failure rollback
set serveroutput on

-- ---------------------------------------------------------------------
-- 0. Las PRW_* tienen que estar vacías
-- ---------------------------------------------------------------------
declare
   l_filas pls_integer;
begin
   for t in (select table_name
               from user_tables
              where table_name in ('PRW_COMPUESTOS_CABECERA', 'PRW_COMPUESTOS_DETALLE',
                                   'PRW_COMPUESTOS_SUCURSALES', 'PRW_CONVERSIONES_CAB',
                                   'PRW_CONVERSIONES_ING', 'PRW_CONVERSION_RES',
                                   'PRW_TRANSFERENCIA_CAB', 'PRW_TRANSFERENCIA_DET'))
   loop
      execute immediate 'select count(*) from ' || t.table_name into l_filas;
      if l_filas > 0 then
         raise_application_error(-20000, t.table_name || ' tiene ' || l_filas
                                         || ' filas: no se recrea. Revisar antes de seguir.');
      end if;
      execute immediate 'drop table ' || t.table_name || ' cascade constraints purge';
      dbms_output.put_line('Eliminada ' || t.table_name);
   end loop;
end;
/

-- ---------------------------------------------------------------------
-- 1. Secuencias
-- ---------------------------------------------------------------------
create sequence prw_compuestos_cab_id_seq   nocache;
create sequence prw_compuestos_det_id_seq   nocache;
create sequence prw_compuestos_suc_id_seq   nocache;
create sequence prw_conversiones_cab_id_seq nocache;
create sequence prw_conversiones_ing_id_seq nocache;
create sequence prw_conversion_res_id_seq   nocache;
create sequence prw_transferencia_cab_id_seq nocache;
create sequence prw_transferencia_det_id_seq nocache;
-- Numeración de comprobantes y de los ajustes de stock que generan
create sequence prw_conversiones_nro_seq    nocache;
create sequence prw_transferencia_nro_seq   nocache;
create sequence prw_entsal_nro_seq          nocache;

-- ---------------------------------------------------------------------
-- 2. Artículos compuestos
--    Cabecera = artículo genérico de producción (ID_PRODUCTO).
--    Detalle  = marcas que lo reemplazan. FACTOR_UB: cuántas unidades
--               base del genérico equivalen a 1 unidad base de la marca
--               (bolsa de 25 kg -> 25). Es una equivalencia ENTRE
--               artículos: STW_RELACIONES solo convierte unidades de un
--               mismo artículo, por eso hace falta esta columna.
--    Sucursales = dónde se permite usar la relación.
-- ---------------------------------------------------------------------
create table prw_compuestos_cabecera (
   id               number(10)    default on null prw_compuestos_cab_id_seq.nextval not null,
   id_empresa       number(10)    not null,
   id_producto      number(10)    not null,
   estado           varchar2(1)   default on null 'A' not null,
   costo_guia_prod  number(21, 6),
   observacion      varchar2(300),
   cod_usu_alta     varchar2(15)  default on null coalesce(sys_context('APEX$SESSION', 'APP_USER'), user),
   fec_alta         date          default on null sysdate,
   cod_usu_modif    varchar2(15),
   fec_modif        date,
   constraint pk_prw_compuestos_cabecera primary key (id),
   constraint uk_prw_compuestos_cab_prod unique (id_empresa, id_producto),
   constraint fk_prw_comp_cab_empresa foreign key (id_empresa) references bsw_empresas (id),
   constraint fk_prw_comp_cab_articulo foreign key (id_producto) references stw_articulos (id),
   constraint ck_prw_comp_cab_estado check (estado in ('A', 'I'))
);

create table prw_compuestos_detalle (
   id               number(10)    default on null prw_compuestos_det_id_seq.nextval not null,
   id_empresa       number(10)    not null,
   id_compuesto     number(10)    not null,
   id_producto      number(10)    not null,
   factor_ub        number(18, 6) not null,
   estado           varchar2(1)   default on null 'A' not null,
   cod_usu_alta     varchar2(15)  default on null coalesce(sys_context('APEX$SESSION', 'APP_USER'), user),
   fec_alta         date          default on null sysdate,
   cod_usu_modif    varchar2(15),
   fec_modif        date,
   constraint pk_prw_compuestos_detalle primary key (id),
   -- Una marca pertenece a un solo genérico: el destino de producción es único
   constraint uk_prw_compuestos_det_prod unique (id_empresa, id_producto),
   constraint fk_prw_comp_det_cab foreign key (id_compuesto)
      references prw_compuestos_cabecera (id) on delete cascade,
   constraint fk_prw_comp_det_articulo foreign key (id_producto) references stw_articulos (id),
   constraint ck_prw_comp_det_factor check (factor_ub > 0),
   constraint ck_prw_comp_det_estado check (estado in ('A', 'I'))
);
create index ix_prw_compuestos_det_cab on prw_compuestos_detalle (id_compuesto);

create table prw_compuestos_sucursales (
   id               number(10)    default on null prw_compuestos_suc_id_seq.nextval not null,
   id_empresa       number(10)    not null,
   id_compuesto     number(10)    not null,
   id_sucursal      number(10)    not null,
   cod_usu_alta     varchar2(15)  default on null coalesce(sys_context('APEX$SESSION', 'APP_USER'), user),
   fec_alta         date          default on null sysdate,
   cod_usu_modif    varchar2(15),
   fec_modif        date,
   constraint pk_prw_compuestos_sucursales primary key (id),
   constraint uk_prw_compuestos_suc unique (id_compuesto, id_sucursal),
   constraint fk_prw_comp_suc_cab foreign key (id_compuesto)
      references prw_compuestos_cabecera (id) on delete cascade,
   constraint fk_prw_comp_suc_sucursal foreign key (id_sucursal) references bsw_sucursales (id)
);

-- ---------------------------------------------------------------------
-- 3. Conversiones
--    TIPO_COSTO: C = con costo (el valor de los insumos pasa a los
--                    resultados por porcentaje o por cantidad)
--                S = sin traslado automático (los subproductos se
--                    valúan al costo informado y el principal recibe el
--                    resto: el valor total se conserva)
--    ORIGEN:     M = manual, R = generada desde una factura de compra
-- ---------------------------------------------------------------------
create table prw_conversiones_cab (
   id                number(10)    default on null prw_conversiones_cab_id_seq.nextval not null,
   id_empresa        number(10)    not null,
   tip_comprobante   varchar2(3)   default on null 'CNV' not null,
   ser_comprobante   varchar2(7)   default on null 'A' not null,
   nro_comprobante   number(10)    default on null prw_conversiones_nro_seq.nextval not null,
   fec_comprobante   date          default on null trunc(sysdate) not null,
   id_sucursal       number(10)    not null,
   tipo_costo        varchar2(1)   default on null 'C' not null,
   origen            varchar2(1)   default on null 'M' not null,
   ind_desposte      varchar2(1)   default on null 'N' not null,
   id_compra_cab     number(10),
   porc_gastos_adm   number(6, 2),
   total_gastos_adm  number(20, 3),
   costo_insumos     number(20, 3),
   costo_total       number(20, 3),
   motivo            varchar2(500),
   estado            varchar2(1)   default on null 'P' not null,
   asientos          varchar2(500),
   cod_usu_alta      varchar2(15)  default on null coalesce(sys_context('APEX$SESSION', 'APP_USER'), user),
   fec_alta          date          default on null sysdate,
   cod_usu_modif     varchar2(15),
   fec_modif         date,
   cod_usu_confir    varchar2(15),
   fec_confir        date,
   cod_usu_anula     varchar2(15),
   fec_anulacion     date,
   motivo_anulacion  varchar2(500),
   constraint pk_prw_conversiones_cab primary key (id),
   constraint uk_prw_conversiones_cab_comp unique (id_empresa, tip_comprobante, ser_comprobante, nro_comprobante),
   constraint fk_prw_conv_cab_empresa foreign key (id_empresa) references bsw_empresas (id),
   constraint fk_prw_conv_cab_sucursal foreign key (id_sucursal) references bsw_sucursales (id),
   constraint fk_prw_conv_cab_compra foreign key (id_compra_cab) references cmw_compras_cabecera (id),
   constraint ck_prw_conv_cab_estado check (estado in ('P', 'C', 'A')),
   constraint ck_prw_conv_cab_tipo check (tipo_costo in ('C', 'S')),
   constraint ck_prw_conv_cab_origen check (origen in ('M', 'R')),
   constraint ck_prw_conv_cab_desposte check (ind_desposte in ('S', 'N')),
   constraint ck_prw_conv_cab_gastos check (nvl(porc_gastos_adm, 0) >= 0 and nvl(total_gastos_adm, 0) >= 0)
);
create index ix_prw_conversiones_cab_compra on prw_conversiones_cab (id_compra_cab);

create table prw_conversiones_ing (
   id                number(10)    default on null prw_conversiones_ing_id_seq.nextval not null,
   id_conversion     number(10)    not null,
   id_empresa        number(10)    not null,
   nro_orden         number(8),
   id_articulo       number(10)    not null,
   id_lote           number(10),
   id_unidad_medida  number(10)    not null,
   cantidad          number(18, 6) not null,
   cantidad_ub       number(18, 6),
   id_compra_det     number(10),
   costo_unitario    number(21, 6),
   costo_total       number(20, 3),
   constraint pk_prw_conversiones_ing primary key (id),
   constraint fk_prw_conv_ing_cab foreign key (id_conversion)
      references prw_conversiones_cab (id) on delete cascade,
   constraint fk_prw_conv_ing_articulo foreign key (id_articulo) references stw_articulos (id),
   constraint fk_prw_conv_ing_lote foreign key (id_lote) references stw_lotes (id),
   constraint fk_prw_conv_ing_um foreign key (id_unidad_medida) references stw_unidades_medida (id),
   constraint ck_prw_conv_ing_cantidad check (cantidad > 0)
);
create index ix_prw_conversiones_ing_cab on prw_conversiones_ing (id_conversion);

create table prw_conversion_res (
   id                   number(10)    default on null prw_conversion_res_id_seq.nextval not null,
   id_conversion        number(10)    not null,
   id_empresa           number(10)    not null,
   nro_orden            number(8),
   id_articulo          number(10)    not null,
   id_lote              number(10),
   nro_lote             varchar2(30),
   fec_vencimiento      date,
   id_unidad_medida     number(10)    not null,
   cantidad             number(18, 6) not null,
   cantidad_ub          number(18, 6),
   articulo_principal   varchar2(1)   default on null 'N' not null,
   porc_costo           number(9, 5),
   costo_unitario_inf   number(21, 6),
   costo_total          number(20, 3),
   costo_unitario       number(21, 6),
   constraint pk_prw_conversion_res primary key (id),
   constraint fk_prw_conv_res_cab foreign key (id_conversion)
      references prw_conversiones_cab (id) on delete cascade,
   constraint fk_prw_conv_res_articulo foreign key (id_articulo) references stw_articulos (id),
   constraint fk_prw_conv_res_lote foreign key (id_lote) references stw_lotes (id),
   constraint fk_prw_conv_res_um foreign key (id_unidad_medida) references stw_unidades_medida (id),
   constraint ck_prw_conv_res_cantidad check (cantidad > 0),
   constraint ck_prw_conv_res_principal check (articulo_principal in ('S', 'N')),
   constraint ck_prw_conv_res_porc check (porc_costo is null or porc_costo between 0 and 100),
   constraint ck_prw_conv_res_costo_inf check (costo_unitario_inf is null or costo_unitario_inf >= 0)
);
create index ix_prw_conversion_res_cab on prw_conversion_res (id_conversion);

-- ---------------------------------------------------------------------
-- 4. Transferencias entre artículos y/o sucursales
--    ID_COMPRA_CAB: si la transferencia corrige una recepción, el costo
--    de salida se toma de esa compra y no del promedio actual.
-- ---------------------------------------------------------------------
create table prw_transferencia_cab (
   id                number(10)    default on null prw_transferencia_cab_id_seq.nextval not null,
   id_empresa        number(10)    not null,
   tip_comprobante   varchar2(3)   default on null 'TRF' not null,
   ser_comprobante   varchar2(7)   default on null 'A' not null,
   nro_comprobante   number(10)    default on null prw_transferencia_nro_seq.nextval not null,
   fec_comprobante   date          default on null trunc(sysdate) not null,
   id_sucursal       number(10)    not null,
   id_sucursal_ent   number(10)    not null,
   id_compra_cab     number(10),
   motivo            varchar2(500) not null,
   estado            varchar2(1)   default on null 'P' not null,
   cod_usu_alta      varchar2(15)  default on null coalesce(sys_context('APEX$SESSION', 'APP_USER'), user),
   fec_alta          date          default on null sysdate,
   cod_usu_modif     varchar2(15),
   fec_modif         date,
   cod_usu_confir    varchar2(15),
   fec_confir        date,
   cod_usu_anula     varchar2(15),
   fec_anulacion     date,
   motivo_anulacion  varchar2(500),
   constraint pk_prw_transferencia_cab primary key (id),
   constraint uk_prw_transferencia_cab_comp unique (id_empresa, tip_comprobante, ser_comprobante, nro_comprobante),
   constraint fk_prw_trf_cab_empresa foreign key (id_empresa) references bsw_empresas (id),
   constraint fk_prw_trf_cab_suc_sal foreign key (id_sucursal) references bsw_sucursales (id),
   constraint fk_prw_trf_cab_suc_ent foreign key (id_sucursal_ent) references bsw_sucursales (id),
   constraint fk_prw_trf_cab_compra foreign key (id_compra_cab) references cmw_compras_cabecera (id),
   constraint ck_prw_trf_cab_estado check (estado in ('P', 'C', 'A'))
);

create table prw_transferencia_det (
   id                     number(10)    default on null prw_transferencia_det_id_seq.nextval not null,
   id_transferencia       number(10)    not null,
   id_empresa             number(10)    not null,
   nro_orden              number(8),
   id_articulo            number(10)    not null,
   id_lote                number(10),
   id_unidad_medida       number(10)    not null,
   cantidad               number(18, 6) not null,
   cantidad_ub            number(18, 6),
   id_articulo_conv       number(10),
   id_lote_conv           number(10),
   id_unidad_medida_conv  number(10),
   cantidad_conv          number(18, 6),
   cantidad_ub_conv       number(18, 6),
   costo_unitario         number(21, 6),
   costo_total            number(20, 3),
   constraint pk_prw_transferencia_det primary key (id),
   constraint fk_prw_trf_det_cab foreign key (id_transferencia)
      references prw_transferencia_cab (id) on delete cascade,
   constraint fk_prw_trf_det_articulo foreign key (id_articulo) references stw_articulos (id),
   constraint fk_prw_trf_det_lote foreign key (id_lote) references stw_lotes (id),
   constraint fk_prw_trf_det_um foreign key (id_unidad_medida) references stw_unidades_medida (id),
   constraint fk_prw_trf_det_art_conv foreign key (id_articulo_conv) references stw_articulos (id),
   constraint fk_prw_trf_det_lote_conv foreign key (id_lote_conv) references stw_lotes (id),
   constraint fk_prw_trf_det_um_conv foreign key (id_unidad_medida_conv) references stw_unidades_medida (id),
   constraint ck_prw_trf_det_cantidad check (cantidad > 0),
   constraint ck_prw_trf_det_cantidad_conv check (cantidad_conv is null or cantidad_conv > 0)
);
create index ix_prw_transferencia_det_cab on prw_transferencia_det (id_transferencia);

-- ---------------------------------------------------------------------
-- 5. Columnas nuevas en tablas existentes
-- ---------------------------------------------------------------------
-- Tolerancia de rendimiento por fórmula (en %). Nula = se usa el
-- parámetro general PD.PRW_TOLERANCIA_PORC.
alter table pdw_formula_cab add (tolerancia_porc number(6, 2));

-- Consumo real de cada insumo. CANTIDAD queda como el teórico calculado
-- por la receta para la cantidad producida.
alter table pdw_produccion_det add (cantidad_real number(18, 4));

-- Auditoría de confirmación y anulación, y justificación de desvíos
alter table pdw_produccion_cab add (
   cod_usu_confir    varchar2(15),
   fec_confir        date,
   cod_usu_anula     varchar2(15),
   fec_anulacion     date,
   motivo_anulacion  varchar2(500),
   motivo_desvio     varchar2(500)
);
