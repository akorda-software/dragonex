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
