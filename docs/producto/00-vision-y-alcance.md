# Visión y alcance

> **Producto.** Qué es Dragonex, para quién, qué principios lo guían y dónde
> termina su alcance hoy. Para *cómo* está construido, ver [`tecnico/`](../tecnico/).

## La idea en una frase

Un **Dungeon Master por IA para D&D 5e**: te sientas a una mesa virtual, creas un
personaje, y un LLM dirige la aventura — narra la escena, interpreta PNJs y
monstruos, y resuelve el combate — mientras **un motor determinístico de reglas**
decide cada tirada. El modelo narra; el motor arbitra.

## Por qué existe

Jugar a D&D requiere un DM humano, y eso es la barrera más alta del juego: hay
mucha más gente que quiere jugar que gente dispuesta a preparar y dirigir.
Dragonex resuelve eso con un DM por IA que:

- **No hace trampas con números.** El LLM no decide si aciertas; lo decide el
  motor 5e. El modelo solo traduce el resultado a narración. (Decisión `D1`:
  el motor es la fuente de verdad.)
- **No olleta.** El estado del mundo (HP, condiciones, hechos establecidos, slots
  de hechizo) vive en un `World` durable, no en la memoria del LLM. Lo que pasó,
  quedó. (`D16`, `D19`.)
- **Sigue el turno.** Quién actúa lo decide un orquestador dedicado (el
  TurnMaster) y lo impone el motor leyendo el `World`, no el capricho del
  modelo. (`D25`; `TurnPolicy.WorldDriven` es el fallback determinista.)

## Para quién

- **Jugadores sin grupo** que quieren una partida de D&D ahora mismo, sin
  coordinar a cinco personas.
- **Grupos pequeños** (1–4 humanos) que quieren un DM siempre disponible, o que
  quieran añadir un PNJ controlado por IA al grupo.
- **Quien quiera experimentar con agentes LLM** en un dominio rico (rol, reglas,
  estado compartido, coherencia narrativa larga) — Dragonex es, encima, un
  laboratorio de agentes aplicados a un juego.

## Principios de diseño

1. **El motor es la fuente de verdad, no el modelo.** El LLM es un narrador; jamás
   computa daño, AC o salvaciones. Invariante `D1`.
2. **Estado durable, no memoria.** El `World` y el historial viven en Postgres; el
   proceso puede morir y la partida rehidrata exactamente donde iba. `D3`, `D5`.
3. **Un solo escritor.** El `World` se muta exclusivamente vía el `Game`
   GenServer; la LiveView nunca escribe en `Repo` datos de partida. `D6`.
4. **Sanitización determinística.** Cualquier texto del modelo que se persista o
   se mande al historial pasa por `Text.scrub`. No se confía en que el modelo
   obedezca el prompt. `D7`.
5. **Offline por defecto en desarrollo.** Sin clave de API, todo sigue
   funcionando con `TestModel` (el DM no narra, pero los turnos se resuelven y
   los tests son deterministas).
6. **Construido para iterar con agentes.** La documentación, los invariantes y los
   tests están pensados para que un agente autónomo pueda añadir features sin
   romper lo que funciona.

## Dentro de alcance (v1, lo que ya existe)

- Creación de personajes 5e nivel 1 (9 razas + subrazas, 12 clases SRD,
  backgrounds, puntuaciones standard array / point buy / explícito, equipo,
  hechizos para casters, skills, idiomas).
- Contenido **custom por usuario** (armas/hechizos/objetos propios con validación
  server-side de mecánicas).
- Subida de nivel milestone (RAW: no cura; ASI en `[4,8,12,16,19]`; hechizos nuevos).
- Partidas de 1 a N participantes: humanos (teclado) y PCs IA (auto-play), más
  monstruos dirigidos por el DM.
- Combate 5e: iniciativa, ataques, hechizos (attack/save/automatic) con
  **upcasting RAW** por casilla superior, daño, críticos,
  ventaja/desventaja, condiciones, death saves, spell slots (incl. Pact Magic),
  descansos, concentración, puntos de golpe temporales y
  resistencia/vulnerabilidad/inmunidad a daño.
- **Recursos de clase y raza** (lote D35–D77): furia (con usos) y Reckless
  Attack, Second Wind, Action Surge, estilos de combate, Castigo divino, Manos
  impositoras, Sentido divino, Expulsar no-muertos, auras de paladín, ki y
  Ráfaga de golpes, Fuente de magia y Metamagia, Recuperación arcana,
  Inspiración bárdica, sneak attack, Marca del cazador, Astucia de pícaro
  (esconderse), Esquiva asombrosa, Expertise, Forma salvaje del druida, y
  rasgos raciales (Lucky, Resistencia implacable, Savage Attacks, Aliento de
  dragón, Astucia gnoma, resistencia enana al veneno).
- Narración streaming token-a-token, dado modal (2D/3D), feed agrupado por turnos.
- Multiplayer con sala de espera y slots abiertos.
- Robustez del agente: retries con backoff, circuit breaker, guardrails
  anti-puppet/anti-loop/anti-repetición, combate fantasma forzado por el motor.
- Durabilidad total: rehidrata tras kill del proceso.
- Mesa responsive (≤720px: feed+input, ficha en drawer).

## Fuera de alcance / no implementado (ver [`../progress.md`](../progress.md) § 🔴)

- **Reacciones / "preparar acción."**
- **Dotes** (fuera; ASI estrictamente +2). `D13`.
- **Multi-nodo** (Horde) — pausado. `D24`.

> Estas limitaciones son **deliberadas o asumidas**, no bugs. Si una entra en
> alcance futuro, se documenta como ADR en [`../decisions.md`](../decisions.md) y
> pasa de 🔴 a ✅ en [`../progress.md`](../progress.md).

## Escenario de éxito

> Ana abre Dragonex, se registra y se forja una maga elfa en cinco pasos. Crea una
> partida del escenario "La Taberna del Dragón Rojo", activa el auto-play para que
> su guerrero compañero lo juegue la IA, y pulsa jugar. El DM narra la taberna, el
> posadero (PNJ) les ofrece una misión, un grupo de goblins irrumpe, el motor
> tira iniciativa, Ana conjura *rayo ígneo* — el motor tira d20, calcula el daño,
> el DM lo traduce en prosa. Ana cierra el navegador; al volver días después, la
> partida está exactamente donde la dejó.

## Cómo se relaciona con el resto de la doc

- **El journey concreto, paso a paso**: [`01-como-se-juega.md`](01-como-se-juega.md).
- **Por qué se decidió cada cosa**: [`../decisions.md`](../decisions.md).
- **Qué está hecho y qué falta**: [`../progress.md`](../progress.md).
- **Cómo está construido por dentro**: [`../tecnico/`](../tecnico/).
