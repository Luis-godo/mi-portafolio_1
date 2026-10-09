-- =====================================================================
-- Módulo de producción — 07: pruebas funcionales
-- Ejecutar conectado como INV DESPUÉS de 01..06.
--
-- Corre los escenarios en UNA transacción y termina con ROLLBACK: no
-- deja datos. Cada control imprime OK o FALLA con el valor obtenido.
--
-- El ROLLBACK deshace stock, costos y documentos. Lo único que queda son
-- las filas de STW_LOG_EXISTENCIAS: STWK_EXISTENCIA las graba en una
-- transacción autónoma. Por eso conviene correrlo en una copia de la base;
-- en producción dejaría en el log movimientos que no ocurrieron.
--
-- Completar los artículos de prueba (IDs de STW_ARTICULOS) antes de
-- ejecutar. Todos de la misma empresa y con stock en la sucursal.
-- =====================================================================
set serveroutput on size unlimited
whenever sqlerror exit failure rollback

define id_empresa   = 121
define id_sucursal  = 0      -- sucursal con stock de las marcas y de la carne
define id_sucursal2 = 0      -- otra sucursal de la misma empresa
define id_generico  = 0      -- "Harina para producción", unidad base kilo
define id_marca1    = 0      -- harina marca A, unidad base bolsa
define id_marca2    = 0      -- harina marca B, unidad base bolsa
define id_carne     = 0      -- carne, unidad base kilo
define id_sebo      = 0      -- sebo, unidad base kilo
define id_formula   = 0      -- fórmula activa cuyos insumos tengan stock en la sucursal

declare
   l_fallas     pls_integer := 0;
   l_id_comp    number;
   l_id_conv    number;
   l_id_trf     number;
   l_id_prod    number;
   l_ub_gen     number;
   l_exis_antes number;
   l_exis_desp  number;
   l_prom_antes number;
   l_prom_desp  number;
   l_valor      number;
   l_texto      varchar2(4000);

   procedure control(p_nombre varchar2, p_ok boolean, p_detalle varchar2 default null) is
   begin
      if p_ok then
         dbms_output.put_line('OK     ' || p_nombre);
      else
         l_fallas := l_fallas + 1;
         dbms_output.put_line('FALLA  ' || p_nombre || ' -> ' || p_detalle);
      end if;
   end control;

   function exis(p_id_articulo number, p_id_sucursal number default &id_sucursal) return number is
      l_q number;
   begin
      select nvl(sum(cant_dispon), 0) into l_q
        from stw_existencia_art
       where id_empresa = &id_empresa and id_sucursal = p_id_sucursal and id_articulo = p_id_articulo;
      return l_q;
   end exis;

   function prom(p_id_articulo number) return number is
      l_c number;
   begin
      select costo_prom into l_c from stw_articulos where id = p_id_articulo;
      return l_c;
   end prom;

   procedure espera_error(p_nombre varchar2, p_bloque varchar2) is
   begin
      execute immediate p_bloque;
      control(p_nombre, false, 'no dio error');
   exception
      when others then
         control(p_nombre, sqlcode between -20299 and -20100, sqlerrm);
   end espera_error;
begin
   savepoint sp_pruebas;

   -- 1-2. Compuesto con dos marcas, factor 25 kg por bolsa, en una sucursal
   insert into prw_compuestos_cabecera (id_empresa, id_producto) values (&id_empresa, &id_generico)
   returning id into l_id_comp;
   insert into prw_compuestos_detalle (id_empresa, id_compuesto, id_producto, factor_ub)
   values (&id_empresa, l_id_comp, &id_marca1, 25);
   insert into prw_compuestos_detalle (id_empresa, id_compuesto, id_producto, factor_ub)
   values (&id_empresa, l_id_comp, &id_marca2, 25);
   insert into prw_compuestos_sucursales (id_empresa, id_compuesto, id_sucursal)
   values (&id_empresa, l_id_comp, &id_sucursal);
   control('01 compuesto válido', prwk_produccion.errores_compuesto(l_id_comp) is null,
           prwk_produccion.errores_compuesto(l_id_comp));
   control('02 marca -> genérico', prwk_produccion.generico_de(&id_empresa, &id_marca1, &id_sucursal) = &id_generico);

   -- 3. Artículo sin compuesto
   control('03 artículo sin compuesto', prwk_produccion.es_marca(&id_empresa, &id_carne) = 'N');

   -- 4. Relación válida en una sucursal y no en otra
   control('04 sucursal no habilitada', prwk_produccion.generico_de(&id_empresa, &id_marca1, &id_sucursal2) is null);

   -- Duplicados: una marca no puede tener dos destinos
   espera_error('UK marca en dos compuestos',
      'insert into prw_compuestos_detalle (id_empresa, id_compuesto, id_producto, factor_ub) values ('
      || &id_empresa || ', ' || l_id_comp || ', ' || &id_marca1 || ', 10)');

   -- 10-11. 80 bolsas de 25 kg = 2.000 kg, con costo
   l_exis_antes := exis(&id_generico);
   l_prom_antes := prom(&id_generico);
   insert into prw_conversiones_cab (id_empresa, id_sucursal, tipo_costo, motivo)
   values (&id_empresa, &id_sucursal, 'C', 'Prueba bolsa a kilo') returning id into l_id_conv;
   insert into prw_conversiones_ing (id_conversion, id_empresa, nro_orden, id_articulo, id_unidad_medida, cantidad)
   select l_id_conv, &id_empresa, 1, a.id, a.id_unidad_medida, 80 from stw_articulos a where a.id = &id_marca1;
   insert into prw_conversion_res (id_conversion, id_empresa, nro_orden, id_articulo, id_unidad_medida, cantidad, articulo_principal)
   select l_id_conv, &id_empresa, 1, a.id, a.id_unidad_medida, 2000, 'S' from stw_articulos a where a.id = &id_generico;
   prwk_produccion.confirmar_conversion(l_id_conv);
   l_exis_desp := exis(&id_generico);
   control('11 entran 2.000 kg al genérico', abs(l_exis_desp - l_exis_antes - 2000) < 0.001,
           'delta ' || (l_exis_desp - l_exis_antes));
   select costo_total into l_valor from prw_conversiones_cab where id = l_id_conv;
   control('16 costo de la conversión = 80 x costo de la marca', abs(l_valor - round(80 * prom(&id_marca1), 3)) < 1,
           l_valor || ' vs ' || 80 * prom(&id_marca1));
   l_prom_desp := prom(&id_generico);
   control('08/09 promedio ponderado del genérico',
           abs(l_prom_desp - round(case when l_exis_antes > 0 and l_prom_antes > 0
                                        then (l_prom_antes * l_exis_antes + l_valor) / (l_exis_antes + 2000)
                                        else l_valor / 2000 end, 3)) < 0.01,
           l_prom_desp);

   -- 24. Doble confirmación
   espera_error('24 doble confirmación', 'begin prwk_produccion.confirmar_conversion(' || l_id_conv || '); end;');

   -- Documento confirmado protegido
   espera_error('documento confirmado no se edita',
      'update prw_conversiones_cab set motivo = ''x'' where id = ' || l_id_conv);

   -- 26. Anulación: el stock vuelve y el costo se restaura
   prwk_produccion.anular_conversion(l_id_conv, 'Prueba');
   control('26 anulación restaura existencia', abs(exis(&id_generico) - l_exis_antes) < 0.001);
   control('26 anulación restaura costo', nvl(prom(&id_generico), 0) = nvl(l_prom_antes, 0),
           prom(&id_generico) || ' vs ' || l_prom_antes);

   -- 18-19. Desposte sin costo: 50 kg de carne -> 40 kg carne + 10 kg sebo
   insert into prw_conversiones_cab (id_empresa, id_sucursal, tipo_costo, ind_desposte, motivo)
   values (&id_empresa, &id_sucursal, 'S', 'S', 'Prueba desposte') returning id into l_id_conv;
   insert into prw_conversiones_ing (id_conversion, id_empresa, nro_orden, id_articulo, id_unidad_medida, cantidad)
   select l_id_conv, &id_empresa, 1, a.id, a.id_unidad_medida, 50 from stw_articulos a where a.id = &id_carne;
   insert into prw_conversion_res (id_conversion, id_empresa, nro_orden, id_articulo, id_unidad_medida, cantidad, articulo_principal, costo_unitario_inf)
   select l_id_conv, &id_empresa, 1, a.id, a.id_unidad_medida, 40, 'S', null from stw_articulos a where a.id = &id_carne;
   insert into prw_conversion_res (id_conversion, id_empresa, nro_orden, id_articulo, id_unidad_medida, cantidad, articulo_principal, costo_unitario_inf)
   select l_id_conv, &id_empresa, 2, a.id, a.id_unidad_medida, 10, 'N', 1000 from stw_articulos a where a.id = &id_sebo;
   l_exis_antes := exis(&id_carne);
   prwk_produccion.confirmar_conversion(l_id_conv);
   control('19 carne: sale 50 y entran 40', abs(exis(&id_carne) - l_exis_antes + 10) < 0.001);
   select sum(costo_total) into l_valor from prw_conversion_res where id_conversion = l_id_conv;
   select costo_total into l_ub_gen from prw_conversiones_cab where id = l_id_conv;
   control('18 el valor se conserva', abs(l_valor - l_ub_gen) < 1, l_valor || ' vs ' || l_ub_gen);
   select costo_total into l_valor from prw_conversion_res where id_conversion = l_id_conv and articulo_principal = 'N';
   control('18 sebo al costo informado (10 x 1000)', l_valor = 10000, l_valor);

   -- 20-21. Transferencia entre sucursales del mismo artículo: no cambia el costo
   l_prom_antes := prom(&id_carne);
   insert into prw_transferencia_cab (id_empresa, id_sucursal, id_sucursal_ent, motivo)
   values (&id_empresa, &id_sucursal, &id_sucursal2, 'Prueba') returning id into l_id_trf;
   insert into prw_transferencia_det (id_transferencia, id_empresa, nro_orden, id_articulo, id_unidad_medida, cantidad)
   select l_id_trf, &id_empresa, 1, a.id, a.id_unidad_medida, 5 from stw_articulos a where a.id = &id_carne;
   l_exis_antes := exis(&id_carne, &id_sucursal2);
   prwk_produccion.confirmar_transferencia(l_id_trf);
   control('21 entran 5 en la otra sucursal', abs(exis(&id_carne, &id_sucursal2) - l_exis_antes - 5) < 0.001);
   control('21 el costo no cambia', prom(&id_carne) = l_prom_antes);

   -- 22. Stock insuficiente
   insert into prw_transferencia_cab (id_empresa, id_sucursal, id_sucursal_ent, motivo)
   values (&id_empresa, &id_sucursal, &id_sucursal2, 'Prueba sin stock') returning id into l_id_trf;
   insert into prw_transferencia_det (id_transferencia, id_empresa, nro_orden, id_articulo, id_unidad_medida, cantidad)
   select l_id_trf, &id_empresa, 1, a.id, a.id_unidad_medida, 999999999 from stw_articulos a where a.id = &id_carne;
   espera_error('22 stock insuficiente', 'begin prwk_produccion.confirmar_transferencia(' || l_id_trf || '); end;');

   -- 12-15. Producción: planificar, calcular insumos, desvío y confirmar
   l_id_prod := null;
   prwk_produccion.agregar_a_orden(&id_empresa, &id_sucursal, trunc(sysdate), &id_formula, 10, l_id_prod);
   update pdw_produccion_producido set cant_procesada = 10 where id_produccion_cab = l_id_prod;
   prwk_produccion.calcular_insumos_produccion(l_id_prod);
   control('12 insumos calculados', prwk_produccion.desvios_produccion(l_id_prod) is null,
           prwk_produccion.desvios_produccion(l_id_prod));
   -- Desvío: se consume 50% más del primer insumo
   update pdw_produccion_det set cantidad_real = cantidad * 1.5
    where id = (select min(id) from pdw_produccion_det where id_produccion_cab = l_id_prod);
   espera_error('15 desvío sin motivo bloquea', 'begin prwk_produccion.confirmar_produccion(' || l_id_prod || '); end;');
   prwk_produccion.confirmar_produccion(l_id_prod, 'S', 'Prueba de desvío');
   control('14 producción confirmada', prwk_produccion.estado_produccion(l_id_prod) = 'C');
   select count(*) into l_valor from stw_entsal_cab where id_produccion = l_id_prod and ser_referencia = 'CONF';
   control('trazabilidad: ajustes de la producción', l_valor >= 2, l_valor);
   espera_error('24 doble confirmación de producción',
      'begin prwk_produccion.confirmar_produccion(' || l_id_prod || ', ''S'', ''x''); end;');
   prwk_produccion.anular_produccion(l_id_prod, 'Prueba');
   control('26 producción anulada', prwk_produccion.estado_produccion(l_id_prod) = 'A');

   dbms_output.put_line('----');
   dbms_output.put_line(case when l_fallas = 0 then 'TODAS LAS PRUEBAS OK' else l_fallas || ' FALLA(S)' end);
   rollback to sp_pruebas;
exception
   when others then
      dbms_output.put_line('ERROR NO ESPERADO: ' || sqlerrm);
      dbms_output.put_line(dbms_utility.format_error_backtrace);
      rollback to sp_pruebas;
end;
/
rollback;
