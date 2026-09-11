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

Verde de referencia hoy: **880 tests passed**, compile sin warnings.

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
Rage D42, Reckless Attack D44, Second Wind D45 y spellcasting paladín/ranger L2, `spells_known`) quedan en 🟡.

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
  PC sólo sí mismo); `short_rest`/`long_rest` recargan. Sin Action Surge.
- **Multiclase**: fuera del builder actual por diseño; implicaría rehacer
  progression.
- **Marketplace de contenido custom** (D22): compartir entre usuarios.
- **Multi-nodo** (D24, pausada): Horde/HA.
- **XP como fuente de progresión** (D43): **entregado.** SUPERSEDE D10.
  Tool `grant_xp` → `World.grant_xp/2`; amount > 0; no auto-level-up;
  no toca hp/slots. Subida explícita (ficha / `level_up`). Sin
  calculadora CR/encuentro. `Accounts.grant_xp/3` intacto.

---

## Cómo trabaja un agente sobre este plan

1. Elige un ítem (F6.x recomendado; F7 exige ADR primero).
2. Lee el requisito `Rxx` enlazado + los docs técnicos que toque
   (`08-mecánicas`, `07-tools`, `tecnico/01` si cambia el bucle).
3. Implementa con tests (ver [`../tecnico/09-estrategia-pruebas.md`](../tecnico/09-estrategia-pruebas.md)
   para qué capa de test exige cada cambio).
4. Verifica: `mix compile` (0 warnings) → `mix format` → `MIX_ENV=test mix test`
   (880 verde). Si toca prompts/agentes: smoke con TestModel incluido.
5. Actualiza `../progress.md` (mueve el ítem) y este doc (marca el ítem). Si
   tomaste una decisión no trivial: ADR en `../decisions.md`.
6. Commit estilizado (`feat(motor): …`, `fix(hero): …`).
