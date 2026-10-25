# Dragonex — Flujo de una partida

> Documento vivo que explica, en lenguaje natural, **cómo funciona una partida de
> Dragonex de punta a punta**, reflejando el código real (con referencias
> `archivo:línea`). Es la fuente de verdad narrativa sobre la que iteramos:
> cuando cambiemos algo, actualizamos este doc. Cuando encontremos un bug, lo
> apuntamos en la última sección.

---

## 1. Qué es Dragonex

Primer recorrido de versión jugable comprobado con navegador y proveedor real:
[`producto/05-cierre-version-jugable.md`](producto/05-cierre-version-jugable.md).
En móvil, el cajón «Ficha» contiene el personaje propio incluso en exploración
en solitario. «Actuar» solo se presenta cuando la partida espera realmente su
acción; en pausa o durante un beat se usa «Declarar» para registrar una intención.
La espera distingue la voz que está narrando de «Actualizando la escena…»,
«Organizando el siguiente turno…» y «Reintentando el turno…» (D191). Durante
esas operaciones la narración publicada ya no mantiene cursor de escritura.
Game proyecta una etapa efímera, validada contra el Task/turno actual; no añade
eventos de historia ni campos al World. Un fallo transitorio posterior a pausar
conserva la pausa: solo reanudar permite continuar el reintento. Estas etiquetas
explican la espera y no prometen un plazo o menor latencia.

Un **Dungeon Master por IA** para D&D 5e. El jugador crea una partida, elige un
escenario (o la arena de pruebas), y uno o varios personajes (controlados por
humano o por IA) viven una aventura narrada y arbitrada por el modelo LLM.

- **Stack**: Elixir + Phoenix LiveView. Motor de agentes: `ExAgent` (checkout
  hermano `../exAgent` en dev/test; paquete publicado Hex en prod, D201).
- **Modelo DM**: `deepseek/deepseek-v4-flash` vía OpenRouter (configurable por
  env). Sumarizador de compacción: `google/gemini-3.1-flash-lite`.
- **Persistencia**: Postgres. Una fila `games` por partida + un log append-only
  `game_events` + el `world` serializado como jsonb.

El modelo **solo narra**. Cada tirada, ataque, daño, salvación y muerte se
resuelve por herramientas (`make_attack`, `roll_initiative`, …). El LLM lee el
resultado factual y lo teje en prosa. El resultado mecánico y la ficha proceden
del motor; la prosa todavía requiere revisión de fidelidad.

El feedback de un golpe distingue el total del arma de sus componentes ya
incluidos: «13 de daño piercing en total (incluye 5 sneak)» (D226). Savage,
furia y marca siguen ese criterio por golpe. Castigo divino es radiante
adicional; inspiración modifica el ataque. La aclaración conserva dados,
PG y recursos; no garantiza que toda narración reproduzca bien las cifras.

---

## 2. Arquitectura por capas

```
┌─────────────────────────────────────────────────────────────┐
│ UI  DragonexWeb.GameLive.Show  (LiveView: vista + input)    │
├─────────────────────────────────────────────────────────────┤
│ App Dragonex.Game (GenServer, uno por partida)              │
│   - bucle por turno, lanza beats en Tasks                   │
│   - persiste world + status + events tras cada beat         │
│   - maneja pausa, auto-play, reintentos                     │
├─────────────────────────────────────────────────────────────┤
│ Motor ExAgent.Session + TurnMaster (decide) + WorldDriven   │
│   - iniciativa principal (D113); TurnMaster = excepciones  │
│   - control guard: solo el actor en turno resuelve          │
├─────────────────────────────────────────────────────────────┤
│ Reglas  Dragonex.{Rules, World, Actions, Tools}             │
│   - matemática de combate (AC, daño, saves, iniciativa)     │
│   - change functions que mutan el World                     │
├─────────────────────────────────────────────────────────────┤
│ Agentes  Dragonex.{DM, PCAgent, TurnMaster, Events}         │
│   - system prompt + tools + capabilities                    │
│   - ExAgent.Server ejecuta el beat contra el modelo         │
├─────────────────────────────────────────────────────────────┤
│ Datos  Postgres: games / characters / participants /        │
│        game_events (log) + world jsonb (vía Codec)          │
└─────────────────────────────────────────────────────────────┘
```

**Principio rector**: el `Game` es la **única fuente de durabilidad**. Tras cada
beat persiste el `world` vivo, la posición de turno y un evento append-only. El
`Session` (motor) corre en memoria; si el proceso `Game` muere, uno nuevo
rehidrata el mismo `game_id` desde Postgres y continúa exactamente donde dejó.

---

## 3. Datos persistentes

- **`games`**: título, story_bible (jsonb), dm_style, world (jsonb via `Codec`),
  status (`:running | :waiting | :paused | :ended`), round,
  current_participant, intents (pendientes del humano), open_slots.
- **`participants`**: nombre, kind (`:ai | :human`), side (`pc | enemy`).
- **`characters`**: hoja del personaje (sheet jsonb) por partida.
- **`game_events`**: log **append-only**, monotónico por `seq`. Es la línea
  temporal reproducible de la partida. Tipos (`game_event.ex:22`):
  `:narration | :action | :tool | :dice | :system | :turn`.

El `world` jsonb se (de)serializa con `Dragonex.Codec`. Al rehidratar, se
reconstruye como `Dragonex.World` struct y se pasa como `shared_state` al
`Session`.

Desde D81–D83 también persiste presupuestos de turno (`turn_state`,
`turn_kind`, `turn_owner`), dados de golpe y descanso diario (`rest_state`),
tiempo de juego (`elapsed_seconds`) y plazos de efectos (`effect_expiries`).
Guardar/cargar no devuelve acciones ni dados ni renueva efectos. Una reacción
se etiqueta como tal y no inicia otro turno propio. El reloj avanza 6 segundos
por ronda. Bootstrap reconstruye el mini-turn pendiente y su dueño desde
`turn_kind`/`turn_owner` al reabrir una reacción en pausa (D114); éxito o fallo
no gastan el turno principal del reactor. El reloj también avanza
1/8 horas por descanso corto/largo o por `advance_time` explícito;
`rest_party` permite que varios personajes compartan el mismo intervalo.
D165 añade al contexto DM de exploración la obligación de registrar duración
explícita realmente consumida con advance_time antes de narrar llegada.
set_scene no aplica tiempo; preguntas/propuestas pendientes no lo consumen y
rests ya registran su intervalo. Tres casos/35 focalizados y gate2472/3 limpio;
19425 llega a la taberna con dos tramos de900 s, el primero registrado tras
confirmación explícita de la omisión. Reinicio/reload conservan recursos,
historial y reloj34200. La selección de la tool sigue dependiendo del modelo;
latencia47,54 s y relevo adicional Vex/DM permanecen bajo revisión.

D170 registra en la acción humana los segundos/reloj inicial de una espera
literal afirmativa en exploración. No aplica tiempo al reconocerla. El DM
recibe ese intervalo y no puede cerrar/publicar texto pendiente sin resolverlo
con advance_time; puede completar o interrumpir, incluso inmediatamente.
World.resolve_wait valida0..duración y conserva un comprobante wait_resolution
en la misma escritura que el efecto. Sobrevive Codec y liquidación del actor,
protege duplicados/paralelos y reinicios tras una interrupción parcial. Al
agotarse una omisión, Game pausa con la declaración intacta y admite reanudar.
Preguntas/planes/condicionales/retellings/rests/viajes/intervalos compuestos
no activan ese contrato. El modo del proveedor sigue normal; el motor valida
la final y su publicación.19425 registra cinco minutos35400→35700 sin ajuste
manual, recursos iguales y restart/reload válidos.32,603 s/recorder10,567 s y
rumor repetido mantienen revisión de ritmo; la interpretación general sigue abierta.

D171 publica directamente las palabras saneadas de una espera puramente
pasiva reconocida, sin pedir al modelo humano que la reformule. Conserva
acción/metadatos/turno/cola y el reloj inicial; el DM posterior sigue obligado
a resolver por D170. Esperas con otras acciones/hechizos o contexto incierto
mantienen el beat humano. La cola pausada no publica antes de consumir el
turno y un reinicio ante DM conserva una sola voz humana.19425 registra180 s
sin petición humana,35700→35880,17,884 s y recursos intactos; restart/reload
verificados. TM con max_tokens/fallback, recorder idéntico pendiente y nuevos
datos del PNJ solo en historial conservan revisión propia.

D172 añade al comprobante una huella del estado anterior cuando la escena
estaba revisada. Tras una espera aislada, el recorder puede confirmar la
descripción idéntica: Game comprueba fuente/duración/reloj/estado y limpia
solo la marca pendiente. Facts/recursos/escena distintos o una revisión previa
requieren un snapshot nuevo; un resultado tardío no pisa el World actual.
Codec preserva la huella válida y retira una inválida sin perder el intervalo.
Al reiniciar, la final DM D164 y el comprobante permiten reanudar solo el
registro, sin narración ni tiempo repetidos. Legacy puede usar un World anterior
real en memoria, sin inventar huella. Diez casos/53 focalizados verifican esta
confirmación; dos esperas reales120/60 s conservan recursos/restart/reload y
revisión limpia, pero ambas actualizan descripción. La rama idéntica aún no
se observa con proveedor; separación de entorno/diálogo PNJ sigue bajo revisión.
Dos esperas reales D175 de15 s confirman por primera vez el entorno idéntico
con proveedor y limpian la marca sin reescribir escena ni consumir recursos.

D173 precisa la instrucción del recorder: guardar entorno físico, omitir
conversación/ofertas/rumores/gestos pasajeros PNJ y no inferir consumo por el
tiempo. El historial sigue conservando el diálogo; no se altera facts, tools,
schema ni guardas. Un smoke verifica entrega real de messages,120 s/recursos/
historial/DB/Codec/restart. La muestra19425 retira pregunta/oferta de la escena
y conserva30 s una vez, pero sigue incluyendo detalles transitorios y nuevos
datos narrados solo en history. La guía no certifica semántica general.

D175 distingue el ritmo de la espera deliberada del atasco. Game consulta
el mismo request de resolución D170 con400 eventos y, tras priorizar una
conversación activa, usa guía de espera antes de limbo/default. Las guardas
siguen usando los últimos40. El DM puede conservar ambiente estable; no
recibe una orden de cerrar investigaciones/retirar PNJs por novedad ni de
deducir hora del día del reloj relativo. Interrupciones coherentes siguen
permitidas y registran solo su intervalo real. No se modifica el reloj ni
se garantiza semántica del modelo. Cuatro casos cubren messages, conservación,
interrupción/restart y restart pendiente;46 focalizados.19425 registra15/15 s
una vez,36090→36105→36120, con entorno/hechos/recursos/modelos iguales.
La primera consulta TM agota tokens/fallback; la segunda completa el relevo.

D176 añade record_npc_statement para recordar información duradera del PNJ
con fuente/dudas. Solo el DM puede proponerla; World la guarda en facts como
«fuente afirma: contenido», sin confirmar lo relatado. Fuente80/contenido800,
scrub/Unicode/citas y rechazo de PJ/nombres cortos; NPC conocido de prefijo
compartido sigue permitido. Conserva cap30/idempotencia/replay/Codec. La
atribución llega en Brief al DM/PC/TM, también después de compactar diálogo.
Actualizar esa memoria no avanza tiempo ni cambia presencia/recursos/entorno:
la marca de revisión conserva su valor previo. Sucesos físicos confirmados
siguen por set_scene/otras tools. La elección de registrar la información
sigue siendo del modelo; no existe extracción automática de cualquier frase.
19425 registra versión de Maribel7,605 s/humano1/DM2, sin TM/recorder/reloj/
gasto y conserva el testimonio tras restart. La nueva fuente del zagal y
relleno de jarra narrado siguen bajo revisión de continuidad.

D177 extiende el inicio informativo literal a viste/oíste/escuchaste, con
tú opcional. Conserva el resto de guardas D167: no reconoce más roles PNJ
ni omite magia/pago/movimiento añadidos.19425 publica «¿Oíste tú misma…?»
exactamente, sin petición humana: una ejecución DM/dos pasos,4,538 s hasta
retorno, un testimonio nuevo y resto de World/reloj36120 intacto. Restart/
reload/teclado375/1440 px acreditados. La continuidad de nuevas versiones
del forastero sigue bajo revisión; no prueba semántica ni latencia universales.

D178 ordena el cajón móvil con ficha propia antes de compañeros y PlayerSheets
reinicia scroll solo al abrir. Patches mientras se lee conservan posición y
details nativo abierto, sin cambios de Game/World. Chrome375/720 px confirma
PG propios visibles tras desplegar/cerrar/reabrir y cambios de borrador;
DM mantiene Grupo. D179 resuelve la adaptación intermedia observada a721 px.
La mesa compacta cubre hasta1023 px; desde1024 conserva tres columnas.
Entre721–1023 px limita la narración a72ch; con altura≤600 px, abrir Ficha
usa un lateral240 px sin quitar altura a la crónica ni ocultar la entrada.
TurnControls revela el control completo al recibir foco dentro de su barra,
sin desplazar el resto de la página. La ficha propia de combate tiene un
contenedor distinto de las fichas duplicadas ocultas en móvil y muestra
PG/CA primero. Son cambios de presentación: World/turnos/history permanecen
iguales en las dos partidas comprobadas mediante SQL de solo lectura.

D146 proyecta las caducidades de las ocho horas para el mensaje del descanso
largo: si Forma salvaje caduca, informa recuperación del cuerpo original,
como el cambio que confirma Rest.complete. Una forma aún vigente conserva
sus PG de bestia. La preparación del feedback es pura y no aplica tiempo.

La presencia de no-PCs se guarda en `absent_characters` (D115). `leave_scene`
termina concentración y retira iniciativa/objetivos activos, conservando ficha,
PG/recursos y caducidad de efectos entrantes. `return_to_scene` recupera esa
misma ficha y entra como refuerzo al final sin renovar el ledger de la ronda.
Solo DM puede registrar estas transiciones; no resuelven una huida ni mueven
PCs fuera del grupo. Ausentes aparecen en un bloque propio de los briefs.
Salida del último hostil cierra combate; retorno en exploración usa iniciativa
automática. Una narración/chequeo sin la tool no cambia presencia.

Bless (D85) registra sus objetivos como efectos con fuente en `conditions`.
`cast_spell` admite `additional_targets` para ese hechizo. El motor añade el
d4 a ataques/salvaciones; perder o reemplazar la concentración del lanzador
retira todos sus efectos, y el minuto de duración conserva su plazo al cargar.

Shield of Faith (D86) comparte ese vínculo de fuente: +2 a la CA efectiva
del objetivo durante hasta 600 segundos, con bonus action y una casilla.
Armas y hechizos de ataque leen la misma CA efectiva; la ficha base no se
modifica. Al terminar concentración desaparece la protección de esa fuente.

Heal (D87) resuelve curación instantánea de 70 PG (+10 por nivel de casilla
superior a 6) y elimina `blinded`, `deafened`, `diseased` junto a sus plazos.
El estado curado y la acción/casilla gastadas sobreviven a la carga; conserva
la concentración previa. Se invoca mediante `cast_spell`, con objetivo aliado
o self; la tool de curación por dados `heal` es una operación distinta.

Spare the Dying (D88) estabiliza a un aliado vivo a 0 PG: borra fallos y
conserva `successes: 3` como sentinel, sin curación. Consume una acción del
lanzador, ninguna casilla y ningún recurso del receptor. PCAgent reconoce al
estable y no solicita nuevas salvaciones; daño posterior rompe estabilidad.
Guardar/cargar conserva ese estado y la acción gastada.

False Life (D89) genera `1d4+4` PG temporales, +5 por nivel de casilla superior.
Solo se lanza sobre uno mismo, con una acción/casilla y una hora sin
concentración. No acumula: solo una cantidad mayor sustituye la reserva y
renueva su plazo; guardar/cargar no concede otra hora.

Lesser Restoration (D90) elimina una condición entre ceguera, sordera, parálisis,
veneno y enfermedad explícita. Cuando hay varias, el agente debe indicar
`condition_to_remove` en `cast_spell`; el motor no decide por él. Retira también
el plazo de esa condición y conserva las demás. Una acción/casilla, sin curar PG
ni concentración. La elección ambigua no consume recursos.

Imposición de manos (D91) admite `conditions_to_remove` en su tool: `poisoned`,
`diseased` o ambas, por 5 puntos de reserva cada una. El paladín puede combinar
esa purificación con `amount` PG de curación en una sola acción, o indicar
`amount: 0` para solo purificar. Purificar sin curar a 0 PG no estabiliza.
Guardar/cargar conserva la reserva gastada y los plazos de efectos restantes.

Los efectos de inicio de turno (D100) se resuelven antes del beat: el Game
pasa su roller y un RollLog a la repetición de Hold Person y al aura de
Spirit Guardians. Los grupos aplicados se persisten como `:dice` con
`timing: "turn_start"` y `combatant`, se publican al modal y forman parte
del history del siguiente narrador. La salvación del aura consume
Inspiración/Indomitable antes de resolver concentración por el daño.
Re-seleccionar, reaccionar o cargar un turno ya iniciado no repite sus efectos.
El fallback de un actor fallido también sincroniza el combatiente siguiente.

---

## 4. El `Game` GenServer: estado y lifecycle

Al borrar una partida desde la lista, el ID entero del registro eliminado
identifica el supervisor que se debe detener (D250). Se cierran también
Session, DM, TurnMaster, PCs y peticiones en curso; otras mesas conservan sus
procesos. La autorización se comprueba antes del borrado. SQL y shutdown no
forman una única transacción: una escritura que termine entre ambos puede
fallar, sin recrear la mesa.

Antes de arrancar, una sala con plazas humanas queda en `:configuring`.
`Games.join_game` y `start_game` bloquean/releen la misma fila en transacción:
una vista anterior no admite plazas de más ni escribe el World después del
inicio. Una unión repetida conserva el personaje; un segundo inicio conserva
pausa/cursor/intenciones. El creador inicia; cada invitado elige su héroe y
los avisos PubSub refrescan el grupo o entran en mesa. Los errores de elección,
plaza o nombre se muestran junto al selector; si la sala desaparece, el socket
regresa a partidas con un mensaje (D121). Desde el inicio, World solo lo
escribe Game; el contexto de admisión no se usa para incorporar PCs en juego.

Definido en `lib/dragonex/game.ex`. Un proceso por partida, arrancado vía
`Dragonex.Game.Supervisor` (registry por `game_id`).

**Struct**: `game_id`, `game`, `session`, `dm`, `turnmaster` (D25),
`pc_agents`, `model`, `roller`, `participants`, `intents`, `status`, `busy`,
`loop_phase` (`:actor | :turnmaster`), `last_actor`, `acted` flags de mini-turno.

### Rehidratación (`init` → `rehydrate`)
1. Carga el `games` row desde Postgres.
2. Decodifica el `world`, crea los `Participant` del `Session`.
3. Arranca el `Session` con policy `{WorldDriven, dm: "dm"}` (fallback).
4. Restaura la posición de turno (`restore_turn` / `Session.handoff`).
5. Crea el **agent DM** (`DM.new/2`) con la story bible horneada.
6. Crea el **agent TurnMaster** (`TurnMaster.new/2`, modelo barato).
7. Crea un **agent PCAgent** por cada participant `:ai` que no sea el DM.
8. `loop_phase`: `:turnmaster` si partida nueva; `:actor` si reanuda.
9. `send(self(), :advance)` → arranca el bucle.

### Cierre de ejecuciones (D147)

Session y servidores se vigilan desde Bootstrap, incluidos los PCs de
autoplay creados después. Game.RunLifecycle monitoriza Game/beat: al perder
un propietario termina el Task del beat y el de exAgent, que vive en un
supervisor global sin enlace al Server. También cubre TurnMaster y el
registro de escena. Los monitores terminan al acabar los procesos vigilados.
La capability comprueba el propietario antes de pedidos/tools y tras la
respuesta; Events y callbacks descartan texto/dados de propietarios muertos.
Una parada normal también cierra los auxiliares.

Pausar permite concluir el beat actual; detener/reiniciar lo invalida.
Las pruebas de reinicio/caída esperan antes de tools y conservan el World
guardado. No certifican recuperación de efectos parciales ni cancelación
de facturación en el proveedor. Mesa19427: TestModel bloqueado, reinicio
público12,48 ms observados, cuatro auxiliares cerrados, World/tres eventos/
pausa/cursor iguales y reload375/1440 px correcto.

En los tests, D148 usa un cierre distinto de la cancelación deliberada:
la fixture pausa y permite terminar el beat antes de cerrar su Game; un
dueño SQL separado sigue vivo hasta `on_exit`. Los Games globales de LiveView
se limpian por Registry antes de liberar SQL. El caso con descanso ya aplicado
comprueba que sus resultados se guardan. Ese cierre de prueba no cambia la
semántica de reinicio real ni prueba recuperación después de una caída parcial.

D149 captura señales de salida para que la parada supervisada deje terminar
el callback del Game antes de cerrar, dentro del timeout OTP. Los beats IA
siguen asíncronos y su cancelación D147 se conserva. Una salida de auxiliar
vigente fuerza recuperación; el autoplay retirado no. Los informes OTP
omiten modelos del estado. La operación controlada100 ms en web19427
responde antes de cerrar/reabrir, con World/eventos/cursor iguales; adopción
en19425/19426 pausadas conserva World/130 y20 eventos y relojes. No protege
`:kill` ni prueba durabilidad tras tools parciales.

D150 enruta `Tools.propose` de beats vivos por `Game.commit_rule_change/3`.
El Game valida el handle y beat actual, evalúa el cambio y guarda el candidato
antes de actualizar Session y confirmar la tool. Un cambio rechazado deja
ambos World intactos. Guardar incluye cursor/pausa/intenciones vigentes.
Sesiones standalone offline conservan SharedState sin DB. Reiniciar durante
la siguiente petición ya conserva el efecto confirmado; dados/eventos siguen
sin una transacción conjunta con ese checkpoint. Mesa19428 offline:14/14 PG,
reloj28800, reinicio con World/historial iguales, continuación al amanecer.

D151 coloca un `TableSupervisor` temporal bajo el gestor dinámico para cada
Game. El presupuesto3 reinicios/5 s queda por mesa; agotarlo no cierra las
sanas ni reinicia el gestor. Game es hijo significativo/transitorio: una
salida normal elimina también el supervisor vacío. Registry separado conserva
la lookup de Game y restart espera ambas claves. APIs devuelven GamePID.
VM19429: cuatro caídas solo cierran sus tres auxiliares; manager y19428
conservan procesos/World/eventos. Adopción19425–19428 pausadas conserva estado.

D152 envuelve las tools anunciadas al DM/PC con `ToolReplay`. Registra solo
resultados exitosos en Beat y los lleva a PendingRetry y al siguiente intento,
también al retry por tokens. Llamadas equivalentes reciben el resultado previo
con aviso, sin nuevos dados/efectos. Los nuevos beats no heredan ese registro.
La definición de magia se resuelve mediante el mismo lookup de Actions para
canonicalizar nombres/nivel base/opcionales. Sesiones standalone mantienen
la ejecución habitual. D153 guarda los resultados confirmados además en
`World.actor_checkpoint` vía Codec. El actor IA recupera turn_id/fase/mini-turn
y enemigos originales, sin duplicar marcador ni ejecutar otra vez la tool.
Éxito/fallo definitivo limpia el registro; nueva declaración inicia otro beat.
Registros inválidos o de otro actor no se restauran. Esto no hace atómico el
guardado previo del efecto con el posterior resultado y los dados/eventos.
D154 cierra efecto→resultado: cada ejecución lleva una referencia efímera,
RuleCheckpoint guarda un comprobante en el mismo World que el cambio y el
feedback final sustituye esa entrada. Varias propuestas de una tool comparten
comprobante; un rechazo sin cambio no lo crea. Si falta el feedback, la IA
consulta estado/tiradas vigentes sin repetir el efecto. Los dados/eventos
anteriores a guardar World estaban fuera de una transacción conjunta.
D157 difiere los grupos por ejecución en RollLog; tras evaluar el candidato,
Persistence guarda World/comprobante y eventos de dados en una transacción.
Solo tras SQL+Session confirma el prefijo y publica cada grupo. roll_dice,
sin efecto mecánico, guarda grupos junto al resultado exitoso. Rechazo/corte
previo/rollback no publica dados. Salvaciones dentro del cambio usan el mismo
buffer Agent, sin self-call al Game. Narraciones y grupos standalone/automáticos
fuera de las tools conservan su camino; no es atomicidad global ni del RNG.

D158 reserva además la respuesta de una pregunta humana literal a rol PNJ
cualificado. Al consumir el texto en exploración, Game crea Conversation con
world_recipient, recipients/pending vacíos y stage world. DM responde con su
instrucción propia; finish_actor pasa a return y vuelve al humano sin consultar
TurnMaster. Codec valida ese caso y la cola sobrevive a reiniciar mientras el
DM espera. request_response conserva su contrato PC y no sustituye esta cola.
Otra declaración humana conserva prioridad. Menciones, planes, preguntas
mixtas, reportes citados y combate no activan este reconocimiento acotado.

D167 evita reformular con el modelo solo un subconjunto seguro de esa cola:
pregunta informativa literal con prefijo/espera pasiva reconocidos, desde un
humano manual y sin mini/re-evaluación/interrupción. Text extrae el interrogante
sin cambiar sus palabras; Events lo sanea con roster vigente y publica como
narración completa del turno. La declaración íntegra sigue en acción y cola.
El Task habitual liquida ese beat y pasa al DM; la primera petición de modelo
corresponde a la respuesta PNJ, con la pregunta humana ya en history compartido.
No publica tokens/uso ficticios ni cambia World directamente. Acciones extra,
peticiones persuasivas o texto incierto siguen por Server.chat; pregunta con
False Life conserva su herramienta, casilla y dado. La recuperación de una
caída durante el beat humano sin comprobante conserva los límites D164.
Siete casos/69 focalizados, gate2490/3 limpio;19425 real vuelve en4,536 s con
solo una petición DM y World intacto. Restart y reload375/1440 px verificados.

D204 añade una cita emparejada con hasta tres preguntas informativas al mismo
PNJ y un preámbulo de recuerdo acotado («cuando dijiste…»). Conserva todas las
palabras habladas; no interpreta el referente. Prefijo/espera pasivos, prioridad
PC y exclusión de acciones exteriores siguen vigentes. DM recibe la misma cola
y guía de registro, pero la información nueva solo persiste si confirma su tool.

D205 trata invalid_tool_arguments generado de ReqLLM como recuperable dentro
de los tres reintentos existentes. El adaptador sigue rechazándolo estrictamente;
schema/history/continuation inválidos no entran por esa regla. Ledger/replay
conserva efectos confirmados. La prueba real877→884 recupera un rechazo y vuelve
al humano; la aclaración PNJ queda solo en prosa, con memoria durable pendiente.

D206 exige ahora un comprobante de `record_npc_statement` para el PNJ y turno
DM cuando la cita incluye ese preámbulo de aclaración. `NPCMemoryResolution`
impide publicar final o deltas mientras falta el recibo; v2 también solicita
herramientas al proveedor. La tool valida la fuente y confirma por el Game,
sin interpretar la prosa. Un duplicado retenido satisface la obligación sin
renovar el fact/reloj; facts anteriores sin recibo no bastan. Restart recupera
el comprobante y combate puede interrumpir. La guía pide conservar dudas o
registrar el límite si no puede aclararlo. Consulta884→891 guarda solo la
aclaración atribuida, conservando14 registros previos/recursos/tiempo; reinicio
y recarga mantienen SQL. Otras preguntas PNJ conservan su contrato previo.

### Status

- `:running` — el bucle avanza solo (turnos IA).
- `:waiting` — esperando que un humano declare (`act/2`).
- `:paused` — pausa; los beats IA no se auto-lanzan.
- `:ended` — fin.

---

## 5. El bucle por turno — `advance/1` (el corazón)

Micro-máquina **actor → turnmaster → handoff** (D25). Un tick = un paso.
**Nunca encadena más de un beat por tick**.

```
handle_info(:advance) → advance(state)
  ¿status != :running?  → no-op
  ¿busy != nil?         → no-op (hay un beat en vuelo)

  si loop_phase == :turnmaster:
    → combate ordinario: relevo por iniciativa, sin petición (D113)
    → respuesta de conversación D120: relevo determinado sin petición TM
    → exploración forzada D28/D30: relevo sin petición
    → los demás casos: beat TurnMaster (decide quién sigue)
    → al cerrar: Session.handoff / end_scene  (o fallback WorldDriven)
    → loop_phase := :actor, tick

  si loop_phase == :actor:
    → depura destinatarios de conversación que ya no pueden responder
    según Session.current:
      nil                  → fin, persist :ended
      ai_pc?(current)      → lanza beat del PCAgent
      human?(current)      → :waiting (o consume intent pendiente)
      _ (DM)               → lanza beat del DM
    → al cerrar OK: NO end_turn; mark_acted; loop_phase := :turnmaster, tick
```

Detalle normativo: [`tecnico/01-bucle-del-agente.md`](tecnico/01-bucle-del-agente.md).
Spec de diseño: [`TURNMASTER.md`](TURNMASTER.md).

### Tipos de turno (fase `:actor`)

**IA PC**: agent propio + `PCAgent.instruction/3` + anti-loop, `run_beat`.

**Pregunta a compañeros (D120)**: el modelo que actúa como PC registra
`request_response(recipients, question)` cuando la declaración pide
explícitamente sus respuestas. El origen sale del handle admitido; el motor
valida 1–5 PCs presentes/capaces/registrados. `World.conversation`, con Codec,
conserva origen, pregunta y pendientes. El Game da un beat a cada destinatario
en orden, después cierre DM (salvo cierre local acreditado D184) y retorno al
humano. No consulta al TM para esos
relevos determinados; humanos pendientes ganan y mini/re-eval/combat conservan
su camino. Reintentos idénticos y fallos terminales no repiten el cursor;
reanudar sobre un caído lo omite antes del beat. Escena nueva o combate cancelan.
Preguntas del PC IA no le conceden otro turno automático tras el cierre.
El contexto del respondedor contiene la pregunta y la voz real anterior.
Desde D143, al consumir una declaración humana, el Game reconoce un vocativo
inicial literal seguido de coma y pregunta completa («Vex, ¿puedes…?»).
Admite nombres canónicos/cortos únicos y varios separados por comas/y/e,
en orden escrito. Registra/persiste la misma cola antes del narrador y su
brief; el prompt/tool indican que ya está registrada. No selecciona por
mención/cita/pregunta indirecta ni abre una cola parcial si falla una guarda.
Una intención pausada/off-turn no la abre hasta consumirse; limpiar cancela.
Cola existente, prioridad humana, fallo terminal e iniciativa conservan
su camino. Fuera de esa forma acotada, llamar la tool depende del modelo.

D182 publica el habla humana localmente si esa cola coincide completa con
una sola pregunta de recuerdo/observación y espera pasiva opcional. Requiere
exploración manual sin mini/re-eval/interrupción; conserva vocativo y orden,
scrub y beat/cierre habituales. Los destinatarios reciben las palabras
literales, sin otra petición humana al modelo. Peticiones/preferencias,
acciones/magia añadidas y esperas cronometradas conservan su resolución.
Seis casos prueban guardas, los requests propios de ambos PCs, reinicio
pendiente sin duplicados y False Life mixto con coste/tirada únicos.19425:
Mara → Lyra → Vex → DM → Mara en7,647 s, tres runs/un paso, World intacto,
cero TM/recorder/tools/dados; reinicio/UTF-8/JSON/reload375/1440 acreditados.
No es clasificación semántica general ni garantía de latencia o campaña larga.
D188 amplía las formas literales a preguntas informativas/opinión, D192 añade
interrogativos con preposición y D211 permite hasta tres preguntas completas
consecutivas a los mismos PCs, manteniendo toda la espera pasiva y las guardas.
Las acciones intermedias/exteriores o una cuarta pregunta no se truncan.

D183 quita la obligación de añadir ambiente al cierre. El Game pasa contexto
explícito de conversación al anti-repeat: si detecta repetición, pide solo
respuesta/consecuencia pendiente o cierre breve, evitando la orden sensorial
contradictoria. El resto de turnos conserva su guía ordinaria. No cambia la
cola, tools ni requiere silencio; el DM sigue teniendo su beat. Requests
repetidos/reinicio/PNJ se verifican con tres Game/42 casos adyacentes.
Dos muestras19425 conservan World/reinicio/reload, pero la final aún añade
«tarde tibia»: selección de guía verificada, calidad de prosa sigue abierta.

D184 reserva quiet_close al registrar una sola consulta informativa/opinión
PC manual, con espera pasiva opcional. Guarda la huella SHA256 del World
codificado sin conversación/checkpoint y el seq de la acción; Conversation.decode
valida esos dos campos y el legado funciona sin ellos. Al cerrar el último PC,
Game.Conversations lee como máximo400 eventos desde la acción y revalida la
prueba en la misma Session.update_state que termina su beat: World igual,
sin intenciones/mini/re-eval/interrupción, narraciones completas en orden,
sin dados/errores/parciales/otra acción y sin nueva pregunta PC. Si pasa,
Conversation.finish_actor("dm") se aplica localmente; el relevo ya existente
devuelve al humano. No hay Task silenciosa ni snapshot que autorice un cambio
fuera del single-writer. Si la prueba falta, cambia o queda truncada, sigue DM.

Pedir a Vex que encargue agua a la posadera, una cláusula de consulta al mundo,
una pregunta nueva de un respondedor o una tirada aunque no mute World
mantienen DM. Preferencias conservan resolución humana; D182 sigue siendo
la única ruta literal PC de recuerdo/observación. No se deducen hechos físicos
de prosa libre.14 casos/69 adyacentes y2580/3 suite limpios.19425 vuelve en
5,574 s: Mara → Lyra → Vex → Mara, dos runs PC/un paso, World/clock36135/
recursos e history DM iguales; reinicio y375/1440 px acreditados. D211 extiende
esa reserva/cierre a hasta tres preguntas informativas consecutivas, verificando
cada una; cláusula adicional en cualquiera conserva DM. La primera
muestra7,642 s no conserva traza de runs por timeout del observador. Continuar
memoria de campaña y PNJs, sin certificar SLA ni calidad narrativa general.

D185 aplica visible_to al historial antes de headers/compresión, igual que
el feed: all para contexto público, all/dm únicamente con viewer "dm".
Game.Beats pasa el participante actual; un turno humano no recibe secretos
aunque use el Server DM. History.import_events(events) es público por defecto,
incluido el recorder. Audiencias desconocidas/ausentes y tool quedan fuera;
las notas originales no se borran. Requests reales TestModel de humano,
Lyra/Vex/DM/recorder y reinicio pendiente verifican la separación. No analiza
secretos en facts/story_bible ni certifica memoria fuera de400. Suite2587/3
limpia, recarga19425/454 eventos sin cambios, sin otro playtest de proveedor.

D186 conserva from_events como crónica reciente; antes de una petición modelo,
Game consulta rolls_before para recuperar hasta32 dice anteriores al corte400.
Filtra partida y all/all-dm antes del límite; History.roll_archive revalida
audiencia, seq/payload, orden y duplicados. El índice parcial de migración9
limita la búsqueda a dice. Se incorpora al prompt actual, después del World,
como selección parcial/pasada, con referencias evento/asalto/fase y el mismo
formateador D181/D161. No es acción pendiente, tool replay ni estado actual;
no añade eventos o nuevos campos. La compresión de history no puede resumir
el mensaje nuevo del run. Habla literal y final recuperada sin modelo omiten
esta consulta; el recorder sigue usando solo la crónica reciente pública.

19425: ventana55–454 ya no contiene24–25. Dos preguntas6,615/5,057 s y dos
runs PC cada una conservan World/clock36135/hero/modelos/history DM, sin dados/
tools/DM/TM/recorder. La primera narra el crítico; la pregunta numérica final
recibe de ambos PCs20 natural,25 contra15 y daño18, contrastados con el original.
454→464→474; dos reinicios/reload375/1440 acreditados. Diez casos/77 adyacentes
y2597/3 suite limpios, incluida compresión forzada. No demuestra memoria de
todo pasado ni recupera escenas/testimonios viejos; las voces siguen copiando
gestos de jarra. Continuar calidad narrativa/campaña antes de declarar beta.

Mesa real `/games/17373`: Iria → Nera → Lyra → DM → Iria en 25,26 s, PG,
casillas y reloj conservados, pausa/reload a 375/1440 px sin JS/overflow.
Regresiones en `conversation_test.exs`/`game_conversation_test.exs` y
artefactos `/tmp/dragonex-playtest/conversation-*`.

Mesa19425 D143: Mara → Vex → DM → Mara en 6,51 s, voz propia Vex85 completa,
raw finish_reason=stop y limpio=persistido; World/biblioteca/pausa/cursor/cola
iguales, cero dados y fichas/reload 375/1440 px sin JS/overflow. El reinicio
real previo tras combate/descanso conserva todo World/historial (79 eventos),
Mara 11/14 PG, 1/2 d6 y tres casillas; anterior/cinco auxiliares terminados.
Gancho de QA retirado; `short-adventure-*`. No garantiza esos tiempos futuros.

**Humano**: intent pendiente → beat; si no, `persist(:waiting)` hasta `declare/3`.
Un `declare` off-turn de **otro** humano despierta al TurnMaster (D27) para
que pueda priorizar esa iniciativa; si el TM no decide, el waiter no pierde
el floor. La UI permite encolar aunque haya un beat en vuelo. Un intent de
combate caduca al volver a exploración (D28). En combate, una reacción
clara (`interrumpo`, `escudo`…) fuerza `cut_in` aunque el TM hubiera
cedido a otro.
Una declaración ordinaria en combate conserva su turno de iniciativa;
el TM solo puede adelantarla como interrupción explícita, no como otro turno
principal. Exploración conserva el reparto dramático.

**DM**: instruction según limbo post-combate / exploración + guardrails, `run_beat`.

**TurnMaster** (fase `:turnmaster`): una sola tool-call de orquestación
(`give_turn_to`, `cut_in`, `react`, `pass_to_dm`, `end_scene`). No narra.
El brief lista **intenciones humanas pendientes**. En combate los relevos
principales se ajustan al primer slot pendiente; tras un mini-turn, al dueño
principal aún pendiente. Si falla o no decide → recuperación canónica de
combate / `WorldDriven` de exploración + nota de sistema, **excepto** en una
re-eval D27 (se queda el waiter).

---

## 6. Construcción y ejecución de un beat — `run_beat`

El GenServer se queda responsive: el beat corre en un
`Task.Supervisor.async_nolink`. El resultado llega por `handle_info({ref, result})`.

**Beat de actor**:
1. Elige el agent (`agent_for`: PCAgent si existe, sino DM).
2. `Brief.turn_prompt` + history compartido (`History.import_events`, §7).
3. Callbacks `on_roll_closed` / `on_text_delta`.
4. `Server.chat` con deps (SharedState, RollLog, beat ctx).
5. `busy = %Beat{kind: :actor, mini_turn: …}`.

Al terminar un DM de exploración, D145 revisa `scene_refresh_pending` del
World. Tiempo positivo/facts nuevos/fin de combate lo marcan; `set_scene`
lo cierra. Si sigue pendiente, el modelo de resúmenes debe devolver un
`final_result(scene)` estructurado, sin herramientas de reglas ni Events.
Usa World y 40 eventos recientes, dos pasos/20 s/1200 caracteres. Game
valida la descripción y que el World siga siendo el esperado, registra
con `refresh_scene` conservando la conversación y luego cierra/persiste el
beat. Errores mantienen pendiente y no repiten efectos. Una pausa no se
revoca. Legacy con tiempo/facts se revisa al rehidratar. No identifica todo
viaje narrado ni garantiza toda semántica; escena inicial de la noche real
queda sustituida por cuarto/huerto, con recursos y retorno intactos.


D166 amplía esa comprobación tras una declaración humana literal de entrada,
salida o aproximación. Su acción guarda scene_before; al terminar el DM,
SceneRefresh exige la misma escena vigente, acción/turn_id actuales y ausencia
de conversación, autoplay, mini o set_scene confirmado. Si el registro ya
cambió, no pide otro. Desde D195 el narrador humano no tiene permiso set_scene:
la confirmación nueva la realiza el DM; se conservan los estados legacy. Una instantánea idéntica confirma sin
writes solo si no hay cambio mecánico pendiente; un fallo de revisión deja
la marca existente durable. La señal no calcula viajes/tiempo ni ejecuta
traslados. Vocabulario acotado; eventos antiguos conservan su ruta.
Once casos/68 focalizados y gate2483/3 trazado limpio.19425 registra interior
de la taberna tras avanzar a la barra, conserva reloj34200/recursos y restart/
reload. Recorder9,579 s y TM6,274 s de22,895 s permanecen bajo revisión de ritmo.

El contexto D144 identifica la escena como último registro e incluye reloj
relativo y disponibilidad real de descanso largo. Los hechos canónicos tienen
prioridad y llegan también a TurnMaster. `rest_party` devuelve el reloj ya
confirmado; construir briefs no modifica el World. La mañana real tras ocho
horas omite `set_scene` aun con esta guía; D145 añade el cierre acotado anterior.

**Beat TurnMaster** (`run_turnmaster_beat`):
Desde D180 el constructor toma `Models.turnmaster_max_tokens/0`:1024 tokens
por petición, incluyendo el razonamiento que contabilice el proveedor.
`DRAGONEX_TURNMASTER_MAX_TOKENS` acepta un entero positivo; vacío/inválido
mantiene1024. Una opción explícita del constructor prevalece. Bootstrap no
repite256: crear/reiniciar el Game recoge la configuración. Modelos/routing,
máximo de tres pasos, primera decisión terminal y fallback no cambian.

1. `Brief.turnmaster_brief/4` (world + last_actor + roster + `state.intents`)
   + `TurnMaster.instruction` (`pending_intents`, contexto D134 de personas
   y compañeros IA que ya actuaron desde la última intervención humana).
2. Recorder `Decision` por beat.
3. `Server.chat(turnmaster, …)` sin streaming y con `message_history: []`
   (D105): cada relevo recibe un solo snapshot vigente. Las correcciones de
   tools permanecen dentro del run; prompts obsoletos no pasan al siguiente.
4. `busy = %Beat{kind: :turnmaster}`.

**Resultado actor OK**: no `end_turn`; `maybe_force_combat` / `maybe_end_combat` /
`mark_acted` / `maybe_advance_round` (por `acted_this_round`); pasa a TurnMaster.
El siguiente tick aplica directamente la iniciativa en combate ordinario
(D113): misma nota, efectos/dados de inicio, persistencia y broadcast, sin
petición al modelo. Intenciones humanas, re-eval e interrupciones mantienen
consulta. Todas las decisiones principales consultadas también respetan ese orden.

En exploración ordinaria, D134 consulta los últimos 64 marcadores `:turn`
con `Games.recent_turns`, sin perder participación entre mensajes del DM ni
por volumen de tools. `ExplorationTurns` deriva PCs elegibles, humanos manuales
y compañeros servidos: repetir una IA devuelve a una persona; una intervención
de cada compañero disponible completa el ciclo y cede al humano sin otra
petición TM. Orden humano por participación más antigua/ninguna y luego nombre.
Intenciones, preguntas dirigidas y conversaciones tienen prioridad. Mini-turns,
re-eval y combate conservan su camino; autoplay cuenta como IA. El cálculo se
reconstruye de eventos al reabrir y no añade estado efímero ni campos al World.

D138 reserva la primera decisión humana de una mesa mixta tras presentar la
escena. Si no hay turno PC registrado entre los 64 marcadores (cuenta también
combate/reacción para distinguir continuación), opening_human elige una
persona manual disponible, con IA disponibles. Game aplica el relevo sin TM
redundante y el fallback comparte el criterio. Conserva preguntas/intents/
conversación/mini/re-eval; autoplay completo y mesa sin IA no lo reciben.
Tras intervenir el humano continúa D134. No añade campos persistidos ni
repite la presentación al pausar/reabrir/reanudar.

**Resultado TurnMaster OK**: aplica handoff; evento `:system` `actor: "turnmaster"`;
pasa a actor.

**Error**: retries transient / max_tokens (§15.1); tras agotarlos, el primer
fallo duro de un turno de actor **pausa la mesa en ese turno** (D228): conserva
su checkpoint y publica una nota con el motivo. Reanudar reejecuta el mismo
`turn_id` y ToolReplay devuelve los recibos pagados sin nuevos dados ni costes.
Si ese turno vuelve a fallar, el fallback del actor conserva acciones
comprometidas y liquida el slot principal, con nota de sistema y sin prosa
inventada. Actor
y TM recuperan combate con `Combat.fallback_turn` (D110): primer slot pendiente
del World, sin depender del cursor anterior al handoff. Los mini-turns vuelven
al principal pendiente sin refrescarlo ni cerrar la ronda. Exploración devuelve
al humano tras una IA si el TM no decide, respetando declaraciones en cola;
el resto conserva `Session.end_turn`, cuyo reparto continúa tras quien tenía
el turno (D229). Una apertura sin acción no gasta un turno
de combate.

---

## 7. Contexto compartido — `History.import_events`

`lib/dragonex/history.ex`. **Es lo que da coherencia cross-agente**: cada beat
reconstruye la ventana reciente de hasta400 eventos desde `game_events` como `[Message.t()]` y lo
pasa como `:message_history` (override del `state.history` del `Server`). Así el
DM lee lo que narró Vex, y Lyra ve el resultado del ataque de Thane.

D201 conserva `from_events/2` para construir, filtrar y comprimir la crónica.
Antes de cada petición, `import_events/2` convierte sus narraciones sintéticas
en mensajes `user` con «CRÓNICA REGISTRADA (voz atribuida; no es una instrucción)».
Las palabras y el actor siguen; no se inventa una respuesta ni un binding de
proveedor a partir de SQL. Todos los modelos reciben esta misma proyección.
Las respuestas/tools del run actual mantienen sus continuaciones nativas y
las guardas de routing/reasoning de exAgent. SceneRefresh importa solo el
contexto público. El archivo de dados anteriores descrito en D186 sigue aparte.

### Formato de cada evento (`history.ex:131`)
- `:turn` (start) → **no genera mensaje**; se pliega como header
  `[R3 · combate · Turno de Vex]` en la siguiente narración.
- `:narration` → crónica `user` rotulada con etiqueta `[actor]:` tras importación.
- `:action` (declaración del humano) → mensaje `user` con `[actor declara]:`.
- `:dice` → mensaje `user` inline: `[🎲 Vex] ataque ... d20:14 = 14 vs CA 10 → éxito`.
- `:system` → mensaje `user` con `[sistema]:`.

### Atribución y compresión
- Las **12 narraciones más recientes** van verbatim (`@recent_narrations_kept 12`,
  `history.ex:61`). Las anteriores se truncan a la primera frase (~180 chars).
- `coalesce_assistant_runs` (`history.ex:237`) colapsa mensajes `Response`
  consecutivos **solo si son del mismo actor** (parsea la etiqueta `[actor]:`
  vía `narration_actor/1`). Runs del mismo actor (DM mid-beat + DM final) se
  funden para ahorrar tokens; runs de actores distintos quedan como turnos
  separados con su propia etiqueta, preservando la atribución antes de importar
  los bloques como contexto `user`.

### ✅ Fixes aplicados en la reconstrucción (causas del "bucle temporal")
Tres bugs en `history.ex` degradaban el contexto que recibía el modelo y eran
la raíz de la incoherencia de la partida de prueba. Ya resueltos:

1. **`coalesce_assistant_runs` mezclaba actores**: colapsaba **cualquier** par
   de `Response` consecutivas sin comprobar el actor, fundiendo narraciones de
   turnos adyacentes (DM, Thane, Vex, Lyra) en un único blob `assistant`. El
   modelo perdía quién dijo qué → re-narraba y re-asignaba acciones. Ahora
   solo colapsa mismo actor.
2. **`split_responses` tenía los grupos invertidos** (el más grave): el
   predicado `responses_after <= keep` seleccionaba los "recent" pero el código
   los llamaba `old_pairs`. Resultado: las narraciones **RECIENTES se
   truncaban** y las **VIEJAS iban verbatim al FINAL** del history (orden
   temporal corrompido). Ahora el predicado es `>= keep`, que marca los "old"
   correctamente. Sin este fix, el modelo veía el pasado reciente recortado y
   el pasado lejano desordenado al final — justo lo que provocaba que el
   demonio pareciera "nuevo".
3. **Compresión demasiado corta** (`@recent_narrations_kept = 5`): con 4 agentes
   auto (~6-8 narraciones por ronda) solo la última ronda y media iba entera.
   Subido a **12** (~2 rondas completas), margen suficiente para la continuidad.

---

## 8. Los agentes

### DM — `lib/dragonex/dm.ex`
Un único agent que narra el mundo, da voz a monstruos/PNJ, arbitra y controla
el ritmo. **System prompt de 18 reglas**, con la story bible
horneada al final (prefijo cacheable). Críticas:
- **#3** quién actúa (turno de jugador vs turno del DM; las herramientas de
  escena como `roll_initiative`/`spawn_monster` están exentas).
- **#5** empezar combate es urgente: llamar `roll_initiative` al instante al
  estallar pelea o al spawnear un hostil (con nota de que el motor lo fuerza
  como red de seguridad, ver §15.2).
- **#11** avance de escena: tras 2 turnos sin progreso, provocar un evento.
- **#14** SOLO narras tu turno y tus monstruos/PNJ; **nunca** narras a un PC
  haciendo algo.
- **#15** no revelar stats (HP/CA) a los jugadores.
- **#16** formato de output: prosa pura, sin etiquetas `[Actor]:`, tablas, ni
  tokens internos.

DM y PCAgent usan `AgentInstructions` después de compacción (D132): antepone
el rol actual en `request_messages`, conservando historial/resumen y una sola
copia del prefijo. Es necesario porque exAgent no inserta instrucciones con
historial no vacío y el adaptador Chat no lee params.instructions. El historial
canónico de eventos y sus índices no se cambian; TurnMaster ya usa historia
vacía en cada decisión. Los smokes verifican messages codificados para proveedor.

D133 pasa también el dm_style guardado a ese prefijo estable: tono/ritmo y
eventos lo reciben al construir/rehidratar DM. Custom/predefinidos y reapertura
pausada están verificados; vacío/legacy no soportado conserva el prompt base.
Se verifica envío de la preferencia; no se garantiza toda obediencia del modelo.

### PCAgent — `lib/dragonex/pc_agent.ex`
Un agent por personaje IA, con personalidad derivada de su clase
(`pc_agent.ex:514`). Tools restringidas (31, `pc_agent.ex:48`): además de lo
básico (`make_attack`, `cast_spell`, `ability_check`, `make_death_save`,
descansos, `drop_concentration`), cada PC gestiona SUS recursos de clase y
raza — furia/Reckless, Second Wind, Action Surge, Ráfaga de golpes (ki),
Marca del cazador, Esconderse (Astucia), Esquiva asombrosa, Fuente de magia
(crear/convertir casillas), Metamagia, Castigo divino, Manos impositoras,
Sentido divino, Expulsar no-muertos, Inspiración bárdica, Recuperación
arcana, Forma salvaje (`wild_shape`/`end_wild_shape`), Aliento de dragón
(racial dragontina) y Expertise (`gain_expertise`). NO puede spawnear, tirar
iniciativa, terminar combate ni subir nivel. Reglas clave:
- **#3** solo objetivos válidos listados en la instrucción.
- **#4** exploración sin enemigos → actúa en personaje sin tool.
- **#5** proactividad en turno libre; responder ya es una intervención completa.
  **ANTIBUCLE** distingue propuestas repetidas de respuestas que conservan hechos (D187).
- **#10/#11** formato y no stats.

### Instruction por turno
- `PCAgent.instruction/3` (`pc_agent.ex:194`): adapta al estado. Caído → solo
  `make_death_save`; estable a 0 PG → no tira ni actúa; muerto → nada. Combate con enemigos → lista objetivos
  válidos + armas + upcasting (`cast_level` en `cast_spell`) y las líneas de
  clase/nivel que apliquen (oleada, ráfaga, inspiración, esconderse, esquema
  asombrosa, aliento, marca, fuente de magia, metamagia armada, forma
  salvaje — recuerda que en forma de bestia NO se puede conjurar).
  Exploración → actúa en personaje, sin forzar tool; Expertise pendiente para
  pícaro/bardo.
- `Brief.turn_prompt/5` (`brief.ex`): `world_brief` + instruction.

D168 añade al turno de respuesta pendiente la personalidad de clase y un
contrato de voz propia: la intervención anterior informa, no es un guion.
Puede coincidir con la elección ajena, sin copiar frases/gestos ni inventar
desacuerdo o hechos. Conserva el historial, los acuerdos y los turnos; no añade
filtros ni otra consulta. Scope normal/combate/caído intacto. Tres casos/39
focalizados y19425 real10,198 s verifican entrega y un acuerdo con otra prosa;
no garantizan originalidad general del modelo.

D187 retira la obligación de añadir gestos a una respuesta. El prefijo estable
y la instrucción del turno permiten diálogo breve y datos confirmados repetidos.
Game selecciona contexto de respuesta desde World.conversation para un PC
consciente; el nudge activo respeta ese contexto, sin inspecciones, nuevas
acciones ni tiradas obligatorias. El detector compara las dos narraciones
públicas más recientes del actor dentro de40 eventos, cita la última en el
turno libre y excluye notas privadas. Sigue siendo una ventana acotada, no
un detector semántico de toda la campaña. No modifica reglas ni filtra prosa
por similitud. Preguntar a un PNJ o pedir agua mantiene la ruta DM existente.

---

D188 amplía literal_pc_speech a las formas informativas/opinión ya reconocidas,
no solo recuerdo. Game publica la pregunta tras scrub y mantiene cola/nombres/
orden/espera pasiva; sin petición humana para decorarla. Declaraciones mixtas,
peticiones de acción y guardas anteriores conservan modelo/tools. D184 sigue
comprobando si después de las respuestas hace falta un beat DM.19425 acredita
habla exacta y dos runs PC, sin cambiar World ni decidir que ya se viajó.

D189 comparte los roles PNJ reconocidos entre pregunta y vocativo, añadiendo
oficios del pueblo y un complemento corto de/del. Game pasa todos los nombres
PC del World tanto al registro como al habla literal; una coincidencia completa
o corta con identidad PC impide reservarlo como PNJ. NFC/artículos/espacios y
límites de palabra conservan esa prioridad. La cola y las guardas D167/D177
siguen vigentes, con el mismo single-writer; acciones añadidas conservan tools.
19425 viaja explícitamente900 s al molino, reloj37035/escena persistidos, y
pregunta al zagal con habla exacta/un DM dos pasos/testimonio atribuido. No
convierte palabras del PNJ en verdad confirmada ni amplía memoria ilimitada.

D192 añade una preposición + interrogativo acentuado a los filtros informativos
PNJ/PC («¿De qué…?», «¿Por qué…?», «¿Con quién…?»). Usa la publicación literal
existente: pregunta registrada completa, palabras saneadas sin reformulación
humana y respuesta del destinatario con su rol. Mantiene prioridades de identidad,
guardas/sufijos pasivos y cierre discreto PC cuando lo acredita el motor.
Acciones añadidas/duración/magia siguen por modelo/tools.19425 confirma pregunta
PNJ sin narrador humano, viaje explícito900 s/escena/reloj37935 y recuerdo de
origen/hatillo por Lyra/Vex sin DM/TM o cambios World. El reinicio conserva682
eventos/estado; reconocimiento acotado, sin promesa de latencia o memoria total.

D193 fecha el registro de testimonios nuevos con elapsed_seconds del World,
fuera de la cita: «[Registrado a los N s del reloj del mundo.]». No es hora del
día/fecha real ni fecha confirmada de lo que el PNJ dice que ocurrió. Brief
DM/PC/TM remite expresiones relativas al momento del registro; legado sin
marca no recibe una fecha inferida. Repetir una versión normalizada aún en
facts conserva primera marca/posición, sin renovar memoria; cap30 permanece.
Codec/DB/checkpoint/restart/compacción conservan el texto, sin campos nuevos.
19425 guarda versión sobre viajar solo en38835, avanza900 s y conserva marca
al preguntar a Lyra/Vex: ambos distinguen versión de botón/huellas. No garantiza
que el modelo guarde cada pista o razone cualquier expresión temporal.

D199 reconoce equivalencia textual de envolturas completas no ambiguas en
record_npc_statement. Nuevos cuerpos omiten comillas externas redundantes;
citas parciales/internas/apóstrofos conservados. Repetir devuelve el fact
retenido exacto, primera marca/posición o ausencia de marca legacy, sin renovar
referencia/expulsar al cap. Fuente/duda/contenido distinto sigue distinto,
reloj dentro de cita sigue contenido; entrada vacía citada rechaza y límites
siguen previos a desenvuelto. World/Codec/Tools/Rules/guías de rol no cambian.
Game DM normal y checkpoint/replay/repeat/restart conserva recurso y único
registro; el caso no-op no requiere checkpoint. Sin nueva acción LLM:19425
sigue pausada806/14 facts originales y otra mesa intacta vía SQL/UI.

D198 proyecta facts con formato «fuente afirma: «…»» en una sección de
Testimonios atribuidos, separada de Hechos establecidos. Conserva cadenas,
marcas y orden por sección sin mutar almacenamiento. Guía final en todos los
beats DM/PC/humano con testimonio, después de archivo/inventario/hechos:
prosa/resumen anterior no convierte comparación de PNJ en observación del PC.
DM conserva primera persona en voz del testigo; TM recibe ambas secciones,
sin nuevas capacidades. Compacción con resumen falso conserva fuentes actuales.
19425 vuelve900 s y registra una comparación del zagal; recuerdo anterior
786→796 confundía fuente. Misma pregunta796→806/6,616 s atribuye al zagal
la comparación en ambas respuestas sin World/tools/dados nuevos. Fuente
correcta en este caso no prueba memoria durable de todos los detalles de
prosa ni voces originales; no cambia Rules/Codec ni reescribe legacy.

D197 reserva heal/grant_temp_hp/apply_condition/remove_condition/level_up
al actor dm antes de World/target/RNG/propuesta. Humano con DMServer resuelve
su hechizo/feature mediante Rules, no concede su efecto por tool directa ni
sube al compañero. Error directivo remite a cast_spell/second_wind/capacidad;
DM conserva adjudicación y aviso de ficha humana. Se restringe permiso PC
propio D36, sin cambiar fuente/plazo/no stacking de False Life. Game normal/
restart conserva slot/dado/plazo originales del hechizo antes de curación DM,
veneno y nivel/compañera intactos. No acredita fuente/coste de toda adjudicación
DM ni extrae efectos de prosa; otros aspectos de agencia siguen en auditoría.

D196 reserva spawn_monster/roll_initiative/end_combat al actor dm antes de
World/RNG/propuesta. Resolver una acción humana con DMServer no concede
permiso para crear enemigos o pedir fases. Error recuperable devuelve al actor
a sus reglas; DM crea y solicita, motor sigue imponiendo combate/iniciativa/
relevos. Reinicio entre rechazo y confirmación no introduce enemigo ni dados
humanos; spawn DM posterior conserva iniciativa forzada nativa. Rules/World
puros y stubs de framework permanecen. Otros mutadores requieren auditoría.

D195 reserva establish_fact/set_scene al actor canónico dm antes de leer o
proponer World. El resolvedor humano comparte DMServer/tools para sus Rules,
pero no puede confirmar por sí mismo entorno o descubrimiento. La guía de
exploración se entrega después de archivo/inventario: DM revisa declaración,
resultado native/facts y registra un descubrimiento relevante confirmado antes
de narrar, sin inferir identidad por éxito ni convertir testimonio en verdad.
No hay extracción automática de prosa ni migración/reclasificación de legacy.
Game/restart entre rechazo y confirmación conserva chequeo/replay; compacción
DM/PC conserva hechos persistidos. Live19425 inspecciona20vs15 sin fact nuevo,
recoge hilo×1 mediante grant_item DM y consulta dueño incierto sin World nuevo.
Restart772/SQL conserva historia/roles/recursos. Detalles solo en prosa siguen
limitados y otros mutadores de mundo requieren auditoría propia.

D194 limita el dado modal a presentación: lee against del grupo factual,
rotula diálogo y conserva lienzo dic_ex montado. Cerrar con Escape/botón o
fallback cancela timers, invalida flush y libera rolling; cada cierre lleva
referencia local y Snapshot la conserva. Un mensaje antiguo no cierra otro
grupo, un flush duplicado no vuelve a lanzar teatro y asentado oculto/antes
de flush no rearma timer. FocusWrap/JS contienen foco y restauran el previo;
aria-hidden/inert apartan el diálogo oculto. No hay World/RNG/Codec nuevos.
19425 investiga19vs15 y después sigue rastro7vs15: éxito previo no garantiza
seguimiento, fallo pierde pista, advance_time registra900 s y revisión de
escena conserva ese resultado. Restart729/SQL mantiene historia y recursos.
UI1440/375 reproduce solo payload716 sin nueva tirada y verifica teclado;
Escape también funciona en tirada724. Pista nueva queda solo en narración;
memoria durable de observaciones y callbacks 3D sin generación siguen acotados.

D190 registra posesión descriptiva con grant_item/remove_item del DM en
exploración: Rules valida nombre, cantidad, stock, identidad y límites, World
aplica mediante Game. El narrador humano no puede confirmar inventario; el
DM registra consecuencias efectivas aunque la prosa anterior diga «lo guarda».
Un recordatorio al final del prompt, después del archivo de dados, conserva
la última declaración pública/DM aún no respondida, saneada/acotada. No extrae
stock desde texto. Brief y ficha propia leen cantidades del World; reload o
subir de nivel no devuelve botín ni modifica la ficha del héroe reusable.

Cambiar posesión solicita revisión durable del decorado. El recorder prioriza
inventario/eventos establecidos y Game confirma su snapshot. Descripción
idéntica solo limpia pendiente con comprobante de ese beat y huella intacta
del resto del World, sin revisión anterior y commit contra estado exacto.
Un timeout deja pendiente y no reejecuta la entrega:19425 retira1 en623→630,
la revisión agota20 s, y la nueva recogida630→637 registra1/revisa escena en
3,634 s/deja pendiente false. Reinicio conserva637 eventos/recursos/ajustes;
la ficha muestra Botón de latón ×1. No hay registro global del suelo,
equipamiento/consumo/economía ni garantía de toda formulación LLM.

## 9. El `world_brief` — lo que el agente "ve"

`brief.ex:24`. Snapshot compacto del mundo que se inyecta en cada turno:
- línea de fase (`Combate -- ronda 2 (iniciativa: goblin → Thane)` o `Exploración`),
- de quién es el turno (y si es DM, qué monstruos controla),
- línea de control (quién es IA auto vs quién espera input humano),
- **hechos establecidos** (`world.facts`, §15.8): verdad canónica persistente
  que todos los agentes leen cada turno (evita que el DM abandone o reintroduzca
  ganchos),
- escena,
- una línea por personaje: identidad canónica de raza/clase/nivel y lado,
  `hp/max_hp pg`, PG temporales separados si hay, CA efectiva (y base si
  difiere), estado vital, condiciones, armas/hechizos/casillas.

Desde D94 se reutiliza `Rules.Effects.effective_ac/1`: Shield of Faith o
Defense ya se reflejan en el contexto del narrador, sin cambiar `Character.ac`.
El sentinel de estabilidad distingue `[ESTABLE]`, `[CAÍDO]` y `[MUERTO]`.
El brief compacto del TM usa la misma presentación factual. DM/PCAgent reciben
una instrucción para respetar esos datos y distinguir regalo narrado de efecto
mecánico aplicado por tools; no es una garantía contra alucinaciones.

Desde D93, cuando D30 ya obliga a dar la palabra al humano interpelado tras
un beat del DM, el Game hace el relevo sin consulta redundante al TM. Combate,
mini-turns/interrupciones, re-evaluación, intents pendientes y narración ambigua
mantienen la consulta. D136 resuelve formas cortas únicas a su identidad completa contra todos los
personajes registrados; un nombre PNJ/IA más largo o abreviatura ambigua no
fuerzan otro humano. World valida presencia/capacidad antes de seleccionar.
Para preguntas genéricas, si los últimos 24 eventos perdieron al humano
anterior, los últimos 64 marcadores de turno conservan su identidad.
Las referencias de preguntas siguen siendo una clasificación acotada.
Los 11 tests de `turnmaster_fast_path_test.exs` cuentan
peticiones del modelo; no sustituyen una medición de latencia real.

> **Nota**: el brief muestra HP/CA al modelo (los necesita para decidir), pero la
> regla #15 le prohíbe verbalizarlos al jugador. La sanitización (`Text.scrub`,
> §14) limpia lo que se escapa.

---

## 10. Herramientas y resolución por reglas

Guiado se combina con las demás fuentes antes de cancelar ventaja y
desventaja (D247): oculto + envenenado + Guiado sigue siendo una tirada
normal. La marca afecta solo al primer ataque y se consume aunque falle;
el furtivo consulta la ventaja efectiva de ese golpe. Los críticos de Arma
espiritual tiran dados independientes, también al subir su nivel de casilla,
y suman el modificador una vez. Su daño final nunca es negativo; el desglose
conserva el subtotal para explicar el mínimo cero.

`lib/dragonex/tools.ex`. Cada `deftool` propone un cambio vía `SharedState` tras
pasar el guard de control (`assert_controls`). Las herramientas de resolución
(`make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `heal`,
`roll_initiative`) tienen `max_retries: 3` (`dm.ex:32`, `pc_agent.ex:54`): si el
modelo propone como actor equivocado, el guard devuelve un error directivo y hay
margen para autocorregirse.

La matemática vive en `Dragonex.Rules.*` (`Combat`, `Ability`, `Skills`,
`Conditions`, `Upcast`) y `Dragonex.Actions`. Las herramientas son puentes:
nunca calculan números, solo proponen el change.

Además de la resolución genérica, el set cubre los recursos de clase/raza del
lote D35–D77: pools y posturas (ki, puntos de hechicería, furia con usos,
metamagia, wild shape, uncanny dodge, aliento de dragón, expertise),
upcasting (`cast_spell` acepta `cast_level`; escalado RAW vía `Rules.Upcast`) y
condiciones (`hidden` para el pícaro, marcado de `hunters_mark`). El daño
entrante pasa por capas fijas en `World.apply_damage/3-4` (`world.ex:326`):
Esquiva asombrosa mitiga el daño entrante y consume la postura
(D64) → resistencias/inmunidades D38 (incl. resistencia racial al veneno
enana D76 y overlay de furia B/P/S D42) → `temp_hp` (D36) → `hp` →
auto-revert de Forma salvaje (D63) → Furia implacable (salva CON, D72) →
Resistencia implacable (semi-orco, hp 0 → 1, D67).

---

## 11. Combate end-to-end

1. **Inicio**: el DM llama `roll_initiative` (o el motor lo fuerza, §15.2).
   `Actions.initiative` rolla d20+mod para cada combatiente consciente, ordena
   descendente y devuelve un `World.begin_combat(order)` change. La fase pasa a
   `:combat`.
2. **Turnos**: un beat por combatiente (D34). `WorldDriven` cicla
   `initiative_order` mapeando enemigos al DM **sin** colapsar slots
   consecutivos. `World.current_combatant` nombra el slot; `can_act?`
   admite al controlador (`"dm"` o el PC).
3. **Resolución**: `make_attack`/`cast_spell` resuelven por reglas, persisten
   `:dice` (modal en vivo) y aplican daño (capas: uncanny → resistencias →
   temp_hp → hp → revert → relentless, §10). `cast_spell` acepta `cast_level`
   para upcasting RAW (D74) y consume/aplica metamagia armada (D65); un
   objetivo `hidden` otorga ventaja al atacante oculto y se revela al
   impactar (D57); `hunters_mark` suma +1d6 contra la presa (D55).
4. **Fin automático** (`maybe_end_combat`, `game/combat.ex:21`): cuando
   `World.combat_over?` (≤1 lado con conscientes), el motor cambia a
   `:exploration` y emite `[sistema]: ⚔ El combate termina.`. No depende de que
   el DM lo recuerde.
5. **Avance de ronda** (`maybe_advance_round`, `game/combat.ex:110`): cuando el último
   del ciclo actúa, `world.round` sube.

---

## 12. Auto-play

Un humano puede togglear auto-play (`enable_auto_play/disable_auto_play`,
`game.ex:252`). Al activarlo se crea un `PCAgent` para ese personaje y, si está
en su turno `:waiting`, se flipea a `:running` para que el bot juegue ya. El
toggle se refleja en el snapshot (`auto_humans`) y sobrevive a recargas.

---

## 13. Eventos en vivo y streaming

D222 conecta `Narration`/`Contract` por defecto a DM, PC y resolutor manual,
en ambos grafos. Text libre y deltas quedan en la continuación nativa privada;
narrate publica declaraciones intermedias y final_result aislado/validado
publica cierre después de las resoluciones obligatorias. Voz manual procede
de la acción original, como intención. Game guarda texto/checkpoint juntos
en SQL antes de Session/PubSub: intermedia antes del acuse, final hasta
settlement incluso sin tools. Rechazo recibe corrección acotada y luego
pausa recuperable; conserva dados/recursos/declaraciones publicadas.
Presupuestos sobreviven a backoff; segundo corte de tokens pausa sin borrar
segmentos válidos. Un cierre inválido/truncado llegado tras pausa manual
conserva pausa y checkpoint, sin programar otro retry de Game.

271 focales locales/269 Hex verifican integración, SQL rollback, reinicios
y etapas de UI; otros9 y30 por grafo verifican espera/PNJ/iniciativa SQL y
voz/memoria/agencia/actualización de escena.109 archivos anteriores
migrados explícitamente; gates completos local2858/3 yHex2849/3,
secuenciales y limpios. R16/live pendientes.
Tandas posteriores local/Hex:25/23 PNJ/escena/ReqLLM retry,55/55 efectos/
persistencia/ciclo de vida,68/68 mesa web/reacciones/progresión,13/13 hechos/
antibucle,17/17 iniciativa/relevo,21/21 TurnMaster y3/3 lobby/ficha móvil.
Los previews inyectados
en pruebas web acreditan sanitización/render legado, no streaming del proveedor.
No hay preview activo token a token del campo estructurado; transporte
privado y mensajes inyectados en LiveView no acreditan ese criterio.
El stream público actual de exAgent/ReqLLM devuelve deltas de texto y calls
completas al terminar; falta un camino público para sus argumentos tipados.
19446/42 conserva el razonamiento público original.
Dentro de un run, las respuestas privadas nativas permanecen completas.
En v2 local, D223 conserva la causa Model cuando sólo la copia de su respuesta
incompleta desborda el error4KiB: esa copia lleva marker y pending_response
retiene el diagnóstico separado del historial ejecutable. Ninguna call parcial
se ejecuta. Game reconoce el corte de tokens y reusa recibos pagados en otro
run; control arbitrario todavía sobredimensionado sigue rechazado.
El retry de Game inicia otro run con eventos públicos y recibos actuales;
el cierre rechazado no se convierte en historia compartida. ReqLLM requiere
tools en cada petición: el texto final también usa final_result.

- **Admisión de ataques enemigos (D225)**: el Game revisa su World antes del
  callback de una nueva make_attack. Enemigo presente/apto/controlado en
  exploración recibe directiva de tirar iniciativa; no consume RNG ni aplica
  daño. El recibo pagado se busca antes de admitir una ejecución nueva.
  La corrección usa el presupuesto del agente; no añade iniciativa por cada
  spawn ni cambia el API de matemática/Session sin Game. Dos regresiones,
  gates2862/3 local/2852/3 Hex verdes; nuevo playtest del guard pendiente.
  19448/48 conserva el ataque previo a iniciativa y el segundo en combate,
  aunque su recogida/entrega/cierre canónico sí pasan con el paquete nuevo.
- **Tiradas en vivo** (`RollLog.start` con `on_close`): cada grupo de dados se
  persiste y broadcastea **al instante** (no al final del beat). El modal abre
  una vez por tirada con todo el contexto.
- **Narración en vivo**: narrate y cierre validado publican `:narration` con
  `Text.scrub(text, actor)`; Game confirma texto/recibo antes del fan-out.
  `Events.after_model_request` conserva las respuestas tipadas privadas.
- **Transporte de streaming**: proveedor puede devolver un stream, pero sus
  `:text_delta` no se anuncian. La burbuja del render legado sigue compatible;
  preview estructurado de R16 requiere implementación/pruebas.
- **Anti-duplicación de segmentos** (`maybe_flush_live_text/3` +
  `segment_already_carded?` en `show.ex`): en un beat `texto → tool → texto`, el
  camino legado: el segundo segmento se persiste como un `:narration` nuevo
  antes del streaming siguiente. Cuando llega
  el `:game_updated`, la burbuja se limpia si su `live_text` coincide con la
  última narración persistida del actor, así el segundo segmento streamea limpio
  en su propia caja en vez de appendarse al primero (que ya está cardado).
- **Render sin auto-referencia duplicada** (`leading_self?/2` en `show.ex`): la
  burbuja usa `Chat.live_shown`/Text con actor y nombres PC. La vista evita
  duplicar la auto-referencia con el span `who`; la limpieza de gestos/citas
  ajenas se comparte con el camino de persistencia (D103/D119/D123).

---

## 14. Sanitización — `Text.scrub`  (`lib/dragonex/text.ex`)

Cuello de botella central y determinístico: se aplica ANTES de persistir
cualquier narración (`events.ex:64`); el history compartido recibe esos eventos
ya limpios y sanea UTF-8, sin volver a recortarlos. Una
sola regla cubre todos los puntos de consumo (cajas, history, summarización) sin
depender de que el modelo obedezca el prompt.

Entradas:
- `scrub(text)` → equivalente a `scrub(text, nil)` (sin actor).
- `scrub(text, actor)` → además quita la auto-referencia inicial del actor (ver
  paso 3).
- `scrub(text, actor, pc_names: names, wait_for_human: boolean)` → añade los
  recortes de voz/preguntas/acciones ajenas y ejecución de exploración.

Pasos, en orden:
1. etiquetas iniciales `[Actor]:` / `[Actor declara]:` (hasta 4 anidadas),
2. headers de turno iniciales (`R2 · combate · Turno de …`) **y** tags
   mid-prosa `[R2 · Turno de X]` / `[→ Name decide]` (D7/D30),
3. **auto-referencia inicial** (`strip_leading_self_name`, solo con `scrub/2`):
   quita el nombre DEL actor al inicio ("Lyra levanta…" → "levanta…"), con
   separador tras él **o pegado a una minúscula** ("Thanedeja…" → "deja…", el
   leak típico de DeepSeek). Así el DM narrando "Lyra cae herida" (actor "dm")
   queda intacto. Resuelve el "LyraLyra" en cajas e history de una sola vez.
4. tokens internos de DeepSeek `<｜DSML｜…>`,
5. bloques de recap de combate (`**Estado del Combate:**` + listas con stats),
6. HP/CA inline: `6/13 pg` (X/Y), `CA 15`, `7 PG` bare, `X de los Y puntos de
   vida`, `clase de armadura N` (conservador con números lore),
7. **líneas con sintaxis de dados del motor** (`d20: +5 vs`) que el modelo
   imita del history — un leak de tool-call narrada se elimina entero,
8. **tool-calls escritas en prosa** (`establish_fact("…")`, `spawn_monster(…)`,
   `[Establecer hecho: …]`) — el modelo las escribe en vez de emitirlas como
   tool real; se eliminan,
9. **frases meta / ruptura de cuarta pared** ("el sistema resuelve…", "la escena
   se resetea", "lo materializo en el mundo para que sea oficial", "como DM…"),
10. frases meta del motor ("el sistema resuelve…"),
11. acciones/citas de PCs ajenos, incluyendo relativas proactivas acotadas
    (D29/D119/D123); el PC actor conserva su voz,
12. fugas PC de voz PNJ/saltos de tiempo y ejecución antes del humano,
13. tablas markdown y battlemaps ASCII.

**Idempotente**: limpiar texto ya limpio es no-op. Es la red que atrapa lo que
el modelo filtra cuando desobedece las reglas #15/#16.

---

## 15. Robustez del bucle

### 15.1 Reintentos y fallback (`game/settlement.ex:34`, `handle_beat_result`)
Dos presupuestos de retry **independientes** por beat:
- **max_tokens**: si el modelo se corta a mitad, reintenta UNA vez con un
  preamble "SÉ BREVE" (`brief_retry_instruction`).
- **transitorio** (`schedule_transient_retry`, `game.ex`): ante errores del
  proveedor `{:model_request_failed, %ExAgent.RequestError{…}}` con `:timeout`,
  `:request_failed`, HTTP 5xx/429, o `:provider_error` con body de overload/rate,
  reintenta con **backoff exponencial** (1s → 3s → 10s, máx. 3) vía
  `Process.send_after({:retry_beat, turn_id})`. Mientras duerme, `busy` queda
  como `pending_retry` (sin Task ref) para que `advance` no lance beats
  competidores. Tras agotar 3 reintentos, el actor pausa con su comprobante y
  motivo; si el mismo turno vuelve a fallar al reanudar, se omite con nota
  explícita (D228). Backoff overrideable por `{:dragonex, :transient_backoffs}`.
- **Crash del Task** → `:DOWN` → la misma política de fallo del actor.

Un reintento por tokens conserva el presupuesto transitorio ya gastado
(D248). Las tres vías de retry, incluida la corrección del contrato de
narración, conservan si el beat era una reacción. Aunque todavía no exista
un recibo durable, ni el backoff ni pausar/reanudar convierten esa reacción
en turno principal ni marcan al reactor como actuado en la ronda.

### 15.2 Combate fantasma — `maybe_force_combat` (`game.ex`, §bug #2)
Si un beat **introduce** un enemigo vivo (`side == "enemy"`, hp > 0) mientras la
fase es `:exploration`, el motor tira iniciativa él mismo y hace `begin_combat`.
Compara `enemies_before`/`after` (guardados en `busy`) para **no** disparar en
el beat de setup (monstruos preexistentes no cuentan). Emite
`[sistema]: ⚔ Aparecen hostiles — el motor toma la iniciativa automáticamente.`.
Los grupos de iniciativa usan el roller de Game/RollLog y se publican una
sola vez en historial/PubSub/modal tras aplicar la transición por Session
(`timing: "forced_initiative"`, D116). También se comprueba al terminar un beat
con fallo terminal después de introducir un hostil; el primer slot sin jugar
no se marca gastado. Iniciativa explícita, escritor no admitido o hostiles
preexistentes no generan tiradas automáticas adicionales.

D159 prepara el candidato antes de
mutar Session. Guarda World, todos los grupos y nota de apertura en la misma
transacción; solo después actualiza Session y publica. Un rechazo pausa la
mesa conservando comprobante/enemigos originales; resume/restart recupera la
tool aplicada y reintenta iniciativa sin otro spawn. Tres casos Postgres/26
focalizados verdes; gate2444/3 limpio y VM19436/restart/reload375/1440 px
verificados sin otra iniciativa ni spawn.
D162 reserva `World.pending_turn` (combatant/kind) antes de evaluar efectos
como aura/salvación repetida. Codec valida esa reserva y Game la reintenta
antes de cualquier beat tras resume/restart. Candidato/todos los grupos/
retirada de reserva SQL juntos, Session/PubSub después; rechazo pausa sin
aplicar efectos parciales. El nombre concreto bajo DM y las reacciones con
su propietario sobreviven a la reapertura. Seis regresiones/82 focalizados,
gate2455/3, VM19439 interrumpida/reiniciada y reload375/1440 px/teclado verificados.
D163 confirma el cierre posterior: World/intenciones/notas de fin y limpieza
en una transacción antes de Session/PubSub. Rechazo pausa con estado/comprobante
previos; Game liquida una victoria guardada antes de esperar/consumir acciones,
salvo actor pendiente, cuyos resultados recupera primero. Siete regresiones/
52 focalizados, gate2462/3 trazado y VM19440/19441/reload375/1440 px lo verifican.
Una incidencia de limpieza de tests sigue abierta (ver estrategia/progress).
Narraciones, relevo posterior y RNG conservan revisión propia.

D164 evita volver a solicitar una respuesta final ya publicada al recuperar
el comprobante del actor. Events marca texto completo sin tools, salvo corte/
filtro; Beats lo busca por partida/actor/turno y retoma Settlement sin otra
petición ni publicación. Conserva las declaraciones intermedias y el registro
de escena pendiente. Legacy/parcial/vacío no prueba finalización. Siete casos
nuevos/49 focalizados, gate2469/3 limpio y VM19442/corte después de publicar,
segunda reapertura/reload375/1440 px lo verifican. Actores sin comprobante,
intentos incompletos, relevo posterior y RNG siguen con revisión propia.

### 15.3 Anti-loop de PCs — `with_pc_anti_loop` (§bug #3)
Compara las últimas 2 narraciones del bot (similitud de **Jaccard** > 0.75 sobre
palabras normalizadas, sin stopwords). En casi-duplicado, inyecta un nudge contundente
que fuerza una acción DISTINTA y concreta.

### 15.4 Anti-puppet del DM — recorte + `with_dm_no_puppet_nudge` (§bug #4, D29)
La apertura real de seis PCs amplía el recorte con predicados directos como
`alza`/`afina` y atribución `comenta` (D119). Citas implícitas sucesivas o aún
incompletas mantienen el hablante PC retirado hasta una voz PNJ explícita o
cláusula de mundo. El mismo corte se usa en streaming, Events e historial,
con controles para preservar estados pasivos y la voz propia del PC.
Si una cláusula del DM **empieza** por `<PC> <verbo de acción>`, `Text.scrub`
(con `pc_names`) la tira antes de persistir. Estados pasivos (`Lyra está
herida`) y menciones que no son sujeto se conservan. El detector suelto
sigue cosiendo un recordatorio de regla 14 al siguiente beat si queda una
fuga mid-cláusula.

Desde D123, la narración de un PC aplica el recorte a los demás PCs, nunca
al actor real. Relativas del caso real (`Miro hacia Lyra, que sigue hojeando
sus pergaminos.`) se retiran localmente conservando referencia/preguntas;
streaming, persistencia y el siguiente agente comparten ese texto limpio.
Predicados proactivos deben pertenecer al sujeto inmediato (aposición/`ya`
opcionales): `Lyra está herida mientras Sena abre la puerta` permanece.
D127 deriva nombres cortos solo si son únicos entre los personajes registrados
(`pc_names` + `character_names` de World). Nombres completos prevalecen en
atribuciones y no se borran al limpiar el nombre propio del actor. El caso real
`cuando Sira deja caer…` y subordinadas con `mientras` se recortan localmente,
sin absorber la siguiente cláusula con coma/puntuación. Streaming de mesa,
Events y detector comparten las formas. Desde D131 Events refresca el roster
vigente, también con personajes creados por tool durante el beat. Homónimos
cortos ambiguos, PNJs aún no registrados y pronombres sin sujeto identificado
no se resuelven. La lista/estructuras son curadas, con los límites D29.

D141 reconoce clíticos antes del predicado inmediato: «Iria las recoge…,
asintiendo» no escapa por interponer «las». Un pronombre indirecto/reflexivo
y uno de objeto como máximo, compartidos con relativas y subordinadas.
Tras una acción PC retirada, separa «, y el calor…» fuera de citas y conserva
ese entorno; la lista de sujetos ambientales es acotada. «Y las guarda» sigue
siendo objeto de la acción retirada, y una cita no vuelve a introducir su voz.
`set_scene` rechaza la propuesta completa antes de mutar World/log/cola;
streaming/Events/historial conservan el corte local y voz propia/PNJs.

D142 conserva al destinatario en «—digo a la posadera—.»: el detector de
rol/cita requiere sujeto/etiqueta en inicio, puntuación o coordinación, no
una mención tras preposición. La relativa «la posadera, que responde…» se
corta desde «que responde», conservando la referencia propia. Las voces
PNJ reales siguen retiradas en un PC y permitidas al DM. Streaming parcial,
persistencia/historial y preview/reload usan este límite gramatical acotado.

Desde D128, el brief de DM/PC incluye los seis pools de clase desbloqueados
(remaining/capacidad), usando `ClassResources.pools` como la ficha. Dados de
golpe se leen del ledger, cuatro flags modelados indican disponible/gastado,
y una forma animal activa indica que no puede conjurar. La lectura es pura,
conservadora para nil y no repone nada. El siguiente beat recibe el World
actual tras el pago; el brief compacto de TurnMaster conserva su alcance.

### 15.5 Limbo de exploración — `exploration_limbo?` (§bug #5)
Detecta un backlog de ≥6 eventos de **narración pura** sin progreso mecánico (sin
`:dice`, `:action`, ni `:system` de spawn/scene) en `:exploration`. Dispara
`dm_advance_instruction` (spawn / PNJ / set_scene / evento / resolver lo pedido).
Es la generalización de `post_combat_limbo?` a la exploración.

### 15.6 Anti-repetición del DM — `with_dm_anti_repeat`
Cuando el DM reutiliza casi la misma línea ("se desvanece en una nube de humo
sulfúrico" x N) lee como un disco rayado. Compara las últimas 2 narraciones del
DM (Jaccard ≥ 0.7) y, en casi-duplicado, cose un nudge que le exige un enfoque y
vocabulario NUEVOS (detalle sensorial, ángulo, ritmo). Espejo del anti-loop de
PCs, pero para variedad narrativa.

### 15.7 Combate fantasma v2 — `with_dm_unspawned_hostile_nudge`
Si el DM narra `"(aparece|se materializa|irrumpe|surge) un hostil"` en exploración
**sin** enemigos vivos en el world (no llamó `spawn_monster`), el motor no puede
forzar combate (`maybe_force_combat` no ve enemigo). El nudge le exige
`spawn_monster` este turno — que luego dispara el `maybe_force_combat` de §15.2.
Si no quiere combate, que no narre apariciones hostiles.

### 15.8 Hechos durables — `world.facts` + `establish_fact`
El DM aterrizaba ganchos solo en narración (truncable en el history), y a los
pocos turnos los abandonaba o reintroducía. Ahora el world lleva `facts: [String]`
persistente (codec round-trip), expuesto en el `world_brief` como
**"Hechos establecidos"**. El DM los registra con la tool `establish_fact("<frase>")`
(regla #11 del prompt) cuando introduce algo concreto y duradero (PNJ, puerta
secreta, encargo, revelación). Idempotente. Todos los agentes leen los hechos
cada turno → coherencia canónica.

### 15.9 Circuit breaker — `fallback_streak` + pausa automática
Si una racha de beats cae al fallback blando (provider caído, rate-limit
persistente, escena atascada que todo agente falla), el loop **PAUSA** la
partida en vez de seguir avanzando turnos. Sin esto, una salida de OpenRouter
producía un flujo infinito de *"X titubea y el turno pasa de largo"* que
inundaba la línea temporal y saturaba el server (síntoma: 503 al paginar).
`fallback_streak` se incrementa en cada fallback y se resetea con cualquier
beat exitoso; al llegar a `@max_fallback_streak` (4 = 1 ronda de 4
participantes) se persiste `:paused`, se emite una nota `:system` explicativa,
y no se manda `tick`. El usuario reanuda manualmente cuando la causa subyacente
se ha despejado.

### 15.10 Coherencia curación/mundo — regla #10 del DM
El DM narraba *"os han cosido a los tres"* sin llamar `heal` → los world
characters seguían a 0 HP y el motor les seguía pidiendo salvaciones de muerte
en una escena narrativamente ya resuelta. La regla #10 ahora obliga a llamar
`heal("nombre", "XdY+mod")` cada vez que algo restaura pg (PNJ cura, poción,
descanso, vendas); narrarlo sin `heal` deja al personaje atascado y rompe la
coherencia. Refuerzo de prompt (no fuerza estructural, pero alinea mundo y
narración en la causa más común de atasco post-combate).

### 15.11 Guardián de idioma — `with_dm_spanish_nudge`
DeepSeek-v4-flash a veces se va al **inglés** durante un párrafo pese al
"responde en castellano" del system prompt. `looks_english?/1` cuenta stopwords
inequívocamente inglesas (`the/and/was/were/this/that/…`) en la última
narración del DM; si pasa de 5, el siguiente beat recibe un nudge fuerte que le
exige castellano exclusivo (salvo nombres propios de la biblia). Conservador:
la lista evita falsos amigos con palabras castellanas.

---

## 16. Modelos — `lib/dragonex/models.ex`
- El grafo publicado usa exAgent 2.2.2/ReqLLM 1.29.0; desarrollo sigue
  resolviendo el checkout hermano. Ambos locks incluyen Bandit 1.13.1 (D246).
- DM: `deepseek/deepseek-v4-flash` (env `DRAGONEX_MODEL`).
- Sumarizador: `google/gemini-3.1-flash-lite` (env `DRAGONEX_SUMMARIZER_MODEL`).
- `DRAGONEX_DM_MAX_TOKENS=1500`. PCs: 2048.
- OpenRouter cachea el prefijo del system; `cached_tokens/1` extrae el ahorro de
  `usage.details`.
- Umbral de compacción 250k (efectivamente desactivado; modelos de 1M).

---

## 17. UI — `DragonexWeb.GameLive.Show`

Las comprobaciones de modelos y catálogos del modal de Ajustes están ligadas
a una referencia por solicitud (D249). Cerrar, reabrir o cambiar selección
invalida respuestas anteriores, incluso si se vuelve al mismo proveedor.
El catálogo que llega después de escribir un modelo conserva ese texto.
En Cuenta, Quitar cancela el guardado pendiente de esa clave; cerrar la
página tampoco permite guardarla después. Solo el callback vigente escribe,
y su mensaje transporta ciphertext. Esto no revoca claves ya cargadas por
otras pestañas o agentes vivos ni aborta el HTTP iniciado.

- Feed **agrupado por turnos** (`chat_blocks/2`): cada turno es un bloque con
  header (`Turno de X · ⚔ combate`) y eventos inline.
- Auto-play: icono 🤖 (lila) cuando el viewer es auto-play; `· TÚ` (verde) si es
  manual. Indicador "X está actuando…" dinámico.
- Input del humano oculto tras 💭 con hover (nunca inline).
- **Paginación** del log: botón ↑ carga turnos anteriores (`events_before/3`).
- **Streaming bubble** `@live_text` con cursor parpadeante, flush al persistir.
- **Modal de dados**: una apertura por grupo, con razón + dados + total + contra
  + resultado.

Al responder una conversación, el PC recibe al final criterio de clase/
trasfondo y formato de diálogo directo en1–2 frases cortas, sin narrador o
gestos; proponer o explicar cómo investigar depende de lo que le preguntan.
Si la pregunta tiene el recibo de acción existente, Game proyecta desde los400
eventos las intervenciones públicas completas de destinatarios anteriores
tras la misma acción: fuente/texto/seq exactos, Text.scrub y1800 caracteres
por voz sin cortar el final. Quitar a alguien de pending no inventa su habla.
Esta voz sigue siendo diálogo, no facts ni instrucciones. Sin ancla o voz
demostrables no hay proyección adicional. Contexto sobrevive restart/compacción
sin nuevas escrituras World/Codec (D209). Consulta911→921 conserva el estado y
el retorno humano y no añade gestos, pero76/61 palabras y matices de fuentes
siguen abiertos; no es una garantía semántica de brevedad.

Brief conserva los testimonios por orden de registro y marca la última
entrada retenida de cada fuente con varias versiones (D210). Igual reloj no
implica igual posición; el orden no fecha el suceso relatado. Agrupa solo el
nombre completo con NFC/espacios/case, sin unir apodos o roles distintos;
mantiene cada cadena literal y no sustituye versiones por interpretación.
Guía DM/PC pide conservar una aclaración posterior sobre fuente o límite al
usar el detalle, sin tratar la última entrada como verdad. Repetir un registro
retenido no lo mueve ni renueva reloj; legacy sigue sin fecha. Archivo/
compacción/restart entre compañeros conservan esta proyección sin World/Codec
nuevos. Consulta921→934/15,905s mantiene World/15 facts/recursos, aún86/66
palabras. Entonces dos interrogativas no entraban en la ruta literal PC de
una pregunta y reaparecían reformulación humana/cierre DM. D211 cubre ese
flujo: hasta tres preguntas informativas consecutivas a los mismos PCs,
verificando cada una y toda la espera pasiva. Texto intermedio/acciones/
cuarto interrogante no se truncan; conservan resolución. Coma/punto y coma/
dos puntos en cualquier pregunta conserva DM aunque el habla sea literal.
El cierre sigue revalidando huella World, eventos, intenciones y nuevos
interrogantes/dados; el cap800 no cambia. Consulta idéntica934→944/4,061s
mantiene World/15 facts/recursos y publica solo la voz exacta de Mara y las
respuestas PC, sin turno/narración DM. Restart y magia mixta mantienen
comprobante/voz y gasto único. La guía no es un verificador semántico de
contradicciones; brevedad/fuentes siguen abiertas.

El creador conserva instrucciones DM largas en text (D212); título mantiene
255 puntos de código y se valida antes de insertar/avanzar. Un error anuncia
el límite y permite corregir/volver con texto/héroe/compañeros conservados,
también tras cambio final forjado. Estilo completo llega al DM tras restart.
Migración test/dev preserva datos previos; producción pendiente de deploy.
La nueva mesa19443 abre pausada6 con estilo476/3D. Primer diálogo a Ada6→13
no resuelve la pregunta: nombre propio fuera de la ruta literal y fallback
tras tres reintentos inválidos; World/recursos/reloj iguales. Revisar antes
de viajar. Las mesas19425/944 y19439/9 siguen intactas; beta activa.

D213 reconoce nombres propios únicos con roster PC y excluye identidades/
primer nombre PC; «¿Sabes si…?» entra en habla informativa. Cita/espera/
consecuencias conservan las guardas anteriores y no se abre reconocimiento
universal. 13→21 publica habla exacta, todavía con fallback DM. Un diagnóstico
stock fresco muestra argumentos planos; el sibling v2 explica una vez el
envelope en Context backend, sin cambiar caller/history/schema/codec/validación.
Consulta 21→28 responde Ada, guarda testimonio atribuido con dudas y devuelve
Thane sin retries inválidos; solo facts cambia. Reloj/recursos/mesas protegidas
exactos. Mesa 28 pausada; seguir campaña. La guía no garantiza fidelidad o SLA.

D214 añade en la proyección de petición un recordatorio de continuación si
ya hay prosa pública intermedia no vacía del mismo game/actor/turn_id. Pide
solo consecuencias nuevas tras tools; no borra eventos ni cambia history/recibos.
Plan y viaje llevan 19443 a 46, reloj 300 s; apertura llega a 68 en combate.
Esqueleto existe a 4/13 PG tras ataque Vex de 9, pero falta del orden.
D215 revalida nombres/DEX de presentes conscientes al aplicar una iniciativa
preparada: un cambio obliga a volver a pedirla. No reescribe ese orden guardado.
La mesa queda pausada para recuperar/reprobar antes de seguir; fidelidad,
handoff/retries y aventura completa continúan abiertos.

El creador y la mesa ofrecen3D solo si el paquete instalado declara caras
autoritativas3D (D208). Sin esa capacidad,3D aparece «No disponible» y la
mesa muestra «Dados2D». Snapshot, montaje del hook y destino del evento usan
el mismo modo efectivo: una preferencia anterior3D puede presentarse en2D
sin reescribirla. Con3D disponible, cada vista puede alternar el modo salvo
durante la animación; actualizaciones conservan su elección. Un fallo de
WebGL posterior sigue utilizando fallback2D del hook (D207), sin cambiar la
preferencia persistida. La presentación nunca genera ni sustituye dados del
motor. Chrome local/Hex1440/375 verifica total19/DC15 y teclado; la partida
real901 permanece pausada e íntegra.

La LiveView **nunca** toca el Repo ni polls: se suscribe a `Dragonex.PubSub` al
tópico `dragonex:game:<id>` y re-fetch del snapshot al recibir
`{:game_updated, game_id}`.

---

## 18. Bugs conocidos y mejoras pendientes  📌

> **Sección viva.** Apuntamos aquí lo que encontremos para atacarlo en orden.

### ✅ Resueltos
- [x] **"LyraLyra" (auto-referencia duplicada)** — `Text.scrub/2` con
      `strip_leading_self_name` quita el nombre del actor al inicio (cajas +
      history). Render con `leading_self?/2` cubre la burbuja de streaming (texto
      sin scrub). Tests en `text_test.exs`.
- [x] **Streaming duplicado** (`texto → tool → texto`) — `maybe_flush_live_text/3`
      + `segment_already_carded?` limpia la burbuja cuando coincide con la última
      narración persistida del actor.
- [x] **Bugs 1-5 del handoff original** — retry con backoff transitorio,
      combate fantasma (`maybe_force_combat`), anti-loop PCs, anti-puppet DM,
      limbo de exploración. Tests en `game_retry_test`, `ghost_combat_test`,
      `pc_anti_loop_test`, `dm_puppet_pc_test`, `exploration_limbo_test`.
- [x] **`coalesce_assistant_runs` mezclaba actores** (`history.ex`) — ahora
      solo colapsa runs del mismo actor (`narration_actor/1`). Causa raíz del
      "quién dijo qué" perdido.
- [x] **`split_responses` invertía los grupos** (`history.ex`) — el más grave:
      truncaba las recientes y dejaba las viejas verbatim al final (orden
      temporal corrompido). Predicado corregido a `>= keep`.
- [x] **`@recent_narrations_kept = 5`** → subido a **12** para 4 agentes auto.
- [x] **Stats revelados** — `Text.scrub` ahora también limpia `CA 15`, `7 PG`
      bare, `X de los Y puntos de vida`, `clase de armadura N` (no solo X/Y).
      Conservador con números lore ("15 monedas"). Tests en `text_test.exs`.
- [x] **Frases calcadas del DM** — `with_dm_anti_repeat` compara las últimas 2
      narraciones (Jaccard ≥ 0.7) y, en casi-duplicado, cose un nudge de variedad.
      Tests en `dm_anti_repeat_test.exs`.
- [x] **Combate fantasma v2** — `with_dm_unspawned_hostile_nudge`: si el DM
      narra "(aparece|se materializa|irrumpe) un hostil" en exploración sin
      enemigos vivos, le fuerza `spawn_monster` (que dispara `maybe_force_combat`).
- [x] **DM narra PCs (ampliado)** — `@puppet_action_verbs` ampliada con verbos
      de movimiento/diálogo/observación (camina, abre, dice, examina…). El
      nudge de regla 14 dispara en más casos.
- [x] **DM apila ganchos y los abandona** — `world.facts` + tool
      `establish_fact` + bloque "Hechos establecidos" en el `world_brief`. Los
      hechos durables sobreviven a la truncación del history y los leen todos
      los agentes cada turno. Tests en `world_facts_test.exs`.
- [x] **Auto-play de varios PCs = caos** — nudge de coordinación en
      `PCAgent.instruction` (exploración): reaccionar a lo que los compañeros
      propusieron en vez de abrir hilos paralelos. (La coherencia base ya viene
      del history bien reconstruido tras el fix de `history.ex`.)
- [x] **`"X titubea"` espurio** — `handle_non_max_token_error` ahora omite el
      fallback de narración si la `Events` capability ya persistió una para ese
      `turn_id` (caso texto-mid-beat + fallo final: no pinta "titubea" encima).
- [x] **Bucle infinito de "titubea"** — `fallback_streak` + circuit breaker:
      tras 4 fallbacks consecutivos la partida se **pausa** (nota `:system`
      explicativa, no se manda `tick`). Evita el flujo infinito durante una
      caída persistente del proveedor y, de paso, el 503 al paginar (síntoma
      de server saturado por el bucle). Test en `game_retry_test`.
- [x] **DM no aplicaba curación al narrarla** — regla #10 reforzada: narrar
      curación sin `heal` deja personajes atascados a 0 pg (salvaciones de
      muerte eternas en una escena ya resuelta). Ahora exige `heal`.
- [x] **Paginación sin límite en el LiveView** — `@max_chat_blocks` (400) tope
      de bloques renderizados; el tail más viejo se suelta al cargar más,
      previniendo OOM tras muchos "load more".
- [x] **Nombre pegado / duplicado** (`Thanedeja`, `Thane**Thane**`) — raíz:
      el modelo emite el nombre en **markdown bold** (`**Thane**deja`); el scrub
      ahora striptea el cierre `**` también, y el render añade un espacio
      textual entre el chip `who` y el texto (el `margin` CSS no se preserva al
      copiar). `leading_self?` del bubble actualizado.
- [x] **Inglés mezclado** — `with_dm_spanish_nudge` detecta narración inglesa
      (stopwords) y fuerza castellano el siguiente beat.
- [x] **Frases meta + tool-calls en prosa** — scrub ampliado: quita
      `establish_fact(…)`, `spawn_monster(…)`, `[Establecer hecho: …]` y
      rupturas de cuarta pared ("la escena se resetea", "lo materializo en el
      mundo", "como DM…").
- [x] **Byte UTF-8 inválido que wedged la partida (crítico)** — el modelo emitía
      a veces un byte líder suelto (`0xC2` sin continuación). Jason no podía
      serializarlo → `{:model_request_failed, %Jason.EncodeError{…}}` → todos
      los beats fallaban → bucle de "titubea" → pausa, y al reanudar seguía
      fallando (el byte estaba en el history persistido). Fix:
      `Text.sanitize_utf8/1` se aplica al final del scrub (lo persistido queda
      limpio) Y en `History` (`msg_request`/`msg_response`) al reconstruir el
      history (limpia datos ya corruptos en DB). Además, el `note` del error en
      `handle_non_max_token_error` se trunca+sanitiza para no persistir el
      binario crudo del `Jason.EncodeError`.
      D169 encuentra otra procedencia: la compresión de una pregunta válida
      después de construir los mensajes. El patrón sin Unicode parte ¿ por
      el byte0xC2 compartido con ¡. Ahora cuenta caracteres y solo termina en
      .!?, conserva doce narraciones recientes y JSON válido. Tres regresiones,
      gate2496/3 y19425/proveedor/restart verifican esa ruta. No reescribe DB
      ni resuelve la omisión independiente del reloj de una espera declarada.
- [x] **GenServer zombie tras borrar un game** — si se borraba la fila `games`
      mientras el proceso seguía vivo, cada tick crasheaba con violación de
      foreign key y el supervisor lo reiniciaba en bucle. Ahora `handle_info(@tick)`
      hace `rescue Ecto.ConstraintError` y para el proceso limpio (`{:stop, :normal}`).

### 🟡 Mejoras futuras (validar en la próxima partida)
- [x] **Coordinación real entre PCs auto (mesa)**: el system prompt #5 y la
      instruction de exploración decían «elige y ejecuta / camina hacia la
      salida», contradiciendo la regla 13 (proponer y esperar). En 258 Lyra
      se marchaba sola («desaparece en el arco», «sin esperar respuesta»).
      Alineado a compañero de mesa; el antibucle ya no empuja a irse.
- [x] **Scrub estructural de DM-narra-PC** (D29): cláusulas sujeto-inicial
      `<PC> <verbo>` se tiran al persistir; pasivo y mención no-sujeto se
      quedan. Time-skip y voz de PNJ en beat de PC también se recortan.
      Opener de exploración = `pass_to_dm` sin «relevo».
- [x] **Voz de PNJ en frase larga** (D30): se recorta desde el primer
      atribuidor; el split no parte comillas. Headers mid-prosa fuera.
- [x] **Pregunta del DM al humano** (D30): no se cede al otro PC.

### 🟡 Validado en vivo (partida 913) y deudas que quedan
- [x] Voz de PNJ en beat de PC: Thane pregunta a Borin; el persistido de
      Thane no trae el diálogo de Borin; el DM responde después.
- [x] Dados: `🎲 Lyra · chequeo/ataque` (punto medio). ThaneSe en el AT
      es chip+«Se…» (el persistido ya es «Se levanta»).
- [x] Combate + D18 iniciativa + `cut_in` («Thane interrumpe.»).
- [x] **«Ábrelo tú, si quieres.»** retiene el floor (D30: `tú` / `si quieres`).
- [x] **`gritando:`** y `el enano … —` se cortan en beat de PC.
- [x] **ThaneSe visual**: chip `Thane ·` (no se pega a Se).
- [x] **`Thane's hand`** se tira al persistir.
- [x] **PC IA no cierra solo** (D32): en exploración con humano, se tiran
      cláusulas de ejecución (`despliega el pergamino`, `coge el…`).
- [x] **Biblia → facts** (D32): Borin + gancho oficial + enemigos previstos.

### ⚪ Menores
- [ ] _(sin pendientes menores abiertos)_

---

## Subir un héroe con partidas abiertas (D124–D125)

La pantalla de subida confirma el nivel montado y Accounts relee/bloquea el
héroe antes de aplicar elecciones. Una segunda pestaña antigua vuelve a la
ficha con aviso de revisión, visible/cerrable en el layout. No aplica otro
nivel ni las elecciones a un nivel diferente. XP y política milestone no
cambian; no hay subida automática por alcanzar el umbral.

D140 valida la elección ASI antes de ajustar el borrador: seis características,
pasos +1/−1 y nivel con ASI. Un parámetro desconocido/incompleto conserva los
puntos elegidos y la conexión, y muestra error local con role=alert junto a
los controles; un clic válido lo elimina. El presupuesto y cap 20 se mantienen.
Elegir no escribe biblioteca ni World; la confirmación sigue usando el nivel
esperado D125. Recargar sin confirmar inicia un borrador nuevo.

Las partidas iniciadas reciben la ficha por su Game canónico, aunque haya
que rehidratarlo. Solo la sala configurándose admite escritura directa bajo
bloqueo/relectura frente al inicio. Game rechaza una ficha de menor nivel
antes de tocar World o baseline. Subir no cura ni descansa: la capacidad
nueva conserva gasto de casillas, pacto y excedentes pagados; sync de igual
nivel no reembolsa recursos. D126 aplica la misma ampliación de capacidad
al pool vivo de ki/Font/Shape/LoH y usos por CHA: recién desbloqueado puede
usarse sin descanso. La ficha propia muestra disponible/máximo desde World;
flags/pausa/turno/escena/reloj/rest_state se conservan.
Un timeout de sync se registra y no tiene reintento automático todavía.

D129 aplica progresión/sync a la ficha original dentro de Forma salvaje,
conservando PG y estadísticas físicas de la bestia. ASI físico y vitalidad
nativa quedan guardados; atributos mentales/nivel/hechizos se actualizan en
el personaje. Al revertir se recupera la forma original progresada. La
actualización del snapshot de la misma bestia no reinicia su deadline;
reapertura, caducidad y daño sobrante mantienen ese criterio.

D130 identifica la bestia en las fichas antes de su barra de PG y muestra
los PG originales guardados en la propia. El resumen de exploración y
detalle móvil avisan que hay que volver a la forma original para conjurar;
snapshot incompleto indica «Sin registrar». Revertir retira esos datos.
Sylvi real, L2 → lobo → L3 → reversión, conserva ambos estados: bestia 11/11,
original 10/24 PG, uso 1/2, casillas 4/2, reloj 0 y ledger vacío. Pausa/reload
y fichas 375/1440 px verificadas; deadline 3600 no se renueva.

D131 relee nombres/PCs del World comprometido al persistir cada respuesta.
Si una tool registró personajes en el mismo beat, refresca deps y mesa antes
de la siguiente petición al modelo: prefijos/homónimos no borran su voz del
preview ni del historial. Las propuestas aún no aplicadas no registran voces;
sin handle utilizable se conserva el contexto inicial.

D135 añade agencia colectiva: sujetos del grupo y movimiento plural explícito
se retiran si actúan por otro PC; conserva PNJs, entorno, pasivos e invitaciones,
también tras una cita cerrada. El mismo filtro rige preview/Events/historial.
set_scene valida el roster/actor vigente y rechaza toda propuesta ajena/
colectiva/vacía antes de tocar World/log/cola, usando los cortes acotados y su
normalización, no el detector amplio de nudges. Preguntas PNJ y movimiento
local propio siguen válidos. Default/avance/postcombate respetan estilo y no
ordenan trasladar el grupo. Alusiones implícitas/consenso semántico siguen D29.

D137 corta también «al acercaros…» y cinco familias temporales plurales
acotadas: retira disparador/destino local conservando descripción. Trabaja
fuera de citas; preguntas/planes e invitaciones PNJ, incluso incompletas,
permanecen. Una cita cerrada no oculta la acción externa. Historial/preview
comparten el corte y set_scene rechaza la propuesta completa antes de World.
No modela todas las formas de prosa, viaje acordado ni consenso/posición.

D139 conserva observaciones figurativas reales: «dice la hora/la verdad»
requiere identidad/rol/atribución real antes de considerarse voz ajena;
«la luz se quiebra» no ejecuta el sello. El cleanup mantiene «tiene:» mientras
sigue retirando números. Tres fixtures proceden de raw completos con
finish_reason=stop; streaming/Events/historial no los truncan. Los cortes
continúan acotados; no reescribe textos anteriores ni resuelve toda semántica.

### Recuperación y feedback del motor (D216–D221)

D217 evita un segundo turno ordinario seguido DM en exploración cuando una
persona manual está disponible: pass_to_dm/give_turn_to(dm) ceden según
marcadores reales. Preguntas/intents/conversaciones y mini/reacción/re-eval
mantienen prioridad; elegir otro compañero aún no servido conserva su camino.
No valida semánticamente toda prosa ni tools del primer beat DM.

D218 acompaña solo el próximo intento tras rechazo req_llm de argumentos con
una guía estática de schema y conservación de recibos, fuera del historial
canónico. No transforma args ni incorpora body privado. D219 diferencia
ficha inexistente/ausencia/controlador en errores de control: no recomienda
dm como atacante, conserva permisos y exige registrar criaturas con tools.

D220 añade desde la segunda petición DM/PC de ese beat una foto temporal
del World vigente en Session, con control/PG/stock/recursos y memoria actuales.
Prevalece sobre el WORLD inicial y conserva los recibos. World.combat_over?
informa si no quedan enemigos vivos/presentes, sin adelantar el cierre del
motor. No modifica historia canónica, prosa pública, reglas ni World; una
foto sustituye a la anterior solo en la proyección de petición.

D221 mantiene las tools del resolutor manual general pero conserva la voz
escrita por la persona. Beats lee la acción pública del mismo game/actor/turn_id,
también en retries/recovery; Events retira solo Text actual, sin cambiar tool
parts/IDs/metadatos, y publica la fuente literal al completar. Su preview no
se transmite. kind:human_declaration se proyecta en History como intención,
sin abreviarla ni declarar confirmado el resultado. Entrada humana conserva
UTF-8/palabras; texto del modelo sigue con Text.scrub y HEEX escapa la fuente.
AI/autoplay/DM y bypass de preguntas/esperas reconocidas conservan su ruta.
Un checkpoint humano interrumpido termina la declaración original antes de
consumir otra intención, sin repetir resultados. Fallo definitivo conserva
acción/dados y avisa como sistema, sin gesto inventado ni complete:true.
No verifica toda interpretación de tools ni la prosa posterior del DM.

Antes de resume o del siguiente beat idle, Game comprueba si faltan hostiles
presentes con PG positivos. World los añade al final por nombre, siguiendo
join_initiative para refuerzos. Conserva slots, owner, turnos gastados y recursos;
no reordena ni inventa una tirada original. World y nota pública se guardan en
una transacción antes de cambiar Session. El fallo deja pausa y reanudar permite
retry idempotente. Busy, actor_checkpoint y pending_turn posponen la reparación
hasta que su intento se liquide. D215 sigue rechazando iniciativas nuevas
preparadas con roster/DEX antiguos; D216 recupera estado ya guardado.

## Cómo correr una partida de prueba

`bin/dev dragonex.playtest` también admite mesas sin interfaz y consume
créditos del proveedor. Tras la última declaración sigue atendiendo pausas
con el mismo presupuesto de reanudación (D251): `turns_reached` requiere
volver al humano; una pausa sin margen devuelve `paused`. Las omisiones y
fallos siguen visibles en las métricas, aunque el bucle logre continuar.

Las métricas reconocen también los relevos de emergencia (D252), cuya nota
incluye el controlador realmente elegido. El tiempo hasta el retorno humano
no cruza otra declaración de ese jugador ni un fallback antiguo sin destino:
se descarta la muestra ambigua para no sumar tiempo de reflexión. Esos eventos
sí cierran la duración del turno IA. Las cifras anteriores deben recalcularse
para comparar mesas con relevos de emergencia.

1. `docker compose -f compose.dev.yml up -d` (levanta Postgres + app; http://localhost:4035).
2. Navegador → http://localhost:4035/games/new → escenario "Arena de Pruebas".
3. Toggle auto-play en un PC para observar sin input humano.
4. Pausar/reanudar cuando haga falta. Logs: `docker logs -f dragonex-app`.

## Tests
- `MIX_ENV=test bin/dev test` → referencia vigente en `docs/progress.md`;
  gates local/Hex en secuencia cuando comparten la misma DB.
- D181: History conserva el outcome confirmado: crítico diferente de
  acierto, fallo normal de muerte explícito y doble fallo natural1 distinto.
  No deduce un crítico desde el dado ni recalcula reglas. Los eventos de dados
  siguen como mensajes compartidos completos aunque se comprima prosa
  antigua. Tres casos Actions/RollLog/JSON y un Game verifican la entrega
  efectiva a dos PCs, con prefijos propios, pausa y reinicio sin tirar otra
  vez. El Game toma400 eventos recientes: no es memoria ilimitada de campaña.
- D174: ConnCase administra los montajes live/live_isolated/follow_redirect.
  Un hijo de ExUnit solicita el cierre síncrono de cada LiveView antes de
  terminar su canal: su callback/consulta SQL devuelve la conexión compartida
  antes de salir. El snapshot en cola del Game y otra vista de la misma
  partida siguen funcionando. Dos pruebas usan advisory lock de PostgreSQL
  en la base test, sin LLM; no cambia el bucle de producción. Los contadores
  TMSpy se supervisan antes de su Game y sobreviven a sus últimas peticiones.
- Tests aislados por bug: `game_retry_test` (incluye circuit breaker),
  `ghost_combat_test`, `pc_anti_loop_test`, `dm_puppet_pc_test`,
  `exploration_limbo_test`, `text_test` (scrub/2 + bold + stats + leak + meta +
  tool-calls), `history_test`, `dm_anti_repeat_test` (incluye anti-inglés),
  `world_facts_test`.
- Tests por mecánica del lote D35–D77: `rage_test`, `rage_uses_test`,
  `flurry_of_blows_test`, `font_of_magic_test`, `metamagic_test`,
  `wild_shape_test`, `uncanny_dodge_test`, `indomitable_savage_test`,
  `breath_gnome_test`, `expertise_test`, `upcast_test`, `hunters_mark_test`,
  `evasion_test` (entre otros; ver `docs/tecnico/10-auditoria-motor.md`).
