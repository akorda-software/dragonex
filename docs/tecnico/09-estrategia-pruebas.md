# Estrategia de pruebas

> **Técnico.** Cómo se verifica Dragonex: capas, principios, cobertura actual
> y el **protocolo de verificación** que todo agente debe pasar antes de
> declarar "hecho". Regla fundacional: **verificabilidad antes que
> afirmaciones** — nada está "funcionando" sin un test verde que lo pruebe.

Últimos gates completos, **D246–D251**, 2026-10-25: **3152 passed / 3 excluded**
en ambos grafos, seed0; local134,7 s y Hex133,7 s, secuenciales. Código propio
dev/test/prod compila con `--warnings-as-errors`, formato limpio y ambos
`mix hex.audit` sin avisos. Compilar dependencias frías con Elixir1.20 emite
avisos de terceros (toml, websockex, gettext y plug), sin avisos de Dragonex;
no se silencian ni parchean dependencias para ocultarlos.

Referencia histórica, **D222–D226**:
**2871 passed, 3 excluded** (`MIX_ENV=test bin/dev test --seed 0`,
2026-10-04,108,5 s) yHex **2861/3** en65,1 s. Ambos seed0/max_cases48,
secuenciales sobre dragonex_combat_test, sin warnings/errores/desconexiones.
Offline, sin peticiones reales al LLM (TestModel y HTTP sintético).
Compiles propios forzados dev133/test140/prod Hex133 con warnings-as-errors limpios;
formato limpio.
Build frío de dependencias
imprime avisos de terceros documentados en D203, sin silenciarlos ni parchearlos.

Los gates completos local/Hex se ejecutan **en secuencia** cuando comparten
dragonex_test. `async:false` serializa casos dentro de una VM, no entre VMs.
GameToolRollCommitTest y GameEngineRollCommitTest crean constraints temporales
en game_events para probar rollback real: dos procesos externos pueden solicitar
AccessExclusiveLock simultáneamente y producir40P01. D209 confirma ambas
sentencias en el log de Postgres; no se cambia esa cobertura ni se añade retry
para esconder la colisión. Para paralelizar grafos, usar DB_TEST_NAME distintos
y crear/migrar ambas bases. MIX_BUILD_PATH de prod/test también debe separarse
(D204/D205), incluso cuando los tests se ejecutan en secuencia.

Gate D170 ordinario48,0 s/seed944912 pasa funcionalmente y registra tres
desconexiones/dos terminaciones Game durante limpieza. La traza max_cases1
pasa en56,4 s sin esos errores. Cinco avisos deliberados del breaker simulado;
la causa Postgrex intermitente sigue abierta. Ver evidencia D170 abajo.
La repetición de trazas55,3 s registra una desconexión y una terminación Game;
ExUnit mantiene max_cases1 incluso con --max-cases48. No es un gate concurrente.
Gate D1712519/3 en47,0 s, seed944912/max_cases48, sin errores/desconexiones;
solo cinco avisos del breaker. No cierra por sí solo la incidencia histórica.
Gate D172 final2529/3 en47,6 s/seed944912/max_cases48: una desconexión owner
SQL, cero terminaciones Game y seis avisos (cinco breaker, uno TestModel agotado).
Traza serial55,2 s/max_cases1 sin esas incidencias; no demuestra causa resuelta.
Gate D1732530/3 en47,9 s/seed944912/max_cases48: una desconexión cliente SQL,
una terminación Game al consultar snapshot y cinco avisos deliberados breaker.
Ningún aviso inesperado por modelo agotado; limpieza sigue abierta.
Gate D1742532/3 en48,0 s/seed944912/max_cases48 sin desconexiones/errores;
el intermedio49,0 s/seed30343 descubre una tarea/aviso por contador TMSpy
terminado. Tras supervisarlo hasta cerrar Game,2532/3 en48,2 s/mismo seed/
max_cases48 sin desconexiones/errores ni avisos inesperados. Cinco avisos
deliberados del breaker en ambos gates finales. Causa LiveView atribuida y
corregida; los casos antiguos de owner sin atribuir siguen bajo seguimiento.
Gate D1752536/3 en47,9 s/seed30343 y48,8 s/seed944912/max_cases48, sin
errores/desconexiones ni avisos inesperados; cinco deliberados breaker.
Gate D1762546/3 en49,3 s/seed30343/max_cases48, sin errores/desconexiones ni
avisos inesperados; cinco deliberados breaker.67 focalizados en1,0 s limpios.

Gate D1772549/3 en49,6 s/seed30343/max_cases48, sin errores/desconexiones ni
avisos inesperados; cinco deliberados breaker.32 focalizados en1,7 s limpios.

Gate D1782549/3 final49,3 s/seed30343/max_cases48 sin errores/desconexiones
ni avisos inesperados; cinco breaker. El primero49,4 s descubrió un fixture
anti-repeat agotado, reproducido con oráculo exacto y corregido abajo.

## D246–D251 — Regresiones de combate, recuperación y operaciones asíncronas

La tanda del 2026-10-25 añade cobertura offline para:

- D247: fuentes simultáneas de ventaja/desventaja, Guiado solo en el primer
  ataque y furtivo; críticos de Arma espiritual con dados distintos y upcast;
  daño cero con SAB baja, sin alterar PG temporales o concentración.
- D248: reacción humana, IA y de monstruo reintentadas antes del checkpoint,
  más pausa/reanudación. Secuencias 503/length con contador de peticiones
  verifican presupuestos independientes sin reponer el margen agotado.
- D249: sondas HTTP/modelo bloqueadas por mensajes, canceladas y reemplazadas.
  El callback anterior no reinicia la mesa ni guarda una clave borrada. Una
  LiveView suspendida permite comprobar que el mailbox lleva ciphertext y no
  la clave; cerrar la página impide persistencia posterior.
- D250: borrado desde la lista y cierre de Game, supervisor, Session y agentes;
  cancelación de una petición en curso y conservación de otra mesa. Un ID
  ajeno no detiene procesos.
- D251: último turno del playtest fallido, con y sin presupuesto de reanudación.
  El bot declara una vez y la pausa no se informa como `turns_reached`.

Antes de corregir, las cuatro pruebas de reacción, dos de crítico, dos de
borrado y dos de playtest reprodujeron sus fallos. Los tests de presupuesto y
reacción filtran la narración por `turn_id`: la introducción creada con la mesa
no es una respuesta del beat. Las pruebas no certifican latencia del proveedor,
calidad narrativa o comportamiento visual en un navegador real.

D246 comprueba los dos grafos en secuencia sobre la base de tests, con
`MIX_DEPS_PATH=.hex_graph/deps MIX_BUILD_PATH=.hex_graph/_build` para Hex;
la compilación de producción usa `.hex_graph/_build_prod`. La auditoría Hex
se ejecuta para ambos locks. No se modifica el checkout de los paquetes ni
se sustituye una prueba de rollback por un retry.

## D226 — Total del arma y componentes incluidos en el feedback

AttackDamageMessageTest reproduce inicialmente8 fallos por mensajes ambiguos.
Tras aclarar Actions,4/8 fallan por esperar tuplas donde RollLog devuelve
listas; corregir únicamente la representación y quitar un default privado
sin uso produce8/8 sin warnings. Los oráculos numéricos permanecen:
13/5 sneak,9/2 furia,10/3 marca,23/4 Savage/11 sneak, dos golpes9+8,
arma7+smite5 con slot único, inspiración en ataque13/daño7 y fallo sin daño.
214 focales en0,3s incluyen los módulos previos con expectativas textuales
migradas; se conservan dados/PG/slots y pruebas de mínimo cero/mitigación.

Gates nuevos2871/3 local en108,5s y2861/3 Hex en65,1s, seed0/max_cases48,
secuenciales sobre dragonex_combat_test. Builds combat-local-build y
combat-hex-build separados, sin warnings/errores/desconexiones. La diferencia
incluye8 casos D226 y1 caso externo de DC/CA en tarjeta modal; no atribuir el
último a esta entrega. Compiles forzados dev133/test140/prod Hex133 con
warnings-as-errors limpios, formato/diff limpios. Recibo
attack-damage-message-verification.json comprueba641 fuentes estables durante
gates y mesas19443–19449/originales/héroe/47 estilos exactos. Esos gates
preceden el trabajo concurrente D227; no garantizan semántica o beta.

VM nueva con D226 ejecuta19450/46: apertura20,899s, entrada/combate64,293s,
ataque humano18,115s, recogida24,238s y entrega16,615s, cero retries/fallos.
Cuatro iniciativas antes de todo ataque, orden Vex/Thane/Lyra/bandido;
Vex10=2+DEX3+sneak5 deja1/11, Thane7=4+STR3 derrota al enemigo. La declaración
inicial sólo abre combate; el ataque humano se ejecuta tras declarar de
nuevo en su slot. La prosa Vex no cita cifras, por lo que no se atribuye
corrección aritmética al modelo. Recogida×1/retirada×1/cierre único, PG12/7/10,
Lyra2 casillas/reloj0 y fuente humana exactos. Reload1440/375 conserva46/SQL/
narraciones, referencias/47 estilos y bundle sibling, cero JS/overflow.
attack-damage-message-live-verification.json registra fuentes concurrentes
en narración/chat/History y docs exAgent; Actions coincide con el gate, pero
no se presenta todo el recorrido como641 fuentes invariables. No se reinician
agentes ni se reanuda esta mesa durante el readback.19450 queda protegida;
testimonios PNJ indirectos/fact histórico con ubicación anterior permanecen.
R16/AC-31.3d/beta siguen abiertos.

## D225 — Iniciativa antes de admitir ataques enemigos en Game

19448/48 con el paquete D223/D224 activado acredita recogida×1, entrega×1 y
cierre canónico único, sin retry;8,290/37,481/10,537/11,541s hasta turno humano
en intro/ataque/recogida/entrega. No reproduce retención ni certifica su causa.
PG12/7/10, casillas Lyra2 y reloj0 íntegros en recogida/entrega; restart de
agentes/reload1440/375 conserva48/SQL/narraciones,47 estilos, otras mesas/héroe
y bundle, cero JS/overflow. La misma mesa conserva ataque enemigo12 antes de
iniciativa14–17, otro21 en combate, prosa repetida22/23 y Vex«13 más5» pese a
total13. No contar el combate como correcto ni cerrar AC-31.3d/beta.

GameForcedInitiativeTest reproduce rojo5/6 por tercer d20 antes de iniciativa.
Game.ToolReplay admite sólo ataques nuevos de enemigos después de iniciativa,
con directiva antes del callback/RNG. El recibo pagado sigue primero.
Dos regresiones, con d20 constante1/20, comprueban ausencia de RNG/daño extra,
dos iniciativas explícitas, World/SQL y retorno humano sin fallo. La ampliación
inicial del fixture daba20 al primer nombre del World y alteraba el orden;
corregir su d20 constante conserva todos los oráculos.72 focales locales
finales en6,9s; gates completos2862/3 en106,4s yHex2852/3 en63,0s, secuenciales,
seed0/max_cases48 sin warnings/errores/desconexiones. Compiles propios forzados
dev133/test140/prod Hex133 limpios; formato/diff limpios. El runtime/config/
deps/lock de exAgent no cambia de nuevo. Actualización externa posterior de
su mix.exs sólo cambia extras/grupos de docs; comparación exacta fuera de
defp docs y hash previo contra HEAD la acotan, conservando el trabajo ajeno.
AC-29.12 pasa offline; otras tools
ofensivas, semántica de daño, repetición, fallback pendiente yR16 abiertos.

VM nueva19449/38 con D225, DeepSeek4.1/Decart: cuatro iniciativas antes de
atacar, orden correcto y ningún ataque enemigo extra. Vex7/Lyra9, una casilla;
recogida×1/entrega×1/cierre único,39,734/10,520/16,111s sin retry. La traza
pública no acredita ejecución del rechazo; la rama conserva prueba offline.
Cita PC repetida/testimonio PNJ indirecto presentes. Restart/reload1440/375
mantiene38/SQL/narraciones,47 estilos y referencias, cero JS/overflow.
Bundle SHA06a39589 servido coincide con sibling actualizado externamente.
Recibo hostile-initiative-live-verification.json;19449 se añade a las mesas
protegidas. R16/AC-31.3d/beta abiertos.

## D224 — Implementaciones de protocolo añadidas después de compilar

LocalProtocolReloadTest compila un tipo con derive de Jason.Encoder en memoria,
serializa y comprueba roundtrip real, con purge/delete del tipo y encoder.
Rojo por Protocol.UndefinedError/derive ignorado; tras desactivar consolidación
sólo en dev/test, verde en los dos grafos. Probe dev sin iniciar la aplicación
verifica además serialize/deserialize del Snapshot real de exAgent.
El aviso anterior seguía impreso sin compilar el paquete: Mix guarda y vuelve
a mostrar sus diagnósticos. deps.compile exagent --force recompila94 archivos
sin warnings; compile propio dev133 y probe posterior limpios. Test140 yprod
Hex133 forzados con warnings-as-errors limpios; configuración prod conserva
consolidación, lock Hex y ambos paquetes publicados. Gates secuenciales
local2860/3 en105,8 s yHex2850/3 en63,3 s, seed0/max_cases48, sin warnings,
errores de proceso o desconexiones. No cambia el estado de partidas ni acredita
corrección live de la entrega19447 o streaming estructurado R16.

## D223 — Causa Model retenida sin duplicar una respuesta parcial grande

Cinco regresiones en el paquete local: causa length/content_filter conservada
en run/stream_text/run_stream, Server sin Response ejecutable, copia exacta4096
y+1, negativo de body/control sobredimensionado con bytes originales y stock
HTTP/SSE con tools válidas pero finish:length. Respuesta incompleta y usage
quedan en partial; la copia de error lleva marker sin parts/usage.
Rojo39/42; el primer estímulo stock usaba un argumento inválido y no proyectaba
respuesta. Corregido con texto parcial largo y argumento válido, reproduce la
pérdida de causa. Verde42; el negativo de bytes reproduce26/27 y obliga a
preservar la medida original si la copia proyectada tampoco cabe.
102 ampliados en11,8 s y58 runtime/Session/persistencia aparte en0,6 s;
no sumarlos como una suite única. Hay diagnósticos existentes de peer cerrado
y owner death en102;58 limpios. Compile forzado propio test130 sin warnings.
No FULL nuevo2235 del framework ni prueba live de su arreglo.

GameNarrationContractTest añade un caso v2: retirada pagada antes de corte
nativo largo, mismo turno/retry, callback una vez pese al replay, fact una
vez y texto privado ausente de history/eventos; no hay RNG.23 focales en3,8 s.
Gates nuevos local2859/3 en106,3 s yHex2849/3 en62,9 s, secuenciales,
seed0/max_cases48, sin warnings/errores/desconexiones. Test140 forzado limpio;
prod Hex133 anterior conserva exactamente lib/config/locks de producción.

19447/52 se conserva pausada: combate y recogida acreditados, entrega fallida
por error6300/4096 con causa original no guardada, objeto todavía en Thane,
sin cierre/checkpoint. El harness ahora rechaza retorno humano tras fallback
como éxito. Restart UI/reload1440/375 conserva SQL/narraciones/protegidos/47
estilos/bundle; cero JS/overflow. Se observa prosa DM repetida. No contar
esta partida como AC-31.3d, ni el delta como arreglo live; R16 sigue abierto.

## D222 — Contrato de publicación estructurada, integración offline verificada

NarrationContractTest añade 15: schema reflejado/longitud/UTF-8, conservación
de partes y flags, preview retenido, tools reales del loop ejecutadas una vez,
texto libre rechazado, final_result junto a hermanas omitidas, output inválido
corregido por el loop, comprobante terminal de este run, esperas/testimonios,
voz manual, cancelación, texto vacío tras scrub y contexto/retorno incorrectos.
Un Server con modelo determinista de streaming usa el mismo callback que su
control sin la frontera; v2 muestra deltas en el control y los retiene con
Contract. Hex 1.2 chat es buffered. No requiere red/API key ni transforma
automáticamente scripts antiguos en output válido.

NarrationReqLLMTest añade un caso exclusivo del backend disponible en v2:
dos peticiones con ReqLLM stock/HTTP sintético, texto privado en el retry
exacto, final_result con el envelope real y Decart only/none/sin fallback.
La versión que quitaba Text reproduce 0/1 porque enviaba assistant vacío.
Ahora Events omite publicar esas respuestas sin alterar contenido nativo;
solo el campo validado llega a SQL y al historial compartido público.

Rojo inicial 1/13: once fallos del contrato y un oráculo de scrub corregido.
El verde inicial 11/13 deja dos IDs repetidos de Session del fixture; se
supervisan con IDs distintos. Contexto ausente reproduce luego 14/15. Las
pruebas iniciales aíslan la frontera y no acreditan la corrección live de
19446/42, latencia ni beta.

GameNarrationContractTest añade19 con agentes por defecto/APIs nativas de
ambos grafos: narrate + cierre validado, raw privado, hermanas omitidas,
corrección/pausa/recovery del mismo turno, voz manual/ataque/RNG únicos,
cinco flags, PC, espera y backoff que mantiene presupuesto. Dos cortes
reproducen14/16 por recibo ausente antes del acuse y en final sin tools;
NarrationCheckpoint guarda texto/recibo antes de Session/PubSub. Constraint
real de Postgres comprueba rollback y retry posterior único. Dos casos de
cierre mixto/truncado después de pausa manual reproducen17/19: el retry
reanudaba Game. La guarda conserva pausa/comprobante sin programar otro retry.

109 archivos anteriores migrados explícitamente; Harness.narration emite
final_result y Narrator siempre ese output, sin inspeccionar params, traducir
respuestas ajenas o dispensar TestModel. SceneRefresh/TM/summarizer/raw
malformado conservan sus contratos. Oráculos de dados/PG/stock/reloj/fuente/
contexto/etapas intactos; prompts incluyen protocolo estable.271 locales/
269 Hex en40,0/19,5 s, seed0/max_cases48, sin warnings/errores/desconexiones.
Otros9 por grafo en2,1/1,2 s: espera con magia, destinatario PNJ,
observaciones e iniciativa rechazada por SQL/recovery con cierre guardado.
Otros30 por grafo en8,2/3,3 s cubren voz/ritmo de PCs, memoria de tiradas,
agencia y actualización de escena, conservando fuente/World/historial.
Tandas posteriores local/Hex, seed0:25/23 PNJ/escena/retry ReqLLM en6,5/2,5 s;
55/55 efectos/persistencia/ciclo de vida en8,0/4,1 s;68/68 mesa web/reacciones/
progresión en11,5/8,8 s;13/13 hechos/antibucle en1,1/0,5 s;17/17 iniciativa/
relevo en1,8/1,0 s;21/21 bucle de TurnMaster en2,7/1,5 s;
3/3 lobby/ficha móvil en1,4/1,1 s.
El primer ensayo web40/46 reproduce seis fixtures vacíos/malformed; se
arrancan narradores positivos explícitos y se conservan todas las aserciones.
Un caso de TurnMaster aceptaba una nota inicial mientras agotaba el script:
ahora exige respuesta DM completada después de la acción y retorno humano,
sin fallo. La prosa inicial atribuía una acción al humano, quedaba vacía
tras scrub y gastaba un retry; el fixture positivo usa entorno válido.
Las comprobaciones nuevas excluyen la intro sin complete;17/17 pasan después
de corregir un BadBooleanError del oráculo, sin tocar el motor.
Compile test140/prod Hex133 forzado limpio. Gates completos de integración D222:
local2858/3 en105,3 s yHex2849/3 en63,8 s, secuenciales, seed0/max_cases48,
sin warnings/errores/desconexiones. R16/live pendientes.
Auditoría max-failures5/seed0 se
detiene en2239/2244/3 por scripts antiguos de variedad/puppet; tras migrarlos,
sus11 pasan y otra auditoría2256/2261/3 localiza limbo/roster. Esos17 pasan
también con Hex. Auditoría3 se detiene en2277/2282/3 por fixtures antiguos
de identidad dirigida, gesto del DM y autoridad de combate; sus8 pasan.
Auditoría4 se detiene en2299/2304/3 por scripts antiguos de equidad; sus7
están incluidos en el focal ampliado. Son diagnósticos, no gates completos.
Auditoría5 se detiene en2413/2418/3 por aquellos cuatro fixtures; sus9
ya pasan por grafo. Auditoría6 se detiene en2467/2472/3 por fixtures antiguos
de voz/ritmo y memoria de tiradas; sus5 casos están en los30 adicionales
verificados. Auditoría7 se detiene en2515/2520/3 por entorno/presencia,
retry stock y citas; sus casos ya están en25/23. Auditoría8 se detiene
en2592/2597/3 por ciclo de vida, confirmación de espera y efectos; incluidos
en55/55. Auditoría9 se detiene en2685/2690/3 por antibucle/hechos; sus13
pasan. También se migran relevos/TurnMaster antes de seguir. Auditoría10
termina2855/2858/3 en120,7 s: tres fixtures positivos de lobby/ficha móvil
seguían usando texto libre. Migrados explícitamente, sus3 pasan en ambos
grafos y los dos gates completos posteriores pasan limpios.

GameNPCMemoryReqLLMTest conserva tres HTTP reales del adaptador stock con
transporte sintético: final_result prematuro no publicado, memoria guardada
y cierre validado. Schema/envelope oficiales, Decart only/none sin fallback,
tool_choice required incluso tras memoria y prosa libre retenida. El fixture
inicial suponía que el retry de Game conservaba aquel assistant: Game importa
historia pública/recibos al iniciar el nuevo run. Se comprueba la ausencia
del cierre rechazado; el caso NarrationReqLLM separado acredita continuación
nativa exacta dentro del mismo run. Otro fallo de fixture esperaba auto tras
memoria; el adaptador stock deriva required de allow_text_output:false.
La primera aserción reforzada de iniciativa también incluía la introducción
sin turn_id: se delimita al beat propio, manteniendo los dados/recursos.
Ni el transporte ni TestModel traducen respuestas ajenas para cumplir output.
Estos focales son diagnósticos acotados; los gates completos se registran
arriba. Ninguno acredita por sí solo beta o corrección live de 19446.

El contrato público actual Model.request_stream expone deltas de texto,
pensamiento/uso y respuesta terminal. ReqLLMStream.on_result emite text_delta;
las calls/argumentos se acumulan para la respuesta completa. No hay un delta
público de argumentos tipados que pueda usarse como preview del campo text.
Las pruebas del render legado no sustituyen ese recorrido. R16 exige
implementación y prueba de ese camino antes de otra certificación live.

Base anterior:55 focales locales en5,6 s y54 Hex en3,0 s, sin warnings/errores.
local-full-37: 2839/3, 101,5 s, seed 872554/max_cases 48; hex-full-22:
2830/3, 62,2 s, seed 595324/max_cases 48. Secuenciales en la misma DB;
un aviso deliberado de retry local y seis de breaker/retry Hex, cero errores
de proceso/desconexiones. Compiles propios dev/prod forzados de 132 archivos
sin warnings y formato/diff limpios. Readback SQL/web a 1440/375 conserva
19446/42 y sus fallos públicos, todas las narraciones, partidas/héroe y 47
estilos previos; bundle dic_ex sibling y cero errores JS/overflow. No es
otra aventura ni un ensayo live del nuevo contrato. Evidencia privada:
narration-contract-*, narration-native-red.log y los dos gates finales.

## D221 — Fuente de la voz humana durante la resolución general

EventsHumanDeclarationTest7 verifica sustitución Text actual, tool IDs/meta
intactos, fuente por game/actor/turno/audiencia, UTF-8 y notación originales,
incompletos/vacío/cancelación sin comprobante y query fuera de contexto400.
HistoryHumanDeclarationTest2 conserva intent user, voz DM separada, visibilidad
y declaraciones antiguas íntegras. GameHumanDeclarationTest6: ataque normal,
503 después del golpe, restart tras daño, autoplay, recogida mediante DM y
fallo definitivo sin gesto inventado. Herramientas/dados/PG/stock/reloj/SQL
exactos; siguiente petición y shared history sin prosa inventada. El control
positivo de streaming DM usa v2; Hex1.2 Server.chat no aplica stream_text.
Rojo0/10 y fallo definitivo5/6. Fixtures iniciales ajustan eventos de creación,
Item.kind atom y marca/log legítimos de inventario; cinco casos anteriores
exigen voz fuente y rechazan reformulación sin debilitar oráculos de reglas.
93 focales por grafo14,1/6,5 s; gates2823/3/100,1 s/seed52307 y Hex2815/3/
60,2 s/seed948896, max_cases48, secuenciales, seis avisos deliberados cada uno,
sin errores/desconexiones; compiles propios dev/prod forzados limpios.

19445/53 es reproducción anterior conservada.19446/42, DeepSeek4.1/Decart
estricto, tiene declaraciones humanas exactas en9/30/37, stock×1 solo entre
recogida/entrega y PG12/7/10/slots/reloj0 intactos. Primera acción no genera
ataque propio; DM registra ficha/iniciativa y Vex mata con arco/daño11. Tres
retries de argumentos en50,641 s; recogida/entrega20,166/21,661 s sin retries.
Reinicio de agentes UI/reload1440/375 conserva todos los textos,42/World,
47 estilos y mesas/héroe protegidos; cero JS/overflow, bundle sibling exacto.
Intro DM incluye razonamiento público y entrega dice cierre sin fact; la voz
DM añade gestos. Esas observaciones siguen abiertas, sin borrar la evidencia.

## D220 — World confirmado después de tools del mismo beat

AgentWorldRefreshTest añade tres puros de stock vigente/reemplazo de foto,
primera petición/contextos fuera del beat sin lectura y Session no World.
GameWorldRefreshTest añade humano y Vex: golpe fatal, continuación con PG0
y ausencia de enemigos vivos antes del cierre; dados exactos, incluido furtivo
de Vex, PCs/reloj/SQL intactos. Foto ausente de canonical/Events, tipos
IA/humano vigentes y snapshot único. Rojo2/5,17 focales locales/Hex1,1 s.
Primer fixture World.add inexistente corregido antes del rojo causal; en
verde se separa el modelo SceneRefresh y se cuenta el d6 furtivo legítimo.
Read-only SharedState + Brief, sin SQL/modelo adicional ni reescritura de
prosa anterior. Ver world-refresh-*. La petición contiene datos vigentes;
eso no acredita fidelidad semántica o latencia universal del modelo real.
Gates finales2808/3/100,4 s/seed261014 y Hex2800/3/60,8 s/seed684244,
max_cases48, secuenciales; seis avisos deliberados y sin errores/desconexiones.
Compiles forzados propios dev/prod limpios; local-full-30/hex-full-20.
Readback109 después de source nuevo conserva World/historial entero y47
estilos previos; bundle dic_ex igual al sibling,1440/375 sin JS/overflow.
Nueva aclaración PNJ109→116: una sola voz humana literal, record_npc_statement
con fuente/dudas/registro606 s y respuesta DM,12,262 s/cero retries. Solo
facts cambia; PG4/reloj606/slots/stock/encargo exactos, prefijo conservado.
Reinicio de agentes UI/reload1440/375 conserva116 y prosa completa; evidencia
lantern-v2-clarify-*/lantern-v2-memory-verification.json. No confirma el relato
ni rescata el primer interrogante fallido; no atribuir causalidad de latencia.

## D219 — Feedback de actor inexistente, ausente y controlador DM

ControlRejectionGuidanceTest añade cuatro puros; GameMissingActorGuidanceTest
añade recuperación scriptada tras rechazo, spawn y después iniciativa. Roller
rechazado falla si se usa; no cambia World. Mensajes distinguen ficha ausente
del mundo/ausente de escena y dm controlador; muestran nombres controlados
disponibles y conservan corrección PC. Rojo1/5 (el primer fixture omitía policy
y se corrige antes de causal);29 focales locales1,8 s/Hex0,9 s, con autoridad
DM/PC/direct effects y ghost combat. Game confirma dos dados iniciales,
esqueleto13 y PC/PG/reloj/SQL exactos. controlled_by? permanece sin cambios.
Live44→67 registra finalmente skeleton y cuatro iniciativas; Vex/Lyra fallan
una vez y espera Thane.41,129 s/un retry/handoff_failed. No atribuir obediencia
universal ni causalidad de latencia; pruebas previas del hostil solo en prosa
no equivalen a ficha ni ataques resueltos. Evidencia control-guidance-*,
lantern-v2-attack-control-*.
Gates finales2803/3/100,2 s/seed192264 y Hex2795/3/60,1 s/seed71290,
max_cases48, secuenciales: seis avisos deliberados y sin errores/desconexiones.
Compiles forzados propios dev/prod, formato y diff limpios; local-full-29/hex-full-19.

Playtest posterior19444: combate67→88 recorre turno del monstruo y ronda,
daño8 a Thane/4PG y enemigo0; reloj306. Recogida88→95 añade solo farol×1,
regreso95→102 suma300 s con fichas exactas y entrega102→109 retira solo
ese item y añade fact de cierre. Tres pasos sin retries,30,964/21,262/34,548 s.
Oráculos comparan fichas completas, slots, prefijos de eventos y ausencia de
checkpoint/pending_turn. Reinicio UI de agentes y reload1440/375 conservan
SQL/World/historial109, cada narración visible y mesas/héroe protegidos.
Sin JS/overflow, bundle igual al sibling; lantern-v2-closure-verification.json.
No certifica fidelidad: humanización de voz/gestos, arma ficticia, petición
de rematar tras golpe mortal y recuerdo Ada sin record_npc_statement persisten.
La primera pregunta PNJ falló; no atribuir a esta mesa la memoria de19443.

## D218 — Feedback en la petición del reintento de argumentos

ToolArgumentRetryGuidanceTest/GameToolArgumentRetryGuidanceTest añaden cuatro:
proyección única/canonical exacto, causas negativas/body privado no expuesto,
actor y TM reales con error sintético y feedback en la siguiente petición.
Grant_item×1/World SQL/reloj exactos, un turno/sin dado, Events/history sin cue.
Rojo1/4;43 focales locales2,7 s/Hex1,7 s. Server.get del fixture se cambia a
history público; primer verde21/22 revela falta de capability en TM, añadida
antes del verde final. Gates2798/3/99,2 s/seed774345 y Hex2790/3/62,3 s/seed64041,
max_cases48, secuenciales y limpios; seis avisos deliberados. Body/payloads
de proveedor no se copian, no se repara/admite argumento inválido ni cambia
backoff/budget. Restart UI37 conserva World/historia; intento37→44 con un
retry cambia a rechazo semántico de control, sin dados/gasto, con prosa43
conservada. No presentar como recuperación completa o mejora causal.

## D217 — Self-handoff DM tras una respuesta ordinaria

ExplorationTurnsTest añade dm como repeat a persona manual elegible, incluso
sin compañeros y sin turnos IA previos; autoplay total no recibe el relevo.
GameDMSelfRepeatTest añade dos casos: pass_to_dm y give_turn_to(dm), cada uno
con cero/dos compañeros. Grant_item registra farol×1; un segundo beat DM
avisa y pide advance_time300/remove_item, y no ocurre. Marcadores Thane/DM
únicos, reloj/escena exactos, World SQL igual. Rojo8/11 (tres nuevos fallan),
32 focales locales3,6 s/Hex1,5 s, con fast-path/opening/anti-loop vecinos.
El primer intento red no compila por una comprehension ambigua del fixture;
se separa en variable antes de obtener el rojo causal. No cambiar producto
para ese error. 19443/107 permanece como reproducción del viaje/entrega
no declarados; una pausa adicional expira porque el helper original ya pausó.
Mesa nueva19444 creada por UI7/13,249 s, DeepSeek4.1/Decart, sin retries.
Continuar recorrido por decisiones separadas; no llamar correcto al encargo107.

## D216 — Recuperación de orden incompleto ya persistido

HostileInitiativeRecoveryTest y GameHostileInitiativeRecoveryTest añaden seis:
hostiles omitidos al final ordenados por nombre, ausentes/caídos/exploración,
idempotencia/Codec, turno humano y turno gastado exactos, resume/reinicio running,
rollback por constraint de la nota y retry; guard busy/checkpoint/pending_turn.
Roller que falla y contador de modelo prueban ausencia de nueva tirada/petición.
Rojo 0/6; 36 focales locales 4,3 s/Hex 2,2 s, secuenciales sobre dragonex_test.
Chrome real reanuda 19443/68→69: una nota, esqueleto añadido al final, solo
order/log cambiados y prefijo/PG/recursos/reloj300 exactos. 1440/375 sin JS ni
overflow, nota visible y bundle igual al sibling. Mantener mesas/héroe protegidos
y seguir pelea/farol/regreso. No reconstruir iniciativa histórica ausente ni
atribuir una tirada al monstruo. Evidencia hostile-initiative-*, lantern-recover-*.

## D215 — Roster de iniciativa revalidado al commit

Control público World/Actions sin app/DB/modelo reproduce el orden de tres PCs
aceptado después de añadir esqueleto; preparación fresca incluye cuatro.
initiative_roster_commit_test añade tres: alta concurrente, ausencia/caída/DEX,
control fresco con cuatro d20 y desempate, escena válida y callback sin reroll.
Rojo 1/3, 53 focales locales 3,9 s/Hex 2,9 s. Cobertura vecina de autoridad,
iniciativa automática, rollback de dados/World, handoff y checkpoint permanece.
No modificar begin_combat ni reescribir la mesa 19443/68 que reproduce el bug.
Pendiente recuperación/replay real; no probar toda combinación concurrente
con este único guard. Evidencia initiative-stale-probe.*, initiative-roster-*.
Gates finales 2785/3/97,3 s/seed 980986 y Hex 2777/3/60,3 s/seed 235773,
max_cases 48, secuenciales; seis avisos deliberados y sin errores/desconexiones.
Compile propio dev/prod/formato/diff limpios. Evidencia local-full-25/hex-full-15.
Readback final readonly de 19443/68, reload 1440/375, fuente hasheada y bundle
dic_ex igual al sibling; 47 estilos anteriores y mesas/héroe protegidos exactos.
El defecto heredado se conserva como tal, sin afirmar recuperación. Recibo
privado continuation-initiative-final-verification.json.

## D214 — Prosa intermedia y continuación dentro del turno

AgentTurnContinuationTest añade tres. Servidor DM/TestModel real con dos tools
recibe cue única solo después de publicar prosa. Verifica todos los segmentos,
recibo final, historia/World y proyección original; negativos game/actor/turn,
secretos, completion falsa mal tipada, texto vacío/no string y ausencia de beat.
Rojo 0/3, 27 focales locales 3,5 s/Hex 2,3 s. Gates intermedios 2782/3/98,8 s
y Hex 2774/3/60,1 s, anteriores a D215. No filtrar ni borrar texto similar.

Mesa real: 28→38/12,613 s mantiene World/voz literal y dos opiniones sin DM;
38→46/32,863 s registra trayecto 300 s una vez, sin gasto, solo log/scene/reloj.
44/45 duplican casi un párrafo antes de la guía. Apertura 46→68/28,957 s con
DeepSeek 4.1/Decart: 58/62 conservados, con contenido diferente; handoff_failed
y dos retries inválidos recuperados. Esqueleto 4/13 tras ataque factual Vex de 9,
pero fuera de iniciativa: se mantiene pausada para D215/replay. Chrome 1440/375
sin errores JS ni overflow horizontal; PNG inspeccionadas, mesas/hero protegidos
exactos. Fidelidad/puerta inventada/pregunta humana añadida/brevedad abiertas.
Evidencia turn-continuation-*, lantern-{peer-plan,walk,open}-*.

## D213 — PNJ por nombre y envelope de tools

NPCNamedSpeechTest: tres casos con pregunta real triple, nombres Unicode/NFC/
guion/apóstrofe, knowledge query, contexto ausente, identidad/alias PC,
multiword, cita/espera/petición/acción/cuarta pregunta. GameNPCLiteralSpeech
añade restart de Ada pendiente con voz única y testimonio atribuido; incorpora
la pregunta a magia mixta con slot/dado. Rojo 9/12; cuatro nuevos y 50 focales
locales 7,5 s/Hex 3,3 s. Sin cambios World/Codec/DB. Primer ensayo 13→21 en 28,809 s
conserva voz humana, pero falla tras tres retries inválidos; World exacto.

Diagnóstico de Model con history incompatible y transport adapter en stream
es rechazado antes de IO por guards existentes; no se desactivan. Fixtures
de script fallan antes de request por Brief/settings/ModelConfig; se conservan
logs y no cuentan como evidencia del proveedor. Dos llamadas frescas públicas
stock ReqLLM, buffered/stream, muestran speaker/statement planos sin arguments,
sin ejecutar efectos. No son captura de las ocho respuestas fallidas originales.
Sibling añade guía backend única, sin tools ausente/caller intacto: rojo 14/15,
un fixture de history se corrige por rol y 131 casos ReqLLM pasan en 14,5 s. Logs
negativos de closed/killed/timeout/fragmentos esperados; sin full del paquete.
Tooling 1.20.0 falla Hex; prefijo 1.20.3/OTP 29.0.5 verifica sin cambios globales.

Local completo tras guía 2779/3/98,7 s/seed 581205; Hex 2771/3/61,3 s/seed 889943
mantiene fuentes propias iguales, max_cases 48, secuenciales con testDB única.
Seis avisos deliberados y sin errores/desconexiones. Compile dev/prod/formato/
diff limpios. Consulta 21→28 en 11,564 s con DeepSeek 4.1/Decart: habla exacta, respuesta
completa Ada y testimonio con fuente/duda, cero retries inválidos; solo facts
cambia, reloj 0/recursos/prefijo/mesas 19425/944 y 19439/9/hero 5164 exactos.
Chrome 1440/375 sin errores JS ni overflow horizontal, PNG inspeccionadas; mesa 28 pausada.
Fuente guía se carga por reloader oficial con exagent incluido, sin VM nueva.
Evidencia privada npc-named-*, envelope-guidance-*, npc-stock-shape.*,
lantern-{first,named,envelope}-question-*, local-full-23/hex-full-13.
La guía soft no prueba obediencia/verdad/SLA universales. Continuar campaña.

## D212 — Creación con texto largo y recuperación del formulario

GameCreationTextTest/contexto prueba estilo Unicode/multilínea completo,
rechazo256 ASCII/128 grafemas descompuestos sin insertar y aceptación255
emoji. LiveView prueba creación/errores en detalles/cambio final forjado,
corrección/back con héroe/compañero/texto conservados. DMStyle existente
recibe estilo largo completo antes/después del restart. Cuatro tests nuevos.
Primer ensayo no compila por variable redirect; segundo usa selector CSS
multilínea inválido. Se corrigen fixtures, sin atribuirles rojo de producto.
Rojo causal2/7: rollback exclusivo testDB (max estilo0) y desactivar solamente
validación título; cinco fallos SQL/flujo. Restaurar validación/migración:
30 focalizados locales5,0s/Hex4,4s verdes. Gates completos secuenciales
2775/3/97,2s/seed503014 y2767/3/59,7s/seed846548/max_cases48, seis avisos
deliberados y sin errores/desconexiones. Compile dev/prod/formato/diff verdes;
detector New vacío. Migración test/dev preserva47 estilos/default y estado
protegido. Producción no migrada; no truncar estilos para rollback.

Browser1440/375 prueba alerta/aria, corrección, Enter y back; crea19443 con
estilo476 exacto/3D/Thane/Lyra/Vex/DM, pausada6. Primer clic previo falló
sin insertar: reintento con journal nuevo y SQL count0, sin repetir a ciegas.
Capturas inspeccionadas, sin JS/overflow. Consulta a Ada6→13/31,821s deja
World/recursos/reloj iguales, reformula al humano y agota tres reintentos
invalid_tool_arguments; fallback público sin respuesta/memoria. No se marca
ese recorrido exitoso. Evidencia privada creation-text-*, lantern-created,
lantern-first-question-{before,click,after}, local-full-21/hex-full-12.
Mesas19425/944,19439/9 y hero5164 exactos. Beta activa, sin deploy.

## D211 — Preguntas PC consecutivas y cierre acreditado

PCMultiQuestionTest prueba dos/tres interrogativas completas con vocativo
común/espera pasiva, rechazo por cualquiera no informativa/petición/cambio
de voz/acciones/cronometrado/cuarta/malformada/identidad incierta, y cláusula
del mundo en cualquier posición sin cierre discreto. ConversationClosureTest
comprueba reserva/Codec/cierre y conserva DM tras tiempo/dado/nueva pregunta.
GamePCLiteralSpeechTest verifica habla exacta, ambos requests/identidades,
contexto previo de Lyra para Vex y retorno sin narrador; amplía restart y
False Life mixto a la pregunta doble. GameConversationClosureTest añade dado
sin efecto World y nueva pregunta PNJ, con solo el DM correspondiente.

Seis tests nuevos. Rojo20/26; primer verde25/26 cuenta apertura DM antigua en
el contador nuevo. El fixture final preserva el prefijo y compara solo eventos
posteriores a declarar. No cambia producto por ese fallo.64 focalizados
locales9,3s y Hex4,1s verdes, incluidos NPCs, fuentes y voces anteriores.
Gates completos secuenciales2771/3/96,8s/seed916615 y2763/3/57,8s/seed90244,
max_cases48; seis avisos deliberados y sin errores/desconexiones. Compile
propio dev/prod forzado con warnings-as-errors y formato/diff limpios.

Consulta idéntica934→944/4,061s con DeepSeek4.1/Decart: voz de Mara exacta,
dos respuestas PC y retorno sin turno/narración DM. World/15 facts/reloj/
recursos/inventario/prefijo/otra mesa/hero exactos, mesa944 pausada. Lyra74/
Vex47 palabras y acuerdo con criterio propio de cautela en Vex; fuentes/
brevedad siguen abiertas. No es benchmark causal/SLA o prueba semántica
general. QA readonly1440/375/reload/SQL sin JS/overflow; capturas inspeccionadas
y bundle SHA76ccd0e6 igual al sibling. Evidencia privada literal-peer-multi-
{before,click,browser,observed,after}.json, pc-multi-question-final-verification.
json/PNG, pc-multi-question-{red,green-1,focused-local,focused-hex,compile-dev,
compile-prod}.log, local-full-20 y hex-full-11. Sin publicar/deploy; AC-32.1c
entregado, beta activa. Seguir nuevos pasos de campaña/memoria y fuentes.

## D210 — Orden retenido de testimonios

TestimonyBriefTest añade cuatro casos causales: mismo reloj, nombre completo
NFC/espacios/case sin alias/roles/acentos fusionados, últimas posiciones por
fuente independientes de relojes/legacy, y repetición retenida sin promoción.
Rojo5/12 incluye tres tests de Game endurecidos para recibir ambas versiones
y su marcador en el mensaje efectivo después del archivo o compacción con
resumen falso. Un quinto caso nuevo reinicia sobre Vex tras publicar Lyra;
conserva World/orden/recursos y cada voz/humano una vez.46 focalizados por
grafo verdes. TestModel verifica entrega, no interpretación semántica libre.

Gates completos en secuencia sobre dragonex_test:2765/3/95,9s/seed916615 y
2757/3/58,6s/seed90244/max_cases48. Seis avisos deliberados, sin errores/
desconexiones. Compile propio dev/prod forzado con warnings-as-errors;
formato/diff limpios. Logs testimony-order-{red,green-1,focused-local,
focused-hex,compile-dev,compile-prod}.log, local-full-19 y hex-full-10.

Probe nueva921→934/15,905s: pregunta sobre cambio de la aclaración y propuesta
de siguiente paso, DeepSeek4.1/Decart. Lyra86/Vex66 palabras: Vex conserva
límite de visión cercana, pero fuentes/brevedad siguen abiertas. La pregunta
doble no satisface pc_question_parts de una sola interrogativa y reaparecen
reformulación humana y cierre DM. No cambiar el resultado para aparentar
una ruta de cierre más corta. World/15 facts/recursos/reloj/otra mesa/hero
exactos, prefijo de eventos íntegro y mesa934 pausada. Chrome readonly1440/
375/reload sin JS/overflow, respuestas completas, capturas inspeccionadas;
bundle SHA76ccd0e6 igual al sibling. Sin beat pagado durante QA readonly ni
benchmark causal/SLA. Evidencia privada ordered-source-{before,click,browser,
observed,after}.json y testimony-order-final-verification.json/PNG.
AC-25.10 entregado; beta activa, sin publicar/deploy.

## D209 — Contexto de la pregunta vigente y diálogo directo

PCPreviousAnswersTest añade cuatro controles puros: ancla seq/fuente/texto,
solo destinatarios previos con voz pública completa, exclusión de otro diálogo/
privados/borradores/actor actual, Text.scrub y omisión íntegra de exceso1800.
Scope combate/caída/DM/primer compañero no adquiere contexto. Codec/World
permanecen. GamePCResponseGuidanceTest endurece entrega en el mensaje efectivo
de Vex (rojo1/3 original), y añade restart después de publicar Lyra y compacción
que exagera su respuesta. No repite primera voz/humano ni gasta recursos.
Son seis casos nuevos;27 focalizados en local/Hex pasan. El formato de diálogo
directo tiene rojo5/6 de entrega, luego esos27 pasan de nuevo en cada grafo.
TestModel prueba mensajes/contratos, no calidad semántica del texto generado.

Primer gate local2759/2760/102,4s y Hex2752/3/66,0s concurren sobre dragonex_test.
40P01 en GameToolRollCommitTest: log Postgres confirma ALTER TABLE para
reject_test_tool_dice y reject_test_engine_dice en procesos distintos. Ambos
casos son async:false dentro de su VM; esa guarda no coordina dos VMs. Se
conserva el fallo SQL real y su cobertura de rollback, sin retry para ocultarlo.
Caso aislado8/8 y gate local solo2760/3/94,9s/misma seed916615 sin colisión.
Tras el formato final, gates secuenciales2760/3/95,4s/seed916615 y2752/3/58,1s/
seed90244/max_cases48, seis avisos deliberados y cero errores/desconexiones.
Compile propio dev/prod forzado con warnings-as-errors, formato/diff limpios.

Preflight de navegador esperaba none literal en el título; la UI muestra off.
Aborta antes de reanudar o escribir journal de click: SQL901 exacto/cero llamadas.
Se corrige el fixture y se comprueba la ausencia de click antes de ejecutarlo.
No se cambia thinking del producto. Consulta901→911/5,594s con solo contexto
mantiene gestos/repetición; formato directo911→921/7,166s elimina gestos de
narrador en ese par. Lyra76/Vex61 palabras siguen largas/repetidas; no se
certifica fidelidad de fuentes. Pregunta repetida/historial distinto y modelo
estocástico no prueban mejora causal o SLA. Ambas consultas conservan World/
15 facts/recursos/reloj/inventarios/prefijos/otra mesa/hero. Última QA readonly
reload1440/375 ve respuestas completas sin JS/overflow y assets SHA76ccd0e6
iguales al sibling; capturas inspeccionadas. Mesa921 pausada, VM original viva.
Sin publicar/deploy. Evidencia privada anchored-peer/direct-peer-{before,
click,browser,after}.json, pc-exchange-final-verification.json y logs
pc-exchange-* / local-full-16/17/18 / hex-full-7/8/9; detalle SQL en
pc-exchange-ddl-deadlock.txt. AC-32.4c entregado, beta activa.

## D208 — Disponibilidad coherente del modo de dados

GameDiceEngineTest usa capacidades reales del grafo instalado: tres nuevos
controles de creador, preferencia anterior/snapshot/dos vistas y stage directo.
Rojo válido local2/3/Hex0/3. Confirma evento autoritativo dirigido al mismo ID
del hook, guardia durante rolling, elección por vista, World/eventos/preferencia
persistida sin cambios. Los errores iniciales de sintaxis/assertions del
fixture se corrigen antes de esos rojos; no se atribuyen al producto.
WizardChoiceTest previo suponía3D disponible en todo grafo: primer gate Hex
2745/2746 descubre esa suposición. Se adapta a capacidad instalada conservando
selección de escenario/héroe y restricciones de compañeros ocupados.

Gate local2754/3 en96,7s/seed729954 y Hex2746/3 en58,4s/seed478056/max_cases48,
ambos sin errores/desconexiones, seis avisos deliberados de breaker/retry.
La limpieza final de una clase visual inexistente se valida con26 focalizados
posteriores en cada grafo; no altera lógica, datos o capacidad. Compile propio dev/prod forzado
con warnings-as-errors y formato pasan; build prod usa directorio separado.

Dos endpoints temporales loopback usan componentes/FSM/delegados reales,
sin Game ni llamadas LLM. Chrome/WebGL local y Hex a1440/375 confirma modo/
hook/control, Space en3D local, foco ignora3D deshabilitado en Hex, total19/DC15,
guardia del toggle mientras anima y cierre posterior. Cero pageerror/overflow;
cuatro capturas inspeccionadas. Endpoints4036/4037 cerrados tras el ensayo;
solo la app original4035 permanece. Navegación readonly real de mesa/creador
a1440/375 conserva SQL19425/901/World/eventos/otra mesa/hero; bundle servido
igual al candidato SHA76ccd0e6. Sin beats/tools/LLM ni hooks QA permanentes.

Detector impeccable ejecutado una vez: seis tratamientos preexistentes de
pixel tabs/animación fuera de este selector. No se declara scan general limpio
ni se rediseñan esas áreas en este cambio. Disponibilidad es del paquete;
fallback posterior por GPU no actualiza el selector del servidor. AC-14.9
entregado, beta activa; evidencia privada dice-mode-browser.json,
dice-mode-final-verification.json, dice-mode-design-scan.json y logs
dice-mode-{local,hex}-{red-3,final-2}.log, local-full-15.log/hex-full-6.log.

## D207 — Constructor3D fallido y liberación de recursos propios

Tres regresiones iniciales en dic_ex fallan9/12: renderer.setPixelRatio,
Rapier.createRigidBody y GridHelper después de reservar recursos. Todos
retienen allocations y no liberan ninguna, porque el constructor falla antes
de asignar hook._scene. Chrome inyecta error después de inicializar física real:
fallback2D funciona/asienta, pero contexto/física/tabla vivos y release counts0.
El constructor ahora hace dispose antes de propagar; no necesita que el hook
reciba la instancia. Caso adicional de contexto no creado conserva el error.

Primer verde13 confirma los cuatro límites. Quinto caso fuerza error en
renderer.dispose y falla13/14: la primera limpieza detenía contexto/física.
Dispose intenta todas las liberaciones de escena, conserva el primer fallo
de limpieza; constructor sigue propagando su error inicial. Final14/14 Node.
El primer comando con el shim del sibling no carga Hex y el siguiente PATH
acotado pierde Node: errores del entorno del ensayo, no del producto. Toolchain
explícita Elixir1.20.3/OTP29 con PATH existente ejecuta rojo/verde y builds con Mix;
no npm/npx, instalación nueva o cambios de versiones.

Chrome final inyecta ambos errores tras reservas reales: releases de renderer/
contexto/física/tabla igual1, world=null/contextLost, error inicial preservado,
dispose repetido y escena normal también limpios. La cola muestra cara18/d20
realmente pintada y un settled, sin pageerror/Game tools/LLM. Bundle rebuild
SHA76ccd0e6 igual al servido en4035. Navegación normal anterior al último
refuerzo de cleanup confirma caras3/5/7/9/11/19, RAF detenido, desmontaje y
1440/375 sin overflow/JS; el último ensayo confirma cleanup normal otra vez.
14 host locales/14 Hex pasan (suite de FSM/assets/diálogo), compile dev/formato
limpios. Root no cambia reglas/protocolo; gates completos conservan referencia
D2062751/3/2743/3, no se repiten por este cambio exclusivo del JS del paquete.

Consulta de consumidores891→901/7,127s: fuentes/referente recuperados y World
igual/15 facts, ninguna tool/dado nuevo. Los PCs repiten datos y Vex dice «juró»:
no se declara corregida fidelidad/brevedad general ni se reescribe memoria.
SQL posterior a ensayos de dados conserva901/World/eventos/otra mesa/hero.
Evidencia privada clarified-peer-{before,click,browser,after}.json,
dice-partial-init-{before,after,after-cleanup,normal,sql}.json y logs
dice-partial-init-{red-3,cleanup-red,green-2,build-2,browser-cleanup-green,host-2,hex-host,normal}.log.
Sin publicación/deploy; no certifica toda GPU o asignaciones internas no
entregadas por un constructor de terceros. Beta sigue abierta.

## D206 — Comprobante de aclaración PNJ antes de publicar

GameNPCMemoryResolutionTest añade cuatro controles de Game/Postgres: borrador
sin registro y deltas privados, fuente incorrecta→correcta, duplicado retenido
y reinicio entre registro/final. Rojo2/4 antes de capability. NPCMemoryResolutionTest
añade cuatro: activación acotada, recibo del actor/turno/fuente/values, memoria
previa insuficiente/interrupción de combate y normalización sin alias ambiguos.
Codec no cambia. Fixture previo de restart de aclaración ahora confirma la
limitación del PNJ antes de responder; las otras preguntas siguen sin obligación.

GameNPCMemoryReqLLMTest añade una frontera HTTP stock: respuesta textual pese
a required, luego herramienta con envelope y final. Tres requests, choices
required/required/auto implícito, Decart only/sin fallback y reasoning_effort:none;
solo un fact, sin borrador publicado/dados. Constructor DM real conserva settings
válidos; solo el selector de streaming de Game se fuerza a buffered para la
fixture JSON. No se modifica el modelo/settings del Server, stock ReqLLM ni
capacidades para acomodar la prueba. Casos previos de fixture detectan metadata
mandatory ausente, temperatura heredada al intercambiar modelos y auto omitido:
se corrige el ensayo, no las guardas del producto. StreamModel con contador
supervisado prueba publicación v2; Hex1.2 chat es buffered y prueba final,
sin atribuirle deltas inexistentes.32 focalizados locales/19 Hex limpios.

Gates2751/3 en96,7s/seed451166 y2743/3 en59,8s/seed561721, max_cases48;
ambos seis avisos deliberados, sin errores/desconexiones/warnings de compilación.
Formato y compile forzado propio dev/prod warnings-as-errors salen0 limpios.
No se repite gate completo de paquetes hermanos por este cambio del host.

Aplicar ajustes recarga capability con todos los datos iguales a884. Consulta
DeepSeek4.1/Decart884→891/7,665s guarda solo una aclaración atribuida a41535s,
no vio la tela de cerca y distingue lo contado del hilo de observación propia.
Prefijo884/14 facts anteriores, recursos/reloj/inventario, otra mesa y hero5164
intactos; cero dados. Restart por ajustes y reload1440/375 conservan exactamente
SQL y muestran pregunta887/final890; cero JS/overflow, assets iguales al paquete.
No se infiere verdad, relevancia semántica general o cobertura de toda pregunta.
Evidencia privada npc-memory-{adoption,navigation}.json,
clarify-testimony-memory-{before,click,browser,after}.json,
npc-memory-{red,local-7,hex-2,compile-dev,compile-prod,live}.log,
local-full-14.log y hex-full-4.log. Beta sigue abierta.

## D204/D205 — Aclaración literal y recuperación de argumentos generados

Declaración real862→869/26,149s: dos interrogantes y preámbulo dentro de cita
no entran en el detector de una sola pregunta; el humano se reformula con
gestos y el DM aclara sin fact. Tres nuevos casos de gramática/Game más magia
mixta/restart existentes: rojo13/16, verde23 adyacentes. La cita completa admite
hasta tres preguntas informativas al mismo PNJ; acciones exteriores, otras
voces, citas/signos inválidos, solicitudes y colisiones PC conservan sus guardas.
El registro de TestModel añade solo una atribución y conserva el texto anterior.

Consulta869→877 conserva habla literal, pero ReqLLMEnvelope rechaza argumentos
generados; Game termina en fallback. Dos nuevos tests de clasificación/HTTP
stock reproducen el rechazo: rojo16/18. Se reintenta solo provider req_llm /
invalid_tool_arguments dentro del límite existente. Schema/history/continuation
siguen terminales. HTTP devuelve tipo inválido después de una tool confirmada
y la repite válida: cuatro requests, una casilla, daño6/un grupo, sin fallo final.
Fixture parametrizado se mueve a una función para evitar avisos por constantes;
34 focalizados finales sin warnings. Hex49 adyacentes pasan.

El primer Hex23 falla en Enumerable.LazyHTML: compartir MIX_BUILD_PATH explícito
entre prod y test dejó consolidación sin el protocolo test. compile.protocols
--force solo no lo corrige; mix clean del app y recompilar test sí. No se cambia
LazyHTML, Phoenix ni el producto para acomodarlo. A partir de aquí prod usa
hex-prod-build separado de hex-build de test; MIX_BUILD_PATH explícito no añade
automáticamente un subdirectorio por MIX_ENV.

Gates actuales: local2742/3 en92,9s/seed758887 y Hex2735/3 en58,2s/seed70122,
max_cases48. Ambos seis avisos deliberados, cero errores/desconexiones/warnings
de compile propios. Compile dev forzado y prod frío warnings-as-errors salen0;
stock dependencias conservan avisos xref/Logger ya documentados. Formato limpio.

Consulta877→884/9,150s tiene un retry1/3 real por invalid_tool_arguments y
respuesta PNJ. SQL fresco confirma World/prefijo862/otra mesa/hero intactos,
habla humana literal y ningún dado nuevo. El criterio esperado de un nuevo
testimonio falla en las tres consultas: no se fabrica ni reescribe memoria
para hacerlo pasar. La aclaración queda solo en prosa; es seguimiento de beta.
Chrome1440/375 muestra pregunta/respuesta, pausa y dados ocultos, sin JS/overflow;
bundle SHA igual al sibling, cero beats en esa navegación.
Evidencia privada clarify-testimony[-fixed|-retry]-{before,browser,after}.json,
clarify-testimony-verification.json, compound-retry-navigation.json,
compound-npc-* / invalid-generated-tool-red / compound-and-retry-* logs y
local-full-13.log / hex-full-3.log. No acredita toda semántica, registro durable
de cada respuesta, gramática universal, hardware distinto ni SLA.

## D203 — Parches web y clientes del paquete efectivo

Una copia privada del estado WIP actualiza ambos locks con Mix; no cambia la
fuente de siblings ni stock ReqLLM. Al partir de deps vacías, update no descarga
todos los unchanged y Hex avisa de Mint todavía inaccesible; deps.get completa
el grafo. No son rojos de producto. Build frío imprime deprecaciones de Toml/
Websockex/Postgrex y Logger de dotenvy. No se parchean paquetes publicados.

Control causal de assets:0/3, HTTP404 y módulos CDN antiguos; después22 controles
privados de assets/ajustes/dados/history/HTTP503 pasan. Root reproduce exactamente
los locks de ensayo. Local2736/3 en94,2s,seed682464/max_cases48; Hex2730/3 en58,0s,
seed175437/max_cases48. Ambos sin errores de proceso/desconexiones y con seis
avisos deliberados. Hex descubre15 aliases no usados cuando faltan fixtures v2:
se mueve solo su ámbito dentro de la guarda;2 locales/3 Hex posteriores pasan
sin esos avisos, con mismo comportamiento/assertions. Compiles forzados de
Dragonex dev/prod con warnings-as-errors salen0 sin warnings propios; formato
limpio. `mix hex.audit` sale0 en ambos locks, sin retirados/avisos conocidos;
no certifica seguridad general o carga adversarial.

VM nueva4035 conserva DeepSeek4.1/Decart para los tres roles. Chrome1440/721/375
conecta/recarga, aplica formulario de ajustes, monta3D y libera física/GPU al
cambiar renderizador. HTTP SHA de los tres módulos coincide con sus paquetes;
peticiones JS solo locales, cero JS/overflow. SQLreadonly conserva19425/852/
World/eventos/otra mesa/hero. Sin otro beat pagado. Evidencia privada web-packages-
browser.json, after-web-packages-sql.json y logs root-web-* / local-full-11 /
hex-full-2. Las suites completas preceden al cambio de ámbito de aliases.

## D202 — Resultado legible después de la animación

Chrome/WebGL real con seis dados reproduce3,426/3,951/4,365s frente al antiguo
cierre2,6s. Rojo9/10 conserva el Socket rolling y demuestra que hide lo borraba.
La FSM separa watchdog10s y hold2,6s; controla fase/token, deadlines viejos,
ack tardío/dismiss y resultado factual antes de cerrar sin callback. Dos vistas
de Game conservan World/SQL/eventos.23 focalizados locales y23 Hex verdes;
gate2733/3 en93,0s,seed174475/max_cases48, seis avisos deliberados sin errores
de proceso/desconexiones. Compile dev/prod y formato limpios.

Endpoint privado4036 solo presenta el Dice.stage/FSM/delegados de Show reales;
no crea Game ni ejecuta modelos. Chrome confirma ack3D4,188s/cierre6,972s y
caras3/5/7/9/11/19/total57/DC15. Al bloquear solo el ack de2D, el watchdog revela
a10,436s y mantiene lectura2,802s, luego oculta. Cero JS; endpoint de prueba
cerrado. VM4035 navega1440/375 sin overflow, asset SHA igual al paquete y SQL
readonly conserva19425/852/World/eventos/otra mesa/hero. No acredita física con
duración máxima, hardware distinto o Safari. Artefactos privados dice-timing-before,
dice-live-timeout-browser y after-dice-{game-navigation,sql}.json.

## D200/D201 — Guía de compañeros y frontera de paquetes

Dos grafos: dev/test hermanos y test Hex explícito con deps/build aislados,
producción siempre Hex/mix.hex.lock. Gate local2731/3 con formulario e importación
uniforme tras continuation4:93,0s, seed546348/max_cases48; seis avisos deliberados de
breaker/retry, sin desconexiones ni errores de proceso. Hex2722/3 completo
en56,4s, seed106828, más29 casos de importación final y15/3 focalizados posteriores.
Compile dev y prod Hex sin warnings; formato limpio.

HTTP sintético sobre stock ReqLLM: Game confirma magic missile, recibe503,
repite la tool y termina con una casilla/un daño6/un grupo, cuatro requests.
No representa SSE: esa frontera se prueba por TCP/SSE en el paquete. Otra
regresión reproduce continuation_routing_mismatch con la antigua crónica antes
de HTTP y verifica que importar eventos como memoria user rotulada permite
tool+respuesta y continuidad nativa none, sin aflojar guardas. JSON/visibilidad/
voz/compresión siguen; los controles TestModel son proyección semántica, no wire.
Importación uniforme pasa33 controles locales de historia/conversación y29 Hex.
Paquete actual:78 focalizados verdes; otro subconjunto anterior81 y copia privada
con fuente6402e4a produce3/8 y cinco fallos causales, sin revertir el checkout
compartido. No se afirma una suite completa de exAgent.

Dados:80 Elixir+9 Node, mix build; geometría real Three de todas las caras,
última carga pendiente, fallback exacto d100/fallo, idle/oculto/0px y dispose
idempotente. Chrome usa el bundle real con WebGL/Rapier: caras3/5/7/9/11/19,
RAF detenido al asentarse y física/contexto liberados al cambiar/destruir.
El fixture visual solo vive en el DOM y no envía herramientas al Game.
Endpoint compara SHA de JS/CSS con el paquete efectivo en ambos grafos; una
copia Hex antigua en priv de Dragonex no se sirve. No promete RAM máxima,
hardware, Safari ni 3D autoritativo en el Hex0.2 aún sin esa capacidad.

Ajustes: tres casos preservan config/World/Game ante clave/perfil incompatible
y reinician una mesa pausada con perfil válido. Catálogo no-key termina antes
de instalar credenciales sintéticas, para evitar IO accidental. Formulario
real: rojo0/3, verde3/3; Chrome antes detectaba input fuera de form, después
cero JS. Reload del hermano y cambio de IA conservan la misma VM web y los
bytes SQL en19425/842, otra mesa19439 y hero5164. Tras continuation4 vuelve a
pasar escritorio/móvil/cambio de IA sin JS, sin beats pagados en esa navegación.
Sin hooks en Show.

Consulta D200 real: baseline806→816/5,613s; primer intento v2 816→832 falla
antes de IO por memoria no ligada, conservado como evidencia. Tras adaptar
memoria,832→842/16,903s vuelve al humano, con criterios distintos y sin nuevos
eventos de DM/tools/dados ni cambios World. Modelo/adaptador cambiaron: no
es una comparación causal aislada del prompt. Persiste una imprecisión de
referente en Lyra; no se certifica fidelidad semántica general. DeepSeek4.1/
Decart local y MiMo2.6/io.net Hex pasaron smoke real tool+texto. MiMo local
sigue rechazado antes de IO: stock1.26 no expone reasoning.enabled. Evidencia
privada en dependency-v2; candidata no publicada, beta abierta.

Consulta explícita842→852 con continuation4:14,824s, retorno humano y pausa,
World/prefijo842/otra mesa/hero exactos. PC conserva fuente y duda, pero comparte
casi toda la formulación con el anterior. No hay modificación del prompt entre
ambas consultas: no acredita una corrección general de referentes o variedad.
Evidencia referent-v4-{before,browser,after}.json y browser-restart-continuation4.json.

Guía posterior de acuerdo breve/corrección: rojo5/9, verde20 locales/20 Hex,
sin mutar World y conservada tras compacción/restart. Consulta852→862/9,177s
con DeepSeek4.1/Decart: World/prefijo852/otra mesa/hero exactos, retorno humano
y pausa. Hay algo más de variación, pero ambos repiten datos y Lyra introduce
«dijo de lejos»/«solo encontramos el botón». El «lo» original es ambiguo: no
se certifica brevedad, fidelidad general ni mejora causal de latencia.
Gate posterior2737/3 en92,1s, seed534983/max_cases48, seis avisos deliberados,
cero errores de proceso/desconexiones. Compile dev/prod warnings-as-errors y
formato salen0. Evidencia concise-peer-{before,browser,after}.json,
concise-peer-{red,local,hex,dev-compile,prod-compile}.log y local-full-12.log.

## D199 — Envolturas de testimonio sin renovar memoria

TestimonyQuoteEnvelopeTest añade siete: testimonio real doble aún retenido
al cap30, primera marca/posición; registros nuevos/anidados/espacios; citas
internas y apóstrofos lexicales; legacy sin reloj; citas parciales/desparejadas
con repetición idempotente; vacío/límites raw; fuentes/dudas/marcas literales y
exteriores inválidas. Solo comparación textual; tipos de cita legacy perdidos
no se reconstruyen. Entrada y comparación acotadas a800 antes de desenvuelto.
No cambian autoridad, World/Codec/Rules ni extracción de memoria desde prosa.

GameTestimonyQuoteTest añade dos: tres variantes en beat DM actual conservan
fact37935, request comprueba «TU turno DM», no ejecuta auxiliares ni dados.
Nuevo registro envuelto fija41535/checkpoint; pause/restart cancela petición,
replay conserva resultado y repetición sin envoltura no duplica. SQL/Codec/
recursos/una declaración y checkpoint final vacío. Primer verde8/9 asumía
checkpoint de repetición no-op; segundo8/9 demuestra que pregunta «Sigues…»
consumía modelo humano antes del DM. Se corrigen fixtures a registro nuevo/
pregunta informativa, con comprobación de actor para evitar falso positivo.
No se cambia flujo del producto para acomodar pruebas. Verde9/9. Red posterior
con esas fixtures finales usa fuente exacta D198, hash verificado, obtiene
1/9 (ocho fallos) y restaura fuente final en finally. Logs iniciales separados.
43 focalizados1,6 s limpios; gate final2709/3 en55,9 s,seed30343/max_cases48/
salida0: cero errores/desconexiones/warnings de compile, seis avisos deliberados
(400 simulado×4, pausa breaker, timeout retry). Formato/compile warnings-as-errors/
diff correctos. El gate final verifica verde tras restaurar el código.

Sin beat LLM/QA hook/PNG nuevos. El motor/flujo se comprueba con TestModel/
Game/Postgres y fixture extraída del testimonio real, no con obediencia LLM
arbitraria. SQL readonly antes/después mantiene19425/806/World/eventos/14facts
originales, envoltura doble y primera marca41535 intactas, recursos/plazos/
inventarios/hero; otra mesa World/events completos iguales. Navegación normal
1440/375/ficha/inventario por teclado/reload/modal oculto/lienzo, cero JS/
overflow y sin efectos en mesas. Show conserva hash limpio D194/D198.
Evidencia privada testimony-quote-verification.json. Alcance textual completo
no ambiguo, no significados, cambios de fuente/dudas, referencias expulsadas,
voz original, semántica libre/hardware/Safari/lector de pantalla ni beta lista.
Historia SQL sin atribuir continúa abierta pese a este gate limpio.

## D198 — Fuentes de memoria y prueba real de atribución

TestimonyBriefTest añade cinco: clasificación del formato atribuido con reloj,
legacy sin reloj, envolturas dobles y reloj ilegible; no interpreta el cuerpo.
DM/PC/TM separan fuentes sin perder texto/marcas/orden ni cambiar World/Codec.
Solo testimonios nunca se rotulan como hechos confirmados; guía condicional,
actor/DM y combate. GameTestimonySourceTest añade tres: Game actual pregunta
literal a Lyra/Vex con dado fuera de los400 eventos recientes; guía después
del archivo, fuentes y rol vigentes, solo PCs/sin auxiliares, World/SQL/Codec
igual, una declaración y dado antiguo intacto. Compacción DM/PC con resumen
falso conserva fuente actual y guía, omite diálogo viejo. TestModel comprueba
entrega/estructura; sus respuestas scriptadas no demuestran semántica libre.

Rojo0/8; verde8/8. La generación for role producía aviso de comparación
constante; helper parametrizado lo elimina sin tocar producto.46 focalizados
1,8 s sin avisos/errores. Gate final2700/3 en55,5 s,seed30343/max_cases48/
salida0: cero errores/desconexiones/warnings de compile, seis avisos deliberados
(400 simulado×4, pausa breaker, timeout retry). Formato/compile warnings-as-errors/
diff correctos. Gate posterior a retirada del hook, no se oculta fixture inicial.

19425: regreso772→779/14,314 s añade900 s y escena; muestra hilo779→786/
9,146 s solo añade testimonio41535, sin entrega. Consulta786→796/4,575 s
no toca World, ambos PCs convierten comparación del zagal en observación
propia. La misma pregunta después del cambio796→806/6,616 s atribuye la
comparación al zagal en ambas respuestas; observador pasivo muestra guía/
secciones/fact/inventario/archivo/rol LAST en dos pasos PC y cero tools/TM/
recorder. World exactamente igual. Cuatro acciones772→806, cero dados nuevos;
SQL conserva prefijos772/796, trece facts previos/catorce totales, recursos/
inventarios/plazos, hero y resultados716/724/742/750. Reinicios796/806
mantienen modelos/ajustes/intents/eventos y cierran cinco auxiliares.

Hook exclusivo de creador/token privado retirado; Show hash original. Carga
normal1440/375/teclado/ficha/inventario/modal oculto/lienzo y dos PNG revisados,
cero JS/overflow; reload y SQL confirman ausencia de efectos de navegación en
ambas mesas. No existe baseline completa de19439 anterior a esas acciones:
solo pausa/Thane12; comparación íntegra desde la navegación final. El segundo
request TM del regreso inicia sin cierre medido al cancelarse. La preparación
QA original del regreso falla antes de actuar por guard creator? aún no
asignado en handle_params; pasa a propietario autenticado persistido, luego
se ejecuta cada acción una vez. Journals exclusivos/logs conservados.

Evidencia privada testimony-source-verification.json. Alcance: contexto y
comparación concreta, no todas las fuentes ni voces/detalles solo en prosa.
Comillas externas dobles y deduplicación de envolturas quedan aparte; legado
sin reescribir, no extracción de facts, no Rules/Codec/migración nuevos.
Historia SQL sin atribuir y beta siguen abiertas pese a este gate limpio.

## D197 — Permiso de efectos directos y nivel

DirectEffectAuthorityTest añade nueve: cinco tools rechazan actor propio/aliado
Mara/Lyra, conservando World; actor nil/DM/PC con SharedState ilegible confirma
rechazo antes de leer World o target/RNG. DM mantiene curación nativa/maxHP,
no stacking de PG temporales y condiciones. Segundo aliento PC en combate
mantiene bonus/uso único y no repite; False Life conserva slot/d4/3600 s y
rechaza sin recurso. Rojo3/9, seis fallos reales: heal alcanza RNG, acceso
compartido prematuro y cuatro efectos/subida aplicados. Verde9/9.

Una fixture antigua de ToolsLevelUpTest tenía human_pcs pero no actor:12/13.
Se da handle DM cuyo Session es ilegible, conserva aviso de ficha sin World
read;13/13. GameDirectEffectAuthorityTest añade dos rutas normal/restart con
cinco tools rechazadas antes del hechizo válido. False Life da temp8, paga slot
una vez y fija44235 desde reloj40635; veneno/aliada/nivel intactos. DM bloqueado,
restart cancela petición vieja y conserva pago; curación posterior registra
solo su d4, no repite hechizo. World/SQL/Codec/checkpoint/una acción coinciden.
15 verdes0,4 s. No hay JSON alias nuevo ni cambios en deps/Rules/Codec.

103 focalizados3,2 s sin avisos/errores. El comando incluía un path de replay
inexistente que Mix ignora;103 solo cuenta archivos existentes, no se atribuye
cobertura a ese path. Gate completo2692/3 en56,2 s, seed30343/max_cases48/
salida0, cero errores/desconexiones/warnings de compile. Seis avisos deliberados:
cuatro400 simulados, pausa breaker y retry timeout. Formato/check-format/compile
warnings-as-errors/diff0. No hook temporal nuevo.

No hay beat LLM nuevo: permiso verificado por TestModel/Session/Game/Postgres.
SQL readonly conserva19425/772/World/events/recursos/hero/facts y otra mesa.
Navegación normal1440/375 conectada/pausada, modal oculto/lienzo presente,
cero JS/overflow; sin PNG nuevos ni cambio UI. Evidencia privada direct-effect-
authority-* y direct-effect-authority-verification.json, modo600. D195/D196
conservan evidencia histórica por hashes aunque Tools/docs evolucionen.

AC-21.4 entregado para las cinco tools. Se restringe permiso PC propio D36.
No acredita fuente/coste de toda adjudicación DM ni completa agencia/semántica
libre/memoria/voz/latencia/hardware/Safari/lector de pantalla o beta lista.

## D196 — Autoridad sobre criaturas y combate

CombatAuthorityTest añade nueve: cada tool spawn_monster/roll_initiative/
end_combat rechaza Mara/Lyra/Vex en exploración y combate; no-DM nil/DM/PC con
SharedState ilegible confirma rechazo antes de acceso o RNG. DM crea enemigo,
inicia y termina por engine con recursos/reloj conservados; refuerzo se une
al final sin otra tirada ni mover current/acted. Rojo inicial2/5 y ampliado2/9,
siete fallos funcionales (creación/fin efectivo/RNG/acceso compartido); verde9/9.

GameCombatAuthorityTest añade dos rutas normal/restart: humano llama las tres
tools, feedback directivo, no enemigo nuevo/ni dados/ni cambios mecánicos en
World/SQL antes del DM. Reinicio conserva declaración y anula la petición vieja.
DM spawn posterior crea Goblin, no Invasor, y motor toma iniciativa nativa una
vez por participante; recursos/checkpoint/Codec/eventos iguales. Primer9/11
supuso orden de roller Mara/Goblin; Actions usa nombre canónico Goblin/Mara.
Esa ejecución de fixture registra dos avisos, conservados en su log.
Fixture corregida,11/11 en0,4 s sin avisos; no se altera Rules para satisfacer el test.

99 focalizados2,8 s sin avisos/errores; gate completo2681/3 en55,8 s,
seed30343/max_cases48/salida0, cero errores/desconexiones/warnings de compile.
Seis avisos deliberados: cuatro400 simulados, pausa breaker, retry timeout.
Formato/check-format/compile warnings-as-errors/diff0. No hook temporal nuevo.

No se ejecuta nuevo beat LLM: permiso comprobado en TestModel/Session/Game/
Postgres, incluido reinicio. SQL readonly conserva la partida19425 en772
exactamente como D195, con recursos/eventos/facts/hero y otra mesa intactos.
Rutas normales1440/375 conectadas/pausadas, modal oculto/lienzo presente, cero
JS/overflow; no nuevos PNG ni cambios UI. Evidencia privada combat-authority-*
y combat-authority-verification.json, modo600. D195 conserva su evidencia
histórica por hashes aunque Tools/docs continúan evolucionando en D196.

AC-22.3 entregado para esas tres tools. No audita condiciones/curación/nivel
ni prueba semántica libre/latencia/hardware/Safari/lector de pantalla o beta lista.

## D195 — Confirmación canónica por DM

Siete nuevos: FactAgencyTest rechaza actores humano/PC y guardas antes de
SharedState ilegible (nil/DM/PC); set_scene también requiere dm.
FactInstructionTest cubre separación descubrimiento/prueba/testimonio/rol y
combate sin guía. GameFactAuthorityTest resuelve12+3=15vs15, rechaza ambas
tools del humano antes del DM, confirma fact/revisión mediante DM, preserva
native/checkpoint/SQL/recursos y reinicia entre rechazo y confirmación sin
otra tirada. Archivo bounded real (401 eventos y un dado antiguo23 distinto
al actual15) precede guía final. Compacción DM/PC conserva pista canónica y
un testimonio legacy aunque resumen omita la prosa antigua.

Rojo pure3/7; segunda ejecución3/10 mezcla dos errores de fixture JSON y un
warning del handle falso. Tras corregir harness, rojo funcional3/10 confirma
siete fallos de contrato; verde10/10. Se añade compacción y dos fixtures
históricos pasan de escena humana a DM: primer focalizado46/47, luego47/47;
primer gate2669/2670 en54,6 s detecta otra fixture antigua.54 focalizados3,0 s
finales y gate limpio sin hook2670/3 en54,6 s, seed30343/max_cases48/salida0.
Cero errores/desconexiones/warnings de compile; seis avisos deliberados
(cuatro400 simulados, pausa breaker y retry timeout). Formato/check-format/
compile warnings-as-errors/diff0. No se ocultan ejecuciones fallidas.

Live19425: consulta729→739/5,585 s, World igual; nueva inspección739→747/
18,745 s da12+3=15vs15 y humano registra fact antes del DM, causa real D195.
Después del cambio inspección747→755/14,695 s native75017+3=20vs15: humano
solo ability_check, guía final propia, DM guía de memoria, World igual.
Detalles nuevos del hilo solo en narración: no acredita registro de cada pista.
Recogida755→762/16,282 s: DM grant_item/hilo×1, recorder4,783 s/espina vacía,
facts/recursos/reloj iguales. Consulta762→772/5,593 s solo PCs, sin tools/dados/
cambioWorld; posesión no demuestra dueño, voces casi repetidas y Vex refuerza
recencia tentativa. Tres probes finished/caps restauradas, roles DM/PC al final
tras archivo; TM sin AgentInstructions. Segundo request TM sin cierre medido.

Restart772 conserva World/events1..772/modelos reales/ajustes/intents/hero y
cierra cinco auxiliares. SQL readonly acredita prefijos729/747, recursos/facts
legacy, hilo único solo en Mara, clock40635, checkpoints vacíos y otra mesa
intacta. Un cierre QA se pidió antes de pausa: termina el mismo observer al
acabar, sin replay de acción. Dos preparaciones de browser fallan antes del
click y la recogida se ejecuta una vez. Logs separados conservados. Hook
retirado/Show idéntico a D194; rutas normales1440/375/reload/teclado/ficha/
inventario/dos PNG revisados, cero JS/overflow, sin actuar desde esa revisión.

Evidencia privada fact-authority-* y fact-authority-verification.json, modo600.
AC-25.6 entregado solo para establish_fact/set_scene. Auditoría del resto de
mutadores humanos, voz/dudas/memoria/latencia y beta continúan; no certifica
semántica libre ni hardware/Safari/lector de pantalla.

## D194 — Diálogo de dados y timers por generación

Ocho nuevos DiceTest: fallback reemplazado/cancelado; cierre ya disparado no
oculta grupo posterior; dismiss invalida flush entregado; duplicado no empuja;
fallback limpia rolling/cards/hand/timers; hooks ocultos/antes de flush no
rearman; caller real formatea DC/CA atom/JSON; diálogo/aria/lienzo/cierre/foco.
GameDiceDialogTest nuevo monta dos LiveViews, refresh conserva generación,
mensajes antiguos/unversionados no cierran, cierre local no afecta otra vista,
fallback permite alternar motor y World/SQL/eventos/turno permanecen iguales.
La fixture PubSub es solo UI y no simula un evento persistido del motor.

Rojo inicial0/8: seis fallos reales y dos harness (Floki no instalado). Primer
verde6/8 aún harness; LazyHTML7/8 revela aria-hidden false omitido por HEEX.
String explícito corrige producto: nueve verdes0,4 s. Intento inicial con ruta
test inexistente y logs intermedios conservados, sin contarlos como evidencia
roja funcional.59 focalizados4,9 s. Gate intermedio con hook2663/3 en53,9 s;
final sin hook2663/3 en54,6 s, seed30343/max_cases48/salida0. Cero errores,
desconexiones o warnings de compile, seis avisos deliberados (cinco breaker,
un retry timeout). Formato/check-format/compile warnings-as-errors/diff0.

Live19425 investigación713→721/13,477 s: native716,16+3=19vs15 éxito, World
igual. Probe expirado tras acción, finalGame/SQL independiente acredita pausa;
no se repite investigación. Replay solo UI716 con dos sesiones1440/375 prueba
rol/nombre/DC/19, Tab/Shift+Tab/Escape/Enter/foco restaurado/44 px/lienzo montado,
sin nuevas tiradas ni cambiosWorld/events. Tres PNG revisados, uno baseline.
Seguimiento721→729/17,729 s: native724,6+1=7vs15 fallo, Escape funciona,
avanza900 s/recorder3,997 s, rastro perdido y retorno humano. Probe finished
restaura caps; DM/PC mantienen AgentInstructions LAST, TM sigue sin esa cap.
No incluye cierre medido de request TM paso2 tras decisión. Restart preserva
World729/seq1..729/roles/modelos/ajustes/intents/hero y cierra cinco auxiliares.
SQL readonly verifica prefijo721, recursos/inventario/facts/hero/otra mesa;
solo scene/log/elapsed_seconds cambian y UI no persiste tokens. Hook retirado,
Show limpio/reload normal antes de gate final. Evidencia privada dice-dialog-*
y dice-dialog-verification.json, archivos privados600.

Detector manual una vez: seis avisos heredados fuera de cambio, revisados;
ningún defecto nuevo en targets. Conserva estética D84; transición de barra
sigue fuera de esta entrega. Chrome2D/teclado no certifica Safari/hardware/
lector de pantalla ni callbacks3D sin generación después de flush posterior.
Investigación solo añadió prosa, no facts: memoria semántica de pistas y
latencia/beta siguen abiertas. AC-14.4 entregado con ese alcance.

## D193 — Referencia temporal del testimonio

Cinco nuevos en npc_statement_test: reloj de registro distinto del actual tras
86400 s/JSON/brief DM/PC/TM; duplicado normalizado mantiene primera marca y
nueva versión recibe otra; legado sin backfill; etiqueta dentro de cita y
puntuación literal; cap30 conserva posición al repetir y expulsa con versión
nueva. Una referencia expulsada no sobrevive en un archivo oculto.
GameNPCStatement existente usa37935 y comprueba SQL/checkpoint/replay/restart;
compacción DM/PC omite diálogo después de86400 s pero mantiene fact/marca37935
junto al reloj124335. Assertions previas conservan contenido y añaden formato.

Rojo7/11 inicial para cuatro casos;22 verdes1,4 s antes de añadir cap.94 finales
2,5 s. Un intento intermedio falla al compilar Regex/D: ancla\z válida corrige
la sintaxis, log retenido. Gate con Show limpio2654/3 en54,8 s/seed30343/
max_cases48/salida0: cero errores/desconexiones/warnings de compile, seis avisos
deliberados (cinco breaker, timeout). Formato/compile warnings-as-errors/diff.

Live19425: retorno682→689/15,299 s y viaje696→703/17,905 s aplican900 s cada uno,
recorders6,491/5,387 s actualizan escena. Pregunta689→696/5,599 s solo DM con
record_npc_statement añade versión sobre ir solo/38835, sin otros cambios.
Consulta703→713/6,097 s solo Lyra/Vex, ambos requests contienen marca y rol
propio; distinguen testimonio/prueba. World39735 intacto. El testimonio live
nuevo no contiene «hace dos días»: envejecimiento de esa expresión solo está
probado offline; no afirmar exactitud temporal libre del modelo ni benchmark.

Restart713 conserva World/historia/modelos/ajustes/hero/cierra cinco auxiliares.
SQL prefijo682/recursos/inventario/once facts previos/dados intactos; nuevo fact,
log/escena/1800 s. Marca38835 tiene900 s de edad; no backfill. Hook retirado/Show
exacto antes de navegar; reload1440/375/teclado/ficha/inventario/compañeros,
dos PNG revisados sin JS/overflow. Evidencia privada npc-clock-* y
testimony-clock-{red,compile-red,green,focused,focused-final,full}.log/
verification.json. AC-25.5b entregado; memoria/semántica/latencia/beta acotadas.

## D192 — Preguntas informativas con preposición

Seis casos nuevos en npc_literal_speech/pc_literal_speech y sus Game tests:
formas naturales/voz exacta, prioridad de nombres/solicitudes/acción/duración
excluidas, PNJ con testimonio/contexto/retorno y ambos PCs con identidad/cola/
cierre sin humano/DM/TM. Restart bloqueado añade la nueva pregunta en ambas
rutas; False Life mixto añade preposición y conserva casilla/PG temporales/dado.
No cambia las reglas, Conversation, Codec ni la política de hechos atribuidos.

Rojo20/26, verde26/26 en1,7 s;86 focalizados4,1 s. Gate2649/3 en55,3 s,
seed30343/max_cases48/salida0: cero errores/desconexiones/warnings de compile,
seis avisos deliberados (cinco breaker y timeout de prueba). Formato/diff y
compile warnings-as-errors correctos. No cierra la incidencia SQL histórica.

Live19425:651→658 original11,742 s agrega gesto humano. Probe inicial parcial
por KeyError de params.tools: conserva tres respuestas/usage pero no requests
iniciales/bytes. Preparación previa falló por asumir AgentInstructions en TM;
se restaura antes de actuar. Otro observer expira sin trace/acción; se comprueba
Game/World/seq658 antes de rearmar. Fallos QA no se ocultan ni se atribuyen al
producto. Callbacks solo observan/devuelven originales y no guardan credenciales.

Corrección658→665/6,123 s: palabras exactas, solo DM con fallo transitorio/reintento,
una respuesta4,938 s; World igual. Viaje665→672/15,268 s: advance_time900/set_scene,
clock37935, sin recorder; TM da turno y D79 cancela petición posterior. No asignar
usage/duración de respuesta a ese request sin stop. Consulta672→682/5,056 s:
Lyra2,597 s/Vex2,090 s y solo esos runs, habla/pista/World intactos, cero tools.
Requests efectivos proyectados conservan facts, investigación y archivo cuando
corresponde; bytes de messages JSON no equivalen a cuerpo HTTP/prompt completo.
AgentInstructions último DM/PC; TM carece de esa capability. Sin reducir400/32
ni usar estas duraciones como benchmark causal/SLA.

Restart inicial/final conserva World/historial/cursor/intents/modelos/ajustes/hero,
cierra cinco auxiliares. SQL prefijo651 y682 secuencias conserva personajes/
inventario/facts anteriores/cero nuevos dados; un testimonio y escena/log/900 s.
Hook retirado/Show exacto antes de navegar normalmente; reload1440/375, propio
inventario/ficha/compañeros por teclado y dos PNG revisados, cero JS/overflow.
Evidencia privada npc-pacing-* y prepositional-question-{red,green,focused,full}.log/
verification.json. AC-31.2h2/32.1b entregados; gramática/coherencia/latencia/beta
con los límites documentados.

## D191 — Etapas de espera y fallo posterior a pausa

Ocho regresiones nuevas: Game3 cubre actor/review, Task/turn_id falsos o antiguos,
idempotencia, pausa/reanudación, TurnMaster con cursor DM y restart durante
recorder sin duplicar inventario/final. LiveView4 cubre status/polite, dos vistas/
reload/borrador, cursor/chunks tardíos, permisos, relevo, backoff real y proveedor
bloqueado cuyo error llega tras pause (SQL/World/eventos intactos). Retry1 comprueba la proyección durante
backoff/pausa y recuperación. No se duerme60 s: se dispara el mensaje del turno
vigente para completar el caso. Modelos de prueba sin red; contador supervisado
hasta cerrar la vista/Game, preservando el orden del SQL sandbox.

Rojo0/5 inicial; los casos web de retry dan2/4 y prueban falta de broadcast y
status running tras pause. Entradas de etapas avisan y backoff conserva paused.
71 focalizados7,8 s;2643/3 en53,3 s, seed30343/max_cases48/salida0, cero errores/
desconexiones/warnings de compilación. Seis avisos deliberados: cinco breaker
y un timeout de prueba. Compile warnings-as-errors/formato/diff correctos.

19425 reinicia preservando637 eventos/World/cursor/intents/modelos/ajustes/hero,
cierra cinco auxiliares. Dejar637→644/22,159 s y recoger644→651/27,396 s:
stock0→1, narraciones finales643/650 únicas. Observer24 snapshots y MutationObserver
en ambas vistas1440/375 confirman review/TM con narración ya publicada, sin
cursor y con status/polite. Duraciones describen recorrido/UI, no peticiones
individuales ni comparación causal de latencia. Cuatro PNG revisados, reload/
borrador/ficha/inventario por teclado; SQL conserva prefijo637, recursos/
inventario final/facts/clock37035/hero y cero dados nuevos. Solo escena/log cambian.
Hook retirado/Show de producto exacto; navegación normal también después del
arreglo final de retry. Evidencia privada busy-stage-verification.json,
busy-stage-live-{baseline,final,runtime,browser,audit}.json y logs. Beta activa.

## D190 — Inventario, replay y revisión de escena

22 casos nuevos: inventory_test8 valida operaciones puras/límites/contexto/
Codec/progresión/brief; inventory_tools_test2 prueba rol y schema; Game4 prueba
dos beats, petición PNJ pendiente y grant/remove confirmados con restart/PID
nuevo/replay NFC/case/espacios único. inventory_scene_review_test4 comprueba
huella durable/Codec, rechazo sin prueba/con otros cambios, contexto recorder
y commit exacto frente a World cambiado. inventory_instruction_test2 comprueba
acción visible/no respondida/acotada/saneada y exclusión de combate/otros roles.
LiveView2 comprueba ambas fichas propias/labels/escape, Game confirmado/reload
y héroe reusable intacto. Ningún escritor se añade a UI ni a Heroes.

Rojo inicial0/10 sin APIs, control replay1/3 y huella3/4, con fuentes restauradas
exactas. Contrato por turno3/4 en rojo antes de añadir contexto.22 finales0,8 s;
110 regresiones2,8 s; gate2635/3 en52,6 s/seed30343/max_cases48/salida0, cero
errores/desconexiones/avisos inesperados, cinco breaker. Formato, compile
warnings-as-errors y diff correctos. No imprimir capturas de estado/modelos
de los gates fallidos: pueden contener credenciales.

Playtest19425 conserva padres hasta552. Investigación552→560 confirma18+3=21
vs15 y dos facts, pero su prepare falló por comparar claves atom/string:
solo SQL/inspección, sin métricas de runs. Recogida560→567 cambia solo prosa.
Primera grant567→574 añade1 sin refrescar suelo; entrega574→581 retira1/revisa
escena. Otro prepare de devolución falla por ruta de fixture incorrecta:
acción581→588 comprobada, sin observer efectivo ni repetición.588→595 registra
intento humano de grant rechazado y omisión DM. Contrato de turno595→602 añade1;
dejar602→609 todavía omite tool. El ajuste final coloca contexto real visible
tras archivo de dados:609→616 retira1/revisa y616→623 añade1/set_scene.

Reprueba de formulación original623→630: remove_item1,44,104 s, recorder
iniciado pero timeout20 s, stock0 y revisión pendiente; no inferir run completado
de ausencia de scene_stop. Nueva recogida630→637: grant_item1,28,626 s y
recorder3,634 s/pendiente false. Sin PG/slots/reloj extra, sin nuevos dados
salvo555. Reinicio final conserva World/637 eventos/cursor/intents/modelos/
ajustes/hero y cierra cinco auxiliares; SQL solo lectura/reload375/1440/teclado,
22 PNG revisados. Hooks retirados, Show restaurado byte por byte. Evidencia
privada inventory-verification.json, inventory-audit.json y north-inventory-*.
No comparación controlada de latencia ni garantía universal del LLM; beta activa.

## D189 — Oficios PNJ con prioridad de las identidades PC

text_npc_question_test.exs añade oficios/complementos cortos y colisiones
PC/NFC/límites de palabra; npc_literal_speech_test.exs añade habla exacta y
acciones/espera con duración excluidas. game_npc_literal_speech_test.exs añade
request PNJ efectivo/testimonio/World, jugador «El Zagal» con resolución humana
y restart pendiente/PID nuevo/sin duplicados. Su magia mixta incluye el zagal,
manteniendo casilla/dado únicos. No se presupone un evento tool_result: el
contrato comprueba ejecución modelo, fact atribuido, voces y World persistido.

Rojo9/14 en2,9 s, verde14/14 en0,8 s. Controles roles9/14 en2,9 s y sin roster
13/14 en0,8 s; fuentes restauradas exactas, sin errores.43 focalizados2,5 s;
2613/3 en52,6 s/salida0/seed30343/max_cases48, cero errores/desconexiones/avisos
inesperados, cinco breaker. Formato/compile warnings-as-errors/diff correctos.

Playtest19425: viaje531→538/15,261 s/advance_time900 s, reloj36135→37035,
recorder3,015 s y escena molino; solo reloj/log/escena cambian. Pregunta inicial
538→545/16,811 s tiene humano un paso/DM dos/TM decisión válida con cancelación
temprana. Nueva pregunta545→552/7,109 s tiene un único DM/dos pasos y
record_npc_statement, habla exacta y cero humano/PC/TM/recorder/dados. Solo
facts cambian en ambas consultas; hero/modelos/recursos íntegros. Scrub elimina
etiquetas del raw DM y clean coincide con persistido. Testimonio conserva fuente.

Reinicio público cierra cinco auxiliares, conserva estado/eventos/cursor/intents/
modelos/ajustes; resume/pause no añade eventos. SQL solo lectura verifica552
eventos/World/cursor/pausa, también19439 pausada. Reload375/1440/teclado y ocho
capturas revisadas sin JS/overflow. Hook retirado/Show exacto; evidencia privada
npc-occupations-verification.json. Roles/gramática acotados, muestras diferentes
sin benchmark causal, sin verdad PNJ ni memoria ilimitada/beta certificada.

## D188 — Habla informativa/opinión PC fiel al texto consumido

pc_literal_speech_test.exs añade dos casos de formas reales/guardas manuales;
game_pc_literal_speech_test.exs añade request efectivo a ambos PCs y opinión+
False Life con coste/dado únicos. Su restart recorre memoria/opinión, PID nuevo,
run anterior terminado y una sola habla/turno humano. El caso de preferencias
ahora exige cero humano/DM y texto exacto. Fixtures de visibilidad/archivo y
narrador bloqueado/fallido añaden declaración propia para probar realmente la
ruta humana; el callback que falla se observa. El contador del intercambio
excluye la narración inicial DM existente, sin borrar eventos.

Rojo6/10/control memory-only6/10 en0,7 s, fuente restaurada exacta, sin errores/
avisos.25 cercanos2,2 s;77 focalizados4,8 s;2607/3 en52,2 s/salida0,
seed30343/max_cases48, cero errores/desconexiones/avisos inesperados, cinco
breaker. Formato/compile warnings-as-errors/diff correctos.

Playtest19425: pregunta a Maribel504→511/6,095 s/DM dos pasos/una tool añade
solo testimonio del cruce; era alternativa no llega a facts. Opinión original
511→521/6,109 s/tres runs modifica habla e inventa esperar a Maribel. Con el
cambio521→531/4,053 s/dos runs PC/un paso: habla exacta, World/clock36135/hero/
modelos/history DM iguales, cero otros/tools/dados. Raw PC/scrub/persistido
coinciden; DM inicial elimina etiquetas por scrub. Nuevo testimonio se conserva
tras restart y no confirma su contenido. Cinco auxiliares cerrados, estado/
eventos/cursor/intents/modelos/ajustes íntegros y resume/pause sin eventos.
SQL solo lectura, UTF-8/JSON/reload375/1440/teclado y ocho capturas revisadas,
hook retirado/Show exacto; pc-opinion-literal-verification.json privado.
No benchmark causal, acuerdo/viaje automático, originalidad universal o memoria
completa PNJ. Próximo: viaje explícito/tiempo/entorno y zagal; beta sigue activa.

## D187 — PC responde sin conflicto con la proactividad o el antibucle

pc_anti_loop_test.exs añade cuatro casos DB: últimas dos narraciones/cita última,
duplicados viejos con respuestas recientes distintas, privados al principio/final
del bloque y nudge de respuesta que permite datos repetidos sin nuevas acciones.
pc_response_voice_test.exs amplía contrato de prefijo/instrucción, conservando
scope normal/combate/caído. game_pc_response_pacing_test.exs añade dos Games
supervisados/try-after con nudge activado en ambos PCs y mensajes del proveedor:
voz propia, pregunta, predecesor, contrato coherente y World entero intacto.
Reinicio durante Lyra termina run antiguo/PID distinto, conserva pendientes y
una narración por actor, sin repetir habla humana ni solicitar DM/TM. El marcador
de turno del intento recuperado existe legítimamente; se corrige el oráculo.

Rojo3/10 en0,5 s y verde10/10 en0,5 s. Controles contexto Game desviado a :scene
8/10 en0,4 s y filtro privado retirado9/10 en0,5 s, fuentes restauradas exactas;
cero errores de log.96 adyacentes en3,8 s, incluidas consultas/peticiones PNJ,
combate/caído y archivo antiguo. Gate2603/3 en51,0 s salió143 tras informar verde:
no se declara cierre ni se atribuye causa. Repetición2603/3 en51,1 s/salida0,
seed30343/max_cases48, cero errores/desconexiones/avisos inesperados y cinco
breaker deliberados. Formato/compile warnings-as-errors/diff correctos.

19425: primer browser3,997 s con hook que no ejecutó (assign incorrecto), sin
contar runs ni afirmar prefijo reconstruido. Se corrige la coincidencia del
socket y cada stage exige su artefacto. Reinicio previo conserva modelos/
ajustes/World/events y reconstruye prefijos. Dos preguntas instrumentadas
4,530/4,013 s:484→494→504, dos runs PC/un paso y cero humano/DM/TM/recorder/
tools/dados. Sin gesto de jarra; cifras20 natural/25 vs15/18 correctas en pregunta
numérica. Nudge no activado en estas muestras; rama y prefijo efectivo probados
offline. World/clock36135/hero/modelos/history DM íntegros, archivo24–25 presente,
raw/scrub/persistido iguales/UTF-8/JSON válidos. Reinicio final cierra cinco
auxiliares y conserva todo, resume/pause sin eventos. SQL solo lectura/reload
375/1440/teclado/fichas, seis capturas revisadas sin JS/overflow. Hook retirado,
Show exacto; pc-response-pacing-verification.json privado. Fórmulas compartidas
y posibles huidas narradas siguen abiertas; sin originalidad/SLA/beta garantizadas.

## D186 — Tiradas antiguas en el mensaje actual, fuera de compresión

history_roll_memory_test.exs: seis casos de archivo con crítico/daño original,
orden/límite32 tras visibilidad/deduplicación, corte y grupo partido, tipos/
seq/payload desconocidos, muerte/subtotal negativo. Un Server DM con threshold1/
keep1/Summary real recibe cifras completas en el mensaje actual y su prefijo;
el summarizer solo devuelve taberna en calma. Evita confiar en que un resumen
LLM conserve números del motor. UTF-8 y representación JSON preservados.
games_roll_memory_test.exs: dos casos DB de filtro partida/audiencia antes del
límite, tope32 aun pidiendo64 y recuperación fuera de410 notas posteriores sin
modificar el log. Un oráculo comparaba payload átomo recién insertado con JSON
leído: usa el evento reconsultado, sin cambiar implementación para ajustarlo.
game_roll_memory_test.exs: dos Games supervisados/try-after, crítico/daño desde
Actions/RollLog y muerto confirmado. Se desplazan fuera de400; requests efectivos
humano/Lyra/Vex/DM muestran archivo en WORLD con audiencia correcta. Reinicio
durante Lyra conserva cola, un habla por actor y cero nuevas tiradas/World cambios.

Primer rojo0/9 en0,6 s antes de API; versión inicial en history era compactable.
Mover al prompt y añadir compresión real deja10/10 en0,7 s limpios. Controles
finales archivo suprimido8/10, filtro SQL de audiencia antes del límite retirado
9/10, ambos0,6 s/cero errores/avisos y fuentes restauradas exactas.77 adyacentes
en5,2 s;2597/3 en50,1 s/seed30343/max_cases48, cero errores/desconexiones/avisos
inesperados, cinco breaker. Formato/compile warnings-as-errors/diff correctos.
Migración9/índice parcial dice aplicado dev/test, sin cambios de datos.

SQL previo19425:55–454 ya excluye24–25. Dos preguntas6,615/5,057 s, dos runs PC/
un paso y cero humano/DM/TM/recorder/tools/dados,454→464→474. Ambos mensajes WORLD
contienen20+5=25 vsCA15 y4d6(1,2,6,6)+3=18/crit con seq original. Primera prosa
sin cifras; petición numérica obtiene20 natural/25 contra15/18 de ambas voces,
contrastados con eventos persistidos. Gestos de jarra copiados siguen abiertos.
World/clock36135/hero/modelos/history DM iguales; dos reinicios conservan
World/events/cursor/intents/modelos/ajustes, cierran cinco auxiliares cada uno
y no añaden eventos al resume/pause. UTF-8/JSON, SQL solo lectura,375/1440 px/
teclado/ficha/compañeros y ocho capturas revisadas sin JS/overflow; hooks retirados/
Show exacto. Evidencia privada roll-memory-verification.json. Server.history
excluye system efímero; compresión forzada/prefix real cubiertos offline.
32 tiradas no acreditan archivo de escenas/testimonios o memoria ilimitada.
Sin SLA, hardware/Safari ni beta; continuar prosa y consecuencias PNJ.

## D185 — Visibilidad en requests efectivos de cada rol

history_visibility_test.exs: cinco casos de visibilidad para narración/acción/
dado/system/turn, audiencias desconocidas/ausentes, headers privados, compresión
pública y request real recorder. Default/PC solo all; DM explícito all/dm.
game_history_visibility_test.exs: dos Games supervisados con cierre try/after,
requests efectivos humano/Lyra/Vex/DM y role prefix. Humano usa Server DM pero
recibe público. Reinicio durante Lyra termina run antiguo, rehidrata pendientes
y conserva una final por actor, World/DB y todas las notas originales.

Primer fixture olvidaba que humano/DM comparten script y registró un aviso por
agotamiento. Preparación corregida, antes del fix0/7 en0,3 s limpio; verde7/7
en0,3 s. Controles negativos mantienen API de audiencia pero desactivan filtro
0/7, y omiten participante en Beats5/7; ambos0,3 s, cero errores/avisos y
fuentes restauradas byte a byte.67 adyacentes en4,7 s, incluido historial,
compresión UTF-8, crítico, entrega system/compaction, conversaciones/cierre
local, recorder, permisos web/paginación.2587/3 en50,5 s/seed30343/max_cases48:
cero errores/desconexiones/avisos inesperados, cinco breaker deliberados.
Formato/compile warnings-as-errors/diff correctos.

Reload19425 a375/1440/teclado conserva última Vex453/ficha/compañeros; dos
capturas revisadas sin JS/overflow. SQL solo lectura verifica World/cursor/
pausa y454 eventos iguales a D184;19439 sigue pausada. Sin hooks ni nueva
conversación/eventos o proveedor. Privacidad probada en requests TestModel,
sin confundir con captura live. Evidencia privada history-visibility-verification.json.
No clasifica secretos dentro de facts/story_bible; memoria fuera de400 y
consecuencias PNJ/beta siguen abiertas. Sin SLA ni hardware/Safari.

## D184 — Cierre local acreditado, sin beat DM

conversation_closure_test.exs: seis casos puros de parser/World/Codec/transcript,
huella determinista tras JSON, controles manuales y legacy. Cambiar escena,
reloj, hechos, log, PG/casillas/descanso/combate impide cierre. Checkpoint solo
no lo impide. Eventos desconocidos/parciales/duplicados, otra pregunta PC,
otra persona/acción o anchor perdido mantienen DM. Hash/seq inválidos se
descartan sin borrar la pregunta; un world_recipient no conserva quiet_close.

game_conversation_closure_test.exs: ocho Games del supervisor público, con
cierre try/after. Dos respuestas/rol system propio sin DM; reinicio mientras
Lyra está bloqueada con PID nuevo y cola durable; habilidad con dado y World
intacto que mantiene DM; False Life paga/tira una vez; preferencia usa narrador
humano pero no DM; PC abre pregunta PNJ; Cora declara entre ambos PCs, recibe
turno antes de Vex y conserva cierre DM; fallo terminal/consulta mixta tampoco
cierran localmente. La regresión del encargo de agua en game_explicit_question
detecta la admisión demasiado amplia y mantiene su expectativa DM intacta.

Tests D182/History/habla pura pasan a esperar Mara/PCs/retorno. D183 usa una
cláusula informativa al mundo para seguir ejercitando realmente el beat DM y
su nudge/reinicio. Control negativo final omite exclusivamente closing_events
de la prueba:11/14 en1,0 s, tres positivos Game fallan; fuente restaurada exacta,
cero errores/avisos.69 focalizados en3,7 s;2580/3 en50,9 s/seed30343/max_cases48,
cero errores/desconexiones/avisos inesperados, cinco breaker deliberados.
Formato/compile warnings-as-errors/diff correctos.

19425:434→444→454, diez eventos por consulta, narraciones humano/Lyra/Vex, cero
DM/dados/fallback. Primera7,642 s: observador expiró, no sirve como traza de runs.
Segunda5,574 s con observador terminado normalmente: dos starts/finishes/un
paso PC, cero humano/DM/TM/recorder/tools; history DM hash idéntico. World/
clock36135/hero/modelos íntegros. Restart preserva World/events/cursor/intents/
modelos/ajustes y cierra cinco auxiliares; resume/pause sin eventos. Histories
UTF-8/JSON, SQL solo lectura y375/1440/teclado/ficha/compañeros, cuatro capturas
revisadas, sin JS/overflow. Hook retirado/Show exacto; evidencia privada
quiet-conversation-verification.json. Server.history excluye system efímero;
prefix verificado offline. Sin SLA/hardware/Safari/memoria ilimitada/beta.
Seguir consecuencias PNJ y hechos fuera de la ventana400.

## D183 — Contexto de conversación hasta el corrector anti-repeat

Tres casos en game_conversation_pacing_test.exs observan requests efectivos
con dos narraciones DM iguales previas: cierre/base/nudge sin obligación
sensorial contradictoria, dos intercambios y World/DB conservados. Reinicio del
DM bloqueado conserva la misma guía, termina el run antiguo y no publica otra
vez a los PCs; permite dos marcadores de intento DM, con una sola final.
Un PNJ sigue respondiendo/guardando testimonio atribuido por tool, sin recursos
ni dados. dm_anti_repeat_test.exs mantiene el comportamiento fuera de conversación.

El fixture inicial confundía speaker con source en la tool y contaba como
cierre la narración de apertura; el reinicio marcaba legítimamente otro intento
DM. Se corrige la preparación/oráculo, sin cambiar el motor para ajustarlo.
Control negativo final1/3 en0,4 s por el nudge que ordenaba cambiar olores/luz.
La revisión de solo prompt también falla live: instrucción vieja todavía
antepuesta a la nueva. Contexto explícito desde World resuelve la contradicción.
42 focalizados en3,3 s;2566/3 en49,6 s/seed30343/max_cases48, cero errores/
desconexiones/avisos inesperados y cinco breaker. Formato/compile/diff correctos.

Dos conversaciones19425:7,618/7,605 s, tres runs de un paso, cero humano/TM/
recorder/tools/dados, World/clock36135/hero/modelos iguales,408→421→434. Primera
con prompt nuevo+nudge viejo; segunda no dispara el umbral y no lleva orden
sensorial vieja. Variante nueva disparada cubierta con TestModel. No afirmar
que el nudge activado fue observado live: el cierre final aún incluye tarde
tibia y «sin fisuras». El problema de prosa permanece abierto.

Dos reinicios/cinco auxiliares cada uno conservan World/historial/cursor/
intenciones/hero/modelos/ajustes sin eventos nuevos al reanudar/pausar. UTF-8/
JSON y reload375/1440 px/teclado, ocho capturas revisadas sin JS/overflow; SQL
solo lectura verifica el estado final. Hooks/probe retirados, Show exacto.
Evidencia privada conversation-pacing-verification.json. Server.history no
incluye system efímero; no confundir esa captura con request completo. Sin
SLA/hardware/Safari/memoria ilimitada/beta certificada. Seguir cierre discreto
con guardas del motor, PNJs/efectos vigentes y continuidad fuera de ventana400.

## D182 — Preguntas informativas PC literales y recuperación pendiente

`pc_literal_speech_test.exs`: tres casos con preguntas live, nombres Unicode/
cortos únicos, orden literal y una pregunta de recuerdo/observación; rechazos
para acciones/magia/pagos, dos preguntas, tiempos, preferencias/peticiones,
roles PNJ/ambiguos y guardas de cola manual completa/interrupciones/mini/combat.

`game_pc_literal_speech_test.exs`: tres Games reales del supervisor público,
con cierre en after. Observa los requests efectivos de Lyra y Vex (habla
exacta/pregunta/rol system propio), solo un request DM de cierre, eventos en
orden y World/DB iguales. Bloquea primera respuesta, pausa y reinicia con PID
nuevo: antiguo run termina, cola conservada, humano no se publica otra vez.
El caso mixto pregunta+False Life mantiene la petición humana/herramienta,
PG temporales5, una casilla y un dado; cero tiempo cobrado y DB coherente.

Antes de conectar Beats, cuatro de seis pasan: los dos Game de habla pura
fallan por segunda petición humana/paráfrasis; cero errores/avisos de fixture.
Conectar la ruta da seis en0,5 s;62 adyacentes en2,9 s. Gate2563/3 en50,0 s/
seed30343/max_cases48: cero errores/desconexiones/avisos inesperados, cinco
breaker deliberados. Formato/compile warnings-as-errors/diff correctos.

19425 repite la pregunta inicial D181: habla humana exacta, Lyra/Vex/DM/Mara
7,647 s y tres runs de un paso, ninguno humano/TM/recorder/tools/dados. World
entero/clock36135/hero/modelos iguales,13 eventos395→408. Ambos histories
contienen la voz literal; raw Vex trae encabezado retirado por scrub y
clean=persistido en los tres roles. Captura live desde Server.history sin
system efímero: no confundir con requests efectivos verificados offline.

Reinicio conserva World/historial/actor/intenciones/hero/modelos/ajustes,
cierra cinco auxiliares y no genera eventos al reanudar/pausar. UTF-8/JSON y
reload375/1440 px/teclado/ficha/compañeros, cuatro capturas revisadas sin JS/
overflow. SQL solo lectura confirma estado final. Hook retirado/Show exacto;
evidencia privada `pc-literal-speech-verification.json`. Una muestra no es SLA
ni validación general del modelo;408 eventos aún conservan dados del combate
en la ventana400. Continúan cierre DM repetido y memoria fuera de ventana.

## D181 — Críticos y salvaciones de muerte íntegros en el contexto

`history_roll_outcome_test.exs` genera grupos reales Actions/RollLog y aplica
transiciones: ataque/daño crítico, uno/dos fallos de muerte, acierto/éxito y
revivir. Compara PG/contadores confirmados antes de History con claves átomo
y JSON. Crit conserva su distinción; fail no desaparece y crit_fail conserva
los dos fallos. No infiere desde el d20 ni modifica la resolución de reglas.

`game_history_roll_outcome_test.exs` guarda esos dados, envejece narraciones
y pide respuesta a dos PCs. Verifica las dos líneas completas en sus
peticiones efectivas, junto a su prefijo system propio; World/persistencia/
eventos conservados y ninguna tirada nueva. El primer verde27/28 falló al
cerrar un Game de ExUnit mediante el supervisor global: no reiniciaba realmente.
El fixture final lo detiene con stop_supervised antes del reinicio público,
exige PID distinto y comprueba historial/World después de reanudar/pausar.
No se adapta producción a ese ownership de pruebas.

Control negativo sobre el fixture final, revirtiendo solo el formatter:1/4
en0,2 s, cero errores/avisos. Restaurar da78 focalizados en1,9 s. Gate2557/3
en49,2 s/seed30343/max_cases48, cero errores/desconexiones/avisos inesperados,
cinco breaker deliberados. Formato, compile warnings-as-errors y diff correctos.

Dos conversaciones reales19425: Lyra/Vex y Vex/Lyra, cada uno un turno y
cierre DM/retorno humano;11,791/9,664 s, cuatro runs de un paso, cero
TM/recorder/tools/dados. World entero, reloj36135, héroe y modelos iguales.
History de ambos PCs conserva ataque25/daño18; antes outcome genérico, después
crítico explícito. Ambos recuerdan el crítico. Preguntas distintas: no es
comparación causal de velocidad ni garantía de semántica del modelo.

La captura live de wire se obtiene de Server.history: incluye el contexto
compartido pero no el system efímero añadido al request. No presentarla como
captura completa del request del proveedor; el Game/TestModel verifica esa
entrega efectiva. Raw/clean/persisted PC coinciden en ambos recorridos.395
eventos aún dentro de la ventana reciente400, sin garantía de memoria ilimitada.
Reinicio real conserva World/historial/intenciones/actor/hero/modelos/ajustes
de todos los roles, cierra cinco auxiliares y valida UTF-8/JSON. Reload375/
1440 px/teclado/ficha/compañeros, seis capturas revisadas, sin JS/overflow.
Hook retirado y Show idéntico al backup. Evidencia privada:
`history-roll-outcome-verification.json`. Sin hardware físico/Safari/SLA/beta;
siguientes casos: preguntas PC con gestos humanos añadidos y cierre DM repetido.

## D180 — Presupuesto TurnMaster hasta el request y contraste real

`turnmaster_token_budget_test.exs` añade cuatro casos offline. Un modelo
determinista observa el ModelSettings recibido y requiere259 tokens para
resolver, cifra de una petición real. Game/Bootstrap deben enviar1024 por
defecto o4096 configurado y ceder a Thane sin fallback ni daño. Otra prueba
verifica que la opción explícita256 prevalece; otra cubre vacío/inválido/no
positivo y espacios periféricos. No simula fiabilidad ni razonamiento LLM.

El fixture fija al goblin como combatiente saliente. La versión inicial con
current_combatant=nil daba legítimamente otro turno y agotaba su script:
se corrige la preparación, sin esconder fallos ni modificar el motor.
Revertir solo constructor/Bootstrap sobre el fixture final da1/4 en0,4 s;
restaurar produce77 focalizados en2,3 s/seed30343/max_cases48, limpios.
Gate final2553/3 en50,2 s/mismo seed/max_cases48: cero errores/desconexiones/
avisos inesperados, cinco breaker deliberados. Compile warnings-as-errors,
formato y diff correctos; no se requiere repetir el gate por documentación.

Cuatro runs aislados con proveedor real alternan256/1024 y mantienen todo
World/eventos/modelo/ajustes del agente real idéntico. Primera256:3,636 s,
finish length/output256/cero tools/sin decisión. Segunda1024:4,135 s total,
primera petición259 tokens/give_turn_to. Tercera256 y cuarta1024 deciden
en3,511/2,564 s. No es benchmark; no se atribuye a razonamiento medido porque
la telemetría no separa su consumo. No cambian modelo/routing/temperatura.

Mesa19425: pregunta literal a Maribel devuelve aclaración contextual en
8,13 s, un run DM/un paso, cero humano/TM/recorder y World entero igual.
No exige registrar nueva declaración ni permite confirmar una mentira por
inferencia. Después, presupuesto1024: espera15 s vuelve al humano en9,667 s,
DM un run/dos pasos, TM un run/give_turn_to válido y cancelación terminal
esperada D79. Sin error/fallback/retry. Solo cambian elapsed_seconds36120→36135
y wait_resolution; hechos/escena/recursos/modelos/hero intactos. Tiempos del
observador usan reloj monotónico, sin interpretar duration_ms del proveedor.
Hay además un scene_start/scene_stop: revisión4,261 s, entorno final idéntico.
El contador se conserva en la evidencia; no es un recorrido sin recorder.
Investigar su entrada y resolución de espera antes de inferir redundancia.
Auditoría posterior sin cambios funcionales: WorldClock.advance marca revisión
al avanzar en exploración; SceneRefresh coteja comprobante/huella/estado y
Game revalida antes del commit. Bootstrap ya usa el summarizer para gateways
reales. Conservar D172 y sus casos de hechos/recursos/restart/estado obsoleto:
la igualdad del resultado por sí sola no autoriza saltar esa revisión.

Dos reinicios conservan World/historial/intenciones/actor/modelos y cierran
cinco auxiliares cada uno; final1024/36135/UTF-8/JSON válidos. Reload375/1440
px/teclado/ficha/compañeros, seis capturas revisadas, sin JS/overflow-x.
El primer intento de instrumentación usó un campo current inexistente:
preparación corregida a Game.current, sin writes de World. Hook retirado y
Show idéntico a su copia anterior; módulos privados descargados. Evidencia
privada `turnmaster-budget-verification.json` relaciona runs, oráculos, logs
y límites. Sin hardware físico/Safari/SLA ni certificación de beta.

## D179 — Anchuras intermedias, teclado y ficha propia de combate

Rojo Chrome: a721 px la crónica mide237 px y su texto185 px; tres columnas
empiezan demasiado pronto. DM/Invitar/ajustes/Salir quedan recortados aunque
scrollWidth de página sea correcto. A375 px Invitar queda parcialmente visible
también con Tab nativo: el navegador de esta prueba no desplaza el botón entero.
Ampliar corte compacto a1023 px mejora lectura, pero no resuelve por sí solo
ese foco; TurnControls ajusta únicamente scrollLeft de su barra con margen7 px.

La prueba táctil de combate descubre la ficha propia con geometría cero:
la regla de duplicados oculta el detail_sheet directo. Contenedor propio evita
esa coincidencia. A812×375 la ficha ya aparece, pero PG siguen bajo el recorte;
PG/CA antes de raza/clase completa el caso sin esconder información.
La referencia de longitud usa avance real del carácter0 de la fuente (≤75ch
en geometría), no un límite fijo650 px incompatible con el contrato72ch.
Cerrar/reabrir espera aria-expanded=false antes del segundo Enter para evitar
un falso resultado por observar todavía el estado anterior de LiveView.

Final: ocho tamaños375/721/812/900/1023/1024/1280/1440 y cuatro casos táctiles
emulados con exploración19425/combate19439. Tab completo, ajustes abre/cancela,
drawer/compañeros/reapertura0, input, iniciativa y objetivos44×44 px; sin
overflow-x ni errores JS. Abrir lateral812×375/900×600 no reduce altura de
crónica. Siete capturas revisadas. SQL de solo lectura compara antes/después
World/actor/estado/ronda/intenciones/todos los eventos de las dos mesas pausadas.
No hardware físico ni Safari probados; no cambia reglas, Game ni modelos.

39 focalizados en5,9 s; gate final2549/3 en48,2 s/seed30343/max_cases48,
cero errores/desconexiones/avisos inesperados y cinco breaker deliberados.
Gate anterior48,3 s también limpio. Compile warnings-as-errors/formato/diff
correctos. Detector CSS devuelve seis avisos anteriores (animación steps del
marcador, transición de barra PG y cuatro acentos D84), sin patrones nuevos;
no se presenta como detector vacío ni se rediseña la mesa por esos avisos.
El caso se verifica con navegador, sin tests que repliquen CSS o el hook.
`responsive-table-verification.json` privado enlaza evidencia y límites.

## D178 — Ficha propia visible al reabrir y scroll estable durante patches

Chrome19425 a375/720 despliega compañeros/cierra/reabre por teclado. El rojo
deja PG propios fuera del área recortada del cajón; reordenar solo conserva
scroll209/151 px y sigue fallando. PlayerSheets deja scroll0 únicamente en
cerrado→abierto. Final muestra PG14/14 dentro del área visible y conserva
scroll durante escritura/retirada de borrador; compañeros siguen abiertos.
El oráculo compara geometría contra los límites del rail, no solo contenido
presente en DOM.721/1024/1440 conserva fichas desktop, DM375 conserva Grupo3.
SQL de solo lectura compara World/actor/estado/ronda/intenciones/history
antes/después y contra el cierre D177; reloj36120. Cinco capturas revisadas,
sin JS/overflow-x.721 px aún tiene crónica estrecha/controles recortados;
un scrollWidth de página correcto no acredita todos los controles accesibles.

Primer gate2549/3 en49,4 s: cero errores SQL, seis avisos (cinco breaker y
nil TestModel en game34425/repeat/cripta). El test de voces variadas esperaba
>=3 por polling, podía iniciar una cuarta antes de pausar. Oráculo reforzado
reproduce0/1 con una cuarta narración fallback, aun con el test anterior verde.
Fixture ahora arranca pausado, separa PC/DM y pausa antes de liberar la tercera
respuesta DM. Verifica tres voces exactas, World/DB iguales y log sin fallo;
no cambia reglas ni dependencia.41 focalizados5,2 s, gate final2549/3 en49,3 s/
seed30343/max_cases48 limpio, cinco breaker deliberados. Compile/formato/diff
correctos, detectores mecánicos de los dos targets UI sin hallazgos; diseño
D84 conservado. No añade tests que repliquen el código del hook: el caso se
verifica en navegador real. `mobile-sheet-verification.json` privado enlaza
rojo/intermedio/confirmación/gates y límites.

## D177 — Preguntas literales por lo visto u oído

Dos `npc_observation_question_test.exs` verifican el caso real «¿Viste tú
misma…?», variantes oíste/escuchaste/tú/mayúsculas y conservación exacta;
magia/pago/movimiento/duración/PJ/varias preguntas/persuasión siguen sin
resolver localmente. Un LiveView bloquea la respuesta PNJ y comprueba que
la voz exacta ya está publicada, entrega contexto DM y luego guarda un
testimonio con recursos/entorno/DB/reload íntegros y ninguna petición auxiliar.
Los Game D176 eliminan su fixture humano y mantienen checkpoint/replay/
restart/compacción; False Life mixto se ejecuta con pregunta abierta/cerrada
y mantiene casilla, dado y5 PG temporales.

Rojo1/3 demuestra whitelist incompleto/petición humana. Intermedio11/13:
dos oráculos nuevos incorrectos (herrero fuera de roles D158 y narración
inicial de creación contada como respuesta). Se corrigen fixtures sin
ampliar roles ni alterar la creación. Final32 en1,7 s;2549/3 en49,6 s/
seed30343/max_cases48 sin errores/desconexiones/avisos inesperados, cinco
deliberados breaker. Compile warnings-as-errors/formato/diff correctos.

19425 conserva modelos reales exactos/biblioteca/reloj36120 y publica
«¿Oíste tú misma…?» exacto. Una ejecución DM/dos pasos, cero humano/TM/
recorder;4,538 s hasta retorno. Testimonio nuevo con fuente antes de narrar,
único cambio de World. Reinicio/recargas375/1440 px/teclado conserva World/
historial/intenciones/modelos/UTF-8/JSON y cierra cinco auxiliares; cuatro
capturas revisadas, sin JS/overflow y hook retirado. Biblia de19425 vacía;
zagal/cabras no figuraban allí/historial, sin demostrar contradicción por esa
ausencia. Versión nueva del encuentro con el forastero y ficha propia después
de compañeros en cajón móvil siguen bajo revisión. No prueba SLA ni semántica
universal. Evidencia privada `npc-observation-verification.json`.

## D176 — Fuente y contenido de testimonio PNJ sin confirmación implícita

Siete `npc_statement_test.exs` verifican cambio exclusivo de facts, marca
de revisión previa conservada, reloj/presencia/recursos iguales y Codec;
normalización/idempotencia/citas internas, rechazo de inputs vacíos/tipos/
límites80/800, permisos DM y fuente PJ completa/corta. Una fuente NPC conocida
de prefijo compartido permanece válida; Unicode NFC/NFD no evita el rechazo
de PJ. Ambos argumentos pasan por scrub; una invocación escrita como prosa
se retira antes de persistencia/display. Schema/toolset acotado, sin tool PC.

Tres `game_npc_statement_test.exs` recorren NPC→humano sin TM/recorder ni
cambio físico; guardan atribución antes del final y conservan DB/Codec/
historial/restart. Caída tras guardar pero antes de narrar conserva checkpoint
y replay del resultado sin duplicar hecho/voz/tiempo. Resúmenes que omiten
diálogo dejan el hecho atribuido en los messages DM/PC; las instrucciones de
resumen conservan fuente/dudas. Se comprueba entrega de contexto, no semántica
universal del modelo. En D176 la pregunta cerrada «¿Viste…?» usaba beat humano
según su whitelist: su fixture incluía esa respuesta legítima antes del DM.
El primer fixture incompleto descubrió un nil de TestModel; no se parchea
la dependencia ni el producto para ocultarlo.

Rojos0/6 por tool/API ausentes;0/1 con5 excluidos por invalidación de entorno;
6/7 por invocación visible y6/7 por fuente PJ Unicode equivalente admitida.
Final67 focalizados en1,0 s;2546/3 en49,3 s/seed30343/max_cases48 sin errores/
avisos inesperados, cinco deliberados breaker. Compile warnings-as-errors/
formato/diff correctos.

Playtest19425 conserva modelos reales exactos/biblioteca. Maribel llama la
tool con fuente propia y lo que le contó el zagal; un testimonio nuevo queda
en facts antes de narrar, sin convertir la salida/dirección en hechos objetivos
separados.7,605 s hasta humano, humano1/DM2/cero TM/recorder. Reloj36120,
escena/revisión/recursos iguales. Zagal/cabras no aparecen en history previo;
relleno de jarra y gestos del humano siguen bajo revisión. No acredita
adherencia general a biblia ni registro de toda información PNJ. Restart/
reload375/1440 px/teclado preserva World/testimonio/historial/modelos/UTF-8/
JSON, cinco auxiliares cerrados; sin JS/overflow, cuatro capturas revisadas.
Hook retirado y LiveView restaurada exactamente. `npc-statement-verification.json`
privado conserva logs, traza, oráculos y límites.

## D175 — Espera deliberada frente a guía de atasco

Cuatro `game_wait_pacing_test.exs`: dos pasos reales del adaptador OpenAIChat
reciben guía de espera sin la orden ordinaria de novedades;30 s mantienen
escena/hechos atribuidos/recursos/DB/Codec, entorno idéntico confirmado y voz
DM única. Una interrupción5 s de30 s sigue permitida y conserva comprobante
tras restart. Caída antes de resolver conserva guía, declaración humana
única y una aplicación de30 s al recuperar. Control de instrucciones normales/
limbo y suite de exploration_limbo conservan su orden de avance. Se valida
la selección/entrega de contexto, no un detector determinista de semántica.
Rojo1/3 antes de implementación;25 y46 focalizados en1,7 s/seed30343. Tras
condicionar la frase común de agencia, siete focalizados en0,5 s y gate final
2536/3 en48,8 s/seed944912/max_cases48, sin errores/avisos inesperados. El gate
previo47,9 s/seed30343 también limpio. Cinco avisos deliberados breaker.

Playtest19425 mantiene modelos reales exactos y biblioteca: dos esperas15 s
idénticas en texto pero con fuentes distintas,36090→36105→36120. Prompt real
incluye espera deliberada y, en la versión final, agencia condicional. No
hay petición humana/dados/gasto/nuevos hechos. Ambos snapshots de escena
son idénticos y la marca queda limpia, primera muestra real de esa rama D172.
17,877/14,256 s hasta humano; DM2/2, TM1 con max_tokens/fallback y2 completados,
recorder3,855/3,623 s. No certifica latencia ni semántica general; la primera
conserva «tarde» del historial previo y la segunda reutiliza imagen del caldero.
Hechos nuevos PNJ/durabilidad y repetición sensorial siguen pendientes.

Reinicios reales tras ambos intervalos conservan World/comprobantes/intenciones/
historial/modelos/biblioteca/UTF-8/JSON y cierran cinco auxiliares cada uno.
Reload375/1440 px/teclado, respuesta única visible, ficha y compañeros sin
JS/overflow; ocho capturas revisadas. Gancho temporal retirado y LiveView
restaurada exactamente. Compile warnings-as-errors/formato/diff correctos;
`wait-pacing-verification.json` privado une fuentes, logs y oráculos.

## D174 — Callback SQL de LiveView terminado antes de cerrar su fixture

La traza temporal de Game.init/snapshot y DOWN, sin Worlds/modelos, atribuye
la reproducción al test de ficha y recarga del druida transformado en
`game_sheet_state_test.exs:167`. Game30899 (#PID<0.16199.0>) comparte owner
#PID<0.16176.0>; las vistas son #PID<0.16218.0>/#PID<0.16289.0>.
La última llamada snapshot de la primera ocurre02:25:36.995739; esa vista
termina02:25:36.996636. Postgrex informa cliente terminado, Game cae al
consultar eventos y su DOWN ocurre02:25:37.002024. El owner comienza a cerrar
después,02:25:37.002095. No acredita owner liberado antes de Game; sí una
consulta interrumpida por muerte del cliente que invalida Sandbox compartido.
No se atribuyen otros logs históricos por sus títulos SQL vecinos.

`Test.LiveViewFixture` delega live/live_isolated/follow_redirect en Phoenix
y registra un hijo después del canal: el cierre inverso de ExUnit solicita
GenServer.stop síncrono y espera su callback. Retornos originales conservados;
vista ya cerrada por navegación es inocua, timeout con vista viva falla.
ConnCase importa estos siete helpers: evitar reimportar los mismos macros
de Phoenix.LiveViewTest, que produciría ambigüedad. El resto de sus helpers
sigue disponible. No se cambia LiveView, Game, Repo ni dependencias.

Dos `live_view_fixture_cleanup_test.exs` usan Game pausado. Una conexión de
control Postgrex a la misma base test retiene un advisory lock; la LiveView
ejecuta la consulta dentro de su callback real y pg_locks verifica la barrera.
El cierre y snapshot quedan en cola hasta liberar el lock; SQL termina,
vista sale normal y World/historial/DB/estado permanecen iguales. Otra prueba
mantiene dos vistas, cierra una y verifica la otra y Game vivos. No añade
esperas al producto ni peticiones LLM. El contador de TMSpy se registra en
ExUnit antes del Game, de modo que sus peticiones terminan antes de cerrarlo.

Rojo0/1 por hijo de cierre inexistente.34 focalizados en6,7 s/seed944912 y45
incluyendo fast-path TM en7,1 s/seed30343, sin errores/avisos. Full2532/3
en48,0 s/seed944912 limpio. Intermedio49,0 s/seed30343, cero desconexiones/
Games caídos, una tarea y un aviso TMSpy:noproc; tras corregirlo,48,2 s/mismo
seed limpio. Todos max_cases48; cinco avisos breaker en cada full. Compile
warnings-as-errors/formato/diff correctos. Instrumentación en test_helper y
Sandbox retirada; traza privada y `live-view-shutdown-verification.json`
conservan evidencia. Los casos históricos de owner sin atribución se siguen
si reaparecen; estos gates no convierten todos en una única causa demostrada.

Desde D122, `MIX_ENV=test` usa `dragonex_test` aunque `.env.dev` o el shell
contengan `DB_NAME`. Solo `DB_TEST_NAME` cambia la base de pruebas; host,
puerto y credenciales pueden compartir servidor. Preparación inicial:
`MIX_ENV=test mix ecto.create` y `MIX_ENV=test mix ecto.migrate`.
`repo_runtime_config_test.exs` evalúa el runtime real con DB_NAME heredado,
override de test y configuración dev; restaura el entorno tras cada caso.
El gate actual corre en esa base separada, sin salas del navegador.

---

## Principios

`level_up_resources_test.exs` usa tablas/estado con gasto real de casillas y
Fuente de magia; comprueba capacidad nueva sin recarga, pacto al cambiar de
nivel, legacy, codec y descanso real. `game_sync_genserver_test.exs` comprueba
sync idempotente/pausa/reapertura y tool DM/TestModel; `hero_level_up_live_test.exs`
confirma desde web con Game activo. HP/rest_state/reloj/límite diario permanecen
(D124). Dos expectativas anteriores de recarga se sustituyen por el oráculo
de consumo conservado de AC-8.4.

D125 añade expectativa de nivel y rechazo monotónico de sync: Accounts prueba
reintento/ASI obsoletos y XP conservada; merge/Game no rebajan mundo ni baseline,
Games preinicio conserva sala y sync de partida pausada ausente rehidrata su
escritor. La regresión de dos pestañas sigue la redirección, comprueba aviso
visible y lo cierra; `game_lobby_join_test.exs` hace lo mismo con un error.
Ambos mensajes faltaban en layout pese a viajar en flash. **6** casos nuevos,
**45** focalizados y **2139 passed / 3 excluded**, rojo/verde documentado.
Navegador de Mara y seis mesas en `07-calidad-jugable.md`; datos antiguos
secuenciales no certifican estrés de conexiones independientes.

D126 añade `class_resource_level_up_test.exs`: unlock y gasto real por Actions
sin descanso, ki/Font/Shape/LoH, capacidad por CHA/ASI/cap y preservación de
flags/PG/rest_state/reloj. Merge usa gasto vivo, Codec e idempotencia; rest
real recarga. Game prueba tool DM/TestModel y sync humano/pausa/reapertura;
web verifica los seis pools y actualización/reload de ki recién desbloqueado.
**16** casos nuevos, **238** focalizados y **2155 passed / 3 excluded**.
Cuatro expectativas antiguas de remaining exacto y una de Font se sustituyen
por el contrato D126 de capacidad nueva/gasto conservado. Sira real verifica
pago/estado persistido y ficha a 375/1440 px, sin certificar toda redacción IA.

D127 añade `text_pc_name_forms_test.exs` (13 casos): fixture real de Sira,
subordinadas locales, voz propia/ajena, nombres completos/prefijos/homónimos,
estados pasivos, Unicode y detector. Dos Game/TestModel comprueban persistencia,
historial y recursos; dos LiveViews comprueban la burbuja de streaming y PNJ
registrado. **17** casos nuevos, **114** focalizados, **2172 passed / 3 excluded**
(31,9 s), compile sin warnings y formato/diff correctos. La segunda reproducción
roja identifica el nombre propio que borraba un prefijo de otro PC. No se
reescriben eventos previos ni se afirma obediencia general del modelo.

D128 añade `brief_resources_test.exs` (14 casos): seis pools vivos, conversión
real, unlock, Forma salvaje, nil/ausencia, flags y ledger tras descanso/Codec.
Dos smokes inspeccionan contexto recibido por DM/PC; Game paga mediante una
declaración humana resuelta por el DM y comprueba el contexto del siguiente
beat. La mesa conserva sus filas con metadatos compartidos. **17** casos nuevos,
**62** focalizados y **2189 passed / 3 excluded** (32,3 s), compile sin warnings,
formato/diff correctos. La pregunta real de Sira conserva recursos/escena/
reloj/rest_state/pausa/cursor, 16,08 s al humano, 375/1440 px sin JS/overflow.
La evidencia live no certifica todas las respuestas futuras del proveedor.

D129 añade `wild_shape_level_up_test.exs` (nueve casos): ambas formas, CON/
DEX/mental ASI, spell nuevo y bloqueo/reversión, daño sobrante, merge repetido,
codec, rechazo obsoleto y caducidad original. Dos Game prueban sync humano/
pausa/reapertura/reversión y tool DM de druida IA; una LiveView muestra PG
**6/11** tras sync/reload y **7/29** al revertir mediante declaración.
**12** casos nuevos, **158** focalizados y **2201 passed / 3 excluded** (32,8 s),
compile sin warnings, formato/diff correctos. La segunda reproducción roja
muestra deadline 3600 → 9000 al cambiar stats originales; se conserva la
transformación en curso en WorldClock. No se afirma playtest live nuevo.

D130 amplía ese recorrido LiveView con distintivo/PG originales/reversión,
y añade tres casos: todas las bestias/resumen/detalle/conjuros, snapshot
incompleto explícito y ausencia de segunda reserva en ficha ordinaria o
resumen de compañero. **69** focalizados, **2204 passed / 3 excluded** (33,0 s),
compile sin warnings y formato/diff correctos. Rojo adicional reproduce el
aviso ausente en el resumen usado durante exploración.
Sylvi real verifica L2 → lobo 11/11 → L3 original 10/24 → reversión 10/24,
uso/casillas/reloj/ledger/deadline y pausa/reload en Postgres; lector no crea
otro Game escritor. Fichas 375/1440 px sin JS/overflow, relevos 14,53/19,06 s.
`/tmp/dragonex-shape-sheet-*.log`, `/tmp/dragonex-playtest/wild-shape-*`.
No certifica obediencia al tono: DM introdujo amenaza en el claro tranquilo.

D131 añade `events_live_roster_test.exs` (cuatro): altas reales mediante
spawn_monster con prefijo/homónimo PC, alta rechazada sin World y fallback
sin handle/inválido/cerrado. `game_live_roster_test.exs` bloquea TestModel
antes/después del alta y verifica ficha/preview antes de la respuesta final,
persistencia/reload y ausencia de diálogo PC inventado. **Cinco** casos nuevos,
**60** focalizados, **2209 passed / 3 excluded** (33,4 s), compile sin warnings,
formato/diff correctos; rojos separados de sink y preview.
`/tmp/dragonex-live-roster-*.log`. Sin nuevo playtest de proveedor real.

D132 añade `agent_instructions_delivery_test.exs` (cuatro): inspecciona los
messages recibidos por TestModel y la codificación Chat, no solo el constructor
o params.instructions. Game DM debe recibir reglas/biblia/historial/World;
PC su propia voz con eventos; compacción conserva resumen y rol; tools reciben
una sola copia del prefijo y mantienen User/ToolReturn. **35** focalizados,
**2213 passed / 3 excluded** (33,1 s), compile sin warnings y formato/diff
correctos. Tres rojos evidencian pérdida de rol al reconstruir historia.
`/tmp/dragonex-instructions-delivery-*.log`; sin nueva medición de proveedor.

D133 añade `game_dm_style_test.exs` (tres): wizard custom multiline/World
conservado/reapertura pausada con idéntico prefijo; todos los escenarios con
estilo/biblia; nil/vacío/tipo legacy omite sección. Inspecciona messages en
codificación Chat. **20** focalizados, **2216 passed / 3 excluded** (32,9 s),
compile sin warnings, formato/diff correctos. `dragonex-dm-style-*.log`.
Mesa nueva Sylvi/Lyra/Vex conserva todos sus recursos/escena/reloj y vuelve
al humano tras ambas respuestas en 20,70 s; 375/1440 px sin JS/overflow.
La apertura larga y el desplazamiento colectivo inventado quedan registrados
para revisión, sin atribuirlos a una corrección ya verificada. `dm-style-*`.

D134 añade `exploration_turns_test.exs` (seis) y
`game_exploration_fairness_test.exs` (siete): cuenta turnos reales entre humanos,
no fragmentos narrativos; cinco compañeros, elegibilidad/autoplay, frontera
de combate incluida reacción, repetición válida, contexto/contador TM,
reapertura con 220 eventos intermedios, orden humano/pausa/reapertura, TM mudo
y declaración pendiente. Cinco rojos de Game y otro de frontera de reacción.
**77** focalizados, **2229 passed / 3 excluded** (33,8 s), compile sin warnings,
formato/diff correctos. `dragonex-exploration-fairness-*.log`.
Mesa nueva `/games/19422`: primera persona en 12,10 s, solo un DM; pregunta a
Lyra/Vex en 17,61 s con World completo codificado igual, pausa/cursor/cola
iguales y sin dados nuevos. Escena inicial conservada; reload/fichas 375/1440 px
sin JS/overflow. `exploration-fairness-*`; lector no crea otro Game escritor.
No es una garantía de latencia ni resuelve aún la agencia colectiva de prosa/tools.

D135 añade `text_collective_agency_test.exs` (seis),
`game_scene_agency_test.exs` (siete), `game_collective_agency_test.exs` (uno)
y `dm_advance_agency_test.exs` (uno). Fixtures exactos de narración/escena
`/games/19421`; sujetos/plurales explícitos, PNJs/invitaciones/pasivos,
streaming tras cita, rechazo antes de World/log/cola y reapertura, escena
legítima/actor propio, vacío y cola Lyra/Vex preservada. La LiveView confirma
preview/reload. Ocho rojos iniciales y otro de invitación PNJ. **97** focalizados,
**2244 passed / 3 excluded** (34,5 s), compile sin warnings y formato/diff
correctos. `dragonex-collective-agency-*.log`; sin nuevo proveedor real.
No interpreta todas las alusiones implícitas ni el consenso/ubicación semánticos.

D136 añade `text_addressed_identity_test.exs` (seis) y
`game_addressed_identity_test.exs` (cinco): nombres cortos únicos, Unicode y
literales, prefijos PNJ/IA, ambigüedad, varios humanos y contrato previo;
Game verifica apertura sin petición TM, pregunta a otro humano, destinatario
incapacitado y speaker conservado con 220 eventos intermedios. Asserts sobre
World/reapertura y contador TM, no solo parser. Diez rojos iniciales, **77**
focalizados, **2255 passed / 3 excluded** (35,0 s), compile sin warnings.
`dragonex-addressed-identity-*.log`; sin nuevo proveedor real.

D137 añade `text_implicit_agency_test.exs` (siete) y dos casos a
`game_scene_agency_test.exs`; refuerza historial y LiveView/preview/reload
sobre el fixture exacto. Prueba cortes locales plurales, destinos, citas
completas/incompletas, preguntas/planes, singular/solo y streaming parcial;
set_scene rechaza sin World/log y conserva estado al reabrir, permite PNJ.
Siete rojos iniciales, **93** focalizados, **2264 passed / 3 excluded** (34,8 s),
compile sin warnings, formato/diff correctos. `dragonex-implicit-agency-*.log`.
Continuación real `/games/19422`: cada compañero responde una vez, DM y retorno
Sylvi **10,02 s**; World completo/escena/pausa/cursor/cola iguales, cero dados.
Recarga/fichas 375/1440 px sin JS/overflow; lector sin segundo escritor.
`dialogue-continuity-*`. Retorno de conversación explícita, no prueba live del
parser D136 ni garantía de latencia o interpretación semántica general.

D138 añade dos casos a exploration_turns y game_exploration_opening: tres
casos nuevos con uno/cinco compañeros, TM no consultado, turno DM único,
World/pausa/reapertura/reanudación iguales y sin beats duplicados. Cuatro
pruebas D134 consumen primero una decisión humana real y mantienen equidad/
contador/fallback. Tres rojos iniciales; **41** focalizados, **2267 passed /
3 excluded** (35,4 s), compile sin warnings, formato/diff correctos.
`dragonex-exploration-opening-*.log`. Mesa seis `/games/19424`: primer control
**6,01 s**, un DM/cero IA, escena original igual; pregunta cinco **22,72 s**,
uno cada uno, DM y retorno Iria, World completo/recursos/pausa/cursor/cola
iguales, cero dados. Reload/fichas 375/1440 px sin JS/overflow; lectores sin
otro escritor. `opening-control-*`. Tres narraciones truncadas de compañeros
quedan para rastrear raw/filtrado; no certificar prosa por un World estable.

D139 añade text_observation_integrity (siete), Game (uno/tres respuestas)
y LiveView (tres/preview/reload), con fixtures exactos de raw de los agentes
19424 pausados: finish_reason=stop, 142/97/65 output tokens. Captura en el
proceso dev existente, solo lectura, gancho temporal retirado: nunca arrancar
otro Game escritor. Verifica frase completa/propiedad de voz/metáforas/colon,
negativos PNJ/sello/stats, historial/colas/World/reapertura. Diez rojos
iniciales; **94** focalizados, **2278 passed / 3 excluded** (35,8 s), compile
sin warnings y formato/diff correctos. `dragonex-observation-integrity-*.log`.
Continuación live: tres respuestas completas y retorno Iria **13,09 s**,
raw=filtrado=persistido, World completo/recursos/pausa/cursor/cola iguales,
sin dados, recarga/fichas 375/1440 px sin JS/overflow. `observation-integrity-*`
y `response-integrity-*`. No reescribe pasado ni certifica toda prosa posible.

D140 añade cinco casos LiveView en `hero_asi_input_test.exs`: característica
desconocida/átomo ajeno, delta inválido/tipo incorrecto, evento incompleto con
elecciones previas, recuperación/caps/confirmación y evento oculto sin ASI.
Cinco rojos iniciales, **28** focalizados, **2283 passed / 3 excluded**
(36,9 s), compile sin warnings y formato/diff correctos. Navegador por teclado:
misma conexión, punto conservado tras error, clic válido recupera y dos puntos
elegidos. Sin confirmar ni mutar biblioteca/todos los World/pausas/cursors/
colas asociados, recarga reinicia el borrador; vistas 375/1440 px sin JS/overflow.
`dragonex-asi-input-*.log` y `asi-input-*` en `/tmp/dragonex-playtest`.

D141 añade fixture exacto del cierre real y **11** casos nuevos: siete Text,
un Game/historial/reapertura, un LiveView/preview/reload y dos Game/set_scene
(PC rechazado, PNJ aceptado). Nueve regresiones en rojo; **89** focalizados,
**2294 passed / 3 excluded** (37,1 s), compile sin warnings y formato/diff
correctos. Verifica pronombres/predicado inmediato, entorno fuera de citas,
objetos coordinados, voz propia, pasivos, homónimos y World intacto al rechazar.
`dragonex-clitic-agency-*.log`. Seguimiento real19424: tres respuestas propias,
DM sin gesto humano y retorno Iria **15,67 s**, World completo/recursos/pausa/
cursor/cola iguales y cero dados, teclado/reload/fichas 375/1440 px sin
JS/overflow. `clitic-agency-*`, lectores sin segundo escritor. La prosa nueva
no contiene el disparador exacto; su corrección se prueba con el fixture,
sin reescribir pasado ni certificar toda agencia semántica.

D142 añade **9** casos (siete Text, un Game, un LiveView): destinatario PNJ
antes de cierre de inciso/cita, sujetos/etiquetas/relativas PNJ reales, raw
del agradecimiento, streaming parcial, Events/historial/World/reapertura y
preview/reload. El fixture de entrega es reconstrucción mínima y reproduce
exactamente la frase truncada guardada; su raw original ya no está en el
agente. Seis rojos iniciales y uno adicional de relativa; **99** focalizados,
**2303 passed / 3 excluded** (37,2 s), compile sin warnings y formato/diff
correctos. `dragonex-npc-recipient-*.log`. Agradecimiento19425 **8,55 s**,
raw capturado en el proceso pausado, finish_reason=stop, solo se retira la
cabecera; texto limpio=persistido, World completo/recursos iguales y fichas
375/1440 px sin JS/overflow. Gancho temporal retirado, compile limpio.
La petición posterior de jarra **13,63 s** no dio turno a Vex y su raw sigue
siendo el previo: no contar el gate técnico como evidencia de ese relevo.

D143 añade **14** casos (cinco Text, ocho Game, un LiveView): vocativo literal,
orden/nombres únicos/Unicode/PNJ/ambiguos, modelo sin tool/fallido, persistencia
antes del beat, reintento distinto, cola humana/reinicio, borrador limpiado,
prioridad ajena y combate. Submit real del formulario, preview por actor,
composer de retorno y reload comprobados. Ocho rojos iniciales, **72**
focalizados, **2317 passed / 3 excluded** (39,3 s), compile/formato/diff correctos.
`dragonex-explicit-question-*.log`. Mesa19425 en **6,51 s**, Mara/Vex/DM propios
y retorno Mara, raw nuevo Vex85 finish_reason=stop y limpio=persistido, todo
World/biblioteca/pausa/cursor/cola igual y cero dados, fichas 375/1440 px sin
JS/overflow. Gancho retirado; no certifica peticiones fuera de esa gramática.
Reinicio real previo del Game pausado tras combate/descanso conserva World/
historial completo (79 eventos)/recursos, cierra anterior/cinco auxiliares y
reabre en web sin cambios. No crea otro escritor ni reinicia el servidor.
`short-adventure-process-restart`/`short-adventure-restart-*`.

D144 añade **6** casos: reloj relativo, facts/escena, descanso diario tras
Codec, frontera de 24 h y bloqueos, respuesta de tool con tiempo confirmado,
contexto del siguiente PC y persistencia Game. Seis rojos iniciales, **64**
focalizados, **2323 passed / 3 excluded** (38,9 s), compile/formato/diff correctos.
Mañana real19425 **13,65 s**, todo World/biblioteca igual, cero dados y web
375/1440 px sin JS/overflow. El modelo omite `set_scene` y conserva el patio
inicial: evidencia negativa del registro, no un cierre de esa brecha.
`dragonex-clock-context-*.log`/`short-adventure-manana-contexto-*`.

D145 añade **16** casos, diez rojos iniciales: marca/Codec/legacy, cola de
respuesta frente a cambio de escena, salida estructurada obligatoria sin
rules tools, schema/reintento/frase truncada real, agencia y homónimos,
timeout, World desactualizado, omisión de set_scene tras descanso, recursos,
error/reapertura sin repetir descanso, registro previo y pausa responsive.
**120** focalizados y **2339 passed / 3 excluded** (38,4 s), compile limpio,
formato/diff correctos. Primera variante real timeout20 s, regreso38,71 s
sin cambios. Final: registro4,72 s/un paso, regreso23,89 s, solo escena/log/
marca diferentes; mecánicas/biblioteca iguales, cero dados, reload y web
375/1440 px correctos. DM sin tools, reinicio conserva World/130 eventos y
cierra cinco auxiliares, rechazo diario vigente. Ganchos retirados.
`dragonex-scene-refresh-*`/`short-adventure-manana-registro-*`.
Los logs de suite D144/D145 contienen el mismo error de teardown de Events
tras salir el dueño Sandbox; el gate pasa, no se afirma un log sin errores.

D146 añade **6** casos, cinco rojos iniciales: feedback después de caducar
forma sana/herida, Codec, frontera exacta8 h, forma con tiempo restante,
grupo con un intervalo y mensaje DM/TestModel/World/reapertura. **76**
focalizados, **2345 passed / 3 excluded** (39,2 s), compile/formato/diff
correctos. Sylvi19426 real: lobo11/11 con nativo10/24, noche28,24 s al humano,
cuerpo24/24, reservas correctas, reloj28800, cero dados/biblioteca igual;
web375/1440 px correcta y reinicio World/20 eventos iguales. Feedback humano
ya sustituido por history DM: replay sobre World previo guardado devuelve
14PG10→24 sin aplicar; entrega al modelo se prueba con TestModel, no se
inventa raw real. Tres auxiliares cerrados, ganchos retirados, compile limpio.
`dragonex-rest-shape-feedback-*`/`rest-form-*`.

D147 añade **12** casos en `game_run_lifecycle_test.exs`: petición esperando
tras parada supervisada/normal, reinicio y caída, PC/TM/registro, autoplay
creado después, Events/tools de propietario muerto y final de monitores.
Tres fallos iniciales válidos; dos fixtures adicionales confundían el evento
de creación con texto tardío y se corrigieron comparando la lista previa.
**67** focalizados y **2357 passed / 3 excluded** (39,1 s), compile limpio.
Mesa19427 en VM web, TestModel esperando antes de tools: petición y cuatro
auxiliares cancelados12,48 ms observados, World/tres eventos/pausa/cursor
iguales; reload375/1440 px y teclado sin JS/overflow. Ganchos retirados.
`dragonex-run-lifecycle-*`/`run-lifecycle-*`. El gate final registra11 errores
de dueño Sandbox salido en teardown; no se afirma un log limpio. La caída
después de tools parciales y la cancelación HTTP real no están verificadas.

D148 sustituye checkout/shared por dueño `start_owner!` separado en67
módulos/69 setups. `Test.GameFixture` registra después del Game un hijo que
lo pausa y deja terminar el beat antes de su cierre;55 módulos/147 arranques.
Los Games globales creados por LiveView se limpian por Registry antes de
liberar SQL. Siete módulos async mantienen sus conexiones aisladas.
`game_fixture_cleanup_test.exs` añade un caso con descanso ya aplicado y
modelo esperando: permite finalizar y verifica World/curación/reloj/narración
persistidos antes del cierre. Las cancelaciones deliberadas D147 siguen
comprobándose por separado. **71** focalizados y **49** finales sin errores;
**2358 passed / 3 excluded** (39,2 s), cero errores de log, compile/formato/
diff correctos. `dragonex-sandbox-lifecycle-final-registry-full.log` es el
gate válido; variantes intermedias con interrupciones no son cierres.
La recuperación ante caída después de tools parciales sigue abierta.

D149 añade **5** casos en `game_shutdown_order_test.exs`, un rojo inicial:
callback controlado en Game responde antes de parada supervisada, caída DM,
Session normal, autoplay retirado e informe sin modelos privados. **54**
focalizados, **2363 passed / 3 excluded** (39,0 s), cero errores de log,
compile/formato/diff correctos. `dragonex-shutdown-order-*`. VM19427:
operación retenida100 ms, tres auxiliares cerrados, reapertura World/tres
eventos/pausa/cursor iguales; reload375/1440 px y teclado correctos. Adopción
19425/19426 pausadas conserva World/130 y20 eventos/relojes32400/28800,
cierra cinco/tres auxiliares y activa trap_exit. Ganchos retirados.
`shutdown-order-*`. El callback controlado prueba orden de parada; no mide
latencia SQL ni durabilidad de tools parciales, `:kill` o timeout OTP.

D150 añade **7** casos en `game_rule_checkpoint_test.exs`. Rojo inicial:
World curado14/14/reloj28800 frente a DB8/14/reloj0 mientras el modelo espera.
Guardado previo a confirmación, reinicio, límite diario, magia humana y gasto,
pausa/intenciones, handles antiguos, cambios inválidos y writer Game cubiertos.
Gate **2370 passed / 3 excluded** (40,6 s), cero errores de ejecución, once
avisos de tests; compile dev limpio. VM19428 offline repite el descanso y
reinicio bloqueado, luego lee estado vigente y actualiza amanecer, sin dados.
`dragonex-rule-checkpoint-*`/`rule-checkpoint-runtime`. No certifica atomicidad
conjunta dados/eventos/World. El gate combinado con un `:kill` adicional
agotó el límite global de reinicios; no se cuenta como gate verde y motiva
una reproducción específica de aislamiento entre mesas.

D151 añade **6** casos en `game_fault_isolation_test.exs`. Rojo inicial:
cuatro caídas rápidas de una mesa cierran la sana por intensidad global.
Supervisor/límite por mesa, cuatro mesas independientes, salida normal,
restart/idempotencia, ID ausente y `:kill` tras descanso cubiertos. Gate final
**2376 passed / 3 excluded** (40,4 s), cero errores y warnings; compile limpio.
Once avisos antiguos de tests eliminados sin cambiar sus aserciones. El gate
previo registró una desconexión: el test mataba un reemplazo registrado antes
de terminar su init SQL. El escenario final espera la respuesta de Game antes
de volver a matarlo; no se presenta esa variante como log limpio.
VM19429: cuatro caídas propias cierran mesa/tres auxiliares, manager y mesa
sana19428 mantienen PID/World/historial; reapertura/reload375/1440 px/teclado
correctos. Adopción19425–19428 pausadas conserva World/eventos/modelos/cursores,
cierra14 auxiliares anteriores. Ganchos retirados. `dragonex-fault-isolation-*`.

D152 añade **9** casos en `game_applied_action_retry_test.exs`:503 tras cast
ya aplicado, max_tokens, IDs/nulos, nombres/nivel/opcionales equivalentes,
dos casts originales consecutivos, rechazo corregido, copias extra, retries
combinados y nueva declaración. Rojo inicial:0 casillas frente a1 esperada.
La fixture inicial de dos llamadas las ejecutaba en paralelo; la variante
final respeta el orden consecutivo sin debilitar guardas del motor.
**28** focalizados y **2385 passed / 3 excluded** (41,3 s), cero errores/
warnings, compile/formato/diff correctos. VM19430 offline/503 simulado:
casillas2→1, Goblin20→14, un evento de dados y feedback reutilizado al modelo;
humano1050,311 ms con backoff1 s. Reload375/1440 px/teclado/reserva correctos.
Adopción19425–19429 conserva World/eventos/modelos y cierra17 auxiliares.
Ganchos retirados. `dragonex-applied-action-retry-*`/`applied-action-retry-*`.
El registro de resultados solo cubre retries del mismo Game; falta duración
entre Games y atomicidad conjunta de efectos/dados/eventos.

D153 añade **8** casos en `game_actor_checkpoint_recovery_test.exs`: restart/
`:kill` tras cast IA, Codec/legacy, registros inválidos, snapshot previo a spawn,
argumentos saneados, nueva declaración y fallo definitivo. Rojo: otra casilla
tras reabrir. **45** focalizados, gate **2393 passed / 3 excluded** (41,8 s),
cero errores/warnings, compile limpio. Fixture timeout de SceneRefresh ya no
presupone callback dentro del plazo que también incluye preparar la petición;
World completo igual y cierre si arrancó. VM19431 offline: cast recuperado
sin replay, una casilla/daño6/un grupo/marcador/turn_id original, petición vieja
cerrada y registro limpio; humano25,518 ms. Reload375/1440 px/fichas/compañeros
por teclado sin JS/overflow. Adopción19425–19430 normaliza el campo nil,
conserva estado/modelos/eventos y cierra20 auxiliares. Ganchos retirados.
`dragonex-actor-checkpoint-recovery-*`. No cierra ventanas previas al registro
ni atomicidad conjunta de World/dados/eventos.

D154 añade **5** casos en `game_effect_checkpoint_recovery_test.exs`. La tool
real se bloquea después de proponer magia y antes de responder: rojo segunda
casilla gastada. Restart/:kill, sustitución del comprobante por feedback preciso,
varias propuestas de una tool y rechazo corregido. **29** focalizados y gate
**2398 passed / 3 excluded** (41,8 s), cero errores/warnings; compile limpio.
VM19432 offline replica ese corte y conserva una casilla/daño6/un grupo/turno;
comprobante llega al actor tras restart, pedido viejo cerrado, humano29,673 ms.
Reload375/1440 px/fichas/compañeros por teclado sin JS/overflow. Adopción
19425–19431 conserva estado/modelos/eventos y cierra24 auxiliares. Ganchos
retirados. `dragonex-effect-checkpoint-recovery-*`. Dados/eventos anteriores
al guardado del efecto conservan su revisión de atomicidad.

D155 añade **9** casos: `text_group_decision_test.exs`, scene guard y LiveView
de preview/reload. Fixtures: DM raw de19425 y narración humana persistida;
rojos de consenso decidido y gesto plural. **46** focalizados, gate final
**2407 passed / 3 excluded** (49,4 s, trace/max_cases48), cero errores/warnings.
Puntuación irregular por sí sola no es agencia; conservación de PNJs/citas/
preguntas/planes/PC solo. Compile/formato/diff limpios. Adopción19425 conserva
estado/modelos/historial, cierra5 auxiliares. Nueva pregunta real12,137 s:
ideas propias, decisión abierta, World completo/biblioteca iguales. Raw Lyra
con etiquetas D7 se guarda limpio; Vex/DM coincide con eventos. Reload375/1440 px
fichas/compañeros por teclado sin JS/overflow; ganchos retirados. `beta-decision-*`.
No compara causalmente rendimiento con la primera pregunta25,431 s ni cierra
consenso semántico general.

D156 añade **5** casos: cuatro en `fact_agency_test.exs` standalone sin DB
y bypass del fixture real en Game/Postgres. Rojo «hecho registrado» frente a
rechazo esperado. **39** focalizados, gate **2412 passed / 3 excluded** (42,5 s),
cero errores/warnings, compile/formato/diff limpios. NPCs/grupos cualificados/
citas/acción propia y saneamiento D7 preservados. VM19433 offline: consenso
rechazado, mapa PNJ aceptado en el mismo beat, escena factual vigente,
humano31,705 ms; mecánicas iguales/cero dados, restart/reload375/1440 px/fichas/
compañeros por teclado correctos. Adopción19425–19432 conserva estado/modelos/
historial y cierra28 auxiliares; ganchos retirados. `dragonex-fact-agency-*`.
No certifica procedencia semántica general ni atomicidad de dados/eventos.

D157 añade **10** casos: ocho en `game_tool_roll_commit_test.exs` y dos en
`roll_log_test.exs`. Rojo: un evento de dados antes del World preparado.
Preparación sin publicación, efecto/comprobante/dados juntos, restart/:kill
antes de commit, rechazo, constraint Postgres temporal y rollback real, commit
posterior sin reroll, concentración preparada y dentro del callback Game,
roll_dice del DM/recovery sin efectos, buffers intercalados y recorder previo
a hot reload. **43** focalizados y **14** finales tras compatibilidad;
gate **2422 passed / 3 excluded** (42,8 s), cero errores/avisos de compilación.
VM19435 offline confirma preparación privada y restart antes del feedback:
un grupo/casilla1/Goblin14/turn_id original, humano27,299 ms. Reload375/1440 px/
teclado/crónica sin duplicados ni JS/overflow. Adopción19425–19434 conserva
estado/modelos/eventos, cierra37 auxiliares. Guion inicial duplicó pausa,
fixture19434 conservado; ganchos retirados. `dragonex-tool-roll-commit-*`.
La garantía se limita a tools anunciadas; narraciones y grupos automáticos
fuera de ellas no heredan atomicidad. PubSub best-effort después del commit.

D158 añade **10** casos en `text_npc_question_test.exs` (2),
`world_question_test.exs` (4) y `game_npc_question_test.exs` (4). Rojo:
Thane→DM→Lyra→DM ante pregunta literal al PNJ. Gramática acotada y controles
negativos, JSON/validación/saneamiento/idempotencia, prioridad humana,
borrador borrado, sustitución de destinatario por modelo y restart con DM
esperando. **55** focalizados; gate **2432 passed / 3 excluded** (43,5 s),
cero errores/avisos de compilación. Real19425: primera pregunta16,216 s con
unos9 s tras DM; nueva pregunta8,143 s con coordinador sin peticiones, voces
Mara/DM, World/biblioteca iguales, cero dados y prefijos DM saneados por D7.
Reload375/1440 px/teclado sin JS/overflow. Adopción19425–19435 conserva estado/
modelos por rol/historial, cierra41 auxiliares; ganchos retirados. `beta-npc-*`.
Preguntas diferentes, sin benchmark controlado ni garantía de latencia global.

D159: `game_engine_roll_commit_test.exs` añade tres casos. Un constraint
rechaza el segundo grupo después del primer INSERT: rollback de World/eventos,
Session anterior y ningún PubSub. Resume/restart conserva spawn/comprobante,
confirma dos grupos una vez y limpia el registro.26 focalizados verdes.
VM19436 y navegador375/1440 px confirman iniciativa durable y recuperación.

D160: nueve casos de `negative_weapon_damage_test.exs`, incluido PC/TestModel
con tools/Session. Rojo de subtotal negativo y MatchError Smite; normal/crítico
cero, PG temporales/concentración, caído/fallos de muerte, furia, marca/
resistencia, Sneak, radiante/casilla y JSON.184 focalizados finales verdes.
VM19437 corta antes del feedback, conserva arma0/radiante4/Goblin6/casilla1
al reiniciar y no repite dados. Navegador375/1440 px y teclado verificados.

Acceso local restablecido: gate D159/D160 **2444 passed / 3 excluded** en44,6 s
sin errores/warnings, compilación dev limpia. Nueva VM recupera19425–19435
propias pausadas con World/historial/cursor/intenciones/relojes iguales; modelos
efémeros desde configuración vigente o TestModel explícito. Ganchos retirados.
`dragonex-engine-damage-full.log`, `engine-damage-{cold-recovery,browser}.json`,
`engine-roll-commit-runtime.json`, `negative-weapon-damage-runtime.json`.

D161: cinco casos nuevos en RollLog, RollFormat (dos), History y
`negative_damage_live_test.exs`, más aserción de subtotal en daño existente.
Rojo de cinco fallos: penalización reconstruida−1 en lugar de−2, subtotal
perdido y LiveView igual. Buffer/ack/JSON, tarjeta, metadatos inválidos y
PC/TestModel→Game→Postgres→LiveView/reload; **50** focalizados verdes. Gate
**2449 passed / 3 excluded** en44,3 s sin errores/warnings. VM19438 conserva
subtotal−1 y efectos al reiniciar antes del feedback, sin nuevos dados; History
muestra el modificador correcto. Navegador375/1440 px, teclado, captura móvil
revisada sin JS/overflow. Compile dev final limpio; ganchos retirados.
`dragonex-damage-breakdown-*`, `damage-breakdown-{runtime,browser}.json`.
Eventos antiguos sin subtotal mantienen su presentación; no se inventan datos.

D162: `game_turn_start_commit_test.exs` añade seis casos. Cuatro rojos iniciales
por Session adelantada ante rechazo del segundo grupo, parada de Game y
marcador no durable. Reserva de slot/tipo antes de evaluar; candidato/dados/
retirada del marcador SQL juntos, publicación posterior. Rollback sin efectos
ni grupos parciales, resume/restart/segundo restart, enemigo nombrado bajo DM,
reacción con dueño principal y JSON/legacy inválido. **82** focalizados; gate
**2455 passed / 3 excluded** en45,4 s sin errores/warnings, compile dev y formato
limpios. No usar una transacción externa de test para la reserva y resolución:
son dos commits distintos; Sandbox sigue aislando ambas en su transacción raíz.

VM19439 corta con roller esperando después de reserva durable y antes de
retornar un dado: Goblin100/concentración intacta/cero eventos. Parada por
supervisor5014,012 ms; restart aplica aura3/Goblin97, tres grupos confirmados,
cinco dados y contexto PC/TestModel97/100. Otra reapertura no repite efectos.
Adopción19425–19438 pausadas conserva World/historial/cursor/intenciones/
relojes/modelos por rol y cierra52 auxiliares. Reload375/1440 px/teclado sin
JS/overflow, captura de escritorio revisada; ganchos retirados.
`dragonex-turn-start-commit-*`, `turn-start-commit-{runtime,paused-adoption,browser}.json`.
El RNG y el cierre posterior del combate/narraciones no heredan esta transacción.

D163: `game_combat_end_commit_test.exs` añade siete casos. Cuatro rojos
principales: Session adelantada al rechazar cualquiera de dos notas y victoria
reabierta esperando otra acción. El control de recuperación usa una pregunta
DM explícita para reservar el regreso humano. Rollback de World/intenciones/
notas, resume/restart antes de reacción obsoleta, ataque ganador recuperado
antes del feedback y tras rechazo de cierre por resume/restart. **52** focalizados.
Gate **2462 passed / 3 excluded**: primer46,3 s con tres desconexiones Postgrex
al cerrar clientes/owner; trazado seed927614 en53,6 s sin errores/warnings.
17 focalizados de autorización/visibilidad/sync, seed534533 en4,4 s, también
limpios. No se acredita corrección de esa incidencia intermitente: conservar
ambos logs y reproducir antes de modificar tiempos o limpieza.

VM19440 recupera derrota durable antes de acción/modelo, cierra fase y solo
borra la intención de combate, sin dados. VM19441 recupera un golpe ganador
antes del feedback, conserva turno/Goblin0/dos dados y confirma dos notas una
vez. Otro restart preserva World/historial sin repetir notas/dados. Adopción
19425–19439 conserva estado/modelos por rol y cierra56 auxiliares. Reload
375/1440 px/fichas por teclado sin JS/overflow, captura móvil revisada; compile/
formato/diff limpios, ganchos retirados. `dragonex-combat-end-commit-{red,focused,
full,trace}.log`, `combat-end-commit-{runtime,paused-adoption,browser}.json`.
Narración, relevo posterior y RNG mantienen garantías independientes.

D164: dos rojos en recuperación del golpe ganador prueban dos finales para el
mismo turno después de rechazar el cierre. `events_completion_test.exs` añade
cinco casos: saneamiento y scope partida/actor/turno, declaraciones iguales
válidas con tools, truncado/filtrado, vacío y metadata legacy/inválida.
`game_narration_recovery_test.exs` añade dos cortes después de publicación y
antes de liquidación: restart y kill durante el registro de escena. No se
solicita otra respuesta, conserva descanso/cronología/turno y completa la
escena independiente. Cinco recuperaciones anteriores reforzadas: prefeedback,
rechazo de cierre y rechazo de iniciativa por resume/restart. El siguiente
modelo en la iniciativa corresponde al turno legítimo del goblin, después
del commit, en lugar de exigir repetir el beat que ya publicó su final.
**49** focalizados; gate **2469 passed / 3 excluded** en46,0 s, sin errores ni
warnings. El primer gate tuvo dos expectativas antiguas de replay del modelo;
se sustituyen por fase/contexto/una publicación comprobados. La incidencia
intermitente de limpieza D163 no se considera resuelta por este gate limpio.

VM19442: corte durante registro de escena posterior a la publicación; restart
16,606 ms, petición antigua cerrada y cero nuevas al actor. Descanso28800 s,
límites, dos intervenciones originales y turno único conservados. Reanuda la
escena y regresa a Thane; segundo restart mantiene World/historial. Reload
375/1440 px/fichas por teclado, sin JS/overflow; ambas capturas revisadas.
Ganchos retirados. `dragonex-narration-recovery-{red,focused-final,full-final,
dev-compile,browser}.log`, `narration-recovery-{runtime,browser}.json`.
Garantía acotada a final completa con comprobante válido; intentos incompletos,
actores sin comprobante, relevo posterior y RNG siguen bajo revisión.


D173: `game_scene_environment_test.exs` usa un registro mezclado con pregunta/
oferta/gesto PNJ. Verifica la nueva guía en los messages system codificados
para el proveedor, contexto intacto, tools vacías y registro físico sin borrar
la voz del DM: una publicación,120 s/recursos/DB/Codec y restart idénticos.
Un caso nuevo; rojo0/1 por guía ausente,27 focalizados en0,7 s/seed944912,
sin errores/avisos. Gate2530/3 en47,9 s/max_cases48: una desconexión cliente
SQL y una terminación Game al consultar snapshot, cinco avisos deliberados
breaker. Sin avisos inesperados de modelo agotado. No acredita limpieza resuelta.
Compile con warnings-as-errors, formato global/diff y HTTP200 verificados.

Proveedor19425/modelos iguales:30 s una vez,36060→36090,21,956 s hasta
humano, DM2/TM2/recorder1 de5,576108 s, ninguna petición humana ni dados/gasto.
World cambia solo reloj/comprobante/escena/log. Scene915→662 caracteres,
omite pregunta/oferta y comparaciones de intención PNJ; conserva manos
apoyadas y la jarra a medio vaciar previa. El DM añade salida del forastero
al norte a mediodía sin facts nuevo. Guía al modelo y muestra acotada: no es
clasificador semántico, migración de escenas ni benchmark de latencia.
Restart conserva World/comprobante/historial/cursor/intenciones/modelos/
biblioteca/UTF-8/JSON y cierra cinco auxiliares. Reload375/1440 px/ficha/
compañeros por teclado sin JS/overflow; capturas revisadas, gancho retirado.
Evidencia privada0600: `scene-environment-{verification,prepare,restart,
restart-browser}.json`, `beta-latency-scene_environment-{runtime,browser}.json`;
logs `dragonex-scene-environment-{red,focused,full-final,format,dev-compile,
live-browser,restart-browser}.log`.

D172: siete `wait_scene_confirmation_test.exs` prueban igualdad estructurada
tras espera completa/parcial, fuente/duración/reloj exactos, revisión previa,
facts/recursos/escena/tiempo distintos, aplicación tardía, Codec/JSON y huella
malformed que retira solo la clave opcional preservando idempotencia. Verifican
en messages del modelo la guía condicional solo cuando corresponde. Tres
`game_wait_scene_confirmation_test.exs` cubren flujo natural y pregunta posterior
sin recorder, pausa durante registro y reinicio tras final DM publicada sin
otra petición al actor, narración duplicada ni nuevo avance.
Diez nuevos; rojo inicial1/6, recuperación7/9 y guía6/7.53 focalizados en1,7 s,
seed181952/max_cases48, sin errores/avisos. El primer negativo de revisión previa
se corrige para resolver desde el World realmente pendiente, sin reutilizar un
comprobante que provenía de un entorno limpio.

Gate anterior a la guía2528/3 en47,5 s/seed944912/max_cases48: dos desconexiones,
cero Games terminados y seis avisos. Tras la guía, traza2529/3 en55,2 s/max_cases1
sin desconexiones ni avisos inesperados; cinco avisos breaker. Gate ordinario
final2529/3 en47,6 s/max_cases48: una desconexión owner SQL, cero Games terminados
y seis avisos, uno por CaseClauseError nil en TestModel. El SDK instalado no
define fallback para una lista no vacía cuyo índice ya se agotó. El fixture
responsable todavía no está identificado; no se parchea la dependencia ni se
añaden esperas para ocultar la ejecución sobrante. Compile con warnings-as-errors,
formato global, diff y HTTP200 correctos. Causa de limpieza sigue abierta.

Proveedor19425/modelos iguales:120/60 s,35880→36000→36060,13,246/18,890 s hasta
humano. Una advance_time DM exitosa por intervalo, cero peticiones humanas,
cero dados, recursos/biblioteca intactos. Dos peticiones DM por recorrido;
TM0/2 y recorder4,903816/4,913670 s. Huella válida y revisión limpia; ambas
descripciones cambian. La confirmación idéntica queda acreditada offline,
incluido reinicio, no observada en estas dos muestras reales. No es un benchmark.
Persisten diálogo/pregunta y gestos PNJ en el registro, además de una jarra a
medio vaciar que requiere revisar continuidad.
Revisión legacy previa5,927 s cambia solo scene/log/marca, sin reloj ni recursos.
El intento QA inicial compara JSON crudo con claves enteras de spell_slots y
falla sin mutar World; el oráculo correcto compara Codec.decode(saved) con
Game.world. Se conserva `wait-scene-legacy-comparison.json` como diagnóstico.
Dos reinicios reales conservan World/comprobante/historial/cursor/intenciones/
modelos/biblioteca/UTF-8/JSON y cierran cinco auxiliares cada uno. Reload375/
1440 px/ficha/compañeros por teclado sin JS/overflow; cuatro capturas revisadas
y ganchos retirados. Evidencia privada0600:
`wait-scene-verification.json`, `wait-scene-{prepare,legacy-review,restart,restart-browser}.json`,
`wait-scene-same-{prepare,restart,restart-browser}.json`,
`beta-latency-wait_scene{,_same}-{runtime,browser}.json`;
logs `dragonex-wait-scene-confirmation-{red,recovery-red,instruction-red,focused,
full,full-trace,full-final,format,dev-compile}.log`.

Verificación adicional cola/limbo2026-10-03: el log D172 permite atribuir el
aviso29249 al fixture multi-human. El oráculo reforzado reproduce fallo:
Thane9 PG en vez de6 tras una respuesta del goblin ausente. Ahora el script
incluye ese turno legítimo y espera las dos declaraciones resueltas y retorno
humano, con goblin2 PG, Thane6 PG, casillas Lyra2, cola vacía y World guardado.
Seis phase0 focalizados verdes, sin errores/avisos.

Instrumentación temporal de propietarios Sandbox en gate2529/3 en47,6 s
sin desconexiones localiza otro aviso nil en limbo. La separación DM/PC y
una barrera antes de la tercera respuesta permiten pausar dentro del recorrido,
completar tres voces, una tirada de capacidad y recursos/World guardados sin
continuar después de la comprobación. Las dos comprobaciones intermedias de
limbo pasan: no se presentan como rojos funcionales. Ocho focalizados finales
en1,1 s/seed944912 sin errores/avisos. Gate final2529/3 en48,1 s/max_cases48,
cinco avisos deliberados del breaker y ninguna advertencia inesperada; una
desconexión cliente SQL, cero Games terminados. No acredita causa SQL resuelta.
El trazado se retira del soporte antes del gate final y no se parchea el SDK.
Logs privados `dragonex-phase0-queue-completion-{red,focused}.log`,
`dragonex-limbo-progress-completion-{red,red-final}.log` (los dos últimos son
verdes pese a su nombre), `dragonex-completed-fixtures-{focused,full-final}.log`,
`dragonex-teardown-owner-full.log`, `teardown-owner-trace.jsonl`.

D171: `wait_literal_speech_test.exs` cubre palabras originales, gramática
pasiva y acciones mixtas/inciertas. Cuatro `game_literal_wait_test.exs`
verifican contexto/peticiones reales, habla literal una vez, recursos/DB,
reinicio antes del reloj, hechizo mixto con casilla/dado y cola pausada sin
publicación anticipada. Siete nuevos, primer rojo1/7 (la comparación de cola
se ajusta al historial inicial de la partida);29 focalizados en1,2 s/seed410661.
Gate2519/3 en47,0 s, seed944912/max_cases48: sin errores/desconexiones,
cinco avisos deliberados del breaker. Compile con warnings-as-errors, formato
global y diff correctos; no marca resuelta la causa histórica de limpieza.

Proveedor19425/modelos iguales: espera180 s/17,884 s,35700→35880, una sola
tool DM exitosa, ninguna petición humana y ninguna tool rechazada. Dos
peticiones DM, una TM con max_tokens/fallback y una recorder3,853 s. Recursos/
biblioteca iguales y cero dados; cambian reloj/comprobante y la marca de
escena pendiente. El recorder idéntico sigue pendiente; el PNJ añade detalles
del rumor solo al historial. No compara latencia entre declaraciones distintas.
Restart conserva World/historial/cursor/intenciones/modelos/JSON y cierra cinco
auxiliares; reload375/1440 px/teclado/fichas/compañeros sin JS/overflow,
capturas revisadas y ganchos retirados. Evidencia:
`dragonex-literal-wait-{red,focused,full,dev-compile,format,live-browser,restart-browser}.log`,
`literal-wait-{verification,prepare,restart,restart-browser}.json`,
`beta-latency-wait_literal-{runtime,browser}.json`.

El recolector temporal definido dentro de un callback de compilación pierde
su módulo al recompilar ese mismo gancho. Se recupera el módulo fuera del
proceso compilador y se conserva la traza/estado del observador existente;
no se vuelve a ejecutar la declaración ni se borra la evidencia. Los scripts
QA que definan módulos deben ejecutarse desde una tarea ajena al compilador,
para no incorporarlos por accidente a la compilación del gancho. El HTTP500
temporal se conserva en `literal-wait-finish-hook.html`; limpieza posterior
HTTP200 y ausencia de fuentes QA verificados.

D170: `wait_declaration_test.exs` cubre la declaración real de comida,
conversiones de unidades/cantidades y exclusiones. `wait_resolution_test.exs`
comprueba comprobante parcial/0 s tras codec/JSON, duplicado sin actor_checkpoint,
nuevo origen, límites/combate/legacy/malformed. Ocho Game verifican omisión
sin publicación, final solo tras reloj, duplicados/parallel/límite, interrupción
0/60 s, pausa/reapertura y restart supervisado después del commit parcial.
Dieciséis nuevos; cuatro rojos de gramática, tres Game, cuatro de comprobante;
27 focalizados en1,4 s sin errores/avisos. Gate ordinario2512/3 en48,0 s,
seed944912: tres desconexiones/dos Games durante limpieza, consulta snapshot
después del cliente terminado y títulos phase0/Mesa. Traza mismo seed/max_cases1,
2512/3 en56,4 s sin esos errores; no demuestra corregida su causa.
Repetir con --trace --max-cases48 sigue informando max_cases1:2512/3 en55,3 s,
una desconexión y una terminación Game. El llamador del último snapshot ya
ha muerto; los títulos SQL cercanos no bastan para identificar su fixture.
La incidencia también ocurre en una traza serial. No se añade una espera ni
se cambia el producto para ocultarla.

Proveedor19425/modelos iguales: espera de cinco minutos32,603 s, avance DM300
una vez,35400→35700, intento humano rechazado, comprobante y fact del rumor
previo durables. Solo reloj/comprobante/facts/log/escena cambian; recursos/
biblioteca iguales, cero dados. Recorder10,567 s y consulta TM; no se acredita
mejora de latencia, y la narración repite el rumor casi literalmente. Restart
conserva todo, cinco auxiliares cerrados y JSON válido; reload375/1440 px por
teclado sin JS/overflow, capturas revisadas y ganchos retirados.
`dragonex-wait-resolution-{parser-red,game-red,receipt-red,focused,full,full-trace}.log`,
`beta-latency-wait_required-{runtime,browser}.json`,
`wait-resolution-{prepare,restart,restart-browser}.json`.
La tercera traza se conserva como `dragonex-wait-resolution-full-trace-concurrent.log`;
su nombre no describe la concurrencia efectiva, que debe leerse del banner.

D168: `pc_response_voice_test.exs` cubre voz/acuerdo/scope con dos casos;
`game_pc_response_voice_test.exs` usa ambos textos reales de comida, verifica
messages codificados con personalidad actual junto a la pregunta y contexto
previo íntegro; cuatro actores una vez, sin cambios de World/dados/TM. Mantiene
también respuestas coincidentes: no certifica un filtro semántico. Dos rojos de
tres iniciales,39 focalizados en2,2 s; gate2493/3 en47,4 s, seed597997, sin
errores/desconexiones ni avisos de compilación. Ocho avisos de ejecución:
cinco del breaker simulado y tres de fixtures anteriores.
19425/modelos preservados: menú/elección11,739 s revela copia Vex/Lyra; nuevas
ideas10,198 s conservan acuerdo con otra prosa, cuatro peticiones/actores,
World/biblioteca/reloj34200 intactos, sin TM/recorder/tools. Preguntas distintas,
sin benchmark. Browser375/1440 px/teclado/recarga verificados.

D169: dos casos `history_compression_utf8_test.exs` envejecen el fixture exacto
del menú tras doce respuestas y prueban ¿/¡/NBSP, atribución, texto reciente y
JSON válido del proveedor. `game_history_compression_test.exs` cruza ese umbral
entre el humano y DM, codifica su petición real, aplica1200 s/escena y restart
sin duplicar tiempo/historia/recursos. Tres rojos/tres nuevos;18 focalizados en
0,6 s, gate2496/3 en47,1 s, seed681098, sin errores/desconexiones ni avisos
de compilación. Diez avisos de ejecución: cinco del breaker simulado y cinco
de fixtures anteriores; la verificación adicional siguiente los distingue.

19425: espera3,504 s falla con Jason antes del proveedor, World igual. Reparar
History devuelve respuesta en6,6 s sin error; DM omite tiempo. Confirmación
explícita1200 s/20,451 s aplica34200→35400 una vez: intento humano rechazado y
DM confirmado, recorder3,699 s; solo reloj/log/escena cambian, recursos/biblioteca
iguales y cero dados. La omisión natural sigue abierta; no se convierte el
smoke guionizado de tiempo en garantía de elección LLM. Restart conserva todo,
JSON válido, cierra cinco auxiliares; reload375/1440 px/teclado sin JS/overflow,
capturas revisadas y ganchos retirados. Siete dados históricos intactos, cero
en ventana reciente. `dragonex-pc-response-voice-{red,focused,full,dev-compile}.log`,
`dragonex-history-compression-{red,focused,full,dev-compile}.log`,
`beta-latency-meal_*-runtime.json`, `meal-choice-{verification,restart,restart-browser}.json`.

Verificación adicional,2026-10-03: nueve casos anteriores ya no se conforman
con un efecto parcial. Tres WorldFacts esperan el turno humano y comprueban
persistencia/ausencia de fallback; set_scene debe modificar positivamente
la escena, y el control negativo sin la tool falla. Dos casos TurnMaster
usan respuesta propia de Lyra y pausan antes de liberarla: el beat acaba,
la intención se consume y Escudo gasta una casilla y da CA efectiva17/base12.
Un caso PCAntiLoop recibe su propio guion PC y un DM sin guion finito; tres
respuestas diferentes exactas, sin nudge ni fallo. Tres casos DMPuppetPC
separan también PC/DM y verifican recorte/reminder/entorno después del beat.
38 focalizados en2,0 s, seed207258, sin errores/avisos.
El gate intermedio2496/3,46,9 s/seed30343,
tenía cinco avisos del breaker y uno del guion antibucle; ese último motiva
la corrección. El posterior2496/3,46,8 s/mismo seed, muestra dos agotamientos
de narración DM, también corregidos en esos fixtures. Se conservan ambos
logs sin atribuirles cero avisos.
`dragonex-world-facts-missing-scene-red.log`,
`dragonex-test-completion-fences-focused-final.log`,
`dragonex-meal-iteration-full-verified.log`,
`dragonex-meal-iteration-full-final-verified.log`.
Gate final2496/3 en48,0 s, mismo seed30343: cinco avisos del breaker simulado,
cero errores/desconexiones/avisos inesperados. Compile warnings-as-errors,
formato global/diff y HTTP200 correctos; sin ganchos QA.
`dragonex-meal-iteration-full-completed-beats.log`,
`dragonex-meal-iteration-dev-compile-final-verified.log`.

D167: `npc_literal_speech_test.exs` añade tres casos de interrogante exacto,
scope registrado y exclusiones por acciones/persuasión/prefijos. Tres en
`game_npc_literal_speech_test.exs` verifican primera petición DM/history,
restart con DM esperando sin repetir humano y pregunta+False Life con una
casilla/dado/PG temporales5. El reinicio usa Game.ensure_started para que lo
gestione TableSupervisor; un arranque directo del fixture no acredita restart.
Un caso LiveView confirma el formulario, respuesta humana inmediata, retorno
y reload con World intacto. Siete nuevos; cinco rojos de seis iniciales.
Un oráculo preserva la minúscula real del interrogante; no cambia el producto
para normalizarla. Scripts PNJ previos omiten la reformulación humana; el caso
de tool request_response usa una observación adicional y conserva ruta normal.
**69** focalizados en3,9 s; gate ordinario **2490 passed / 3 excluded** en47,6 s,
seed886859, sin errores/warnings ni desconexiones. Limpieza D163/D166 abierta.

19425: pregunta por invitación4,536 s hasta humano, una petición DM de3,911 s,
sin petición humana/TM/recorder/tools ni dados; eventos mantienen interrogante
exacto una vez y declaración completa. Maribel confirma guiso/pan/jarra gratis,
vino/licor aparte. World/reloj34200/biblioteca/modelos iguales; restart mantiene
estado/historial/cursor/intenciones y cierra cinco auxiliares. Reload375/1440 px/
teclado sin JS/overflow, una respuesta visible y capturas revisadas. Siete dados
anteriores íntegros, uno en ventana reciente. Ganchos retirados. `dragonex-npc-
literal-speech-{red,focused,full,dev-compile,browser,restart-browser}.log`,
`npc-literal-speech-{verification,restart,restart-browser}.json`. No se compara
latencia de preguntas distintas ni se garantiza toda semántica/caída humana.

D166: `local_scene_review_test.exs` cubre movimiento literal y exclusiones,
confirmación idéntica sin escritura y el rechazo intacto para cambios mecánicos
pendientes. `game_local_scene_review_test.exs` usa textos exactos de la entrada
real, ausencia de set_scene, petición estructurada sin tools de reglas, recursos,
cola/historial/pausa/reapertura; fallo conserva pending, registro humano/DM ya
aplicado evita consulta y preguntas/observaciones/IA no activan revisión.
Once casos nuevos, seis rojos iniciales;68 focalizados. El primer gate47,3 s
(seed8106) detecta el caso humano ya registrado y dos desconexiones de limpieza;
se corrige preservando scene_before en la acción, sin cambiar esa expectativa.
Gate final con trazas/mismo seed2483/3 en54,4 s sin errores/warnings. La limpieza
sigue abierta. Los dos primeros oráculos de narraciones incluían la introducción
inicial de Games.create_game; se comparan solo eventos añadidos por la acción.

19425: pregunta PNJ8,657 s sin TM/World igual; entrada15,713 s omite registro
(6,5 s narraciones/8,7 s TM). Nueva declaración hacia barra22,895 s: DM sin tools,
recorder9,579 s/un paso y TM6,274 s; solo escena/log se actualizan, reloj34200,
recursos/biblioteca/encargo intactos y cero dados nuevos. Pregunta menú5,026 s
sin TM/recorder y World igual. Modelo scene deepseek-v4-flash-0731 preservado;
no se compara con el resumidor por defecto ni se acredita un SLA. Restart
conserva World/historial/cursor/intenciones/modelos, cierra cinco auxiliares;
reload375/1440 px/teclado sin JS/overflow y capturas revisadas. Un grupo de dados
en la ventana reciente, siete históricos en crónica completa, sin borrados.
Un cierre del gancho QA intenta cargar otra vez Beats y recibe not_purged;
se retira esa carga repetida y la captura termina sin alterar la mesa.
Ganchos retirados. `dragonex-local-scene-review-{red,focused,full,full-trace,
dev-compile}.log`, `beta-latency-{verification,restart,restart-browser}.json`.

D165: `game_exploration_clock_test.exs` añade dos casos. La llegada real al
molino había actualizado escena sin reloj; raw DM solo set_scene. Dos rojos
comprueban que falta advance_time en el contexto de la petición DM; no prueban
un fallo del motor, que ya avanza correctamente con la tool. Los smokes resuelven
900 s, caducan Inspiración y conservan PG/casillas/rest_state; restart después
del avance recupera el comprobante sin sumar otro900 s. Un caso nuevo en
`brief_clock_context_test.exs` limita la guía al DM en exploración, fuera de
PC/TM/combate. **35** focalizados y **2472 passed / 3 excluded** en46,9 s sin
errores/warnings. Compile/formato/diff correctos; limpieza D163 sigue abierta.

19425 con mismo modelo por rol: invitación17,833 s conserva World y respuestas
propias. Viaje inicial34,751 s cambia escena pero no reloj; tras cargar Brief
nuevo sin cambiar World/modelos, confirmar el tramo registra32400→33300 en
35,721 s. Nuevo viaje hasta plaza/Ciervo:33300→34200 en47,54 s. Solo cambian
reloj/log/escena; recursos, fichas, encargo y biblioteca intactos, cero dados
nuevos. El cierre adicional Vex/DM reemplaza history del primer DM de llegada;
no atribuirle su lista vacía de tools. Restart con modelos por rol conserva
World/historial/cursor/intenciones, cierra cinco auxiliares; reload375/1440 px/
teclado sin JS/overflow y siete dados antiguos conservados. El primer oráculo
web esperaba cero dados totales; se corrige para mantener los siete históricos,
no se cambia producto para borrarlos. Capturas revisadas, ganchos retirados.
`dragonex-exploration-clock-*`, `adventure-choice-{verification,restart,
restart-browser}.json` y capturas por etapa. El registro inicial requirió
confirmación explícita; no prueba selección universal de tools ni un SLA.

1. **Determinismo**: nada de `:rand` en `Rules`/`Actions`/`World` — el roller
   se inyecta (`Dice`/`dic_ex` en prod; `seq([...])`/`always(n)` en tests).
   Un test puede decir "el d20 sale 20 → crítico" y asertar el resultado exacto.
2. **Oráculo independiente**: la matemática 5e se verifica en `Rules`/`Actions`
   **sin** LLM de por medio; los flows de agentes asertan sobre el **World**
   (estado), no sobre el texto de la narración. El LLM puede mentir; el test
   no le cree.
3. **Offline por defecto**: la suite no toca red. Lo que exige modelo real es
   `--include integration` (opt-in, `DRAGONEX_RUN_LIVE=1` + API key).
4. **Builder sin DB** (D9): `Heroes`/`Catalog` son puros; el contexto custom
   se inyecta. Sus tests corren `async: true`.
5. **Pirámide**: muchísimos unitarios del motor → flows de integración del
   bucle → un puñado de LiveView → smoke de LLM.

---

## Capas (dónde va cada test nuevo)

| Capa | Qué | Dónde | Modo |
|---|---|---|---|
| **L1 — Motor puro** | `Rules.Ability`/`Rules.Combat`/`Rules.Conditions`/`Rules.Skills`/`Rules.Upcast`, `Actions`, `World`, `Dice`, `SpellSlots` (mecánicas `M1`–`M60`) | `test/dragonex/rules/`, `test/dragonex/{actions,world,conditions,spell_slots,rest,world_facts,ghost_combat,healing_and_bestiary}_test.exs` | `async: true`, rollers fijos |
| **L2 — Builder/catálogos** | `Heroes.build`, catálogos SRD, `LevelUp`, validaciones, custom content mechanics | `test/dragonex/heroes/*`, `test/dragonex/accounts/level_up_test.exs` | `async: true` sin DB (D9) |
| **L3 — Bucle y persistencia** | `Game` GenServer, beat completo con TestModel, retries/breaker, rehidratación, sync level-up, multiplayer, codec round-trip | `test/dragonex/{game_*,multi_level,persistence,turn_master*}_test.exs`, `test/dragonex/flows/*` | DB sandbox (ECTO Sandbox) |
| **L4 — Web** | LiveViews (mesa, wizard, level-up, custom content), auth | `test/dragonex_web/*` | `conn_case` + LiveViewTest |
| **L5 — Smoke LLM** | Un beat con `TestModel` (offline) por cada flujo de agente tocado | junto al flow que toca | offline |
| **L6 — Integración live** | Narración real contra proveedor | `flows/live_*_test.exs` | `--include integration`, opt-in |

Censo histórico D77 por área (bloques `test` estáticos; sus 1511 casos
incluyen además los generados dinámicamente por comprensión, p. ej.
`srd_golden_test`): motor/game+flows (raíz, `game/`, `flows/`) ~1080 ·
heroes ~200 · rules ~44 · web ~42 · accounts ~22.

---

## Qué exige cada tipo de cambio

| Si tocas… | Mínimo de tests |
|---|---|
| Una mecánica (`Rules`/`Actions`/`World`) | L1 determinista + entrada en [`08-catalogo-mecanicas.md`](08-catalogo-mecanicas.md) |
| Una tool (firma/guarda/set) | L1 de la mecánica + smoke L5 del flow + update de [`07-contrato-tools.md`](07-contrato-tools.md) |
| El bucle (`game.ex`, TurnMaster, policies) | L3 del camino feliz Y del fallback (TurnMaster roto → WorldDriven, D25) |
| Prompts (DM/PC/TM) | L5 smoke +, si cambia comportamiento observable (idioma, repetición), test de guardrail (`dm_anti_repeat_test.exs` estilo) |
| Persistencia (`Codec`, schema) | Round-trip `codec_test.exs` + rehidratación `game_sync_genserver_test.exs` |
| Builder/catálogo | L2 + (si es derivado SRD) caso golden de ficha (ver F6.5) |
| LiveView | L4 del evento user-facing (click→evento→render) |

## Tests de robustez (ya existentes — no romper)

Retries/backoff/breaker (`game_retry_test.exs`), combate fantasma
(`ghost_combat_test.exs`), anti-loop PCs (`pc_anti_loop_test.exs`), anti-puppet
DM (`dm_puppet_pc_test.exs`), limbo de exploración (`exploration_limbo_test.exs`),
UTF-8/español (`text_test.exs`), rehidratación tras kill
(`game_sync_genserver_test.exs`), efectos/dados al inicio del turno con
fallback del TM/actor (`game_start_turn_effects_test.exs`, D100).
Ese archivo prueba también fin de combate por aura antes de esperar (D104).
`text_puppet_dialogue_test.exs` usa una salida real del playtest y conserva
PNJ/estados pasivos (D103); `turnmaster_context_test.exs` inspecciona mensajes
del runner por relevo y durante validación (D105). La fixture real de seis
PCs y casos D119 cubren gesto con aposición, comentario, citas sucesivas y
streaming incompleto, con controles de PNJ/estado pasivo/voz propia e
historial compartido. `protected_routes_test.exs` usa sandbox compartido con
el socket y UUID para aislar su registro entre ejecuciones. Las pruebas web de
autorización, historial y controles tienen sus regresiones en
`game_{viewer_authorization,history_live,table_controls}_test.exs`.
`game_actor_failure_test.exs` conserva acciones comprometidas tras errores,
releva dos monstruos consecutivos y cierra la ronda sin consumir mini-turns
(D107); `turn_budget_test.exs` verifica el mensaje directivo fuera de turno.
`game_combat_fallback_test.exs` añade handoff/cambio de fase, iniciativa y
acción dentro del beat, apertura sin acción, ronda nueva, muerte/caída y
retorno de mini-turn sin refresco; incluye contexto del runner Game/TestModel
tras un ataque comprometido (D110).
`game_combat_handoff_test.exs` verifica relevos principales impuestos por
iniciativa, sin petición al TM en los casos ordinarios (contador de modelo),
retorno de reacción, contexto del monstruo, ronda, PC caído y aura/persistencia
(D113). Los tests anteriores de consulta inyectan `combat_handoffs: :turnmaster`
para seguir ejecutando captura, fallbacks y errores del agente; la iniciativa
se impone también en ese modo.
`game_reaction_rehydration_test.exs` reabre mini-turns pausados de humano,
PC IA y monstruo DM, incluido un fallo tras gastar Escudo; conserva el ledger
principal y los recursos comprometidos del reactor/dueño (D114).
`conversation_test.exs`/`game_conversation_test.exs` verifican petición
explícita a PCs, orden y voces reales, contexto con la respuesta anterior,
roles/schema, recursos y JSON/World en memoria anteriores. Pausa con humano
esperando o tras una respuesta IA, errores de origen/respondedor/DM, caída
antes de reabrir y re-eval muda con intervención humana encolada. Contador
TestModel comprueba cero consultas TM en el recorrido determinado. Mesa real
de seis muestra Iria → Nera → Lyra → DM → Iria en 25,26 s, sin cambio de
PG/casillas/reloj; pausa/reload sin JS/overflow (`conversation-*`, D120).
La fixture `pc_iria_foreign_gesture.txt` y `text_puppet_dialogue_test.exs`
comprueban preguntas propias, gestos/citas ajenos, relativas, streaming,
estados pasivos/PNJs y nombres escapados. Dos casos Game/conversación verifican
que el siguiente agente recibe las narraciones ya recortadas, con voces,
recursos y persistencia conservados (D123). El control de sujeto reproduce
un falso recorte anterior al tomar el verbo de un PNJ posterior.
Otra pregunta real al grupo da Iria → Nera → Lyra → DM → Iria en 17,12 s,
con PG/casillas/escena/reloj intactos y pausa/reload sin JS/overflow
(`pc-voice-*`); no se reescribe la historia anterior.
`scene_presence_test.exs`/`game_scene_presence_test.exs` separan presencia de
PG/muerte, excluyen objetivos/áreas/auras/iniciativa, rechazan acciones ya
preparadas y conservan recursos/efectos/plazos/ledger tras volver. Incluyen
JSON legado, roles DM/PC, Game reabierto y fallo posterior a salida (D115).
La arena real verifica retirada/reentrada de una diana dañada, con ficha y
casilla conservadas (`/tmp/dragonex-playtest/presence-live.log`).
`game_forced_initiative_test.exs` verifica iniciativa automática tras éxito
o fallo terminal: dados exactos con roller inyectado, eventos/historial sin
duplicados, World/Postgres y primer slot pendiente. Controles para iniciativa
explícita, hostil preexistente y escritor no admitido. El navegador observa
ambos grupos en modal/crónica (`forced-dice-live.log`, D116).
`game_lobby_transition_test.exs` retrasa un socket real hasta que Game espera
o se pausa; la sala debe entrar igualmente en mesa (D111). Las pruebas de
controles incluyen declaración desplegable literal y escape HTML (D112), con
recorrido de dos cuentas/navegador en `/tmp/dragonex-playtest/shared-verify.log`.
`game_lobby_admission_test.exs` comprueba copias obsoletas, consumo de plazas,
rollback por identidad ambigua, reintentos y segundo inicio sin reset. El
bloqueo de fila serializa unión/inicio; los casos deterministas usan copias
obsoletas, no afirman una prueba de carga con conexiones simultáneas.
`game_lobby_join_test.exs` cubre motivo/estado/reintento, IDs inválidos,
última plaza/inicio tras abrir el selector y sala eliminada en click/aviso.
Dos cuentas reales a 375/1440 px muestran el error completo junto al selector,
reintento por Enter, grupo compartido y recarga sin JS/overflow (D121).
`lobby-admission-viewport-red.log` reproduce el aviso fuera de pantalla antes
de acercarlo al selector; `lobby-admission-live.log` comprueba la corrección.
`wizard_choice_test.exs` comprueba controles nativos, selección al volver,
habilidades/idiomas/hechizos/equipo, compañeros deshabilitados y texto custom
conservado. Simula la metadata `button.value` que el cliente LiveView añade
después de `phx-value-*`. El navegador recorre ambos asistentes con teclado,
guarda/reabre una clériga, crea partida con dos PCs IA y verifica pausa/reload
a 375/1440 px (`wizard-keyboard-{live,verify}.log`, D117).
`game_party_visibility_test.exs` conserva los seis PCs y la ficha propia,
excluye ausentes, mantiene caídos y acota no-PCs. Verifica compañeros/DM
en cajón móvil y actualización de PG por ataque real de DM a través de Game,
World/Postgres/LiveView. Navegador con grupo real de seis, apertura conservada
tras PubSub, pausa/reload a 375/1024/1440 px y retirada factual de diana
(`party-after.log`, `presence-cards-live.log`, D118).
`cast_spell_contract_test.exs` contrasta el schema de DM/PC con la ejecución
real del runner y el rechazo sin gasto de selectores inválidos (D108).
`game_sheet_state_test.exs` cubre defensas/estabilidad/muerte, reservas reales,
nombres de turnos y gasto de casilla a través de Game + recarga LiveView (D109).
Un cambio en el bucle que pase la suite
rompiendo alguno de estos **no está terminado**.

---

## Protocolo de verificación (antes de declarar "hecho")

```sh
mix compile --warnings-as-errors   # 0 warnings
mix format --check-formatted       # formato limpio
MIX_ENV=test mix test              # 0 failed; referencia actual en progress.md
```

Y según la tabla anterior: tests nuevos de la capa que toca, docs actualizados
 (`progress.md` mueve el ítem; ADR si hay decisión). Con API key disponible,
opcionalmente: `DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=… mix test --include integration`.

## Límites declarados

- No hay CI que corra la suite en cada push (pendiente de infra; el verde de
  referencia es local). Al añadir CI, este doc es el contrato de qué correr.
- Golden SRD del creador (F6.5): `test/dragonex/heroes/srd_golden_test.exs`
  (12 clases × L1/L3/L5).
