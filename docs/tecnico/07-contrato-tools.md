# Contrato de tools (LLM ↔ motor)

> **Técnico.** La especificación exacta de las herramientas `deftool` que el
> LLM puede invocar: firmas, quién las tiene, guardas, semántica de errores y
> reglas transversales. Es el equivalente al "contrato con el solver": si una
> tool cambia de firma o comportamiento, **este doc cambia en el mismo commit**.

Fuente canónica del código: `lib/dragonex/tools.ex` (S5), sets por agente en
`dm.ex`/`pc_agent.ex`/`turn_master/tools.ex` (S6). Las mecánicas que resuelven:
[`08-catalogo-mecanicas.md`](08-catalogo-mecanicas.md).

---

## 1. Reglas transversales (todas las tools)

1. **`ctx.deps`** — toda tool recibe el contexto del beat con:
   - `:state` — handle de `ExAgent.Session.SharedState` (proponer cambios),
   - `:roller` — fn `sides -> value` inyectada (`Dice` en prod, fija en tests),
   - `:roll_log` (opcional) — `RollLog` para el dado modal,
   - `:human_pcs` — `MapSet` de nombres de PCs humanos (lo inyecta el Game).
2. **Single-writer** (D6/D150): una tool propone un change_fn. En partida
   viva Game valida beat/actor/Session/dueño, evalúa y guarda el candidato
   antes de publicarlo en Session. Standalone usa SharedState sin DB.
3. **El modelo sólo ve el mensaje**: las tools devuelven `{:ok, texto}` o
   `{:error, motivo}`. El cálculo (dados, AC, HP) vive en `Rules`/`Actions`;
   el texto devuelto es factual.
4. **Guarda de control** (`assert_controls`): en las tools con actor, el actor
   debe estar **controlado por el participante actual** (`World.controlled_by?`).
   El error es **directivo** — dice exactamente quién debe actuar y cómo
   reemitir, para que el modelo se autocorrija en el retry.
5. **Sanitización** (D7): todo texto del modelo que se persiste en el world
   (`set_scene`, `establish_fact`) pasa por `Text.scrub` ANTES de proponer.
   Ambas tools validan además agencia con roster/actor vigentes (D135/D156):
   acciones ajenas o del grupo no se convierten en entorno/hechos canónicos.
   NPCs, citas y acción propia mantienen la atribución acotada de Text.
   D176 record_npc_statement sanea fuente/contenido dentro de la transición
   World; ambos son acotados y su atribución permanece explícita.
6. **Sin `:rand`** en el camino de una tool: siempre `deps.roller`.
7. **D81–D83**: el motor comprueba incapacidad, turno y cupos antes de tirar.
   Extra Attack es una acción; bonus/reacción tienen cupos separados. Una
   interrupción no concede una acción completa. Recursos/turno que cambien
   antes de aplicar la transición provocan error y requieren resolver de nuevo.
   Un daño ya preparado no repite tiradas al aplicarse.
8. **Reintentos** (D152/D153): wrappers DM/PC registran resultados exitosos
   saneados por identidad canónica. Un intento posterior del mismo beat usa
   feedback previo sin nuevos efectos/dados; errores se pueden corregir y
   calls originales consecutivas mantienen costes. World/Codec conserva el
   registro hasta liquidar, también tras restart; nuevas declaraciones no
   lo heredan. D154 asocia el comprobante al efecto en un mismo World antes
   del feedback y luego lo sustituye por el resultado final. Dados/eventos
   anteriores al guardado no eran atómicos. D157 bufferiza grupos por ejecución
   y los guarda con World/comprobante en una transacción; roll_dice guarda sus
   grupos con el resultado exitoso. Publica tras SQL+Session; rechazo/rollback
   no publica ni cobra recursos. Narraciones/tiradas standalone/resoluciones
   automáticas fuera de estas tools no heredan esa garantía.
9. **Preguntas PNJ literales** (D158): Game registra una reserva durable
   DM→humano al consumir un destinatario de rol PNJ cualificado. No es una
   tool nueva ni permite recipients vacíos en request_response. Un modelo
   no puede sustituir esa cola por compañeros; menciones/planes/ambigüedad
   mantienen la ruta anterior. Las respuestas respetan la misma agencia.

---

## 2. Catálogo de tools de juego (`Dragonex.Tools`)

### Narrativa y mundo (DM)

| Tool | Firma | Efecto |
|---|---|---|
| `set_scene` | `(narration: String)` | Escena actual scrubbed; valida actor/roster vigente y rechaza texto vacío o acciones ajenas/colectivas explícitas, también con clíticos antes del predicado, o disparadores temporales plurales acotados antes de proponer. Solo actor dm antes de leer/proponer World (D195); conserva World/log/cola al rechazar. Admite entorno/invitaciones PNJ; el humano resuelve su acción y espera confirmación DM (D135/D137/D141/D195) |
| `establish_fact` | `(fact: String)` | Solo actor dm antes de leer/proponer World (D195); hecho durable canónico (D16), idempotente, cap30, scrubbed; no convierte prosa humana en confirmación |
| `record_npc_statement` | `(speaker: String, statement: String)` | Solo DM: fuente80/contenido800, scrub/NFC/espacios/citas internas, rechazo de fuente PJ completa/corta. Guarda «fuente afirma: contenido» como testimonio en facts existentes, cap30/idempotencia/replay; no confirma contenido ni cambia entorno/presencia/recursos/reloj/marca de revisión previa (D176) |
| `grant_item` | `(who: String, item: String, quantity: Integer)` | Solo DM/exploración/PC presente; confirma entrega efectiva sumando a Item :gear. Nombre scrub/NFC1..160, identidad case/espacios, cantidad1..9999, pila≤9999, inventario≤80 entradas. Rechaza colisión con equipo no :gear; solicita revisión de escena, sin PG/slots/reloj/equipar/efectos (D190) |
| `remove_item` | `(who: String, item: String, quantity: Integer)` | Mismas guardas; resta del stock real :gear, rechaza inexistente/insuficiente y elimina pila vacía. No retira equipo de combate ni consume efectos; solicita revisión de escena (D190) |
| `leave_scene` | `(who: String, reason: String)` | Solo DM, no-PC existente; motivo scrubbed/acotado; conserva ficha/PG/recursos y termina concentración/presencia activa. No decide una huida (D115) |
| `return_to_scene` | `(who: String)` | Solo DM; recupera la ficha ausente, sin curar/renovar recursos; refuerzo al final del combate, con ledger conservado (D115) |
| `spawn_monster` | `(kind: String, name: String)` | Solo dm antes de World/propuesta (D196); añade monstruo del bestiario (`Monsters`) y lo une a iniciativa sin reroll si hay combate; nombre único/ausentes conservados por World. Si `kind` no existe, lista disponibles |

D190 expone límites reales en JSON Schema y excluye ambas tools de PCAgent.
Una devolución PNJ efectiva requiere grant_item antes de narrarla; una petición
pendiente conserva stock. Wrapper normaliza identidad NFC/case/espacios para
replay del mismo beat, sin duplicar efecto tras caída. Game persiste el cambio
con su comprobante; UI/brief son lectores. La revisión posterior no cobra ni
repite cantidades: confirmación idéntica exige huella del resto del World,
comprobante solo de inventario, pendiente previo false y commit exacto. Timeout
conserva pendiente. No crea registro físico global de objetos ni verifica su
procedencia semántica; el motor valida/aplica la propuesta, no calcula desde
lo narrado. Contrato por turno/contexto reciente reduce las omisiones observadas,
sin garantizar toda respuesta de un proveedor.

D135 usa los mismos cortes estructurales de Text que la narración, con
normalización equivalente para evitar falsos rechazos por saltos/espacios.
Un error es directivo y rechaza toda la propuesta, conservando la escena y
preguntas pendientes. PNJs/nombres completos frente a prefijos y preguntas
como «¿Lyra abre la ventana?» siguen válidos; no prueba consenso o ubicación
de toda prosa posible. Fixtures y Game/LiveView en `game_scene_agency_test.exs`
y `game_collective_agency_test.exs`.

D176 separa recordar una versión de establecer un suceso. Fuente es nombre
o rol del PNJ, no diálogo; la identidad de un NPC conocido prevalece frente
a un prefijo PJ compartido. PNJs no representados en World pueden guardar
testimonio: el DM aporta su identidad/contenido, sin prueba automática de
existencia o veracidad. Citas internas se normalizan para permanecer dentro
del cuerpo atribuido; una alegación sobre acciones PJ no ejecuta esas acciones.
Brief DM/PC/TM conserva fuente/dudas y distingue atribución de confirmación.
La tool cambia solo memoria y mantiene la revisión previa: sucesos físicos
reales requieren las tools correspondientes. Permanece en el set DM (incluido
el agente que resuelve humanos), con guarda de participante dm; no se anuncia
a PCAgent. Es elección del modelo usarla, sin extracción automática de prosa
ni migración inferida de facts antiguos. Tests NPCStatement/Game y compacción.

D198 reconoce esa envoltura atribuida solo para presentación: Brief separa
Hechos establecidos y Testimonios atribuidos para DM/PC/TM, conservando las
cadenas/marcas/orden por sección. No valida una fecha ni modifica World ni
reclasifica mediante interpretación de prosa. Guía final de beats con
atribución conserva fuente frente a narración/resumen anterior: una comparación
PNJ no pasa a observación propia; DM puede dar primera persona al testigo.
No cambia la firma/guarda/deduplicación de record_npc_statement. Comillas
externas dobles y equivalencia de envolturas se abordan después en D199.

D199 amplía deduplicación solo a envolturas completas no ambiguas del mismo
texto: el fact retenido se devuelve verbatim con primera marca/posición o
legacy sin marca. Nuevos cuerpos no incluyen envoltura externa redundante;
citas parciales/internas/apóstrofos permanecen. Vacío tras desenvuelto rechaza,
límites previos80/800 y guarda DM siguen; no interpreta semántica ni nombres/
relojes por inferencia. Marcas exteriores se reconocen estrictamente; contenido
con marca literal sigue dentro de cita. No cambia firma/Tools/World/Codec,
ni migra o recupera facts expulsados. Tests/Game/replay/restart/SQL verdes.

### Preguntas a compañeros (PC / resolución de declaración humana)

| Tool | Firma | Guarda y efecto |
|---|---|---|
| `request_response` | `(recipients: [String], question: String)` | Participante actual PC, exploración, 1–5 PCs distintos presentes/capaces/registrados, sin self/PNJs. Origen tomado del handle, pregunta scrubbed/acotada a 800 caracteres. Cola durable; cada PC responde en su beat, luego cierre DM y retorno al humano. Reintento idéntico idempotente; petición distinta pendiente rechazada (D120). Desde D143 el Game puede registrar el vocativo humano literal antes del beat; si ya hay pregunta registrada, el modelo no vuelve a llamar ni sustituye esa cola. Schema sin cambios. |

Schema live limita la lista a 1–5 elementos únicos y la pregunta a 800
caracteres; el motor vuelve a validar la entrada. Está en PCAgent y en DM
porque ese agente resuelve declaraciones humanas como el PC admitido;
actuando como `dm` no puede abrir la petición. No decide respuestas ni tira
dados. Game conserva la cola al pausar, liquida fallos terminales una vez y
omite destinatarios incapaces antes de reabrir. Escena nueva o combate la
cancelan; prioridades humanas y mini/re-eval se mantienen. El texto libre
requiere que el modelo reconozca la pregunta y llame esta tool.

### Resolución de reglas (DM y, según tool, PC)

**Schema live de magia (D108)**: DM y PCAgent consumen `Tools.agent_tools/0`.
`caster`, `spell` y `target` son obligatorios. `cast_level`,
`additional_targets` y `condition_to_remove` se pueden omitir o enviar como
`null`; el selector enumera `null` y las cinco condiciones de abajo. Los
metadatos corrigen la derivación obligatoria/no nullable de exAgent, sin
cambiar la firma ni su compatibilidad Elixir/JSON. Un selector vacío o de
espacios se trata como ausente. Otro selector no vacío para un hechizo distinto
de Lesser Restoration se rechaza antes de gasto/tiradas y pide omisión/`null`.
Regresiones y beat PCAgent real/TestModel en `cast_spell_contract_test.exs`.

**Lesser Restoration (M65/D90)**: `cast_spell` acepta al final
`condition_to_remove` opcional, exclusivo de este hechizo: `blinded`, `deafened`,
`paralyzed`, `poisoned` o `diseased`. Sin él solo selecciona si cada objetivo
tiene exactamente una condición elegible; la ambigüedad devuelve error sin gasto.
Elimina una condición y su plazo, sin curar PG; acción/casilla >=2, instantáneo,
sin concentración/escalado. Twinned D65 usa el selector común o una selección
única independiente por receptor no-self. JSON antiguo y aridades Elixir previas
conservadas; otras spells rechazan el selector para no ignorarlo.

**False Life (M23/D89)**: `cast_spell(caster, "false life", caster, cast_level)`
genera `1d4+4`, +5 PG temporales por nivel superior al primero. Exige objetivo
propio, una acción/casilla, una hora sin concentración; no activa metamagia.
El motor conserva la reserva mayor y solo un valor estrictamente mayor sustituye
el plazo. RollLog registra una única tirada y el total generado. Firma intacta.

**Spare the Dying (M64/D88)**: `cast_spell(caster, "spare the dying", target)`
estabiliza una criatura viva a 0 PG sin curarla: `successes: 3, fails: 0`.
Una acción, sin dados/casillas/concentración; rechaza muertos, constructos,
no-muertos y PG positivos. Ya estable es válido. Twinned D65 admite dos
objetivos distintos; no admite upcast ni `additional_targets`. El schema
y las guardas de control de actor no cambian.

**Heal (M63/D87)**: `cast_spell(caster, "heal", target, cast_level)` restaura
70 PG a nivel 6 y +10 por nivel superior (cap al máximo), sin dados/modificador.
Elimina `blinded`, `deafened`, `diseased` y sus plazos. Una acción/casilla, sin
concentración. Admite self/caídos vivos y Twinned D65; rechaza muertos,
constructos y no-muertos. No cambia el schema ni la tool separada `heal`, que
sigue recibiendo una expresión de dados. `additional_targets` no aplica aquí.

**Shield of Faith (M62/D86)**: `cast_spell(caster, "shield of faith", target)`
aplica +2 CA efectiva con bonus action y una casilla; concentra hasta 600 s.
No apila copias ni aumenta al subir casilla. Respeta Twinned D65 para dos
objetivos distintos no-self, pero `additional_targets` sigue siendo solo
para Bless. Armas y hechizos de ataque consultan `Rules.Effects.effective_ac/1`
(CA base + Defense + protección) y el RollLog refleja esa CA. Abandonar,
perder o reemplazar concentración retira los efectos de la fuente.

| Tool | Firma | Guarda | Resuelve |
|---|---|---|---|
| `roll_initiative` | `()` | Solo dm antes de World/RNG (D196) | Iniciativa de todos los presentes conscientes + `begin_combat` (M2); D215 revalida nombres/DEX al commit y rechaza preparación obsoleta sin rellenar el orden ni calcular dados nuevos |
| `make_attack` | `(attacker, target, weapon, mode)` | `assert_controls(attacker)`; Game rechaza ejecución nueva de enemigo presente/apto/controlado en exploración antes del callback/RNG, pide iniciativa; recibo pagado conserva replay (D225, verificado offline) | Acción de Ataque: N golpes vs el mismo objetivo (Extra Attack D35 / M3); d20(+adv/dis) + prof + mod vs AC; crítico dobla dados (M3–M6) |
| `cast_spell` | `(caster, spell, target, cast_level, additional_targets, condition_to_remove)` | `assert_controls(caster)` | Por `kind`: `:automatic` / `:attack` / `:save`; consume slot si nivel > 0. `cast_level` opcional = upcasting (M58/D74). `additional_targets` es una lista opcional **solo para Bless** (M61/D85), además de `target`: hasta `2 + cast_level` nombres únicos, existentes y no muertos. Bless consume una acción/casilla, fija concentración de 60 s; +1d4 a ataques/salvaciones. `condition_to_remove` opcional **solo para Lesser Restoration** (M65/D90). JSON antiguo y llamadas Elixir anteriores compatibles. |
| `ability_check` | `(who, ability, dc, mode)` | `assert_controls(who)` | d20 + mod vs DC del DM (5/10/15/20). `ability` acepta un SKILL (`"stealth"`, `"Animal Handling"`… — normalizado): el motor mapea la característica, aplica la prof de la ficha y JoaT del bardo L2+ en no entrenadas (D60 / M44); ability cruda sin prof de ficha (compat) |
| `make_death_save` | `(character)` | `assert_controls(character)` | Death save: nat20 revive, nat1 doble fallo, 3/3 (M14) |
| `heal` | `(target, dice)` | Solo dm antes de World/RNG (D197); PCs usan spell/feature | Curación por expresión (`1d8+3`), cap max_hp, resetea death saves (M15). No toca `temp_hp` |
| `grant_temp_hp` | `(who, amount)` | Solo dm antes de World/target (D197, restringe permiso PC D36) | Otorga pg temporales sin apilar (`max` actual vs nuevo) (M23 / D36) |
| `grant_xp` | `(who, amount)` | DM | Suma XP 5e; no sube de nivel; amount > 0 (M27 / D43) |
| `drop_concentration` | `(who)` | DM cualquiera; PC sólo sí mismo | Suelta la concentración actual (M24 / D37) |
| `start_rage` | `(who)` | DM cualquiera; PC sólo sí mismo | Entra en furia (bárbaro). Rompe concentración (M26 / D42) |
| `end_rage` | `(who)` | DM cualquiera; PC sólo sí mismo | Sale de furia (M26 / D42) |
| `start_reckless` | `(who)` | DM cualquiera; PC sólo sí mismo | Reckless Attack (bárbaro). El motor aplica ventaja (M28 / D44) |
| `end_reckless` | `(who)` | DM cualquiera; PC sólo sí mismo | Sale de Reckless Attack (M28 / D44) |
| `second_wind` | `(who)` | DM cualquiera; PC sólo sí mismo | Segundo aliento (fighter): 1d10+level, 1/rest (M29 / D45) |
| `action_surge` | `(who, target, weapon, mode)` | DM cualquiera; PC sólo sí mismo | Oleada de acción (fighter L2+): 1 Acción de Ataque extra, Extra Attack D35 incluido, 1/rest (M31 / D47) |
| `flurry_of_blows` | `(who, target, mode)` | DM cualquiera; PC sólo sí mismo | Ráfaga de golpes (monje L2+): gasta 1 ki; el motor resuelve 2 golpes sin armas con el dado de artes marciales (M38 / D54) |
| `hunters_mark` | `(who, target)` | DM cualquiera; PC sólo sí mismo | Marca del cazador (explorador L2+): gasta 1 casilla de nivel 1 y concentra; el motor suma +1d6 por impacto de arma contra la presa, crit dobla (M39 / D55) |
| `cunning_action_hide` | `(who)` | DM cualquiera; PC sólo sí mismo | Astucia de pícaro (pícaro L2+): el motor tira Sigilo (1d20+DES+prof) vs la máxima percepción pasiva de enemigos conscientes (DC 10 sin enemigos); éxito → condición `hidden` (ventaja en su próximo ataque, que lo revela) (M41 / D57) |
| `create_spell_slot` | `(who, level)` | DM cualquiera; PC sólo sí mismo | Fuente de magia (hechicero L2+): convierte puntos de hechicería (coste 2/3/5/6/7) en 1 casilla de nivel 1..5 (M40 / D56) |
| `convert_to_sorcery_points` | `(who, level)` | DM cualquiera; PC sólo sí mismo | Fuente de magia (hechicero L2+): drena 1 casilla de nivel 1..5 y recupera esos puntos de hechicería, con cap al máximo (M40 / D56) |
| `arm_metamagic` | `(who, option, target)` | DM cualquiera; PC sólo sí mismo | Metamagic (hechicero L3+): gasta 1/3/2 puntos y arma UNA opción (`"empowered"`/`"heightened"`/`"twinned"`; `target` para las dos últimas, `""` para la primera) que el motor aplica y consume con el próximo hechizo que califique — Empowered re-tira los primeros `max(1, CAR)` dados de daño conservando el mayor (crit dobla sin duplicar rerolls), Heightened da desventaja a la salvación del objetivo armado (entra como `requested` en `save_mode`), Twinned resuelve el mismo hechizo también contra el segundo objetivo armado (una casilla, una concentración); SIN un-arm ni reembolso; rests no la tocan (M49 / D65) |
| `divine_smite` | `(who, slot_level)` | DM cualquiera; PC sólo sí mismo | Castigo divino (paladín): arma `smite_slot` 1..5; no gasta casilla aún (M30 / D46) |
| `end_smite` | `(who)` | DM cualquiera; PC sólo sí mismo | Retira Castigo divino pendiente; no gasta casilla (M30 / D46) |
| `lay_on_hands` | `(who, target, amount, conditions_to_remove)` | DM cualquiera; PC sólo `who` sí mismo (target puede ser aliado) | Manos impositoras (paladín): cura PG y opcionalmente elimina una lista sin duplicados de `poisoned`/`diseased`, por 5 puntos cada condición más curación efectiva, en una acción. `amount: 0` solo purifica, sin estabilizar; exige reserva para cantidad solicitada + purificación. Lista omitida/vacía mantiene curación anterior. JSON y aridad Elixir antiguos compatibles (M33 / D49/D91). |
| `divine_sense` | `(who)` | DM cualquiera; PC sólo sí mismo | Sentido divino (paladín): gasta 1 uso y reporta celestial/fiend/undead (M36 / D52) |
| `turn_undead` | `(who)` | DM cualquiera; PC sólo sí mismo | Expulsar no-muertos (clérigo L2+): gasta Canalizar divinidad; no-muertos tiran Sabiduría o frightened (M37 / D53) |
| `bardic_inspiration` | `(who, target)` | DM cualquiera; PC sólo `who` sí mismo (target puede ser aliado) | Inspiración bárdica (bardo): gasta 1 uso, marca target inspired; el motor aplica 1d6 al primer roll (M34 / D50) |
| `arcane_recovery` | `(who)` | DM cualquiera; PC sólo sí mismo | Recuperación arcana (mago): restaura huecos gastados greedy, 1/long rest, fuera de combate (M35 / D51) |
| `wild_shape` | `(who, beast)` | DM cualquiera; PC sólo sí mismo | Forma salvaje (druida L2+): transforma en bestia del catálogo fijo `"cat"` (ND 0) / `"wolf"` (ND 1/4) / `"black_bear"` (ND 1/2, L4+); gasta 1 uso (2/rest); el motor guarda la forma original, aplica stats/armas de la bestia y conserva mental/identidad/concentración; sin conjuros en forma animal; si la bestia cae a 0 pg el motor auto-revierte con sólo el exceso de daño (M47 / D63) |
| `end_wild_shape` | `(who)` | DM cualquiera; PC sólo sí mismo | Vuelve a la forma original progresada con sus PG guardados, incluida vitalidad por ASI de CON mientras estaba transformado (M47 / D63 / D129) |
| `start_uncanny_dodge` | `(who)` | DM cualquiera; PC sólo sí mismo | Esquiva asombrosa (pícaro L5+): arma la postura para el próximo daño, antes de resistencias y PG temporales. D82 reserva la reacción al armarla y caduca al comenzar el siguiente turno propio. Se conserva la simplificación de cualquier fuente de D64 |
| `breath_weapon` | `(who, target)` | DM cualquiera; PC sólo sí mismo | Aliento de dragón (dragontino, racial, cualquier clase/nivel): gasta el uso (1/descanso — short y long recargan); el motor tira la salvación de DES del objetivo vs CD `8+CON+competencia` del dragontino y aplica el daño de fuego por nivel (`2d6`→`5d6`); éxito → mitad (floor). Mismo stack de sitio de salvación que los hechizos (aura, Lucky, Indomitable, Evasión, concentración del objetivo). No es hechizo: sin casillas, funciona en Forma salvaje (M54 / D70) |
| `gain_expertise` | `(who, skill)` | DM cualquiera; PC sólo sí mismo | Expertise (pícaro L1+ / bardo L3+): duplica el bonus de competencia de UNA skill entrenada en los checks con skill nombrada (`Actions.check` y `cunning_action_hide`; desglose "prof N (experto)"). 2 elecciones (4 desde rogue L6 / bard L10, `Progression.expertise_count/2`); permanente (sin rests). El motor valida clase, nivel, entrenamiento, duplicado y cupo; skill normalizada ("Animal Handling" ok). El error de cupo lista lo ya elegido (M57 / D73) |
| `short_rest` | `(target, hit_dice?)` | DM cualquiera; PC sólo sí mismo | 1 h; dados finitos, 0 para recuperar solo rasgos; omitir gasta como máximo 1. Recarga rasgos de corto, CD de Furia implacable e inspiración de bardo L5+. No devuelve usos de Furia ni reservas de largo (D83) |
| `long_rest` | `(target)` | DM cualquiera; PC sólo sí mismo | 8 h, máximo uno cada 24 h. PG y reservas de largo, hasta la mitad de dados de golpe (mínimo 1), elimina PG temporales y procesa caducidades (D83) |
| `rest_party` | `(targets, kind)` | Solo DM | Descanso simultáneo y atómico; `targets` lista sin duplicados, `kind` short/long. Un único intervalo para todo el grupo. Devuelve el reloj confirmado y pide registrar el entorno con `set_scene` sin repetir efectos (D144). La tool marca pendiente; el cierre de beat D145 puede registrar una instantánea sin repetir el descanso. Feedback long informa el cuerpo vigente después de caducar efectos (D146) |
| `advance_time` | `(seconds)` | Solo DM | Entero ≥0, fuera de combate; avanza reloj y caduca efectos. En combate el tiempo avanza con rondas |
| `roll_dice` | `(count, sides)` | — | Tirada libre NdM para el modelo |
| `end_combat` | `()` | Solo dm antes de propuesta (D196) | Vuelve a `:exploration`; apaga raging, reckless y smite_slot en todos (D42 / D44 / D46) |

### Estado de personajes (DM)

| Tool | Firma | Efecto |
|---|---|---|
| `apply_condition` | `(target, condition)` | Solo dm antes de World/target (D197); Condición persistente (`prone`, `poisoned`, …) (M20) |
| `remove_condition` | `(target, condition)` | Solo dm antes de World/target (D197); Quita la condición |
| `level_up` | `(target, opts)` | Solo dm antes de World/target (D197). **Rechaza PCs humanos** (mensaje directivo → ficha, sin leer World). Para NPCs/PCs IA: `opts = %{"spells" => [keys], "asi" => %{"str" => 2}}`. Cupo validado por el motor (M21) |

### Stubs legado (SOLO framework tests — no usar)

`attack(target, damage)`, `roll(sides)`, `spawn_character(name, hp)`,
`next_round()`. Aplican efectos crudos sin tirar — **anulan D1** si un agente
los usa en producción. Se mantienen para los tests de capacidades de exAgent
(`tools.ex:36-77`). **Regla: jamás añadirlos al set de un agente real.**

---

## 3. Sets por agente (S6)

| Agente | Tools | Extras |
|---|---|---|
| **DM** | Todas menos los 4 stubs legado (`DM.tools/0` rechaza `attack`/`roll`/`spawn_character`/`next_round`) | `make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `heal`, `roll_initiative` con `max_retries: 3` (margen para autocorrección tras error directivo) |
| **PCAgent** | `make_attack`, `cast_spell`, `spiritual_weapon_attack`, `ability_check`, `make_death_save`, `short_rest`, `long_rest`, `drop_concentration`, `start_rage`, `end_rage`, `start_reckless`, `end_reckless`, `second_wind`, `action_surge`, `flurry_of_blows`, `hunters_mark`, `cunning_action_hide`, `start_uncanny_dodge`, `create_spell_slot`, `convert_to_sorcery_points`, `arm_metamagic`, `divine_smite`, `end_smite`, `lay_on_hands`, `divine_sense`, `turn_undead`, `bardic_inspiration`, `arcane_recovery`, `wild_shape`, `end_wild_shape`, `breath_weapon`, `gain_expertise`, `request_response` | `make_attack`/`cast_spell` con `max_retries: 3`. **Nunca**: escenas, monstruos, condiciones, nivel, XP, iniciativa, end_combat |
| **TurnMaster** | `{give_turn_to, cut_in, react, pass_to_dm, end_scene}` (propias, `turn_master/tools.ex`) | **Ninguna muta el world**: registran una `Decision`; el `Game` la aplica (`Session.handoff/2`/`update_state/3`). `end_scene` propone cambio de escena vía el Game, no directo |

### Semántica de las tools del TurnMaster

- `give_turn_to(participant)` — turno principal al nombrado.
- `cut_in(participant, reason)` — interrupción: mini-turno que **vuelve** al
  actor interrumpido al terminar.
- `react(participant, reason)` — reacción corta ídem.
- `pass_to_dm(reason)` — cede la palabra al DM.
- `end_scene(summary)` — cierra la escena (cambia fase/escena vía el Game).

Si el TurnMaster falla, buclea o elige un objetivo inválido → fallback
`WorldDriven` determinista + circuit breaker (D17/D25). La partida nunca
deadlockea.

**Intenciones humanas (D27):** el brief del TM incluye un bloque
`Intenciones humanas pendientes` con el texto scrubbed de `games.intents`.
No hay tool nueva: el TM usa `give_turn_to` / `cut_in` / `react` para honrarlas.
Una re-eval disparada por `declare/3` mientras otro humano espera, si el TM
no decide, **deja el floor en el waiter** (no se aplica WorldDriven).

---

## 4. Errores: taxonomía y retry

D219 conserva controlled_by? y modifica solo el rechazo de control: actor
sin ficha pide nombre canónico/registro previo DM; ausente conserva ficha y
presencia; dm controlador nunca se recomienda como atacante. El DM recibe
nombres registrados disponibles que controla, sin actuar por PCs. El rechazo
precede Rules/RNG/propuesta, sin crear criaturas automáticamente desde prosa.

D218 transmite solo la causa req_llm invalid_tool_arguments al siguiente
intento como una guía estática system de schema/contenedor/tipos. No admite
args inválidos, cambia envelope, copia body privado ni persiste la guía en
historia/eventos. Los presupuestos/backoff y recibos siguen vigentes; la guía
no asegura que el modelo la obedezca.

D216 recupera órdenes heredadas incompletas desde Game antes de resume/beat
idle; no añade una tool al modelo. Los hostiles presentes con PG positivos
faltantes se incorporan al final como refuerzos, con nota pública y World
atómicos antes de Session. No tira iniciativa retrospectiva ni repite turnos.
Un intento busy/checkpoint/pending_turn conserva su propio protocolo; rechazo
SQL pausa y permite reanudar sin duplicar la incorporación.

| Tipo | Ejemplo | Efecto en el agente |
|---|---|---|
| **Directivo** (guarda) | `RECHAZADO — es el turno de X…` | El modelo reemite corregido en el retry (por eso `max_retries: 3` en resolución) |
| **De mundo** | `{:error, :unknown_character}` de un change_fn | Mensaje factual; el modelo ajusta la intención |
| **De proveedor** | timeout / respuesta rota | No llega a la tool: lo maneja el beat (backoff 1s→3s→10s, máx 3; luego breaker D17) |

---

## 5. Cómo añadir una tool nueva (checklist)

1. `deftool` en `tools.ex` con **type annotations** (el JSON Schema se deriva
   de los `::`), doc clara en español para el modelo.
2. Si resuelve una mecánica: la lógica va en `Actions`/`Rules`/`World` (D1),
   la tool es sólo puente. Test determinista de la mecánica primero.
3. ¿Tiene actor? → `assert_controls`. ¿Persiste texto del modelo? → `Text.scrub`.
4. Añádela al set del agente que corresponda (`dm.ex`/`pc_agent.ex`) y decide
   su `max_retries`.
5. Actualiza ESTE doc y `08-catalogo-mecanicas` si introduce mecánica nueva.
6. Smoke test del flujo con `TestModel` si cambia el comportamiento de un beat.
