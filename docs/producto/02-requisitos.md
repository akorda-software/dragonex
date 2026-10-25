# Requisitos del producto

> **Producto.** El **contrato de iteración** de Dragonex: qué debe hacer la
> aplicación, con identificadores estables y criterios de aceptación verificables.
> Los agentes (y humanos) trabajan contra este doc: una feature está **hecha**
> cuando sus `AC` pasan y el estado pasa a ✅ en [`../progress.md`](../progress.md).

Convenciones:

- **`Rxx`** — identificador estable del requisito (no se renumera; si se
  descarta, se tacha con nota, no se borra).
- **`AC-x`** — criterio de aceptación verificable. Cada AC nombra **cómo se
  verifica** (test determinista, smoke, inspección) — nunca "funciona".
- **Estado** — ✅ hecho y probado · 🟡 simplificación asumida (con ADR) ·
  🔴 pendiente. El estado vivo vive en [`../progress.md`](../progress.md);
  aquí se refleja para contexto.
- Prioridad de producto (orden de importancia): **1** motor correcto ·
  **2** bucle de partida robusto · **3** creador de héroes fiel al SRD ·
  **4** mesa usable · **5** multiplayer · **6** pulido (mobile, UX).

Fuente de verdad complementaria: los ADR de [`../decisions.md`](../decisions.md)
(`D1`–`D78`), las mecánicas `M1`–`M60` de
[`../tecnico/08-catalogo-mecanicas.md`](../tecnico/08-catalogo-mecanicas.md) y
el contrato de tools de [`../tecnico/07-contrato-tools.md`](../tecnico/07-contrato-tools.md).

---

## Área A — Cuenta y héroes

### R01 — Cuenta de usuario ✅
Registro, login y logout con email + contraseña (bcrypt, session cookies).

- AC-1.1: registro → login → sesión persistente → logout, test en
  `test/dragonex/accounts_test.exs`.
- AC-1.2: rutas protegidas redirigen a login sin sesión — redirect del plug
  `:auth` en el render desconectado y live_redirect del mount hook
  (`test/dragonex_web/protected_routes_test.exs:23`).
- AC-1.3 (D249): borrar una clave o cerrar la página de Cuenta invalida su comprobación
  pendiente; una respuesta antigua no vuelve a guardarla ni sustituye una
  comprobación nueva. El callback lleva una referencia y texto cifrado, nunca
  la clave en claro; solo la LiveView vigente acepta la escritura
  (`account_live_test.exs`).

### R02 — Galería de héroes ✅
`/heroes` lista los héroes del usuario; cada héroe es un personaje 5e reusable
entre partidas (persistido como snapshot en `heroes`).

- AC-2.1: la galería muestra sólo los héroes del usuario logueado.
- AC-2.2: un héroe borrado no rompe partidas pasadas (la partida guarda su
  propia copia en `participants`/world).

### R03 — Creador de héroes en 5 pasos ✅
`/heroes/new` wizard: identidad (raza+subraza, clase) → linaje (background) →
equipo (grupos con opciones) → atributos (standard array / point buy /
explícito) → detalles (hechizos si es caster, backstory).

- AC-3.1: cada clase SRD del catálogo puede crear un héroe válido nivel 1
  (`test/dragonex/wizard_create_test.exs` y parámetricos por clase).
- AC-3.2: atributos inválidos (point buy fuera de presupuesto, array repetido)
  se rechazan server-side (`test/dragonex/heroes/heroes_validation_test.exs`).
- AC-3.3: el builder no toca DB — contexto custom inyectado, tests `async: true`
  (D9).
- AC-3.4 (D117): opciones operables con Tab/Enter/Espacio, estado seleccionado
  accesible, foco conservado y metadata nativa sin borrar la elección;
  guardar/reabrir héroe propio comprobado en navegador a 375/1440 px
  (`wizard_choice_test.exs` y recorrido real).

### R04 — Catálogos SRD en español ✅
9 razas con subrazas, 12 clases, backgrounds, equipo (armas simple/martial,
armaduras light/medium/heavy, escudos, gear), skills, idiomas y **319 hechizos**
SRD (`priv/srd/spells.es.json`, regenerable con `scripts/import_srd_spells.py`).

- AC-4.1: el catálogo mezcla builtin + SRD + custom del usuario con
  `source: :builtin | :srd | :custom` (`Catalog`, test `catalog_test.exs`).
- AC-4.2: la cuenta de hechizos SRD cargados es exactamente 319
  (`test/dragonex/heroes/srd_spells_test.exs:69`).
- AC-4.3: i18n ES/EN de catálogo y tipos de daño (`Translations`).

### R05 — Derivados nivel 1 correctos ✅
HP (dado de golpe + CON), AC (armadura + dex, con límites), iniciativa,
proficiencias, save DC, modifiers — calculados por `Heroes.build`.

- AC-5.1: ficha de un guerrero humano con array estándar y cota de malla da
  los números del SRD (test de humo en `heroes_integration_test.exs`).

### R06 — Edición de héroe ✅
Un héroe editable mientras no esté en partida activa; los cambios no afectan
partidas ya creadas (snapshot, D22 mismo principio).

### R07 — Contenido custom por usuario ✅
CRUD en `/mi-contenido` de armas, hechizos y objetos propios, con validación
server-side de mecánicas (dados parseables, kind de spell válido, ability
válida, classes conocidas). Único por `(user, kind, key)`; no compartido entre
usuarios (D22).

- AC-7.1: un arma custom inválida (daño no parseable) se rechaza con error
  accionable (`custom_content_test.exs`).
- AC-7.2: el contenido custom aparece en el builder y en la mesa con la misma
  mecánica que el builtin (consume structs, no JSON crudo).

### R08 — Subida de nivel (XP 5e, D43) ✅
El DM otorga XP en partida (`grant_xp`); no hay auto-level-up (D43;
D10 SUPERSEDED). La subida sigue explícita: `/heroes/:id/level-up`
(humano) o tool `level_up` (IA). Ficha humana: cuando `level < 20`.
`LevelUp.apply`: +1 nivel, PG (dado medio + CON + racial), retro-CON, **RAW no
cura** (D11), ASI 2 puntos en `[4,8,12,16,19]` cap 20 (D13), AC recalculada,
hechizos nuevos respetando `max_spell_level`, half-casters desde nivel 2.

- AC-8.1: subir de nivel no cambia `hp` actual si hay daño (conserva déficit).
- AC-8.2: ASI fuera de niveles ASI se ignora; cap 20 por característica.
- AC-8.3: un paladín nivel 2 gana slots de nivel 1; un wizard nivel 3 gana
  slots de nivel 2 (`test/dragonex/spell_slots_test.exs:85` y el golden
  wizard L3 en `test/dragonex/heroes/srd_golden_test.exs:196`).
- AC-8.4: la subida se **sincroniza a partida viva** vía single-writer
  (`Game.sync_hero_level_up`) preservando hp dañado/conditions/slots/AC
  (`game_sync_genserver_test.exs`).
- AC-8.4b (D124): la capacidad nueva conserva los usos gastados por nivel;
  una maga L1 agotada gana una sola casilla al subir a L2. El gasto de pacto
  se traslada al nuevo nivel y Fuente de magia conserva sus excedentes pagados.
  Merge repetido/reapertura no recargan; HP/condiciones/reloj/rest_state y
  límite diario permanecen. Motor, tool DM/TestModel y confirmación LiveView
  (`level_up_resources_test.exs`, `game_sync_genserver_test.exs`,
  `hero_level_up_live_test.exs`).

- AC-8.5 (D125): una confirmación conserva el nivel que vio el jugador;
  dos pestañas antiguas no aplican dos niveles ni consumen ASI de otro nivel.
  Aviso visible/cerrable en ficha, error de expectativa sin cambios, XP
  conservada y sync antigua rechazada sin rebajar World/baseline. Toda partida
  iniciada usa Game incluso si hay que rehidratarlo; configuración bloquea
  frente al inicio (`accounts/level_up_test.exs`, `level_up_resources_test.exs`,
  `games_sync_test.exs`, `game_sync_genserver_test.exs`,
  `hero_level_up_live_test.exs`).

- AC-8.6 (D126): ki/puntos de hechicería/Forma salvaje recién desbloqueados
  se pueden usar sin descanso; reserva viva gana solo capacidad nueva y
  conserva gasto, también con Imposición de manos o ASI de Carisma para
  Inspiración/Sentido divino. Cap sin cambio/merge repetido/codec/reapertura
  no recargan. Mesa/drawer muestra disponible/máximo desde World y oculta
  capacidad aún bloqueada (`class_resource_level_up_test.exs`,
  `game_sync_genserver_test.exs`, `game_sheet_state_test.exs`).

- AC-8.7 (D129): progresar en Forma salvaje usa la ficha original guardada
  y conserva PG/atributos físicos/CA/armas de la bestia. ASI físico/PG/CA
  nativos se restauran al revertir; ASI mental/nivel/hechizos permanecen,
  con conjuros bloqueados hasta salir de forma animal. Sync repetida/codec/
  reapertura no curan, recargan ni renuevan duración. Caducidad/reversión por
  daño recuperan la forma original progresada (`wild_shape_level_up_test.exs`,
  `game_wild_shape_progression_test.exs`, `game_sheet_state_test.exs`).

- AC-8.8 (D140): la elección ASI acepta solo las seis características y
  pasos de +1/−1 cuando ese nivel incluye la mejora. Parámetros desconocidos,
  incompletos o con tipos incorrectos producen un error visible junto a los
  controles, conservan el borrador y la conexión; un ajuste válido recupera
  el error. Cap 20/presupuesto 2 y confirmación siguen correctos, sin escribir
  biblioteca/World al elegir (`hero_asi_input_test.exs`, navegador 375/1440 px).

### R09 — Fidelidad de clase (simplificaciones declaradas) 🟡
- Pact Magic del warlock entregado (D40); upcasting RAW con tabla curada
  entregado (D74). Queda fuera Mystic Arcanum (6º–9º 1/long rest).
- Sin feats; ASI = 2 puntos (D13).
- `spells_known` sin tope modelado (D14).
- Features de clase por nivel: el núcleo SRD del lote D35–D76 está entregado —
  Extra Attack (D35), Sneak Attack (D41), Rage con usos y Furia implacable
  (D42/D72), Reckless Attack (D44), Second Wind (D45), Divine Smite (D46),
  Action Surge (D47), Fighting Style (D48), Lay on Hands (D49), Bardic
  Inspiration (D50), Arcane Recovery (D51), Divine Sense (D52), Turn Undead
  (D53), Ki/Flurry of Blows (D54), Hunter's Mark (D55), Font of Magic (D56),
  Cunning Action: Hide (D57), Danger Sense (D58), Evasión (D59), skills +
  Jack of All Trades (D60), auras de paladín (D61/D62), Wild Shape (D63),
  Uncanny Dodge (D64), Metamagic (D65), Lucky (D66), Resistencia implacable
  (D67), Indomitable (D68), Savage Attacks (D69), Expertise (D73) — y
  spellcasting de paladín/ranger a L2. Fuera siguen, p. ej.: Mystic Arcanum,
  Action Surge a L17 (2 usos), Inspiración bárdica > d6, Font of Inspiration,
  colleges/arquetipos de subclase. Cada ADR declara sus recortes exactos.
- Empate de iniciativa por DEX score y luego nombre; sin roll-off extra (D39).

> **No son bugs.** Cambiar cualquiera exige un ADR que reemplace al vigente.

---

## Área B — Crear una partida

### R10 — Wizard de nueva partida ✅
`/games/new` en 2 tabs: detalles (escenario predefinido con story bible, o
custom con título/escena inicial/estilo de DM) + personajes.

- AC-10.1: cada escenario predefinido (`Scenarios.all`) arranca una partida
  con su story bible horneada en el system prompt (D20) — el wizard persiste
  la biblia y `DM.new/2` la cuece en las instrucciones
  (`test/dragonex/scenarios_test.exs:37`).
- AC-10.2 (D117): título/escena/estilo custom permanecen visibles al volver
  atrás o cambiar de escenario dentro del asistente (`wizard_choice_test.exs`).
- AC-10.3 (D117): escenario/héroe/dados se eligen con controles nativos por
  teclado; anuncian su selección y deshabilitan compañeros ya ocupados.
- AC-10.4 (D133): estilo custom/predefinido guardado llega al request del DM
  junto con biblia/reglas, también al reabrir una partida pausada; valores
  legacy vacíos conservan el prompt base (`game_dm_style_test.exs`). No basta
  comprobar el valor guardado: se inspeccionan los messages codificados.
  Crear una partida propia comprobado desde navegador (`wizard_choice_test.exs`).
- AC-10.5 (D212, ✅): estilo DM mayor de255 caracteres se guarda completo y
  llega al request incluso tras restart. Título mayor de255 puntos de código
  devuelve error recuperable antes de insertar, en detalles y creación final;
  corregir/volver mantiene texto/héroe/compañeros. Dos tests de contexto/dos
  LiveView, DMStyle largo y30 focalizados por grafo; rojo causal2/7. Chrome
  1440/375/teclado crea19443 con476 caracteres exactos y3D. Migración text
  test/dev preserva47 estilos existentes; producción pendiente de deploy.

### R11 — Compañeros: héroes, arquetipos y monstruos ✅
El creador añade sus héroes, arquetipos predefinidos (guerrero/maga/pícaro) o
monstruos del bestiario. Cada compañero es **humano** o **IA**.

- AC-11.1: un compañero IA tiene su propio `PCAgent` con personalidad por
  clase y tools restringidas (`pc_agent_test.exs`).

### R12 — Multiplayer con slots abiertos ✅
Partida con slots abiertos arranca en **sala de espera**: link compartido,
otros usuarios se unen con su héroe, el creador pulsa **Empezar**.

- AC-12.1: `join_game` valida slot libre y añade participante
  (`games_context_smoke_test.exs:154`; las guardas de estado —`no_open_slots`,
  `already_started`, lobby `:configuring`— en el mismo archivo).
- AC-12.2: la partida no arranca hasta "Empezar"; tras arrancar no se admiten
  uniones.
- AC-12.3: URL/patch no permiten jugar como otro participante ni acceder a
  secretos del DM; solo el creador tiene vista DM (`game_viewer_authorization_test.exs`, D101).
- AC-12.4 (D121): unión/inicio bloquean y releen la fila vigente de la sala.
  Copias anteriores no consumen de nuevo la última plaza ni sobrescriben un
  World iniciado; dos uniones conservan ambas fichas. Nombres duplicados,
  variantes de mayúsculas y `DM` se rechazan sin cambios; reintentos conservan
  identidad y un segundo inicio no despausa (`game_lobby_admission_test.exs`).
- AC-12.5 (D121): selección propia inválida, sala llena/iniciada y nombre
  ocupado muestran motivo recuperable y estado actual; elegir otro héroe
  limpia el aviso. IDs inválidos no desconectan y una sala eliminada vuelve
  a partidas con mensaje. Aviso enlazado al selector, visible a 375 px por
  teclado; plaza y grupo compartidos sobreviven a recarga
  (`game_lobby_join_test.exs`, navegador con dos cuentas).

---

## Área C — La mesa (`/games/:id`)

### R13 — Feed narrativo agrupado por turnos ✅
La narración del DM y las acciones se agrupan por turno/asalto, con autor y
paginación "cargar más" (tope ~400 bloques, ventana inicial ~200 eventos).

- AC-13.1: los eventos llegan ordenados por `seq` append-only (`game_events`).
- AC-13.2: "cargar más" pagina hacia atrás sin saltos ni duplicados
  (`test/dragonex_web/game_live_test.exs:287`).
- AC-13.3: el historial paginado sobrevive a actualizaciones y se reagrupa
  por turnos; borra los fragmentos retirados por retry y puede atravesar
  páginas privadas (`game_history_live_test.exs`, D102).
- AC-13.4: la vista queda acotada a 2000 eventos/400 bloques, mantiene los
  recientes y señala el límite sin borrar la crónica persistida (D102).

### R14 — Dado modal con desglose ✅

- AC-14.9 (D208, ✅): creador, control de mesa, snapshot, hook y destino del
  evento usan la capacidad real del paquete instalado. Solo una capacidad
  autoritativa3D permite seleccionar3D; sin ella el creador mantiene2D y
  deshabilita3D con «No disponible», y la mesa muestra el modo2D sin botón
  inoperante. Preferencia anterior3D se adapta al presentar sin reescribir DB
  o World; elección por vista sobrevive actualizaciones. Control disponible
  anuncia modo/destino accesibles y rechaza cambiar durante animación.
  Tres nuevas regresiones y pruebas del wizard pasan con local y Hex. Chrome
  a1440/375 en ambos grafos confirma teclado/hook/total19/DC15, sin JS/overflow
  ni llamadas a agentes. SQL de la partida real901 permanece íntegro. Un
  fallo posterior de WebGL puede usar el fallback2D existente; esta garantía
  de disponibilidad no certifica éxito en toda GPU ni reporta ese fallo como
  nueva preferencia al servidor.

- AC-14.8 (D207, ✅): el renderer local libera los recursos que ya posee si
  falla la construcción de la escena antes de asignarse al hook. Dispose
  tolera recursos aún no creados y sigue intentando otras liberaciones si una
  falla; constructor conserva el error original. Fallback2D mantiene la tirada
  pendiente exacta y un solo asentado; repetir dispose no duplica liberaciones.
  Cinco nuevos casos Node: contexto/renderer/física/tabla y fallo de limpieza;
  rojo9/12 y13/14→verde14/14. Chrome/WebGL/Rapier real confirma liberación de
  contexto/física/tabla, fallo original y cara18/d20 con un asentado, además
  de ruta3D normal/cambio de modo/RAF/móvil sin JS.14 host locales/14 Hex verdes,
  SQL19425/901/15 facts/otra mesa/hero intactos. Candidato local sin publicar;
  Hex de producción conserva su fallback seguro. No certifica recursos que
  un constructor de terceros no llegue a entregar, toda GPU o todos los fallos.

- AC-14.7 (D202, ✅): el modal no se cierra por agotar el tiempo de lectura
  mientras todavía anima. El asentado abre una ventana de lectura de2,6s;
  si el hook no responde en10s, se muestran los grupos factuales y se abre
  esa misma ventana antes de cerrar. Un timer de fase/generación anterior no
  revela o esconde otra tirada. Cerrar manualmente sigue siendo inmediato.
  No hay nuevas tiradas ni cambios de total/World desde el cliente.

- AC-14.6 (D201, ✅): la mano y el total ya confirmados por el motor no se
  sustituyen con caras enviadas por el cliente. El paquete local revela esas
  mismas caras en 3D; geometrías no soportadas/fallo de inicialización y Hex
  sin capacidad autoritativa revelan el resultado exacto en 2D. La última
  tirada recibida durante carga se conserva. Escena asentada/oculta/sin tamaño
  detiene RAF; desmontar/cambiar renderizador libera física y contexto. Verificación
  Node de todas las caras y ciclo de vida más WebGL real y SQL sin cambios.

Cada tirada (ataque, daño, salvación, chequeo) muestra dados animados (2D/3D,
conmutable) y el desglose: `d20 + 5 vs CA 14 → ACIERTO` (FSM del modal,
`roll_format.exs`).

- AC-14.1: el desglose del modal coincide exactamente con el `RollLog`
  estructurado del motor (`roll_format_test.exs`).
- AC-14.2 (D116): iniciativa automática usa el roller de Game y publica una
  sola vez sus grupos factuales en historial/PubSub/modal, solo tras aplicar
  el cambio. Iniciativa explícita y guardas no producen tiradas duplicadas
  (`game_forced_initiative_test.exs` y navegador real).

- AC-14.3 (D161): un mínimo de daño cero conserva el subtotal y muestra la
  penalización real con «mínimo0» en crónica/modal/History. Metadatos inválidos
  no cambian el cálculo mostrado y eventos antiguos no se reescriben. Cinco
  casos nuevos y PC/TestModel→Game→Postgres→LiveView/reload, VM19438/restart y
  navegador375/1440 px lo verifican; gate2449/3 limpio.

- AC-14.4 (D194, ✅): modal muestra DC/CA del grupo factual; diálogo rotulado,
  cierre por botón/Escape y foco contenido/restaurado. Flush/cierre retrasados
  no reabren o esconden una tirada posterior; reasentado reemplaza fallback,
  cierre limpia rolling/timers y permite cambiar motor. World/dados persistidos
  no se modifican por interacción; auto-hide y hooks dic_ex siguen operativos.
  Nueve nuevos/59 focalizados y gate2663/3 limpio lo verifican. Dos vistas
  Chrome1440/375 reproducen payload persistido716 sin RNG: foco/Tab/Shift+Tab,
  Escape/Enter/44 px y lienzo conservado. Tirada nueva724 falla7vs15, Escape
  funciona; restart729/SQL conserva estado. Hardware/Safari/lector de pantalla
  y callbacks 3D sin generación tras flush posterior no están certificados.

### R15 — Panel de personaje vivo ✅
Ficha viva: atributos, HP, AC, condiciones, armas, hechizos, slots. Identidad
por humano según su sesión autenticada; "Ver como DM" para el creador (D101).

- AC-15.1: ficha compacta/detallada y tracker presentan CA efectiva y estado
  vital canónico; retirar una defensa actualiza la CA sin alterar su base.
  Distinguen caída, estabilidad y muerte, y muestran salvaciones pendientes
  (`game_sheet_state_test.exs`, D109).
- AC-15.2: las reservas propias presentan casillas restantes por nivel, dados
  de golpe y Segundo aliento desde World. Un lanzamiento vía Game y la recarga
  conservan el gasto; un caster sin reservas registradas lo indica, sin asumir
  que están completas (`game_sheet_state_test.exs`, D109).
- AC-15.3 (D118): fichas de exploración conservan todos los PCs del grupo,
  incluida caída, priorizan la propia y excluyen ausentes; fichas de escena
  adicionales no desplazan compañeros. Daño real de Game actualiza la vista
  y Postgres (`game_party_visibility_test.exs`).

### R16 — Streaming token a token 🟡
La narración llega en streaming con anti-duplicación; si el modelo falla:
reintento con backoff y, si insiste, pausa con nota — nunca feed roto.

Revisión D222: DM/PC/Game retienen los deltas de texto libre y publican solo
narrate/final_result validados. Las etapas/dados/declaraciones siguen llegando
en vivo; el preview token a token de un campo estructurado no está implementado
ni verificado. AC-16.1 comprueba truncación/retry/cierre validado en el feed;
AC-16.2 conserva pruebas del render legado. No acreditan el preview activo
nuevo del proveedor. R16 permanece abierto; no se
relaja el criterio de aceptación para considerar terminada la integración.
D234 añade la vista previa del campo `text` mediante fragmentos de argumentos
de tools (exAgent sin publicar) y la verifica live con un proveedor que
trocea; R16 se cerrará con exAgent publicado y proveedor por defecto elegido.

- AC-16.1: chunks duplicados (reintento) no aparecen dos veces en el feed
  (`test/dragonex_web/game_live_test.exs:338`).
- AC-16.2: streaming aplica la sanitización de PCs del DM y reinicia la
  burbuja al cambiar de actor (`game_table_controls_test.exs`, D103).
- AC-16.3 (D191, ✅): el indicador distingue narración/acción, actualización
  de escena, selección del siguiente turno y backoff. Tras publicarse la
  narración no mantiene cursor de escritura durante esas esperas. Pausa,
  reanudación, recarga y reinicio no dejan una etapa obsoleta; avisos de un
  Task/turno anterior se ignoran. Estado accesible sin porcentajes o tiempos
  prometidos, borrador conservado y permisos/World/eventos sin efectos extra.
  Game3/LiveView4 y retry1 lo verifican; partida real19425 con dos vistas
  375/1440, revisión/relevo, borrador/reload/teclado y cuatro capturas revisadas.

### R17 — Declarar el turno ✅
Cuando es el turno de un humano, la mesa muestra "Es tu turno" + input. La
declaración viaja `LiveView → Game.declare/3` (nunca Repo directo, D6).

- AC-17.1: declarar fuera de turno encola la intención en `games.intents` y
  se consume al llegar el turno (`game_phase0_test.exs`).
- AC-17.2: si la partida está `:waiting` en **otro** humano, encolar despierta
  al TurnMaster (D27) para que pueda priorizar esa iniciativa
  (`turn_master_loop_test.exs`).
- AC-17.3: un envío fallido conserva el borrador y muestra una recuperación;
  un envío vacío no elimina la intención pendiente (`game_table_controls_test.exs`).
- AC-17.4: el borrador sin enviar sobrevive reload/retorno de la vista DM;
  el confirmado por Game no se reenvía al recargar (D106, LiveView + Chrome).
- AC-17.5 (D112): una declaración ya resuelta conserva su texto literal
  consultable con disclosure nativo, por toque o teclado, después de un
  snapshot; texto HTML se escapa (`game_table_controls_test.exs`).

### R18 — Auto-play del PC humano ✅
Toggle 🤖 crea un `PCAgent` que juega el personaje cuando le toca; se puede
desactivar. El humano siempre puede retomar.

### R19 — Pausa / reanudar durables ✅
Pausa en cualquier momento (`:paused`), persistida; reanudar continúa el bucle
exactamente donde estaba (incluso tras kill del proceso).

- AC-19.1: matar el GenServer y reabrir la partida rehidrata estado + historial
  y el turno en curso (`test/dragonex/persistence_test.exs:16` y
  `test/dragonex/flows/session_persistence_test.exs:29`).

- AC-19.2: en pausa o con beat en curso no se anuncia «Es tu turno / Actuar»;
  se permite declarar intención como «Declarar» (`mobile_player_sheet_test.exs`).
- AC-19.3 (D191, ✅): un error transitorio del proveedor recibido después de
  pausar conserva paused. Backoff no reanuda por sí solo ni anuncia escritura;
  reanudar recupera la etapa de reintento y permite completar el mismo turno
  (`game_busy_stage_test.exs` web, proveedor bloqueado sin red).

### R20 — Mesa responsive ✅
A ≤1023px la mesa apila: feed + input primero, ficha en un cajón accesible
(`#sheet-drawer`), sin scroll horizontal. Dados ya son overlay. ≥1024px
sigue el grid 3-col. Entre721–1023px y altura≤600px, el cajón ocupa un lateral
para conservar la altura de lectura. Estilos en `priv/static/assets/game.css`.

- AC-20.1: a 375px el input queda visible y no hay overflow-x; la ficha
  se abre/cierra con el control «Ficha».
- AC-20.2: tests LiveView de la mesa siguen verdes.
- AC-20.3: el cajón móvil muestra la ficha propia también en exploración solo,
  aunque su asiento de escritorio esté a la izquierda; input «Tu acción» con
  nombre accesible (`mobile_player_sheet_test.exs` y playtest V1.4).
- AC-20.4: ficha operable con teclado/estado expandido, pausa/reanudar visible
  y controles de 44 px a 390 px; scroll conserva al lector o sigue el último
  turno según su posición (`game_table_controls_test.exs` + Chrome real, D102).
- AC-20.7 (D178): abrir Ficha móvil muestra primero los datos propios también
  tras desplegar compañeros/cerrar/reabrir; un patch mientras se lee conserva
  scroll y apertura de compañeros. Chrome375/720 comprueba PG visibles en el
  área recortada del cajón, borrador y teclado; DM mantiene Grupo, escritorio
  mantiene sus fichas. SQL de solo lectura confirma partida intacta,41
  focalizados y2549/3 limpios. Adaptación intermedia completada en D179.
- AC-20.8 (D179): entre721–1023px la crónica no se divide en tres columnas
  y sus bloques tienen máximo72ch; en horizontal812×375/900×600 abrir Ficha
  conserva altura de crónica e input visible. Los controles se alcanzan
  completos mediante Tab también a375/1024px, y ajustes abre/cancela a375px.
  Chrome comprueba ocho tamaños375–1440px, sin overflow-x ni errores JS.
- AC-20.9 (D179): la ficha propia de combate se ve al abrir el cajón y muestra
  PG/CA dentro del área recortada también a812×375; iniciativa visible y
  controles táctiles≥44×44px. Cuatro casos táctiles emulados incluyen
  exploración y combate; SQL confirma World/turnos/history iguales en ambas
  mesas.39 focalizados y2549/3 limpios. No acredita dispositivos físicos.

---

## Área D — Motor 5e (la mitad del D1)

- AC-20.6 (D118): cajón móvil permite consultar PG/CA/estados de compañeros
  en exploración/combate; apertura sobrevive a patches sin impedir datos
  factuales (`game_party_visibility_test.exs`, navegador real 375/1024/1440 px).

### R21 — El motor es la fuente de verdad ✅
El LLM **nunca** calcula: llama a `deftool`s que resuelven por `Rules`/`Actions`
y proponen cambios en el `World` (D1). El turno tampoco lo decide el modelo.

- AC-21.1: un HP/daño/AC mostrado al jugador siempre coincide con el `World`,
  nunca con texto del modelo (los tests de flows asertan sobre world).
- AC-21.2: ninguna tool permite al modelo escribir HP/daño libremente (los
  stubs legado `attack`/`spawn_character` están restringidos al framework
  test, ver `07-contrato-tools` § legado).
- AC-21.3 (D130): ficha identifica la bestia activa antes de su barra de PG,
  muestra PG originales guardados en la ficha propia y cómo volver a conjurar.
  Resumen exploración/detalle/móvil reflejan World tras sync/reload/reversión;
  snapshot incompleto dice «Sin registrar». Sin transformación no presenta
  segunda reserva ni aviso (`game_sheet_state_test.exs`, Sylvi real a 375/1440 px).

- AC-21.4 (D197, ✅): heal/grant_temp_hp/apply_condition/remove_condition/
  level_up directos requieren dm antes de inspección World/target/RNG/propuesta,
  también en resolvedor humano. Rechazo no cura, elimina veneno, altera aliados,
  crea PG temporales libres ni progresa un PC. Hechizos/features siguen por
  Rules con recurso/acción y efecto real; restart conserva el pago una vez
  antes de respuesta DM. Guardas DM/aura/nivel humano por ficha se mantienen.
  No certifica una fuente mecánica para toda adjudicación directa del DM.
  Once nuevos/103 focalizados y2692/3 limpio; Game/TestModel normal/restart
  acredita False Life/slot/dado/plazo conservados antes de curación DM nativa,
  sin cambiar veneno/aliada/nivel. Segundo aliento conserva coste/uso único.
  Partida19425/772 intacta vía SQL readonly y navegación1440/375; no se presenta
  esa navegación como una nueva llamada LLM a las tools rechazadas.

### R22 — Combate completo ✅
Iniciativa (tirada por el motor, orden imparcial), ataque con ventaja/
desventaja y cancelación 5e, críticos (nat 20, dados doblados), daño (floor 0),
salvaciones, chequeos, death saves (nat 20 revive / nat 1 doble fallo / 3-3).

- AC-22.1..n: ver mecánicas `M2`–`M6`, `M12`–`M14` en
  `08-catalogo-mecanicas` con sus tests.
- AC-22.2 (D160): el total de daño del arma nunca
  es negativo en Rules, feedback o RollLog. La penalización se suma con furia,
  Sneak Attack y marca antes del mínimo cero; Castigo divino conserva su
  componente radiante y gasto único. Cero no consume PG temporales ni provoca
  salvaciones de concentración/fallos de muerte. Nueve casos deterministas,
  incluido PC/TestModel/Session; gate2444/3, VM19437/restart y navegador
  375/1440 px verificados sin gasto ni dados repetidos.

- AC-22.3 (D196, ✅): spawn_monster/roll_initiative/end_combat requieren actor
  canónico dm antes de World/RNG/propuesta, también en resolvedor humano.
  Rechazo no introduce enemigo, dados ni cambio de fase/ronda/recursos.
  Introducción DM mantiene bestiario/nombre único/refuerzo/iniciativa automática;
  restart entre rechazo y confirmación conserva declaración sin repetir efectos.
  Rules/World puros y stubs de framework no cambian; otros mutadores pendientes.
  Once nuevos/99 focalizados y2681/3 limpio; Game/TestModel normal/restart
  confirma el permiso sin dados humanos y dos iniciativas forzadas tras spawn
  DM. Partida real19425/772 conservada vía SQL y navegación1440/375; no se
  presenta esa navegación como nueva ejecución LLM de las llamadas rechazadas.

- AC-22.4 (D219, ✅): un rechazo de control diferencia actor sin ficha,
  actor fuera de escena y controlador DM. No sugiere dm como atacante;
  muestra criaturas registradas disponibles que controla, respeta permiso
  existente y no recrea ausentes. PC ajeno sigue corrigiéndose al propio PC.
  Cinco nuevos, rojo1/5 y29 focales por grafo; roller rechazado nunca se usa.
  Game/TestModel registra criatura tras el error, luego iniciativa con dos
  dados, sin ataque fantasma/PG/reloj alterados. Obediencia live se revisa aparte.

- AC-22.5 (D226, ✅ offline): el feedback de cada golpe distingue el total
  del daño del arma de Savage/sneak/furia/marca ya incluidos. Smite radiante
  sigue adicional, inspiración pertenece al ataque, y fallo no inventa daño.
  Ocho casos deterministas/214 focales verifican dados, PG y pago de recursos,
  incluidos crítico y Extra Attack. Gates2871/3 local/2861/3 Hex limpios y
  secuenciales; la aclaración no cambia matemática.19450/46 con Actions
  verificado registra Vex10 incluido sneak5 yThane7, iniciativa/orden correctos,
  recogida/entrega×1 y cierre único. Vex no cita cifras: no acredita corrección
  aritmética del modelo. Cambios concurrentes de narración/chat/History se
  registran en el recibo; no garantiza fidelidad semántica ni beta lista.

- AC-22.6 (D247): Guiding Bolt entra en el cálculo conjunto de ventaja y
  desventaja de armas, conjuros, ráfaga y arma espiritual. Varias ventajas no
  eliminan una desventaja; el furtivo usa el modo efectivo del primer golpe,
  conservando su límite de uso y el consumo de la marca (`guiding_bolt_test.exs`).
- AC-22.7 (D247): el crítico de arma espiritual tira por separado todos los
  dados adicionales, también con upcast, y suma una sola vez el modificador.
  El daño mínimo es cero en PG, feedback y RollLog; cero no consume PG
  temporales ni provoca concentración (`spiritual_weapon_test.exs`).

### R23 — Hechizos ✅
Tres kinds (`:automatic`, `:attack`, `:save` con mitad en éxito), consumo de
slot (nivel > 0), save DC y spell attack por aptitud de conjuración.

- AC-23.1: ver `M7`–`M11`; crítico de spell attack dobla dados (test de
  regresión).
- AC-23.2 (Bless, M61/D85): +1d4 a ataques y salvaciones, incluidas
  concentración y muerte; no a chequeos/iniciativa/daño ni apilado entre
  fuentes; naturales 1/20 conservados (`bless_test.exs`).
- AC-23.3: Bless afecta hasta `2 + cast_level` objetivos únicos existentes
  y no muertos, con una acción y una casilla; errores no gastan. JSON antiguo
  y `additional_targets` funcionan (`bless_test.exs`, `flows/bless_test.exs`).
- AC-23.4: pérdida/reemplazo de concentración o plazo de 60 s retira efectos
  de su fuente; recargar no renueva el plazo (`bless_test.exs`,
  `bless_persistence_test.exs`).
- AC-23.5 (Shield of Faith, M62/D86): +2 CA efectiva contra armas y hechizos,
  sin alterar CA base ni apilar copias; suma con Defense. Consume bonus action
  y una casilla, sin bonus adicional por upcast (`shield_of_faith_test.exs`).
- AC-23.6: protección ligada al lanzador, retirada por pérdida/reemplazo de
  concentración o 600 segundos; carga conserva plazo. Twinned comparte
  concentración/casilla y protege ambos objetivos. Ver pruebas anteriores,
  `flows/shield_of_faith_test.exs` y `shield_of_faith_persistence_test.exs`.
- AC-23.7 (Heal, M63/D87): 70/80/90/100 PG a niveles 6/7/8/9, sin dados
  ni modificador; cap al máximo y mensaje con curación real. Retira únicamente
  `blinded`, `deafened`, `diseased` y sus plazos; también a PG completos
  (`heal_spell_test.exs`).
- AC-23.8: una acción/casilla, concentración previa conservada; self y caídos
  vivos válidos, muertos/constructos/no-muertos inválidos. Twinned cura dos
  objetivos distintos una vez cada uno. Errores y cambios preparados obsoletos
  se rechazan (`heal_spell_test.exs`).
- AC-23.9: JSON anterior funciona con PCAgent/TestModel y control de actor;
  PG, limpieza, casilla y acción gastadas sobreviven Postgres/Game
  (`flows/heal_spell_test.exs`, `heal_spell_persistence_test.exs`).
- AC-23.10 (Spare the Dying, M64/D88): objetivo vivo a 0 PG queda estable
  (`successes: 3, fails: 0`), sin curación ni dados; una acción, ninguna casilla,
  concentración conservada y sin gastar recursos del receptor. Rechaza muertos,
  constructos/no-muertos, PG positivos, upcast y resultados obsoletos; Twinned
  exige objetivos distintos (`spare_the_dying_test.exs`).
- AC-23.11: daño posterior rompe estabilidad con fallos nuevos; curación
  reinicia contadores; PCAgent distingue estable de muerto/moribundo y no pide
  herramientas al estable. JSON antiguo y recarga Postgres/Game conservan el
  estado (`spare_the_dying_test.exs`, `flows/spare_the_dying_test.exs`,
  `spare_the_dying_persistence_test.exs`).
- AC-23.12 (False Life, M23/D89): genera `1d4+4+5×(cast_level−1)` PG
  temporales sobre el propio lanzador, sin modificador, con una acción/casilla
  y sin concentración. Solo una tirada, reflejada en RollLog. Otro objetivo,
  casilla inválida o recursos obsoletos se rechazan; metamagia permanece armada
  (`false_life_test.exs`).
- AC-23.13: conserva el mayor valor sin acumular; menor/igual no renueva plazo,
  mayor inicia una hora nueva. Daño absorbe PG temporales primero y descanso
  largo los elimina. JSON/Postgres/Game conservan plazo y cantidad; TestModel
  lanza con `cast_level` (`false_life_test.exs`, `flows/false_life_test.exs`,
  `false_life_persistence_test.exs`).

- AC-23.14 (Lesser Restoration, M65/D90): elimina una condición entre
  `blinded`, `deafened`, `paralyzed`, `poisoned`, `diseased`, y su plazo, sin
  curar PG ni tirar dados. Selección automática solo si es única; si hay varias
  exige `condition_to_remove`. Selección inválida/ausente, muerto, ausencia de
  condición elegible o estado obsoleto se rechazan sin mutación. Una acción y
  casilla >=2, sin concentración/escalado (`lesser_restoration_test.exs`).
- AC-23.15: Twinned D65 elimina una condición por objetivo no-self distinto;
  conserva efectos no elegidos. JSON anterior/nuevo, control del actor y
  rehidratación Postgres/Game preservan condiciones, plazos y recursos
  (`flows/lesser_restoration_test.exs`, `lesser_restoration_persistence_test.exs`).

- AC-23.16 (Imposición de manos, M33/D91): `conditions_to_remove` admite
  `poisoned` y/o `diseased` sin duplicados; cada condición cuesta 5 puntos,
  además de la curación efectiva. Puede combinar ambas con curación en una acción;
  `amount: 0` permite purificar sin curar ni estabilizar. Rechaza selecciones
  ausentes/inválidas, reserva insuficiente, estados obsoletos y objetivos
  muertos/constructos/no-muertos (`lay_on_hands_purify_test.exs`).
- AC-23.17: compatibilidad del JSON antiguo, control del actor y persistencia
  de reserva, acción y condiciones/plazos restantes
  (`flows/lay_on_hands_purify_test.exs`, `lay_on_hands_purify_persistence_test.exs`).
- AC-23.18 (D100): la salvación del aura de Spirit Guardians consume
  Inspiración/Indomitable antes de resolver concentración; el mismo recurso
  no se usa de nuevo en ese daño ni en otro tick. Inmunidad no devuelve el
  recurso (`spirit_guardians_test.exs`).

### R24 — Condiciones ✅
`apply/remove_condition` persisten; `Rules.Conditions` aplica ventaja/
desventaja/auto-fallo por condición en **ataques, salvaciones y chequeos**
(tabla M06). Cancelación 5e (ventaja+desventaja=normal) en todos los caminos.

- AC-24.1: cada condición de la tabla M06 tiene test de ataque/salva/chequeo
  en `test/dragonex/rules/conditions_test.exs`.
- AC-24.2: `Actions.check` y `Actions.spell` (`:save` / `:attack`) leen el
  modo efectivo; paralizado auto-falla STR/DEX sin tirar
  (`conditions_test.exs`).
- AC-24.3: cancelación 5e se mantiene cuando se cruzan condición y `mode` del
  modelo.
- AC-24.4 (M66/D100): repetición de Hold Person y daño recurrente usan el
  roller de Game y registran grupos de dados. Re-selección, reacción y carga
  no repiten efectos de inicio de turno (`spirit_guardians_test.exs`,
  `game_start_turn_effects_test.exs`).

### R25 — Escenas y hechos durables ✅
`set_scene` (escena actual, scrubbed) y `establish_fact` (hechos canónicos,
idempotentes, cap 30, visibles para todos los agentes cada turno — D16).

- AC-25.1: un hecho sobrevive compresión del historial (vive en el world).
- AC-25.2 (D115): salida/reentrada de no-PCs registrada por DM; ausentes no
  son objetivos ni participantes de iniciativa/áreas/auras. Salir conserva
  PG/recursos, termina concentración y no equivale a muerte; PCs siguen en el grupo.
- AC-25.3 (D115): presencia sobrevive World/Codec/Game/reapertura; legado
  sigue presente. Reentrada conserva ficha/presupuesto/ledger y se incorpora
  como refuerzo; acciones preparadas rechazan objetivos que salieron y un
  spawn duplicado no renueva ficha (`scene_presence_test.exs`).
- AC-25.4 (D115): la salida del último hostil cierra combate incluso tras
  un fallo del actor; reentrada inicia combate con los mismos PG/recursos
  (`game_scene_presence_test.exs`, Game/TestModel/Postgres y arena live propia).
- AC-25.5 (D176): record_npc_statement solo admite DM y conserva una
  afirmación PNJ con fuente/dudas en facts; registrar atribución no confirma
  contenido ni hace actuar a PCs. Fuente80/contenido800, scrub/Unicode/citas
  y rechazo de fuente PJ completa/corta; NPC conocido de prefijo compartido
  permitido. Solo cambia memoria: recursos/reloj/presencia/entorno y marca
  de revisión previa iguales. Idempotencia/cap30/DB/Codec/checkpoint/replay/
  restart conservados. Brief DM/PC/TM explica la atribución; DM y PC siguen
  viendo la fuente cuando compacción omite el diálogo. Diez casos/67
  focalizados y2546/3; Maribel registra testimonio con proveedor y restart/
  reload375/1440 px. No verifica la versión ni garantiza que el modelo registre
  toda información duradera; no migra declaraciones antiguas por inferencia.

- AC-25.5b (D193, ✅): cada testimonio PNJ nuevo conserva el elapsed_seconds
  de su registro fuera de la cita; avanzar tiempo/Codec/reinicio/compacción no
  renueva la referencia. Duplicado normalizado aún conservado retiene su primera marca;
  legado sin marca no recibe una fecha inferida. Fuente/dudas/guardas/límites/
  recursos/revisión y cap30 permanecen. Brief explica los dos casos al DM/PC/TM.
  Cinco nuevos/94 focalizados y2654/3; Game37935/checkpoint/replay/restart y
  DM/PC tras compacción/86400 s conservan marca original.19425 guarda nueva
  versión en38835 y tras viaje900 s sigue igual; ambos PCs reciben marca y
  distinguen testimonio/evidencia. SQL/reinicio713/reload375/1440/teclado verdes.
  Cap30 sigue limitado: una referencia expulsada no se recupera ni se inventa.
  No interpreta «ayer» en fecha absoluta ni garantiza semántica temporal del LLM.

- AC-25.6 (D195, ✅): establish_fact/set_scene solo permiten actor dm, también
  al resolvedor humano con tools DM. Rechazo temprano no lee ni cambia World,
  datos canónicos o resultados de replay exitosos; chequeos propios siguen
  vigentes. Confirmación DM conserva agencia/scrub/idempotencia/cap/Codec y
  facts legacy sin reclasificación. Guía después de archivo remite descubrimiento
  al DM y separa prueba/testimonio; estado/chequeo/retorno se conservan al
  reiniciar entre rechazo humano y confirmación DM. Sin extracción de prosa.
  Siete nuevos/54 focalizados y2670/3 limpio; compacción DM/PC conserva facts
  y testimonio legacy.19425 inspecciona20vs15 sin facts propios, recoge hilo×1
  por DM, consulta dueño desconocido sin World nuevo y reinicia772 sin repetir
  efectos. Detalles solo en prosa no se consideran memoria durable verificada;
  otros mutadores de mundo y coherencia semántica siguen en auditoría.

- AC-25.7 (D198, ✅): el contexto de DM/PC/TM separa los facts con formato
  atribuido de los hechos establecidos. Conserva exactamente texto, fuente,
  dudas, marcas y orden dentro de cada sección sin mutar World/Codec ni
  reclasificar hechos mediante interpretación de prosa. La guía final de DM/PC
  distingue información confirmada de testimonio y no permite tratar una
  comparación de PNJ o prosa/resumen anterior como observación propia. Se
  entrega después del archivo y sobrevive compacción incluso si el resumen
  contiene una conclusión equivocada. Game conserva recursos/tiempo/facts y
  dados al responder a una consulta. La misma consulta real sobre el hilo debe
  conservar «según el zagal» sin afirmar haber visto la comparación con el
  abrigo. Ocho nuevos/46 focalizados y2700/3 limpio. Game conserva estado y
  archivo antiguo; DM/PC reciben fuentes después de compacción con resumen
  falso.19425 repite la misma pregunta796→806/6,616 s, atribución correcta en
  ambas respuestas, World igual/sin tools/dados; restart y SQL/UI verdes.
  Las pruebas de contexto no garantizan toda semántica libre del LLM.

- AC-25.8 (D199, ✅): record_npc_statement reconoce el mismo texto con
  envolturas completas de comillas no ambiguas. Un registro retenido devuelve
  su cadena original, posición y primera marca, o sigue sin reloj si era legacy;
  un cambio real de fuente, duda o contenido es otro testimonio. Nuevos registros
  omiten la envoltura externa redundante y conservan citas internas/apóstrofos.
  Citas parciales no se desenvuelven y contenido citado vacío se rechaza; los
  límites80/800 siguen sobre la entrada normalizada antes de quitar envoltura.
  Cap30, guardas DM/PC, scrub, reloj/recursos/presencia/revisión y Codec no
  cambian. Game normal y checkpoint/replay/restart conservan el primer fact.
  Sin interpretación semántica, renovación de referencias ni migración legacy.
  Nueve nuevos/43 focalizados y2709/3 limpio. Red con fixtures finales1/9;
  Game confirma actor DM, conserva legacy37935 y nuevo41535 tras replay/
  repeat/restart. SQL/UI conserva19425/806/14 facts y otra mesa íntegros.
  TestModel prueba el motor/flujo; sin nuevo beat LLM ni garantía de semántica.

- AC-25.9 (D206, ✅): una aclaración literal citada de palabras PNJ previas,
  reconocida por el preámbulo acotado de D204 en conversación de exploración,
  exige un comprobante exitoso de record_npc_statement del mismo turno DM y
  fuente antes de publicar texto final o deltas. Memoria previa sin comprobante
  no satisface la obligación; una repetición retenida sí, sin nuevo fact/reloj.
  Fuente distinta se rechaza antes de mutar y combate puede interrumpir.
  Reinicio tras confirmar recupera el comprobante sin repetir pregunta/tool.
  Single-writer/atribución/scrub/Codec/cap30 conservados; sin campos nuevos,
  extracción de prosa o reparación retroactiva. Nueve nuevos,32 focalizados
  locales/19 Hex y gates2751/3/2743/3. HTTP stock v2 pide herramientas hasta
  guardar, con Decart estricto/none; streaming v2 mantiene privado el borrador.
  Hex1.2 buffered conserva el bloqueo final.19425/884→891/7,665s añade solo
  aclaración atribuida a41535s, guarda los14 registros previos y conserva
  recursos/reloj/otra mesa/hero. Restart/reload1440/375/SQL verdes. No cubre
  todas las preguntas PNJ, verifica su verdad o garantiza relevancia/fidelidad
  de toda prosa; la guía pide registrar el límite cuando no puede aclararlo.

- AC-25.10 (D210, ✅): Brief de DM/PC/TM identifica la última entrada retenida
  de cada fuente con varias versiones, por posición y sin inferir fechas a
  partir del reloj. Conserva cada fact literal una vez y el orden dentro de
  su sección. Solo normaliza NFC/espacios/case del nombre completo al agrupar;
  apodos, roles distintos y acentos diferentes no se unen. Repetir memoria
  retenida no la promueve ni renueva su reloj; legacy sigue sin fecha conocida.
  Una entrada posterior puede aclarar fuente/límites, sin confirmar su verdad
  ni anular automáticamente otras afirmaciones. Guía efectiva conserva este
  contexto tras archivo, compacción adversa y restart entre compañeros, sin
  nuevo World/Codec/DB. Rojo5/12, cinco casos nuevos y46 focalizados por grafo;
  gates2765/3/2757/3 secuenciales limpios.
  Consulta921→934 conserva World/15 facts/recursos/reloj/otra mesa/hero, pero
  respuestas86/66 palabras y reformulación/cierre de una pregunta doble
  siguen abiertos. Entrega proyección de procedencia, no garantía semántica.

### R26 — Descansos y curación ✅
`heal` (expresión de dados, cap max_hp, resetea death saves), `short_rest`
(hit die), `long_rest` (PG + slots). Fuera de combate.

- AC-26.1 (D146): el feedback del descanso largo usa el cuerpo vigente
  después de caducar los efectos al terminar las ocho horas. Forma salvaje
  que caduca informa PG nativos; con plazo restante informa la bestia.
  La preparación no aplica tiempo/curación. Grupo comparte un intervalo;
  mensaje al TestModel y World persistido coinciden
  (`rest_wild_shape_feedback_test.exs`, `game_rest_wild_shape_feedback_test.exs`).

### R27 — Level-up in-game ✅
El DM sube nivel a NPCs/enemigos/**PCs IA** con la tool `level_up`; los PCs
humanos **siempre** desde su ficha (la tool los rechaza con mensaje directivo).

- AC-27.1: `level_up` sobre un PC humano devuelve instrucción de ir a la
  ficha, no aplica cambios (`tools_level_up_test.exs`).

### R28 — Declarado fuera de v1 (no bugs)
Las features que esta sección listaba como "fuera" entraron por ADR durante el
lote D35–D76: Sneak Attack (**D41**; sin grid ni once-per-turn entre varias
llamadas `make_attack`), Rage (**D42/D72**; bonus melee, overlay B/P/S, usos
por descanso y Furia implacable; sin reloj de 1 minuto), Reckless Attack
(**D44**; expira al inicio de su turno, sin cupo/día), Second Wind (**D45**),
Action Surge (**D47**; sin L17 2 usos), Fighting Style (**D48**; sin
Protection/TWF/GWF ni picker), Lay on Hands (**D49/D91**; incluye enfermedad/veneno explícitos),
Bardic Inspiration (**D50**; siempre d6, sin Font of Inspiration ni colleges),
Arcane Recovery (**D51**), Divine Sense (**D52**; sin 60 ft), Divine Smite
(**D46**; sin Improved), `temp_hp` (**D36**), Concentración (**D37**, reloj
**D83** y efecto real de Bless **D85**), Resistencias/vulnerabilidades/inmunidades (**D38**; sin
magic vs mundane), además de todo el lote D53–D76 (ver R09 y el
[`08-catalogo-mecanicas`](../tecnico/08-catalogo-mecanicas.md)).
Siguen fuera: reacciones como mecánica formal (el TurnMaster da interrupciones
narrativas, no la mecánica 5e), multiclase, feats (D13) y escalados de upcast
multi-objetivo salvo Bless (exclusión D74, excepción D85). Cada una requiere ADR propio
para entrar.
Iniciativa individual por monstruo → **D34 / F6.4**.

---

### R38 — Inventario narrativo durante la aventura ✅ (D190, alcance acotado)

- AC-38.1: grant_item/remove_item del DM en exploración actualizan
  inventario de PC presente y solicitan revisión de escena; cantidades enteras positivas/suma/resta, stock
  insuficiente y entradas vacías se resuelven en el motor. Nombre saneado/NFC,
  límites160 caracteres/9999 unidades/80 entradas; contexto inválido no muta.
- AC-38.2: mismo efecto confirmado sobrevive Codec/reinicio y replay del beat
  sin duplicarse por case/NFC/espacios; otro beat legítimo puede recibir más.
  Ficha del héroe reusable, PG/slots/reloj y progresión conservan su criterio.
- AC-38.3: brief y ficha detallada muestran nombres/cantidades actuales, con
  labels SRD traducidas cuando existen. Reload/móvil/teclado conservan lectura
  y no introducen escritor LiveView. Armas/armaduras/equipar/consumir/peso/
  dinero y registro global del suelo no se deducen de estos Item descriptivos.
- AC-38.4: la revisión de entorno no repite el cambio confirmado. Una escena
  idéntica solo limpia pendiente con comprobante de beat/inventario, huella
  intacta del resto del World, sin pendiente anterior y commit contra estado
  exacto. Otros efectos/legacy/timeout mantienen el criterio conservador; un
  snapshot posterior válido puede cerrar pendiente sin duplicar stock.

22 casos deterministas de Rules/tools/Game/Codec/replay/escena/contexto/UI;
110 focalizados2,8 s y2635/3 en52,6 s limpios, cinco breaker deliberados.
19425 confirma cantidades0/1 y escena; formulación original de dejar623→630
retira1 con timeout de revisión, recogida630→637 añade1 y confirma snapshot.
Reinicio/SQL/reload375/1440/teclado/22 capturas conservan recursos/hero/modelos.
No garantiza que toda formulación LLM invoque tools: continuar variantes y
latencia; posesión cuantificada no certifica semántica física o beta completa.

## Área E — Orquestación de turnos

### R29 — Turno impuesto por el motor ✅
En combate el motor impone los turnos principales por iniciativa (D113),
sin consulta redundante en relevos ordinarios. `TurnMaster` decide excepciones
explícitas y reparte exploración, con recuperación determinista; el LLM no
puede saltarse ni reordenar turnos principales.
La invariante `controlled_by?` restringe las tools al participante actual.

- AC-29.1: si TurnMaster falla/buclea/elige inválido, el Game cae a la policy
  sin deadlock (`turn_master_loop_test.exs`).
- AC-29.2: un participante no puede usar tools de resolución en turno ajeno
  (error directivo; `test/dragonex/skill_checks_test.exs:327` y la invariante
  `controlled_by?` en `test/dragonex/world_test.exs:526`).
- AC-29.3 (D100): decisiones y fallbacks del TM o del actor sincronizan el
  combatiente y resuelven sus efectos antes del siguiente beat. Los dados
  llegan al timeline/modal y al contexto del DM/PCAgent
  (`game_start_turn_effects_test.exs`, con TestModel y Postgres).
- AC-29.4 (D104): si un efecto al inicio del turno derrota al último enemigo,
  el combate termina antes de esperar la declaración humana; World y
  Postgres coinciden y se registra una sola nota (`game_start_turn_effects_test.exs`).
- AC-29.5 (D105): cada petición de relevo recibe un único World vigente;
  conserva corrección dentro del beat, intenciones e interrupciones
  (`turnmaster_context_test.exs`).
- AC-29.6 (D107): un fallo del actor conserva resultados ya aplicados y marca
  su turno principal antes del relevo; completa la ronda cuando corresponde,
  sin consumir el ledger principal por mini-turns (`game_actor_failure_test.exs`).
- AC-29.7 (D110): tras un handoff o cambio de fase, la recuperación usa slots
  pendientes del World y no repite turnos por el cursor heredado. Iniciativa
  dentro del beat liquida al actor real; apertura sin acción no consume slot.
  Ronda nueva reinicia por su primera posición, salta enemigos derrotados y
  conserva PCs caídos (`game_combat_fallback_test.exs`).
- AC-29.8 (D113): un relevo principal válido no salta ni repite slots; los
  relevos ordinarios y el cambio de ronda no hacen peticiones al TM. Conservan
  contexto del monstruo, dados, cierre por aura, PCs caídos y persistencia
  (`game_combat_handoff_test.exs`, contador del modelo y Game/Postgres).
- AC-29.9 (D116): un fallo terminal tras introducir un hostil en exploración
  abre combate y registra iniciativa antes de recuperar el relevo; conserva
  el primer slot aún sin actuar (`game_forced_initiative_test.exs`).

- AC-29.10 (D215, ✅): una iniciativa preparada se confirma solo si siguen
  presentes los mismos combatientes conscientes, con los mismos valores DEX.
  Un alta/salida/caída/cambio de DEX posterior rechaza el callback y pide una
  preparación fresca; una escena diferente conserva los dados válidos.
  Tres regresiones, rojo 1/3 y 53 focales por grafo. No rellena orden ni
  calcula nuevos dados al confirmar. D216 recupera19443/68→69; replay nuevo
  19444/44→67 incluye cuatro iniciativas tras spawn. Estos ensayos no
  certifican toda composición de tools concurrentes.

- AC-29.11 (D216, ✅): al reanudar o reiniciar una mesa idle con combate
  incompleto, los hostiles presentes con PG positivos omitidos se incorporan
  al final por nombre, como refuerzos. Conserva actor/owner, slots y turnos
  gastados, reloj/recursos/dados; no inventa iniciativa original. World y nota
  pública se guardan juntos antes de Session; rechazo SQL deja pausa y el
  retry es idempotente. No interviene con beat/checkpoint/pending_turn en vuelo.
  Seis regresiones, rojo 0/6 y 36 focales por grafo. Mesa real 68→69 incluye
  esqueleto y conserva Thane/Vex; no certifica toda concurrencia ni cierre beta.

- AC-29.12 (D225, ✅ offline): una nueva make_attack de enemigo
  presente/apto/controlado en una mesa no se ejecuta en exploración antes de
  iniciativa. Rechazo directivo antes de RNG/daño; iniciativa explícita corrige
  dentro del presupuesto del agente. Recibos pagados conservan replay.
  Dos regresiones con Game real/ExAgent/Postgres;72 focales locales y gates
  completos2862/3 local/2852/3 Hex, secuenciales y limpios. VM nueva19449/38
  muestra cuatro iniciativas antes de atacar y orden correcto; no acredita
  públicamente que se ejercitara la rama de rechazo. Otras tools ofensivas
  y sorpresa siguen fuera de esta cobertura.

### R30 — TurnMaster dramático ✅ (D25, D27)
En combate respeta `initiative_order` con excepciones explícitas (`cut_in`,
`react`); en exploración reparte con criterio dramático (`give_turn_to`,
`pass_to_dm`, `end_scene`). Mini-turnos que **vuelven** al actor interrumpido.
`acted_this_round` evita dobles turnos. El brief incluye **intenciones humanas
pendientes** (D27): el TM las considera; no las resuelve.

- AC-30.1: el catálogo de tools del TM es exactamente
  `{give_turn_to, cut_in, react, pass_to_dm, end_scene}` y **ninguna muta el
  World** (sólo registran; aplica el Game — D6).
- AC-30.2: un `cut_in` devuelve el turno al actor interrumpido al terminar.
- AC-30.2b (D110): si el mini-turn falla o su TM no decide, vuelve al
  principal aún pendiente sin refrescar sus recursos ni avanzar la ronda
  (`game_combat_fallback_test.exs`).
- AC-30.2c (D113): también una decisión válida tras el mini-turn devuelve el
  principal aún pendiente sin refresco. Una reacción humana no recibe un
  turno principal extra aunque coincida con el `give_turn_to` del TM
  (`game_combat_handoff_test.exs`).
- AC-30.2d (D114): reabrir una reacción pausada conserva su tipo y dueño;
  éxito/fallo no consumen el ledger principal del reactor ni renuevan recursos
  del dueño. Tools ya comprometidas permanecen (`game_reaction_rehydration_test.exs`).
- AC-30.2e (D248): reintentar una reacción humana, IA o de monstruo antes
  del primer comprobante conserva su tipo ante 503, `max_tokens` y cierre
  inválido, incluida pausa/reanudación. Devuelve el turno principal sin marcar
  al reactor, cambiar ronda o renovar recursos; una sola narración del turno
  y ningún dado añadido (`game_reaction_retry_test.exs`).
- AC-30.3: `Brief.turnmaster_brief` lista intents humanos scrubbed; sin
  intents no aparece el bloque (`brief_test.exs`).
- AC-30.4: un declare off-turn puede adelantar la intervención en exploración
  o una reacción en combate; si el TM mantiene al waiter, el intent sigue encolado; si el TM
  falla en la re-eval, **no se roba** el turno del waiter.
- AC-30.5 (D93/D113): el relevo forzado por D30 tras pregunta del DM se aplica sin
  petición al TM. Mini/interrupted, re-eval e intents conservan su
  camino; contador TestModel en `turnmaster_fast_path_test.exs`.
- AC-30.5b (D136): nombres cortos únicos devuelven el nombre completo del
  humano; un PNJ/IA con nombre más largo, un homónimo ambiguo o un PC no
  disponible no fuerzan al humano equivocado. Se valida presencia/capacidad
  con World. Varias personas nombradas no se eligen por orden de roster.
  La pregunta genérica recuerda al humano mediante marcadores de turno pese
  a cientos de eventos intermedios, sin mutar recursos/World
  (`text_addressed_identity_test.exs`, `game_addressed_identity_test.exs`).
- AC-30.6 (D120): una petición `request_response` válida a 1–5 PCs da un
  beat propio a cada destinatario en orden, después cierre DM (o cierre local
  acreditado por AC-30.6e) y retorno al
  humano que preguntó, sin consulta TM redundante. Origen/destinatarios son
  PCs presentes, capaces y registrados; no admite PNJs/self/duplicados ni
  una conversación nueva mientras responde. No cambia iniciativa ni recursos.
- AC-30.6b: pausa/recarga conserva solo respuestas pendientes; fallos
  terminales no repiten los beats y un destinatario incapacitado al reabrir
  se omite antes de lanzarlo. Escena nueva/combate cancelan. Re-eval muda
  conserva al humano esperando y su cola; una intención ajena mantiene su
  prioridad (`conversation_test.exs`, `game_conversation_test.exs`).
- AC-30.6c (D143): al consumir una declaración humana en exploración, un
  vocativo inicial de PCs seguido de coma y pregunta completa registra la
  cola antes del narrador, aunque este omita la tool o falle. Nombres canónicos/
  cortos únicos y orden literal; no menciones/citas/indirectas/ambiguos ni cola
  parcial para destinatarios no disponibles. Pausa/off-turn espera al consumo,
  limpiar intención cancela. Cola previa/reintentos, prioridad ajena e
  iniciativa siguen vigentes; World y recursos vuelven íntegros tras el cierre
  (`text_explicit_recipients_test.exs`, `game_explicit_question_test.exs`,
  `test/dragonex_web/game_explicit_question_test.exs`).
- AC-30.6d (D182): una pregunta humana de recuerdo/observación dirigida a
  PCs mediante el vocativo D143 se publica literalmente sin petición humana
  al modelo, si la cola registrada coincide íntegramente y el beat es manual
  en exploración, sin mini/re-eval/interrupción. Solo una pregunta completa y
  espera pasiva opcional; conserva nombres/orden y scrub. Peticiones,
  preferencias, hechizos/acciones añadidos y esperas cronometradas mantienen
  su ruta. Ambos PCs reciben esa voz/rol propio; pausa/reinicio durante la
  primera respuesta conserva pendientes sin duplicar el habla ni el turno.
  Caso mixto False Life conserva tirada y coste únicos. Seis casos,62
  focalizados y2563/3 limpios; conversación real19425 con tres runs, World
  igual, retorno/reinicio/reload acreditados (`pc_literal_speech_test.exs`,
  `game_pc_literal_speech_test.exs`). No es clasificador semántico universal.
- AC-30.6d1 (D188): las formas informativas/opinión reconocidas amplían
  la publicación literal D182, incluyendo «qué os parece» y «qué preferís».
  Una pregunta completa con vocativo inicial y espera pasiva conserva palabras/
  destinatarios/orden sin petición humana. Mismas guardas de cola manual,
  exploración y capacidad; peticiones, acciones/magia/duración añadidas y
  ambigüedades conservan resolución. Dos casos puros/dos Game nuevos,
  restart de ambas variantes y False Life con coste/dado únicos; caso real
  sobre molino elimina una espera a Maribel inventada por el narrador y
  conserva World/retorno a humano. No es clasificador semántico universal ni
  acuerdo de viaje. Supersede la exclusión de preferencias de AC-30.6d solo
  para este habla simple.
- AC-30.6e (D184): una consulta informativa/opinión PC en exploración manual
  puede terminar sin beat DM cuando Game acredita, dentro del settlement,
  World íntegro y una respuesta completa por interlocutor en orden, desde la
  acción original conservada. Prueba durable validada por Codec, recuperable
  durante un PC pendiente. Solo una pregunta y espera pasiva; peticiones de
  acción/cláusulas al mundo, nueva pregunta PC, dados incluso sin efecto,
  World modificado, fallos/parciales, otra intervención humana, historial
  incompleto, mini/re-eval/interrupción/autoplay o legado sin prueba conservan
  DM. Preferencias mantienen narrador humano. Seis casos de prueba/Codec y
  ocho Game,69 focalizados/2580 suite limpios;19425 vuelve5,574 s con dos runs
  PC, cero DM/TM/recorder/tools/dados, World igual y history DM sin cambios.
  Reinicio/SQL/reload375/1440 acreditados (`conversation_closure_test.exs`,
  `game_conversation_closure_test.exs`). Sin inferir semántica general de prosa,
  SLA ni memoria ilimitada.
- AC-30.7 (D134): las respuestas DM no borran qué compañeros IA ya actuaron.
  Un segundo turno ordinario para la misma IA cede a una persona disponible;
  tras intervenir todos los compañeros se aplica el relevo humano sin otra
  petición TM. Prioriza a quien lleva más tiempo sin participar, sin mutar
  recursos/World; el contexto del modelo contiene personas y compañeros
  servidos (`exploration_turns_test.exs`, `game_exploration_fairness_test.exs`).
- AC-30.7b: reabrir conserva esa información pese a cientos de eventos entre
  turnos; TM mudo tras una IA devuelve al humano. Declaraciones pendientes,
  preguntas dirigidas y conversaciones mantienen prioridad. Combate,
  mini-turns, re-eval y autoplay no reciben este relevo forzado; ausentes,
  caídos/incapacitados no se eligen como participantes disponibles.

- AC-30.7c (D217, ✅): después de una respuesta ordinaria DM en exploración,
  pass_to_dm y give_turn_to(dm) ceden a una persona manual elegible, también
  sin compañeros IA. Prioridad por marcadores reales; no repite beat DM ni
  adelanta viaje/retirada como consecuencia de ese self-handoff. Intents,
  conversación, combate, mini/reacción/re-eval y autoplay mantienen caminos.
  Tres nuevos, rojo8/11 y32 focales por grafo; no valida semántica universal
  de una tool ni modifica retrospectivamente 19443/107.

- AC-30.8 (D138): tras presentar una nueva mesa mixta, y antes del primer
  turno PC, una persona manual disponible recibe la primera decisión sin
  petición TM ni beat IA. Reconocimiento por marcadores, incluyendo turnos
  previos de combate/reacción; no confunde continuación con apertura.
  Preguntas/intents/conversación/mini/re-eval y autoplay mantienen sus
  caminos. Uno/cinco compañeros, pausa/reapertura/reanudación sin duplicados
  y ciclo después de una decisión humana real preservan World/recursos
  (`exploration_turns_test.exs`, `game_exploration_opening_test.exs`,
  `game_exploration_fairness_test.exs`).

### R31 — DM con tres sombreros ✅ (D23, D34)
Árbitro + controlador de monstruos (un beat por monstruo, D34) + director
narrativo. System prompt de 18 reglas, story bible horneada cacheable (D20),
budget de retries ampliado en tools de resolución.

- AC-31.1: el DM nunca narra números que contradigan el motor (guardrails +
  scrub D7; `dm_anti_repeat_test.exs`, `dm_test.exs`).
- AC-31.1b (D119): la apertura real de seis PCs no conserva gestos/citas
  inventados de Lyra/Nera; citas sucesivas/incompletas mantienen su atribución
  para streaming, Events e historial. Preserva PNJs, estados pasivos y voz
  propia del PC (`text_puppet_dialogue_test.exs`, `dm_puppet_pc_test.exs`).
- AC-31.1c (D127): nombres cortos solo se vinculan a un PC si son únicos
  entre personajes registrados; nombres completos prevalecen frente a prefijos
  de otros PCs/PNJs. La apertura `cuando Sira deja…` conserva ambiente y
  mensajero sin la acción inventada, en streaming/Events/historial. Homónimos
  ambiguos, voz propia y estados pasivos se conservan; prosa fuera de estas
  estructuras sigue bajo D29 (`text_pc_name_forms_test.exs`,
  `dm_puppet_pc_test.exs`, `game_table_controls_test.exs`).
- AC-31.2 (D94): el brief expone CA efectiva, PG temporales separados,
  estable/caído/muerto e identidad canónica sin mutar World. Pruebas
  `brief_effective_state_test.exs` y smoke `*_narrative_context_test.exs`;
  se verifica el contexto enviado, no la obediencia de un proveedor real.

- AC-31.1d (D131): un personaje registrado por tool dentro del mismo beat
  conserva su cita frente a prefijos/homónimos de PCs, en persistencia/historial
  y preview. La mesa refresca el roster antes de la siguiente petición; una
  propuesta rechazada no gana identidad y la voz PC inventada sigue retirada.
  Contexto sin handle/sesión cerrada usa el snapshot inicial
  (`events_live_roster_test.exs`, `game_live_roster_test.exs`).

- AC-31.1e (D135): sujetos colectivos/movimiento plural explícito no actúan
  por otros PCs en streaming, Events e historial. La narración real del roble
  conserva pájaro/objeto sin «El grupo cruza…». PNJs/grupos cualificados,
  consecuencias pasivas, singular propio e invitaciones permanecen válidos.
  `set_scene` rechaza la propuesta completa ajena/colectiva/vacía antes de
  mutar World/log/cola; permite escena legítima y movimiento local propio.
  Pregunta Lyra/Vex pendiente sigue en orden tras rechazo. Las instrucciones
  de avance respetan estilo/agencia (`text_collective_agency_test.exs`,
  `game_scene_agency_test.exs`, `game_collective_agency_test.exs`,
  `dm_advance_agency_test.exs`). Prosa implícita/consenso semántico siguen D29.

- AC-31.1f (D137): «al acercaros…» y cinco familias temporales plurales
  acotadas no dan por supuesto un movimiento de los demás PCs. Se retira el
  disparador local conservando entorno, movimiento singular propio, propuestas,
  preguntas y citas PNJ completas/incompletas; el texto fuera de una cita se
  valida por separado. Streaming/historial y set_scene aplican ese criterio;
  el rechazo conserva World y reapertura (`text_implicit_agency_test.exs`,
  `game_scene_agency_test.exs`, `game_collective_agency_test.exs`). No exige
  interpretar todas las alusiones semánticas ni el consenso del grupo.

- AC-31.1g (D139): observaciones propias «me dice la hora/la verdad»,
  «la luz se quiebra» y gramática «tiene:» se conservan completas en streaming,
  Events/historial y recarga. La atribución ajena exige identidad registrada,
  rol conocido o cita/dash explícitos; quiebra del sello y stats reales siguen
  retirados. Fixtures originales de tres agentes con finish_reason=stop,
  Game/reapertura/World intactos y preview/reload de cada respuesta
  (`text_observation_integrity_test.exs`, `game_observation_integrity_test.exs`
  y homónimo LiveView). No exige resolver toda metáfora o profesión ficticia.

- AC-31.1h (D141): el fixture real «Iria las recoge…, asintiendo» no asigna
  un gesto ajeno pese al pronombre. Predicados inmediatos, relativas y
  subordinadas admiten un clítico indirecto/reflexivo y uno de objeto;
  conservación local del entorno «, y el calor…» fuera de citas. Voz propia,
  PNJs, estados pasivos, homónimos y objetos coordinados conservan su criterio.
  Streaming/Events/historial/reload comparten el corte y `set_scene` rechaza
  antes de World/log/reapertura (`text_clitic_agency_test.exs`,
  `game_clitic_agency_test.exs`, homónimo LiveView y `game_scene_agency_test.exs`).
  Vocabulario de predicados/entorno acotado, sin intérprete semántico general.

- AC-31.1i (D142): dirigirse «a la posadera—.» no cambia de hablante al
  cerrar el inciso del propio PC. Mantiene destinatario/frase completa,
  incluido streaming parcial, Events/historial y preview/reload. Sujeto/
  etiqueta PNJ real en una cláusula sigue cortado; la relativa inmediata
  «la posadera, que responde…» se retira desde la respuesta y conserva la
  referencia (`text_npc_recipient_test.exs`, `game_npc_recipient_test.exs`
  y homónimo LiveView). Reconstrucción mínima de la entrega truncada,
  agradecimiento raw real independiente; gramática de roles acotada.

- AC-31.1j (D155): «La decisión queda tomada entre vosotros…» no cierra
  una decisión humana pendiente; «y os miráis un momento» no impone un gesto
  colectivo dentro de la narración propia. Filtro compartido en streaming/
  Events/historial, set_scene rechazado antes de World. Preserva preguntas,
  planes, acuerdos PNJ, citas completas/abiertas y PC solo; puntuación sola
  no activa agencia. Nueve casos y continuidad real19425 en12,137 s con World/
  biblioteca iguales lo verifican. Consenso semántico general sigue fuera.

- AC-31.1k (D156): establish_fact no permite convertir las acciones ajenas
  o consenso que rechaza set_scene en hechos canónicos. Valida actor/roster
  con la misma gramática antes de proponer; conserva NPCs/grupos cualificados,
  citas y acción propia, con sanitización D7. Cinco casos y mesa19433 offline
  verifican rechazo/corrección, mecánicas iguales y reapertura; no certifica
  procedencia semántica de cualquier hecho libre.

- AC-31.2e (D158): una pregunta humana literal a rol PNJ cualificado en
  exploración reserva la respuesta DM y devuelve control a quien preguntó sin
  una consulta adicional al coordinador. Cola durable world_recipient, JSON
  validado, instrucciones propias; no convierte una mención/plan/reporte o
  pregunta mixta en respuesta PC. Conserva prioridad de otro humano, borrador
  y recuperación con DM esperando; modelo no sustituye el destinatario.
  Diez casos y mesa19425 real8,143 s con World/biblioteca iguales/coordinador
  sin peticiones/reload375/1440 px lo verifican. Gramática acotada, sin SLA.

- AC-31.2b (D128): DM/PC reciben reservas de clase disponibles/máximas
  del World, compartidas con la ficha; incluyen agotadas y solo capacidades
  desbloqueadas. Dados de golpe provienen del ledger, cuatro flags de recarga
  y Forma salvaje activa reflejan estado real. Una conversión de puntos en
  casilla aparece agotada en el siguiente beat, sin descanso/curación implícitos
  (`brief_resources_test.exs`, `game_resource_context_test.exs`, smokes de agentes).
  Se verifica el contexto enviado; las herramientas mantienen la validación.

- AC-31.2c (D144): briefs DM/PC/TurnMaster incluyen reloj relativo y el cupo
  de descanso largo desde el mismo cálculo que valida el motor. Los hechos
  canónicos tienen prioridad sobre el último registro de escena y llegan
  también al TurnMaster. `rest_party` devuelve el reloj confirmado
  (`brief_clock_context_test.exs`, `game_clock_context_test.exs`). El registro
  no quedó garantizado por esa guía: la mañana real omite la tool; ver D145.

- AC-31.2d (D145): después de tiempo de exploración, facts nuevos o fin de
  combate, el registro pendiente sobrevive Codec/reinicio. Un DM que omite
  `set_scene` puede cerrar con una instantánea estructurada sin tools de
  reglas, validada/aplicada por Game. Mantiene cola/retorno, pausa, recursos
  y World posterior; fallo/reintento no repiten efectos. Schema obligatorio,
  salida completa y guardas acotadas de agencia en `scene_refresh_test.exs`
  y `game_scene_refresh_test.exs`. Mesa real registra cuarto/huerto y conserva
  todo tras reinicio; viajes sin esas señales y semántica general siguen abiertos.

- AC-31.2f (D165): el contexto del DM en exploración explica registrar con
  advance_time una duración declarada realmente consumida antes de narrar
  llegada, sin duplicar rests/intervalos previos ni consumir preguntas o
  propuestas pendientes. Dos smokes Game/TestModel prueban900 s/caducidad y
  restart sin repetición; el scope excluye PC/TM/combate.35 focalizados y
  gate2472/3; viaje real19425 registra el tramo anterior tras confirmación
  explícita y el siguiente hasta la taberna, conserva recursos/biblioteca/
  World al reiniciar y reload375/1440 px. La selección de tools sigue siendo
  del modelo; no garantiza resolver todas las duraciones naturales ni latencia.

- AC-31.2g (D166): un movimiento humano literal en exploración guarda la
  escena anterior en su acción. Si el DM la deja sin registrar, una instantánea
  estructurada puede actualizar solo el entorno, sin resolver tiempo/reglas
  ni mover otros PCs. Excluye preguntas/planes/IA y escenas ya registradas;
  confirmación idéntica no escribe, fallo queda pendiente/reabrible. Respeta
  cola, World posterior y cambios mecánicos pendientes. Once casos/68
  focalizados, gate2483/3 y19425 real plaza→interior con recursos/reloj34200
  intactos; restart/reload375/1440 px verificados. Vocabulario acotado y
  selección/semántica del recorder, sin garantía de latencia general.
  D195 confirma la escena mediante DM: el narrador humano ya no puede usar
  set_scene. La exclusión de una escena ya registrada y los estados legacy
  permanecen; dos fixtures verifican el nuevo permiso sin doble revisión.

- AC-31.2h (D167): una pregunta informativa literal a rol PNJ, registrada
  en exploración manual y con solo habla/espera pasiva, publica su interrogante
  saneado sin petición para reformularlo. Conserva la acción original, turno,
  cola/retorno y respuesta DM. Acciones/persuasión/gramática incierta/combate/
  autoplay/mini mantienen resolución habitual. Siete casos/69 focalizados,
  gate2490/3 y19425 real con una sola petición DM/4,536 s, World/biblioteca/
  reloj iguales; restart/reload375/1440 px y teclado verificados. El caso
  mixto con False Life conserva casilla/dado. Gramática acotada y garantía
  de recuperación D164 intacta, sin SLA ni cobertura semántica general.

  D177 incluye inicios viste/oíste/escuchaste, con tú opcional, bajo las
  mismas guardas. Tres casos nuevos y32 focalizados verifican voz exacta,
  contexto/respuesta PNJ/testimonio/reload y controles negativos; el caso
  mixto False Life mantiene costes/dados con pregunta abierta o «¿Viste…?».
 19425 vuelve en4,538 s con una ejecución DM/dos pasos y ningún humano/TM/
  recorder, solo facts cambian. Restart/modelos/recargas acreditados; sigue
  siendo gramática acotada y no una garantía sobre la veracidad del PNJ.

- AC-31.2h1 (D189): preguntas informativas literales a oficios como zagal,
  molinero/herrera/pastora/mercader/guardia/curandera, con complemento corto
  de/del opcional, conservan el interrogante saneado y respuesta PNJ/retorno.
  Todos los nombres PC del World tienen prioridad sobre el rol: coincidencias
  completas/cortas, artículos/NFC y límites de palabra impiden reservar PNJ
  para un jugador. Acciones añadidas/gramática incierta conservan resolución;
  magia mixta mantiene casilla/dado. Seis regresiones/43 focalizados y2613/3;
  request/restart pendientes, testimonio atribuido y colisión PC comprobados.
 19425: pregunta exacta, un run DM/dos pasos, solo facts cambian; reinicio y
  reload375/1440 px acreditados. Vocabulario acotado, no verdad del testimonio,
  reconocimiento universal de entidades ni garantía de latencia.

- AC-31.2h2 (D192, ✅): pregunta informativa PNJ con preposición + interrogativo
  (de qué, por qué, con quién, hacia dónde, desde cuándo…) conserva las palabras
  del jugador y no solicita un narrador humano. PNJ/cola/retorno e identidad
  PC siguen vigentes; magia/pago/movimiento/duración o texto adicional conserva
  resolución normal. Reinicio no duplica habla ni respuesta o testimonio.
  Seis nuevos/86 focalizados y2649/3; magia/restart en ambas rutas.19425
 658→665 conserva habla y World, solo DM con un reintento transitorio;
  preparación/métricas parciales documentadas, sin comparación causal de latencia.

- AC-31.2h3 (D204, ✅): una cita completa dirigida al mismo rol PNJ admite
  hasta tres interrogantes informativos y un preámbulo acotado «cuando dijiste…».
  Comillas emparejadas, prefijo/espera pasivos y prioridad PC validados; no
  incluye acciones exteriores, otras voces, peticiones persuasivas ni signos
  incompletos. Conserva literalmente la intervención sin narrador humano;
  magia mixta sigue resolviendo casilla/dado y restart no duplica la pregunta.
  Tres regresiones nuevas, rojo13/16 y verde23 adyacentes.19425/869→877 y
  877→884 conservan las palabras y World; una respuesta falla por argumentos
  inválidos y la siguiente recupera por D205. TestModel prueba registro atribuido
  sin reescribir el anterior; la aclaración real sigue solo en prosa. No es
  reconocimiento universal, verdad del testimonio ni garantía de memoria durable.

- AC-31.2h4 (D213, ✅): un nombre propio único de 3–40 caracteres con inicial mayúscula,
  roster PC no vacío y ausencia de identidad/primer nombre PC permite pregunta
  literal PNJ; «¿Sabes si…?» es informativa. Guardas de cita/espera/consecuencias
  y hasta tres preguntas se mantienen; multiword/descripciones/contexto ausente
  conservan la ruta normal. Cuatro nuevos/rojo 9/12/50 focales por grafo; restart
  no duplica voz/memoria y magia mixta cobra slot/dado. El sibling v2 entrega
  guía de envelope sin relajar schema/codec/validación: 131 focales. Consulta
  19443/21→28 conserva voz humana exacta, responde Ada y registra duda/fuente
  sin retries inválidos; solo facts cambia. No certifica verdad o modelos en
  general; beta/campaña siguen abiertas.

- AC-31.3 (D132): el modelo recibe las reglas/biblia del DM como prefijo
  system con historial compartido no vacío, también tras compactar. No basta
  que el constructor o params.instructions las contengan; la codificación
  de messages debe enviarlas. Resumen/conversación se conservan y el rol
  no se duplica entre pasos de tool (`agent_instructions_delivery_test.exs`).

- AC-31.3a (D214, ✅): si ya existe prosa pública intermedia no vacía del
  mismo game/actor/turn_id, cada continuación recibe una sola guía de no
  repetirla tras tools y conservar sus resultados. Sin esa evidencia no se
  añade. Solo cambia request_messages: conserva eventos, historia y recibo
  de finalización; no consulta texto secreto ni oculta prosa similar.
  Tres regresiones, rojo 0/3 y 27 focales por grafo verifican entrega real
  y scope, no obediencia o novedad semántica general del modelo.

- AC-31.3b (D220, ✅): desde la segunda petición del mismo beat DM/PC,
  el modelo recibe un único World vigente desde SharedState, con los tipos
  de participantes reales. Objetivos/PG/stock/recursos confirmados prevalecen
  sobre el resumen inicial. World.combat_over? indica que ya no quedan
  enemigos presentes con PG positivos, sin cerrar/adelantar el turno desde
  la capability. Primera petición/contextos ajenos no reciben esa foto;
  cambios de stock sustituyen solo la proyección anterior. Cinco regresiones,
  rojo2/5 y17 focales por grafo: Game humano/Vex, datos/dados/reloj/SQL exactos,
  canonical/Events sin foto. No garantiza obediencia semántica universal.

- AC-31.3c (D221, ✅): el resolutor humano general publica su declaración
  original del mismo game/actor/turno, preservando herramientas y resultados.
  No publica prosa/deltas inventados; final no vacía termina la voz literal,
  truncación/filtrado/vacío/cancelación no. History conserva su condición de
  intención, visibilidad y texto íntegro. Retry/restart tras efectos reusa
  acción/recibos, sin golpe doble; fallo definitivo avisa como sistema.
  Quince regresiones/93 focales por grafo, incluyendo contexto400, recogida,
  autoplay y fuente equivocada. Bypass literal reconocido conserva su ruta.
  19446 acredita ataque declarado, recogida y entrega con voz exacta/stock
  íntegro tras restart UI/reload; no garantiza fidelidad o memoria del DM.

- AC-31.3d (D222, 🟡): el contenido público de DM/PC se recibe mediante un
  campo de narración validado, separado del texto libre/deltas auxiliares.
  Un cierre solo se publica tras una call de output aislada y su retorno
  exitoso de este run, con esperas/testimonios obligatorios resueltos. Rechazo,
  truncación, filtrado o cancelación no crean comprobante ni repiten efectos
  pagados. La voz manual sigue siendo su intención original. Base verificada
  por 15 casos en ambos grafos y un caso de transporte ReqLLM stock;
  integración por defecto DM/PC/Game escrita y verificada con19 casos nuevos
  de Game: declaraciones explícitas, retry/pausa/recovery, efectos/RNG únicos
  y publicación/comprobante SQL atómicos, incluidos cierres sin tools.
  Respeta una pausa manual si después llega cierre inválido/truncado, sin
  lanzar otro retry de Game. 271 focales locales/269 Hex, incluyendo el
  transporte stock con output y memoria PNJ, más9 y30 adicionales por grafo
  de espera/PNJ/iniciativa SQL y voz/memoria/agencia/escena. Más tandas local/Hex:
  25/23 PNJ/escena/ReqLLM retry,55/55 efectos/persistencia/ciclo de vida,
  68/68 mesa web/reacciones/progresión,13/13 hechos/antibucle,17/17 iniciativa/
  relevo,21/21 TurnMaster y3/3 lobby/ficha móvil.109 archivos anteriores
  migrados explícitamente y gates completos de integración D222:2858/3 local y2849/3 Hex,
  secuenciales y limpios; compiles test140/prod Hex133 limpios. Pendiente la
  actualización verificada del comportamiento de R16. Exige además una
  partida live nueva conservando la reproducción 19446/42; no garantiza
  fidelidad semántica de lo escrito dentro del campo público.
  Nueva19447/52 acredita ataque humano/dados, combate/casilla y recogida,
  pero falla en entrega por error de retención6300/4096 y vuelve al humano
  sin resolverla. Conserva objeto/fuente/recursos tras restart/reload; prosa
  DM repetida. D223 tiene regresión offline de causa/retry/inventario pagado
  sobre v2 local y gates posteriores2859/3 local/2849/3 Hex; no certifica
  corrección live ni cierra este AC.
  Tras activar D223/D224,19448/48 recoge/entrega×1 y guarda cierre único;
  entrega11,541s sin retry. No reproduce el error de retención. El bandido
  ataca antes de iniciativa y otra vez en combate; Vex suma en prosa sneak
  ya incluido en daño13. Conservar esos defectos y verificar D225, sin dar
  por cerrada fidelidad semántica o beta por el cierre del encargo.
  Con D225 activado,19449/38 respeta iniciativa/orden, recoge/entrega×1 y
  registra cierre único sin retry. Conserva una cita PC repetida y testimonio
  PNJ indirecto. Reload1440/375 mantiene SQL/recursos/fuente y referencias;
  no acredita públicamente el rechazo de admisión ni cierra R16 o este AC.
  19450/46 repite el recorrido con D226: iniciativa antes de ataques, Vex10/
  Thane7, recogida×1/retirada×1/cierre único. Fuentes concurrentes D227
  registradas; testimonios PNJ indirectos y un fact histórico que conserva
  la ubicación anterior del objeto. No cierra fidelidad/R16/este AC.

- AC-31.2i (D170): una espera humana literal afirmativa con duración explícita
  en exploración guarda segundos/reloj inicial en su acción. El DM no puede
  cerrar/publicar una respuesta final pendiente: debe registrar el intervalo
  completo o una interrupción0..duración; el motor aplica reloj/caducidades
  una vez. Omisión persistente pausa y permite reanudar sin redeclarar. No
  activa preguntas/propuestas/condicionales/retellings/rests/viajes/intervalos
  múltiples. Dieciséis casos/27 focalizados y19425 real300 s/restart/reload
  lo verifican. Gramática acotada a esperas explícitas, semántica general abierta.

- AC-31.2j (D171): una espera literal puramente pasiva en exploración manual
  publica la declaración original saneada sin petición humana para reformularla
  ni aplicar el reloj. El DM recibe duración/fuente y resuelve por D170; hasta
  entonces el reloj permanece igual. Cola pausada no publica antes del turno;
  restart conserva una sola voz humana. Gramática mixta/incierta, hechizos,
  combate/autoplay/mini/conversaciones/interrupciones mantienen sus controles.
  Siete casos/29 focalizados y19425 real180 s/restart/reload lo verifican;
  el hechizo mixto gasta su casilla/dado. No garantiza latencia general.

- AC-31.2k (D172): una revisión pendiente tras una espera aislada puede
  confirmar la escena idéntica solo con fuente/duración/reloj y huella del
  estado anterior coincidentes. Game revalida al aplicar y limpia únicamente
  la marca, sin reescribir entorno/log/recursos. Facts, recursos, escena,
  tiempo adicional, snapshot obsoleto o una revisión anterior impiden ese
  permiso. Una final DM ya publicada permite recuperar solo recorder, sin
  repetir voz ni intervalo. Diez casos/53 focalizados incluyen pausa/restart;
  las dos muestras reales actualizan escena, por lo que el caso idéntico queda
  acreditado offline. No amplía globalmente la aceptación de escenas pendientes.
  D175 observa dos confirmaciones idénticas con proveedor:15 s por fuente
  distinta, escena/recursos iguales y marca pendiente limpia.

- AC-31.2l (D173): el recorder recibe en los messages reales del proveedor
  la separación entre entorno físico establecido y diálogo/ofertas/rumores/
  gestos PNJ. Registrar un nuevo entorno conserva íntegra la conversación,
  recursos, intervalo y comprobante, también al reiniciar. Un smoke Game y27
  focalizados verifican entrega/persistencia. La muestra real retira pregunta/
  oferta de la escena, pero conserva detalles transitorios: es una guía al
  modelo, sin garantía determinista de clasificación semántica ni migración.

- AC-31.2m (D175): una espera deliberada reconocida por D170, sin conversación
  activa prioritaria, selecciona guía DM de espera antes de limbo/default.
  Recibe esa guía en messages antes/después de advance_time: permite ambiente
  estable, evita órdenes de cierre de hilos por novedad y distingue reloj
  relativo/hora del día. Una interrupción coherente sigue permitida; su
  parcial5 s y restart no cobran el intervalo restante. Reiniciar antes de
  resolver conserva guía, voz humana única y una aplicación de tiempo. Las
  guías de avance normales/atascos siguen disponibles. Cuatro casos,46
  focalizados y2536/3; dos esperas reales15 s/recursos/restart/reload verdes.
  Es un contrato de selección/entrega de contexto, sin garantía semántica
  general ni corrección retroactiva de afirmaciones PNJ.

- AC-31.2n (D183): el Game selecciona explícitamente contexto de conversación
  para el anti-repeat del DM. El cierre deja de exigir ambiente y una repetición
  detectada no recibe simultáneamente la orden de cambiar olores/sonidos/luz.
  Fuera de conversación se conserva la guía ordinaria; agencia, PNJs, tools,
  lengua y retorno humano siguen vigentes. Tres Games prueban requests con
  historial repetido, dos intercambios, reinicio pendiente sin nuevas voces PC
  y testimonio PNJ persistido.42 focalizados y2566/3 limpios. Dos muestras reales
  preservan World/reinicio/reload, pero la final todavía repite tarde tibia:
  verifica entrega de instrucciones coherentes, sin certificar prosa libre de
  repetición (`game_conversation_pacing_test.exs`, `dm_anti_repeat_test.exs`).
- AC-31.4 (D181): History entrega a los agentes los resultados de dados
  confirmados sin perder distinciones: ataque/daño crit diferente de hit,
  fail de muerte explícito y crit_fail como dos fallos. Success/failure/revive
  conservan su significado; no se recalcula el resultado desde el dado.
  Tres casos Actions/RollLog con claves átomo/JSON y un Game comprueban
  contadores/PG, dos peticiones PC con prefijo propio y reinicio con PID
  distinto sin tiradas ni cambios de World/eventos. Control negativo1/4,
 78 focalizados y2557/3 limpios. Dos conversaciones reales conservan el
  mundo; ambos PCs recuerdan el crítico en la segunda. No acredita semántica
  general, SLA ni memoria fuera de la ventana400 usada por el Game.
- AC-31.4b (D186): cuando una tirada sale del contexto400, los narradores
  reciben hasta32 dice anteriores con seq/asalto/fase y resultados registrados,
  como archivo parcial dentro del prompt actual. Filtro por partida/visibilidad
  antes del límite y revalidado en History; sin duplicar recientes, recalcular
  reglas ni inferir recursos vigentes. Habla local/final recuperada sin modelo
  omite la consulta; recorder mantiene reciente público. Índice parcial/9ª
  migración dev/test. Seis casos puros/compresión efectiva, dos DB y dos Game
  prueban límites, privacidad, crítico/daño/death_save/mínimo y reinicio sin
  volver a tirar.77 focalizados/2597 suite limpios;19425 con eventos24–25 fuera
  de400 recibe y verbaliza20 natural,25 vsCA15 y daño18, World íntegro y dos
  runs PC. No acredita pasado ilimitado, recuperación de escenas/testimonios
  ni diversidad de prosa (`history_roll_memory_test.exs`,
  `games_roll_memory_test.exs`, `game_roll_memory_test.exs`).
- AC-31.5 (D185): el historial de eventos enviado a modelos respeta la misma
  visibilidad pública/DM que el feed. Default, PCs, resolución humana y
  recorder solo all; el DM explícito recibe all/dm. Game usa participante,
  aunque el narrador humano comparta Server con DM. Filtra antes de headers,
  coalescing y compresión; audiencias desconocidas/ausentes y tools excluidos,
  notas privadas intactas en DB. Cinco casos puros/recorder y dos Game verifican
  mensajes efectivos/roles y reinicio pendiente sin duplicados. Controles
  filtro0/7/selección DM5/7,67 focalizados/2587 suite limpios; SQL y recargas
 19425 sin cambios (`history_visibility_test.exs`, `game_history_visibility_test.exs`).
  Solo permisos de game_events, sin inferir secretos en facts/story_bible.

### R32 — PCAgent con personalidad ✅
Un agente por PC IA: voz por clase, tools restringidas (sin escenas/monstruos/
condiciones/nivel), `instruction/3` adaptativa (caído→death_save,
combate→targets, exploración), anti-loop Jaccard.

- AC-32.1 (D120): el agente que responde recibe la pregunta registrada y el
  historial de la respuesta anterior, actúa como su propio personaje y no
  recibe una instrucción de viaje, tirada o gasto de magia. Game/TestModel y
  mesa real de seis verifican actores y recursos; el reconocimiento semántico
  de la declaración para llamar `request_response` depende del modelo fuera
  del vocativo inicial literal registrado por el motor desde D143.
- AC-32.1b (D192, ✅): vocativo PC con pregunta informativa precedida por
  preposición conserva la voz literal. Cada destinatario recibe la pregunta
  registrada; pregunta simple conserva el cierre sin DM cuando lo acredita
  el motor. Guardas, magia mixta, reinicio y recursos permanecen coherentes.
 2649/3;19425 consulta la pista tras viajar900 s: Lyra/Vex recuerdan origen/
  hatillo y vuelven en5,056 s sin humano/DM/TM/tools ni cambios World. Reinicio,
  SQL/reload375/1440/teclado comprobados; no garantiza fidelidad semántica general.
- AC-32.1c (D211, ✅): de una a tres preguntas informativas/opinión consecutivas
  a los mismos PCs conservan la voz literal del humano y pueden cerrar sin
  petición DM cuando el comprobante/huella/eventos lo acreditan. Cada pregunta
  debe calificar; acciones exteriores/intermedias, petición de acción, espera
  cronometrada, cuarto interrogante o identidad incierta conservan resolución.
  Cláusula/vocativo adicional en cualquier pregunta conserva DM; una nueva
  pregunta del respondedor, dado aun sin efecto World, magia o intervención
  pendiente también. Cap800, scrub, single-writer, World/Codec y prioridad
  permanecen. Reinicio conserva comprobante/pregunta y una voz humana; magia
  mixta gasta/tira una vez. Seis nuevos, rojo20/26,64 focalizados por grafo
  y gates2771/3/2763/3 secuenciales limpios.
  Consulta idéntica934→944/4,061s publica palabras exactas de Mara, dos voces
  PC y retorno directo; World/15 facts/reloj/recursos/otra mesa/hero iguales,
  UI1440/375/SQL verdes. No certifica semántica, toda gramática o SLA.

- AC-32.2 (D123): la narración de un PC conserva su voz/preguntas y retira
  acciones/citas de otros PCs; la relativa real `Lyra, que sigue hojeando…`
  no llega a persistencia ni al historial del siguiente agente. Streaming
  usa el mismo recorte. Estados pasivos/voz propia/PNJs se conservan y un
  verbo posterior de PNJ no se atribuye al PC. Lista/estructuras curadas,
  con límites D29 (`text_puppet_dialogue_test.exs`, `game_conversation_test.exs`).
- AC-32.3 (D132): el modelo recibe el prompt de identidad/voz de su propio
  PC al usar el historial común de eventos; se verifica el mensaje system
  codificado para el proveedor (`agent_instructions_delivery_test.exs`).
- AC-32.4 (D168): la respuesta pendiente recuerda su personalidad de clase
  junto a la pregunta y permite coincidir con otro PC usando palabras propias,
  sin copiar frases/gestos ni inventar desacuerdo/hechos. Conserva historia del
  predecesor, turno/recursos y scope normal/combate/caído. Tres casos/39 focalizados,
  gate2493/3 y19425 real10,198 s con acuerdo formulado de otra manera verifican
  la entrega. No se filtran coincidencias ni se garantiza originalidad semántica.

- AC-32.4a (D187): responder una pregunta no obliga a proponer otra acción
  ni decorar con gestos. Prefijo estable, instrucción y nudge activo ofrecen
  guía compatible; permite repetir datos confirmados. Game selecciona el
  contexto desde la petición vigente. El antibucle usa las dos narraciones
  públicas más recientes del actor en40 eventos; duplicados anteriores o
  notas privadas no disparan la guía ni aparecen en ella. Cuatro regresiones
  del detector y dos Game/TestModel verifican mensajes efectivos, historia
  del compañero anterior, World íntegro y recuperación de respuesta pendiente
  sin repetir al humano. La ruta libre y las preguntas/peticiones al mundo
  conservan sus contratos. No certifica originalidad semántica del LLM.

- AC-32.4b (D200, ✅): una respuesta pendiente recibe después del archivo
  de dados guía condicional para recomendaciones: opción/razón propia y
  criterio de clase/trasfondo vigentes, sin copiar plan/justificación anterior,
  forzar desacuerdo o cambiar hechos. Permite coincidir aportando un criterio
  respaldado o reconocer que no hay otro aporte. Preguntas de memoria/datos
  siguen sin obligación de proponer. Distingue hipótesis/prueba: ausencia de
  testimonios no confirma destino o identidad. No mueve PCs, gasta recursos,
  ejecuta planes ni encadena preguntas; decisión humana preservada. Contexto
  se entrega tras compacción y restart; combate/caída/DM/turno libre excluidos.
  Consulta832→842 aporta contraste independiente de indicios y preguntas
  sin revelar pistas, conservando World y decisión humana. Cambió también
  modelo/adaptador: no se atribuye la diferencia solo al prompt. Persistió
  una imprecisión de referente («lejos» abrigo→hilo). Entrega y caso acotado,
  no garantía de originalidad ni fidelidad semántica general.
  Refinamiento: permite acuerdo breve cuando el resumen anterior conserva
  fuente/dudas y exige corregir contradicciones. Veinte focalizados en cada
  grafo verifican entrega/compacción/restart. Consulta852→862/9,177s conserva
  World y decisión humana, pero sigue repitiendo datos e introduce imprecisiones.
  El referente del testimonio original es ambiguo: calidad semántica abierta.

- AC-32.4c (D209, ✅): con un recibo de acción verificable de la pregunta
  vigente, la guía final del siguiente compañero conserva intervenciones
  públicas completas de destinatarios anteriores, atribuidas a su voz. Ancla
  seq/fuente/texto exactos; borradores/privados/otras preguntas/no publicación
  no inventan respuestas. Sanitiza y omite entero un texto mayor de1800
  caracteres, sin cortar sus dudas finales. La proyección permanece después
  de compacción adversa o restart del segundo compañero, sin repetir al
  primero ni escribir World. Sin ancla en400 eventos se conserva la guía normal.
  Respuestas pendientes piden diálogo directo en1–2 frases cortas, sin narrador/
  gestos, y propuestas/pasos de investigación solo cuando se solicitan.
  Voz/criterio de clase/trasfondo y guardas de combate/caída/DM/turno libre
  permanecen. Seis casos nuevos,27 focalizados por grafo y gates2760/3/2752/3.
  Dos consultas reales conservan World/15 facts y retorno humano; la última
  no añade gestos narrados, pero76/61 palabras y matices de fuente siguen
  pendientes. Es entrega del contexto/formato, no fidelidad semántica general,
  originalidad, memoria ilimitada o un límite duro de longitud de respuesta.

---

## Área F — Robustez y persistencia

### R33 — Persistencia por tool confirmada y beat ✅
Tras cada beat: `games.world` (jsonb vía `Codec`, D4/D8) + evento append-only
en `game_events`. La partida se reconstruye por `game_id` (D3, D5).

- AC-33.1: world round-trips struct→jsonb→struct sin pérdida (campos nuevos
  de `Character` requieren `Codec.encode/decode` o **no sobreviven**).
- AC-33.1a (D169): la compresión de narraciones antiguas preserva UTF-8,
  atribuciones y doce voces recientes completas; ¿/¡/espacio inseparable no
  generan bytes inválidos tras saneamiento. Tres regresiones/18 focalizados
  codifican JSON del proveedor, y Game aplica una espera/escena y reinicia sin
  repetirla. Gate2496/3;19425 real vuelve a responder y conserva JSON válido
  tras restart/reload375/1440 px. La selección de advance_time sigue abierta.
- AC-33.2: reinicio del server + abrir partida = mismo mundo, turno e historial.
- AC-33.1b (D170): el comprobante World.wait_resolution se guarda junto al
  efecto del reloj y sobrevive Codec/JSON/reinicio/borrado de actor_checkpoint.
  Legacy/malformed carga nil; duplicados/paralelos y recuperación de una
  interrupción parcial o0 s no cobran de nuevo la espera completa. Nuevos
  turnos humanos pueden autorizar otro intervalo con el mismo texto.
- AC-33.1c (D172): una huella scene_review_fingerprint válida sobrevive
  Codec/JSON/reinicio dentro de wait_resolution. Una clave opcional inválida
  se retira conservando el comprobante válido del intervalo y su idempotencia;
  legacy no obtiene una huella fabricada. Solo un World anterior real y limpio
  en memoria puede habilitar esa confirmación legacy. Tests Codec/Game y dos
  reinicios reales verifican el alcance; no cambia structs de ficha ni migración.
- AC-33.2a (D147): detener/reiniciar con una petición IA esperando antes
  de tools termina la ejecución antigua, Session y agentes, incluidos
  autoplay posteriores, PC/TurnMaster/registro. No persiste texto tardío ni
  ejecuta nuevas tools del propietario muerto. Monitores se retiran al
  concluir. Doce casos offline y mesa19427/reload375/1440 px lo verifican;
  recuperación tras efectos parciales y cancelación del proveedor quedan abiertas.
- AC-33.2b (D149): una parada supervisada permite responder al callback
  en curso dentro del plazo de shutdown; una salida de auxiliar vigente
  reinicia la mesa, quitar autoplay no. Cinco casos offline y operación
  controlada100 ms en VM web19427 lo verifican. Adopción19425/19426 pausadas
  conserva World/eventos/cursor. `:kill`, expiración del plazo y efectos
  parciales no quedan cubiertos por esta garantía.

- AC-33.2c (D150): una tool viva confirma su cambio de World después de
  guardarlo vía Game. Reiniciar antes de la narración conserva PG/reloj/límite
  de descanso y gasto de casilla/acción. Valida Session/actor/turn_id y dueño,
  rechaza handles antiguos y cambios inválidos, conserva pausa/intenciones.
  Siete casos offline y mesa19428 lo verifican. No garantiza atomicidad
  conjunta de dados/eventos/World ni recuperación de texto aún no completado.

- AC-33.2d (D151): cuatro caídas rápidas de una mesa no cierran otra sana;
  cada mesa tiene su límite3/5 s, agotarlo cierra sus procesos y permite
  reabrir desde Postgres. Salida normal retira el supervisor vacío; restart
  conserva GamePID como retorno y espera ambas claves de Registry. Seis
  casos offline, incluidos checkpoint tras `:kill`, y mesas19428/19429 en VM
  web con cuatro caídas/reapertura/reload375/1440 px lo verifican.

- AC-33.2e (D153): reiniciar un actor IA después de confirmar una tool y
  antes de liquidar conserva resultados, turn_id y enemigos originales;
  reanudar no repite casilla/daño/dados ni marcador del actor. Éxito/fallo
  definitivo limpia el registro; nueva declaración humana no lo hereda.
  Ocho casos offline y mesa19431/reload375/1440 px lo verifican. La ventana
  anterior a guardar resultado y atomicidad World/dados/eventos siguen abiertas.

- AC-33.2f (D154): el cambio de una tool y su comprobante se guardan en
  el mismo World antes de responder; reiniciar/:kill antes del feedback no
  repite el efecto. Respuesta final sustituye la entrada reservada; varias
  propuestas de una ejecución conservan una entrada, rechazos sin efectos
  ninguna. Cinco casos offline y mesa19432/reload375/1440 px lo verifican.
  Dados/eventos anteriores al guardado siguen fuera de la transacción conjunta.

- AC-33.2g (D157): grupos de dados de tools anunciadas en un beat de actor
  se guardan con World/comprobante en una transacción, y se publican después
  de aceptar Session. Preparación rechazada/interrumpida o fallo SQL conserva
  recursos y no publica grupos. roll_dice guarda dados con resultado exitoso;
  restart no los repite. Varias propuestas vacían solo los grupos confirmados.
  Diez casos nuevos, rollback Postgres real y mesa19435/reload375/1440 px lo
  verifican. Narraciones, tiradas standalone y resolución automática fuera
  de las tools mantienen su camino; no garantiza atomicidad global ni RNG.

- AC-33.2h (D159): iniciativa automática confirma
  World, todos sus dados y nota en una transacción antes de Session/PubSub.
  Rechazar un grupo no deja combate ni modal parciales; pausa y conserva el
  comprobante para resume/restart sin duplicar spawn. Tres casos nuevos con
  rollback Postgres real/26 focalizados verdes; gate2444/3 y VM19436/restart,
  reload375/1440 px/teclado verificados.
  Inicio de turno, narraciones y RNG mantienen revisión propia.

- AC-33.2i (D162): efectos automáticos de inicio de turno y todos sus dados
  se confirman juntos antes de Session/PubSub. Rechazar un grupo no aplica
  daño/concentración parciales; la reserva durable del slot/tipo permite
  resume/restart antes del actor, incluidos enemigos bajo DM y reacciones.
  Seis regresiones/82 focalizados, gate2455/3 y VM19439/corte antes de tirar,
  segundo restart y navegador375/1440 px/teclado lo verifican. RNG, cierre
  posterior de combate y narraciones conservan garantías independientes.

- AC-33.2j (D163): cierre automático de combate confirma fase, limpieza de
  estados/intenciones y todas sus notas juntos antes de Session/PubSub. Fallo
  pausa sin fase/notas parciales y conserva el comprobante pendiente; resume/
  restart liquida una victoria ya guardada antes de consumir una reacción
  obsoleta, recuperando primero el actor cuando corresponde. Siete casos/52
  focalizados, gate2462/3 trazado, VM19440/19441 y reload375/1440 px/teclado lo
  verifican. Narración y relevo posterior conservan revisión independiente.

- AC-33.2k (D164): si el actor conserva su comprobante durable y ya publicó
  una respuesta completa para el mismo turno, resume/restart liquida sin
  repetir petición, streaming ni párrafo final. Conserva declaraciones junto
  a tools y la escena pendiente; texto truncado/filtrado y eventos antiguos no
  prueban finalización. Siete casos nuevos/49 focalizados, gate2469/3 y corte
  real de VM19442 después de la publicación, segunda reapertura y navegador
  375/1440 px/teclado lo verifican. Actores sin comprobante, intentos incompletos
  y relevo posterior mantienen revisión propia.

- AC-33.3 (D250): eliminar una partida propia desde el listado detiene su
  Game, supervisor, Session y agentes, incluida una petición pendiente.
  Conserva procesos, World e historial de otra mesa; una petición de borrado
  sobre una partida ajena no detiene nada (`game_delete_live_test.exs`).

### R34 — Single-writer ✅ (D6)
El `World` vivo se muta **sólo** vía el GenServer `Game`. La LiveView nunca
escribe Repo/world; enruta (`declare`, `sync_hero_level_up`, pausa, auto-play).

### R35 — Degradación elegante ✅
Retries transient con backoff (1s→3s→10s, máx 3), retry `max_tokens` con nudge
"SÉ BREVE", pausa recuperable del turno fallido (D228, sustituye la racha de
fallbacks de D17 para actores), combate fantasma forzado (D18), UTF-8 sanitize
+ guardián de español (D7).

- AC-35.1 (D228): tras agotar reintentos, el turno de actor fallido deja la
  partida `:paused` con nota pública del motivo y su checkpoint; ninguna prosa
  de relleno. Reanudar reejecuta el mismo turno sin repetir efectos pagados;
  un segundo fallo del mismo turno lo omite con nota, sin bucle infinito
  (`game_retry_test.exs`, `game_human_declaration_test.exs`,
  `game_failed_turn_resume_test.exs`).
- AC-35.2: un beat que introduce enemigo vivo en exploración arranca combate
  aunque el DM olvide `roll_initiative` (`ghost_combat_test.exs`).

- AC-35.3 (D152): reintentar un beat después de una tool exitosa no repite
  una llamada equivalente ni paga otros recursos/dados. Conserva resultados
  en transient/max_tokens, también combinados; errores pueden corregirse y
  una nueva declaración ejecuta de nuevo. Nueve casos offline y mesa19430
  con503 simulado/casillas2→1/Goblin20→14/un grupo/reload lo verifican.
  D153 amplía el registro a tools confirmadas entre Games; mantiene las
  limitaciones de atomicidad anteriores a la confirmación.

- AC-35.4 (D205, ✅): invalid_tool_arguments generado y rechazado por el
  adaptador ReqLLM entra en los tres reintentos/backoff existentes. Validación
  de herramientas estricta; schema/history/routing/credenciales inválidos no
  se reintentan por esta regla. HTTP stock rechaza un tipo inválido tras un
  hechizo confirmado; repetir la tool conserva una casilla/un daño/un grupo.
  Dos regresiones nuevas, rojo16/18;34 focalizados finales y gates2742/3 local,
  2735/3 Hex. Consulta19425/877→884 recupera ese rechazo con un reintento y
  vuelve al humano en9,150s sin cambiar World. No garantiza que el siguiente
  resultado sea válido o registre toda información duradera.

- AC-35.5 (D218, ✅): un reintento provocado por invalid_tool_arguments de
  req_llm recibe una guía estática de schema en la siguiente petición DM/PC/TM.
  Solo causa normalizada, sin body privado; única en request y ausente de
  canonical/history/events. Primer intento y otros errores no la reciben.
  Conserva reglas, validación, presupuestos/backoff y efectos confirmados.
  Cuatro nuevos, rojo1/4 y43 focales por grafo; no garantiza tool válida después.

- AC-35.6 (D248): el reintento por `max_tokens` conserva el presupuesto
  transitorio ya consumido. Tres 503, un corte y otro 503 pausan tras cinco
  peticiones; un 503, corte, dos 503 y cierre válido usan el margen restante
  sin duplicar narración ni efectos (`game_retry_budget_test.exs`).

### R36 — Sin API key = TestModel ✅
Sin `OPENROUTER_API_KEY`, los beats usan `TestModel` (no narran, no consumen
créditos). Los tests de la suite son 100% offline.

### R37 — Modelo-por-rol y coste ✅ (D20, D21, D180)
`Models`: `dm/0` (adherencia), `summarizer/0` (barato), `turnmaster/0` (barato,
1024 tokens por petición; presupuesto configurable por entorno D180).
Selector runtime vía modal Ajustes (ephemeral, restart).
Prefijo cacheable medido 44–85% de input cacheado.

- AC-37.2 (D201, ✅): dev/test resuelve los checkouts hermanos sin flag y sin
  fallback remoto; producción resuelve versiones/checksums de Hex con su propio
  lockfile. Ambos grafos pasan conversación, compacción/restart y replay de
  reglas. Cambiar JS requiere reconstruir el paquete; el consumidor sirve
  exactamente sus assets sin que otro grafo los sobrescriba. Un perfil de IA
  incompatible se rechaza antes
  de cambiar configuración/parar Game; un cambio válido conserva la mesa
  pausada, World e historial. DeepSeek4.1 solo Decart y MiMo2.6 solo io.net,
  sin fallback: herramienta+texto en smoke real. La candidata local aún
  rechaza MiMo antes de IO por una opción ausente en stock ReqLLM; Hex1.2
  sí queda verificado. No exige publicar la candidata ni desplegar producción.

- AC-37.3 (D203, ✅): los módulos de cliente Phoenix/LiveView vienen de los
  paquetes efectivos del servidor en ambos grafos. No necesitan CDN ni build
  JS propio. Bytes/MIME/imports se verifican por HTTP; escritorio/tablet/móvil
  conectan, aplican ajustes y recargan con dados operativos sin JS ni cambios
  de partida. Los locks adoptan parches publicados y pasan `mix hex.audit` sin
  avisos conocidos, sin exigir modificar ReqLLM ni publicar los candidatos.

- AC-37.1 (D180): el presupuesto efectivo del TurnMaster alcanza la petición
  del Game:1024 por defecto, entero positivo de
  `DRAGONEX_TURNMASTER_MAX_TOKENS` si válido; vacío/inválido/no positivo
  conserva1024. La opción explícita del constructor prevalece. Bootstrap no
  fuerza256. Modelo/ajustes restantes/DM/PC, tres pasos, primera decisión
  terminal y fallback conservan su contrato. Cuatro casos offline; control
  negativo1/4,77 focalizados y2553/3 limpios. Prueba real aislada reproduce
  corte256 sin decisión y decisión259 con margen1024. Una espera real15 s
  vuelve al humano en9,667 s sin fallback, conserva escena/recursos/hechos y
  cobra tiempo una vez; restart conserva configuración y partida. No acredita
  SLA, consumo fijo ni fiabilidad estadística del proveedor.

- AC-37.4 (D249): catálogos y comprobaciones de modelos solo actualizan la
  solicitud vigente. Cerrar/reabrir el modal, cambiar fuente/modelo o refrescar
  invalida respuestas antiguas según su operación; el catálogo conserva un
  modelo escrito manualmente. Una comprobación cancelada no reinicia la mesa
  ni guarda otra selección (`game_settings_compatibility_test.exs`).
- AC-37.5 (D246): los grafos local y Hex resuelven exAgent 2.2.2 con ReqLLM
  1.29.0 y Bandit 1.13.1, conservando paquetes hermanos en dev/test y lock
  independiente en producción. Verificar suite, compilación y `mix hex.audit`
  en ambos grafos; el resultado vigente se registra en `../progress.md`.

---

## No funcionales (NFR)

| # | Requisito | Estado |
|---|---|---|
| NFR-1 | Determinismo del motor: roller inyectado, nunca `:rand` en `Rules`/`Actions`/`World` | ✅ |
| NFR-2 | Suite offline verde: `MIX_ENV=test bin/dev test`; referencia local/Hex vigente en `../progress.md`, TestModel/HTTP sintético sin peticiones LLM reales; seis avisos deliberados de breaker/retry; gates en secuencia si comparten DB | ✅ |
| NFR-3 | `mix compile` sin warnings; `mix format` limpio | ✅ |
| NFR-4 | Sanitización determinística en TODO texto persistido (D7) | ✅ |
| NFR-5 | Latencia: streaming token-a-token; GenServer nunca bloquea en LLM (Task) | 🟡 D222 retiene deltas libres; preview estructurado pendiente. Task/etapas preservados |
| NFR-6 | Partida sobrevive restart de proceso y de server (D3/D5) | ✅ |
| NFR-7 | Coste: caching de prefijo (D20), modelo barato para TurnMaster (D25) | ✅ |

- AC-NFR-2a (D174): cerrar una LiveView montada mediante ConnCase espera a
  que su callback SQL devuelva la conexión; el snapshot en cola del Game
  conserva World/historial/DB/estado pausado. Cerrar una vista mantiene otra
  del mismo Game operativa. TMSpy conserva su contador hasta terminar las
  peticiones del Game. Dos pruebas de cierre,34 focalizados y45 con TurnMaster;
  gates2532/3 en48,0/48,2 s, seeds944912/30343/max_cases48, sin errores ni
  avisos inesperados. No garantiza por sí solo causas históricas sin atribuir
  ni cambia el comportamiento de la aplicación al cerrar un navegador real.

- AC-NFR-2b (D251): el playtest aplica a la última declaración el mismo
  presupuesto de reanudación y plazo que a las anteriores. Solo devuelve
  `turns_reached` al recuperar el turno humano; una pausa sin reanudaciones
  disponibles devuelve `paused`, conservando la causa y los resultados
  registrados (`playtest/playtest_test.exs`). No certifica fidelidad narrativa.

---

## Lectura siguiente

- Qué falta y en qué orden → [`03-plan-fases.md`](03-plan-fases.md).
- Cómo se implementa cada mecánica → [`../tecnico/08-catalogo-mecanicas.md`](../tecnico/08-catalogo-mecanicas.md).
- Cómo se verifica → [`../tecnico/09-estrategia-pruebas.md`](../tecnico/09-estrategia-pruebas.md).
