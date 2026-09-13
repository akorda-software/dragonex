# Plan por fases

> **Producto.** Historial de fases entregadas y, sobre todo, el **backlog
> accionable** de lo que falta. Cada ítem pendiente referencia su requisito
> (`Rxx` de [`02-requisitos.md`](02-requisitos.md)), su definición de "hecho"
> y su receta de verificación. **Un agente puede tomar cualquier ítem de F6/F7
> y trabajar hasta verde sin más contexto que ese ítem + sus docs enlazados.**

Regla de oro (de [`../progress.md`](../progress.md)): una feature está hecha
cuando 1) tiene tests deterministas (o smoke si toca LLM), 2) `MIX_ENV=test
mix test` está verde, 3) su decisión está en `decisions.md` si es no trivial,
4) no deja TODO/FIXME sin dirección. **No se marca hecha por "el commit
existe" sino por "se verifica".**

---

## Fases entregadas ✅ (resumen; el detalle vive en `../progress.md`)

| Fase | Hito | Entregables clave |
|---|---|---|
| F0 — Spike exAgent | "encaja" (`FINDINGS.md`) | 10 flujos, validación de Session/TurnPolicy/tools |
| F1 — Motor 5e | El motor manda | `Rules`+`Actions`+`World`+`Tools`+`Dice`, WorldDriven |
| F2 — Partida durable | Jugar y sobrevivir | `Game` GenServer (D5), persistencia por beat (D3/D4), Codec (D8) |
| F3 — Robustez | Nunca se rompe | retries+breaker (D17), combate fantasma (D18), history compartido (D19), anti-loops |
| F4 — Héroes | Forjar y crecer | Builder 5 pasos + catálogos SRD ES + custom (D22) + level-up (D10–D13) |
| F5 — TurnMaster | La partida fluye | Orquestador de turnos (D25) con fallback WorldDriven |

Verde de referencia hoy: **1041 tests passed**, compile sin warnings.

---

## F6 — Pulido del producto (backlog activo)

Orden sugerido por valor/esfuerzo. Cada ítem es autónomo.

### F6.0 — Intenciones humanas al TurnMaster ✅ (D27, R17/R30)

Hecho: el brief del TM lista intents pendientes; `declare` off-turn en
`:waiting` ajeno re-evalúa al TM; fallback de esa re-eval no roba el floor;
anti-spam por firma del mapa de intents. Tests en `brief_test.exs`,
`turn_master_test.exs`, `turn_master_loop_test.exs`.

### F6.1 — Automatismos de condición → ventaja (R24 🟡→✅) ✅

Hecho: `Rules.Conditions` concentra la tabla M06 (ataque / salva / chequeo).
`Actions.attack`, `Actions.check` y `Actions.spell` (`:attack` y `:save`)
leen el modo efectivo. STR/DEX auto-fallan si paralizado/aturdido/
inconsciente/petrificado. Cancelación 5e en todos los caminos. Contrato de
tools sin cambios. Tests en `rules/conditions_test.exs` + `conditions_test.exs`.

Nota: el ejemplo del backlog mezclaba poisoned con saves de STR/DEX; RAW
poisoned no afecta salvaciones (sí ataques y chequeos). Se implementó RAW.

### F6.2 — Banner de level-up en la mesa (decisión abierta → resolver) ✅

Hecho (D33): se elimina el banner inerte. El humano sube desde la ficha
(`/heroes/:id/level-up`). Un flag "DM granted" en mesa sería reabrir XP (F7).

### F6.3 — Mesa responsive (R20 🔴) ✅

Hecho: `@media (max-width:720px)` en `game.css` — feed+input primero, rails
izquierdo oculto (iniciativa ya está en el topbar), ficha derecha en drawer
CSS (`#sheet-drawer` + label, cero JS). Dados overlay con `max-width:100vw`.
Nota en `tecnico/00-arquitectura`.

### F6.4 — Iniciativa individual por monstruo (R28 → D34) ✅

**Qué**: un beat por combatiente; el DM sigue como controlador (D34).
`World.current_combatant` nombra el slot; `WorldDriven` ya no colapsa
enemigos consecutivos; `acted_this_round` marca el monstruo, no `"dm"`.

**Hecho cuando**:
- AC-1: ADR D34 — un beat por monstruo, no un beat del DM que los recorre.
- AC-2: 3 monstruos con iniciativa distinta actúan en su orden, el DM narra
  cada uno; TurnMaster sigue respetando el orden con `cut_in` disponible.
- AC-3: tests de loop (`turn_master_loop_test.exs`) + `world_driven_test.exs`.

### F6.5 — Pase de fidelidad SRD del creador (auditoría) ✅

Hecho: `test/dragonex/heroes/srd_golden_test.exs` — 12 clases × {1, 3, 5}
= 36 oráculos a mano (humano + soldier + standard array, ASI +2 al
primario en L4). HP/AC/saves/slots/DC coinciden con SRD 5.1 y el modelo
Dragonex (warlock Pact Magic D40; paladín/ranger spellcasting a L2 R09).
Sin bugs de derivados; las simplificaciones (feats, features
por nivel salvo Extra Attack D35, Pact Magic D40, Sneak Attack D41,
    Rage D42, Reckless Attack D44, Second Wind D45, Divine Smite D46,
    Action Surge D47, Fighting Style D48, Lay on Hands D49, Bardic Inspiration D50, Arcane Recovery D51, Divine Sense D52, Turn Undead D53, Ki/Flurry of Blows D54, Hunter's Mark D55, Font of Magic D56 y spellcasting paladín/ranger L2,
`spells_known`) quedan en 🟡.

---

## F7 — Fuera de v1 (requieren ADR nuevo para entrar)

Cada uno cierra una simplificación declarada (`02-requisitos` R09/R28):

- **Extra Attack** (D35): **entregado.** `Actions.attack` resuelve N golpes
  vs el mismo objetivo; N de `Progression.attack_count/2`. No es Action
  Surge ni economía de acciones (R28 reacciones siguen fuera).
- **temp_hp** (D36): **entregado.** Daño absorbe `temp_hp` primero; no
  apila; `heal` no lo toca; tool `grant_temp_hp`; False Life 1d4+4 al
  caster. Sin reloj de duración.
- **Concentración** (D37): **entregado.** `Character.concentrating` +
  Codec; CON save al daño; rotura a 0 hp / incapacitated-class; tool
  `drop_concentration`. Sin reloj ni efecto de Bless.
- **Resistencias** (D38): **entregado.** Tres listas en `Character`;
  `apply_damage/3` por tipo (inmune / resist / vuln, cancelación);
  `temp_hp` post-mod; concentración post-resist; skeleton SRD;
  hellish resistance. Sin magic vs mundane.
- **Feats** (D13): catálogo + integración en ASI (elección feat vs +2).
- **Pact Magic del warlock** (D40): **entregado.** Tabla PHB 5.1 (huecos
  1º–5º del mismo nivel); consume el hueco de pacto; short rest restaura
  solo al brujo. Sin Mystic Arcanum ni upcast de daño.
- **Sneak Attack del rogue** (D41): **entregado.** `div(level+1, 2)` d6;
  arma finesse o ranged; advantage o aliado consciente; disadvantage
  bloquea; primer hit de `Actions.attack`; crítico 2N d6. Sin grid ni
  once-per-turn entre varias `make_attack`.
- **Rage del bárbaro** (D42): **entregado.** `Character.raging` + Codec;
  bonus melee `rage_damage/1` en cada hit; overlay B/P/S; no spells;
  STR check ventaja; termina en end_rage / 0 hp / unconscious /
  end_combat. Sin usos/día, sin reloj de 1 minuto.
- **Reckless Attack del bárbaro** (D44): **entregado.** `Character.reckless`
  + Codec; melee STR ventaja; cualquier ataque vs el bárbaro ventaja;
  expira al inicio de su turno (`set_current_combatant`); también
  end_reckless / 0 hp / unconscious / end_combat. Sin cupo/día.
- **Second Wind del fighter** (D45): **entregado.** `Character.second_wind_used`
  + Codec; cura `1d10+level` 1/rest; tool `second_wind` (DM cualquiera,
  PC sólo sí mismo); `short_rest`/`long_rest` recargan.
- **Action Surge del fighter** (D47): **entregado.** `Character.action_surge_used`
  + Codec; tool `action_surge(who, target, weapon, mode)` = 1 Acción de
  Ataque extra (`Actions.attack`, Extra Attack D35 incluido) 1/rest
  desde L2; hit o miss gasta; rest recarga. Sin L17 (2 usos). Sin
  Indomitable.
- **Fighting Style del fighter** (D48): **entregado.** Tres estilos
  (`archery` / `defense` / `dueling`) en `Character.fighting_style` +
  Codec; motor aplica el bonus (ataque / CA efectiva / daño). Builder
  default `"defense"` sin picker. Sin Protection, TWF, GWF. Paladín/
  ranger fuera.
- **Lay on Hands del paladín** (D49): **entregado.** `Character.lay_on_hands_pool`
  + Codec; pool `5 * level`; tool `lay_on_hands(who, target, amount)`
  gasta `applied` (cap max_hp) y cura a self o aliado; long rest
  recarga, short rest no; undead/construct bloqueados. Sin
  enfermedad/veneno. Sin Divine Sense.
- **Bardic Inspiration del bardo** (D50): **entregado.**
  `Character.bardic_inspiration_uses` + `inspired` + Codec; usos
  `max(1, cha_mod)`; tool `bardic_inspiration(who, target)` gasta 1
  uso y marca inspired; motor aplica 1d6 al primer
  attack/check/save/death save (primer swing, hit o miss); long rest
  recarga usos y quita inspired. Siempre d6. Sin Font of Inspiration,
  colleges, Cutting Words.
- **Arcane Recovery del mago** (D51): **entregado.**
  `Character.arcane_recovery_used` + Codec; tool `arcane_recovery(who)`
  restaura huecos gastados greedy (`div(level+1, 2)`, ningún hueco >
  5º); fuera de combate; long rest recarga, short rest no. Sin
  Signature Spells, Spell Mastery, ritual_casting como tool.
- **Divine Sense del paladín** (D52): **entregado.**
  `Character.divine_sense_uses` + Codec; usos `max(1, 1 + cha_mod)`;
  tool `divine_sense(who)` gasta 1 uso y reporta celestial/fiend/undead
  por `race`; combate permitido; long rest recarga, short rest no. Sin
  Channel Divinity, Turn the Unholy, Improved Divine Sense, 60 ft,
  cobertura.
- **Turn Undead del clérigo** (D53): **entregado.**
  `Character.channel_divinity_used` + Codec; clérigo L2+ 1/rest; tool
  `turn_undead(who)` gasta y aplica frightened a no-muertos (`race`)
  que fallen Sabiduría vs DC `8+prof+wis`; combate y exploración;
  short y long rest recargan. Sin Destroy Undead, sin Channel de
  dominio, sin Turn the Unholy, sin 30 ft.
- **Ki + Flurry of Blows del monje** (D54): **entregado.**
  `Character.ki` + Codec (restantes, default 0; máximo `level` en monk
  L2+, builder L2+ → nivel); tool `flurry_of_blows(who, target, mode)`
  gasta 1 ki SIEMPRE que se resuelvan los 2 golpes sin armas (arma
  sintética `unarmed strike`, dado de artes marciales
  `martial_arts_die/1` 1d4→1d10, DEX; N=2 fijo, sin Sneak/Smite/Extra
  Attack); combate permitido; objetivo cae a mitad → omite el segundo
  swing; short y long rest recargan al máximo (`compose_rest`);
  level-up no resetea restante. Sin Patient Defense, Step of the Wind,
  Stunning Strike, Deflect Missiles, golpe extra de Martial Arts,
  Unarmored Movement.
- **Divine Smite del paladín** (D46): **entregado.** `Character.smite_slot`
  + Codec; `divine_smite(who, slot_level)` arma pendiente sin gastar
  casilla; primer hit melee de `Actions.attack` consume el hueco y tira
  radiante (`2d8+(slot-1)d8`, tope 5d8; undead/fiend +1d8, máx 6d8).
  Extra Attack: solo el primer swing que acierte. Expira en `end_smite`
  / inicio de su turno / `end_combat` / 0 hp / unconscious. Sin Improved
  Divine Smite. Sin Great Weapon Fighting.
- **Hunter's Mark del explorador** (D55): **entregado.** Sin campos
  nuevos (la marca vive en `concentrating` como
  `"hunter's mark:<presa>"`, D37, y gasta `spell_slots` nivel 1, D46);
  tool `hunters_mark(who, target)` (ranger L2+; DM cualquiera, PC sólo
  sí mismo) valida who/target, caídos, ranger L2+, casilla y
  no-concentración antes de gastar; errores no gastan; el motor suma
  +1d6 por impacto de `make_attack` contra la presa (crit dobla los
  d6, tipo de daño del arma, RollLog patrón sneak; spells y Flurry
  nunca; match exacto case-insensitive sin fuzzy); fin sólo por las
  rutas existentes de concentración (drop, condiciones, rage, 0 hp);
  rests sin cambios. Sin bonus action economy, ventajas de tracking,
  múltiples presas, transferir ni Branding Smite.
- **Font of Magic del hechicero** (D56): **entregado.**
  `Character.sorcery_points` + Codec (restantes, default 0; jsonb
  viejo → 0; máximo `Progression.sorcery_points/2` = `level` en
  sorcerer L2+, builder L2+ → nivel, L1 → 0); tools
  `create_spell_slot(who, level)` (nivel 1..5, coste RAW
  `sorcery_slot_cost/1` 2/3/5/6/7, suma 1 casilla de ese nivel vía
  `World.gain_slot/2`, puede superar el máximo diario — RAW) y
  `convert_to_sorcery_points(who, level)` (drena 1 casilla 1..5 vía
  `consume_slot` y recupera esos puntos con `gain_sorcery_points/2`
  cap silencioso al máximo; el mensaje muestra el resultado real);
  DM cualquiera, PC sólo sí mismo; combate permitido; errores no
  mutan (missing who, caído, no hechicero, L1, nivel inválido,
  puntos insuficientes, sin casillas); SOLO long rest rellena
  (`compose_long_rest`, distinto del ki D54); level-up no resetea
  restante. Sin Metamagic, sorcerous restoration, casillas > 5º ni
  gastar puntos en otras cosas.
- **Cunning Action (Hide) del pícaro** (D57): **entregado.** Sin
  campos nuevos ("hidden" va en `conditions` vía `apply_condition`;
  M06 le añade ventaja al atacar junto a invisible); tool
  `cunning_action_hide(who)` (rogue L2+; DM cualquiera, PC sólo sí
  mismo) valida who, caído, clase/nivel y no ya oculto antes de
  tirar; el motor resuelve 1d20 + DES + prof (si "stealth" en
  `skill_proficiencies`; modo vía `Conditions.check_mode`) contra la
  máxima percepción pasiva de enemigos conscientes (`10 + SAB + prof`
  si "perception" entrenada, `Actions.passive_perception/1`; DC 10
  sin enemigos conscientes); éxito → "hidden" → ventaja en
  `make_attack` (cancela con desventaja vía `combine`; habilita
  Sneak Attack D41 sin aliado); el ataque de arma (hit o miss, todos
  los swings) y el hechizo de ataque revelan y quitan "hidden"
  (composition en el change_fn); RollLog patrón ability_check;
  errores no mutan. Sin Dash/Disengage (sin grid ni opportunity
  attacks), visibilidad/posición, sigilo sostenido, ocultarse de
   aliados, Uncanny Dodge, feats ni multiclase.
- **Danger Sense del bárbaro** (D58): **entregado.** Pasiva sin tool ni
  campos nuevos: `Rules.Conditions.save_mode/3` concede ventaja en
  TODAS las salvaciones de DES del bárbaro L2+ (combinada vía
  `combine/2`: la desventaja de condición —p. ej. restrained— se
  cancela a normal; la ventaja pedida por el modelo se mantiene); el
  corte de incapacitación reusa `@auto_fail_saves` (paralyzed/stunned/
  unconscious/petrified auto-fallan DES cortocircuitando antes de
  computar la ventaja); `mode_tag(:advantage)` existente muestra
  "(ventaja)" en el mensaje; WIS y otros saves no cambian. Sin aplicar
  prof a ability_check, Uncanny Dodge, Indomitable, Relentless Rage,
  feats ni multiclase.
- **Evasión del pícaro** (D59): **entregado.** Pasiva sin tool ni
  campos nuevos: en la rama `:save` de `cast_spell`, un pícaro L7+ ante
  un hechizo con salvación de DES recibe 0 daño si supera la
  salvación (aunque el hechizo mitigara a mitad en éxito) y
  `div(full, 2)` —redondeo hacia abajo— si falla (aunque el hechizo
  hiciera daño completo en fallo); un hechizo que ya haría 0 en éxito
  sigue en 0; la inspiración bárdica (D50) se aplica antes (un éxito
  por inspiración activa Evasión); desglose "(Evasión: sin daño)" /
  "(Evasión: mitad)"; el pícaro incapacitado auto-falla DES en
  `save_mode` y nunca llega a la rama que aplica Evasión (mismo corte
  que D58); saves no-DES y daño sin save (o `:attack`) ignoran
  Evasión. Sin Uncanny Dodge, Indomitable, Jack of All Trades, feats
  ni multiclase.
- **Multiclase**: fuera del builder actual por diseño; implicaría rehacer
  progression.
- **Marketplace de contenido custom** (D22): compartir entre usuarios.
- **Multi-nodo** (D24, pausada): Horde/HA.
- **XP como fuente de progresión** (D43): **entregado.** SUPERSEDE D10.
  Tool `grant_xp` → `World.grant_xp/2`; amount > 0; no auto-level-up;
  no toca hp/slots. Subida explícita (ficha / `level_up`). Sin
  calculadora CR/encuentro. `Accounts.grant_xp/3` intacto.
  Leftover UI ficha (`Por hitos` / callout `level < 20`) cerrado.

---

## Cómo trabaja un agente sobre este plan

1. Elige un ítem (F6.x recomendado; F7 exige ADR primero).
2. Lee el requisito `Rxx` enlazado + los docs técnicos que toque
   (`08-mecánicas`, `07-tools`, `tecnico/01` si cambia el bucle).
3. Implementa con tests (ver [`../tecnico/09-estrategia-pruebas.md`](../tecnico/09-estrategia-pruebas.md)
   para qué capa de test exige cada cambio).
4. Verifica: `mix compile` (0 warnings) → `mix format` → `MIX_ENV=test mix test`
   (907 verde). Si toca prompts/agentes: smoke con TestModel incluido.
5. Actualiza `../progress.md` (mueve el ítem) y este doc (marca el ítem). Si
   tomaste una decisión no trivial: ADR en `../decisions.md`.
6. Commit estilizado (`feat(motor): …`, `fix(hero): …`).
