# Cómo se juega (nivel producto)

> **Producto.** Qué hace un jugador de cara a Dragonex, paso a paso, y cuál es el
> bucle de gameplay. Sin entrar en código. Para la mecánica interna de ese bucle,
> ver [`../tecnico/01-bucle-del-agente.md`](../tecnico/01-bucle-del-agente.md).

## El journey del jugador

### 1. Cuenta y heroes

El jugador se **registra** (email + contraseña) y abre su galería de héroes en
`/heroes`. Cada héroe es un personaje 5e reusable entre partidas.

Forjar un héroe (`/heroes/new`) son **5 pasos guiados**:

1. **Identidad** — nombre, raza (+subraza), sexo, clase.
2. **Linaje** — background (trasfondo) que da skills, idiomas y equipo.
3. **Equipo** — el equipo inicial de la clase, con opciones (arma principal, etc.).
4. **Atributos** — standard array, point buy o puntuaciones explícitas.
5. **Detalles** — hechizos (si es caster), backstory, y ajustes finos.

El catálogo es **SRD completo en español**: 9 razas, 12 clases, 319 hechizos, más
el **contenido custom** que el jugador cree en `/mi-contenido` (armas, hechizos y
objetos propios con mecánicas validadas).

Los héroes se pueden **editar** mientras no estén en una partida, y **subir de
nivel** (milestone) desde `/heroes/:id/level-up` cuando el jugador lo decida.

### 2. Crear una partida

Desde el lobby (`/`) el jugador pulsa **+ Nueva partida** y entra un wizard de
dos pasos:

- **Detalles** — elige un **escenario** predefinido (la taberna, la cripta, el
  asedio…) con su *story bible* (gancho, tono, PNJs, enemigos sugeridos), o uno
  **custom** (título, escena inicial, estilo de DM).
- **Personajes** — elige su héroe y opcionalmente **compañeros**: otros héroes
  propios, arquetipos predefinidos (guerrero Thane, maga Lyra, pícaro Vex) o
  monstruos del bestiario. Cada compañero puede ser **humano** (lo juega alguien
  más) o **IA** (lo auto-juega el sistema).

Si la partida tiene **slots abiertos** (multiplayer), arranca en una **sala de
espera**: el creador comparte el link, otros se unen con su héroe, y cuando todos
están, el creador pulsa **Empezar**.

### 3. La mesa

La partida se vive en `/games/:id`, la **mesa**: una pantalla con tres zonas:

- **El feed** (centro) — la narración del DM y las acciones, **agrupada por
  turnos**. Cada bloque lleva quien lo dijo y en qué asalto. Se pagina hacia
  arriba (desde los últimos ~200 eventos) con "cargar más".
- **El dado modal** — cuando alguien tira (ataque, daño, salvación, chequeo),
  salen los dados animados (2D/3D, conmutable) con el desglose: `d20 + 5 vs CA 14
  → ACIERTO`.
- **El panel del personaje** — ficha viva: atributos, HP, AC, condiciones, armas,
  hechizos, slots. La identidad del humano se asigna al personaje correcto
  automáticamente; con `?as=dm` el creador puede "ver como DM".

La narración llega **streaming, token a token**, mientras el DM "piensa". Si el
modelo falla (timeout, respuesta rota), el motor degrada con elegancia: reintenta
con backoff, y si insiste, pausa la partida con una nota en vez de romperla.

### 4. Jugar un turno

Cuando es el turno de un **personaje humano**, la mesa muestra **"Es tu turno"** y
un campo de texto. El jugador **declara** lo que quiere hacer en lenguaje natural:

> *"Conjuro rayo ígneo contra el goblin del centro."*

El DM (IA) lee la declaración, decide la intención, y llama a la herramienta del
motor que corresponde (`cast_spell`). El motor tira los dados, calcula, aplica el
daño al `World`, y devuelve el resultado. El DM lo traduce a narración. La
naración llega al feed y el turno pasa al siguiente combatiente.

Si es el turno de un **PC IA** o del **DM** (monstruos), no hay input humano: el
sistema lo resuelve solo y narra. El humano puede **activar el auto-play 🤖** en
su propio personaje para que la IA lo juegue cuando le toque.

El jugador puede **pausar** y **reanudar** la partida cuando quiera (el estado se
persiste), y **declarar fuera de turno**: la acción se encola y el orquestador
de turnos **la ve** — puede adelantarte si la iniciativa lo merece, o dejarla
para tu turno.

## El bucle de gameplay (vista producto)

```
        ┌──────────────────────────────────────────────────────────┐
        │  ¿De quién es el turno?  (lo decide el motor, no el DM)   │
        └──────────────────────────────────────────────────────────┘
              │              │              │              │
        humano PC        PC IA           DM (monstruos)   humano sin
        (declara)        (auto-play)     (narra + actúa)  auto-play (idle)
              │              │              │
              ▼              ▼              ▼
        ┌──────────────────────────────────────────────────────────┐
        │  El agente del turno lee el World + el historial         │
        │  y decide qué hacer (narra / ataca / conjura / etc.)     │
        └──────────────────────────────────────────────────────────┘
                              │
                              ▼
        ┌──────────────────────────────────────────────────────────┐
        │  El motor 5e resuelve: tira dados, aplica daño/salva/…   │
        │  El World se actualiza. El resultado vuelve al agente.   │
        └──────────────────────────────────────────────────────────┘
                              │
                              ▼
        ┌──────────────────────────────────────────────────────────┐
        │  El agente narra el resultado → feed (streaming) + dice  │
        │  El historial y el World se persisten a Postgres         │
        └──────────────────────────────────────────────────────────┘
                              │
                              ▼
                      Pasa al siguiente turno
```

Tres ideas clave para entender Dragonex desde el producto:

1. **El LLM no tira dados.** Decide *qué* intentas y lo narra; el motor decide
   *si* aciertas y *cuánto* daño. Por eso el DM "no miente".
2. **El estado es la verdad, no la memoria.** Si el DM dice que el goblin tiene
   3 PG, el `World` es el que sabe cuántos tiene de verdad. La narración describe;
   el motor cuenta.
3. **Todo sobrevive.** Cerrar el navegador o reiniciar el servidor no pierde la
   partida: el `World` y el historial viven en Postgres y se rehidratan.

## Roles dentro de una partida

| Rol | Quién lo controla | Qué hace |
|---|---|---|
| **DM** | siempre la IA | narra la escena, interpreta PNJs, dirige monstruos, arbitra el mundo |
| **PC humano** | un jugador por teclado | declara acciones cuando es su turno |
| **PC IA (auto-play)** | la IA con personalidad por clase | actúa solo cuando es su turno, con tools restringidas |
| **Monstruo / enemigo** | el DM | sus turnos se "pliegan" sobre el turno del DM |

## ¿Dónde aprender más?

- **El contrato del agente (qué tools tiene, qué reglas sigue)**: [`../tecnico/04-agentes-dm-y-pc.md`](../tecnico/04-agentes-dm-y-pc.md).
- **El trace exacto de un turno (código)**: [`../tecnico/01-bucle-del-agente.md`](../tecnico/01-bucle-del-agente.md).
- **Las decisiones de producto (por qué milestone, por qué no feats, etc.)**: [`../decisions.md`](../decisions.md).
