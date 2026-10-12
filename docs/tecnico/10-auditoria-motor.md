# Auditoría del motor — lote D35–D76 (D77)

Fecha: 2026-09-15. Base: `f91bacf` (D75/D76). Objetivo del contrato D77:
revisar que el lote FUNCIONE, que los tests TENGAN SENTIDO y dejar el código
pulido — sin features nuevas ni cambios de comportamiento.

---

## 1. Metodología

1. **Salud de suite**: `MIX_ENV=test mix test` ×2 (flakiness), anotando
   tiempos; `mix format --check-formatted`; `mix compile --warnings-as-errors`.
2. **Calidad de tests**: lectura archivo por archivo de los ~34 archivos de
   test del lote contra tres criterios: (a) ¿asertan comportamiento público
   (mensajes ES, hp, pools, world) y no internals?, (b) ¿rollers
   deterministas con números exactos y conteo de dados consumidos?, (c) ¿
   cubren las interacciones que los ADRs declaran?
3. **Código**: invariantes de arquitectura verificados con `rg` (D6/D31);
   lectura de `Actions.ex`/`World.ex` en busca de bloques privados cohesivos
   y puros extraíbles mecánicamente; duplicación de validación; docstrings.
4. **Docs**: numeración/estado de ADRs D35–D76, M-numbers del catálogo,
   contadores de progress/plan-fases/AGENTS.
5. Extracciones ejecutadas SOLO donde eran copiar+delegar con la suite como
   red; tests añadidos SOLO para interacciones prometidas por ADRs.

## 2. Salud de suite (resultado)

| Chequeo | Resultado |
|---|---|
| `mix test` corrida 1 (pre-cambios) | **1500 passed, 3 excluded** — 11,2 s |
| `mix test` corrida 2 (pre-cambios) | **1500 passed, 3 excluded** — 11,3 s |
| `mix test` corrida 3 (post-cambios) | **1511 passed, 3 excluded** |
| `mix format --check-formatted` | limpio |
| `mix compile --warnings-as-errors` | limpio |

**Los 3 excluded**: `test/dragonex/flows/live_smoke_test.exs` (1 test) y
`test/dragonex/flows/live_dm_test.exs` (2 tests), ambos `@moduletag
:integration` — opt-in con `DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=...`
(`--include integration`), exactamente como documenta AGENTS.md. Son humo
contra un LLM real: excluirlos por defecto es lo contratado, no flakiness.

**Observación menor (fuera de alcance)**: los tests LiveView de hero imprimen
warnings de Phoenix (`form with phx-change but missing id` en el form
`/logout` del layout). Es cosmético y de la capa web (no del motor); no se
toca en D77.

## 3. Calidad de tests — veredicto por archivo

Criterio de etiqueta: **OK** = cumple los tres criterios; **gap-cubierto** =
cumplía pero le faltaba alguna interacción declarada en su ADR (añadida
aquí); no hubo consolidaciones (no se encontró duplicación clara que valiera
la pena: los fixtures por-archivo son intencionalmente autocontenidos para
`async: true`).

| Archivo | ADR | Etiqueta | Notas |
|---|---|---|---|
| `second_wind_test` | D45 | OK | Exacto (1d10+level, cap, rests, guards). |
| `action_surge_test` | D47 | OK | Miss también marca; no-marca en error. |
| `divine_smite_test` | D46 | OK | Extra Attack sólo primer swing; expiry completo. |
| `lay_on_hands_test` | D49 | OK | applied=min(...); long-rest-only. |
| `divine_sense_test` | D52 | OK | Scan por raza; gasta aunque vacío. |
| `turn_undead_test` | D53 | OK | DC 8+prof+SAB; ambos rests. |
| `arcane_recovery_test` | D51 | OK | Greedy alto→bajo; fuera de combate. |
| `bardic_inspiration_test` | D50 | OK | Los 4 consumidores del d6. |
| `flurry_of_blows_test` | D54 | OK | N=2 fijo; dado por nivel; mid-fall omite. |
| `hunters_mark_test` | D55 | OK | +1d6 vs presa, crit dobla, RollLog. |
| `font_of_magic_test` | D56 | OK | Costes RAW; cap silencioso con mensaje real. |
| `cunning_action_hide_test` | D57 | OK | Ventaja→sneak gratis; revela (hit/miss/hechizo). |
| `danger_sense_test` | D58 | OK | Conteo de dados prueba ventaja/cancelación. |
| `evasion_test` | D59 | **gap-cubierto** | +1 test: éxito gracias a inspiración bárdica activa Evasión (D59×D50). |
| `skill_checks_test` | D60/D73 | OK | JoaT nunca solapa con prof/expertise. |
| `paladin_auras_test` | D61/D62 | OK | Apilado, CHA<10 sin piso, death saves, turn_undead, concentración, no-op idempotente. |
| `wild_shape_test` | D63 | OK | Auto-revert con exceso exacto; temp_hp; bloqueo hechizos. |
| `uncanny_dodge_test` | D64 | OK | Mitad antes de resist/temp; apila con Evasión (cuarto). |
| `metamagic_test` | D65 | OK | Empowered sin duplicar rerolls en crit; twinned 1 casilla/1 concentración. |
| `racial_traits_test` | D66/D67 | OK | Lucky sólo dado conservado; RE tras revert y tras dodge. |
| `indomitable_savage_test` | D68/D69 | **gap-cubierto** | +1 test: aura re-sumada en el reroll (D68×D61). |
| `breath_gnome_test` | D70/D71 | **gap-cubierto** | +6 tests: aliento × concentración-del-objetivo / Danger Sense / Lucky / inspiración / aura / Indomitable (el stack completo que D77 declara). |
| `rage_uses_test` | D72 | OK | Furia implacable antes de RE racial; aura en la CON. |
| `expertise_test` | D73 | OK | 2×prof en las dos rutas (check y hide); cupo por nivel. |
| `upcast_test` | D74 | **gap-cubierto** | +3 tests: casilla de pacto del brujo (D74×D40), Twinned con cast_level (D74×D65), Empowered sobre dados combinados (D74×D65). |
| `poison_test` | D75/D76 | OK | Conteo de dados; cuarto (mitad×mitad); Heightened cancela. |
| `conditions_test` + `rules/conditions_test` | M06 | OK | Cancelación 5e y auto-fails. |
| `concentration_test` | D37 | OK | DC max(10, dmg/2); inmunidad no fuerza save. |
| `sneak_attack_test` | D41 | OK | Aliado consciente; desventaja nunca; crit 2N d6. |
| `reckless_attack_test` | D44 | OK | Expira al empezar su turno. |
| `fighting_style_test` | D48 | OK | Archery/defense/dueling. |
| `rage_test` | D42 | OK | Bonus melee-only; overlay resistencias. |
| `grant_xp_test` | D43 | OK | Mensaje con umbral y can_level_up?. |
| `spell_slots_test` | D40 | OK | Pact Magic completa. |
| `actions_test` | D35/D36/D38/D39 | OK | Mid-action target-fall; tie DEX→nombre. |

**Total: 11 tests añadidos** (todos de interacciones prometidas por ADR),
0 eliminados, 0 consolidados.

## 4. Código — mantenibilidad y arquitectura

### 4.1 Invariantes verificados (rg) — TODOS se cumplen

- `Rules.*` no referencia `Actions`/`World`/`Tools` en código (solo
  menciones en docstrings, que son documentación deliberada del contrato).
- `World` no referencia `Actions`/`Tools` en código (ídem docstrings).
- `Tools` es delgado: cada `deftool` es assert + `propose(ctx, Actions...)`.
- LiveView no toca `Repo` ni escribe `world` (D6): sólo pasa `@world` a
  componentes.

### 4.2 Extracciones hechas (las claramente mecánicas)

**`Dice.parse_expr/1` — gramática de dados única.** La regex
`^(\d+)d(\d+)(?:([+-])(\d+))?$` estaba replicada en 4 sitios: `Dice.roll_expr`
(y su evaluación inline), `Dice.valid?`, `Rules.Upcast.parse` (privado,
idéntico a…) y `Actions.parse_dice_expr` (privado). Extracción: parser
público `Dice.parse_expr/1` que devuelve `{count, sides, mod}`; `roll_expr`
y `valid?` lo reusan (attr `@dice_expr`); `Rules.Upcast` y `Actions`
delegan y se borran las copias. Misma regex, mismos mensajes de error, cero
cambio observable.

*Desviación del contrato (documentada en D77)*: la casa es `Dice`, no un
`Rules.*` existente — es donde ya vivía la gramática que consumían
`roll_expr`/`valid?`, y meter el parser en `Rules.Combat` habría añadido
acoplamiento sin quitar duplicación.

**No extraídas a propósito** (revisadas y descartadas):
- `Rules.Combat.parse_dice/1` (sólo `NdM`, error "weapon dice"): su
  estrechez es un feature (D75: un `3d8+3` en `dice` de arma debe petar).
- `Actions.simulate_damage/2`: replica deliberadamente SOLO las capas
  resist+temp_hp de `World.apply_damage` (sin revert/Furias implacables)
  para calcular DCs de concentración y tracking multi-golpe (D76 exige la
  coherencia con `incoming_damage`, no con todo el pipeline). Moverla
  sugeriría que es "la" simulación canónica del pipeline completo.
- `Actions.empowered_roll/3` y `dice_with/3`: dependen del shape de
  `%Spell{}` y del flag metamagic; quedaron en 5 líneas tras delegar el
  parser.

### 4.3 Deuda técnica encontrada (con propuesta, NO ejecutada)

1. **Validación repetida en `Actions`** (~25 sitios): el patrón
   `case World.character(world, who) do nil -> {:error, "no existe…"} …`
   con mensajes por-feature. **Por qué no se extrajo**: cada ADR fija el
   ORDEN de validación (p. ej. D55: who/target existen → who vivo → ranger
   L2+ → target vivo → casilla → concentración) y un helper genérico
   (`with_character/3`) obligaría a re-verificar los 25 órdenes uno a uno
   contra sus ADRs — no es mecánico. **Propuesta**: introducir
   `Actions.fetch/2` + pipeline `with` por feature en una pasada dedicada
   con tabla de órdenes en el PR.
2. **Bloque de formato ES en `Actions`** (~200 líneas: `describe_swing`,
   `format_attack_message`, `check_parts`, `*_tag`, `aura_bit`, `mode_tag`,
   `ability_es`…). Cohesivo y puro, pero su casa natural es un presenter
   (`Actions.Format` o `Narration`), que no es un `Rules.*` existente.
   **Propuesta**: extraer como módulo propio en el mismo refactor que el
   ítem 1 (suite como red; son funciones puras de string).
3. **`Actions.ex` ~3.3k líneas**: la raíz es que cada feature D35–D76 trae
   validación + resolución + mensaje. Los ítems 1–2 lo dejarían en ~2.8k
   sin cambiar responsabilidades. No hay bloques PUROS grandes restantes
   que pertenezcan a `Rules.*` (lo que queda es orquestación con RollLog/
   World, que es su razón de ser).
4. **Pasivas raciales/de clase dispersas**: `evasion?/2`,
   `gnome_cunning?/2`, `dwarven_resilience?/2`, `dragonborn?/1` viven como
   privados de `Actions`. No hay módulo `Rules.Races`; crearlo es una
   decisión de estructura nueva (no mecánica) → queda propuesta para un
   D futuro si siguen entrando razas.

### 4.4 Docstrings/comentarios

Revisados los moduledocs de `World` (lista de invariantes por feature —
vigente, incluye D72/D76), `Actions`, `Tools`, `Rules.*` y el comentario del
pipeline de `apply_damage` (orden D76 correcto: dodge → resist → temp → hp →
revert → Furia implacable → RE). Sin descuadres encontrados; los que citaban
tests eran los docs de producto (ver §5).

## 5. Docs consistencia

| Doc | Chequeo | Acción |
|---|---|---|
| `decisions.md` | D1–D77 sin huecos ni duplicados; D35–D76 todos `Aceptada` | ✅ + añadido D77 |
| `tecnico/08-catalogo-mecanicas` | M1–M60 sin duplicados, alineado con D35–D76 | ✅ sin cambio |
| `progress.md` | contador decía 1500 (era el real pre-audit) | actualizado a 1511 + puntero a este informe |
| `producto/03-plan-fases` | decía "1041 tests passed" (obsoleto) | actualizado a 1511 |
| `AGENTS.md` | decía "941 passed"; 8 migraciones ✓; comandos ✓ | contador → 1511 |
| `tecnico/09-estrategia-pruebas` | decía "941 passed" (2 sitios) | → 1511 |

## 6. Veredicto final

- **Implementado y probado**: salud de suite (2 corridas idénticas, format y
  compile limpios), revisión de los 34 archivos de test del lote (etiquetas
  arriba), invariantes de arquitectura, 1 consolidación mecánica de
  duplicación (`Dice.parse_expr`), 11 tests de gaps ADR, realineación de
  contadores en 4 docs, D77 en decisions.md y este informe.
- **Pendiente (deuda propuesta, no bloqueante)**: helper de validación con
  órdenes por ADR, presenter de mensajes ES, y eventual `Rules.Races`. Ninguna
  afecta comportamiento; todas tienen receta en §4.3.
- **Cero cambios de comportamiento**: la suite de behaviour pasó igual
  (1500 → 1511 por los tests añadidos; ninguno eliminado).

---

## 7. Auditoría de invariantes — 5e 2014 / SRD 5.1 (D80)

Fecha de inicio: 2026-09-16. Alcance: `Rules`, `Actions`, `World`, ficha y
persistencia de sus estados. Las garantías se verifican con dados inyectados,
sin depender de que el invocador elija bien sus acciones.

### Primera pasada: garantías verificadas

| Invariante | Cobertura |
|---|---|
| Estabilizar borra fallos; daño posterior rompe estabilidad y reinicia el contador | `stabilization_test.exs`, incluye críticos, daño cero y Codec |
| Curación ordinaria no resucita muertos | `engine_lifecycle_test.exs`: World, curación por dados, conjuro y Manos impositoras |
| Curación y descanso corto nunca restan PG | Tiradas con modificadores negativos y rechazo de curación negativa directa |
| Un muerto, estable o consciente no puede recibir una nueva salvación de muerte | Validación también al aplicar el resultado en World |
| Daño cero y daño a un semi-orco ya caído no disparan Resistencia implacable | Casos negativos y caída real como control positivo |
| Caer efectivamente a 0 PG elimina concentración | Ruta directa World; sobrevivir a 1 no la borra automáticamente |
| Actores incapacitados no ejecutan acciones, bonus o reacciones | `action_incapacitation_test.exs`: 18 entradas Actions × 5 condiciones, más comandos World |
| Preparar una acción no autoriza ejecutarla después de quedar incapacitado | Revalidación de actor en el cambio devuelto por Actions |
| Manos impositoras no gasta una reserva insuficiente ni revive muertos | Revalidación de reserva/objetivo al aplicar; cura legal a un aliado caído |

Las regresiones originales se ejecutaron fallando antes de las correcciones.
Se corrigieron también fixtures que permitían autocurarse a 0 PG y atacar
estando aturdido. Decisión: D80.

Verificación posterior: `MIX_ENV=test mix test` → **1594 passed, 3 excluded**;
`mix compile --warnings-as-errors`, `mix format --check-formatted` y
`git diff --check` correctos. La suite web sigue emitiendo avisos de
formularios; la compilación del código modificado no emite warnings.

### Siguientes frentes, todavía no certificados

1. **Unificar daño y concentración.** `Actions.simulate_damage` calcula una
   proyección para salvaciones; `World.apply_damage` tiene capas adicionales
   (Uncanny Dodge, Wild Shape, Relentless). Revisar secuencias combinadas y
   evitar que ambas rutas discrepen en PG, CD, consumo o número de tiradas.
   El fix de caída a 0 no certifica las salvaciones de toda esta combinación.
2. **Economía de acciones y recursos.** Hoy hay simplificaciones explícitas:
   una tool representa una acción, pero no hay presupuesto completo de
   acción/bonus/reacción por turno. Revisar repetición de ataques, posturas,
   rasgos una vez por turno y todas las reservas entre preparación/aplicación.
   La revalidación de actor no revalida automáticamente cada recurso.
3. **Descansos.** El descanso corto tira un dado, pero falta contabilidad
   completa de dados de golpe restantes, recuperación y restricciones
   temporales. El mínimo de curación 0 no cierra ese subsistema.
4. **Condiciones y duración.** Auditar fin/inicio de turno, inmunidades,
   desaparición de efectos al acabar concentración, y distancias/rangos que
   el modelo de mundo actual no representa.
5. **Catálogo y progresión.** Distinguir hechizos con texto descriptivo de
   efectos ejecutables; contrastar tablas de clase/nivel y acumulación de
   bonificadores con oráculos SRD independientes.
6. **Entradas inválidas.** Completar validación de expresiones de dados,
   rangos numéricos, objetivos y operaciones repetidas en todas las entradas.

Estas áreas mezclan limitaciones deliberadas y riesgos de incoherencia que
requieren reproducción. No se presentan como bugs ya corregidos ni como
reglas cubiertas por el simple hecho de que la suite esté verde.

## 8. Segunda pasada — tres frentes implementados (D81–D83)

Verificación: **1632 passed / 3 excluded** (`MIX_ENV=test mix test`),
`mix compile --warnings-as-errors`, formato y diff correctos. Son 38 pruebas
nuevas respecto al cierre de D80 (1594). La suite conserva avisos de tests
preexistentes y formularios LiveView; la compilación pasa sin warnings.

Los puntos 1–3 anteriores ya tienen implementación y regresiones específicas:

- **Daño/concentración**: `Damage` prepara usando `World.apply_damage`, conserva
  resultados sin repetir dados y rechaza objetivos modificados. Ataque Extra
  resuelve y aplica las capas de cada impacto antes de calcular el siguiente;
  smite va dentro del impacto con su propio tipo, no después de todos los golpes.
- **Economía**: `TurnBudget` controla acción, bonus, reacción, death save y
  marca de furtivo. Distingue turno propio e interrupción; un handoff repetido
  o una carga de partida no da recursos nuevos. Controla bonus spells en ambos
  órdenes y su alcance por turno global. Cambios obsoletos de recursos/turno
  requieren preparar otra vez. Los comandos de arbitraje/los setters no se
  convierten en acciones de personaje.
- **Descansos y duración**: `Rest` contabiliza dados gastados y el límite diario.
  `WorldClock` caduca las representaciones mecánicas existentes según tiempo
  explícito. Los descansos de grupo avanzan el reloj una sola vez. Short rest
  recarga la CD de Relentless Rage y la inspiración de bardos L5+. Long rest
  devuelve hasta la mitad de dados y termina PG temporales.

Pruebas: `damage_pipeline_test.exs`, `turn_budget_test.exs`,
`rest_clock_test.exs`, `flows/rest_clock_test.exs`; este último ejecuta las
nuevas tools con TestModel y comprueba el estado, incluida la firma antigua
de short_rest sin número de dados. Las pruebas incluyen JSON real de ida/vuelta.

### Alcance que sigue siendo explícito

- Las 319 entradas del catálogo no equivalen a 319 efectos implementados.
  D85 implementa Bless y sus objetivos vinculados al conjurador; caducar
  concentración no implementa por sí solo el resto de efectos secundarios.
- Se conservan aproximaciones documentadas de D35–D76 (distancia/posicionamiento,
  Esquiva asombrosa como postura para cualquier fuente, efectos de clase
  parciales). Un lanzamiento de varias acciones se rechaza en combate; no
  existe todavía una máquina de lanzamiento sostenido.
- Slots de las partidas normales se inicializan con `World.init_spell_slots`.
  Sigue la compatibilidad antigua de mundos auxiliares sin seguimiento de
  slots; esta pasada no convierte un mundo no inicializado en una ficha válida.
- Tiempo explícito no es un simulador de viajes o de interrupciones de descanso.
  Las condiciones sin duración/fuente conocida necesitan retirada explícita.
  Custom sin metadatos usa el contrato de acción ordinaria, sin duración inventada.
- En jsonb antiguo no hay datos para reconstruir gastos previos ni tiempo
  restante exacto: D83 especifica la inicialización conservada. Los snapshots
  nuevos sí preservan los contadores exactos.

## 9. Consolidación y recorrido persistido — 2026-09-26

- Base comprobada al retomar: **1634 passed / 3 excluded**.
- Reproducido antes del fix: preparar un ataque contra un objetivo concentrado,
  gastar después su Inspiración o Indomitable y aplicar el ataque aceptaba
  una salvación apoyada en un recurso ya consumido. `Damage.prepare` ahora
  revalida ambos campos. Las rutas de hechizo/aliento conservan la ficha
  previa a su salvación para distinguir gasto propio y cambio externo (D81).
- Dos regresiones en `damage_pipeline_test.exs`; los 87 casos de daño,
  concentración, aliento y `indomitable_savage_test` pasan juntos.
- `game_engine_journey_test.exs`: crea héroe desde el builder y partida en
  Postgres; gasta acción incluso fallando, rehidrata un Game, reanuda hasta
  espera humana y pausa; comprueba luego descanso corto, segundo arranque,
  dados agotados, caducidad original, descanso largo y tercer arranque con
  límite diario conservado. Las transiciones de reglas se preparan con el
  Game detenido; las escrituras del proceso usan su API pública.
- Verificación final del lote: **1637 passed / 3 excluded**, compilación
  con `--warnings-as-errors` correcta. Es una verificación offline del motor
  y persistencia; el playtest visual y con LLM real sigue en la cola actual
   de `producto/03-plan-fases.md`.

## 10. Efectos ejecutables — Heal (D87), 2026-09-26

- Curación plana 70–100 PG, límites y limpieza de condiciones explícitas;
  no se confunde catálogo descriptivo con reglas implementadas.
- Revalidación de objetivos y recursos, una acción/casilla y Twinned sin
  curación doble sobre el mismo objetivo. Codec conserva PG y limpieza.
- 14 pruebas nuevas: 12 oráculos puros, un smoke PCAgent/TestModel y un
  recorrido Postgres/Game que conserva la acción gastada y los plazos restantes.
- Suite completa: **1693 passed / 3 excluded**; compilación con warnings-as-errors,
  formato global y diff correctos. Permanecen las demás áreas abiertas de §7
  y el playtest integrado del producto.

## 11. Estabilización por conjuro — Spare the Dying (D88), 2026-09-26

- Reproducciones previas: el truco devolvía texto sin cambiar los contadores;
  PCAgent pedía `make_death_save` al estable pese al rechazo correcto del motor.
  Ambas comprobadas en rojo antes de implementar.
- Estabilización explícita conserva PG/condiciones, borra fallos y no gasta
  el presupuesto de muerte del receptor. Valida criatura viva a 0 PG y las
  exclusiones del conjuro; Twinned no estabiliza dos veces al mismo objetivo.
- 13 pruebas nuevas: 11 casos puros, smoke PCAgent/TestModel y Postgres/Game.
  Cubren acciones, recursos, cambios obsoletos, compatibilidad con bonus spell,
  persistencia y daño/curación posteriores.
- Suite completa: **1706 passed / 3 excluded**; compile con warnings-as-errors,
  formato global y diff correctos. No añade recuperación automática del
  inconsciente tras 1d4 horas ni cierra la auditoría completa del motor.

## 12. False Life — escalado y ciclo de PG temporales (D89), 2026-09-26

- Reproducido antes del cambio: casilla nivel 2, d4=3 → 7 PG temporales;
  el oráculo exige 12. Ahora escala +5 por nivel superior con un solo dado.
- Valida objetivo propio y evita la duplicación por Twinned al nombrar otro.
  Conserva la política de mayor valor: menor/igual no renueva el plazo,
  mayor reemplaza fuente y duración. PG reales y concentración intactos.
- 13 pruebas nuevas: 11 casos puros, PCAgent/TestModel y Postgres/Game;
  interacciones con RollLog, daño, descanso largo, metamagia y estados obsoletos.
- Suite: **1719 passed / 3 excluded**, compile con warnings-as-errors,
  formato global y diff correctos. No se certifican otros efectos descriptivos
  ni el playtest de producto pendiente.

## 13. Lesser Restoration — selección de condición (D90), 2026-09-26

- Reproducido antes del cambio: lanzarlo sobre `poisoned` gastaba casilla y
  dejaba la condición. Ahora elimina exactamente una condición elegible y su plazo.
- Selección explícita ante ambigüedad; errores no gastan recursos. Revalida
  personajes/plazos antes de aplicar y conserva efectos no seleccionados.
- 18 pruebas nuevas: motor (15), PCAgent/TestModel con JSON anterior/nuevo (2)
  y Postgres/Game (1). Suite **1737 passed / 3 excluded**; compile sin warnings
  y formato global correctos. No cierra la auditoría ni el playtest real pendiente.

## 14. Imposición de manos — purificación (D91), 2026-09-26

- Cierra la limitación explícita de D49/M33: veneno/enfermedad por 5 puntos
  cada condición, combinables con curación en una acción. Mantiene el modelo
  abstracto de condiciones y las llamadas anteriores.
- 13 pruebas nuevas cubren coste combinado, curación efectiva, cero PG,
  selección/estado inválido, self, descanso largo, control de actor y persistencia.
- Última suite: **1750 passed / 3 excluded**; compile con warnings-as-errors,
  formato global y diff correctos.
- Incidencia de verificación pendiente de endurecer: primera suite tuvo una
  colisión `users_email_index` en `ProtectedRoutesTest` con su fixture basada
  en `System.unique_integer`. Aislada: 3 passed; repetición completa: verde.
  No atribuida a purificación ni corregida en este lote.

## 15. Primer corte jugable — navegador + proveedor real (D92), 2026-09-26

- V1.1–V1.4 verificados con alcance documentado en
  `producto/05-cierre-version-jugable.md`: registro/login, builder, combate de
  arena, microaventura con final narrativo, Segundo aliento/descanso,
  pausa/recarga/reanudación y mesa móvil/escritorio.
- Dos regresiones UI reproducidas antes del fix: ficha móvil ausente en
  exploración solo y banner/«Actuar» visibles durante pausa. Corregidas junto
  al nombre accesible del input en `GameLive.Components`; test nuevo
  `mobile_player_sheet_test.exs` (un caso con recorrido de pausa).
- **1751 passed / 3 excluded**, compile con warnings-as-errors y formato
  correctos. `game_engine_journey_test.exs` complementa el recorrido real con
  daño al héroe, dados agotados y reinicios de Game deterministas.
- Latencia real de turnos y consistencia narrativa son el siguiente foco.
  La aprobación de este corte no cierra la auditoría completa del motor.

## 16. Mejoras post-V1 — relevo y brief factual (D93–D94), 2026-09-26

- GLM-5.3 max: camino directo del relevo ya forzado por D30, manteniendo
  TurnMaster para casos no forzados. 11 tests con contador real de peticiones.
- Grok 4.7 high: brief con CA efectiva, PG temporales, estados vitales e
  identidad canónica. 14 tests, incluidos smoke TestModel para DM/PCAgent.
- Correcciones exigidas en integración: aridad de la API de traducción;
  guardas explícitas de mini-turn DM; tipo de instructions en los smoke;
  fixture de reacción que intentaba usar una acción y consumía un guion ajeno.
- Gate coordinador: **1776 passed / 3 excluded**, compile warnings-as-errors,
  formato y diff correctos. La suite tiene advertencias preexistentes de tests;
  no se ha realizado una nueva medición live de latencia.

## 17. Oleada noche A — trucos RAW, Guiding Bolt y condiciones (D95), 2026-09-26

- **D95 (GLM-5.3 max)**: escalado de trucos por nivel de personaje (umbrales
  5/11/17, `Rules.Cantrips`), overlay en `cast_spell` que rellena solo campos
  `nil` con el catálogo (builtin gana; hojas rancias corregidas sin migración),
  builtin poison spray, acid splash a un objetivo y Guiding Bolt ejecutable
  (marca en `conditions`, consumo hit-o-miss por cualquier atacante, caducidad
  perezosa vía `turn_state`; simplificación documentada: caduca al inicio del
  siguiente turno del lanzador, no al final RAW). Rojos reproducidos antes:
  sacred flame 0/null, fire bolt L5 sin 2d10, guiding bolt sin ventaja.
  29 pruebas nuevas (15+14); un oráculo de upcast actualizado por el cambio
  RAW-documentado (base builtin de spiritual weapon + upcast = 2d8).
- **§7.4 condiciones y duración (Grok 4.7 high)**: dos divergencias
  reproducidas en rojo y corregidas — (1) `set_current_combatant` apagaba
  Esquiva asombrosa al iniciar turno (D64 declara que solo el daño la consume);
  (2) `seed_legacy` borraba Escudo de la fe porque `observe` trataba
  nil→hechizo como fin de concentración. 15 pruebas nuevas
  (`conditions_audit_test.exs`) fijan además: reacciones y reselecciones sin
  apagar posturas, inmunidades por una sola ruta sin doble aplicación, limpieza
  de bless/shield por drop/0 pg/furia/incapacidad/reloj, marca del cazador
  ligada a concentración, plazos explícitos y no caducidad de condiciones sin
  plazo. Distancia, alcance, cobertura, línea de visión y AoO siguen sin
  representarse (documentado, no implementado).
- Gate coordinador: **1820 passed / 3 excluded** (+44), compile
  warnings-as-errors, formato y diff correctos. Primer intento 1819/1820 por
  el contador de builtins (44→45) y un warning de test nuevo; reasignados al
  responsable y verificados.

## 18. Oleadas noche B/C — entradas inválidas, mapa de efectos, Sleep y Shield (D96), 2026-09-26

- **§7.6 entradas inválidas (GLM-5.3 max)**: 6 hallazgos con reproducción y
  guarda temprana — heal con dados malformados, gramática Dice cerrada
  (0d6/1d0), rangos 1..100/2..1000 unificados en `Dice.valid?`/`parse_expr`
  (antes solo Actions.roll/Tools.roll; heal podía colgar con 101d8),
  **`apply_damage` con daño negativo aumentaba `temp_hp`** (mutación real),
  amounts no enteros, spawn con nombre en blanco. 21 pruebas nuevas.
- **§7.5 mapa catálogo→ejecutable (Grok 4.7 high)**:
  `tecnico/11-mapa-efectos.md` — 28 ejecutables / 47 parciales / 244
  descriptivos, trampas documentadas (sleep curaba, charm/hold sin condición,
  shield ≠ shield of faith, hunter's mark fuera de cast_spell) y top 10 de
  candidatos con borradores de ADR y oráculos.
- **D96 Sleep + Shield (GLM-5.3 max)**: Sleep corrige el bug de la rama de
  curación (pool RAW, orden PG ascendente, parada al no caber, despertar por
  daño, 1 minuto); Shield como postura +5 CA efectiva con expiración eager y
  magic missile 0. 25 pruebas nuevas; 2 tests de upcast actualizados por
  codificar el comportamiento bug (sleep ausente de la tabla / "curaba").
- **Revisión cruzada (Grok)**: sin defectos en cantrips D95 ni en los fixes
  P4; dos hallazgos corregidos por GLM en la misma tanda — la marca guided
  podía revivir entre combates terminados en la misma ronda (end_combat
  ahora borra las condiciones guided) y los rangos de dados estaban fuera de
  `Dice`. Hallazgo de modelado para tandas futuras: `without_source` solo
  limpia bless/shield_of_faith — implementar condiciones vinculadas a
  concentración exige extenderlo.
- Gate coordinador: **1868 passed / 3 excluded** (+48), compile
  warnings-as-errors, formato y diff correctos. Tres fallos del primer
  intento (builtin shield duplicado, contador y test de Twinned que usaba
  shield como ejemplo) reasignados al responsable y verificados.

## 19. Oleada noche D — Hold Person y Faerie Fire (D97), 2026-09-26

- **D97 (Grok 4.7 high)**: Hold Person impone `paralyzed` vinculado a
  concentración (fuente `hold_person:<lanzador>`; repetición de la
  salvación de SAB solo en turno nuevo del objetivo) y Faerie Fire marca al
  que falle DES con ventaja cancelable para cualquier atacante. La limpieza
  por fuente se generaliza: `without_source` ya no se limita a
  bless/shield_of_faith — requisito nacido del hallazgo de la revisión
  cruzada (§18). Simplificaciones documentadas: humanoide abstracto (kobold
  del catálogo entra como reptilian y queda registrado), sin radio,
  repetición a inicio de turno, un objetivo.
- El camino previo (kind save sin dados → salvación de 0 efecto) quedó
  documentado; la suite final valida el contrato nuevo. 15 pruebas nuevas
  (`hold_person_test.exs`, `faerie_fire_test.exs`) con regresión de
  concentración/efectos/condiciones/metamagia (182 passed de área).
- Gate coordinador: **1883 passed / 3 excluded** (+15), compile
  warnings-as-errors, formato y diff correctos a la primera.

## 20. Sesión 2, oleada E — Mage Armor y Charm Person (D98) + revisión D97, 2026-09-27

- **D98 (Grok 4.7 high)**: Mage Armor como condición de 8 h sin concentración
  con CA efectiva `max(ficha, 13 + mod DES)` sin armadura (el escudo no
  cuenta); Charm Person con salvación de SAB (ventaja en combate), `charmed`
  1 h, desventaja solo contra el lanzador y ruptura por daño del lanzador o
  su bando (daño sin atacante no rompe, documentado). 9 pruebas nuevas +
  paridad de salvación.
- **Revisión cruzada de D97 (GLM-5.3 max)**: núcleo correcto (DC con aura,
  repetición solo en turno nuevo, limpieza por fuente sin romper D85/D86,
  Twinned, Codec). Hallazgo medio corregido por Grok: las salvaciones de
  condición (hold/faerie/charm y su repetición) ahora pasan por el mismo
  pipeline que los hechizos — Astucia gnoma (D71), Heightened (D65), aura
  (D61), inspiración bárdica (D50), Indomitable (D68) y RollLog `:save`.
  Hallazgo bajo corregido: liberar al último objetivo de hold person libera
  la concentración del lanzador (antes quedaba huérfana). Cobertura ampliada
  (kobold/reptilian, aura).
- Gate coordinador: **1897 passed / 3 excluded** (+14), compile
  warnings-as-errors, formato y diff correctos a la primera.

## 21. Sesión 2, oleada F — Spiritual Weapon y Spirit Guardians (D99), 2026-09-27

- **D99 (GLM-5.3 max)**: Spiritual Weapon como postura de 10 rondas (el
  lanzamiento consume la acción adicional — casting_time RAW verificado por
  los tests) con tool `espiritual_weapon_attack` de acción adicional por el
  pipeline completo de ataque de conjuro; envejecimiento solo en turno nuevo
  (D44), sustitución al relanzar. Spirit Guardians como aura recurrente:
  marca sin daño al lanzar (patrón D97), tick al inicio de cada turno nuevo
  del lanzador mientras concentra — SAB con stack completo, mitad floor en
  éxito, un conjunto de dados por enemigo, daño vía pipeline (rompe
  concentración del enemigo), upcast +1d8/nivel. 20 pruebas nuevas.
- **Fix de revisión E incluido**: las salvaciones de hold/faerie/charm dejan
  grupo `:save` en el RollLog vivo. Límite documentado: la repetición de
  turno de hold person no registra (el cuello `set_current_combatant` no
  recibe roll_log; `game.ex` congelado esa tanda).
- Revisión cruzada de la oleada E (Grok): oráculos de mage armor/charm
  validados (armadura montada de verdad, tercero no rompe, desventaja solo
  vs fuente); un hallazgo bajo (RollLog nil) corregido en esta tanda.
- Gate coordinador: **1918 passed / 3 excluded** (+21), compile
  warnings-as-errors, formato y diff correctos a la primera. Los 13 rojos
  iniciales del worker fueron oráculos propios (0 fixes de motor),
  documentados.

## 22. Inicio de turno, recursos y contexto de agentes (D100), 2026-10-01

- **Reproducción previa**: cuatro regresiones de Spirit Guardians fallan
  porque Inspiración/Indomitable permanecen disponibles o se tiran otra vez
  en concentración. Seis regresiones Game/Postgres fallan porque el roller
  inyectado no recibe ninguna tirada de inicio de turno. El camino de error
  del actor deja además el combatiente anterior sin iniciar el siguiente.
- **Corrección**: recursos de la salvación consumidos antes del daño,
  validación de la ficha original; `Game.Combat.start_turn` comparte roller
  y RollLog entre decisiones/reacciones/fallbacks. Se registran grupos solo
  tras aplicar el cambio, desde Game; ningún cambio de struct/Codec.
- **Cobertura**: daño inmune, dos salvaciones encadenadas, tick siguiente,
  repetición de Hold Person, re-selección/reacción/Codec, pausa y nuevo Game.
  Dos smokes inspeccionan la petición real a TestModel del DM y PC automático:
  PG actualizados y salvación/daño/concentración presentes en el history.
- **Gate**: 13 pruebas nuevas; focalizadas **82/82**, suite completa
  **1931 passed / 3 excluded**, compile con warnings-as-errors, formato global
  y diff correctos. Logs locales
  `/tmp/dragonex-spirit-guardians-red.log`, `/tmp/dragonex-start-turn-red.log`,
  `/tmp/dragonex-engine-focused.log`, `/tmp/dragonex-engine-full.log`.
- **Proveedor real**: `DRAGONEX_RUN_LIVE=1 MIX_ENV=test mix test
  test/dragonex/flows/live_dm_test.exs test/dragonex/flows/live_smoke_test.exs
  --include integration --timeout 120000`: **3/3**, 37,5 s de suite; escena,
  iniciativa y ataque mediante tools. Log `/tmp/dragonex-engine-live.log`.
- **Límites**: conserva D97/D99 (sin grid, repetición/aura al inicio del
  turno); el smoke live no certifica estos efectos con proveedor real ni
  coordinación prolongada entre PCs ni latencia por turno. No cierra la
  auditoría del resto de reglas.

## 23. Calidad de mesa y coordinación en playtest (D101–D106), 2026-10-01

- **Mesa**: `?as=` permitía asumir otro PC o DM; paginación desaparecía en
  PubSub, dividía turnos y se bloqueaba al mostrar solo secretos. Identidad
  autenticada y ventana retenida corrigen esos caminos. Cuatro regresiones
  de historial incluyen el límite de 2000 eventos sin ocultar los recientes.
- **Uso real**: controles de 44 px/reanudar visible, ficha por Espacio,
  seguimiento después de resize, intención/borrado y DM/PC a 1440/390 px.
  Borrador en sessionStorage hasta confirmación, recuperado tras reload sin
  volver a enviar la acción aceptada. Sin errores JS en esos recorridos.
- **Motor**: cuatro regresiones muestran aura con último enemigo a 0 pero
  fase aún combate mientras espera al humano. Ahora `start_turn` ejecuta el
  cierre estándar después de publicar los dados de la fase original.
- **Narración**: fixture de salida real; PC unido a una cita previa de PNJ,
  diálogo con atribución y asentimiento no se retiraban. Corte acotado de Text,
  conservando PNJ/estados legítimos, compartido con vista de streaming.
- **TurnMaster**: dos regresiones prueban snapshots antiguos/feedback inválido
  acumulados entre relevos. `message_history: []` conserva feedback dentro
  del beat y entrega solo estado vigente al siguiente; tercera prueba verifica
  reacción humana y actor interrumpido. No cambia la aplicación single-writer.
- **Gate**: 29 pruebas nuevas tras D100; **1960 passed / 3 excluded**,
  compile con warnings-as-errors, formato global y diff correctos.
  `/tmp/dragonex-web-quality-full.log` y `/tmp/dragonex-flow-quality-full.log`.
  Reproducciones en `/tmp/dragonex-{viewer,history-refresh,controls,narrative,
  aura-combat,preview,tm-context,draft-ack}-red.log`.
- **Límite de producto**: exploración 28,69 s y emboscada hasta el siguiente
  humano 116,90 s, con un ataque fuera de turno y fallback TM observados.
  Sigue el plan `producto/07-calidad-jugable.md`; no se certifica todavía
  fluidez de campañas ni sanitización semántica universal.

## 24. Turno consumido después de un fallo del actor (D107), 2026-10-01

- **Reproducción**: acción válida de g1 comprometida y ataque de g2 rechazado
  fuera de turno. El fallback volvía a elegir g1 porque no marcaba su turno;
  el último fallo principal también impedía cerrar la ronda. Tres regresiones
  en rojo, con un control de mini-turn que ya pasaba.
- **Corrección**: marcar el slot principal antes de `Session.end_turn`, igual
  que en éxito. PG/acción ya gastados permanecen; mini-turns no marcan.
  Rechazo de TurnBudget identifica el combatiente vigente y el relevo del TM.
- **Gate**: cinco pruebas nuevas, 61 focalizadas y suite **1965 passed /
  3 excluded** (16,6 s); compile sin warnings, formato global y diff correctos.
  Evidencia `/tmp/dragonex-actor-failure-{red,green}.log`,
  `/tmp/dragonex-turn-directive-red.log` y `/tmp/dragonex-actor-quality-full.log`.
- **Playtest**: combate propio cerrado; Lyra 3/7 PG/0 casillas, otros PCs
  ilesos y tres enemigos a 0. Se conserva la incidencia de huida solo narrativa
  para el siguiente bloque; ni fluidez ni objetivo global declarados completos.
