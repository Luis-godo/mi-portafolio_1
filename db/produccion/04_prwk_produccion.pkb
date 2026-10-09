create or replace package body prwk_produccion
as
   -- ==================================================================
   -- Constantes y estado
   -- ==================================================================
   co_modulo            constant varchar2(2)  := 'PD';
   co_tip_entsal        constant varchar2(5)  := 'AJS';
   co_ref_conversion    constant varchar2(3)  := 'CNV';
   co_ref_transferencia constant varchar2(3)  := 'TRF';
   co_ref_produccion    constant varchar2(3)  := 'PRO';
   co_ser_confirma      constant varchar2(7)  := 'CONF';
   co_ser_anula         constant varchar2(7)  := 'ANUL';
   co_tolerancia_cant   constant number       := 0.0001;
   co_lote_defecto      constant varchar2(1)  := '0';

   e_recurso_ocupado exception;
   pragma exception_init(e_recurso_ocupado, -54);

   g_en_proceso boolean := false;
   -- Se cargan en INICIO_PROCESO: las sentencias SQL no pueden llamar a
   -- funciones privadas del paquete, pero sí usar variables
   g_usuario     varchar2(10);
   g_moneda_base number;

   -- Línea de un movimiento de stock
   type t_linea is record (
      id_articulo       stw_articulos.id%type,
      id_lote           stw_lotes.id%type,
      id_unidad_medida  stw_unidades_medida.id%type,
      cantidad          number,
      cantidad_ub       number,
      costo_unitario    number,           -- por unidad base
      id_ref_det        number,
      id_produccion_det number
   );
   type t_lineas is table of t_linea index by pls_integer;

   -- Acumulado por artículo para valorizar una sola vez por movimiento
   type t_acumulado is record (
      cantidad_ub  number := 0,
      costo_total  number := 0,
      id_lote      number
   );
   type t_acumulados is table of t_acumulado index by pls_integer;

   -- ==================================================================
   -- Utilidades
   -- ==================================================================
   function en_proceso return boolean is
   begin
      return g_en_proceso;
   end en_proceso;

   procedure error(p_codigo in pls_integer, p_mensaje in varchar2) is
   begin
      raise_application_error(p_codigo, substr(p_mensaje, 1, 2000));
   end error;

   function usuario return varchar2 is
   begin
      return substr(coalesce(sys_context('APEX$SESSION', 'APP_USER'), user), 1, 10);
   end usuario;

   function parametro(p_parametro in varchar2) return varchar2 is
      l_valor bsw_parametros_generales.valor%type;
   begin
      l_valor := w_busca_parametro(co_modulo, p_parametro);
      if l_valor is null then
         error(-20190, 'Falta el parámetro general ' || co_modulo || '.' || p_parametro
                       || '. Ejecute db/produccion/02_parametros_motivos_menu.sql.');
      end if;
      return l_valor;
   end parametro;

   function moneda_base return number is
   begin
      return to_number(w_busca_parametro('BS', 'ID_MONEDA_BASE'));
   end moneda_base;

   procedure inicio_proceso is
   begin
      g_en_proceso := true;
      g_usuario := usuario;
      g_moneda_base := moneda_base;
   end inicio_proceso;

   procedure fin_proceso is
   begin
      g_en_proceso := false;
   end fin_proceso;

   function articulo(p_id_articulo in number) return stw_articulos%rowtype is
      l_articulo stw_articulos%rowtype;
   begin
      select * into l_articulo from stw_articulos a where a.id = p_id_articulo;
      return l_articulo;
   exception
      when no_data_found then
         error(-20110, 'El artículo ' || p_id_articulo || ' no existe.');
   end articulo;

   function descripcion_articulo(p_id_articulo in number) return varchar2 is
      l_texto varchar2(400);
   begin
      select a.cod_articulo || ' - ' || a.descripcion
        into l_texto
        from stw_articulos a
       where a.id = p_id_articulo;
      return l_texto;
   exception
      when no_data_found then
         return to_char(p_id_articulo);
   end descripcion_articulo;

   function descripcion_sucursal(p_id_sucursal in number) return varchar2 is
      l_texto varchar2(200);
   begin
      select s.descripcion || ' (' || s.cod_sucursal || ')'
        into l_texto
        from bsw_sucursales s
       where s.id = p_id_sucursal;
      return l_texto;
   exception
      when no_data_found then
         return to_char(p_id_sucursal);
   end descripcion_sucursal;

   procedure validar_articulo(p_id_empresa in number, p_id_articulo in number, p_contexto in varchar2) is
      l_articulo stw_articulos%rowtype := articulo(p_id_articulo);
   begin
      if l_articulo.id_empresa != p_id_empresa then
         error(-20111, p_contexto || ': el artículo ' || descripcion_articulo(p_id_articulo)
                       || ' no pertenece a la empresa ' || p_id_empresa || '.');
      end if;
      if nvl(l_articulo.estado, 'N') != 'S' then
         error(-20112, p_contexto || ': el artículo ' || descripcion_articulo(p_id_articulo)
                       || ' está inactivo.');
      end if;
   end validar_articulo;

   procedure validar_sucursal(p_id_empresa in number, p_id_sucursal in number, p_contexto in varchar2) is
      l_id_empresa bsw_sucursales.id_empresa%type;
   begin
      if p_id_sucursal is null then
         error(-20113, p_contexto || ': falta la sucursal.');
      end if;
      select s.id_empresa into l_id_empresa from bsw_sucursales s where s.id = p_id_sucursal;
      if l_id_empresa != p_id_empresa then
         error(-20113, p_contexto || ': la sucursal ' || descripcion_sucursal(p_id_sucursal)
                       || ' no pertenece a la empresa ' || p_id_empresa || '.');
      end if;
   exception
      when no_data_found then
         error(-20113, p_contexto || ': la sucursal ' || p_id_sucursal || ' no existe.');
   end validar_sucursal;

   function a_unidad_base(p_id_articulo      in number,
                          p_id_unidad_medida in number,
                          p_cantidad         in number)
      return number
   is
      l_cantidad_ub number;
      l_factores    pls_integer;
   begin
      if p_cantidad is null then
         return null;
      end if;
      -- STW_PKG.TRAE_MULT_UB devuelve la cantidad sin convertir si el
      -- artículo no tiene esa unidad (o la tiene repetida): 80 bolsas
      -- pasarían como 80 kg. Se valida la relación antes de usarla.
      select count(distinct rd.mult / nullif(rd.divisor, 0))
        into l_factores
        from stw_articulos ar
        join stw_relaciones_cab rc on rc.id = ar.id_relacion_um
        join stw_relaciones rd on rd.id_unidad_rel = rc.id
       where ar.id = p_id_articulo
         and rd.id_relacion_um = p_id_unidad_medida;
      if l_factores = 0 then
         error(-20114, 'El artículo ' || descripcion_articulo(p_id_articulo)
                       || ' no tiene la unidad de medida ' || p_id_unidad_medida
                       || ' en su relación de unidades. Elija una unidad del artículo o complete la relación.');
      elsif l_factores > 1 then
         error(-20114, 'La relación de unidades del artículo ' || descripcion_articulo(p_id_articulo)
                       || ' tiene la unidad ' || p_id_unidad_medida || ' repetida con factores distintos.');
      end if;
      -- Misma conversión que usa STWT_ENTSAL_DET_PROCESA_STOCK
      l_cantidad_ub := stw_pkg.trae_mult_ub(p_id_articulo      => p_id_articulo,
                                            p_id_unidad_medida => p_id_unidad_medida,
                                            p_cantidad         => p_cantidad);
      if l_cantidad_ub is null or l_cantidad_ub <= 0 then
         error(-20114, 'No hay equivalencia a la unidad base para el artículo '
                       || descripcion_articulo(p_id_articulo) || ' en la unidad ' || p_id_unidad_medida
                       || '. Revise la relación de unidades del artículo.');
      end if;
      return l_cantidad_ub;
   end a_unidad_base;

   function lote_defecto(p_id_empresa in number, p_id_articulo in number) return number is
      l_id_lote stw_lotes.id%type;
   begin
      select min(l.id)
        into l_id_lote
        from stw_lotes l
       where l.id_empresa = p_id_empresa
         and l.id_articulo = p_id_articulo
         and l.nro_lote = co_lote_defecto;
      if l_id_lote is null then
         error(-20115, 'El artículo ' || descripcion_articulo(p_id_articulo)
                       || ' no tiene lote ' || co_lote_defecto || '. Créelo desde la ficha del artículo.');
      end if;
      return l_id_lote;
   end lote_defecto;

   -- Lote informado, o el lote '0' si el artículo no maneja lotes
   function lote_de_linea(p_id_empresa  in number,
                          p_id_articulo in number,
                          p_id_lote     in number,
                          p_contexto    in varchar2)
      return number
   is
      l_articulo stw_articulos%rowtype := articulo(p_id_articulo);
      l_id_articulo_lote stw_lotes.id_articulo%type;
   begin
      if p_id_lote is not null then
         select l.id_articulo into l_id_articulo_lote from stw_lotes l where l.id = p_id_lote;
         if l_id_articulo_lote != p_id_articulo then
            error(-20116, p_contexto || ': el lote ' || p_id_lote || ' no corresponde al artículo '
                          || descripcion_articulo(p_id_articulo) || '.');
         end if;
         return p_id_lote;
      end if;
      if nvl(l_articulo.ind_maneja_lote, 'N') = 'S' then
         error(-20116, p_contexto || ': el artículo ' || descripcion_articulo(p_id_articulo)
                       || ' maneja lotes. Indique el lote.');
      end if;
      return lote_defecto(p_id_empresa, p_id_articulo);
   exception
      when no_data_found then
         error(-20116, p_contexto || ': el lote ' || p_id_lote || ' no existe.');
   end lote_de_linea;

   -- Lote por número; lo crea con su vencimiento si no existe
   function obtener_lote(p_id_empresa      in number,
                         p_id_articulo     in number,
                         p_nro_lote        in varchar2,
                         p_fec_vencimiento in date)
      return number
   is
      l_id_lote stw_lotes.id%type;
      l_id_um   stw_articulos.id_unidad_medida%type;
   begin
      if p_nro_lote is null then
         return lote_de_linea(p_id_empresa, p_id_articulo, null, 'Resultado');
      end if;
      select min(l.id)
        into l_id_lote
        from stw_lotes l
       where l.id_empresa = p_id_empresa
         and l.id_articulo = p_id_articulo
         and l.nro_lote = p_nro_lote;
      if l_id_lote is null then
         l_id_um := articulo(p_id_articulo).id_unidad_medida;
         insert into stw_lotes (id_empresa, id_articulo, nro_lote, fec_vencimiento, id_unidad_medida)
         values (p_id_empresa, p_id_articulo, p_nro_lote, p_fec_vencimiento, l_id_um)
         returning id into l_id_lote;
      end if;
      return l_id_lote;
   end obtener_lote;

   function existencia(p_id_empresa  in number,
                       p_id_sucursal in number,
                       p_id_articulo in number,
                       p_id_lote     in number)
      return number
   is
      l_cantidad number;
   begin
      select nvl(sum(e.cant_dispon), 0)
        into l_cantidad
        from stw_existencia_art e
       where e.id_empresa = p_id_empresa
         and e.id_sucursal = p_id_sucursal
         and e.id_articulo = p_id_articulo
         and e.id_lote = p_id_lote;
      return l_cantidad;
   end existencia;

   -- Existencia de la empresa en las sucursales que manejan stock: la
   -- misma base que usa la confirmación de compras para el promedio
   function existencia_total(p_id_empresa in number, p_id_articulo in number) return number is
      l_cantidad number;
   begin
      select nvl(sum(e.cant_dispon), 0)
        into l_cantidad
        from stw_existencia_art e
        join bsw_sucursales s
          on s.id = e.id_sucursal
         and s.id_empresa = e.id_empresa
       where e.id_empresa = p_id_empresa
         and e.id_articulo = p_id_articulo
         and nvl(s.maneja_stock, 'S') = 'S';
      return greatest(l_cantidad, 0);
   end existencia_total;

   function costo_promedio(p_id_articulo in number) return number is
      l_costo stw_articulos.costo_prom%type;
   begin
      select nvl(a.costo_prom, 0) into l_costo from stw_articulos a where a.id = p_id_articulo;
      return l_costo;
   end costo_promedio;

   -- Costo unitario (unidad base) de una línea de compra, sin IVA y con
   -- gastos, como lo toma la confirmación de compras. Nulo si la compra
   -- no está en la moneda base.
   function costo_linea_compra(p_id_compra_det in number) return number is
      l_costo number;
   begin
      select (nvl(d.monto_total, 0) + nvl(d.monto_gastos, 0)) / nullif(d.cantidad_ub, 0)
        into l_costo
        from cmw_compras_detalle d
        join cmw_compras_cabecera c on c.id = d.id_compras_cab
       where d.id = p_id_compra_det
         and c.id_moneda = g_moneda_base;
      return l_costo;
   exception
      when no_data_found then
         return null;
   end costo_linea_compra;

   function motivo(p_id_empresa in number, p_parametro in varchar2, p_ind_ent_sal in varchar2)
      return number
   is
      l_id   stw_motivo_ent_sal.id%type;
      l_ind  stw_motivo_ent_sal.ind_ent_sal%type;
      l_cod  stw_motivo_ent_sal.cod_motivo_ent_sal%type := parametro(p_parametro);
   begin
      select m.id, m.ind_ent_sal
        into l_id, l_ind
        from stw_motivo_ent_sal m
       where m.id_empresa = p_id_empresa
         and m.cod_motivo_ent_sal = l_cod;
      if l_ind != p_ind_ent_sal then
         error(-20191, 'El motivo de entrada/salida ' || l_cod || ' (' || p_parametro
                       || ') es de tipo ' || l_ind || ' y se esperaba ' || p_ind_ent_sal || '.');
      end if;
      return l_id;
   exception
      when no_data_found then
         error(-20191, 'No existe el motivo de entrada/salida ' || l_cod || ' en la empresa '
                       || p_id_empresa || ' (parámetro ' || p_parametro || ').');
   end motivo;

   -- ==================================================================
   -- Movimiento de stock por el mecanismo oficial
   --
   -- Genera un ajuste STW_ENTSAL_CAB/DET. El trigger del detalle mueve
   -- la existencia por STWK_EXISTENCIA. El signo depende de reglas
   -- internas de STWK_EXISTENCIA que no son legibles desde este
   -- esquema, así que cada línea se verifica: la existencia del lote
   -- tiene que cambiar exactamente la cantidad esperada.
   -- ==================================================================
   function mover_stock(p_id_empresa    in number,
                        p_id_sucursal   in number,
                        p_ind_ent_sal   in varchar2,
                        p_par_motivo    in varchar2,
                        p_tip_ref       in varchar2,
                        p_ser_ref       in varchar2,
                        p_id_ref        in number,
                        p_nro_ref       in number,
                        p_comentario    in varchar2,
                        p_lineas        in t_lineas,
                        p_id_produccion in number default null)
      return number
   is
      l_id_cab        stw_entsal_cab.id%type;
      l_id_motivo     stw_motivo_ent_sal.id%type := motivo(p_id_empresa, p_par_motivo, p_ind_ent_sal);
      l_signo         pls_integer := case p_ind_ent_sal when 'E' then 1 else -1 end;
      l_permite_neg   varchar2(1) := parametro('PRW_PERMITE_NEGATIVO');
      l_articulo      stw_articulos%rowtype;
      l_antes         number;
      l_despues       number;
      l_tot_costo     number := 0;
      l_tot_cantidad  number := 0;
      l_hay_lineas    boolean := false;
      l_nro_lote      stw_lotes.nro_lote%type;
      l_fec_venc      stw_lotes.fec_vencimiento%type;
      l_serie         stw_entsal_cab.ser_ent_sal%type := parametro('PRW_SERIE_ENTSAL');
      l_tipos_ajs     pls_integer;
   begin
      -- STWK_EXISTENCIA busca el tipo de comprobante AJS de la empresa y
      -- falla con NO_DATA_FOUND si no existe
      select count(*)
        into l_tipos_ajs
        from bsw_tipos_comprobantes t
       where t.tip_comprobante = co_tip_entsal
         and t.id_empresa = p_id_empresa;
      if l_tipos_ajs = 0 then
         error(-20193, 'La empresa ' || p_id_empresa || ' no tiene el tipo de comprobante ' || co_tip_entsal
                       || ': créelo en tipos de comprobantes antes de mover stock con el módulo.');
      end if;

      for i in 1 .. p_lineas.count loop
         l_tot_costo := l_tot_costo + nvl(p_lineas(i).cantidad_ub * p_lineas(i).costo_unitario, 0);
         l_tot_cantidad := l_tot_cantidad + p_lineas(i).cantidad_ub;
      end loop;

      l_id_cab := stw_entsal_cab_id_seq.nextval;
      insert into stw_entsal_cab (id, id_empresa, id_sucursal, num_ent_sal, fec_ent_sal,
                                  id_motivo_ent_sal, id_moneda, fec_inicio, comentario,
                                  cod_usuario_aud, ind_actualiza_costo, tip_referencia,
                                  ser_referencia, num_referencia, id_referencia, estado,
                                  fecha_estado, ser_ent_sal, tip_ent_sal, id_produccion,
                                  tot_costo, tot_cantidad)
      values (l_id_cab, p_id_empresa, p_id_sucursal, prw_entsal_nro_seq.nextval, trunc(sysdate),
              l_id_motivo, g_moneda_base, sysdate, substr(p_comentario, 1, 150),
              g_usuario, 'N', p_tip_ref,
              p_ser_ref, p_nro_ref, p_id_ref, 'C',
              sysdate, l_serie, co_tip_entsal, p_id_produccion,
              round(l_tot_costo, 3), l_tot_cantidad);

      for i in 1 .. p_lineas.count loop
         l_articulo := articulo(p_lineas(i).id_articulo);
         -- Los artículos que no manejan stock (servicios, mano de obra)
         -- suman costo pero no se mueven
         if nvl(l_articulo.ind_maneja_stock, 'N') = 'S' then
            l_hay_lineas := true;
            if l_articulo.id_iva is null then
               error(-20117, 'El artículo ' || descripcion_articulo(p_lineas(i).id_articulo)
                             || ' no tiene IVA asignado: complételo en la ficha del artículo.');
            end if;

            -- Bloqueo de las filas de existencia: serializa con otros
            -- movimientos del mismo lote mientras se verifica
            for r in (select e.id
                        from stw_existencia_art e
                       where e.id_empresa = p_id_empresa
                         and e.id_sucursal = p_id_sucursal
                         and e.id_articulo = p_lineas(i).id_articulo
                         and e.id_lote = p_lineas(i).id_lote
                         for update)
            loop
               null;
            end loop;

            l_antes := existencia(p_id_empresa, p_id_sucursal, p_lineas(i).id_articulo, p_lineas(i).id_lote);

            if l_signo < 0 and l_permite_neg = 'N'
               and l_antes - p_lineas(i).cantidad_ub < -co_tolerancia_cant
            then
               error(-20150, 'Stock insuficiente de ' || descripcion_articulo(p_lineas(i).id_articulo)
                             || ' en ' || descripcion_sucursal(p_id_sucursal) || ', lote '
                             || p_lineas(i).id_lote || ': disponible ' || l_antes
                             || ', requerido ' || p_lineas(i).cantidad_ub || '.');
            end if;

            select l.nro_lote, l.fec_vencimiento
              into l_nro_lote, l_fec_venc
              from stw_lotes l
             where l.id = p_lineas(i).id_lote;

            insert into stw_entsal_det (id, id_empresa, id_sucursal, id_entsal_cab, id_articulo,
                                        costo, cantidad, cantidad_ub, id_unidad_medida, nro_lote,
                                        fec_venc, id_lote, id_ref_det, precio, estado, costo_c_iva,
                                        nro_orden, desc_articulo, id_iva, total_costo,
                                        cantidad_confirmada, id_produccion_det, observacion,
                                        cod_usuario_aud)
            values (stw_entsal_det_id_seq.nextval, p_id_empresa, p_id_sucursal, l_id_cab,
                    p_lineas(i).id_articulo, round(p_lineas(i).costo_unitario, 6),
                    p_lineas(i).cantidad, p_lineas(i).cantidad_ub, p_lineas(i).id_unidad_medida,
                    l_nro_lote, l_fec_venc, p_lineas(i).id_lote, p_lineas(i).id_ref_det,
                    round(p_lineas(i).costo_unitario, 6), 'C', round(nvl(p_lineas(i).costo_unitario, 0), 6),
                    i, substr(l_articulo.descripcion, 1, 3000), l_articulo.id_iva,
                    round(p_lineas(i).cantidad_ub * p_lineas(i).costo_unitario, 3),
                    p_lineas(i).cantidad, p_lineas(i).id_produccion_det,
                    substr(p_comentario, 1, 200), g_usuario);

            l_despues := existencia(p_id_empresa, p_id_sucursal, p_lineas(i).id_articulo, p_lineas(i).id_lote);

            if abs((l_despues - l_antes) - l_signo * p_lineas(i).cantidad_ub) > co_tolerancia_cant then
               error(-20192, 'El mecanismo de stock no registró el movimiento esperado para '
                             || descripcion_articulo(p_lineas(i).id_articulo) || ' en '
                             || descripcion_sucursal(p_id_sucursal) || ': se esperaba '
                             || l_signo * p_lineas(i).cantidad_ub || ' y la existencia cambió '
                             || (l_despues - l_antes) || '. No se registró ningún movimiento.');
            end if;
         end if;
      end loop;

      if not l_hay_lineas then
         -- Nada que mover: no se deja una cabecera vacía
         delete from stw_entsal_cab where id = l_id_cab;
         return null;
      end if;
      return l_id_cab;
   end mover_stock;

   -- ==================================================================
   -- Valorización
   -- ==================================================================
   -- Costo promedio ponderado tras una entrada valorizada. Se llama
   -- después de mover el stock: la existencia previa es la actual menos
   -- lo que entró.
   procedure valorizar_entrada(p_id_empresa    in number,
                               p_id_articulo   in number,
                               p_cantidad_ub   in number,
                               p_costo_total   in number,
                               p_id_entsal_cab in number,
                               p_tip_ref       in varchar2,
                               p_id_ref        in number,
                               p_id_lote       in number,
                               p_fecha         in date)
   is
      l_articulo     stw_articulos%rowtype;
      l_exis_previa  number;
      l_nuevo_prom   number;
      l_nuevo_ult    number;
   begin
      if nvl(p_cantidad_ub, 0) <= 0 then
         return;
      end if;

      select * into l_articulo from stw_articulos a where a.id = p_id_articulo for update;

      l_exis_previa := existencia_total(p_id_empresa, p_id_articulo);
      if nvl(l_articulo.ind_maneja_stock, 'N') = 'S' then
         l_exis_previa := greatest(l_exis_previa - p_cantidad_ub, 0);
      end if;

      l_nuevo_ult := round(nvl(p_costo_total, 0) / p_cantidad_ub, 3);
      if l_exis_previa > 0 and nvl(l_articulo.costo_prom, 0) > 0 then
         l_nuevo_prom := round((l_articulo.costo_prom * l_exis_previa + nvl(p_costo_total, 0))
                               / (l_exis_previa + p_cantidad_ub), 3);
      else
         l_nuevo_prom := l_nuevo_ult;
      end if;

      update stw_articulos a
         set a.costo_prom_anterior   = a.costo_prom,
             a.costo_ultimo_anterior = a.costo_ultimo,
             a.costo_prom            = l_nuevo_prom,
             a.costo_ultimo          = l_nuevo_ult,
             a.costo_prom_gs         = case when a.id_moneda_costo = g_moneda_base then l_nuevo_prom else a.costo_prom_gs end,
             a.costo_ultimo_gs       = case when a.id_moneda_costo = g_moneda_base then l_nuevo_ult else a.costo_ultimo_gs end
       where a.id = p_id_articulo;

      insert into stw_hist_costos_art (id, id_empresa, id_articulo, costo_prom_actual,
                                       cant_exist_total, costo_movim, cant_movim,
                                       costo_prom_nuevo, costo_prom_ant_h, costo_ultimo_h,
                                       costo_ultimo, id_moneda_costo, fec_proceso,
                                       cod_usuario_aud, id_entsal_cab, tip_comprobante,
                                       id_comprobante, id_lote, fec_comprobante)
      values (stw_hist_cost_art_id_seq.nextval, p_id_empresa, p_id_articulo, l_articulo.costo_prom,
              l_exis_previa, l_nuevo_ult, p_cantidad_ub,
              l_nuevo_prom, l_articulo.costo_prom, l_articulo.costo_ultimo,
              l_nuevo_ult, l_articulo.id_moneda_costo, sysdate,
              g_usuario, p_id_entsal_cab, p_tip_ref,
              p_id_ref, p_id_lote, p_fecha);
   end valorizar_entrada;

   -- Deshace la valorización de un ajuste. Solo si ningún movimiento
   -- posterior cambió el costo del artículo: si lo hubo, recalcular
   -- hacia atrás daría un costo inventado.
   procedure revertir_costo(p_id_entsal_cab in number, p_id_entsal_anulacion in number) is
      l_posterior varchar2(400);
   begin
      if p_id_entsal_cab is null then
         return;
      end if;
      for h in (select h.*
                  from stw_hist_costos_art h
                 where h.id_entsal_cab = p_id_entsal_cab
                 order by h.id)
      loop
         select max(nvl(p.tip_comprobante, 'COMPRA') || ' ' || nvl(to_char(p.id_comprobante), to_char(p.id_comprobante_compra))
                    || ' del ' || to_char(p.fec_proceso, 'dd/mm/yyyy'))
           into l_posterior
           from stw_hist_costos_art p
          where p.id_empresa = h.id_empresa
            and p.id_articulo = h.id_articulo
            and p.id > h.id;
         if l_posterior is not null then
            error(-20160, 'No se puede anular: el costo de ' || descripcion_articulo(h.id_articulo)
                          || ' cambió después por otro movimiento (' || l_posterior
                          || '). Anule primero los movimientos posteriores o ajuste el costo desde contabilidad.');
         end if;

         update stw_articulos a
            set a.costo_prom      = h.costo_prom_ant_h,
                a.costo_ultimo    = h.costo_ultimo_h,
                a.costo_prom_gs   = case when a.id_moneda_costo = g_moneda_base then h.costo_prom_ant_h else a.costo_prom_gs end,
                a.costo_ultimo_gs = case when a.id_moneda_costo = g_moneda_base then h.costo_ultimo_h else a.costo_ultimo_gs end
          where a.id = h.id_articulo;

         -- Registro de la reversión, para que el historial cuente lo que pasó
         insert into stw_hist_costos_art (id, id_empresa, id_articulo, costo_prom_actual,
                                          cant_movim, costo_movim, costo_prom_nuevo,
                                          costo_prom_ant_h, costo_ultimo_h, costo_ultimo,
                                          id_moneda_costo, fec_proceso, cod_usuario_aud,
                                          id_entsal_cab, tip_comprobante, id_comprobante,
                                          id_lote, fec_comprobante)
         values (stw_hist_cost_art_id_seq.nextval, h.id_empresa, h.id_articulo, h.costo_prom_nuevo,
                 -h.cant_movim, h.costo_movim, h.costo_prom_ant_h,
                 h.costo_prom_nuevo, h.costo_ultimo, h.costo_ultimo_h,
                 h.id_moneda_costo, sysdate, g_usuario,
                 p_id_entsal_anulacion, h.tip_comprobante, h.id_comprobante,
                 h.id_lote, trunc(sysdate));
      end loop;
   end revertir_costo;

   procedure acumular(p_acumulados  in out nocopy t_acumulados,
                      p_id_articulo in number,
                      p_cantidad_ub in number,
                      p_costo_total in number,
                      p_id_lote     in number)
   is
   begin
      if not p_acumulados.exists(p_id_articulo) then
         p_acumulados(p_id_articulo).cantidad_ub := 0;
         p_acumulados(p_id_articulo).costo_total := 0;
         p_acumulados(p_id_articulo).id_lote := p_id_lote;
      end if;
      p_acumulados(p_id_articulo).cantidad_ub := p_acumulados(p_id_articulo).cantidad_ub + nvl(p_cantidad_ub, 0);
      p_acumulados(p_id_articulo).costo_total := p_acumulados(p_id_articulo).costo_total + nvl(p_costo_total, 0);
   end acumular;

   procedure valorizar_acumulados(p_id_empresa    in number,
                                  p_acumulados    in t_acumulados,
                                  p_id_entsal_cab in number,
                                  p_tip_ref       in varchar2,
                                  p_id_ref        in number,
                                  p_fecha         in date)
   is
      l_id pls_integer := p_acumulados.first;
   begin
      while l_id is not null loop
         valorizar_entrada(p_id_empresa    => p_id_empresa,
                           p_id_articulo   => l_id,
                           p_cantidad_ub   => p_acumulados(l_id).cantidad_ub,
                           p_costo_total   => p_acumulados(l_id).costo_total,
                           p_id_entsal_cab => p_id_entsal_cab,
                           p_tip_ref       => p_tip_ref,
                           p_id_ref        => p_id_ref,
                           p_id_lote       => p_acumulados(l_id).id_lote,
                           p_fecha         => p_fecha);
         l_id := p_acumulados.next(l_id);
      end loop;
   end valorizar_acumulados;

   -- Ajustes generados por un documento, por tipo de movimiento
   function entsal_de(p_tip_ref in varchar2, p_id_ref in number, p_ser_ref in varchar2, p_ind_ent_sal in varchar2)
      return sys.odcinumberlist
   is
      l_ids sys.odcinumberlist;
   begin
      select c.id
        bulk collect into l_ids
        from stw_entsal_cab c
        join stw_motivo_ent_sal m on m.id = c.id_motivo_ent_sal
       where c.tip_referencia = p_tip_ref
         and c.id_referencia = p_id_ref
         and c.ser_referencia = p_ser_ref
         and m.ind_ent_sal = p_ind_ent_sal
       order by c.id;
      return l_ids;
   end entsal_de;


   -- ==================================================================
   -- Compuestos
   -- ==================================================================
   function generico_de(p_id_empresa  in number,
                        p_id_marca    in number,
                        p_id_sucursal in number)
      return number
   is
      l_id_generico prw_compuestos_cabecera.id_producto%type;
   begin
      select max(c.id_producto)
        into l_id_generico
        from prw_compuestos_detalle d
        join prw_compuestos_cabecera c on c.id = d.id_compuesto
       where d.id_empresa = p_id_empresa
         and d.id_producto = p_id_marca
         and d.estado = 'A'
         and c.estado = 'A'
         and (p_id_sucursal is null
              or exists (select null
                           from prw_compuestos_sucursales s
                          where s.id_compuesto = c.id
                            and s.id_sucursal = p_id_sucursal));
      return l_id_generico;
   end generico_de;

   function factor_marca(p_id_empresa in number, p_id_marca in number) return number is
      l_factor prw_compuestos_detalle.factor_ub%type;
   begin
      select max(d.factor_ub)
        into l_factor
        from prw_compuestos_detalle d
       where d.id_empresa = p_id_empresa
         and d.id_producto = p_id_marca
         and d.estado = 'A';
      return l_factor;
   end factor_marca;

   function es_marca(p_id_empresa in number, p_id_articulo in number) return varchar2 is
      l_cuenta pls_integer;
   begin
      select count(*)
        into l_cuenta
        from prw_compuestos_detalle d
        join prw_compuestos_cabecera c on c.id = d.id_compuesto
       where d.id_empresa = p_id_empresa
         and d.id_producto = p_id_articulo
         and d.estado = 'A'
         and c.estado = 'A';
      return case when l_cuenta > 0 then 'S' else 'N' end;
   end es_marca;

   function errores_compuesto(p_id_compuesto in number) return varchar2 is
      l_cab      prw_compuestos_cabecera%rowtype;
      l_errores  varchar2(4000);
      l_cuenta   pls_integer;

      procedure agregar(p_texto in varchar2) is
      begin
         l_errores := substr(l_errores || case when l_errores is not null then chr(10) end || p_texto, 1, 4000);
      end agregar;
   begin
      select * into l_cab from prw_compuestos_cabecera c where c.id = p_id_compuesto;

      begin
         validar_articulo(l_cab.id_empresa, l_cab.id_producto, 'Genérico');
      exception
         when others then
            agregar(regexp_replace(sqlerrm, '^ORA-[0-9]+: '));
      end;

      -- El genérico no puede ser a su vez marca de otro compuesto
      select count(*)
        into l_cuenta
        from prw_compuestos_detalle d
       where d.id_empresa = l_cab.id_empresa
         and d.id_producto = l_cab.id_producto;
      if l_cuenta > 0 then
         agregar('El genérico ' || descripcion_articulo(l_cab.id_producto)
                 || ' figura como marca de otro compuesto: la relación sería circular.');
      end if;

      select count(*)
        into l_cuenta
        from prw_compuestos_detalle d
       where d.id_compuesto = p_id_compuesto
         and d.estado = 'A';
      if l_cuenta = 0 then
         agregar('El compuesto no tiene marcas activas.');
      end if;

      for d in (select d.*
                  from prw_compuestos_detalle d
                 where d.id_compuesto = p_id_compuesto)
      loop
         if d.id_producto = l_cab.id_producto then
            agregar('La marca ' || descripcion_articulo(d.id_producto) || ' es el mismo genérico.');
         end if;
         begin
            validar_articulo(l_cab.id_empresa, d.id_producto, 'Marca');
         exception
            when others then
               agregar(regexp_replace(sqlerrm, '^ORA-[0-9]+: '));
         end;
         select count(*)
           into l_cuenta
           from prw_compuestos_cabecera c
          where c.id_empresa = l_cab.id_empresa
            and c.id_producto = d.id_producto;
         if l_cuenta > 0 then
            agregar('La marca ' || descripcion_articulo(d.id_producto)
                    || ' es genérico de otro compuesto: la relación sería circular.');
         end if;
      end loop;

      select count(*)
        into l_cuenta
        from prw_compuestos_sucursales s
       where s.id_compuesto = p_id_compuesto;
      if l_cuenta = 0 then
         agregar('Habilite al menos una sucursal.');
      end if;

      return l_errores;
   exception
      when no_data_found then
         return 'El compuesto ' || p_id_compuesto || ' no existe.';
   end errores_compuesto;

   -- ==================================================================
   -- Conversiones
   -- ==================================================================
   function bloquear_conversion(p_id in number) return prw_conversiones_cab%rowtype is
      l_cab prw_conversiones_cab%rowtype;
   begin
      select * into l_cab from prw_conversiones_cab c where c.id = p_id for update nowait;
      return l_cab;
   exception
      when no_data_found then
         error(-20101, 'La conversión ' || p_id || ' no existe.');
      when e_recurso_ocupado then
         error(-20102, 'La conversión está siendo procesada por otro usuario. Intente nuevamente.');
   end bloquear_conversion;

   procedure calcular_conversion_int(p_cab in prw_conversiones_cab%rowtype) is
      l_contexto       varchar2(200);
      l_costo_unit     number;
      l_costo_insumos  number := 0;
      l_gastos         number;
      l_total          number;
      l_cant_ing       pls_integer := 0;
      l_cant_res       pls_integer := 0;
      l_con_porc       pls_integer := 0;
      l_suma_porc      number := 0;
      l_suma_ub        number := 0;
      l_principales    pls_integer := 0;
      l_asignado       number := 0;
      l_id_ajuste      prw_conversion_res.id%type;
      l_ub             number;
      l_costo          number;
      l_id_lote        stw_lotes.id%type;
   begin
      validar_sucursal(p_cab.id_empresa, p_cab.id_sucursal, 'Conversión');

      for i in (select * from prw_conversiones_ing where id_conversion = p_cab.id order by nro_orden, id) loop
         l_cant_ing := l_cant_ing + 1;
         l_contexto := 'Insumo ' || l_cant_ing;
         validar_articulo(p_cab.id_empresa, i.id_articulo, l_contexto);
         l_ub := a_unidad_base(i.id_articulo, i.id_unidad_medida, i.cantidad);
         l_costo_unit := case when i.id_compra_det is not null then costo_linea_compra(i.id_compra_det) end;
         l_costo_unit := nvl(l_costo_unit, costo_promedio(i.id_articulo));
         l_id_lote := lote_de_linea(p_cab.id_empresa, i.id_articulo, i.id_lote, l_contexto);
         update prw_conversiones_ing x
            set x.cantidad_ub    = l_ub,
                x.id_lote        = l_id_lote,
                x.costo_unitario = round(l_costo_unit, 6),
                x.costo_total    = round(l_ub * l_costo_unit, 3)
          where x.id = i.id;
         l_costo_insumos := l_costo_insumos + round(l_ub * l_costo_unit, 3);
      end loop;

      if l_cant_ing = 0 then
         error(-20120, 'La conversión no tiene insumos.');
      end if;

      l_gastos := nvl(p_cab.total_gastos_adm, 0) + round(l_costo_insumos * nvl(p_cab.porc_gastos_adm, 0) / 100, 3);
      l_total := l_costo_insumos + l_gastos;

      for r in (select * from prw_conversion_res where id_conversion = p_cab.id order by nro_orden, id) loop
         l_cant_res := l_cant_res + 1;
         l_contexto := 'Resultado ' || l_cant_res;
         validar_articulo(p_cab.id_empresa, r.id_articulo, l_contexto);
         l_ub := a_unidad_base(r.id_articulo, r.id_unidad_medida, r.cantidad);
         update prw_conversion_res x set x.cantidad_ub = l_ub where x.id = r.id;
         l_suma_ub := l_suma_ub + l_ub;
         if r.porc_costo is not null then
            l_con_porc := l_con_porc + 1;
            l_suma_porc := l_suma_porc + r.porc_costo;
         end if;
         if r.articulo_principal = 'S' then
            l_principales := l_principales + 1;
            l_id_ajuste := r.id;
         end if;
      end loop;

      if l_cant_res = 0 then
         error(-20121, 'La conversión no tiene resultados.');
      end if;
      if l_principales > 1 then
         error(-20122, 'Marque un solo resultado como principal.');
      end if;

      if p_cab.tipo_costo = 'C' then
         -- Con costo: por porcentaje si se informa en todos, si no por cantidad
         if l_con_porc > 0 and l_con_porc < l_cant_res then
            error(-20123, 'Informe el porcentaje de costo en todos los resultados o en ninguno.');
         end if;
         if l_con_porc = l_cant_res and abs(l_suma_porc - 100) > 0.01 then
            error(-20124, 'Los porcentajes de costo suman ' || l_suma_porc || '%: deben sumar 100%.');
         end if;
         for r in (select * from prw_conversion_res where id_conversion = p_cab.id order by cantidad_ub desc, id) loop
            if l_id_ajuste is null then
               l_id_ajuste := r.id;   -- el de mayor cantidad absorbe el redondeo
            end if;
            l_costo := round(case when l_con_porc = l_cant_res then l_total * r.porc_costo / 100
                                  else l_total * r.cantidad_ub / l_suma_ub end, 3);
            update prw_conversion_res x set x.costo_total = l_costo where x.id = r.id;
            l_asignado := l_asignado + l_costo;
         end loop;
      else
         -- Sin traslado automático: los subproductos se valúan al costo
         -- informado (o su promedio actual) y el principal recibe el resto
         if l_principales = 0 then
            error(-20125, 'En una conversión sin costo marque el resultado principal: es el que recibe '
                          || 'el valor de los insumos que no se asigna a los subproductos.');
         end if;
         for r in (select * from prw_conversion_res where id_conversion = p_cab.id and articulo_principal = 'N') loop
            l_costo := round(r.cantidad_ub * nvl(r.costo_unitario_inf, costo_promedio(r.id_articulo)), 3);
            update prw_conversion_res x set x.costo_total = l_costo where x.id = r.id;
            l_asignado := l_asignado + l_costo;
         end loop;
         if l_total - l_asignado < 0 then
            error(-20126, 'El valor asignado a los subproductos (' || l_asignado
                          || ') supera el valor de los insumos (' || l_total || ').');
         end if;
         update prw_conversion_res x set x.costo_total = 0 where x.id = l_id_ajuste;
      end if;

      -- Diferencia de redondeo al principal o al de mayor cantidad
      update prw_conversion_res x
         set x.costo_total = x.costo_total + (l_total - l_asignado)
       where x.id = l_id_ajuste;

      update prw_conversion_res x
         set x.costo_unitario = round(x.costo_total / x.cantidad_ub, 6)
       where x.id_conversion = p_cab.id;

      update prw_conversiones_cab c
         set c.costo_insumos = l_costo_insumos,
             c.costo_total   = l_total
       where c.id = p_cab.id;
   end calcular_conversion_int;

   procedure calcular_conversion(p_id_conversion in number) is
      l_cab prw_conversiones_cab%rowtype;
   begin
      inicio_proceso;
      l_cab := bloquear_conversion(p_id_conversion);
      if l_cab.estado != 'P' then
         error(-20103, 'Solo se recalculan conversiones pendientes.');
      end if;
      calcular_conversion_int(l_cab);
      fin_proceso;
   exception
      when others then
         fin_proceso;
         raise;
   end calcular_conversion;

   procedure confirmar_conversion(p_id_conversion in number) is
      l_cab         prw_conversiones_cab%rowtype;
      l_lineas      t_lineas;
      l_acumulados  t_acumulados;
      l_id_entsal   stw_entsal_cab.id%type;
      l_id_lote     stw_lotes.id%type;
      l_comentario  varchar2(150);
   begin
      savepoint sp_confirmar_conversion;
      inicio_proceso;
      l_cab := bloquear_conversion(p_id_conversion);
      if l_cab.estado != 'P' then
         error(-20104, 'La conversión ' || l_cab.nro_comprobante || ' no está pendiente (estado '
                       || l_cab.estado || '): no se puede confirmar de nuevo.');
      end if;

      calcular_conversion_int(l_cab);
      l_comentario := 'Conversion ' || l_cab.tip_comprobante || ' ' || l_cab.ser_comprobante || '-' || l_cab.nro_comprobante;

      -- Salida de insumos
      for i in (select * from prw_conversiones_ing where id_conversion = l_cab.id order by nro_orden, id) loop
         l_lineas(l_lineas.count + 1).id_articulo := i.id_articulo;
         l_lineas(l_lineas.count).id_lote := i.id_lote;
         l_lineas(l_lineas.count).id_unidad_medida := i.id_unidad_medida;
         l_lineas(l_lineas.count).cantidad := i.cantidad;
         l_lineas(l_lineas.count).cantidad_ub := i.cantidad_ub;
         l_lineas(l_lineas.count).costo_unitario := i.costo_unitario;
         l_lineas(l_lineas.count).id_ref_det := i.id;
      end loop;
      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal, 'S', 'PRW_MOTIVO_CONV_SAL',
                                 co_ref_conversion, co_ser_confirma, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_lineas);

      -- Entrada de resultados, valorizada
      l_lineas.delete;
      for r in (select * from prw_conversion_res where id_conversion = l_cab.id order by nro_orden, id) loop
         l_id_lote := case when r.id_lote is not null
                           then lote_de_linea(l_cab.id_empresa, r.id_articulo, r.id_lote, 'Resultado')
                           else obtener_lote(l_cab.id_empresa, r.id_articulo, r.nro_lote, r.fec_vencimiento)
                      end;
         update prw_conversion_res x set x.id_lote = l_id_lote where x.id = r.id;
         l_lineas(l_lineas.count + 1).id_articulo := r.id_articulo;
         l_lineas(l_lineas.count).id_lote := l_id_lote;
         l_lineas(l_lineas.count).id_unidad_medida := r.id_unidad_medida;
         l_lineas(l_lineas.count).cantidad := r.cantidad;
         l_lineas(l_lineas.count).cantidad_ub := r.cantidad_ub;
         l_lineas(l_lineas.count).costo_unitario := r.costo_unitario;
         l_lineas(l_lineas.count).id_ref_det := r.id;
         acumular(l_acumulados, r.id_articulo, r.cantidad_ub, r.costo_total, l_id_lote);
      end loop;
      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal, 'E', 'PRW_MOTIVO_CONV_ENT',
                                 co_ref_conversion, co_ser_confirma, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_lineas);
      valorizar_acumulados(l_cab.id_empresa, l_acumulados, l_id_entsal, co_ref_conversion,
                           l_cab.id, l_cab.fec_comprobante);

      update prw_conversiones_cab c
         set c.estado         = 'C',
             c.cod_usu_confir = g_usuario,
             c.fec_confir     = sysdate
       where c.id = l_cab.id;
      fin_proceso;
   exception
      when others then
         rollback to sp_confirmar_conversion;
         fin_proceso;
         raise;
   end confirmar_conversion;

   procedure anular_conversion(p_id_conversion in number, p_motivo in varchar2) is
      l_cab         prw_conversiones_cab%rowtype;
      l_lineas      t_lineas;
      l_id_entsal   stw_entsal_cab.id%type;
      l_entradas    sys.odcinumberlist;
      l_comentario  varchar2(150);
   begin
      savepoint sp_anular_conversion;
      inicio_proceso;
      if trim(p_motivo) is null then
         error(-20105, 'Indique el motivo de la anulación.');
      end if;
      l_cab := bloquear_conversion(p_id_conversion);
      if l_cab.estado != 'C' then
         error(-20106, 'Solo se anulan conversiones confirmadas.');
      end if;
      l_comentario := 'Anula conversion ' || l_cab.ser_comprobante || '-' || l_cab.nro_comprobante;

      -- Salida de los resultados (deben seguir en stock)
      for r in (select * from prw_conversion_res where id_conversion = l_cab.id order by nro_orden, id) loop
         l_lineas(l_lineas.count + 1).id_articulo := r.id_articulo;
         l_lineas(l_lineas.count).id_lote := r.id_lote;
         l_lineas(l_lineas.count).id_unidad_medida := r.id_unidad_medida;
         l_lineas(l_lineas.count).cantidad := r.cantidad;
         l_lineas(l_lineas.count).cantidad_ub := r.cantidad_ub;
         l_lineas(l_lineas.count).costo_unitario := r.costo_unitario;
         l_lineas(l_lineas.count).id_ref_det := r.id;
      end loop;
      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal, 'S', 'PRW_MOTIVO_CONV_SAL',
                                 co_ref_conversion, co_ser_anula, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_lineas);

      l_entradas := entsal_de(co_ref_conversion, l_cab.id, co_ser_confirma, 'E');
      for i in 1 .. l_entradas.count loop
         revertir_costo(l_entradas(i), l_id_entsal);
      end loop;

      -- Reingreso de los insumos al costo con que salieron
      l_lineas.delete;
      for i in (select * from prw_conversiones_ing where id_conversion = l_cab.id order by nro_orden, id) loop
         l_lineas(l_lineas.count + 1).id_articulo := i.id_articulo;
         l_lineas(l_lineas.count).id_lote := i.id_lote;
         l_lineas(l_lineas.count).id_unidad_medida := i.id_unidad_medida;
         l_lineas(l_lineas.count).cantidad := i.cantidad;
         l_lineas(l_lineas.count).cantidad_ub := i.cantidad_ub;
         l_lineas(l_lineas.count).costo_unitario := i.costo_unitario;
         l_lineas(l_lineas.count).id_ref_det := i.id;
      end loop;
      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal, 'E', 'PRW_MOTIVO_CONV_ENT',
                                 co_ref_conversion, co_ser_anula, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_lineas);

      update prw_conversiones_cab c
         set c.estado           = 'A',
             c.cod_usu_anula    = g_usuario,
             c.fec_anulacion    = sysdate,
             c.motivo_anulacion = substr(p_motivo, 1, 500)
       where c.id = l_cab.id;
      fin_proceso;
   exception
      when others then
         rollback to sp_anular_conversion;
         fin_proceso;
         raise;
   end anular_conversion;

   procedure generar_conversion_compra(p_id_compra_cab in  number,
                                       p_id_conversion out number)
   is
      l_compra     cmw_compras_cabecera%rowtype;
      l_cuenta     pls_integer;
      l_id_conv    prw_conversiones_cab.id%type;
      l_generico   stw_articulos%rowtype;
      l_orden      pls_integer;
   begin
      inicio_proceso;
      select * into l_compra from cmw_compras_cabecera c where c.id = p_id_compra_cab;
      if nvl(l_compra.estado, 'P') != 'C' then
         error(-20130, 'La factura de compra debe estar confirmada para generar la conversión.');
      end if;

      select count(*)
        into l_cuenta
        from prw_conversiones_cab c
       where c.id_compra_cab = p_id_compra_cab
         and c.estado != 'A';
      if l_cuenta > 0 then
         error(-20131, 'La compra ya tiene una conversión generada. Anúlela antes de generar otra.');
      end if;

      -- Una conversión por genérico: el costo de cada genérico sale de
      -- sus propias marcas, no se reparte entre genéricos distintos
      for g in (select generico_de(l_compra.id_empresa, d.id_articulo, l_compra.id_sucursal) id_generico
                  from cmw_compras_detalle d
                 where d.id_compras_cab = p_id_compra_cab
                   and nvl(d.ind_stock, 'S') = 'S'
                   and generico_de(l_compra.id_empresa, d.id_articulo, l_compra.id_sucursal) is not null
                 group by generico_de(l_compra.id_empresa, d.id_articulo, l_compra.id_sucursal))
      loop
         l_generico := articulo(g.id_generico);
         insert into prw_conversiones_cab (id_empresa, id_sucursal, tipo_costo, origen,
                                           id_compra_cab, motivo)
         values (l_compra.id_empresa, l_compra.id_sucursal, 'C', 'R', p_id_compra_cab,
                 substr('Conversion de la compra ' || l_compra.tip_comprobante || ' '
                        || l_compra.ser_comprobante || '-' || l_compra.nro_comprobante
                        || ' a ' || l_generico.descripcion, 1, 500))
         returning id into l_id_conv;
         p_id_conversion := nvl(p_id_conversion, l_id_conv);

         l_orden := 0;
         for d in (select d.*
                     from cmw_compras_detalle d
                    where d.id_compras_cab = p_id_compra_cab
                      and nvl(d.ind_stock, 'S') = 'S'
                      and generico_de(l_compra.id_empresa, d.id_articulo, l_compra.id_sucursal) = g.id_generico
                    order by d.id)
         loop
            l_orden := l_orden + 1;
            insert into prw_conversiones_ing (id_conversion, id_empresa, nro_orden, id_articulo,
                                              id_lote, id_unidad_medida, cantidad, id_compra_det)
            select l_id_conv, l_compra.id_empresa, l_orden, d.id_articulo,
                   d.id_lote, a.id_unidad_medida, d.cantidad_ub, d.id
              from stw_articulos a
             where a.id = d.id_articulo;
         end loop;

         insert into prw_conversion_res (id_conversion, id_empresa, nro_orden, id_articulo,
                                         id_unidad_medida, cantidad, articulo_principal)
         select l_id_conv, l_compra.id_empresa, 1, g.id_generico, l_generico.id_unidad_medida,
                sum(d.cantidad_ub * factor_marca(l_compra.id_empresa, d.id_articulo)), 'S'
           from cmw_compras_detalle d
          where d.id_compras_cab = p_id_compra_cab
            and nvl(d.ind_stock, 'S') = 'S'
            and generico_de(l_compra.id_empresa, d.id_articulo, l_compra.id_sucursal) = g.id_generico;
      end loop;

      if p_id_conversion is null then
         error(-20132, 'La compra no tiene artículos que sean marca de un compuesto habilitado en '
                       || descripcion_sucursal(l_compra.id_sucursal) || '.');
      end if;
      fin_proceso;
   exception
      when no_data_found then
         fin_proceso;
         error(-20133, 'La compra ' || p_id_compra_cab || ' no existe.');
      when others then
         fin_proceso;
         raise;
   end generar_conversion_compra;

   -- ==================================================================
   -- Transferencias
   -- ==================================================================
   function bloquear_transferencia(p_id in number) return prw_transferencia_cab%rowtype is
      l_cab prw_transferencia_cab%rowtype;
   begin
      select * into l_cab from prw_transferencia_cab c where c.id = p_id for update nowait;
      return l_cab;
   exception
      when no_data_found then
         error(-20101, 'La transferencia ' || p_id || ' no existe.');
      when e_recurso_ocupado then
         error(-20102, 'La transferencia está siendo procesada por otro usuario. Intente nuevamente.');
   end bloquear_transferencia;

   procedure confirmar_transferencia(p_id_transferencia in number) is
      l_cab          prw_transferencia_cab%rowtype;
      l_salidas      t_lineas;
      l_entradas     t_lineas;
      l_acumulados   t_acumulados;
      l_contexto     varchar2(100);
      l_linea        pls_integer := 0;
      l_ub           number;
      l_destino      number;
      l_um_destino   number;
      l_ub_destino   number;
      l_lote         number;
      l_lote_destino number;
      l_costo_unit   number;
      l_id_compra_det cmw_compras_detalle.id%type;
      l_id_entsal    stw_entsal_cab.id%type;
      l_comentario   varchar2(150);
   begin
      savepoint sp_confirmar_transferencia;
      inicio_proceso;
      l_cab := bloquear_transferencia(p_id_transferencia);
      if l_cab.estado != 'P' then
         error(-20104, 'La transferencia ' || l_cab.nro_comprobante || ' no está pendiente: no se puede confirmar de nuevo.');
      end if;
      validar_sucursal(l_cab.id_empresa, l_cab.id_sucursal, 'Sucursal de salida');
      validar_sucursal(l_cab.id_empresa, l_cab.id_sucursal_ent, 'Sucursal de entrada');
      l_comentario := 'Transferencia ' || l_cab.ser_comprobante || '-' || l_cab.nro_comprobante;

      for d in (select * from prw_transferencia_det where id_transferencia = l_cab.id order by nro_orden, id) loop
         l_linea := l_linea + 1;
         l_contexto := 'Línea ' || l_linea;
         validar_articulo(l_cab.id_empresa, d.id_articulo, l_contexto);
         l_ub := a_unidad_base(d.id_articulo, d.id_unidad_medida, d.cantidad);
         l_lote := lote_de_linea(l_cab.id_empresa, d.id_articulo, d.id_lote, l_contexto);

         l_destino := nvl(d.id_articulo_conv, d.id_articulo);
         validar_articulo(l_cab.id_empresa, l_destino, l_contexto || ' (destino)');
         l_um_destino := nvl(d.id_unidad_medida_conv, case when l_destino = d.id_articulo then d.id_unidad_medida
                                                           else articulo(l_destino).id_unidad_medida end);
         if d.cantidad_conv is not null then
            l_ub_destino := a_unidad_base(l_destino, l_um_destino, d.cantidad_conv);
         elsif l_destino = d.id_articulo then
            l_ub_destino := l_ub;
         elsif generico_de(l_cab.id_empresa, d.id_articulo, l_cab.id_sucursal_ent) = l_destino then
            l_ub_destino := l_ub * factor_marca(l_cab.id_empresa, d.id_articulo);
         else
            error(-20140, l_contexto || ': indique la cantidad de destino de '
                          || descripcion_articulo(l_destino) || '.');
         end if;

         l_lote_destino := case when d.id_lote_conv is not null
                                then lote_de_linea(l_cab.id_empresa, l_destino, d.id_lote_conv, l_contexto || ' (destino)')
                                when l_destino = d.id_articulo then l_lote
                                else lote_de_linea(l_cab.id_empresa, l_destino, null, l_contexto || ' (destino)')
                           end;

         if l_destino = d.id_articulo and l_cab.id_sucursal = l_cab.id_sucursal_ent and l_lote = l_lote_destino then
            error(-20141, l_contexto || ': el artículo, el lote y la sucursal de destino son los de origen; '
                          || 'la línea no transfiere nada.');
         end if;
         if l_destino = d.id_articulo and abs(l_ub - l_ub_destino) > co_tolerancia_cant then
            error(-20142, l_contexto || ': para el mismo artículo la cantidad de destino debe ser igual a la de origen.');
         end if;

         -- Costo de salida: el de la compra si la transferencia corrige
         -- una recepción, si no el promedio vigente
         l_costo_unit := null;
         if l_cab.id_compra_cab is not null then
            select max(cd.id)
              into l_id_compra_det
              from cmw_compras_detalle cd
             where cd.id_compras_cab = l_cab.id_compra_cab
               and cd.id_articulo = d.id_articulo;
            if l_id_compra_det is not null then
               l_costo_unit := costo_linea_compra(l_id_compra_det);
            end if;
         end if;
         l_costo_unit := nvl(l_costo_unit, costo_promedio(d.id_articulo));

         update prw_transferencia_det x
            set x.cantidad_ub           = l_ub,
                x.id_lote               = l_lote,
                x.id_articulo_conv      = l_destino,
                x.id_unidad_medida_conv = l_um_destino,
                x.cantidad_ub_conv      = l_ub_destino,
                x.cantidad_conv         = nvl(x.cantidad_conv, l_ub_destino),
                x.id_lote_conv          = l_lote_destino,
                x.costo_unitario        = round(l_costo_unit, 6),
                x.costo_total           = round(l_ub * l_costo_unit, 3)
          where x.id = d.id;

         l_salidas(l_salidas.count + 1).id_articulo := d.id_articulo;
         l_salidas(l_salidas.count).id_lote := l_lote;
         l_salidas(l_salidas.count).id_unidad_medida := d.id_unidad_medida;
         l_salidas(l_salidas.count).cantidad := d.cantidad;
         l_salidas(l_salidas.count).cantidad_ub := l_ub;
         l_salidas(l_salidas.count).costo_unitario := l_costo_unit;
         l_salidas(l_salidas.count).id_ref_det := d.id;

         l_entradas(l_entradas.count + 1).id_articulo := l_destino;
         l_entradas(l_entradas.count).id_lote := l_lote_destino;
         l_entradas(l_entradas.count).id_unidad_medida := l_um_destino;
         l_entradas(l_entradas.count).cantidad := nvl(d.cantidad_conv, l_ub_destino);
         l_entradas(l_entradas.count).cantidad_ub := l_ub_destino;
         l_entradas(l_entradas.count).costo_unitario := round(l_ub * l_costo_unit, 3) / l_ub_destino;
         l_entradas(l_entradas.count).id_ref_det := d.id;

         -- Solo cambia el costo si cambia el artículo: el promedio es
         -- de la empresa, no de la sucursal
         if l_destino != d.id_articulo then
            acumular(l_acumulados, l_destino, l_ub_destino, round(l_ub * l_costo_unit, 3), l_lote_destino);
         end if;
      end loop;

      if l_linea = 0 then
         error(-20143, 'La transferencia no tiene líneas.');
      end if;

      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal, 'S', 'PRW_MOTIVO_TRF_SAL',
                                 co_ref_transferencia, co_ser_confirma, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_salidas);
      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal_ent, 'E', 'PRW_MOTIVO_TRF_ENT',
                                 co_ref_transferencia, co_ser_confirma, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_entradas);
      valorizar_acumulados(l_cab.id_empresa, l_acumulados, l_id_entsal, co_ref_transferencia,
                           l_cab.id, l_cab.fec_comprobante);

      update prw_transferencia_cab c
         set c.estado         = 'C',
             c.cod_usu_confir = g_usuario,
             c.fec_confir     = sysdate
       where c.id = l_cab.id;
      fin_proceso;
   exception
      when others then
         rollback to sp_confirmar_transferencia;
         fin_proceso;
         raise;
   end confirmar_transferencia;

   procedure anular_transferencia(p_id_transferencia in number, p_motivo in varchar2) is
      l_cab        prw_transferencia_cab%rowtype;
      l_salidas    t_lineas;
      l_entradas   t_lineas;
      l_id_entsal  stw_entsal_cab.id%type;
      l_previas    sys.odcinumberlist;
      l_comentario varchar2(150);
   begin
      savepoint sp_anular_transferencia;
      inicio_proceso;
      if trim(p_motivo) is null then
         error(-20105, 'Indique el motivo de la anulación.');
      end if;
      l_cab := bloquear_transferencia(p_id_transferencia);
      if l_cab.estado != 'C' then
         error(-20106, 'Solo se anulan transferencias confirmadas.');
      end if;
      l_comentario := 'Anula transferencia ' || l_cab.ser_comprobante || '-' || l_cab.nro_comprobante;

      for d in (select * from prw_transferencia_det where id_transferencia = l_cab.id order by nro_orden, id) loop
         l_salidas(l_salidas.count + 1).id_articulo := d.id_articulo_conv;
         l_salidas(l_salidas.count).id_lote := d.id_lote_conv;
         l_salidas(l_salidas.count).id_unidad_medida := d.id_unidad_medida_conv;
         l_salidas(l_salidas.count).cantidad := d.cantidad_conv;
         l_salidas(l_salidas.count).cantidad_ub := d.cantidad_ub_conv;
         l_salidas(l_salidas.count).costo_unitario := d.costo_total / d.cantidad_ub_conv;
         l_salidas(l_salidas.count).id_ref_det := d.id;

         l_entradas(l_entradas.count + 1).id_articulo := d.id_articulo;
         l_entradas(l_entradas.count).id_lote := d.id_lote;
         l_entradas(l_entradas.count).id_unidad_medida := d.id_unidad_medida;
         l_entradas(l_entradas.count).cantidad := d.cantidad;
         l_entradas(l_entradas.count).cantidad_ub := d.cantidad_ub;
         l_entradas(l_entradas.count).costo_unitario := d.costo_unitario;
         l_entradas(l_entradas.count).id_ref_det := d.id;
      end loop;

      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal_ent, 'S', 'PRW_MOTIVO_TRF_SAL',
                                 co_ref_transferencia, co_ser_anula, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_salidas);
      l_previas := entsal_de(co_ref_transferencia, l_cab.id, co_ser_confirma, 'E');
      for i in 1 .. l_previas.count loop
         revertir_costo(l_previas(i), l_id_entsal);
      end loop;
      l_id_entsal := mover_stock(l_cab.id_empresa, l_cab.id_sucursal, 'E', 'PRW_MOTIVO_TRF_ENT',
                                 co_ref_transferencia, co_ser_anula, l_cab.id, l_cab.nro_comprobante,
                                 l_comentario, l_entradas);

      update prw_transferencia_cab c
         set c.estado           = 'A',
             c.cod_usu_anula    = g_usuario,
             c.fec_anulacion    = sysdate,
             c.motivo_anulacion = substr(p_motivo, 1, 500)
       where c.id = l_cab.id;
      fin_proceso;
   exception
      when others then
         rollback to sp_anular_transferencia;
         fin_proceso;
         raise;
   end anular_transferencia;

   -- ==================================================================
   -- Producción
   -- ==================================================================
   function estado_produccion(p_id_produccion in number) return varchar2 is
      l_estado varchar2(1);
   begin
      select case when nvl(c.anulado, 'N') = 'S' then 'A' else nvl(c.estado, 'P') end
        into l_estado
        from pdw_produccion_cab c
       where c.id = p_id_produccion;
      return l_estado;
   exception
      when no_data_found then
         return null;
   end estado_produccion;

   function bloquear_produccion(p_id in number) return pdw_produccion_cab%rowtype is
      l_cab pdw_produccion_cab%rowtype;
   begin
      select * into l_cab from pdw_produccion_cab c where c.id = p_id for update nowait;
      return l_cab;
   exception
      when no_data_found then
         error(-20101, 'La orden de producción ' || p_id || ' no existe.');
      when e_recurso_ocupado then
         error(-20102, 'La orden de producción está siendo procesada por otro usuario. Intente nuevamente.');
   end bloquear_produccion;

   -- Los triggers legados de PDW_PRODUCCION_* mueven stock y costo por
   -- su cuenta. Con ellos activos, confirmar duplicaría movimientos.
   procedure verificar_triggers_legados is
      l_activos varchar2(1000);
   begin
      select listagg(t.trigger_name, ', ') within group (order by t.trigger_name)
        into l_activos
        from user_triggers t
       where t.trigger_name in ('ACTUALIZA_PRODUCCION_DET', 'ACTUALIZA_STOCK_UTILIZADOS',
                                'ACTUALIZA_STOCK_PRODUCIDO', 'ACTUALIZA_COSTO_PRODUCCION',
                                'ACTUALIZA_DETALLE_PRODUCCION', 'ACTUALIZA_ANULACION_PRODUCCION')
         and t.status = 'ENABLED';
      if l_activos is not null then
         error(-20180, 'Los triggers legados de producción siguen activos (' || l_activos
                       || '). Ejecute db/produccion/06_triggers_legados.sql antes de confirmar.');
      end if;
   end verificar_triggers_legados;

   function formula(p_id_formula in number) return pdw_formula_cab%rowtype is
      l_formula pdw_formula_cab%rowtype;
   begin
      select * into l_formula from pdw_formula_cab f where f.id = p_id_formula;
      return l_formula;
   exception
      when no_data_found then
         error(-20170, 'La fórmula ' || p_id_formula || ' no existe.');
   end formula;

   -- Cantidad (unidad base) sobre la que se calcula la receta: la
   -- procesada (real) o, si todavía no hay, la planificada
   function cantidad_base_producido(p_id_articulo      in number,
                                    p_id_unidad_medida in number,
                                    p_cant_procesada   in number,
                                    p_cantidad         in number)
      return number
   is
   begin
      return a_unidad_base(p_id_articulo, p_id_unidad_medida, nvl(nullif(p_cant_procesada, 0), p_cantidad));
   end cantidad_base_producido;

   procedure calcular_insumos_produccion(p_id_produccion in number) is
      type t_reales is table of number index by varchar2(100);
      l_cab       pdw_produccion_cab%rowtype;
      l_formula   pdw_formula_cab%rowtype;
      l_reales    t_reales;
      l_clave     varchar2(100);
      l_factor    number;
      l_sucursal  number;
      l_costo     number;
      l_teorico   number;
      l_cuenta    pls_integer := 0;
      l_id_emp    number;
      l_real      number;
      l_id_lote   number;
   begin
      inicio_proceso;
      l_cab := bloquear_produccion(p_id_produccion);
      if estado_produccion(p_id_produccion) != 'P' then
         error(-20103, 'Solo se recalculan los insumos de órdenes pendientes.');
      end if;
      l_id_emp := to_number(l_cab.id_empresa);

      -- Se conserva el consumo real ya cargado
      for d in (select d.id_articulo, d.id_formula, d.id_sucursal, d.cantidad_real
                  from pdw_produccion_det d
                 where d.id_produccion_cab = p_id_produccion
                   and nvl(d.indice, 'M') = 'M'
                   and d.cantidad_real is not null)
      loop
         l_reales(d.id_articulo || '-' || d.id_formula || '-' || d.id_sucursal) := d.cantidad_real;
      end loop;

      delete from pdw_produccion_det d
       where d.id_produccion_cab = p_id_produccion
         and nvl(d.indice, 'M') = 'M';

      for p in (select * from pdw_produccion_producido
                 where id_produccion_cab = p_id_produccion
                   and nvl(anulado, 'N') = 'N'
                 order by id)
      loop
         l_cuenta := l_cuenta + 1;
         l_formula := formula(p.id_formula);
         if nvl(l_formula.cantidad_ub, 0) <= 0 then
            error(-20171, 'La fórmula ' || l_formula.cod_formula || ' no tiene cantidad de referencia.');
         end if;
         -- La receta está expresada para la cantidad de referencia de la
         -- fórmula: se escala a lo que se produce
         l_factor := cantidad_base_producido(p.id_articulo, p.id_unidad_medida, p.cant_procesada, p.cantidad)
                     / l_formula.cantidad_ub;

         for f in (select fd.*, a.descripcion desc_articulo
                     from pdw_formula_det fd
                     join stw_articulos a on a.id = fd.id_articulo
                    where fd.id_formula_cab = p.id_formula
                    order by fd.nro_orden, fd.id)
         loop
            if es_marca(l_id_emp, f.id_articulo) = 'S' then
               error(-20172, 'La fórmula ' || l_formula.cod_formula || ' usa la marca '
                             || descripcion_articulo(f.id_articulo)
                             || '. Las fórmulas deben usar el artículo genérico del compuesto.');
            end if;
            l_sucursal := nvl(f.id_sucursal, p.id_sucursal);
            validar_sucursal(l_id_emp, l_sucursal, 'Insumo ' || descripcion_articulo(f.id_articulo)
                                                   || ' de la fórmula ' || l_formula.cod_formula);
            l_costo := costo_promedio(f.id_articulo);
            l_teorico := f.cantidad * l_factor;
            l_clave := f.id_articulo || '-' || p.id_formula || '-' || l_sucursal;
            l_real := case when l_reales.exists(l_clave) then l_reales(l_clave) else round(l_teorico, 4) end;
            l_id_lote := lote_defecto(l_id_emp, f.id_articulo);

            insert into pdw_produccion_det (id_produccion_cab, id_empresa, id_articulo, cantidad,
                                            cantidad_referencia, cantidad_det, cantidad_ub,
                                            id_sucursal, id_unidad_medida, id_lote, id_formula,
                                            indice, estado, anulado, afecta_merma,
                                            ind_mp_fundamental, desc_articulo, costo_unitario,
                                            costo_promedio, monto_total, nro_orden, cantidad_real)
            values (p_id_produccion, l_id_emp, f.id_articulo, round(l_teorico, 2),
                    round(l_teorico, 2), f.cantidad, round(f.cantidad_ub * l_factor, 2),
                    l_sucursal, f.id_unidad_medida, l_id_lote, p.id_formula,
                    'M', 'P', 'N', f.afecta_merma,
                    f.ind_mp_fundamental, substr(f.desc_articulo, 1, 200), round(l_costo, 2),
                    round(l_costo, 2), round(f.cantidad_ub * l_factor * l_costo, 2), f.nro_orden,
                    l_real);
         end loop;
      end loop;

      if l_cuenta = 0 then
         error(-20173, 'La orden no tiene artículos producidos.');
      end if;
      fin_proceso;
   exception
      when others then
         fin_proceso;
         raise;
   end calcular_insumos_produccion;

   function tolerancia(p_formula in pdw_formula_cab%rowtype) return number is
   begin
      return nvl(p_formula.tolerancia_porc, to_number(parametro('PRW_TOLERANCIA_PORC')));
   end tolerancia;

   function desvios_produccion(p_id_produccion in number) return varchar2 is
      l_texto    varchar2(4000);
      l_formula  pdw_formula_cab%rowtype;
      l_desvio   number;

      procedure agregar(p_linea in varchar2) is
      begin
         l_texto := substr(l_texto || case when l_texto is not null then chr(10) end || p_linea, 1, 4000);
      end agregar;
   begin
      for p in (select * from pdw_produccion_producido
                 where id_produccion_cab = p_id_produccion and nvl(anulado, 'N') = 'N')
      loop
         l_formula := formula(p.id_formula);
         if nvl(p.cantidad, 0) > 0 then
            l_desvio := round((nvl(p.cant_procesada, 0) - p.cantidad) / p.cantidad * 100, 2);
            if abs(l_desvio) > tolerancia(l_formula) then
               agregar('Producido ' || descripcion_articulo(p.id_articulo) || ': planificado ' || p.cantidad
                       || ', real ' || nvl(p.cant_procesada, 0) || ' (desvío ' || l_desvio
                       || '%, tolerancia ' || tolerancia(l_formula) || '%).');
            end if;
         end if;
      end loop;

      for d in (select d.*, f.cod_formula
                  from pdw_produccion_det d
                  join pdw_formula_cab f on f.id = d.id_formula
                 where d.id_produccion_cab = p_id_produccion
                   and nvl(d.indice, 'M') = 'M'
                   and nvl(d.anulado, 'N') = 'N')
      loop
         if nvl(d.cantidad, 0) > 0 then
            l_formula := formula(d.id_formula);
            l_desvio := round((nvl(d.cantidad_real, 0) - d.cantidad) / d.cantidad * 100, 2);
            if abs(l_desvio) > tolerancia(l_formula) then
               agregar('Insumo ' || descripcion_articulo(d.id_articulo) || ' (fórmula ' || d.cod_formula
                       || '): teórico ' || d.cantidad || ', real ' || nvl(d.cantidad_real, 0)
                       || ' (desvío ' || l_desvio || '%, tolerancia ' || tolerancia(l_formula) || '%).');
            end if;
         end if;
      end loop;
      return l_texto;
   end desvios_produccion;

   procedure confirmar_produccion(p_id_produccion in number,
                                  p_forzar_desvio in varchar2 default 'N',
                                  p_motivo_desvio in varchar2 default null)
   is
      type t_costos is table of number index by pls_integer;
      type t_cantidades is table of number index by pls_integer;
      l_cab           pdw_produccion_cab%rowtype;
      l_id_emp        number;
      l_formula       pdw_formula_cab%rowtype;
      l_costo_formula t_costos;
      l_ub_formula    t_cantidades;
      l_desvios       varchar2(4000);
      l_real_ub       number;
      l_costo_unit    number;
      l_esperado      number;
      l_cuenta        pls_integer;
      l_lineas        t_lineas;
      l_acumulados    t_acumulados;
      l_id_entsal     stw_entsal_cab.id%type;
      l_id_lote       stw_lotes.id%type;
      l_comentario    varchar2(150);
      l_costo_prod    number;
   begin
      savepoint sp_confirmar_produccion;
      inicio_proceso;
      verificar_triggers_legados;
      l_cab := bloquear_produccion(p_id_produccion);
      if estado_produccion(p_id_produccion) != 'P' then
         error(-20104, 'La orden ' || l_cab.nro_produccion || ' no está pendiente: no se puede confirmar de nuevo.');
      end if;
      l_id_emp := to_number(l_cab.id_empresa);
      l_comentario := 'Produccion ' || l_cab.tip_produccion || ' ' || l_cab.ser_produccion || '-' || l_cab.nro_produccion;

      -- Producidos: cantidad real obligatoria
      select count(*) into l_cuenta from pdw_produccion_producido
       where id_produccion_cab = p_id_produccion and nvl(anulado, 'N') = 'N';
      if l_cuenta = 0 then
         error(-20173, 'La orden no tiene artículos producidos.');
      end if;
      for p in (select * from pdw_produccion_producido
                 where id_produccion_cab = p_id_produccion and nvl(anulado, 'N') = 'N')
      loop
         if nvl(p.cant_procesada, 0) <= 0 then
            error(-20174, 'Cargue la cantidad procesada (real) de ' || descripcion_articulo(p.id_articulo) || '.');
         end if;
         l_formula := formula(p.id_formula);
         if nvl(l_formula.estado, 'N') != 'S' then
            error(-20175, 'La fórmula ' || l_formula.cod_formula || ' está inactiva.');
         end if;
         validar_sucursal(l_id_emp, p.id_sucursal, 'Producido ' || descripcion_articulo(p.id_articulo));
      end loop;

      -- Los insumos tienen que estar calculados para la cantidad real:
      -- por fórmula, lo que pide la receta para todo lo producido con
      -- ella contra lo que hay en el detalle
      for x in (select p.id_formula, sum(p.cant_procesada) cant_procesada,
                       max(p.id_articulo) id_articulo, max(p.id_unidad_medida) id_unidad_medida,
                       count(*) lineas
                  from pdw_produccion_producido p
                 where p.id_produccion_cab = p_id_produccion
                   and nvl(p.anulado, 'N') = 'N'
                 group by p.id_formula)
      loop
         l_formula := formula(x.id_formula);
         for f in (select fd.id_articulo, sum(fd.cantidad) cantidad
                     from pdw_formula_det fd
                    where fd.id_formula_cab = x.id_formula
                    group by fd.id_articulo)
         loop
            l_esperado := f.cantidad
                          * a_unidad_base(x.id_articulo, x.id_unidad_medida, x.cant_procesada)
                          / l_formula.cantidad_ub;
            select nvl(sum(d.cantidad), -1)
              into l_real_ub
              from pdw_produccion_det d
             where d.id_produccion_cab = p_id_produccion
               and d.id_formula = x.id_formula
               and d.id_articulo = f.id_articulo
               and nvl(d.indice, 'M') = 'M'
               and nvl(d.anulado, 'N') = 'N';
            -- Margen: el redondeo a 2 decimales de cada línea del detalle
            if abs(l_real_ub - l_esperado) > 0.01 * x.lineas then
               error(-20176, 'Los insumos de la fórmula ' || l_formula.cod_formula
                             || ' no corresponden a la cantidad producida. Pulse "Calcular insumos" y revise el consumo real.');
            end if;
         end loop;
      end loop;

      for d in (select * from pdw_produccion_det
                 where id_produccion_cab = p_id_produccion
                   and nvl(indice, 'M') = 'M' and nvl(anulado, 'N') = 'N'
                   and cantidad_real is null)
      loop
         error(-20177, 'Falta el consumo real de ' || descripcion_articulo(d.id_articulo) || '.');
      end loop;

      -- Rendimiento
      l_desvios := desvios_produccion(p_id_produccion);
      if l_desvios is not null then
         if parametro('PRW_TOLERANCIA_BLOQUEA') = 'S' then
            error(-20178, 'Desvíos fuera de tolerancia:' || chr(10) || l_desvios);
         elsif nvl(p_forzar_desvio, 'N') != 'S' or trim(p_motivo_desvio) is null then
            error(-20179, 'Desvíos fuera de tolerancia:' || chr(10) || l_desvios || chr(10)
                          || 'Para confirmar igual marque "Confirmar con desvío" e indique el motivo.');
         end if;
      end if;

      -- Salida de insumos al costo promedio vigente, por sucursal
      for s in (select distinct d.id_sucursal
                  from pdw_produccion_det d
                 where d.id_produccion_cab = p_id_produccion
                   and nvl(d.indice, 'M') = 'M' and nvl(d.anulado, 'N') = 'N')
      loop
         l_lineas.delete;
         for d in (select * from pdw_produccion_det
                    where id_produccion_cab = p_id_produccion and id_sucursal = s.id_sucursal
                      and nvl(indice, 'M') = 'M' and nvl(anulado, 'N') = 'N'
                    order by id)
         loop
            validar_sucursal(l_id_emp, d.id_sucursal, 'Insumo ' || descripcion_articulo(d.id_articulo));
            l_costo_unit := costo_promedio(d.id_articulo);
            l_real_ub := case when d.cantidad_real > 0
                              then a_unidad_base(d.id_articulo, d.id_unidad_medida, d.cantidad_real)
                              else 0 end;
            update pdw_produccion_det x
               set x.costo_unitario = round(l_costo_unit, 2),
                   x.costo_promedio = round(l_costo_unit, 2),
                   x.monto_total    = round(l_real_ub * l_costo_unit, 2),
                   x.estado         = 'C'
             where x.id = d.id;
            l_costo_formula(d.id_formula) := case when l_costo_formula.exists(d.id_formula)
                                                  then l_costo_formula(d.id_formula) else 0 end
                                             + round(l_real_ub * l_costo_unit, 3);
            if l_real_ub > 0 then
               l_lineas(l_lineas.count + 1).id_articulo := d.id_articulo;
               l_lineas(l_lineas.count).id_lote := lote_de_linea(l_id_emp, d.id_articulo, d.id_lote, 'Insumo');
               l_lineas(l_lineas.count).id_unidad_medida := d.id_unidad_medida;
               l_lineas(l_lineas.count).cantidad := d.cantidad_real;
               l_lineas(l_lineas.count).cantidad_ub := l_real_ub;
               l_lineas(l_lineas.count).costo_unitario := l_costo_unit;
               l_lineas(l_lineas.count).id_ref_det := d.id;
               l_lineas(l_lineas.count).id_produccion_det := d.id;
            end if;
         end loop;
         l_id_entsal := mover_stock(l_id_emp, s.id_sucursal, 'S', 'PRW_MOTIVO_PROD_SAL',
                                    co_ref_produccion, co_ser_confirma, p_id_produccion, l_cab.nro_produccion,
                                    l_comentario, l_lineas, p_id_produccion);
      end loop;

      -- Costo de cada producido: el de los insumos de su fórmula,
      -- repartido por cantidad si la fórmula se usa en más de una línea
      for p in (select * from pdw_produccion_producido
                 where id_produccion_cab = p_id_produccion and nvl(anulado, 'N') = 'N')
      loop
         l_ub_formula(p.id_formula) := case when l_ub_formula.exists(p.id_formula)
                                            then l_ub_formula(p.id_formula) else 0 end
                                       + cantidad_base_producido(p.id_articulo, p.id_unidad_medida, p.cant_procesada, p.cantidad);
      end loop;

      for s in (select distinct p.id_sucursal
                  from pdw_produccion_producido p
                 where p.id_produccion_cab = p_id_produccion and nvl(p.anulado, 'N') = 'N')
      loop
         l_lineas.delete;
         l_acumulados.delete;
         for p in (select * from pdw_produccion_producido
                    where id_produccion_cab = p_id_produccion and id_sucursal = s.id_sucursal
                      and nvl(anulado, 'N') = 'N'
                    order by id)
         loop
            l_real_ub := cantidad_base_producido(p.id_articulo, p.id_unidad_medida, p.cant_procesada, p.cantidad);
            l_costo_prod := round(case when l_costo_formula.exists(p.id_formula)
                                       then l_costo_formula(p.id_formula) else 0 end
                                  * l_real_ub / l_ub_formula(p.id_formula), 3);
            l_id_lote := lote_de_linea(l_id_emp, p.id_articulo, p.id_lote, 'Producido');
            update pdw_produccion_producido x
               set x.costo               = l_costo_prod,
                   x.costo_materia_prima = l_costo_prod,
                   x.cant_diferencia     = nvl(x.cantidad, 0) - nvl(x.cant_procesada, 0),
                   x.cantidad_ub         = round(l_real_ub, 2),
                   x.id_lote             = l_id_lote,
                   x.estado              = 'C'
             where x.id = p.id;

            l_lineas(l_lineas.count + 1).id_articulo := p.id_articulo;
            l_lineas(l_lineas.count).id_lote := l_id_lote;
            l_lineas(l_lineas.count).id_unidad_medida := p.id_unidad_medida;
            l_lineas(l_lineas.count).cantidad := p.cant_procesada;
            l_lineas(l_lineas.count).cantidad_ub := l_real_ub;
            l_lineas(l_lineas.count).costo_unitario := l_costo_prod / l_real_ub;
            l_lineas(l_lineas.count).id_ref_det := p.id;
            l_lineas(l_lineas.count).id_produccion_det := p.id;
            acumular(l_acumulados, p.id_articulo, l_real_ub, l_costo_prod, l_id_lote);
         end loop;
         l_id_entsal := mover_stock(l_id_emp, s.id_sucursal, 'E', 'PRW_MOTIVO_PROD_ENT',
                                    co_ref_produccion, co_ser_confirma, p_id_produccion, l_cab.nro_produccion,
                                    l_comentario, l_lineas, p_id_produccion);
         valorizar_acumulados(l_id_emp, l_acumulados, l_id_entsal, co_ref_produccion,
                              p_id_produccion, l_cab.fec_produccion);
      end loop;

      update pdw_produccion_cab c
         set c.estado         = 'C',
             c.fec_estado     = sysdate,
             c.cod_usu_confir = g_usuario,
             c.fec_confir     = sysdate,
             c.motivo_desvio  = case when l_desvios is not null then substr(p_motivo_desvio, 1, 500) end
       where c.id = p_id_produccion;
      fin_proceso;
   exception
      when others then
         rollback to sp_confirmar_produccion;
         fin_proceso;
         raise;
   end confirmar_produccion;

   procedure anular_produccion(p_id_produccion in number, p_motivo in varchar2) is
      l_cab        pdw_produccion_cab%rowtype;
      l_id_emp     number;
      l_lineas     t_lineas;
      l_id_entsal  stw_entsal_cab.id%type;
      l_previas    sys.odcinumberlist;
      l_comentario varchar2(150);
   begin
      savepoint sp_anular_produccion;
      inicio_proceso;
      verificar_triggers_legados;
      if trim(p_motivo) is null then
         error(-20105, 'Indique el motivo de la anulación.');
      end if;
      l_cab := bloquear_produccion(p_id_produccion);
      if estado_produccion(p_id_produccion) != 'C' then
         error(-20106, 'Solo se anulan órdenes confirmadas.');
      end if;
      l_id_emp := to_number(l_cab.id_empresa);
      l_comentario := 'Anula produccion ' || l_cab.ser_produccion || '-' || l_cab.nro_produccion;

      -- Salida de lo producido
      for s in (select distinct id_sucursal from pdw_produccion_producido
                 where id_produccion_cab = p_id_produccion and nvl(anulado, 'N') = 'N')
      loop
         l_lineas.delete;
         for p in (select * from pdw_produccion_producido
                    where id_produccion_cab = p_id_produccion and id_sucursal = s.id_sucursal
                      and nvl(anulado, 'N') = 'N')
         loop
            l_lineas(l_lineas.count + 1).id_articulo := p.id_articulo;
            l_lineas(l_lineas.count).id_lote := p.id_lote;
            l_lineas(l_lineas.count).id_unidad_medida := p.id_unidad_medida;
            l_lineas(l_lineas.count).cantidad := p.cant_procesada;
            l_lineas(l_lineas.count).cantidad_ub := cantidad_base_producido(p.id_articulo, p.id_unidad_medida, p.cant_procesada, p.cantidad);
            l_lineas(l_lineas.count).costo_unitario := p.costo / cantidad_base_producido(p.id_articulo, p.id_unidad_medida, p.cant_procesada, p.cantidad);
            l_lineas(l_lineas.count).id_ref_det := p.id;
            l_lineas(l_lineas.count).id_produccion_det := p.id;
         end loop;
         l_id_entsal := mover_stock(l_id_emp, s.id_sucursal, 'S', 'PRW_MOTIVO_PROD_SAL',
                                    co_ref_produccion, co_ser_anula, p_id_produccion, l_cab.nro_produccion,
                                    l_comentario, l_lineas, p_id_produccion);
      end loop;

      l_previas := entsal_de(co_ref_produccion, p_id_produccion, co_ser_confirma, 'E');
      for i in 1 .. l_previas.count loop
         revertir_costo(l_previas(i), l_id_entsal);
      end loop;

      -- Reingreso de insumos al costo con que salieron
      for s in (select distinct id_sucursal from pdw_produccion_det
                 where id_produccion_cab = p_id_produccion
                   and nvl(indice, 'M') = 'M' and nvl(anulado, 'N') = 'N' and cantidad_real > 0)
      loop
         l_lineas.delete;
         for d in (select * from pdw_produccion_det
                    where id_produccion_cab = p_id_produccion and id_sucursal = s.id_sucursal
                      and nvl(indice, 'M') = 'M' and nvl(anulado, 'N') = 'N' and cantidad_real > 0)
         loop
            l_lineas(l_lineas.count + 1).id_articulo := d.id_articulo;
            l_lineas(l_lineas.count).id_lote := d.id_lote;
            l_lineas(l_lineas.count).id_unidad_medida := d.id_unidad_medida;
            l_lineas(l_lineas.count).cantidad := d.cantidad_real;
            l_lineas(l_lineas.count).cantidad_ub := a_unidad_base(d.id_articulo, d.id_unidad_medida, d.cantidad_real);
            l_lineas(l_lineas.count).costo_unitario := d.costo_unitario;
            l_lineas(l_lineas.count).id_ref_det := d.id;
            l_lineas(l_lineas.count).id_produccion_det := d.id;
         end loop;
         l_id_entsal := mover_stock(l_id_emp, s.id_sucursal, 'E', 'PRW_MOTIVO_PROD_ENT',
                                    co_ref_produccion, co_ser_anula, p_id_produccion, l_cab.nro_produccion,
                                    l_comentario, l_lineas, p_id_produccion);
      end loop;

      update pdw_produccion_det set anulado = 'S' where id_produccion_cab = p_id_produccion;
      update pdw_produccion_producido set anulado = 'S' where id_produccion_cab = p_id_produccion;
      update pdw_produccion_cab c
         set c.anulado          = 'S',
             c.fec_estado       = sysdate,
             c.cod_usu_anula    = g_usuario,
             c.fec_anulacion    = sysdate,
             c.motivo_anulacion = substr(p_motivo, 1, 500)
       where c.id = p_id_produccion;
      fin_proceso;
   exception
      when others then
         rollback to sp_anular_produccion;
         fin_proceso;
         raise;
   end anular_produccion;

   procedure agregar_a_orden(p_id_empresa    in     number,
                             p_id_sucursal   in     number,
                             p_fecha         in     date,
                             p_id_formula    in     number,
                             p_cantidad      in     number,
                             p_id_produccion in out number)
   is
      l_formula   pdw_formula_cab%rowtype := formula(p_id_formula);
      l_serie     pdw_produccion_cab.ser_produccion%type := nvl(w_busca_parametro('PD', 'SERIE_PRODUCCION'), 'A');
      l_nro       pdw_produccion_cab.nro_produccion%type;
      l_sucursal  number;
      l_articulo  stw_articulos%rowtype;
      l_cantidad_ub number;
      l_id_lote   number;
   begin
      inicio_proceso;
      if to_number(l_formula.id_empresa) != p_id_empresa or nvl(l_formula.estado, 'N') != 'S' then
         error(-20175, 'La fórmula ' || l_formula.cod_formula || ' no está activa en la empresa.');
      end if;
      if nvl(p_cantidad, 0) <= 0 then
         error(-20174, 'La cantidad a producir debe ser mayor que cero.');
      end if;
      l_sucursal := nvl(l_formula.id_sucursal_destino, p_id_sucursal);
      validar_sucursal(p_id_empresa, l_sucursal, 'Fórmula ' || l_formula.cod_formula);
      l_articulo := articulo(l_formula.id_articulo);

      if p_id_produccion is null then
         select nvl(max(c.nro_produccion), 0) + 1
           into l_nro
           from pdw_produccion_cab c
          where c.id_empresa = to_char(p_id_empresa)
            and c.tip_produccion = co_ref_produccion
            and c.ser_produccion = l_serie;
         insert into pdw_produccion_cab (id_empresa, tip_produccion, ser_produccion, nro_produccion,
                                         id_sucursal, fec_produccion, estado, anulado, id_usuario,
                                         fec_alta, ind_tip_prod, comentario)
         values (to_char(p_id_empresa), co_ref_produccion, l_serie, l_nro,
                 to_char(p_id_sucursal), p_fecha, 'P', 'N', g_usuario,
                 sysdate, 'V', 'Generada desde la planificacion')
         returning id into p_id_produccion;
      elsif estado_produccion(p_id_produccion) != 'P' then
         error(-20103, 'Solo se agregan producidos a órdenes pendientes.');
      end if;

      l_cantidad_ub := round(a_unidad_base(l_formula.id_articulo, l_formula.id_unidad_medida, p_cantidad), 2);
      l_id_lote := lote_defecto(p_id_empresa, l_formula.id_articulo);
      insert into pdw_produccion_producido (id_empresa, id_sucursal, id_articulo, id_unidad_medida,
                                            cantidad, cantidad_ub, id_lote, costo, estado, anulado,
                                            id_produccion_cab, id_formula, desc_articulo,
                                            cant_producir, cant_procesada, cant_diferencia,
                                            ind_tip_prod, de_formula, cantidad_de_formula,
                                            cantidad_ub_de_formula)
      values (p_id_empresa, l_sucursal, l_formula.id_articulo, l_formula.id_unidad_medida,
              p_cantidad, l_cantidad_ub,
              l_id_lote, 0, 'P', 'N',
              p_id_produccion, p_id_formula, substr(l_articulo.descripcion, 1, 200),
              0, 0, p_cantidad,
              'V', 'S', l_formula.cantidad, l_formula.cantidad_ub);
      fin_proceso;
   exception
      when others then
         fin_proceso;
         raise;
   end agregar_a_orden;

   -- ==================================================================
   -- Compras
   -- ==================================================================
   function errores_orden_compra(p_id_pedido_cab in number) return varchar2 is
      l_cab      cmw_pedidos_cabecera%rowtype;
      l_errores  varchar2(4000);
      l_bloquea  varchar2(1) := parametro('PRW_OC_BLOQUEA');
      l_generico number;
      l_marca    varchar2(1);
      l_es_gen   pls_integer;

      procedure agregar(p_texto in varchar2) is
      begin
         l_errores := substr(l_errores || case when l_errores is not null then chr(10) end || p_texto, 1, 4000);
      end agregar;
   begin
      select * into l_cab from cmw_pedidos_cabecera c where c.id = p_id_pedido_cab;

      for d in (select d.id_articulo, a.ind_produccion
                  from cmw_pedidos_detalle d
                  join stw_articulos a on a.id = d.id_articulo
                 where d.id_pedido_cab = p_id_pedido_cab
                   and nvl(d.anulado, 'N') = 'N')
      loop
         l_marca := es_marca(l_cab.id_empresa, d.id_articulo);
         l_generico := generico_de(l_cab.id_empresa, d.id_articulo, l_cab.id_sucursal);
         select count(*) into l_es_gen
           from prw_compuestos_cabecera c
          where c.id_empresa = l_cab.id_empresa and c.id_producto = d.id_articulo and c.estado = 'A';

         if l_marca = 'S' and l_generico is null then
            agregar(descripcion_articulo(d.id_articulo) || ': es marca de un compuesto que no está habilitado en '
                    || descripcion_sucursal(l_cab.id_sucursal) || '. Habilite la sucursal en Artículos Compuestos.');
         end if;

         if nvl(l_cab.ind_produccion, 'N') = 'S' then
            if nvl(d.ind_produccion, 'N') = 'S' and l_marca = 'N' and l_es_gen = 0 then
               agregar(descripcion_articulo(d.id_articulo) || ': está marcado para producción y no tiene compuesto '
                       || 'configurado. Asocie la marca a su genérico en Artículos Compuestos.');
            end if;
         elsif l_bloquea = 'S' and l_marca = 'S' then
            agregar(descripcion_articulo(d.id_articulo) || ': es un insumo de producción y la orden no está marcada '
                    || 'como Producción. Marque la orden o quite el artículo.');
         end if;
      end loop;

      if l_errores is not null then
         l_errores := 'Empresa ' || l_cab.id_empresa || ', sucursal ' || descripcion_sucursal(l_cab.id_sucursal)
                      || ':' || chr(10) || l_errores;
      end if;
      return l_errores;
   exception
      when no_data_found then
         return null;
   end errores_orden_compra;
end prwk_produccion;
/
