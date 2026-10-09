# Módulo de producción — despliegue

Paquete `PRWK_PRODUCCION`, tablas `PRW_*` corregidas, ocho páginas nuevas
(1700–1707) y cambios en las páginas 7, 513, 515 y 741. El diagnóstico que
justifica cada decisión está en `docs/produccion/01-fase1-diagnostico.md`.

## Qué resuelve

| Necesidad | Dónde |
|---|---|
| Artículos compuestos: varias marcas = un insumo genérico, por sucursal, con equivalencia (bolsa de 25 kg → 25) | Páginas 1700/1701, `PRW_COMPUESTOS_*` |
| Recepción de compras de producción como insumo genérico, con el costo de la compra | Página 1702 → "Generar desde la compra" |
| Conversión con costo (por % o por cantidad, con gastos) | Página 1703, tipo C |
| Conversión sin traslado automático (desposte: 50 kg carne → 40 carne + 10 sebo) | Página 1703, tipo S |
| Transferencia entre artículos o sucursales, con costo de la compra que corrige | Páginas 1704/1705 |
| Planificación por demanda (sugerencia, no mueve stock) | Página 1706 |
| Producción: insumos por receta escalada, consumo real, rendimiento con tolerancia, confirmación y anulación | Página 741 + paquete |
| Orden de compra con artículos de producción sin marcar (decisión D-1) | Página 7 |
| Controles: rendimiento, saltos de costo, compras sin convertir, configuración incompleta, inconsistencias, trazabilidad | Página 1707 |

## Reglas de diseño

- **Stock solo por el mecanismo oficial.** Cada movimiento genera un ajuste
  `STW_ENTSAL` (`AJS`, serie `PR`, con referencia al documento: `TIP_REFERENCIA`
  `CNV`/`TRF`/`PRO`, `SER_REFERENCIA` `CONF`/`ANUL`). El trigger del detalle lo
  pasa por `STWK_EXISTENCIA`. El paquete **verifica la existencia antes y
  después de cada línea**: si el delta no es exactamente el esperado, revierte
  todo (`ORA-20192`). Así se cubre que las reglas de signo de `STWK_EXISTENCIA`
  no se pudieron leer.
- **Unidades validadas**: `STW_PKG.TRAE_MULT_UB` devuelve la cantidad sin
  convertir si el artículo no tiene la unidad. El paquete verifica la relación
  antes de usarla (`ORA-20114`): 80 bolsas nunca pasan como 80 kg.
- **Un solo criterio de costo**: promedio ponderado en unidad base sobre las
  sucursales que manejan stock, igual que la confirmación de compras. Se
  actualizan `COSTO_PROM`/`COSTO_ULTIMO` (y sus `_GS`) y se registra en
  `STW_HIST_COSTOS_ART`. Las salidas no cambian el promedio.
- **Anulación**: movimientos inversos más restauración del costo, **solo si
  ningún movimiento posterior cambió el costo** del artículo. Si lo cambió, la
  anulación se rechaza (`ORA-20160`): recalcular hacia atrás inventaría un
  costo.
- **Sin COMMIT en el paquete.** Cada confirmación o anulación abre un
  `SAVEPOINT` y vuelve a él si algo falla.
- **Concurrencia**: `SELECT … FOR UPDATE NOWAIT` sobre la cabecera, control de
  estado bajo bloqueo (doble confirmación imposible) y bloqueo de las filas de
  existencia mientras se verifica el movimiento.
- **Triggers solo de integridad**: impiden editar documentos confirmados o
  anulados y borrar fórmulas usadas. Ninguno mueve stock ni costo.
- **Receta escalada**: insumo = cantidad del ingrediente × (producido /
  cantidad de referencia de la fórmula). El trigger anterior no dividía por la
  referencia (en la fórmula 258, de 110 unidades, descontaba 110 veces de más).

## Antes de desplegar (bloqueantes)

1. ~~Leer `STWK_EXISTENCIA`~~ (P-01, resuelto con el fuente que pasó el
   usuario): el signo de un `AJS` sale del motivo (E suma, S resta), el stock
   no se commitea dentro del paquete y solo el log (`STW_LOG_EXISTENCIAS`) va
   en transacción autónoma. Exige el tipo de comprobante **`AJS` en la
   empresa**: hoy solo existe en la 121. Para usar el módulo en la 221 hay que
   crearlo (el script 02 lo advierte y el paquete lo valida).
2. **Conciliar la orden 628 y los ajustes 10–13 y 24** (P-04): los generaron
   los triggers legados y la página 768.
3. **Revisar las decisiones provisorias** (sección 2.4 del diagnóstico):
   `PD.PRW_TOLERANCIA_PORC` = 5 % provisorio (D-3), `PD.PRW_OC_BLOQUEA` = S
   (D-1), costo de subproductos al informado o al promedio vigente (D-2).
4. Las tablas `PRW_*` actuales se **borran y recrean** (01). El script se
   detiene si alguna tiene filas. Avisar a quien las creó.

## Orden de despliegue

Conectado como `INV`, en este orden, en la misma ventana:

| Paso | Script | Reversible |
|---|---|---|
| 1 | `01_tablas.sql` | Sí (90) mientras no haya documentos |
| 2 | `02_parametros_motivos_menu.sql` — motivos, parámetros, menú (como la página 8) y acceso total del grupo ADMINISTRADOR DEL SISTEMA (como la 17) | Sí (90) |
| 3 | `03_prwk_produccion.pks` y `04_prwk_produccion.pkb` — después `show errors` | Sí (90) |
| 4 | `05_integridad_y_vistas.sql` | Sí (90) |
| 5 | `06_triggers_legados.sql` | Sí (90 los reactiva) |
| 6 | Import APEXlang de la aplicación (páginas nuevas y modificadas) | Reimportar la versión anterior |
| 7 | `07_pruebas.sql` en una copia de la base | — |

Los pasos 5 y 6 van juntos: con los triggers legados desactivados y la 741
anterior, "Generar" en la 768 seguiría creando ajustes sin confirmar la orden.

### Aplicación

Las páginas nuevas no se pueden subir de a una (`apex-importar-pagina` solo
reemplaza páginas existentes y no se generan llamadas `wwv_flow_imp_*`), así
que va el **import completo** de APEXlang:

1. `apex-exportar-lang` y comparar contra `src/`: cualquier cambio hecho en el
   App Builder desde el último sync se pierde en el import.
2. Si hay correcciones de página pendientes (la página 185), llevarlas a `src/`
   antes. **No correr `apex-sync` con trabajo sin commitear en `src/`**: borra
   la carpeta antes de exportar.
3. Commit y push del estado a desplegar.
4. `apex-importar-lang` con aprobación.
5. `apex-sync`: el diff tiene que salir vacío salvo los identificadores que
   asigna APEX.

## Después de desplegar

```sql
select object_name, object_type, status from user_objects
 where object_name like 'PRW%' or object_name like 'PDW_PRODUCCION%PROTEGE' or object_name = 'PDW_FORMULA_CAB_PROTEGE';
select trigger_name, status from user_triggers where trigger_name like 'ACTUALIZA_%PRODUC%';
```

La página 1707 (Controles) muestra desde el primer día compras sin convertir,
configuración incompleta y documentos inconsistentes.

## Verificación hecha sin desplegar

- Cuerpo del paquete compilado como bloque anónimo contra la base. Corrigió dos
  errores de sintaxis SQL y las llamadas a funciones privadas dentro de SQL
  (`PLS-00231`). Lo que queda son los objetos que crea este mismo despliegue y el
  permiso de `CLAUDE_INV` sobre `STW_PKG`. Oracle corta la lista de errores
  semánticos, así que **la compilación definitiva es la del paso 3** (`show errors`).
- Consultas de la planificación, de las vistas de rendimiento y trazabilidad, de
  los costos de compra y de las LOV, ejecutadas contra datos reales.
- Comprobaciones estáticas de CLAUDE.md sobre las páginas nuevas y modificadas:
  sin referencias rotas, sin IDs numéricos, sin identificadores internos
  emitidos, sin `null`, con `refresh` con destino y llaves balanceadas.
- **No se corrió `apex validate`** (requiere autorización).
