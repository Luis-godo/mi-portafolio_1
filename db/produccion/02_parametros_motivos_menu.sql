-- =====================================================================
-- Módulo de producción — 02: parámetros, motivos de stock y menú
-- Ejecutar conectado como INV, después de 01_tablas.sql.
-- Idempotente: no duplica lo que ya existe.
-- =====================================================================
whenever sqlerror exit failure rollback
set serveroutput on

declare
   l_id_modulo bsw_modulos.id%type;

   procedure parametro(p_parametro varchar2, p_valor varchar2, p_descripcion varchar2) is
   begin
      merge into bsw_parametros_generales p
      using (select p_parametro parametro from dual) s
         on (p.parametro = s.parametro and p.id_modulo = l_id_modulo)
       when not matched then
         insert (parametro, id_modulo, descripcion, valor, cod_usuario_aud)
         values (p_parametro, l_id_modulo, p_descripcion, p_valor, 'PRW');
   end parametro;

   procedure motivo(p_cod varchar2, p_ind_ent_sal varchar2, p_descripcion varchar2,
                    p_abreviatura varchar2, p_ind_costo varchar2) is
   begin
      for e in (select id from bsw_empresas) loop
         merge into stw_motivo_ent_sal m
         using (select e.id id_empresa, p_cod cod from dual) s
            on (m.id_empresa = s.id_empresa and m.cod_motivo_ent_sal = s.cod)
          when not matched then
            insert (cod_motivo_ent_sal, ind_ent_sal, descripcion, abreviatura,
                    cod_usuario_aud, id_empresa, activo, ind_costo)
            values (p_cod, p_ind_ent_sal, p_descripcion, p_abreviatura,
                    'PRW', e.id, 'S', p_ind_costo);
      end loop;
   end motivo;
begin
   select id into l_id_modulo from bsw_modulos where cod_modulo = 'PD';

   -- Motivos de entrada/salida. El 80 (Entrada por PRODUCCION) ya existe
   -- en la empresa 121: se reutiliza y se crea en las que no lo tienen.
   motivo('80', 'E', 'Entrada por PRODUCCION',          'EP',    'S');
   motivo('81', 'S', 'Salida de insumos por produccion', 'SPROD', 'N');
   motivo('82', 'E', 'Entrada por conversion',           'ECONV', 'S');
   motivo('83', 'S', 'Salida por conversion',            'SCONV', 'N');
   motivo('84', 'E', 'Entrada por transferencia de art.', 'ETRF', 'S');
   motivo('85', 'S', 'Salida por transferencia de art.',  'STRF',  'N');

   parametro('PRW_MOTIVO_PROD_ENT', '80', 'Motivo ent/sal: entrada de producidos');
   parametro('PRW_MOTIVO_PROD_SAL', '81', 'Motivo ent/sal: salida de insumos de produccion');
   parametro('PRW_MOTIVO_CONV_ENT', '82', 'Motivo ent/sal: entrada de resultados de conversion');
   parametro('PRW_MOTIVO_CONV_SAL', '83', 'Motivo ent/sal: salida de insumos de conversion');
   parametro('PRW_MOTIVO_TRF_ENT',  '84', 'Motivo ent/sal: entrada por transferencia de articulos');
   parametro('PRW_MOTIVO_TRF_SAL',  '85', 'Motivo ent/sal: salida por transferencia de articulos');
   parametro('PRW_SERIE_ENTSAL',    'PR', 'Serie de los ajustes AJS generados por el modulo');
   -- Decisión D-3 pendiente con el área usuaria: valor provisorio.
   parametro('PRW_TOLERANCIA_PORC',   '5', 'Tolerancia de rendimiento en % si la formula no define la suya (PROVISORIO, D-3)');
   parametro('PRW_TOLERANCIA_BLOQUEA', 'N', 'S: un desvio fuera de tolerancia bloquea. N: exige motivo para confirmar');
   parametro('PRW_PERMITE_NEGATIVO',  'N', 'S: permite dejar existencias negativas al confirmar');
   -- Decisión D-1 (recomendada): bloquear.
   parametro('PRW_OC_BLOQUEA',        'S', 'S: una OC con articulos de produccion debe tener IND_PRODUCCION = S');

   dbms_output.put_line('Parametros y motivos: OK');
end;
/

-- ---------------------------------------------------------------------
-- Menú (lo mismo que la página 8/9) y permisos (lo mismo que la 17/18)
-- Las páginas cuelgan de "Definiciones" (1373) y "Movimientos" (1374)
-- del módulo de producción (725). NAV_ID e ID_ACCESO los asignan los
-- triggers BSW_FORMAS_PAGINAS_T1 y BSW_ACCESO_POR_GRUPOS_APEX_SEQ, que
-- pisan cualquier valor: por eso se toman con RETURNING.
-- Acceso completo (insertar, actualizar, borrar, consultar) para el
-- grupo ADMINISTRADOR DEL SISTEMA. Otros grupos se habilitan desde la 17.
-- ---------------------------------------------------------------------
declare
   co_modulo constant varchar2(10) := '725';
   l_id_grupo bsw_grupos_usuarios.id%type;

   -- Nodo padre: solo se crea si falta, sin tocar permisos existentes
   procedure acceso_nodo(p_nav_id number) is
   begin
      insert into bsw_acceso_por_grupos_apex (id_grupo, pagina_id, permiso, id_modulo)
      select l_id_grupo, p_nav_id, 1, co_modulo
        from dual
       where not exists (select null
                           from bsw_acceso_por_grupos_apex a
                          where a.id_grupo = l_id_grupo
                            and a.pagina_id = p_nav_id);
   end acceso_nodo;

   procedure acceso(p_nav_id number) is
   begin
      merge into bsw_acceso_por_grupos_apex a
      using (select l_id_grupo id_grupo, p_nav_id pagina_id from dual) s
         on (a.id_grupo = s.id_grupo and a.pagina_id = s.pagina_id)
       when matched then
         update set a.permiso = 1, a.puede_insertar = 'S', a.puede_actualizar = 'S',
                    a.puede_borrar = 'S', a.puede_consultar = 'S'
       when not matched then
         insert (id_grupo, pagina_id, permiso, puede_insertar, puede_actualizar,
                 puede_borrar, puede_consultar, id_modulo)
         values (l_id_grupo, p_nav_id, 1, 'S', 'S', 'S', 'S', co_modulo);
   end acceso;

   procedure pagina(p_page_no varchar2, p_nombre varchar2, p_padre number,
                    p_tipo_pagina varchar2, p_menu varchar2) is
      l_nav_id bsw_formas_paginas.nav_id%type;
   begin
      select max(nav_id) into l_nav_id from bsw_formas_paginas where page_no = p_page_no;
      if l_nav_id is null then
         insert into bsw_formas_paginas ("LEVEL", nav_name, page_no, parent_id,
                                         id_modulo, tipo_pagina, mostrar_menu)
         values ('3', p_nombre, p_page_no, p_padre, to_number(co_modulo), p_tipo_pagina, p_menu)
         returning nav_id into l_nav_id;
      end if;
      acceso(l_nav_id);
      dbms_output.put_line('Página ' || p_page_no || ' -> NAV_ID ' || l_nav_id);
   end pagina;
begin
   select g.id
     into l_id_grupo
     from bsw_grupos_usuarios g
    where upper(g.descripcion) = 'ADMINISTRADOR DEL SISTEMA';

   -- Nodos padre del menú, como hace la página 18 (módulo y tipo de página)
   acceso_nodo(1372);
   acceso_nodo(1373);
   acceso_nodo(1374);

   pagina('1700', 'Artículos Compuestos',           1373, '1', 'S');
   pagina('1701', 'Carga de Artículo Compuesto',    1373, '1', 'N');
   pagina('1702', 'Conversiones',                   1374, '2', 'S');
   pagina('1703', 'Carga de Conversión',            1374, '2', 'N');
   pagina('1704', 'Transferencias de Artículos',    1374, '2', 'S');
   pagina('1705', 'Carga de Transferencia',         1374, '2', 'N');
   pagina('1706', 'Planificación de Producción',    1374, '2', 'S');
   pagina('1707', 'Controles de Producción',        1374, '2', 'S');

   dbms_output.put_line('Menú y permisos del grupo ' || l_id_grupo || ': OK');
end;
/

-- STWK_EXISTENCIA exige el tipo de comprobante AJS en la empresa del
-- movimiento. Se informa (no se crea: es configuración del módulo de stock).
select 'ATENCION: la empresa ' || e.id || ' (' || e.descripcion
       || ') no tiene el tipo de comprobante AJS: el módulo no podrá mover stock en ella.' aviso
  from bsw_empresas e
 where not exists (select null from bsw_tipos_comprobantes t
                    where t.tip_comprobante = 'AJS' and t.id_empresa = e.id);

commit;
