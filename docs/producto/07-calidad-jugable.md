# Calidad jugable — trabajo sostenido

Inicio: 2026-10-01. Estado: **activo**, por petición del usuario. La referencia
es el mundo visual D84 y el corte de V1; se conserva el trabajo anterior del
checkout. No se considera terminado por añadir mecánicas o por pasar una suite.

## Criterios de salida

| Recorrido | Evidencia necesaria | Estado actual |
|---|---|---|
| Crear y recuperar un héroe propio | Builder, guardar/reabrir y usarlo en partida desde navegador | Mara L2 desde navegador, seis mesas y pestaña antigua verificados; Iria creada/reabierta por teclado |
| Jugar una aventura corta | Explorar, declarar, iniciativa, turnos humanos/IA, dados y fin de combate | Granero: goblin derrotado, encargo/recompensa durables y descanso Mara; destinatario D142 y relevo explícito Vex D143 comprobados |
| Conservar la partida | Pausa, reload, caída/reinicio, PG/recursos/intenciones coherentes | Reinicio real tras combate/descanso del granero conserva World/historial/recursos; ampliar variantes de fallos y campaña |
| Mesa compartida | Cada usuario controla su PC; secretos solo para DM creador | D101/D111/D112 y dos sesiones reales: unión/inicio, intenciones, identidad, DM, pausa/reload |
| Lectura y acciones cómodas | 375–1440 px, teclado, ficha, borrador, historial que conserva posición | Ficha/declaraciones/asistentes por teclado a 375/1440 px; ampliar grupo completo, ajustes y esperas |
| IA coherente y fluida | Estado vigente, resultados solo por tools, decisiones propias de cada PC, espera comprensible | D100/D103/D105; medir más turnos y corregir errores de actor fuera de turno |
| Cierre técnico | AC aplicables, suite completa, compile sin warnings, formato y diff correctos | D222/D223: gates completos2859/3 local y2849/3 Hex, secuenciales y limpios; compiles test140/prod Hex133 limpios. Entrega live fallida19447/52, R16 y AC-31.3d pendientes |

«Da gusto jugar» exige que no queden bloqueos o confusión conocidos en estos
recorridos. Los límites del SRD, geometría y progresión se mantienen explícitos;
no se exige convertir las 319 entradas del catálogo en mecánicas como parte
del cierre de calidad.

## En curso — publicación estructurada (D222)

La frontera está verificada con 15 casos en ambos grafos y un caso adicional
del adaptador ReqLLM stock. Conserva respuestas nativas privadas, retiene
deltas y solo publica cierre aislado/validado con requisitos resueltos.
DM/PCAgent/Beats ya la usan por defecto en ambos grafos. narrate registra
declaraciones intermedias; cierre inválido recibe corrección acotada y pausa
recuperable, sin repetir efectos. Game guarda publicación/comprobante juntos
antes de Session/PubSub, incluso sin tools previas.19 casos nuevos/271 focales
locales/269 Hex verifican integración, pausa manual respetada y transporte
stock con memoria PNJ/output.109 archivos anteriores migrados, con otros9
casos por grafo de espera con magia/PNJ/observaciones/iniciativa SQL y otros30
de voz/ritmo, memoria de tiradas y agencia/actualización de escena. Tandas
posteriores local/Hex:25/23 PNJ/escena/retry stock,55/55 efectos/persistencia/
ciclo de vida,68/68 mesa web/reacciones/progresión,13/13 hechos/antibucle,
17/17 iniciativa/relevo,21/21 TurnMaster y3/3 lobby/ficha móvil.
Las pruebas web conservan los
oráculos de recursos/dados/World y recarga; previews inyectados solo acreditan
el render legado. Gates completos de integración D222:2858/3 local y2849/3 Hex,
en105,3/63,8 s, seed0/max_cases48, secuenciales y sin warnings/errores/
desconexiones. Preview estructurado de R16 y nueva partida live pendientes. AC-31.3d
permanece pendiente. No se cuenta como corrección del flujo jugable de 19446.

Base previa:55 focales locales/54 Hex; gates 2839/3 y 2830/3, compiles propios forzados
sin warnings y formato/diff limpios. SQL/web 1440/375 conserva todas las voces
y World de 19446/42, originales y 47 estilos; cero JS/overflow y bundle sibling.
El readback conserva deliberadamente la reproducción, sin otro beat LLM.

Nueva19447/52 con contrato activo: iniciativas completas, golpe humano real
por4 y voz literal, Lyra magic missile14/casilla y recogida×1. Entrega falla
por retención error6300/4096, dejando objeto en Thane y sin cierre/comprobante;
volver al turno humano no cuenta como resolución. Restart UI/reload1440/375
conserva la reproducción,47 estilos y todos los originales; sin JS/overflow.
Prosa DM intermedia/final repetida, sin reasoning visible en la muestra.
D223 corrige una reproducción general de esa pérdida de causa en el sibling
v2, con102/58 focales de framework y23 de Game; causa original de19447 y
arreglo live no acreditados. Gates posteriores2859/3 y2849/3, limpios.
Fallback sin resolución y R16 siguen abiertos.

## Entregas verificadas

- **D221 / R31**: el resolutor manual conserva herramientas pero su voz
  procede de la declaración original del mismo turno. Sin prosa/deltas
  inventados; History conserva intención/UTF-8/texto, retry/restart reusan
  recibos y fallo definitivo avisa como sistema.15 nuevos/93 focales por
  grafo y gates2823/3/2815/3, compiles propios forzados/formato/diff limpios.
  Nueva19446/42 conserva tres voces exactas, campanilla×1 entra/sale y demás
  PG/stock/slots/reloj0 tras restart UI/reload1440/375; originales protegidos.
  Vex derrota al bandido, sin golpe humano propio inicial. El DM sigue
  publicando razonamiento, adornos humanos y cierre sin fact. Esos defectos,
  tres retries iniciales y fluidez impiden declarar beta lista.

- **D220 / R31**: la continuación DM/PC recibe desde su segunda petición el
  World vigente leído de Session, con tipos de participantes correctos. Cinco
  nuevos, rojo2/5 y17 focales por grafo: humano/Vex ven PG0 tras golpe fatal;
  stock renovado/foto única, dados/recursos/reloj/SQL exactos. No cambia
  canonical/Events/prosa ni cierra combate desde la capability. Corrige
  información antigua entregada; no garantiza obediencia o latencia real.
  Gates2808/3/2800/3 sin errores/desconexiones. Aclaración Ada109→116 en
  12,262 s/cero retries guarda testimonio con fuente/duda/606 s, solo facts
  cambia; voz humana exacta y encargo/recursos íntegros tras restart UI/reload.

- **D219 / R22**: el mensaje de control ya no pide actuar como dm cuando
  falta una ficha. Diferencia desconocido/ausente/controlador y actores
  disponibles, sin cambiar permisos/World/RNG. Cinco nuevos, rojo1/5 y29
  focales por grafo. TestModel registra criatura tras rechazo y después dos
  iniciativas. Live19444/44→67 incluye cuatro slots/dados, esqueleto13PG y
  dos fallos PCs sin gasto adicional; un retry/handoff_failed, sin garantía
  general. Combate67→88 recorre monstruo/ronda y deja Thane4PG; recogida,
  regreso300 s y entrega declarados por separado88→109 añaden/retiran
  farol×1 y guardan cierre, sin curación/regalo. Los tres sin retries;
  reinicio de agentes UI y reload1440/375 conservan estado/historial completos.
  Continúan abiertos voz/armas/resultado narrado, memoria PNJ no registrada
  y fluidez/formato. Este recorrido cerrado no acredita beta lista.

- **D218 / R35**: cada reintento por argumentos inválidos req_llm recibe
  feedback temporal de schema, sin body privado/canonical/Events alterados.
  Cuatro nuevos, rojo1/4 y43 focales por grafo; DM/TM efectivamente lo reciben,
  efectos/dados/turnos no se duplican. Gates2798/3/2790/3 limpios; restart UI37
  conserva todo.37→44 llega a error semántico de actor; no recuperación total.

- **D217 / R30**: ambos self-handoffs DM ordinarios ceden a persona disponible.
  Tres nuevos, rojo8/11 y32 focales por grafo, cero/dos compañeros, farol×1/
  reloj/escena/SQL exactos. Gates2794/3/2786/3 limpios.19443/107 conserva la
  reproducción del viaje/entrega no declarados;19444 creada desde UI para
  reensayo. Formato y registro de entidades siguen abiertos.

- **D216 / R29**: Game recupera el orden incompleto idle con la regla de
  refuerzos: hostiles vivos/presentes omitidos al final, sin dados inventados
  ni turnos repetidos. World/nota atómicos antes de Session, fallo SQL pausa
  y retry idempotente; intentos pendientes intactos. Seis nuevos, rojo0/6 y
  36 focales por grafo. Navegador 19443/68→69 añade esqueleto y nota visible,
  conserva Thane/Vex, prefijo, PG/recursos/reloj300; solo order/log cambian.
  1440/375 sin JS/overflow, bundle sibling. Seguir pelea y encargo; beta activa.

- **D215 / R29**: el esqueleto existe en 19443/68 pero falta de iniciativa.
  Control puro reproduce preparación anterior al spawn aceptada después;
  snapshot de nombres/DEX ahora se revalida al commit. Alta/salida/caída/DEX
  rechazan con indicación de preparar de nuevo; tres nuevos, rojo 1/3 y 53
  focales por grafo. La reproducción guardada sigue pausada; recuperar/reprobar
  antes de continuar combate, farol y regreso. Beta activa.

- **D214 / R31**: guía de continuación tras prosa pública intermedia de este
  actor/turno. Tres nuevos, rojo 0/3 y 27 focales por grafo; no borra/oculta
  relato ni cambia historia/recibos/World. Plan PC 28→38 preserva World;
  trayecto 38→46 registra 300 s una vez. Apertura 46→68 no repite aquel
  párrafo en 58/62, pero registra handoff fallido y dos retries recuperados;
  fidelidad/brevedad y estado de iniciativa quedan abiertos. No obediencia
  semántica universal, beta lista ni SLA.

- **D213 / R31**: preguntas a PNJ por nombre con roster PC/exclusión de
  identidad, «¿Sabes si…?» y guardas de consecuencias. Cuatro nuevos,
  rojo 9/12 y 50 focales por grafo; restart/memoria/magia mixta verificados.
  Tras voz exacta 13→21, persiste rechazo. Stock buffered/stream fresco entrega
  argumentos planos; exAgent v2 ahora explica su envelope en Context backend,
  sin cambiar schema/codec/validación. 131 focales del paquete; gates 2779/3/
  2771/3, seis avisos deliberados y sin errores/desconexiones. 21→28 en 11,564 s
  conserva voz humana, responde Ada y guarda un testimonio con límites/fuente,
  cero retries inválidos y solo facts cambiado. 1440/375/PNG sin errores JS ni overflow
  horizontal; relojes/recursos/otra mesa/hero exactos. Mesa 28 pausada;
  decisiones PC/trayecto/combate/regreso aún pendientes. No SLA/generalización,
  no publicar/deploy, beta activa.

- **D212 / R10**: el creador fallaba con estilo476 (SQL22001), sin insertar.
  dm_style ahora text; título255 se valida por puntos de código antes de
  insertar/avanzar. Alerta asociada y elecciones recuperables, incluso con
  cambio final forjado. Cuatro nuevos, rojo causal2/7,30 focalizados por grafo
  y gates2775/3/2767/3 limpios. DMStyle largo llega al request tras restart.
  Migración test/dev preserva47 estilos/default/mesas/hero; prod pendiente.
  Chrome1440/375/teclado/PNG sin JS/overflow crea19443/3D/estilo476 exacto,
  pausada6. Primera pregunta a Ada6→13/31,821s conserva World, pero reformula
  Thane y termina en fallback tras tres reintentos inválidos, sin respuesta
  ni memoria. Revisar nombre PNJ/argumentos antes de viajar; beta abierta.

- **D211 / R32**: una a tres preguntas informativas consecutivas a los mismos
  PCs conservan voz literal y cierre acreditado. Cada pregunta/espera debe
  calificar; acciones intermedias/exteriores, petición de acción, identidad
  incierta o cuarto interrogante conservan resolución. Nueva pregunta PNJ,
  dado sin efecto World, magia o intenciones no quedan ocultos por el cierre.
  Seis nuevos, rojo20/26,64 focalizados por grafo y gates2771/3/2763/3
  secuenciales limpios; restart y magia mixta verdes.
  Primer25/26 cuenta apertura DM como cierre: se corrige el límite del fixture
  conservando su prefijo, sin cambiar producto. Consulta idéntica934→944/
  4,061s publica palabras exactas de Mara, dos respuestas PC y retorno sin
  turno/narración DM. World/15 facts/reloj/recursos/otra mesa/hero iguales,
  QA1440/375/SQL/PNG sin JS/overflow, assets iguales al sibling. Lyra74/Vex47
  palabras y criterios de cautela propios; semántica/brevedad generales siguen
  abiertas. Continuar campaña/preguntas distintas, no solo repetir la pista;
  sin SLA o cierre beta, sin publicar/deploy.

- **D210 / R25**: proyección del orden retenido de testimonios y última
  entrada por fuente, sin unir apodos/roles distintos ni borrar versiones.
  Misma marca de reloj no obliga a inventar fecha; duplicado retenido no se
  mueve/renueva y legacy sigue desconocido. Guía conserva aclaración de fuente
  o límites sin darle verdad automática. Rojo5/12, cinco nuevos y46 focalizados
  por grafo y gates2765/3/2757/3 secuenciales limpios; Game entrega contexto tras archivo/compacción adversa y restart
  sobre Vex sin repetir Lyra/humano ni gastar recursos. Consulta nueva921→934/
  15,905s mantiene World/15 facts/recursos/reloj/otra mesa/hero. Vex conserva
  límite de visión cercana; respuestas86/66 palabras siguen extensas y con
  matices abiertos. Pregunta doble aún provoca reformulación humana y cierre
  DM porque la ruta literal PC solo admite una. QA readonly1440/375/SQL/PNG
  sin JS/overflow, assets iguales al sibling. Entrega orden/procedencia, no
  semántica/SLA; beta activa. Siguiente caso: varias preguntas informativas a
  los mismos PCs con habla literal y cierre acotados, además de voz/brevedad.

- **D209 / R32**: el siguiente compañero recibe contexto atribuido de las
  intervenciones públicas completas tras la acción exacta de la pregunta
  vigente, sin inventar voz por retirar a alguien de pending. Omite privados/
  borradores/anclas ausentes y texto excesivo entero; no convierte diálogo en
  facts. Sobrevive restart del segundo compañero y compacción adversa. Formato
  final de diálogo directo, sin narrador/gestos y propuesta condicional.
  Seis casos nuevos,27 focalizados por grafo, gates2760/3/2752/3 separados.
  Una colisión DDL de fixtures entre VMs queda atribuida por ambas sentencias
  Postgres; protocolo exige secuencia o DB distintas, sin quitar rollback.
  Mesa901→911→921 conserva World/15 facts/reloj/recursos/otra mesa/hero. Última
  consulta7,166s no añade gestos de narrador; aún76/61 palabras y matices de
  fuente. Reload1440/375/SQL/PNG sin JS/overflow. No cerrar beta ni certificar
  brevedad/fidelidad semántica o percentiles de latencia. Continuar aclaraciones
  posteriores frente a versiones previas y memoria de otras preguntas.

- **D199 / R25**: repetir testimonio con comillas externas equivalentes
  conserva primer texto/marca/posición o legacy sin fecha; no expulsa hechos
  retenidos al cap. Nuevos cuerpos sin envoltura redundante, citas internas/
  parciales/apóstrofos y límites vigentes. Vacío citado rechaza. Nueve nuevos,
  rojo final1/9 contra fuente exacta D198, verde9/9 y43 focalizados1,6 s;
  dos8/9 iniciales corrigen fixtures (no-op/checkpoint y pregunta que consumía
  modelo humano); Game comprueba actor DM y replay/repeat/restart conserva
  un solo fact/recursos/SQL/Codec. Gate2709/3 en55,9 s limpio, seis avisos
  deliberados; formato/compile/diff correctos. Sin beat LLM/hook/PNG nuevos.
  SQL conserva19425/806/14 facts originales/World/eventos/hero/recursos y
  otra mesa íntegra; UI1440/375/teclado/reload sin JS/overflow. Equivalencia
  textual acotada, sin interpretación de significados ni fuentes/fechas
  inferidas. Opiniones/voces propias, semántica libre y beta siguen abiertas.

- **D198 / R25**: después de registrar la comparación del zagal, ambos PCs
  afirmaban haberla visto. Brief separa hechos/testimonios existentes sin
  mutarlos y guía final conserva fuente frente a prosa/resumen equivocado.
  Ocho nuevos rojo0/8, verde8/8; aviso de fixture constante corregido;46
  focalizados1,8 s y2700/3 en55,5 s limpios (seis avisos deliberados). Game y
  compacción DM/PC conservan contexto actual/SQL/Codec/archivo/recursos.
  Misma pregunta real796→806/6,616 s atribuye la comparación al zagal, solo
  dos requests PC, sin tools/World/dados nuevos.772→806: regreso900 s/un fact,
  cuatro acciones/cero dados, inventarios/plazos/hero/facts previos intactos.
  Reinicios conservan modelos/ajustes/eventos y cierran cinco auxiliares;
  hook retirado/Show exacto/UI1440/375/teclado/dos PNG revisados, cero JS/
  overflow; navegación no cambia ambas mesas. Sin baseline completa de la
  otra mesa anterior a acciones ni cierre del segundo request TM del regreso.
  Caso de fuente corregido; voces parecidas, detalles solo en prosa y
  deduplicación de envolturas quedan abiertos. No certifica toda memoria,
  semántica libre/hardware/Safari/lector de pantalla ni beta lista.

- **D197 / R21**: heal/grant_temp_hp/apply_condition/remove_condition/level_up
  directos exigen DM antes de World/target/RNG. El humano comparte DMServer
  para Rules y ya no puede eliminar veneno, darse PG temporales o subir nivel
  directamente. Se restringe permiso PC D36; hechizo/feature conserva fuente,
  coste y reglas. Puro rojo3/9, verde9/9; fixture de aviso nivel sin actor se
  adapta a DM ilegible sin leer World. Dos Game normal/restart conservan False
  Life pagado, slot/dado/plazo únicos, veneno/compañera/nivel; DM cura después
  con su único dado nativo. Segundo aliento mantiene bonus/uso único. Once
  nuevos,15 verdes0,4 s,103 focalizados3,2 s y2692/3 en56,2 s limpios; seis
  avisos deliberados en gate. Un path ignorado por Mix no se cuenta como prueba.
  Formato/compile/diff correctos. No hay nuevo beat LLM: TestModel/Session/Game/
  Postgres verifica esta corrección;19425/772/World/eventos/recursos/hero/facts/
  otra mesa intactos vía SQL readonly. Navegación1440/375 conectada/sin JS/
  overflow, sin hooks/PNG nuevos. AC-21.4 entregado para cinco tools; fuente de
  adjudicaciones DM/agencia/voz/dudas/memoria/latencia y beta siguen abiertos.

- **D196 / R22**: guardas DM tempranas en spawn_monster/roll_initiative/
  end_combat cierran ejecución por humano/PC que comparte DMServer para Rules.
  Rojo2/9 confirma creación de goblin/fin/RNG no autorizados; nueve verdes y
  dos Game normal/restart conservan estado/SQL sin dados humanos. Spawn DM
  mantiene iniciativa automática nativa y refuerzo no repite dados. Primera
  fixture Game invirtió orden de roller: se corrige a Goblin/Mara del motor;
  11/11 en0,4 s,99 focalizados2,8 s y2681/3 en55,8 s limpios. Seis avisos
  deliberados en gate; formato/compile/diff correctos. No hay acción LLM nueva:
  TestModel/Session/Game/Postgres verifica esta corrección;19425/772/World/
  eventos/recursos/hero y otra mesa intactos vía SQL readonly. Navegación normal
  1440/375 conectada, modal/lienzo correctos, cero JS/overflow, sin hooks/PNG
  nuevos. AC-22.3 entregado; alcance tres tools, otros permisos/voz/dudas/
  memoria/latencia y beta siguen activos.

- **D195 / R25**: una pista real guardada por humano revela permiso excesivo
  de establish_fact/set_scene. Ambas exigen DM antes de leer/proponer World;
  chequeos propios siguen válidos, facts legacy permanecen y guía final pide
  confirmación/fuente/dudas sin extracción automática. Siete nuevos/54
  focalizados3,0 s y2670/3 en54,6 s limpios; seis avisos deliberados. Game/
  restart/revisión/compacción comprobados; dos fixtures adaptan confirmación DM.
  Consulta729→739/5,585 s y hallazgo739→747/18,745 s documentan antes del cambio.
  Inspección747→755/14,695 s:20vs15, humano solo ability_check, World igual;
  detalles nuevos solo en prosa. Recogida755→762/16,282 s: DM grant_item/hilo×1,
  recorder4,783 s/espina vacía, sin gastar recursos ni mover reloj/facts.
  Consulta762→772/5,593 s: solo Lyra/Vex, sin tools/dados/World nuevo; no atribuyen
  dueño al hilo. Reinicio772 conserva eventos/modelos/ajustes/hero/legacy y
  cierra cinco auxiliares; SQL/prefijos729/747/otra mesa intactos. Hook retirado,
  Show limpio y reload1440/375/ficha/inventario por teclado/dos PNG, cero JS/overflow.
  Cierre QA temprano y dos preparaciones previas fallidas se conservan; ninguna
  acción repetida. TM paso2 sin cierre medido. Alcance solo dos tools: auditar
  los demás mutadores que humano recibe. Voz casi repetida y Vex transforma
  recencia tentativa en afirmada; memoria de cada detalle no acreditada.
  AC-25.6 entregado; semántica libre/latencia/hardware y beta siguen abiertos.

- **D194 / R14**: el modal muestra contra qué se tira y ofrece cierre/foco
  por teclado. Timers por generación y limpieza local impiden cierres antiguos,
  flush duplicados o rolling bloqueado tras fallback. Nueve nuevos, 59
  focalizados4,9 s y gate2663/3 en54,6 s limpios; seis avisos deliberados.
  Primera ejecución roja contiene seis fallos de producto y dos de harness
  Floki inexistente; LazyHTML corrige harness, 7/8 detecta aria-hidden false
  omitido, corregido mediante string. Nueve verdes finales, sin ocultar errores.
  Investigación713→721/13,477 s produce19vs15; World igual, pista solo en prosa.
  Probe expirado tras completar se conserva separado de confirmación Game/SQL.
  Replay UI de payload716 en1440/375 no tira ni persiste: DC/19/foco/Tab/Shift+Tab/
  Escape/Enter/botón44/lienzo, dos PNG finales y baseline revisados, cero JS/overflow.
  Seguimiento721→729/17,729 s da7vs15 y pierde huellas, avanza900 s/revisa escena
  3,997 s y vuelve al humano; Escape también cierra ese dado nativo nuevo.
  Restart729/SQL preserva prefijo721/recursos/inventario/12 facts/hero/modelos/
  ajustes; solo escena/log/reloj cambian, otra mesa aislada, cinco auxiliares
  cerrados. Hook retirado/Show limpio/reload normal, compile/formato/diff.
  Detector una vez: seis avisos heredados, ningún hallazgo en cambios D194;
  se preserva D84 y se mantiene la transición de barra para otra tarea.
  TM entrega turno, pero probe no mide fin de su segundo request. No certifica
  hardware/Safari/lector de pantalla/callback 3D antiguo tras flush nuevo.
  AC-14.4 entregado; beta, memoria de pistas, coherencia y latencia activas.

- **D193 / R25**: cada testimonio nuevo incluye reloj determinista fuera de
  la cita; duplicado aún conservado mantiene primera referencia/posición y
  legado no se fecha por inferencia. Cap30/fuente/dudas/recursos/Codec iguales.
  Cinco nuevos/94 focalizados2,5 s;2654/3 en54,8 s limpios, seis avisos deliberados.
  Game37935/checkpoint/replay/restart y compacción DM/PC tras86400 s acreditados.
  19425 retorno682→689900 s, consulta689→6965,599 s añade versión nueva sobre
  ir solo marcada38835; viaje696→703900 s deja39735, marca original intacta.
  Consulta703→7136,097 s solo Lyra/Vex, requests con marca; distinguen palabra
  del zagal de botón/huellas. No valida semántica temporal general ni relato:
  versión live nueva carece de «hace dos días», probado con envejecimiento offline.
  Movimientos15,299/17,905 s, recorders6,491/5,387 s; no benchmark de latencia.
  Restart713/SQL conserva prefijo682/recursos/inventario/hero/modelos/once facts
  previos; solo un testimonio/escena/log/1800 s, cero dados. Hook retirado/Show
  exacto antes de navegación normal; reload1440/375/ficha/inventario/compañeros
  por teclado y dos PNG revisados, cero JS/overflow. AC-25.5b entregado; beta activa.

- **D192 / R31 / R32**: interrogativo con una preposición conserva el habla
  informativa literal PNJ/PC, con destinatarios/acciones/duración/identidad
  protegidos. Seis nuevos, restart pendiente y False Life ampliados; rojo20/26,
  verde26/26 y86 focalizados4,1 s;2649/3 en55,3 s limpios, seis avisos deliberados.
  19425 pregunta original añade gesto humano; corregida658→665/6,123 s solo
  DM con fallo/reintento, World igual. Viaje665→672/15,268 s registra900 s y
  curva del norte; consulta672→682/5,056 s solo Lyra/Vex conserva voz/pista/World.
  Métricas completas de esos tres recorridos, sin considerar completa la
  petición TM cancelada tras decisión; probe original parcial y preparaciones
  fallidas sin acciones conservados. No comparación causal de latencia.
  Restart682 conserva World/eventos/modelos/ajustes/hero/cierra cinco auxiliares;
  SQL/prefijo651/recursos/inventario/facts anteriores/dados intactos. Un nuevo
  testimonio atribuido, escena/log y900 s, reloj37935. Hook retirado/Show exacto,
  navegación normal/reload375/1440/teclado, dos PNG revisados, cero JS/overflow.
  AC entregados, gramática acotada; voces/coherencia semántica/memoria/latencia y
  beta siguen abiertas. Evidencia privada prepositional-question-verification.json.

- **D191 / R16 / R19**: revisión de escena, selección del siguiente turno y
  backoff se distinguen de narrar; etapas efímeras/PID/turn_id validados por
  Game, status accesible y cursor terminado limpio, sin eventos/World nuevos.
  Pruebas descubren cambio de retry sin aviso y fallo posterior a pause que
  restauraba running: ambos corregidos. Ocho nuevos/71 focalizados7,8 s,
  gate2643/3 en53,3 s sin errores/desconexiones/warnings de compile; seis
  avisos deliberados, formato/compile/diff.19425 conserva estado/modelos/
  ajustes al reiniciar; dejar637→644/22,159 s y recoger644→651/27,396 s,
  stock0→1. Dos vistas375/1440 muestran revisión/relevo sin cursor y conservan
  borrador; reload/teclado/ficha, cuatro capturas revisadas y SQL correctos.
  Recursos/inventario final/facts/clock37035/hero intactos, cero dados; hook
  retirado/Show exacto. Mejora la comprensión de espera; latencia y beta abiertas.

- **D190 / R38**: posesión descriptiva cuantificada por Rules/World, dos tools
  DM de exploración, guardas de stock/actor/límites/identidad y replay tras PID
  nuevo; brief/ficha propia leen inventario actual. Revisión durable de escena
  prioriza posesión; huella/comprobante/commit exactos para confirmar entorno
  idéntico, timeout conserva pendiente sin repetir el objeto.22 nuevos/110
  focalizados2,8 s y2635/3 en52,6 s limpios, cinco breaker. Contrato por turno
  y última declaración visible después del archivo de dados responden a las
  omisiones reales intermedias; ninguna reparación deduce stock desde prosa.
  19425 confirma entregar/dejar/recoger0/1; formulación original623→630 retira1
  pero revisión agota20 s.630→637 recoge1 y confirma entorno en3,634 s.
  Reinicio conserva637 eventos/estado/ajustes y cierra cinco auxiliares; SQL,
  reload375/1440/teclado/22 capturas revisadas, Show exacto/hook retirado.
  Pendientes beta: latencia44,104/28,626 s en ese último par, otras variantes
  del agente/transferencias, durabilidad PNJ y aventura al norte. Inventario
  de aventura entregado; sin economía/equipamiento/registro global del suelo.

- **D189**: zagal/oficios con complemento corto reciben la pregunta exacta,
  con nombres PC del World protegidos antes del registro y publicación literal.
  Seis regresiones/restart/testimonio/colisión y False Life mixto comprobados;
  controles9/14/13/14,43 focalizados2,5 s y2613/3 en52,6 s limpios, cinco breaker.
 19425 viaja900 s al molino,531→538/15,261 s: reloj37035/escena registrados,
  recursos/hero/modelos intactos. Pregunta original16,811 s/538→545 pasa por
  humano/DM/TM; continuación7,109 s/545→552 tiene solo DM dos pasos/una tool,
  habla exacta, cero otros/dados. Solo añade versión atribuida del zagal.
  Reinicio conserva estado/ajustes y cierra cinco auxiliares; SQL/reload375/1440/
  teclado/ocho capturas revisadas, hook retirado/Show exacto. Continuar pistas,
  consecuencias físicas y memoria fuera de ventana; sin beta certificada.

- **D188**: información/opinión PC simple conserva las palabras del jugador,
  con las guardas D182. Cuatro nuevos/restart en ambas variantes y False Life
  con coste real; fixtures de narrador/privacidad mantienen esa ruta mediante
  una declaración propia adicional. Control6/10,77 focalizados4,8 s y2607/3
  en52,2 s/salida0 limpios, cinco breaker.19425: pista PNJ6,095 s/DM dos pasos/
  una tool añade solo testimonio; era alternativa queda solo en prosa. Opinión
  antes6,109 s/tres runs modifica habla; después4,053 s/dos runs PC conserva
  palabras exactas/World/clock36135/hero/modelos/history DM,521→531. Sin otros
  runs/tools/dados. Restart conserva ajustes/estado y cierra cinco auxiliares;
  SQL/reload375/1440/teclado y ocho capturas revisadas, hook retirado/Show exacto.
  Seguir viaje declarado al molino/tiempo y fuente del zagal; no afirmar que
  una propuesta sea viaje ni garantizar toda memoria de prosa PNJ o beta.

- **D187**: respuesta PC suficiente sin gestos/propuestas obligatorias;
  prefijo/instrucción/nudge compatibles y datos confirmados repetibles. Detector
  usa dos voces públicas más recientes dentro de40, sin textos privados ni
  duplicados antiguos. Cuatro detector/dos Game con mensajes efectivos y restart;
  controles8/10/9/10,96 focalizados3,8 s y2603/3 en51,1 s/salida0 limpios,
  cinco breaker. Gate previo2603/3 salió143, conservado/repetido sin atribuir causa.
 19425: ensayo3,997 s sin instrumentación efectiva; hook corregido/reinicio previo
  y dos preguntas observadas4,530/4,013 s, dos runs PC/un paso y cero otros/tools/
  dados,484→494→504. Cifras originales y World/clock36135/hero/modelos/history DM
  íntegros; sin gesto de jarra en ambas, todavía fórmulas parecidas y posibles
  huidas narradas. Nudge live no activado; rama efectiva probada offline. Dos
  reinicios conservan ajustes/estado y cierran cinco auxiliares cada uno; SQL,
  reload375/1440/teclado y seis capturas revisadas, hook retirado/Show exacto.
  Próximo: continuidad PNJ/efectos físicos, nueva aventura y hechos antiguos;
  no originalidad, memoria ilimitada, SLA ni beta certificadas.

- **D186**: hasta32 tiradas anteriores al corte400 vuelven al prompt actual,
  como archivo histórico parcial con seq/asalto/fase y resultados del motor,
  sin recalcular/volver a tirar ni inferir PG actuales. Visibilidad antes del
  límite/History revalidado/índice parcial9ª migración dev-test. Seis casos
  puros/compresión real, dos DB y dos Game con roles/reinicio; controles8/10/
 9/10,77 focalizados5,2 s y2597/3 en50,1 s limpios, cinco breaker.19425 vuelve
 6,615/5,057 s con dos runs PC/cero humano/DM/TM/recorder/tools/dados y World/
  clock36135/hero/modelos/history DM intactos. Eventos24–25 ya fuera de400
  llegan íntegros a ambos prompts; al pedir números, Lyra/Vex dicen20 natural,
 25 vs15 y daño18.454→464→474. Dos reinicios conservan estado/ajustes, cinco
  auxiliares cada uno; SQL/reload375/1440/teclado y ocho capturas revisadas,
  hooks retirados. Las voces repiten gesto de jarra: continuar diversidad,
  consecuencias PNJ y recuerdos más allá de32 tiradas/escenas/testimonios.
  Sin memoria ilimitada, SLA, hardware/Safari ni beta certificada.

- **D185**: visible_to también protege el historial enviado a modelos, antes
  de headers/fusión/compresión. Humano/PC/recorder solo públicos; DM explícito
  conserva notas privadas. Selección por participante Game, aunque humano
  comparta Server DM; notas originales/World intactos. Cinco casos puros/
  recorder y dos Game con requests efectivos/roles/reinicio pendiente, rojo0/7
  limpio, controles filtro0/7/DM omitido5/7;67 focalizados4,7 s y2587/3 en50,5 s
  limpios, cinco breaker.19425 sigue454 eventos/World/cursor/pausa iguales por
  SQL; reload375/1440/teclado/ficha/compañeros y dos capturas revisadas sin JS/
  overflow. Sin nuevos hooks/eventos/proveedor; privacidad probada offline.
  Alcance: permisos de game_events, sin clasificación de secretos en facts/
  story_bible. Continuar memoria fuera de400, PNJs y beta abierta.

- **D184**: una consulta informativa/opinión a PCs vuelve al jugador sin DM
  cuando el motor acredita World íntegro y transcript completo, en el mismo
  settlement. Prueba JSON durable/hash+seq, reinicio pendiente sin duplicados;
  peticiones al mundo, dados incluso sin efectos, preguntas nuevas PC, fallos,
  otra persona, cambios de mundo o evidencia truncada conservan DM. Preferencia
  mantiene narrador humano.14 casos/control sin transcript11/14,69 focalizados
 3,7 s y2580/3 en50,9 s limpios, cinco breaker.19425 vuelve5,574 s con dos runs
  PC/un paso y cero humano/DM/TM/recorder/tools/dados; history DM idéntico,
  World/clock36135/hero/modelos iguales. Primera7,642 s con observador caducado,
  sin afirmar runs;434→444→454. Reinicio conserva modelos/ajustes y cierra cinco
  auxiliares; SQL/reload375/1440/teclado/ficha/compañeros y cuatro capturas
  revisadas, hook retirado/Show exacto. Prosa PNJ y memoria fuera de400 siguen
  abiertas; no acredita SLA, semántica general, hardware/Safari ni beta.

- **D183**: guía de cierre/anti-repeat coherente con conversación. El Game
  selecciona contexto desde World; una repetición no exige olores/sonidos/luz
  nuevos mientras el cierre los prohíbe. Fuera conserva guía ordinaria, sin
  cambiar reglas/tools/modelos o imponer silencio. Tres Game prueban requests
  repetidos/reinicio pendiente sin nuevas voces PC y testimonio PNJ guardado.
  Control negativo1/3,42 focalizados3,3 s,2566/3 en49,6 s limpios, cinco breaker.
 19425 vuelve7,618/7,605 s con tres runs/un paso/cero humano/TM/recorder/tools/
  dados, World/clock36135/hero/modelos iguales. Dos reinicios conservan estado/
  ajustes y cierran cinco auxiliares cada uno;375/1440 px/teclado y ocho
  capturas revisadas, hooks retirados. El primer prompt aún recibe el nudge
  antiguo; la muestra final no lo activa y sigue repitiendo tarde tibia.
  El nudge nuevo activado se verifica offline. Repetición narrativa y beta
  siguen abiertas; continuar cierre discreto guardado por motor y campaña larga.

- **D182**: preguntas PC de recuerdo/observación salen con las palabras del
  jugador, sin reformulación humana. Cola registrada idéntica/manual/exploración
  y guardas intactas; acciones/hechizos/esperas con duración conservan motor.
  Tres parser/guardas y tres Game prueban ambos requests, reinicio durante
  respuesta y False Life mixto con coste/tirada únicos. Control negativo4/6;
 62 focalizados2,9 s,2563/3 en50,0 s limpios, cinco breaker deliberados.
 19425 vuelve en7,647 s con Lyra/Vex/cierre DM: tres runs de un paso, cero
  humano/TM/recorder/tools/dados, World/reloj36135/hero/modelos iguales. Habla
  exacta en ambos histories; scrub retira encabezado añadido de Vex, clean
  igual a persistido. Reinicio cierra cinco auxiliares/preserva modelos/ajustes,
  reload375/1440 px/teclado y cuatro capturas revisadas, hook retirado.
 408 eventos superan400 pero dados del combate aún permanecen en contexto.
  Una muestra sin SLA; seguir cierre DM repetido y hechos fuera de ventana.

- **D181**: History conserva crítico, fallo normal de muerte y doble fallo
  natural1 sin convertirlos en resultados genéricos. No calcula desde el
  d20 ni cambia reglas/recursos/eventos/UI. Tres casos Actions/RollLog/JSON
  y un Game entregan dos críticos antiguos a ambos agentes con prefijo
  propio y reinicio real sin nuevas tiradas. Control negativo1/4;78
  focalizados1,9 s y2557/3 en49,2 s limpios, cinco breaker deliberados.
 19425 recibe Lyra/Vex y luego Vex/Lyra: una voz cada uno/cierre DM/retorno
  humano11,791/9,664 s, cuatro runs de un paso, cero TM/recorder/tools/dados.
  World entero/reloj36135/hero/modelos iguales; ambos recuerdan el crítico
  en la segunda respuesta. Reinicio conserva modelos/ajustes/historial/cola,
  cierra cinco auxiliares; reload375/1440 px/teclado y seis capturas revisadas.
  Hook retirado. Captura live es history convertido, sin prefijo system
  efímero; prefijo efectivo probado con TestModel.395 eventos dentro de400,
  sin benchmark causal ni semántica general. Continuar preguntas PC sin
  reformulación/gestos añadidos y cierres DM menos repetidos; beta abierta.

- **D180**: coordinador1024 por petición configurable con entero positivo;
  vacío/inválido conserva1024 y opción explícita del constructor prevalece.
  Bootstrap usa la misma configuración. Cuatro muestras reales aisladas
  reproducen corte256 sin tool y decisión259 con margen1024; las dos1024
  deciden, sin garantía estadística. Cuatro casos offline/control negativo1/4;
 77 focalizados2,3 s y2553/3 en50,2 s limpios, cinco breaker deliberados.
 19425 aclara las palabras de Maribel en8,13 s con un paso DM/World idéntico,
  sin nuevos hechos ni veracidad certificada. Espera15 s vuelve en9,667 s:
  DM dos pasos/TM una ejecución/decisión válida, sin fallback; reloj36120→36135
  una vez y escena/hechos/recursos intactos. Una revisión de escena tarda
 4,261 s y conserva el entorno; investigar su entrada antes de eliminarla.
  Dos reinicios conservan mesa/
  modelos y cierran cinco auxiliares cada uno. Reload375/1440 px/teclado,
  seis capturas revisadas, sin JS/overflow; instrumentación retirada. Sigue
  abierta la beta: ampliar grupo, cambios físicos narrados y latencia.

- **D179**: mesa compacta hasta1023 px, escritorio desde1024 y bloques72ch
  entre721–1023. Horizontal≤600 px usa ficha lateral240 px sin quitar altura
  a crónica/entrada. Controles completos al recibir foco y objetivos táctiles
 44×44 px. Corrige ficha propia de combate oculta por la regla de duplicados;
  PG/CA preceden raza/clase para caber en el lateral corto. Chrome verifica
  ocho tamaños375–1440 y cuatro casos táctiles emulados exploración/combate,
  ajustes/cancelar, teclado/ficha/compañeros/iniciativa, sin JS/overflow-x.
  Dos mesas intactas por SQL de solo lectura, siete capturas revisadas;
 39 focalizados5,9 s y2549/3 en48,2 s/seed30343/max_cases48 limpios, cinco
  breaker deliberados. Detector: seis patrones CSS anteriores conservados,
  sin nuevas incidencias. No hardware físico probado. Continuar versiones
  PNJ/cambios físicos narrados y coordinador/latencia; beta sigue abierta.

- **D178**: Ficha móvil propia primero y scroll0 solo al abrir. Los patches
  durante lectura mantienen posición/compañeros; teclado y DM Grupo intactos.
  Chrome375/720 reproduce el fallo y la corrección;721/1024/1440 conserva
  fichas de escritorio, DM375 tres miembros. SQL de solo lectura confirma
  World/actor/estado/ronda/intenciones/history iguales, reloj36120. Cinco
  capturas revisadas sin JS/overflow-x.41 focalizados en5,2 s,2549/3 en49,3 s
  limpio/seed30343/max_cases48, cinco breaker deliberados. El primer gate
  descubrió un fixture anti-repeat agotado: barrera antes de tercera final,
  modelo PC separado y exactamente tres voces/World/DB comprobados. Próximo:
  crónica estrecha y controles recortados721–1023/paisaje, continuidad PNJ.

- **D177**: viste/oíste/escuchaste, con tú opcional, conservan palabras del
  jugador sin reformulación humana. Destinatario/cola manual/prefijo/espera
  acotados D167, sin roles nuevos; magia/pago/movimiento/persuasión conservan
  ruta habitual. Tres casos nuevos/32 focalizados en1,7 s,2549/3 en49,6 s/
  seed30343/max_cases48 sin errores ni avisos inesperados; cinco breaker.
 19425 publica «¿Oíste tú misma…?» literal y guarda testimonio en4,538 s,
  una ejecución DM/dos pasos, ningún humano/TM/recorder. Reloj36120 y todo
  World salvo facts, modelos/biblioteca iguales. Restart/UTF-8/JSON/recargas
 375/1440 px/teclado acreditados; cinco auxiliares cerrados, cuatro capturas
  revisadas y hook retirado. Biblia vacía; nuevas versiones del forastero y
  orden de ficha/compañeros móvil siguen bajo revisión. No certifica SLA.

- **D176**: record_npc_statement guarda fuente/dudas de la versión del PNJ,
  sin confirmar contenido ni ejecutar lo que relata. Solo DM, fuente80/
  contenido800/scrub/NFC/citas/rechazo de PJ completo/corto; NPC conocido de
  prefijo compartido válido. Memoria existente/cap30/replay; entorno/revisión
  previa/reloj/recursos iguales. Brief y resúmenes distinguen testimonios
  de hechos confirmados. Diez casos cubren World/DB/Codec/checkpoint/restart,
  cuerpo citado y fuente visible para DM/PC tras compacción.67 focalizados,
  gate2546/3 en49,3 s sin errores/avisos inesperados, cinco breaker deliberados.
 19425/modelos iguales: Maribel guarda su versión de salida/dirección7,605 s,
  humano1/DM2/cero TM/recorder, reloj36120/recursos/escena/biblioteca iguales.
  Restart/reload375/1440 px/teclado conserva hechos/historial/modelos/JSON/
  UTF-8, cinco auxiliares cerrados, cuatro capturas revisadas y hook retirado.
  Fuente nueva del zagal/cabras, relleno de jarra y gestos del beat humano
  siguen en revisión. No certifica veracidad, biblia ni registro universal.

- **D175**: esperar deliberadamente deja de recibir la orden de novedades
  del DM ordinario. Game selecciona contexto de espera reconocido, conserva
  guardas/agencia/estilo y permite interrupciones coherentes. Prefijo estable
  y guía común no obligan cambios del entorno. Cuatro casos prueban messages
  antes/después de reloj, recursos/hechos/escena, parcial5 s/restart y restart
  pendiente sin duplicar voz/tiempo; controles normales/atasco preservados.
  46 focalizados y siete tras el último ajuste;2536/3 en47,9/48,8 s limpio.
 19425/modelos iguales:15/15 s una vez,36090→36105→36120,17,877/14,256 s,
  sin nuevos hechos/dados/gasto/petición humana. Ambas escenas idénticas
  confirmadas/revisión limpia: primera observación real D172. Recorder3,855/
  3,623 s, TM1 fallido/fallback y2 completos; no es benchmark. Reinicios/
  reload375/1440 px/teclado preservan estado/historial/modelos/biblioteca/
  UTF-8/JSON y cierran cinco auxiliares cada uno; capturas revisadas, ganchos
  retirados. No corrige afirmaciones previas ni certifica semántica general.

- **D174**: traza identifica ficha/recarga del druida: LiveView termina durante
  consulta SQL, snapshot Game falla con owner aún vivo. ConnCase supervisa
  cierre síncrono antes de terminar el canal. Dos pruebas retienen SQL real
  con advisory lock y conservan snapshot/World/historial/DB y otra vista viva.
  TMSpy supervisa su contador hasta terminar el Game; evita falso fallo final
  de petición.34 focalizados en6,7 s y45 con TM en7,1 s, limpios. Gates2532/3
  en48,0/48,2 s, seeds944912/30343/max_cases48, sin desconexiones ni errores,
  solo cinco avisos breaker. El intermedio49,0 s que descubrió TMSpy queda
  conservado. Sin cambios productivos/dependencias, instrumentación retirada;
  los casos históricos sin atribución exacta conservan seguimiento.

- **D173**: guía explícita al recorder de referencia física del lugar,
  omitiendo conversación/ofertas/rumores/gestos PNJ e inferencias de consumo.
  Un smoke verifica messages del proveedor, entorno, diálogo íntegro una vez,
  120 s/recursos/DB/Codec/restart;27 focalizados y2530/3 en47,9 s. Una desconexión
  SQL y una terminación Game/snapshot siguen abiertas; cinco avisos breaker.
 19425/modelos iguales registra30 s una vez,21,956 s, sin petición humana/
  dados/gasto. Escena915→662 caracteres sin pregunta/oferta, pero mantiene
  detalles transitorios y la jarra previa. Nueva salida del forastero al norte
  solo en history; no se certifica coherencia semántica ni latencia general.
  Restart/reload375/1440 px/teclado conservan estado/historial/modelos/biblioteca/
  JSON, cinco auxiliares cerrados y capturas revisadas; gancho retirado.

- **Verificación de cola/limbo2026-10-03**: el fixture multi-human deja de
  terminar al registrar acciones; incluye el siguiente turno del goblin y
  exige daño/casillas/cola vacía/World guardado. Limbo separa las respuestas
  DM/PC, pausa antes de la tercera voz y comprueba tres respuestas completas,
  una tirada y recursos/persistencia. Ocho focalizados en1,1 s y2529/3 en48,1 s
  sin avisos inesperados; una desconexión SQL sigue abierta. Instrumentación
  temporal retirada, sin cambios de producto ni parche a la dependencia.

- **D172**: una espera aislada conserva huella del World anterior limpio.
  Recorder puede confirmar la escena idéntica; Game revalida fuente/intervalo/
  estado y limpia solo la marca. Facts/recursos/escena/tiempo adicionales,
  revisión previa y resultados obsoletos siguen requiriendo actualización.
  Codec conserva huella válida y descarta solo la opcional inválida, sin perder
  el tiempo resuelto. Recuperación tras final DM no repite voz ni intervalo.
  Diez casos/53 focalizados; gate2529/3 en47,6 s/max_cases48 con una desconexión
  owner y un aviso de modelo agotado; cero terminaciones Game. Traza serial
  limpia55,2 s no cierra la causa. Compile/formato/diff correctos.
 19425/modelos iguales registra120/60 s una vez,13,246/18,890 s sin petición
  humana/dados/gasto. Recorder4,904/4,914 s cambia ambas escenas; la confirmación
  idéntica está probada offline, incluido restart. Dos reinicios/reloads375/
  1440 px/ficha/compañeros por teclado conservan World/historial/modelos/JSON/
  biblioteca, cinco auxiliares cerrados cada uno; capturas revisadas y ganchos
  retirados. Persisten preguntas/gestos PNJ en la escena y continuidad dudosa
  de la jarra a medio vaciar. Beta sigue en preparación, sin benchmark de latencia.

- **D171**: esperas puramente pasivas publican las palabras saneadas del
  jugador sin reformulación humana. Acción/cola/turno/metadatos intactos;
  el reloj sigue pendiente hasta la resolución DM por D170. Hechizos y
  declaraciones mixtas mantienen sus tools/casilla/dados. Siete casos/29
  focalizados y2519/3 en47,0 s, sin errores/desconexiones; cinco avisos esperados
  del breaker. Compile/formato/diff correctos.19425/modelos iguales registra
  tres minutos35700→35880 una vez,17,884 s, cero peticiones humanas y sin gasto.
  DM dos peticiones/TM una con max_tokens/recorder3,853 s; no es un benchmark.
  SceneRefresh deja pendiente una escena idéntica y el PNJ añade datos del
  rumor solo al historial; continuar esas revisiones. Restart conserva estado/
  modelos/historial/JSON y cierra cinco auxiliares; reload375/1440 px/fichas/
  compañeros por teclado sin JS/overflow, capturas revisadas y ganchos retirados.

- **D170**: esperas literales humanas guardan segundos/reloj inicial en la
  acción; el DM debe resolver antes de finalizar/publicar. World.resolve_wait
  conserva comprobante con el efecto y Codec admite legacy nil; interrupción
  parcial/0 s, duplicados/paralelos y restart no duplican el intervalo.
  Omisión persistente pausa conservando la declaración. Dieciséis casos/
  27 focalizados, gate2512/3; limpieza intermitente reaparece y queda abierta.
  19425 registra cinco minutos35400→35700 una vez, sin dados/recargas ni cambios
  de biblioteca/modelos; añade a facts el rumor anterior.32,603 s con recorder
  10,567 s y consulta TM; repite casi literalmente el rumor. Restart/reload
  375/1440 px/teclado/JSON/capturas verificados, cinco auxiliares cerrados;
  ganchos retirados. Otras duraciones y ritmo/fidelidad narrativa siguen abiertos.

- **Verificación adicional2026-10-03**: nueve fixtures anteriores comprueban
  beats completos y persistencia, en vez de un efecto parcial. Escena exige
  cambio positivo/control negativo; reacción Lyra aplica Escudo real, una
  casilla y CA efectiva17/base12; antibucle y narración DM usan modelos propios.
  **38** focalizados en2,0 s sin errores/avisos. La suite y el desglose de avisos
  están en el protocolo de pruebas; no se ocultan fallos con esperas nuevas.
  Gate final2496/3 en48,0 s/seed30343, sin errores/desconexiones/avisos inesperados;
  cinco avisos del breaker simulado. Compile/formato/diff y HTTP200 correctos.

- **D169**: espera real3,504 s rompe la petición DM antes del proveedor al
  comprimir la antigua pregunta del menú. Regex por bytes parte ¿; Unicode y
  terminadores .!? conservan caracteres/atribución/doce recientes. Tres rojos/
  tres casos/18 focalizados, gate2496/3 en47,1 s sin errores/desconexiones;
  avisos de ejecución atribuidos en el protocolo de pruebas. Misma19425 responde
  en6,6 s, pero todavía omite el reloj. Confirmación explícita1200 s20,451 s
  deja35400 una vez; intento humano rechazado, DM confirmado, recorder3,699 s.
  Solo reloj/log/escena cambian, recursos/biblioteca intactos y cero dados.
  Restart/JSON/historial/modelos iguales, cinco auxiliares cerrados; reload
  375/1440 px/teclado sin JS/overflow, capturas revisadas, ganchos retirados.
  Siete dados históricos conservados, cero recientes. `meal-choice-*`.
  La omisión natural y detalles inventados al contar el goblin quedan abiertos.

- **D168**: elección de comida11,739 s devuelve cuatro voces y World igual,
  pero Vex copia casi toda la respuesta de Lyra. La instrucción de respuesta
  ahora recuerda su personalidad y permite acuerdo con palabras propias, sin
  copiar gestos ni forzar desacuerdo/hechos. Tres casos/39 focalizados, gate2493/3
  en47,4 s sin errores/desconexiones; avisos de ejecución atribuidos en el
  protocolo de pruebas. Nueva conversación10,198 s tiene acuerdo con prosa distinta,
  cuatro peticiones, sin TM/recorder/tools/dados; World/reloj/biblioteca iguales.
  Guía real entregada a ambos, no garantía de originalidad. Reload375/1440 px/
  teclado verificados; preguntas distintas no prueban mejora de latencia.

- **D167**: preguntas informativas PNJ literales con solo habla/espera pasiva
  publican interrogante saneado sin reformulación humana por el modelo. Acción
  completa/turno/liquidación/cola DM/retorno conservados; acciones/persuasión/
  gramática incierta siguen ruta normal. Siete casos/69 focalizados, gate2490/3
  ordinario en47,6 s limpio; mixto False Life consume casilla/dado una vez.
  Misma19425/modelos: invitación4,536 s, una petición DM3,911 s, sin humano/
  TM/recorder/tools/dados, World/reloj34200/recursos/biblioteca intactos. Maribel
  confirma guiso/pan/jarra gratis, vino/licor aparte; no se decide por PCs.
  Restart conserva estado/historial/modelos y cierra cinco auxiliares; reload
  375/1440 px/ficha/compañeros por teclado sin JS/overflow, capturas revisadas
  y ganchos retirados. `npc-literal-speech-*`. Sin SLA ni garantía semántica/
  recuperación humana general; limpieza intermitente anterior sigue abierta.

- **D166**: la entrada real narrada en taberna conserva plaza en World.
  Movimiento humano literal registra scene_before; si DM omite set_scene,
  se revisa con el recorder D145 sin tools de reglas. Excluye registro ya
  aplicado, preguntas/planes/IA/mini; confirmación idéntica sin writes y fallo
  pendiente durable. Once casos/68 focalizados, gate2483/3 en54,4 s trazado
  limpio; primera suite detectó registro humano ya aplicado y dos desconexiones
  de limpieza (incidencia abierta). Misma mesa/modelos: barra22,895 s, recorder
  un paso9,579 s/TM6,274 s; solo escena/log plaza→interior, reloj34200,
  recursos/fichas/encargo/biblioteca intactos, cero dados nuevos. Maribel8,657/
  5,026 s, World igual y sin TM/recorder adicional. Restart conserva todo y
  cierra cinco auxiliares; reload375/1440 px/teclado sin JS/overflow, capturas
  revisadas y ganchos retirados. `beta-latency-*`. Muestras distintas, sin SLA;
  sigue pendiente ritmo y revisar invitación gratis frente al precio anunciado.

- **D165**: la marcha real al molino cambia escena sin registrar sus quince
  minutos; raw DM solo set_scene. Brief incorpora la operación de advance_time
  para DM en exploración, diferenciando tiempo consumido de preguntas/propuestas
  y rests. Motor/caducidades sin cambios. Dos rojos de entrega, tres casos nuevos
  de viaje/caducidad/restart/scope,35 focalizados; gate2472/3 en46,9 s limpio.
  Confirmación explícita del tramo omitido:32400→33300; nueva marcha hasta plaza/
  Ciervo:33300→34200. Solo reloj/log/escena cambian; recursos/fichas/encargo/
  biblioteca intactos, sin dados nuevos. Restart conserva World/historial/modelos
  por rol y cierra cinco auxiliares. Reload375/1440 px/teclado, siete dados
  históricos conservados, sin JS/overflow; capturas revisadas y ganchos retirados.
  Invitación17,833 s, marcha34,751 s, confirmación35,721 s, llegada47,54 s. La
  selección de tools sigue siendo del modelo: no se garantizan todas las
  duraciones. Revisar esa latencia, el relevo adicional Vex/DM y Maribel.

- **D164**: Events distingue una respuesta completa de declaraciones con tools
  y texto truncado/filtrado. Beats recupera la final ya publicada para el actor/
  turno con comprobante durable, sin consultar al modelo ni duplicar la crónica.
  Conserva intervenciones intermedias y el registro de escena independiente.
  Dos rojos resume/restart; siete casos nuevos, cinco recuperaciones previas
  reforzadas y49 focalizados; gate2469/3 en46,0 s limpio. VM19442 corta después
  de publicar: restart16,606 ms, cero peticiones al actor, descanso28800 s y
  límites intactos, dos intervenciones/turno DM únicos; escena completa y retorno
  a Thane. Otro restart conserva World/historial. Reload375/1440 px/teclado,
  sin JS/overflow, ambas capturas revisadas; compile/formato/diff y ganchos
  limpios. No certifica actores sin comprobante, intentos incompletos ni relevo
  posterior. La incidencia de limpieza D163 sigue abierta, sin repetirse aquí.

- **D163**: cierre/intenciones/notas SQL juntos antes de Session/PubSub;
  rechazo pausa con comprobante y estado previo para resume/restart. Victoria
  guardada se liquida antes de una reacción obsoleta, tras recuperar al actor
  pendiente. Siete casos/52 focalizados; gate2462/3 trazado en53,6 s sin errores/
  warnings. Gate anterior con tres desconexiones de limpieza no reproducidas
  en trazas ni17 focalizados: incidencia abierta. VM19440 cierra sin modelo/
  dados, VM19441 recupera golpe ganador/turno/dos dados y una sola nota de fin;
  otra reapertura sin repeticiones. Adopción15 mesas/modelos por rol y56
  auxiliares cerrados; reload375/1440 px/teclado sin JS/overflow, captura móvil
  revisada, ganchos retirados. Narración/relevo posterior mantienen revisión.

- **D162**: reserva durable de slot/tipo antes de evaluar inicio de turno;
  efecto/todos los dados/retirada de reserva SQL juntos, publicación posterior.
  Rechazo pausa sin daño/concentración parciales; resume/restart resuelve antes
  del actor/coordinador, incluidos nombres DM/reacciones. Seis casos/82
  focalizados y gate2455/3 en45,4 s sin errores/warnings. VM19439 interrumpida
  antes de devolver un dado conserva Goblin100/cero eventos; tras parada
  supervisada aplica aura3/Goblin97 una vez, PC recibe97/100 y segundo restart
  no tira. Adopción14 mesas/modelos por rol,52 auxiliares cerrados; reload
  375/1440 px/fichas por teclado sin JS/overflow. Captura de escritorio revisada;
  ganchos retirados. Cierre de combate/narraciones mantienen revisión propia.

- **D161**: conservar subtotal negativo en RollLog/jsonb permite mostrar−2
  y mínimo0 en crónica/modal/History sin cambiar daño o dados. Cinco casos
  nuevos/50 focalizados; gate2449/3 en44,3 s sin errores/warnings. VM19438
  conserva arma0/radiante4/Goblin6/casilla1 al reiniciar antes del feedback,
  sin más tiradas, y retorna al humano26,544 ms. Reload375/1440 px/fichas por
  teclado sin JS/overflow; captura móvil revisada. Eventos antiguos conservan
  su desglose previo, sin inventar un subtotal desconocido. Ganchos retirados.

- **D159–D160**: iniciativa/World/dados/nota SQL juntos antes de publicar;
  daño mínimo cero después de bonos y radiante separado. Tres regresiones
  de rechazo/recuperación y nueve de daño, con PC/TestModel. Acceso local
  restablecido; gate2444/3 en44,6 s sin errores/warnings. VM19436 confirma
  iniciativa y VM19437 arma0/radiante4/Goblin6/casilla1, ambas recuperables
  sin repetir efectos/dados. Nueva VM recupera once mesas propias pausadas
  con World/historial/cursor/intenciones/reloj iguales; los modelos efímeros
  proceden de configuración vigente o TestModel explícito. Navegador375/1440
  px/teclado sin JS/overflow, ganchos retirados. Inicio de turno y narraciones
  conservan revisión propia; no supone un cierre de beta.

- **D158**: pregunta literal a rol PNJ cualificado reserva DM→humano en cola
  durable, sin crear respuesta PC ni consultar coordinador. Diez casos/55
  focalizados, gate2432/3 en43,5 s sin errores/avisos de compilación. Otra
  intervención humana mantiene prioridad, JSON validado, borrador y restart
  con DM esperando. Modelo no sustituye la cola; gramática acotada.
  Misma19425 real: segunda pregunta8,143 s, voces Mara/DM, coordinador sin
  peticiones, World/biblioteca iguales/cero dados y raw DM saneado por D7.
  Reload375/1440 px/teclado sin JS/overflow. Adopción19425–19435 conserva
  estado/modelos por rol/eventos, cierra41 auxiliares; ganchos retirados.
  Preguntas distintas frente a16,216 s; no acredita percentiles de latencia.

- **D157**: preparación de dados privada por ejecución; World/comprobante y
  eventos de dados en una transacción para tools anunciadas. Rechazo, corte
  previo o rollback no publica ni cobra; roll_dice guarda grupos con resultado.
  Diez casos/43 focalizados/14 finales, gate2422/3 en42,8 s sin errores/avisos
  de compilación. VM19435: preparación cero eventos; restart antes del feedback
  conserva casilla1/Goblin14/un grupo/turn_id original; humano27,299 ms.
  Reload375/1440 px/teclado/crónica correctos. Adopción19425–19434 conserva
  estado/modelos/eventos, cierra37 auxiliares. Guion inicial duplicó pausa,
  fixture19434 conservado; ganchos retirados. Narraciones y grupos automáticos
  fuera de tools mantienen revisión propia.

- **D156**: establish_fact aplica la misma guarda de agencia que set_scene;
  no convierte acciones ajenas/consenso en estado canónico. Mantiene NPCs,
  grupos cualificados, citas, acción propia y saneamiento. Cinco casos/39
  focalizados, gate2412/3 en42,5 s sin errores/warnings. VM19433 offline
  rechaza consenso y acepta mapa PNJ, escena factual actualizada, mecánicas
  iguales/cero dados; humano31,705 ms. Restart/reload375/1440 px/fichas/
  compañeros por teclado correctos. Adopción19425–19432 conserva estado/
  modelos/historial, cierra28 auxiliares; ganchos retirados.

- **D155**: consenso pasivo entre vosotros y gesto plural real no deciden
  por el humano/compañeros. Conserva preguntas propias, entorno, citas y planes;
  puntuación irregular sola no activa agencia. Nueve casos/46 focalizados,
  gate2407/3 en49,4 s trace/max_cases48 sin errores/warnings. Primera pregunta
  real25,431 s revela los dos fixtures; nueva pregunta12,137 s deja decisión
  abierta con World/biblioteca iguales y voces propias. Raw Lyra con etiquetas
  D7 se guarda limpio; Vex/DM coincide. Adopción19425 conserva estado/modelos/
  historial, cierra5 auxiliares. Reload375/1440 px/fichas/compañeros por teclado
  correctos; ganchos retirados. No certifica consenso semántico general.

- **D154**: efecto y comprobante en el mismo World antes del feedback;
  interrumpir ahí ya no repite gasto. Respuesta final sustituye la entrada;
  varias propuestas comparten una, rechazo sin cambio no crea ninguna.
  Cinco casos/29 focalizados, gate2398/3 en41,8 s sin errores/warnings.
  VM19432 offline conserva una casilla/daño6/un grupo/turno y entrega comprobante
  al actor recuperado; pedido viejo cerrado, humano29,673 ms. Reload375/1440 px
  y ficha/compañeros por teclado correctos. Adopción19425–19431 conserva estado/
  modelos/eventos y cierra24 auxiliares; ganchos retirados. Quedan dados/eventos
  anteriores al guardado del efecto y playtest con proveedor real.

- **D153**: beat IA durable en World/Codec con resultados saneados, turn_id/
  fase/mini-turn/enemigos originales. Reiniciar no repite recursos/dados;
  éxito/fallo definitivo limpia registro y nueva declaración empieza otro.
  Ocho casos,45 focalizados, gate2393/3 en41,8 s sin errores/warnings.
  VM19431 offline: una casilla/daño6/un grupo, un marcador/ID original,
  petición vieja cerrada y humano25,518 ms. Reload375/1440 px/ficha/compañeros
  por teclado correctos. Adopción19425–19430 normaliza nil, conserva estado/
  modelos/eventos y cierra20 auxiliares. Ganchos retirados. Sigue abierta la
  ventana anterior al registro y atomicidad World/dados/eventos.

- **D152**: resultados de tools en Beat/PendingRetry evitan gastos/tiradas
  duplicados en reintentos de narración. Identidad por argumentos canónicos;
  varias llamadas originales preservadas, nuevas declaraciones siguen
  ejecutando. Nueve casos,28 focalizados, gate2385/3 en41,3 s sin errores ni
  warnings. VM19430 offline/503 simulado: casillas2→1, daño6, un grupo de
  dados, resultado previo al modelo, humano1050,311 ms con backoff1 s.
  Reload375/1440 px/teclado y reserva visible correctos; ganchos retirados.
  Adopción19425–19429 conserva todo estado/modelos y cierra17 auxiliares.
  El registro de memoria no cubre el relevo a un nuevo Game tras una caída.

- **D151**: presupuesto de reinicios independiente por mesa, supervisor
  temporal y cierre automático tras salida normal. APIs conservan GamePID,
  reapertura espera ambas claves. Seis casos nuevos, gate2376/3 en40,4 s sin
  errores ni warnings; compile limpio. VM19429: cuatro caídas cierran solo
  esa mesa y tres auxiliares; gestor y mesa19428 siguen con los mismos
  procesos/World/historial. Reapertura y reload375/1440 px/teclado en ambas
  correctos. Adopción19425–19428 pausadas conserva recursos/eventos/modelos,
  cierra14 auxiliares antiguos. Ganchos retirados. Atomicidad conjunta pendiente.

- **D150**: las tools vivas guardan su candidato World dentro de Game antes
  de publicarlo o confirmar resultados. Siete casos nuevos, gate2370/3 en
  40,6 s sin errores y once avisos de tests; compile dev limpio. Mesa19428
  offline conserva descanso8→14/reloj28800/historial al reiniciar con
  narración pendiente; continúa al humano y actualiza amanecer sin repetir
  descanso ni dados. Ganchos retirados. Siguen abiertas la atomicidad conjunta
  de dados/eventos/World; el aislamiento del límite global se cierra en D151.

- **D149**: parada supervisada espera al callback del Game dentro del
  plazo OTP. Auxiliar vigente parado recupera Game; autoplay retirado no.
  Informes de estado excluyen modelos. Cinco casos,54 focalizados, gate2363/3
  sin errores. VM19427: operación100 ms responde antes del cierre/reapertura;
  World/tres eventos iguales, reload375/1440 px/teclado correcto. Adopción
  en19425/19426 pausadas conserva todos los recursos/130 y20 eventos/relojes,
  cierra auxiliares antiguos. Ganchos retirados, compile/formato/diff correctos.
  No garantiza continuidad tras `:kill` ni efectos parciales de tools.

- **D148**: fixtures pausan y dejan terminar el beat antes de cerrar Game y
  dueño SQL separado. Limpieza de partidas globales por Registry. Un caso
  nuevo comprueba descanso/curación/World/narración conservados al limpiar.
  71 focalizados,49 de la variante final, gate2358/3 en39,2 s sin errores de
  log; compile/formato/diff correctos. No cambia el reinicio real D147 ni
  prueba durabilidad tras caída con efectos parciales.

- **D147**: cancelación de ejecución al perder Game/beat y cierre de
  Session/Servers, también autoplay posterior, PC/TM/registro. Doce casos,
  67 focalizados y gate2357/3. Mesa19427 offline con petición esperando antes
  de tools: reinicio12,48 ms observados, cuatro auxiliares cerrados, World/
  tres eventos/pausa/cursor iguales; reload375/1440 px y teclado correctos.
  Ganchos retirados, compile limpio. Gate con11 errores de cierre Sandbox:
  pendiente orden de teardown, recuperación parcial y proveedor real.

- **D146**: feedback del descanso largo refleja el cuerpo que recibe la
  curación después de caducar los efectos. Seis casos nuevos, 76 focalizados,
  gate2345/3. Sylvi19426 real: lobo11/11/original10/24 → cuerpo24/24,
  noche28,24 s al humano, reservas/reloj/biblioteca/reinicio correctos.
  Feedback humano no se conserva en history DM: replay del World previo
  informa14PG10→24 sin aplicar, y TestModel verifica entrega del mensaje.
  Web375/1440 px correcta; tres auxiliares/ganchos retirados, compile limpio.

- **D145**: cambios confirmados marcan el registro de escena pendiente y
  un resumidor sin reglas devuelve una instantánea estructurada; Game valida
  antes de aplicar. Cola/pausa/reinicio/recursos conservados, fallo no repite
  efectos. Dieciséis casos nuevos, 120 focalizados, gate2339/3. Variante final
  real: cuarto/huerto registrado4,72 s, vuelta Mara23,89 s, solo escena/log/
  marca cambian; reinicio conserva World/130 eventos y rechazo diario.
  Primera variante timeout20 s quedó pendiente y no se cuenta como éxito.
  Web375/1440 px correcta; semántica general y viajes por prosa siguen abiertos.

- **D144**: reloj relativo y límite de descanso largo compartidos con el
  validador; facts vigentes también para TurnMaster, escena identificada
  como último registro. Seis casos nuevos, 64 focalizados, gate2323/3.
  Mañana19425 13,65 s, World/biblioteca intactos y web375/1440 px correcta;
  el agente todavía omite `set_scene`. El registro persistente de la escena
  quedó abierto en esa medición y se aborda en D145.

- **D101–D102**: identidad autenticada, secretos protegidos, paginación que
  sobrevive a PubSub/retry, turnos reagrupados, límites de memoria, controles
  móviles, ficha por teclado y borrador conservado cuando falla el envío.
  Gate: 1943 passed / 3 excluded.
- **D103–D106**: caso narrativo real convertido en fixture y sanitizado,
  streaming por actor, aura que cierra combate antes de esperar, TurnMaster
  con un World vigente por beat y borrador local hasta confirmación.
  Gate: 1960 passed / 3 excluded.
- **D107**: un fallo del actor marca el turno principal, conserva resultados
  y permite completar la ronda; mensaje fuera de turno identifica el actor
  que debe terminar. Gate: 1965 passed / 3 excluded.
- **D108–D109**: schema de magia opcional/nulo y selección vacía normalizada;
  CA efectiva, estado vital, reservas y combatiente visibles desde el World.
  Gate: 1978 passed / 3 excluded. Magia real en arena y ficha por teclado,
  pausa/reload a 375/1440 px sin errores JS ni overflow horizontal.
- **D110**: recuperación por slots pendientes, apertura con/sin acción,
  dueño anterior y retorno de reacción sin consumir/refrescar el principal.
  Gate: 1992 passed / 3 excluded.
- **D111–D112**: sala no queda atrapada al llegar tarde el aviso; texto
  declarado consultable por toque/teclado. Gate: 1996 passed / 3 excluded.
  Dos sesiones reales verificadas, con selector DM/otro PC rechazado.
- **D113**: relevo principal impuesto por iniciativa, sin consulta redundante
  en combate ordinario; mini-turn vuelve sin reembolso, también ante decisión
  válida. Gate: 2007 passed / 3 excluded. Contador del modelo y Game/Postgres.
- **D114**: mini-turn pendiente recuperado desde World al reabrir; humano,
  PC IA, monstruo DM y fallo tras Escudo conservan ledger/recursos.
  Gate: 2011 passed / 3 excluded, cuatro regresiones en rojo/verde.
- **D115**: presencia de escena durable para no-PCs, sin pérdida/renovación de
  ficha ni recursos, con objetivos/efectos/turnos coherentes. Retorno después
  de reabrir y fallo posterior a salida comprometida cubiertos.
  Gate: 2034 passed / 3 excluded; 23 regresiones nuevas.
- **D116**: iniciativa automática con grupos factuales publicados una vez y
  apertura tras fallo terminal que introdujo un hostil; primer slot pendiente.
  Gate: 2039 passed / 3 excluded; cinco regresiones nuevas. Modal/crónica
  verificados en retorno real de la diana, con pausa/reload sin JS/overflow.
- **D117**: ambos asistentes por teclado, estado seleccionado accesible,
  metadata nativa correcta y texto custom conservado al volver atrás.
  Gate: 2045 passed / 3 excluded, seis regresiones nuevas. Clériga guardada/
  reabierta y partida creada con dos PCs IA desde navegador, 375/1440 px.
- **D118**: seis PCs conservados en fichas, ausentes excluidos y grupo móvil
  con PG/CA/estados actualizables. Gate: 2052 passed / 3 excluded, siete
  pruebas nuevas. Mesa real de seis a 375/1024/1440 px, disclosure estable
  ante PubSub y DM/pausa/reload; retirada de diana ausente de fichas comprobada.
- **D119**: nueva apertura real sanitizada, gesto/apositivo/comentario y
  atribución de citas sucesivas/streaming, con PNJ/estados/voz propia conservados.
  Gate: 2061 passed / 3 excluded, nueve regresiones nuevas. Fixture de login
  aislada para evitar choques entre ejecuciones. Sigue el relevo de preguntas
  a compañeros, reproducido con eventos Iria → DM → Iria.

- **D120**: petición declarativa a compañeros y respuestas de sus propios
  agentes en orden; cierre DM y retorno al humano. Cola durable, idempotencia,
  fallos, incapacidad al reabrir y prioridad humana/re-eval comprobados.
  Gate: 2085 passed / 3 excluded, 24 pruebas nuevas. Mesa real: Iria → Nera →
  Lyra → DM → Iria en 25,26 s, PG/casillas/escena/reloj conservados; pausa/
  reload a 375/1440 px sin JS/overflow. Reconocer la pregunta y llamar la tool
  depende del modelo; continúa la revisión de otras variantes de narración.

- **D123**: voz propia PC preservada y gestos/citas de otros PCs recortados;
  relativa de Iria real convertida en fixture, sujeto inmediato para conservar
  acciones de PNJ tras PC pasivo. Gate: 2117 passed / 3 excluded, 11 pruebas
  nuevas y 85 focalizadas. Otra pregunta en la mesa de seis: Iria → Nera →
  Lyra → DM → Iria en 17,12 s, PG/casillas/escena/reloj conservados; pausa/
  reload sin JS/overflow a 375/1440 px. `pc-voice-*`.

- **D125**: expectativa de confirmación releída/bloqueada, XP conservada,
  sync antigua rechazada sin rebajar World/baseline; Game canónico incluso
  sin proceso previo y configuración protegida frente al inicio. Avisos
  de redirección visibles/cerrables y envío deshabilitado. Gate: 2139 passed /
  3 excluded, seis pruebas nuevas y 45 focalizadas. Navegador: Mara L1 → L2,
  dos pestañas/Enter, 8/14 PG, 2/2 d6 y capacidad adicional exacta en seis mesas.
  Pausa/cursor/escena/reloj/PG/rest_state conservados; arena/ficha/reload a
  375/1440 px sin JS/overflow. `level-up-*`.

- **D126**: capacidad nueva de seis pools de clase sin recarga implícita,
  recién desbloqueados utilizables; ficha propia disponible/máximo factual.
  Gate: 2155 passed / 3 excluded, 16 pruebas nuevas y 238 focalizadas,
  compile/formato/diff correctos. Sira L2 paga dos puntos por una cuarta
  casilla: reserva 0/2, 8/14 PG, reloj 0 y pausa/reload sin JS/overflow.
  Relevo 31,29 s. Nueva acción inventada por DM con nombre corto queda para
  la siguiente regresión narrativa. `class-{progression,pool}-*`.

- **D127**: fixture real de nombre corto/subordinada, propiedad única entre
  personajes registrados y prioridad de nombres completos para PC/PNJ.
  Voz propia, estados pasivos, Unicode, Game/historial y burbuja web preservados.
  Gate: **2172 passed / 3 excluded** (31,9 s), **17** pruebas nuevas, **114**
  focalizadas, compile/formato/diff correctos. No reescribe apertura histórica;
  pronombres/otras formas y personajes no registrados conservan límites D29.
  `/tmp/dragonex-short-name-*.log`.

- **D128**: reservas de clase disponibles/capacidad compartidas con ficha,
  dados de golpe del ledger, cuatro flags y forma animal factual en brief.
  Gate: **2189 passed / 3 excluded** (32,3 s), **17** casos nuevos y **62**
  focalizados, compile/formato/diff correctos. Sira pregunta sin gastar:
  16,08 s, mismos 0/2 puntos/cuatro casillas/8 de 14 PG/escena/reloj/rest_state,
  pausa/reload/cursor y fichas 375/1440 px sin JS/overflow. `resource-context-*`.

- **D129**: progresión sobre forma original, bestia/PG intactos y deadline
  original conservado. ASI/codec/reversión manual/daño/caducidad, biblioteca,
  Game/TestModel y ficha web verificados. Gate: **2201 passed / 3 excluded**
  (32,8 s), **12** casos nuevos, **158** focalizados, compile/formato/diff
  correctos. PG fixture 6/11 → forma normal 7/29; sin nuevo playtest live.
  `/tmp/dragonex-wild-progression-*.log`.

## Playtest actual

Noche real19425: propuesta a Lyra/Vex en **10,59 s** con World igual; completar
las ocho horas en **16,24 s** usa una sola rest_party(long), capturada del DM
con finish_reason=stop. Reloj3600→32400, tres comienzos3600, Mara14/14 PG y
2/2 d6; casillas correctas por PC, Vex sin reserva real. Biblioteca, goblin
y facts del encargo intactos. Reinicio/reapertura conserva todo World/historial
(109 eventos)/pausa/cursor/cola y el límite24h del validador para los tres.
Fichas375/1440 px y teclado sin JS/overflow, ganchos retirados, compile limpio.
`short-adventure-noche-*`/`short-adventure-long-rest-runtime`.
Brecha pendiente: escena guardada sigue con el patio/encargo inicial; DM solo
llamó rest_party. Los briefs la presentan como «Escena» sin reloj ni cupo diario:
revisar contexto vigente antes de afirmar continuidad narrativa completa.

D143 registra un vocativo humano literal al consumir la declaración, antes
del narrador: no vuelve a perder al destinatario si este omite la tool.
**14** casos nuevos, ocho rojos iniciales, **72** focalizados y **2317 passed /
3 excluded** (39,3 s), compile/formato/diff correctos. Cola antes del beat,
modelo fallido/reintento, humano/reinicio, prioridad ajena y combate probados.
Nueva petición19425: Mara → Vex → DM → Mara en **6,51 s**, Vex85 pide agua
con voz propia; raw finish_reason=stop y limpio=persistido. World completo/
biblioteca/pausa/cursor/cola iguales, cero dados; teclado/reload/fichas 375/1440 px
sin JS/overflow. Fuera de esa gramática acotada sigue la tool semántica.
`short-adventure-explicit-question-*`/`explicit-question-response-raw`.

Reinicio real previo de esa mesa después del combate y descanso: PID nuevo,
anterior/cinco auxiliares terminados, todo World/historial (79 eventos)/pausa/
cursor/cola iguales y biblioteca intacta. Web reabre Mara 11/14 PG, 1/2 d6,
tres casillas, reloj3600, encargo/recompensa; fichas 375/1440 px sin JS/overflow.
Ganchos temporales retirados, compile limpio; lectores sin otro escritor,
sin reiniciar servidor/otras mesas. `short-adventure-process-restart`/
`short-adventure-restart-*`. La continuidad larga sigue abierta.

D142 conserva «a la posadera—.» en la voz propia y retira sujetos/etiquetas/
relativas PNJ reales. Fixture reconstruido produce exactamente la entrega
truncada guardada, sin atribuirle un raw original ya sustituido. **9** casos
nuevos, seis rojos iniciales más una relativa, **99** focalizados,
**2303 passed / 3 excluded** (37,2 s), compile/formato/diff correctos.
Agradecimiento19425 **8,55 s**, Vex propio/DM; raw del agente existente pausado,
finish_reason=stop, solo cabecera retirada, limpio=persistido. World/recursos
iguales, 375/1440 px sin JS/overflow; gancho temporal retirado, compile limpio.
Petición posterior de jarra **13,63 s** conserva World pero omite Vex: Human
→ DM → Human. Aquella captura de Vex es su agradecimiento anterior y no prueba
una respuesta nueva; ese relevo motiva D143, verificado arriba. `short-adventure-*`.

Aventura nueva19425 «El saquito del granero»: Mara propia L2, Lyra/Vex IA.
Apertura **5,01 s** y reconocimiento **20,63 s** sin World/recursos nuevos.
Declaración de Proyectil mágico abre combate; iniciativas factuales y desempate
DEX comprobados. Vex primero: nat20 +3 DEX +2 competencia =25 contra CA15,
crítico/Sneak Attack 1+2+6+6+3=18, goblin 7→0 y cierre automático antes de los
demás. **27,78 s** al humano, Mara conserva tres casillas al no ejecutarse
su conjuro. Muerte instantánea por daño masivo permanece fuera D78.
Petición Vex → devolución propia → DM **16,17 s**, dos facts persistidos
incluyen encargo cerrado/recompensa. Propuesta de descanso acordada Lyra/Vex
**15,63 s** conserva World; completar el descanso de Mara **21,75 s** aplica
un d6=1 +2 CON, 8→11/14 PG, 1/2 d6, reloj 3600 y casillas intactas.
Fallback TM no_decision al cerrar; latencia y otras variantes siguen abiertas.
Oráculo independiente, biblioteca igual, pausa/reload/teclado y fichas 375/1440 px
sin JS/overflow. `short-adventure-*`, lector sin segundo escritor; sin código
ni gate nuevo (D141, 2294 passed / 3 excluded). Frase Vex «le tiendo el saquito
a Aquí…» pierde el nombre de la posadera: siguiente diagnóstico de raw/filtro.

D141 cubre con fixture exacto el cierre «Iria las recoge…, asintiendo»:
pronombres antes de predicados inmediatos, entorno posterior fuera de citas
conservado, objetos/voz propia/PNJs/homónimos protegidos. **11** casos nuevos,
nueve rojos, **89** focalizados, **2294 passed / 3 excluded** (37,1 s),
compile/formato/diff correctos. `set_scene` rechaza la propuesta PC antes de
mutar y permite la PNJ. Nueva continuación19424: tres propias Lyra/Mara/Nera,
cierre DM sin gesto humano, **15,67 s**; World completo/recursos/pausa/cursor/
cola iguales y cero dados, teclado/reload/fichas 375/1440 px sin JS/overflow.
`clitic-agency-*`, lector sin segundo escritor. La nueva prosa no contiene
el disparador exacto (gate con fixture); pasado y otras estructuras semánticas
siguen conservados/bajo revisión.

D140 permite recuperar una elección ASI inválida sin perder borrador ni
conexión. Cinco rojos iniciales, **5** casos nuevos, **28** focalizados y
**2283 passed / 3 excluded** (36,9 s), compile/formato/diff correctos.
Sylvi L3, borrador L4 sin confirmar: punto de CON conservado tras parámetro
desconocido, clic DEX elimina el error local y deja los dos puntos asignados.
Misma LiveView, biblioteca y todos sus World/pausas/cursors/colas iguales;
recarga devuelve los dos puntos sin gastar. Teclado y vistas 375/1440 px sin
JS/overflow. `asi-input-*`; lector sin segundo Game escritor.

D139 rastrea las tres frases truncadas: los agentes habían entregado raw
completos con finish_reason=stop; el filtro confundía metáforas con PNJs,
quiebra de la luz con ejecución y borraba tiene antes de colon. Tres fixtures
exactos y **11** casos nuevos, **94** focalizados, **2278 passed / 3 excluded**
(35,8 s), compile/formato/diff correctos. Continuación19424 de Lyra/Mara/Nera:
**13,09 s**, propias completas, cierre DM y retorno Iria. Raw=filtrado=texto
persistido de los tres, World completo/recursos/pausa/cursor/cola iguales,
cero dados, recarga/fichas 375/1440 px sin JS/overflow. Lectura en el escritor
existente, diagnóstico temporal retirado. `observation-integrity-*` y
`response-integrity-*`. Pasado conservado y otras formas acotadas siguen abiertas;
el DM aún dice que Iria asiente sin petición explícita.

D138 reserva la primera decisión humana después de presentar una nueva mesa
mixta. Tres casos nuevos (uno/cinco compañeros y turnos previos/guardas),
**41** focalizados, **2267 passed / 3 excluded** (35,4 s), compile/formato/diff
correctos. Cuatro pruebas de equidad ahora parten de declaración humana real.
Nueva `/games/19424`: primera persona **6,01 s**, un DM/cero IA y escena
original igual. Pregunta a cinco **22,72 s**, uno cada uno, DM y vuelta Iria;
World completo/recursos/pausa/cursor/cola iguales, cero dados. Reload/fichas
375/1440 px sin JS/overflow, lectores sin otro escritor. `opening-control-*`.
Variabilidad del proveedor: no promete esos tiempos. Tres respuestas propias
terminan en «me»/«se»; se rastrea origen proveedor/sanitización antes de dar
por buena la coherencia de ese diálogo.

Nuevo grupo completo `/games/19423` (Iria + Lyra/Vex/Mara/Nera/Thane):
control inicial **25,76 s**, dos beats DM y uno Mara, sin repetir IA; escena
inicial íntegra. Pregunta a los cinco: **14,05 s**, una intervención de cada
compañero, cierre DM y retorno Iria. World completo/recursos/pausa/cursor/cola
iguales, cero dados; reload/fichas 375/1440 px sin JS/overflow y cinco tarjetas
móviles accesibles. `six-continuity-*`, lectores sin otro escritor. La prosa
introduce una muesca/sendero y «al girar la cabeza…» sin declaración humana:
continúa la revisión semántica. La apertura todavía deja actuar una IA antes
del humano y motiva revisar ese primer control. No garantiza esos tiempos.

D137 retira «al acercaros…» dentro de la descripción real y conserva PNJs/
entorno, citas abiertas/cerradas, preguntas y planes. Scene rechaza movimiento
implícito antes de mutar; Game/historial/preview/reload iguales. **9** nuevos,
**93** focalizados, **2264 passed / 3 excluded** (34,8 s), compile/formato/diff
correctos. `implicit-agency-*.log`. El vocabulario sigue acotado.
Continuación `/games/19422`: Sylvi pide opiniones/preguntas desde la sala;
Lyra/Vex una voz propia cada uno, DM y retorno humano **10,02 s**. World
completo/escena/recursos y pausa/cursor/cola iguales, cero dados, reload/fichas
375/1440 px sin JS/overflow. `dialogue-continuity-*`, lector sin otro escritor.
No prueba aún D136 con proveedor: el retorno usa la conversación registrada,
aunque los compañeros dicen «Sylvi». No garantiza latencia/consenso semántico.

D136 cubre identidad/presencia en el relevo por pregunta: «Sylvi» resuelve al
nombre completo, PNJs/IA de prefijo no roban el turno, nombres ambiguos no
fuerzan humano y los incapacitados no son elegibles. El humano previo persiste
por marcadores pese a 220 eventos entre acciones. **11** nuevos, **77**
focalizados, **2255 passed / 3 excluded** (35,0 s), compile sin warnings.
`addressed-identity-*.log`. Verificación offline; semántica de preguntas,
prosa implícita y continuidad/latencia con proveedor siguen abiertas.

D135 convierte la narración/escena de D133 en fixtures. Text retira colectivos
explícitos sin perder entorno/PNJs, y set_scene rechaza la propuesta completa
antes de World/log/cola. Admite invitaciones/nombres NPC completos y actor
propio. Pregunta Lyra/Vex ya registrada permanece en orden tras rechazo;
preview/reload verificados en LiveView. **15** casos nuevos, **97** focalizados,
**2244 passed / 3 excluded** (34,5 s), compile/formato/diff correctos.
`collective-agency-*.log`. Sin nuevo playtest de proveedor; alusiones implícitas
como «al acercaros» y consenso semántico siguen pendientes.

D134 conserva la participación de PCs entre respuestas DM. Seis casos puros
y siete Game/Postgres prueban equidad, elegibilidad/autoplay, frontera de
combate, contador/contexto TM, reapertura pese a 220 eventos, pausa/cursor,
TM mudo y prioridad humana. Gate **2229 passed / 3 excluded** (33,8 s),
77 focalizados y compile/formato/diff correctos. `exploration-fairness-*.log`.
Nueva mesa `/games/19422`, Sylvi + Lyra/Vex: control humano en **12,10 s** tras
una narración DM, sin turnos IA previos; pregunta a ambos en **17,61 s**,
voces propias, World completo codificado/pausa/cursor/intenciones iguales y
sin dados nuevos. Escena inicial conservada, reload/fichas a 375/1440 px sin
JS/overflow. `exploration-fairness-*`. No garantiza esa latencia siempre;
continúa la fuga colectiva y el traslado mediante set_scene de D133.

D133 conecta estilo guardado al constructor del DM. Tres casos/20 focalizados
verifican request custom, todos los escenarios, rehidratación pausada y legacy;
gate **2216 passed / 3 excluded** (32,9 s), compile/formato/diff correctos.
Nueva mesa `/games/19421`, Sylvi + Lyra/Vex IA: pregunta recibe ambas voces
propias, 20,70 s al humano, mismos Character/casillas/escena/reloj/ledger/
plazos/ausencia/pausa/cursor/intenciones y sin dados nuevos. Reload/fichas a
375/1440 px sin JS/overflow. `dm-style-*`.
La apertura tardó cinco turnos de Lyra y dos chequeos en ceder a Sylvi; introdujo
arrendajo/colgante y desplazó al grupo en prosa sin decisión humana. El
recorrido mantiene tono sin amenazas, pero quedan agencia y relevo oportuno.

D132 corrige el envío del rol DM/PC con historia compartida: el adaptador Chat
no usaba params.instructions y exAgent no insertaba el prompt al continuar
un historial no vacío. Cuatro casos/35 focalizados verifican messages del
modelo y codificación system, biblia/voz, resumen y ausencia de duplicados en
tools. Gate **2213 passed / 3 excluded** (33,1 s), compile/formato/diff correctos.
`instructions-delivery-*.log`. Falta conectar estilo y medir agentes nuevos.

D131 añade cinco casos de Game/capability/mesa para voces registradas durante
el beat: roster comprometido en persistencia, refresco antes de preview,
prefijos/homónimos, alta rechazada y compatibilidad de contexto. Gate **2209
passed / 3 excluded** (33,4 s), 60 focalizados y compile/formato/diff correctos.
`live-roster-*.log`; no es una nueva conversación de proveedor real.

Sylvi del Roble `/heroes/5899`, `/games/19420`: creada por teclado desde web,
L1 → L2 desbloquea 2/2 Forma salvaje; adopta lobo 11/11 con uso 1/2. L3
conserva bestia, guarda forma original 10/24 PG y amplía casillas a 4/2 sin
descanso; deadline 3600, reloj 0 y ledger vacío conservados. Revertir devuelve
10/24 PG y CA 15, conserva recursos y retira plazo. Fichas/pause/reload a
375/1440 px sin JS/overflow, 14,53/19,06 s al humano. D130 añade distintivo,
PG originales y aviso para conjurar; el playtest encontró y cubrió la omisión
del aviso en exploración. Tres casos nuevos/69 focalizados, gate **2204 passed
/ 3 excluded** (33,0 s), compile/formato/diff correctos. `wild-shape-*`.
El DM añade un aullido amenazante pese al escenario tranquilo solicitado;
los estados del motor son coherentes, pero ese tono requiere seguimiento.

Sira de la Chispa `/heroes/5898`, hechicera propia creada desde navegador,
partida tranquila `/games/19419`: L1 → L2 confirma en web y gana **2/2** puntos.
Fuente de magia paga dos por una casilla: **0/2** puntos y **4** casillas de
primer nivel. **8/14 PG**, **2/2 d6**, exploración/reloj 0/rest_state vacío y
pausa/cursor conservados, lectura assertada de Postgres sin otro Game escritor.
Relevo **31,29 s**, ficha/reload a 375/1440 px sin JS/overflow.
`/tmp/dragonex-playtest/class-progression-{live,state}.log`, capturas y
`class-pool-verify.log`. Gate D126: **238** focalizadas, **2155 passed /
3 excluded** (32,1 s), compile/formato/diff correctos.

La apertura tiene `cuando Sira deja caer la última chispa…`: nombre corto
frente al canónico `Sira de la Chispa`, otra acción inventada por el DM.
Se preserva como evidencia histórica. D127 reproduce esa apertura exacta y
retira su acción en nuevos beats, conservando ambiente/mensajero/cita; no
reescribe el historial previo. Alias únicos y nombres completos tienen
regresiones para no borrar voz propia o PNJ. Continúan otras formas de prosa
fuera del recorte curado. D128 entrega la revisión de reservas en el brief:
Sira pregunta si puede crear otra casilla, reconoce su reserva agotada y
vuelve al turno humano en **16,08 s**. Puntos/casillas/Character completo,
escena/reloj/rest_state/pausa/cursor/intenciones iguales a la captura anterior;
lectura Postgres sin otro escritor. Nuevas narraciones seq 16/19, ficha/recarga
375/1440 px sin JS/overflow. `/tmp/dragonex-playtest/resource-context-*`.
No se declara una obediencia universal del modelo por esta consulta.

Mara `/heroes/5164` ya subió a **L2** desde navegador (D125): dos pestañas
montadas en L1, una confirmación por Enter y la otra rechazada con aviso
completo/cerrable. **8/14 PG**, **2/2 d6**. En seis partidas propias se conserva
pausa/cursor/escena/reloj/PG/rest_state/fase y capacidad exacta: `/games/15110`
y `/games/16629` pasan 1 → 2 casillas; `/games/15574`, `/games/16225`,
`/games/17032` y `/games/17373` pasan 2 → 3. Arena/ficha/recarga a 375/1440 px
sin JS/overflow. Lectura de Postgres sin otro Game escritor, con comparaciones
assertadas. `/tmp/dragonex-playtest/level-up-{before,after,live}.log` y capturas.
**45** focalizadas y **2139 passed / 3 excluded** (31,5 s), compile/formato/diff
correctos. El objetivo continúa con recursos de clase al progresar.

D124 corrige progresión: capacidad de magia nueva sin reposición de lo gastado,
incluidos pacto y excedentes de Fuente de magia. **16** pruebas nuevas,
**89** focalizadas, **2133 passed / 3 excluded** (30,9 s), compile/formato/diff
correctos. Tool DM/TestModel y confirmación LiveView por Game, pausa/reapertura,
HP/rest_state/reloj/límite diario verificados. El playtest preparado entonces
queda aplicado/verificado por D125; las seis mesas siguen pausadas.

Entrega D121–D122 (2026-10-02): **18** pruebas nuevas de admisión/LiveView y
**3** de runtime. Sala vigente validada en transacción, nombres ambiguos
rechazados, reintentos sin reset y motivos recuperables. Base test separada:
**2106 passed / 3 excluded** (30,3 s), **35** focalizadas, compile sin warnings,
formato/diff correctos. La verificación visual reprodujo el aviso fuera de
viewport; ahora está completo junto al selector, enlazado para accesibilidad.

Sala propia `/games/19212`, Iria e Invitada/Lena: error de elección → Enter
→ plaza/grupo compartidos → recarga a 375/1440 px, sin JS/overflow. Se conserva
configurada, sin beats. Tras separar las bases, ambas cuentas siguen viendo
los mismos personajes/plazas. `/tmp/dragonex-playtest/lobby-admission-*`.
El gate actual usa `dragonex_test`, sin salas del navegador; no se afirma
que los casos de copias obsoletas sean una prueba de carga simultánea.

Cuenta propia **Prueba de aventura**, registrada desde navegador; partida
`/games/14025`, La Taberna del Dragón Rojo. Thane humano, Lyra y Vex IA.
No se modifican partidas ajenas. Phoenix local usa el puerto ya asignado 4035.

- Registro → wizard → compañeros → mesa; escritorio 1440×1000 y móvil
  390×844. Sin errores JavaScript en los recorridos de ficha, intención,
  borrado, DM/PC y restauración del borrador.
- Interacción sobre asaltos: **28,69 s** hasta el siguiente turno humano.
- Salida al camino → emboscada de dos goblins y lobo: **116,90 s** hasta
  Thane después de recorrer acciones de varios combatientes. Se observan
  `make_attack` fuera de turno y un fallback por límite de tokens del TM.
- La apertura puso una acción/dialogo en boca de Lyra y asentimiento de Vex;
  fixture real en `test/fixtures/narration/dm_tavern_puppet.txt`, corregido en
  D103. Los eventos anteriores conservan su contenido persistido.
- Batalla cerrada después de dos declaraciones humanas de ataque; **74,92 s**
  y **75,61 s** hasta recuperar el turno. Lyra 3/7 PG y ambas casillas de nivel
  1 gastadas, Thane 12/12 y Vex 10/10; enemigos a 0, fase exploración/ronda 2.
  Pausa y estado persistido verificados. Sin errores JS durante combate.
- El último goblin narró que huía y desaparecía después de un chequeo, pero
  seguía presente en World. Thane renunció narrativamente a atacarlo y Lyra
  lo alcanzó con Magic Missile en el turno siguiente. Sigue abierto representar
  salidas de escena sin confundir prosa/chequeo con una transición aplicada.
- Los segundos anteriores no demuestran todavía mejora de latencia por D105.
- Continuidad: descanso corto real de Lyra de 3/7 a 7/7; consume su único
  dado de golpe, no repone las casillas. Reloj 3606 s. Nuevos hostiles abren
  otro combate; dos errores de `condition_to_remove` reproducen D108 y un
  cursor de fallback repite a Lyra. Partida pausada en Thane, ronda 2.
- Héroe propio `/heroes/5164`: Mara de la Bruma, maga humana nivel 1, 8/8 PG,
  CA 12; guardado/reabierto a 1440/375 px sin errores JS ni overflow.
- Nueva partida propia `/games/15110`, arena de entrenamiento, Mara sola.
  Magic Missile inflige 11 y 14 de daño; reservas pasan de 2 a 1 a 0, primer
  maniquí derrotado y combate cerrado por el motor. Relevos de **31,77 s** y
  **42,97 s**. El DM prepara después otra diana sin rellenar las casillas.
  Pausa/reload conserva 0 casillas y 1/1 d6; ficha abierta con Enter a 375 px,
  texto de armas/hechizos en español. Sin errores JS ni overflow horizontal.

- En la misma arena, Rayo ígneo acierta (15 contra CA 15) e inflige 10 sin
  gastar casillas: siguen a 0. Cierre de práctica + Recuperación arcana dejan
  1 casilla de nivel 1. Pausa/reload mantiene 1 y 1/1 d6. Relevos de
  **43,53 s** y **46,61 s**; sin errores JS. La latencia sigue siendo un frente.
- Mesa propia `/games/15574`: cuenta Invitada de prueba crea Lena del Río,
  se une al hueco humano y recibe el inicio. Ambas intenciones se encolan
  mientras está pausada y se resuelven con sus actores correctos al reanudar.
  La invitada no cambia de personaje con la URL ni obtiene DM/ajustes; el
  creador inspecciona DM y retorna a Mara. Declaraciones abiertas con Enter
  y toque, pausa compartida/reload a 375/1440 px sin errores JS ni overflow.

Artefactos locales (temporales): `/tmp/dragonex-playtest/` conserva capturas,
automatización Python/Playwright y logs de navegador; los gates están en
`/tmp/dragonex-web-quality-full.log` y `/tmp/dragonex-flow-quality-full.log`.
La sesión de navegador de prueba contiene credenciales y no se publica.

Nueva arena propia `/games/16225`, Mara en solitario: dos Rayo ígneo reales
después de D113. **8,46 s** (fallo) y **13,01 s** (impacto, 9 de daño) hasta
recuperar el turno; la diana toma su slot entre ambos, 2 casillas de nivel 1
conservadas. Pausa/reload y ficha a 375/1440 px sin errores JS ni overflow.
Preparación de la diana: 21,59 s. Frente al turno previo de 43,53 s es una
muestra favorable, no una comparación controlada ni garantía de latencia.
Evidencia `/tmp/dragonex-playtest/handoff-live.log` y capturas `handoff-*`.

Arena propia de presencia `/games/16629`: Magic Missile inflige 12 y deja la
misma diana en **8/20 PG**, con Mara **1 casilla**. Retirada aplicada durante
el turno DM cierra combate; reentrada conserva 8/20 y 1 casilla, e inicia la
iniciativa automática. Preparación/ataque/retirada/retorno: **7,09/8,65/17,29/
15,71 s** hasta el humano. Pausa/reload a 375/1440 px, sin JS/overflow; estados
Postgres leídos sin otro Game escritor. `/tmp/dragonex-playtest/presence-live.log`.
El retorno automático reveló dados de iniciativa sin evento/modal, corregidos
en D116. Nueva retirada/retorno: **14,59/22,73 s**; ambos grupos visibles en
modal/crónica (Mara 1+2=3, diana 10−4=6), sin duplicados. Pausa/reload a 375 px
sin JS/overflow, conservando PG/casillas. `forced-dice-live.log`.

Mesa propia `/games/17373`: Iria, Lyra, Mara, Nera del Camino, Thane y Vex.
Antes D118 ocultaba Thane/Vex en exploración; ahora muestra los seis, la
ficha propia primero y cinco compañeros en cajón móvil. PG visibles:
Lyra 7/7, Mara 8/8, Nera/Thane 12/12 y Vex 10/10. Declaración/borrado en
pausa conserva el desplegable abierto; DM muestra los seis. 375/1024/1440 px
sin JS/overflow, pausa/reload. Nera propia `/heroes/5474`, humana exploradora.
`party-after.log` y capturas. Retirada real de diana en `/games/16629` en
19,25 s: desaparece de fichas, conserva 8/20 PG y Mara una casilla; pausa/
reload sin JS/overflow (`presence-cards-live.log`, estado Postgres leído).
El setup de seis reveló nueva fuga narrativa de Lyra, cubierta por fixture/
regresiones D119, sin reescribir historia guardada. La pregunta real a Nera/
Lyra tardó **14,05 s** y volvió directamente a Iria pasando por DM: no actuaron
los PCs interpelados. Dio otra cita implícita, cubierta por regresión de
atribución continuada; queda abierto el relevo real a sus agentes. PG intactos,
casillas Iria/Lyra/Mara a 2, pausa/reload sin JS/overflow.
`party-dialogue-{live,state}.log`.

Tras D120, misma mesa y selección de modelo, agentes reiniciados desde
Ajustes: la misma declaración produce **Iria → Nera → Lyra → DM → Iria**,
con eventos propios de Nera/Lyra. **25,26 s** para todo el intercambio. PG,
casillas, escena y reloj conservados; cola liquidada. Pausa/reload a 375/1440
px sin JS/overflow. Estado leído de Postgres sin otro Game escritor.
`conversation-{live,state}.log` y capturas. La petición depende de una tool
explícita del modelo; ese recorrido real no garantiza todas las variantes.

Asistentes comprobados: Iria del Alba (`/heroes/5425`), humana clériga nivel 1,
10/10 PG y CA 17, creada por Tab/Enter/Espacio. Point buy/retorno a array,
habilidades, idioma, equipo y hechizos; selección conserva foco y controles
pequeños alcanzan 44 px. Partida `/games/17032`, Guardia del puente de la bruma,
Iria humana con Mara/Vex IA; texto custom conservado al volver atrás, valores
guardados y pausa/reload. 375/1440 px sin JS/overflow. `wizard-keyboard-live.log`
recoge el recorrido; `wizard-keyboard-verify.log` verifica ficha/URL y mesa.

## Orden de continuación

0. Ampliar recuperación anterior a la confirmación: D150 guarda World,
   D151 aísla caídas, D152 evita replay en Game vivo y D153 recupera resultados
   confirmados entre Games.
   D154 cierra efecto→resultado con un comprobante en el mismo World;
   D157 cierra dados preparados de tools con World/comprobante en una
   transacción. D159 confirma iniciativa, D160/D161 resuelven daño mínimo y
   desglose, y D162 reserva/confirma inicio de turno con gate/VM/navegador
   acreditados. D163 confirma cierre/intenciones/notas y recuperación de
   victoria/actor. D164 reutiliza respuestas finales completas ya publicadas
   para el actor pendiente. Revisar intentos incompletos, actores sin comprobante
   y relevo posterior,
   investigar la limpieza intermitente de tests si reaparece y retomar
   continuidad narrativa real. D165 completa la llegada de19425 a la plaza/
   taberna y registra sus dos tramos de900 s, con confirmación explícita del
   primero omitido. D166 continúa entrada/diálogo y corrige la plaza obsoleta
   en el registro del interior. La traza mide recorder9,579 s y TM6,274 s en
   un movimiento de22,895 s; preguntas PNJ sin esos pasos8,657/5,026 s.
   Reducir esperas conservando voz IA; probar otros movimientos y confirmar
   la invitación gratuita de Maribel frente al precio del menú. D167 confirma
   esa oferta y elimina la reformulación humana en preguntas informativas
   literales: una petición DM/4,536 s con World igual, restart/navegador verdes.
   Continuar elección y servicio con decisiones propias IA, duraciones y hechos
   durables; conservar revisión de esperas. D168 completa elección/ideas con
   ambas voces y D169 repara compresión UTF-8 en una pregunta que envejece.
   La espera de veinte minutos no queda registrada por la guía D165: después
   de reparar JSON, DM omite la tool. Reconciliación explícita aplica1200 s una
   vez y deja35400, con restart/navegador verdes. D170 exige registrar las
   esperas literales nuevas antes de la final DM y conserva comprobantes de
   interrupción parcial/0 s sin cobrar de nuevo tras restart.19425 registra
   cinco minutos sin reconciliación manual,35400→35700,32,603 s y recursos
   intactos. Repite el rumor anterior, que ahora queda en facts. Siguiente:
   viajes/otras duraciones, menos peticiones/recorder, detalles del combate
   al contarlo y continuidad de hechos PNJ. La limpieza SQL sigue abierta:
   D170 vuelve a observarla, incluso en una traza con max_cases1.
   D171 elimina la reformulación de esperas pasivas acotadas y verifica180 s
   naturales sin petición humana,17,884 s/restart/navegador. Revisar registro
   idéntico dejado pendiente, límite TM y afirmaciones nuevas del PNJ antes
   de ampliar otras duraciones. Gate2519/3 limpio no cierra la causa SQL histórica.
   D172 cierra la falsa revisión tras espera aislada con guardas durables y
   recuperación,53 focalizados/2529/3. Dos muestras reales120/60 s dejan revisión
   limpia pero reescriben la escena; no prueban idéntico con proveedor. Siguiente:
   separar entorno de diálogo/pose transitoria PNJ, conservar hechos nuevos y
   revisar jarra a medio vaciar/relato del combate antes de ampliar campaña.
   Mantener seguimiento de TM/latencia y limpieza SQL/fixture agotado.
   D173 separa entorno/conversación en la instrucción del recorder y preserva
   el diálogo al registrar/reiniciar. La escena real retira pregunta/oferta,
   pero mantiene detalles transitorios. El DM cierra la presencia del forastero
   con datos nuevos solo en history: próxima revisión de continuidad/durabilidad
   y avance de trama por inactividad. D174 identifica/corrige el cierre de
   LiveViews durante SQL y la vida del contador TMSpy:2532/3 en dos seeds,
   sin desconexiones ni errores inesperados. Los casos antiguos de owner
   sin atribución se investigarán si reaparecen. Continuar coherencia PNJ,
   durabilidad de afirmaciones y latencia antes de ampliar campaña.
   D175 evita tratar esperas deliberadas como atascos, con interrupción/restart
   y entorno idéntico confirmado en dos muestras reales15 s. Sigue pendiente
   registrar afirmaciones PNJ con su fuente, repetir menos imágenes sensoriales
   y sostener relevos sin agotar tokens TM. No reparar history antiguo por
   inferencia ni convertir rumores en hechos objetivos automáticamente.
   D176 entrega registro atribuido y lo verifica con Maribel/compacción/
   restart: una versión durable no confirma su contenido. Continuar fuente
   nueva del zagal/cabras frente a biblia/historial, cambios físicos narrados
   que no llegan al entorno. D177 elimina la reformulación de viste/oíste/
   escuchaste bajo guardas D167. La biblia de19425 está vacía; ausencia del
   zagal allí/historial no prueba contradicción. Revisar nuevas versiones del
   forastero. D178 corrige ficha propia/scroll al abrir sin mover lectura
   durante patches. D179 completa adaptación intermedia/paisaje y controles
   por teclado, incluyendo ficha propia de combate y PG visibles.
   D180 verifica una aclaración contextual de Maribel sin alterar World y
   corrige el presupuesto256 que truncó una decisión TM; espera/reinicio
   reales acreditados con1024 configurable. La revisión4,261 s responde a
   WorldClock/D172, con comparación de estado y commit revalidado; ya usa
   summarizer barato. Conservar esas guardas al optimizar. Ampliar variantes con varios PCs,
   cambios físicos narrados y latencia. Mantener calidad semántica, sin registro automático
   de toda prosa ni reclasificación de hechos anteriores por inferencia.
   D181 contrasta el relato del combate con los dados: dos conversaciones
   conservan resultados/recursos y responden ambos PCs en orden. Corrige
   etiquetas críticas/death_save perdidas en History. El narrador humano
   añade en ambas preguntas la misma jarra a medio vaciar; el cierre DM
   repite cuenco/postigos/tarde. Siguiente: habla informativa PC literal con
   guardas y menos repetición;395 eventos aún no superan el corte400.
   D182 elimina esa reformulación: habla exacta, tres runs/World igual y
   reinicio sin duplicados. El cierre DM mantiene esos motivos repetidos.
  408 eventos aún conservan el combate antiguo en la ventana400; revisar
   continuidad cuando la evidencia quede fuera, sin asumir memoria ilimitada.
   D183 corrige el anti-repeat contradictorio; la última respuesta aún añade
   tarde tibia. Seguir cierre discreto controlado por motor cuando el mundo no
   necesita resolver nada, sin omitir PNJs/efectos. No dar por resuelta la prosa.
   D184 acredita ese cierre para consultas PC puras sin cambios y devuelve el
   turno sin DM; peticiones al mundo/evidencia incompleta conservan resolución.
   Continuar continuidad fuera de400 y cambios físicos PNJ. No dar por
   certificada la fidelidad semántica de toda narración.
   D185 separa eventos públicos y notas DM antes de enviar contexto a los
   modelos; continuar recuperación de evidencia vieja respetando esos mismos
   permisos. No convertir la clasificación de secretos de prosa en este filtro.
   D186 recupera hasta32 dice anteriores con audiencia/prompt actual protegido
   de compresión; ambos PCs vuelven a verbalizar el resultado exacto antiguo.
   Seguir prosa con gesto de jarra copiado entre voces, consecuencias PNJ y
   recuperación de más pasado sin convertir archivo parcial en memoria ilimitada.
   D187 alinea el prefijo y nudge de respuesta; D188 publica información/
   opinión simple sin reinterpretación humana.19425 obtiene pista atribuida
   del cruce y vuelve a ambos compañeros con habla exacta/World intacto.
   D189 acredita desplazamiento declarado900 s/escena del molino y preguntas
   al zagal con testimonio durable y habla exacta, sin confundir roles con PCs.
   Próximo: seguir las pistas y consecuencias físicas; revisar semántica/memoria
   fuera de ventana. La era alternativa de Maribel aún solo está en prosa.

   D190 añade inventario factual/replay/revisión durable; D191 distingue etapas
   de espera y respeta pausa ante error tardío. D192 elimina el narrador humano
   de «¿De qué…?» bajo guardas existentes; viaje al norte900 s/reloj37935 y
   consulta de origen/hatillo a ambos PCs comprobados.682 eventos preservados.
   Próximo: seguir huellas/consecuencias físicas, revisar voz propia y memoria
   de testimonios fuera de ventana/tiempo relativo. No considerar una versión
   PNJ prueba objetiva ni las muestras un SLA; beta permanece en preparación.

   D193 añade primera marca del reloj a testimonios nuevos, sin fechar legado
   ni renovar duplicados aún conservados.713 eventos/clock39735, pista nueva
   del zagal y consulta Lyra/Vex después de viajar900 s acreditados. Seguir
   huellas al norte, consecuencias físicas y versiones nuevas/contradictorias,
   conservando memoria acotada/atribución y medición honesta de latencia.

1. Ampliar consistencia y mediciones con múltiples PCs: D120 entrega
   respuestas propias, cola durable y prioridad humana; D123 cubre la relativa
   real de Iria y voz/sujeto de los demás PCs; D127 cubre la subordinada real
   y nombres cortos/completos; D128 comparte recursos factuales con la ficha.
   Revisar otras formas de prosa, preguntas al grupo y progresión mientras
   sigue activa Forma salvaje. D129 cubre progresión de ambas formas/deadline;
   D130 muestra transformación/vitalidad original y verifica Sylvi real.
   D131 cubre personajes creados durante el beat. Revisar tono solicitado:
   D132 entrega el rol perdido y D133 conecta estilo/mesa nueva. D134 cubre
   equidad/relevo y verifica una nueva apertura en 12,10 s. Revisar «El grupo
   cruza…» y traslado mediante set_scene quedan cubiertos de forma acotada en
   D135. D136 cubre nombres cortos/identidad y disponibilidad en preguntas.
   D137 cubre «al acercaros…» y continuidad real del diálogo en 10,02 s.
   D138 reserva primera persona, nueva apertura seis en 6,01 s; D139 corrige
   tres falsos positivos con raw original y continuidad real en 13,09 s.
   D141 cubre el cierre con pronombre/gesto y conserva entorno; seguimiento
   real de tres en 15,67 s. D140 recupera entradas ASI inválidas sin perder
   elecciones/conexión ni mutar biblioteca/partidas al elegir.
   Revisar otras alusiones, semántica de preguntas/viaje acordado, fidelidad a
   escenario y decisiones locales de PCs. D158 reserva la respuesta PNJ
   literal/retorno humano, real8,143 s sin consulta al coordinador. Ampliar
   continuidad del viaje explícitamente elegido y datos narrativos durables.
   D110/D113 cubren recuperación e iniciativa ordinaria sin consulta redundante;
   D114 conserva también el mini-turn pendiente al reabrir.
2. Repetir salida/reentrada explícita en una aventura con PCs IA. D115/D116
   cubren presencia durable, dados automáticos y transición tras fallo de actor.
3. Ampliar magia, descanso y progresión del héroe propio en navegador;
   revisar qué entiende el jugador sobre hechizos de efecto narrativo.
4. Ampliar la mesa compartida ya comprobada y revisar grupo completo/ajustes
   a 375 px, teclado/foco, nombres de turnos y errores/esperas. Los errores
   de unión y sus reintentos están verificados en D121. D117 verifica
   los asistentes. Conservar el diseño D84.
5. Volver a los demás hallazgos de motor del backlog con reproducciones y AC;
   actualizar este estado y `progress.md` en cada entrega verificable.
