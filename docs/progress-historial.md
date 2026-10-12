# Dragonex — progreso y estado

Estado canónico por feature. **Esta es la fuente de la verdad sobre qué está
hecho, qué falta y qué se simplificó.** Si el `ROADMAP.md` o cualquier handoff
histórico (`docs/historical/`) discrepan con esto, manda este doc.

- Últimos gates completos, **con D237**: **3027 passed / 3 excluded** en
  ambos grafos (local y Hex, sin skipped) (`MIX_ENV=test bin/dev test`,
  2026-10-12); compile `--warnings-as-errors` limpio y formato limpio.
- **Qué falta y en qué orden** → [`producto/03-plan-fases.md`](producto/03-plan-fases.md)
  (backlog F6/F7 accionable). **El contrato de requisitos** (con criterios de
  aceptación) → [`producto/02-requisitos.md`](producto/02-requisitos.md).
- Arquitectura y porqués → `docs/decisions.md`.
- Cómo funciona el bucle de una partida en detalle → `docs/FLUJO_PARTIDA.md`.
- Cómo se verifica cada cambio → `docs/tecnico/09-estrategia-pruebas.md`.

## ✅ Producción alineada con exAgent 2.1 / dic_ex 0.3 de Hex (D237), 2026-10-12

El grafo de producción deja exAgent 1.2/dic_ex 0.2 y usa las versiones ya
publicadas que dev llevaba usando: misma API en ambos grafos y los dos tests de
vista previa ya no se saltan en Hex. Sin desplegar. La DB `dragonex_test`
necesitaba `ecto.migrate` (columna `games.locale`).

## ✅ Motor bilingüe es/en: cada partida íntegra en su idioma (D235, D236), 2026-10-04

Cada partida elige su idioma en el asistente (`games.locale`). En ese idioma
salen los mensajes del motor, las tiradas, los prompts de DM/PC/TurnMaster, los
guardrails, el saneado de texto, los escenarios, los efectos de hechizos y la
interfaz de la mesa. Los catálogos ingleses están completos: engine 602,
prompts 284, ui 531. El castellano no cambia. La partida live 19453 en inglés
no tuvo restos de castellano. Convenciones en
[`tecnico/12-localizacion.md`](tecnico/12-localizacion.md). Las partidas anteriores son `es`.

## 🟡 Narración en vivo mientras se genera (D234, R16), 2026-10-04

La burbuja de la mesa vuelve a mostrar la narración del DM y de los PCs IA
mientras el modelo escribe el `text` de `narrate`/`final_result`; al publicarse
el evento validado la sustituye. Requiere el evento opcional `tool_call_delta`
de exAgent (publicado; prod lo usa desde D237) y un proveedor que trocee los argumentos:
Decart (el enrutado fijado hasta ahora) los entrega de golpe, fireworks sí los
trocea. `DRAGONEX_DEEPSEEK_PROVIDERS` elige el proveedor (por defecto decart).
Verificado live en 19451 con fireworks. Pendiente: decidir proveedor por
defecto y cualificarlo.

## ✅ Home rediseñada: crónica viva y logotipo pixel (D233), 2026-10-04

La home reproduce un combate real de 19451 sobre el pergamino, con dados 2D
de dic_ex cayendo en una bandeja de fieltro y lectura del último resultado;
«Declara tu intención…» lleva a Crear cuenta. Fuera el dragón y la blackletter
del título: nuevo logotipo SVG pixel en la cabecera de toda la app. Sin JS
propio ni llamadas al modelo; demostración pausable. 7 tests nuevos; revisión
final independiente (dos rondas) y capturas 1440/375 sin desbordamiento ni
errores JS. PRODUCT.md y DESIGN.md creados. Pendiente: localizar en el motor
las claves inglesas de las tiradas (shortbow, piercing) que también ve la mesa.

## 🟡 Playtest — el libro del molino (19451), correcciones D230–D232, 2026-10-04

Mesa nueva por UI, DeepSeek4.1/OpenRouter, Thane humano con Lyra/Vex IA:
pregunta a Mira, combate con dos ratas, recogida y entrega del libro. D228 se
ejercita en vivo dos veces: el DM agota `record_npc_statement` con «Mira, la
molinera» (pausa con motivo, reanudación, segundo fallo omitido con nota) y el
resolutor de Thane agota `spawn_monster` contra ratas sin ficha (pausa). D227
pliega la doble voz humana en la crónica. Corregido: aposición de la fuente
(D230), iniciativa sin hostiles y guía para objetivos sin ficha (D231), nota de
intención pendiente para el DM (D232), marca «Es TU turno (DM)» eliminada por
`Text.scrub`, doble punto de la apertura, favicon (404), «Antorcha» traducida,
objetos nuevos en castellano (`grant_item`) y cierre de encargo con
`establish_fact` tras una entrega. Tras las correcciones el combate usa dados
en cada ataque, el testimonio queda registrado, el libro entra/sale×1 y no hay
errores JS ni desbordamiento a 1440/375. Abierto: el DM narró un ataque de
Thane sin tirada antes de D232; la entrega no registró cierre antes del ajuste;
ninguno se ha revalidado live. Mesas 19443–19450 intactas (sha256).
Gates 2905/3 local y 2895/3 Hex; dev134/test141 forzados sin warnings.

## ✅ Turno fallido pausa y se reanuda sin repetir efectos — offline (D228/D229), 2026-10-04

19447/52 devolvía la palabra tras un fallo duro del DM con prosa de relleno
(«Una pausa breve…») y la entrega sin resolver. Ahora el primer fallo duro de
un turno de actor pausa la mesa en ese turno con nota pública del motivo y su
checkpoint; reanudar reejecuta el mismo `turn_id` y las tools pagadas
devuelven su recibo (sin dados ni costes nuevos). Un segundo fallo del mismo
turno lo omite con nota, nunca prosa inventada. Siete casos nuevos, rojos con
la política anterior (humano con/sin replay, doble fallo, monstruo con ataque
pagado, 503 agotado, 400, proveedor caído). Once módulos que prueban la vía de
omisión usan `setup :skip_failed_turns`. La sonda destapó guiones agotados que
el relleno ocultaba y una carrera de WorldDriven (D229): en exploración el
reparto seguía un cursor ajeno a `current` y podía dar al DM dos beats seguidos
tras un handoff; ahora continúa tras quien tenía el turno. Un invitado ve
«En pausa · la reanuda quien creó la partida» (solo el creador tiene el botón).
Gates 2892/3 local (seed 0 y 4242) y 2882/3 Hex; dev134/test141 forzados sin
warnings. Pendiente: partida live con un fallo real del proveedor.

## ✅ Ecos de voz en el chat se muestran una vez — offline (D227), 2026-10-04

El chat repetía prosa por dos vías: la voz humana literal de D221 tras el
`:action` original (14/14 declaraciones recientes, chip D112 + línea visible)
y cierres `final_result` que copian `narrate` (19447/35→36, 19448/22→23,
19443/44→45, cita de Vex 19449/14→15, 258/55→56). `Dragonex.SpeechEcho`
(puro) pliega, por actor y `turn_id`, copias exactas, contenidas (≥4 palabras)
o casi idénticas (jaccard de raíces ≥0,6); paráfrasis y continuaciones se
conservan. La acción humana con voz publicada se lee visible antes de sus
dados y sin chip; sin voz, el chip D112 sigue. Chat y History usan el mismo
análisis; eventos, checkpoints, recibos y paginación no cambian. En origen,
la instrucción de cierre y la respuesta de `narrate` piden continuar sin
repetir. 17 casos nuevos (rojo LiveView 0/2 y History 2/3 sin el análisis);
probe sobre 55 mesas dev/965 eventos oculta exactamente 5 copias y 14 voces,
sin falsos positivos. Gates 2888/3 local (107,4 s) y 2878/3 Hex (65,7 s),
seed0, secuenciales en dragonex_chat_test con deps/build Hex propios; test141
forzado con warnings-as-errors limpio. Mesas protegidas solo leídas.
Falta partida live con el refuerzo de prompt; las paráfrasis (19447/20→21)
siguen visibles. R16 necesita deltas de argumentos de tools en exAgent
(hoy solo texto/razonamiento/uso): requiere publicar una versión nueva.

## ✅ Total de daño y componentes incluidos — offline (D226), 2026-10-04

19448 conserva Vex«13 más5» cuando sneak5 ya forma parte del total13.
Actions presenta ahora «13 de daño piercing en total (incluye 5 sneak)»;
Savage/furia/marca siguen el mismo criterio por golpe. Smite mantiene su
componente radiante adicional, e inspiración se identifica en el ataque.
No cambia matemática, dados, PG, slots ni formas persistidas. Ocho regresiones
rojas antes del feedback; el primer verde4/8 descubre listas de RollLog
comparadas con tuplas. Corregidas esas expectativas y un default sin uso,
8/8 y214 focales en0,3s, conservando oráculos de recursos/dados anteriores.
Gates nuevos2871/3 local y2861/3 Hex, secuenciales en DB test propia;
incluyen8 casos propios y1 caso externo de tarjeta DC/CA, sin atribuirlo a D226.
Dev133/test140/prod Hex133 forzados limpios; formato/diff y641 fuentes
estables durante gates. Mesas19443–19449, originales/héroe y47 estilos exactos.
Recibo attack-damage-message-verification.json. No garantiza obediencia
semántica ni cierra R16/beta; esos gates preceden el trabajo concurrente D227.

VM nueva con D226 ejecuta19450/46, DeepSeek4.1/Decart: la apertura20,899s
no registra enemigo; la declaración de entrada/ataque abre combate64,293s
con cuatro iniciativas antes de atacar. Vex10 incluye sneak5, bandido queda1;
Thane vuelve a declarar en su slot y hace7/fin de combate en18,115s.
Vex no cita números en prosa: no prueba corrección aritmética del modelo.
Recogida24,238s añade campanilla×1; entrega16,615s retira×1/guarda cierre
único. Cero retries/fallos; PG12/7/10, Lyra2 casillas y reloj0 conservados.
Reload1440/375 mantiene46/SQL/narraciones,47 estilos y referencias previas,
cero JS/overflow/bundle sibling.19450 queda protegida. El recibo
attack-damage-message-live-verification.json registra cambios concurrentes
en narración/chat/History y docs exAgent; no presenta toda la partida como
ejecución de las641 fuentes fijas anteriores. Actions conserva su hash.
Testimonios PNJ indirectos y un fact histórico que aún dice campanilla sobre
la mesa requieren revisión de fidelidad/memoria; R16/AC-31.3d/beta abiertos.

## ✅ Iniciativa antes de ataques enemigos — offline (D225), 2026-10-04

19448/48 con DeepSeek4.1/Decart recoge/entrega campanilla×1 y guarda cierre
único; entrega11,541s sin retry y reload1440/375 conserva SQL/recursos/fuente.
Pero el bandido ataca en exploración12 antes de iniciativa14–17 y otra vez
en combate21. Game admite ahora nuevas make_attack de enemigos sólo después
de iniciativa; rechaza antes del callback/RNG, sin impedir replay pagado.
Rojo5/6 con d20 extra; dos regresiones deterministas y72 focales finales
verdes en6,9s; gates completos2862/3 local y2852/3 Hex, secuenciales y limpios.
Dev133/test140/prod Hex133 forzados sin warnings. Ésta es la prueba offline
del rechazo de AC-29.12. La prosa Vex«13 más5» suma sneak
ya incluido en total13; DM22/23 se repite. Se conserva48 como reproducción;
no demuestra el retry D223 live ni cierra fidelidad/R16/beta.

La VM nueva con D225 ejecuta19449/38, DeepSeek4.1/Decart estricto: cuatro
iniciativas antes de todo ataque, orden respetado y ningún ataque enemigo
extra. Vex hace7 y Lyra9, gasta una casilla y termina el combate; recogida×1,
entrega×1 y cierre canónico único.39,734/10,520/16,111s hasta el humano, sin
retry. No hay evidencia pública de que se ejercitara el rechazo de admisión;
no presentarlo como prueba live de esa rama. La cita de Vex se repite entre
prosa intermedia/final y se guarda un testimonio PNJ indirecto; fidelidad abierta.
Restart/reload1440/375 conserva38/SQL/narraciones,47 estilos y mesas/héroe
previos, cero JS/overflow. Bundle servido coincide con el sibling actualizado
externamente, SHA06a39589; no se atribuye ese cambio a D225.19449 queda protegida.

## ✅ Protocolos dinámicos en dev/test (D224), 2026-10-04

Los paquetes locales pueden añadir tipos con derive de Jason.Encoder después
de compilar; dev/test ya no consolidan su tabla de despacho. Producción
conserva consolidación y dependencias Hex. Regresión roja por encoder ignorado,
verde en ambos grafos; probe dev sin arrancar app comprueba tipo nuevo y
Snapshot real de exAgent. El aviso antiguo persistía en el manifiesto del
paquete: recompilación dev de sus94 archivos lo elimina sin silenciarlo.
Dev133/test140/prod Hex133 forzados limpios; gates completos2860/3 y2850/3,
secuenciales. Esto verifica iteración local, no cualifica otra partida live
ni cierra R16 o beta.19447/52 y las demás mesas protegidas siguen íntegras.

## 🟡 Causa de cortes conservada — exAgent local (D223), 2026-10-04

Una respuesta incompleta de6–8KiB cabía en su límite pero, duplicada dentro
de RequestError, excedía el control4KiB y ocultaba length/content_filter.
El sibling sólo omite esa copia, con marker explícito sin parts/usage;
pending_response mantiene el diagnóstico fuera de historia ejecutable.
Copias pequeñas, control arbitrario/límites y contabilidad permanecen.
Cinco casos nuevos del paquete: rojo39/42 y26/27 por tamaño del negativo,
verde ampliado102 en11,8 s y58 runtime/Session/persistencia en0,6 s aparte.
Los102 conservan diagnósticos existentes de peer cerrado/owner death.
Compile propio test130 forzado con warnings-as-errors limpio; no FULL nuevo
del framework ni cualificación de proveedor. Dragonex23 en3,8 s acredita
retirada de inventario pagada una vez durante el retry del mismo turno,
fact de cierre una vez y texto privado ausente de history/eventos.
Gates completos nuevos2859/3 local y2849/3 Hex, limpios y secuenciales.
Producción sigue usando Hex publicado.19447/52 conserva la entrega fallida;
no hay corrección live acreditada, nueva publicación, bump o commit.
Paquete activado después en VM nueva;19448 entrega objeto y registra cierre,
pero sin reproducir la causa de retención. Esa partida acredita el recorrido
de entrega, no el recovery live del error6300/4096 de19447.
R16, fallback sin resolución, prosa repetida y beta permanecen abiertos.

## 🟡 Narración estructurada — integración offline verificada (D222), 2026-10-04

Activada en una VM web nueva con DeepSeek4.1/Decart estricto.19447/22 en27,572 s
registra al bandido/cuatro iniciativas; Vex falla y recibe6, quedando PG12/7/4.
Ataque22→37 en21,197 s acredita espada larga humana, daño4 una vez y voz fuente;
Lyra gasta una casilla en magic missile14, bandido0/cierre de combate.
Recogida37→45 en10,034 s añade campanilla×1 sin cambiar PG/slots/reloj0.
Sin retries de proveedor ni razonamiento visible en estas narraciones revisadas;
no es una garantía semántica general. Se repite prosa intermedia/final del DM,
incluida una copia exacta35/36. Entrega45→52 en9,532 s falla por retención de
error6300/4096; objeto sigue en Thane, sin cierre ni checkpoint recuperable.
El fallback devuelve el turno humano sin resolver la entrega: no contar como
éxito. Restart UI/reload1440/375 conserva52/todas las narraciones,47 estilos y
mesas/héroe previos; bundle sibling, cero JS/overflow.19447/52 queda protegida.
D223 corrige una reproducción general de pérdida de causa por copia parcial;
la causa original de esta entrega no se conservó y no se infiere como prueba.

Narration define el campo público text mediante un embedded_schema de Ecto;
Events conserva Text libre en la continuación privada, sin publicarlo, y
Contract retiene sus deltas cuando se usa ese output. La publicación
explícita exige final_result aislado en este run, validación coincidente y
ToolReturn nativo emparejado. Rechaza herramientas omitidas junto al cierre,
truncación/filtrado, esperas y testimonios sin comprobante, contexto ausente,
cancelación y texto vacío tras Text.scrub. Conserva partes/metadatos nativos,
historia anterior y voz humana original; no ejecuta tools omitidas ni resuelve reglas.

Quince casos deterministas prueban el loop y Server reales, incluido un
control positivo del streaming v2. Otro verifica el adaptador ReqLLM stock:
retry conserva texto nativo privado, routing estricto y envelope de output.
No es un detector semántico de razonamiento dentro del campo text.
DM/PCAgent y Beats ya usan el output oficial por defecto, sin excepción por
modelo o grafo. narrate publica declaraciones intermedias explícitas; un
cierre rechazado recibe una corrección acotada y después pausa el mismo
turno, incluso sin herramientas previas. Checkpoints conservan voz humana
y efectos pagados en retry/restart; los presupuestos sobreviven a backoff.
Truncación/filtrado no completan; el retry de tokens conserva la prosa válida
ya publicada. Game guarda narración y comprobante en una transacción SQL
antes de Session/PubSub, incluido un cierre sin tools pendiente de revisión.

Diecinueve casos nuevos de Game prueban DM/PC/humano, herramientas omitidas,
ataque sin repetir RNG, cinco flags, espera, backoff, pausa y reinicios antes
del acuse/finalización. Rechazo real de Postgres revierte texto/comprobante;
retry publica una vez. Un cierre inválido o truncado después de una pausa
manual no lanza otro retry de Game ni reanuda la mesa. Migración explícita de
109 archivos anteriores, con
oráculos de reglas/recursos/fuente conservados y sin convertir respuestas
arbitrarias. 271 focales locales en40,0 s/269 Hex en19,5 s, seed0/max_cases48,
sin warnings/errores/desconexiones. Después,9 casos adicionales por grafo
en2,1/1,2 s verifican espera con magia, destinatario PNJ, observaciones e
iniciativa rechazada por SQL; mantienen fuente/dados/recursos y recuperación
desde el cierre guardado. Otros30 por grafo en8,2/3,3 s verifican voz y
ritmo de PCs, memoria de tiradas, agencia y actualización de escena.
Más tandas verificadas local/Hex:25/23 casos de PNJ/escena y retry ReqLLM
en6,5/2,5 s;55/55 de efectos/persistencia/ciclo de vida en8,0/4,1 s;
68/68 de mesa web/reacciones/progresión en11,5/8,8 s;13/13 de hechos/
antibucle en1,1/0,5 s;17/17 de iniciativa/relevo en1,8/1,0 s;21/21
del bucle de TurnMaster en2,7/1,5 s;3/3 de lobby/ficha móvil en1,4/1,1 s.
Los oráculos de reglas permanecen.
Las pruebas web arrancan narradores válidos explícitos; los previews
inyectados solo comprueban el render legado. Un caso de relevo ahora exige
la respuesta DM posterior a la acción, en vez de aceptar el relevo inicial;
conserva el turno humano y no produce el fallo de script agotado que ocultaba.
Compile test forzado140 archivos y prod Hex133 con warnings-as-errors
limpios. Gates de integración D222 completos2858/3 local y2849/3 Hex, secuenciales,
seed0/max_cases48, en105,3/63,8 s, sin warnings/errores/desconexiones.
R16 y una partida nueva siguen pendientes. AC-31.3d permanece abierto;
19446/42 conserva el fallo.
Conversaciones, equidad, inventario, memoria/visibilidad y reinicios de
efectos/cierre de combate mantienen sus oráculos. ReqLLM stock verifica
tres peticiones: cierre prematuro rechazado, testimonio guardado y output
validado, con Decart/none estricto y tool_choice required en todas. Game
reconstruye el retry desde historia pública/recibos; no importa el cierre
rechazado. El Text nativo permanece intacto dentro de su run privado.
No hay prueba live
de la solución ni mejora de latencia acreditada. Beta sigue abierta.

La base anterior tuvo55 focales locales/54 Hex en5,6/3,0 s y gates2839/3 y2830/3.
Compiles propios forzados dev/prod: 132 archivos, warnings-as-errors limpios;
formato/diff limpios. SQL y readback web 1440/375 conservan 19446/42, las
mesas/héroe protegidos, 47 estilos y todas las narraciones. Bundle sibling,
cero errores JS/overflow; no se lanza otro beat ni se borra la reproducción.
Readback SQL posterior a la integración conserva originales,19443–19446,
47 estilos, bundle sibling y adaptador ReqLLM stock exactos, sin abrir el
navegador ni activar beats. La VM web nueva acredita los recorridos parciales
registrados arriba; la entrega fallida y R16 impiden cerrar el AC.
R16/NFR-5 quedan en revisión: los deltas libres están retenidos; la UI sigue
recibiendo prosa validada, dados y etapas. No se certifica streaming token a
token de campos estructurados con esta implementación. El contrato público
de Model.request_stream actual emite deltas de texto/pensamiento y respuesta
terminal; el adaptador ReqLLM acumula las calls y entrega sus argumentos al
final. Falta un camino público de preview estructurado verificado.

## ✅ Entregado — declaración humana propia durante la resolución (D221), 2026-10-04

La integración D222 conserva también el Text nativo en la continuación
privada; sigue publicando solo la voz humana fuente.
El resolutor general conserva sus herramientas, pero deja de escribir la voz
del jugador. Beats lee la acción pública del mismo game/actor/turn_id; Events
retira solo Text de la respuesta actual, conserva partes nativas/recibos y
publica la declaración literal al completar. No hay preview generado del
humano. History etiqueta esa voz como intención, sin abreviarla ni confirmar
resultados. Entrada humana conserva palabras/UTF-8; texto del modelo sigue
con Text.scrub. Preguntas/esperas con bypass literal y PCs IA/autoplay/DM
conservan sus caminos. Un checkpoint humano interrumpido termina el turno
original antes de consumir otra intención; fallo definitivo avisa como sistema,
sin gesto inventado ni comprobante de finalización.

Quince nuevos: Events7, History2 y Game6; rojo0/10 y fallo definitivo5/6.
93 focales locales/Hex14,1/6,5 s. Ataque, retry503, restart después de daño,
recogida, autoplay, visibilidad/turno exacto y acción fuera del contexto400;
dados/stock/PG/reloj/SQL íntegros. Cinco fixtures anteriores pasan a exigir
voz literal y a rechazar prosa inventada, conservando sus oráculos de reglas.
Gates finales2823/3 y2815/3; compiles propios dev/prod forzados, formato/diff
limpios. AC-31.3c entregado; fidelidad del DM y beta permanecen abiertas.

## 🟡 Playtest — campanilla, voz corregida y nuevos límites del DM, 2026-10-04

19445/53 conserva la reproducción anterior: primer ataque humano sin dados
propios antes de registrar enemigo/iniciativa; segundo golpe sí usa espada
larga, daño11 y bandido0. Recogida/entrega añaden y retiran gear×1, guardan
cierre y conservan Thane8/otros PG/slots/reloj0. Reinicio UI/reload1440/375
íntegros. El narrador humano inventa palabras en41 y matiza la entrega en48;
no se reescriben esos eventos.

Nueva19446 con DeepSeek4.1/Decart estricto: creación6/23,734 s publica
razonamiento del DM como texto público y aún no registra al bandido.6→27 en
50,641 s/tres retries de argumentos (dos DM, uno TM) publica la declaración
humana exacta, sin dados propios; DM registra ficha/cuatro iniciativas y Vex
causa11 con arco corto, bandido0/cierre automático. No contar como ataque
mecánico de Thane ni atribuir una mejora causal universal a D220/D221.
Recogida27→34/20,166 s y entrega34→42/21,661 s, sin retries: voz humana
literal, campanilla×1 entra/sale una vez y demás recursos/PG12/7/10/reloj0
exactos. Reinicio de agentes UI/reload1440/375 conservan42, todas las
narraciones y47 estilos previos; bundle sibling, cero JS/overflow, mesas/héroe
protegidos exactos. El DM sigue añadiendo gestos del PC y dice encargo cumplido
sin fact de cierre. Razonamiento publicado, atribución/registro de hechos,
formato de tools y latencia continúan abiertos. Esta mesa no acredita beta.

## ✅ Entregado — World vigente durante la continuación (D220), 2026-10-04

El resumen inicial podía seguir anunciando objetivos vivos después del golpe
mortal. Desde la segunda petición del mismo beat DM/PC, AgentInstructions lee
Session y proyecta un Brief actual con tipos reales de participantes. Si el
motor ya ve combate terminado, recuerda ausencia de enemigos vivos/presentes,
sin adelantar cierre. Una foto temporal sustituye a la anterior; canonical,
recibos, prosa pública, reglas y World se conservan. Cinco nuevos, rojo2/5,
17 focales locales/Hex1,1 s; humano/Vex ven PG0 tras un golpe, dados exactos
(incluido furtivo), PCs/reloj/SQL intactos, stock actualizado sin acumulación.
Una lectura por petición posterior, sin SQL/modelo adicional. AC-31.3b acredita
contexto entregado; fidelidad semántica/latencia universal y beta abiertas.
Gates finales2808/3 y2800/3, seis avisos deliberados sin errores/desconexiones;
compiles propios dev/prod forzados limpios. Readback109 conserva todas las
narraciones y recursos a1440/375; 47 estilos previos exactos y bundle sibling.
Después, aclaración Ada109→116 en12,262 s/cero retries: voz humana literal y
testimonio atribuido con fuente/duda/registro606 s. Solo facts cambia; encargo,
PG4/reloj606/stock/slots exactos. Reinicio de agentes UI y reload conservan116.
Es una aclaración nueva, no recuperación de la primera consulta fallida ni
confirmación objetiva del avistamiento. No atribuir causalidad de latencia.

## ✅ Entregado — rechazos de control con una corrección posible (D219), 2026-10-04

La guarda antes pedía usar dm como atacante incluso cuando faltaba una ficha.
Ahora distingue desconocido/ausente/controlador: nombre canónico y registro
DM para criatura nueva, conservar ficha fuera de escena y nombres controlados
disponibles. El PC mantiene corrección hacia sí mismo. controlled_by?/permisos,
World/RNG/turnos no cambian. Cinco nuevos, rojo1/5;29 focales locales1,8 s/
Hex0,9 s. Game/TestModel corrige rechazo, registra skeleton y tira dos
iniciativas; PG/reloj/SQL exactos. AC-22.4 verifica feedback, no obediencia universal.
Gates finales2803/3 y2795/3, seis avisos deliberados y sin errores/desconexiones;
compiles propios dev/prod, formato y diff limpios.

## ✅ Entregado — feedback del último rechazo de argumentos (D218), 2026-10-04

PendingRetry conserva solo la causa req_llm invalid_tool_arguments. La siguiente
petición recibe una guía estática de schema/contenedor/tipos y de conservar
recibos. Temporal, única en request y ausente de canonical/history/events;
body privado no se entrega. DM/PC/TM, cuatro nuevos rojo1/4 y43 focales por
grafo. TM añade AgentInstructions, sin Events; reglas/schema/envelope/routing/
presupuestos/backoff intactos. Gates2798/3 y2790/3 sin errores/desconexiones,
seis avisos deliberados; compiles propios dev/prod limpios. AC-35.5 entregado.
Reinicio UI19444/37 conserva World/historia.37→44 pasa del rechazo de formato
al error semántico de actor; un retry, sin dados/gasto y prosa43 conservada.
No es recuperación completa, causalidad de latencia ni garantía de formato.

## ✅ Entregado — impedir self-handoff DM ordinario (D217), 2026-10-04

Tras respuesta ordinaria DM en exploración, pass_to_dm/give_turn_to(dm) ceden
a una persona manual elegible. Prioridad por turnos, también sin compañeros IA;
conversación/intents/combate/mini/reacción/re-eval/autoplay conservan caminos.
Tres nuevos, rojo8/11;32 focales locales3,6 s/Hex1,5 s. Ambas decisiones con
cero/dos compañeros impiden segundo beat, viaje/retirada no declarados y
conservan farol×1/reloj/escena/SQL. Gates2794/3/99,1 s/seed987248 y Hex2786/3/
61,4 s/seed715486, max_cases48, seis avisos deliberados y sin errores/desconexiones;
compiles propios dev/prod/formato/diff limpios. AC-30.7c entregado, beta activa.

## 🟡 Playtest — el farol del vado: encargo cerrado, fidelidad abierta, 2026-10-04

Mesa nueva19444 creada por UI7. Pregunta7→15 falla tras tres retries de
argumentos; voz literal/World conservados y Ada sin respuesta. Trayecto15→23
registra300 s una vez, un retry. Apertura23→30 anuncia esqueleto sin ficha.
Ataque30→37 falla sin dados/gasto;37→44 tras D218 muestra rechazo semántico
de control y prosa intermedia de un ataque sin dados. No contar esos golpes
como resultados.44→67 tras D219 registra skeleton13PG y cuatro iniciativas:
Vex21, Lyra19, Thane11, esqueleto9. Vex/Lyra fallan una vez y Thane espera;
reloj300/recursos PCs intactos.41,129 s, un retry y handoff_failed; el lote
real ahora incluye cuatro, sin recuperación retrospectiva. No certifica toda
concurrencia/adherencia.

Combate67→88 en45,644 s/un retry: Thane causa10, esqueleto13→3; el monstruo
usa su turno/arco corto, daño8 y Thane12→4. Cambio de ronda1→2 suma6 s;
Vex causa12 y esqueleto3→0, cierre automático. Recogida88→95 guarda
farol de señales de Ada gear×1, sin viaje; regreso95→102 suma300 s exactos
y conserva stock; entrega explícita102→109 retira esa unidad y establece
encargo cerrado.30,964/21,262/34,548 s, cero retries en esos tres pasos.
Reloj606, Thane4, slots/inventario restante exactos, sin curación ni regalo.

Reinicio de agentes por ajustes UI con el mismo modelo y reload1440/375
conservan SQL/World/historial109 exactos, incluidas todas las narraciones.
Sin errores JS ni overflow; bundle dic_ex igual al sibling.19443/107 conserva
el defecto previo; mesas/héroe protegidos exactos, sin deploy. La primera
consulta a Ada sigue sin respuesta registrada. La entrega añade un recuerdo
de Ada sin record_npc_statement; prosa de hacha/veneno no coincide con armas
canónicas y Vex pide rematar después del golpe mortal. El narrador humano
embellece la voz/gestos. Mantener fidelidad, registro de testimonios,
formato de tools y fluidez abiertos; este cierre no declara beta lista.
La aclaración posterior109→116 registra la fuente y sus límites sin cambiar
recursos/encargo; no reescribe la entrega ni la primera pregunta fallida.

### Reproducción anterior a D217

D216 recupera 68→69 por el motor: esqueleto al final y una nota visible, sin
dados ni cambios de turno/PG/recursos/reloj. El combate 69→85 tarda47,327 s,
sin retries: Thane falla d20 2+5 contra CA13; Lyra obtiene crítico natural20,
firebolt 9+3=12, esqueleto4→0 y cierre automático. PCs intactos, reloj300.

Recoger solamente el farol 85→107 tarda72,258 s con un retry inválido. Después
de recogerlo, seis beats DM seguidos adelantan viaje300 s, entrega/retirada
del inventario y fact de encargo cerrado sin una declaración humana para eso.
La mesa107 queda pausada en exploración con Thane, reloj600; conservar esta
reproducción y no contar el encargo como recorrido correcto. La prueba original
pausa al devolver el turno; un segundo intento de pausa llega después y su
locator expira sin mutar. Revisar pass_to_dm/give_turn_to(dm) tras respuesta
ordinaria antes de otra mesa real. Mara944, 19439/9 y héroe5164 exactos.

## ✅ Entregado — recuperación de orden incompleto guardado (D216), 2026-10-04

Game incorpora al final los hostiles vivos/presentes omitidos, como refuerzos
por nombre. Preserva actor/owner, slots, turnos gastados y todos los recursos;
no inventa la iniciativa histórica. World y nota atómicos antes de Session;
SQL fallido pausa y retry idempotente. Busy/checkpoint/pending_turn conservan
su protocolo. Seis nuevos, rojo0/6;36 focales locales4,3 s/Hex2,2 s. Resume y
reinicio running, rollback real, ausencia de petición/dado, Codec y guards.
Chrome1440/375 recupera68→69 en0,080 s; solo order/log cambian, nota visible,
prefijo/reloj300/recursos exactos, sin JS/overflow y bundle dic_ex igual al sibling.
Gates2791/3 y2783/3, seis avisos deliberados y sin errores/desconexiones;
compiles propios dev/prod limpios. AC-29.11 entregado; beta y objetivo activos.

### Reproducción anterior a D216

La mesa 19443 llega a 68, pausada en combate con Thane. El esqueleto tiene
4/13 PG tras un ataque de Vex: d20 15 + 5 contra CA 13, daño 5 + 1 + 3 = 9.
Reloj 300 s, PG/slots/inventario de los PCs intactos y testimonio de Ada
conservado. El orden guardado solo contiene Vex/Thane/Lyra: falta el esqueleto.
Se preserva esa reproducción; D215 protege futuros commits y no reescribe
esta partida. Antes de continuar la pelea, recuperar el caso por el motor
y verificar aparición/iniciativa juntas en una mesa real. Después: combate,
recogida cuantificada, regreso de cinco minutos y devolución del farol.

La apertura 46→68 tarda 28,957 s: un handoff_failed y dos retries de argumentos
inválidos (DM/Vex) recuperados. La guía de envelope D213 sigue siendo evidencia
acotada. El narrador humano añade una pregunta no declarada y detalles físicos;
la puerta entreabierta aparece primero en una opinión PC sin confirmación.
Brevedad, fidelidad y agencia continúan abiertas. Chrome 1440/375 sin errores
JS ni overflow horizontal; capturas inspeccionadas. Mara 944, mesa 19439/9
y héroe 5164 exactos; sin publicar/deploy. Beta y objetivo siguen activos.

## ✅ Entregado — iniciativa preparada contra el roster vigente (D215), 2026-10-04

El caso anterior se reproduce con APIs públicas World/Actions, roller fijo,
sin app/DB/modelo: preparar iniciativa de tres PCs, añadir esqueleto y aplicar
el callback acepta un orden sin él. Una preparación fresca sí incluye los
cuatro. ExAgent ejecuta tools del lote concurrentemente; el single-writer
serializa commits, pero el cálculo puede leer un World anterior.

Actions guarda nombres/DEX de combatientes presentes y conscientes. El cambio
compara esa foto al aplicarse: altas, salidas, caída o DEX diferente rechazan
la iniciativa con una indicación de volver a pedirla. Cambios de escena no
invalidan dados válidos. No añade dados al commit, cambia World/Codec/DB ni
repara retrospectivamente órdenes guardadas. World.begin_combat conserva
su contrato general. Tres nuevos: rojo 1/3; 53 focales locales/Hex verdes.
AC-29.10 acredita el guard del commit; replay real y estado heredado pendientes.
Gates finales 2785/3 y Hex 2777/3, seis avisos deliberados y sin errores de
proceso/desconexiones; compiles propios dev/prod, formato y diff limpios.
Reload readonly 1440/375 conserva toda la apertura y el estado 68 exactamente,
sin errores JS/overflow; bundle dic_ex igual al sibling y 47 estilos previos
intactos. Evidencia privada continuation-initiative-final-verification.json.

## ✅ Entregado — guía tras prosa intermedia del mismo turno (D214), 2026-10-04

Plan 28→38 en 12,613 s: voces Lyra/Vex, humano literal y sin cierre DM;
World exacto. Trayecto 38→46 en 32,863 s: 300 s registrados una vez,
Thane fuera, sin combate/dados/gasto; solo log/scene/reloj cambian.
Los eventos DM 44/45 repiten casi el mismo párrafo antes/después de una tool.

AgentInstructions añade una guía solo si existe prosa pública intermedia,
complete:false, no vacía, del mismo game/actor/turn_id. Consulta EXISTS sin
traer texto ni secretos. Tras tools recuerda que la prosa ya está publicada,
pide una consecuencia nueva y conservar sus resultados. Solo cambia la
proyección de petición: todos los eventos, recibos, historia canónica y reglas
permanecen. Tres nuevos, rojo 0/3; 27 focales locales 3,5 s/Hex 2,3 s verdes.
Cue única tras dos tools; negativos de scope/metadata, historia y World intactos.
Gates intermedios 2782/3 y Hex 2774/3 (antes de D215). AC-31.3a acredita
entrega, no obediencia o novedad semántica universal. En apertura 46→68 la
continuación DM 58/62 no repite el párrafo, con otros límites descritos arriba.

## ✅ Entregado — pregunta a PNJ por nombre y formato de tools v2 (D213), 2026-10-04

La consulta a Ada quedaba fuera del detector de roles; «¿Sabes si…?» tampoco
entraba en habla informativa. Text admite un nombre propio único de 3–40
caracteres, inicial mayúscula y roster PC no vacío para excluir identidad/
primer nombre PC. Sin ese contexto, nombres largos/descripciones/minúsculas/
planes/consecuencias conservan resolución normal. Cita/espera completas, hasta
tres preguntas, scrub y comprobante manual siguen con sus guardas. Conjurar
después de preguntar sigue cobrando slot/dado; no cambia World/Codec/DB.
Cuatro nuevos: rojo 9/12, 50 focalizados por grafo verdes y restart con habla
única/memoria atribuida. Mesa 13→21 en 28,809 s ya conserva la voz exacta, pero
todavía agota tres reintentos inválidos y no responde Ada.

Dos requests frescos con APIs públicas stock, buffered/stream, devuelven
speaker/statement planos, sin el envelope arguments de v2. No son capturas
de los ocho rechazos anteriores. El sibling exAgent añade una guía system
una vez al Context backend cuando hay tools cualificadas; caller/history/
schema/codec/validación se mantienen. No unwrap, reparación ni fake caps.
Rojo14/15; un fixture de history cambia índice absoluto por assistant único,
conservando su comprobación de envelope. 131 casos del adaptador pasan en 14,5 s;
logs de cierre/cancel/timeout negativos esperados. FULL 2235 anterior no se
repite ni se presenta como evidencia de este delta. Tooling 1.20.0 falló por
Hex; selección explícita 1.20.3/OTP 29.0.5 funciona sin cambios globales.

Consulta idéntica 21→28 en 11,564 s con DeepSeek 4.1/Decart: voz exacta, respuesta
completa Ada, un testimonio con procedencia/duda y cero retries inválidos.
Solo cambia facts; reloj 0/recursos/inventario/prefijo/otra mesa/hero exactos.
Chrome 1440/375 sin errores JS ni overflow horizontal, capturas inspeccionadas. Mesa 28
pausada. Gates locales 2779/3 después de guía y Hex 2771/3 con fuentes propias
iguales, seis avisos deliberados y sin errores/desconexiones; compile propio
dev/prod/formato/diff verificados. La guía no garantiza obediencia, verdad,
brevedad o SLA. AC-31.2h4 entrega este alcance. Beta y objetivo activos, sin
publicar/deploy. Seguir decisiones de PCs, trayecto/combate/regreso y memoria;
Mara 944 y la mesa 19439/9 permanecen intactas.

## ✅ Entregado — instrucciones completas y errores recuperables al crear (D212), 2026-10-04

Crear una aventura con476 caracteres de estilo DM produjo SQL22001 y cerró
el asistente; no insertó partida. La migración20261004000000 cambia dm_style
a text, sin truncar instrucciones. Título conserva varchar255 y se valida
por puntos de código antes de insertar y al avanzar desde detalles. Error
asociado al campo/role=alert; corregir/volver conserva escena/estilo/héroe/
compañeros, también tras cambio final forjado. No cambian World/Codec.

Cuatro regresiones nuevas y estilo largo en el test del request DM/restart.
Rojo causal2/7 con esquema antiguo y validación desactivada;30 focalizados
locales/Hex verdes. Los primeros ensayos tuvieron dos fallos de fixture
(variable de redirect y selector CSS con saltos de línea); no prueban el bug.
Gates completos2775/3/97,2s y2767/3/59,7s, semillas de cabecera, seis avisos
deliberados y sin errores/desconexiones. Compile propio dev/prod y formato/
diff limpios. Detector de interfaz sin hallazgos en New.

Migración aplicada en test/dev:47 estilos existentes y mesas19425/944,
19439/9/combate, hero5164 exactos. Sin deploy ni migración de producción;
rollback a varchar255 falla si ya hay estilos largos y nunca debe truncarlos.
Chrome1440/375 verifica alerta, corrección, teclado y retorno entre pasos,
sin JS/overflow; capturas inspeccionadas. Nueva mesa19443 con476 caracteres,
Thane humano/Lyra/Vex IA/DM y3D, pausada al abrir en6. La primera consulta
a Ada6→13/31,821s conserva World/recursos/reloj, pero reformula al humano y
agota tres reintentos de argumentos inválidos antes del mensaje de reserva.
No respondió Ada ni dejó memoria: beta activa; revisar nombre PNJ y fallo
del proveedor antes de viajar. Las mesas anteriores siguen intactas.

## ✅ Entregado — preguntas múltiples con voz literal y cierre acreditado (D211), 2026-10-04

La pregunta doble921→934 quedaba fuera del detector de una sola interrogativa:
reformulaba la voz humana y añadía un cierre DM. Text admite ahora de una a
tres preguntas informativas/opinión consecutivas bajo el mismo vocativo PC.
Verifica cada pregunta y toda la espera pasiva; no trunca acciones intermedias/
exteriores, peticiones, cambio de voz, espera cronometrada o cuarto interrogante.
Una cláusula/vocativo adicional en cualquier pregunta conserva DM aunque el
habla sea literal. Scrub, cap800, manual/exploración/identidad/cola exacta,
comprobante de acción, huella World, eventos/intenciones y consecuencias
mantienen sus guardas; sin nuevos World/Codec/DB o permisos de tools.

Seis casos nuevos; rojo20/26 y64 focalizados locales/Hex verdes. Primer25/26
incluye apertura DM en el contador del test: se corrige el límite de eventos
del fixture, preservando el prefijo. Game verifica entrega efectiva a ambos
PCs y voz anterior anclada de Lyra para Vex, restart sin repetir humano y
magia mixta con slot/dado únicos. Dado sin efecto World o nueva pregunta PNJ
del respondedor conservan DM. Gates completos secuenciales2771/3/96,8s y
2763/3/57,8s, semillas/max_cases de cabecera, seis avisos deliberados y sin
errores/desconexiones. Compile propio dev/prod forzado/formato/diff limpios.

Consulta idéntica934→944/4,061s con DeepSeek4.1/Decart publica palabras exactas
de Mara, dos respuestas PC y retorno sin turno/narración DM. World/15 facts/
reloj/recursos/inventario/otra mesa/hero exactos. QA readonly1440/375/reload/
SQL/PNG sin JS/overflow, capturas inspeccionadas y assets iguales al sibling.
Lyra74/Vex47 palabras; el acuerdo de Vex añade criterio de cautela, pero
brevedad/fuentes generales siguen abiertas. No se atribuye una mejora causal
de semántica o SLA por este par de consultas con historial distinto.
AC-32.1c entrega el flujo acotado. Mesa944 pausada, beta y objetivo activos,
sin publicar/deploy. Continuar nuevos pasos de campaña/preguntas distintas,
memoria útil, agencia y coste, además de voz/brevedad.

## ✅ Entregado — orden retenido de testimonios y aclaraciones (D210), 2026-10-04

La comparación inicial y la aclaración del zagal tienen el mismo reloj41535.
Brief marca ahora la última entrada retenida de cada fuente con varias
versiones, por posición y sin interpretar el contenido. Agrupa solo el nombre
completo con NFC/espacios/case: apodos, roles y acentos distintos permanecen
separados. Cada cadena literal aparece una vez en su orden; nada se elimina,
confirma o pasa a nuevo World/Codec/DB. El orden no fecha el suceso relatado.
La guía conserva una aclaración posterior sobre fuente/límites al usar ese
detalle; no supone que toda entrada posterior invalide lo anterior o sea verdad.
Repetir memoria retenida no la mueve ni renueva el reloj; legacy sigue sin fecha.

Rojo5/12, cinco casos nuevos y46 focalizados en cada grafo. Game entrega
ambas versiones después del archivo, compacción con resumen falso y restart
entre Lyra y Vex, sin repetir primera voz/humano ni gastar recursos. Gates
finales2765/3/95,9s y2757/3/58,6s, en secuencia con semillas/max_cases de la
cabecera, seis avisos deliberados y sin errores/desconexiones. Compile propio
dev/prod forzado con warnings-as-errors y formato/diff limpios.

Consulta nueva921→934/15,905s con DeepSeek4.1/Decart mantiene World/15 facts/
reloj/recursos/inventario/otra mesa/hero exactos. Vex conserva el límite de
visión cercana, pero Lyra86/Vex66 palabras siguen extensas y con matices de
fuente abiertos. La pregunta doble queda fuera de la ruta literal PC de una
sola interrogativa: reaparecen reformulación humana y cierre DM. Mesa934
pausada; reload1440/375 muestra respuestas completas sin JS/overflow,
capturas inspeccionadas y assets iguales al sibling. AC-25.10 entrega orden/
procedencia, no resolución semántica de contradicciones ni SLA. Beta y
objetivo activos, sin publicar/deploy. Siguiente caso: varias preguntas
informativas a los mismos compañeros con habla literal/cierre acotados,
además de voz/brevedad y memoria de otras preguntas.

## ✅ Entregado — diálogo directo y contexto de la pregunta vigente (D209), 2026-10-04

La guía del segundo compañero podía perder la intervención anterior entre la
crónica y un resumen. Game pasa los400 eventos que ya lee a PCAgent: con el
recibo de acción existente, la guía final proyecta únicamente intervenciones
públicas completas de destinatarios anteriores tras esa misma pregunta.
Acción/fuente/texto deben coincidir. Quitar a alguien de pending no inventa
una respuesta: borradores, privados, faltas de voz o de ancla quedan fuera.
Cada intervención se sanitiza y se omite entera si supera1800 caracteres,
sin cortar una duda final. Voz atribuida, no hechos ni nuevas instrucciones;
sin DB/World/Codec nuevos. La aridad anterior sigue disponible.

Un primer ensayo901→911/5,594s conserva World, pero repite datos y gestos.
El formato de novela del prefijo contradice la respuesta factual breve. La
guía final ahora pide diálogo directo,1–2 frases cortas sin narrador/gestos,
y hace condicional la propuesta o cómo investigar. Clase/trasfondo, acuerdo,
dudas, agencia y efectos siguen con sus contratos. Rojo Game1/3 y formato5/6;
seis casos nuevos y27 focalizados por grafo verifican entrega, fuentes,
sanitización/límites, restart sobre segundo compañero y compacción adversa.
Gates finales2760/3/2752/3, formato/compiles propios dev/prod limpios.

Consulta911→921/7,166s con DeepSeek4.1/Decart devuelve la palabra al humano,
sin gestos narrados en ambas respuestas. Lyra76/Vex61 palabras: aún recapitulan
y dejan matices de fuente por afinar. No se certifican brevedad/fidelidad
generales ni una mejora causal de latencia: el historial de preguntas repetidas
cambió. Dos consultas conservan exactamente World/15 facts/reloj/recursos/
inventario/otra mesa/hero. Reload1440/375 muestra respuestas completas sin JS/
overflow; capturas inspeccionadas y assets iguales al sibling. Mesa921 pausada.
AC-32.4c entrega el contexto/formato, no un verificador semántico.

El primer gate local2759/2760 detecta40P01: dos VMs de tests comparten DB y
solicitan constraints temporales de rollback. El log Postgres confirma ambas
sentencias. Caso aislado8/8 y gates finales separados con las mismas semillas
pasan sin cambiar cobertura/añadir retry al producto. AGENTS/protocolo exigen
secuencia o bases distintas por grafo. Beta y objetivo activos, sin publicar/
deploy; pendientes: aclaraciones posteriores frente a versiones anteriores,
brevedad/repetición y memoria de otras preguntas.

## ✅ Entregado — ofrecer el modo de dados disponible (D208), 2026-10-04

Hex publicado no ofrece caras autoritativas en3D, pero el creador y la mesa
permitían elegir y anunciaban3D mientras montaban un hook2D con ID3D. Ahora
creador, controles, snapshot, montaje y destino del evento resuelven la misma
capacidad real del paquete instalado. Sin ella,2D queda seleccionado y3D
aparece deshabilitado con «No disponible»; la mesa muestra «Dados2D» como dato.
Con ella, el botón anuncia modo actual/destino y permite cambiar, salvo durante
la animación. Elección por vista sobrevive actualizaciones; una preferencia
antigua guardada como3D se presenta en2D sin reescribirla ni tocar World.

Tres regresiones nuevas: rojo local2/3 y Hex0/3, green de flujo real y evento
autoritativo dirigido al mismo ID del hook. El fixture anterior del wizard
asumía3D en todo grafo; se adapta a capacidad instalada conservando sus
assertions de selección y compañeros ocupados. Gates2754/3 y2746/3 limpios;
26 focalizados finales pasan en cada grafo tras ajustar el texto del control.
Chrome local/Hex a1440/375 confirma teclado, modo/hook, total19/DC15 y guardia
de animación, sin JS/overflow/tools/LLM. Capturas inspeccionadas. Lectura real
4035 de creador/mesa conserva SQL19425/901/15 facts/otra mesa/hero íntegros;
fixtures temporales cerrados y assets iguales al sibling. Formato y compiles
propios dev/prod limpios. AC-14.9 entregado; sin publicar/deploy.

La disponibilidad describe el paquete, no garantiza WebGL en cada navegador:
un fallo posterior de3D conserva fallback2D de D207. El detector de diseño
señala seis tratamientos preexistentes del estilo pixel/animaciones ajenos a
este selector; no se declara una auditoría visual general limpia. Beta activa;
fidelidad/brevedad de PCs y otras respuestas PNJ siguen abiertas.

## ✅ Entregado — liberar la escena 3D si falla su constructor (D207), 2026-10-04

El fallback2D funcionaba, pero una excepción después de reservar WebGL/Rapier
impedía asignar la escena al hook y dejaba sus recursos vivos. Rojo9/12 Node
y Chrome real confirman esa fuga. DiceScene libera los recursos que ya posee
antes de propagar el error de inicialización; dispose tolera recursos aún no
creados y sigue intentando las otras liberaciones si una falla. Cinco nuevos
controles: cuatro fases de construcción y error adicional durante limpieza.
El segundo rojo13/14 expone la interrupción de limpieza; verde14/14 final.

Bundle reconstruido y servido directamente por la misma VM. Chrome con fallos
controlados de inicialización y limpieza confirma WebGL/contexto/física/tabla
liberados una vez, error original conservado y fallback exacto18/d20 con un
solo asentado. Ruta normal3D conserva caras3/5/7/9/11/19, detiene RAF y libera
al cambiar modo; escritorio/móvil sin JS/overflow.14 tests host locales y14
Hex pasan; formato/compile propios limpios. Gates completos de referencia son
los de D206, no se repiten por un cambio JS del paquete con contrato invariable.
AC-14.8 entregado en el candidato local; producción conserva Hex publicado.

Consulta posterior a D206:19425/891→901/7,127s, Lyra/Vex recuperan el referente
y devuelven la palabra, World/15 facts/otra mesa/hero iguales. Aún repiten datos
y Vex usa «juró» donde el registro dice que contó botones: brevedad/fidelidad
general siguen abiertas. Las pruebas de dados no añaden beats/dados del motor;
mesa901 pausada y SQL íntegro. Beta activa, sin publicación o deploy.

## ✅ Entregado — aclaración PNJ confirmada antes de publicar (D206), 2026-10-04

Una aclaración citada «cuando dijiste…» exige un comprobante de
`record_npc_statement` del mismo PNJ y turno DM antes de publicar texto final
o deltas. La herramienta confirma memoria por el single-writer existente;
un duplicado retenido también confirma sin duplicar el fact o renovar su marca.
Facts previos solos no sustituyen el comprobante. Fuente distinta se rechaza;
interrupción de combate permite continuar. Sin campos nuevos en World/Codec,
extracción de prosa o reescritura de testimonios anteriores.

Nueve regresiones nuevas: rojo2/4 en el flujo original,32 focalizados locales
y19 Hex verdes. HTTP stock v2 confirma Decart/sin fallback/reasoning_effort:none
y tool_choice required hasta guardar, después elección auto por defecto.
Stream v2 no revela el borrador previo; Hex1.2 usa chat buffered y conserva
el bloqueo final. Restart entre registro y respuesta no repite pregunta/fact.
Gates2751/3 y2743/3; formato y compiles propios dev/prod limpios.

Mesa19425/884→891 retorna al humano en7,665s y añade solo un testimonio
atribuido a41535s: el zagal aclara que vio al forastero de lejos, no vio de
cerca la tela y el hilo lo conoce por lo contado por las jugadoras. Los14
registros previos, recursos, reloj, inventario, otra mesa y hero5164 se conservan.
Restart por ajustes y reload1440/375 conservan exactamente SQL; pregunta y
respuesta visibles, cero JS/overflow y assets iguales a los paquetes.
La mesa queda pausada. AC-25.9 entrega esta garantía acotada, sin comprobar
la verdad del PNJ ni cubrir toda respuesta informativa o semántica libre.
Beta/objetivo activos; MiMo/io.net local sigue pendiente del contrato stock.

## ✅ Entregado — aclaraciones literales y reintento v2 (D204/D205), 2026-10-03

La pregunta real al zagal862→869/26,149s contiene dos interrogantes y un
preámbulo citado; el detector de una sola pregunta la enviaba al narrador
humano. Añadía gestos y el DM respondía sin guardar la aclaración. Se admite
una cita completa con hasta tres preguntas informativas al mismo PNJ y un
preámbulo acotado «cuando dijiste…». Palabras literales, fuente/cola/retorno,
guardas PC, hechizo mixto y restart conservados. Tres regresiones nuevas;
rojo13/16, verde23 adyacentes. La pregunta869→877 queda literal, pero el
proveedor devuelve argumentos de tool inválidos: falla sin cambiar World.

D205 reintenta solo ese rechazo generado de ReqLLM dentro del límite existente
de tres reintentos; schema/history/continuation inválidos siguen terminales.
Dos regresiones nuevas, rojo16/18; HTTP stock demuestra que rechazar un tipo
inválido después de un hechizo y repetirlo no duplica casilla/daño/dados. El
fixture se refactoriza para quitar avisos por constantes, sin cambiar su caso.
34 focalizados finales limpios; Hex49 adyacentes. Gates2742/3 y2735/3 limpios,
formato/compile propios dev/prod correctos; build frío conserva avisos de terceros.

Consulta877→884/9,150s recupera un invalid_tool_arguments con un reintento y
contesta como PNJ. Conserva World/prefijo862/otra mesa/hero y habla humana
exacta; Chrome1440/375 sin JS/overflow, bundle igual al sibling. La aclaración
queda solo en prosa: no hay fact nuevo. AC-31.2h3/35.4 entregan ruta y recuperación,
no persistencia automática de cada respuesta. El registro original ambiguo
sigue intacto; registrar información duradera y fidelidad/voz siguen abiertos.
Beta y objetivo activos; sin despliegue o publicación.

## ✅ Entregado — parches web y clientes del servidor (D203), 2026-10-03

Dos lockfiles actualizan Phoenix1.8.15/LiveView1.2.12/Bandit1.12.5/Postgrex0.22.4/
LazyHTML0.1.13 y transitivas resueltas. Hex incorpora Mint1.11/hpax1.1/Plug1.20.3
ya presentes en local. ReqLLM1.26 y exAgent/dic_ex de cada grafo no cambian.
Ambos `mix hex.audit` pasan sin paquetes retirados o avisos conocidos; no es
certificación de seguridad general. Clientes Phoenix/LiveView se sirven desde
sus paquetes, sin CDN o build JS propio. Red0/3 de assets→green en22 focalizados
privados; instalación en raíz reproduce exactamente ambos locks de ensayo.

Root local2736/3 y Hex2730/3 pasan, seis avisos deliberados de breaker/retry y
cero errores de proceso/desconexiones. Hex imprime15 aliases no usados de dos
fixtures v2; se mueven dentro de su guarda, y2 locales/3 Hex verifican sin esos
avisos. No cambian comportamiento o assertions. Compile dev/prod forzado con
warnings-as-errors sale0 limpio; el build frío imprime avisos de terceros (xref
deprecated y Logger de dotenvy), sin avisos de Dragonex ni parches vendored.
Web reiniciada en4035 mantiene los tres roles DeepSeek4.1/Decart. Chrome1440/
721/375 conecta, cambia ajustes, monta/libera3D y recarga sin JS/overflow;
peticiones JS solo locales y bytes de los tres módulos iguales a sus paquetes.
SQLreadonly conserva19425/852/World/eventos/otra mesa/hero. AC-37.3 entregado;
beta/objetivo siguen activos.

## ✅ Entregado — lectura del resultado de dados (D202), 2026-10-03

Chrome con WebGL real reproduce tres animaciones de3,426/3,951/4,365s, todas
por encima del cierre anterior2,6s. La FSM podía borrar mano/cards antes de
recibir el asentado. Rojo9/10 acredita cierre durante rolling. Se separa un
watchdog de animación10s del hold de lectura2,6s: el callback o watchdog revela
el resultado factual, después se cierra. Tokens/fase rechazan cierres y
deadlines viejos; dismiss sigue inmediato. No cambia dados/World ni espera al
cliente para resolver reglas. Local23 y Hex23 focalizados pasan. Gate2733/3 en
93,0s, seed174475/max_cases48, seis avisos deliberados y cero errores de proceso/
desconexiones; compile dev/prod sin warnings y formato limpio. LiveView aislada
usa el componente/FSM/delegados reales: asentado3D4,188s, cierre6,972s; sin ack,
resultado visible10,436s y lectura2,802s. Total57/DC15/caras comprometidas exactos,
cero JS/tools/LLM. Fixture cerrada, sin hooks nuevos en la app. Navegación
1440/375 y SQLreadonly conserva19425/852/World/eventos/otra mesa/hero íntegros.
AC-14.7 entregado; no se certifica duración física máxima o hardware distinto.

## ✅ Entregado — dependencias locales v2 y grafo Hex (D201), 2026-10-03

Dev/test siempre usa exAgent/dic_ex hermanos; prod usa Hex/mix.hex.lock. Compose
monta ambos y Phoenix los recarga; JS/CSS se sirve del paquete cargado por la VM. Adaptadas
fronteras Session/tools/streaming/RunError/compaction. Hex1.2 necesitaba recuperar
historial compartido por chat y cargar capabilities:12/12 conversación/replay.

Smoke real: DeepSeek4.1Flash→Decart con v2 local9,5s; MiMo2.6Flash→io.net con
Hex1.2 7,9s, herramienta+texto, sin fallback. MiMo local no envía pago: stock
ReqLLM1.26 carece de reasoning.enabled:false. exAgent78/78 focalizados con el
contrato actual de routing/continuation4; anteriormente81/81 en otro subconjunto
HTTP/SSE/codec/guards. No son gates completos del paquete. Dados9/9 Node con mix,
modo3D autoritativo y fallback2D exacto,
idle/hidden/0px y liberación Rapier/GPU. Bundling pasa y errores abortan build.

Gate actualizado2731/3 en93,0s. La repetición anterior2729/2731 detectó el
nuevo contrato concurrente de routing/continuation4. Crónica ahora se importa
como memoria user en todos los modelos, sin fingir respuestas de proveedor.
Stock HTTP503/history y33 conversaciones pasan; Hex2722/3 completo más29 casos
de importación final. VM local v2/Decart, WebGL real/reload/hermano/formulario
sin JS. Revisión posterior a continuation4 conserva escritorio/móvil y ajustes;
consulta real842→852 en14,824s mantiene World, prefijo de eventos, otra mesa y
hero intactos. AC-14.6/37.2 verificados. Paquetes candidatos sin publicar;
MiMo local sigue limitado por stock. Beta/objetivo activos.

---

## ✅ Entregado — guía de criterio de compañeros (D200), 2026-10-03

Consulta real806→816/5,613 s: Lyra y Vex reciben voz/fuentes, responden sin
tools ni World nuevo y dejan decidir a Mara. Ambos proponen seguir hasta
primera aldea/granja y buscar testigos; Vex repite plan/justificación y concluye
que nadie verlo confirmaría que no llegó lejos. La propuesta necesita criterio
propio y prudencia sobre qué probaría la falta de testimonios. Se aplica
guía final de recomendación condicional con clase/trasfondo vigentes, sin forzar
desacuerdo, hechos nuevos ni planes cuando la pregunta solo pide recuerdos.
Ocho regresiones/compacción/restart y pregunta832→842/16,903s pasan: contraste
de indicios de Lyra y preguntas sin revelar pistas de Vex, World igual. Cambiaron
modelo/adaptador, no es comparación causal solo del prompt. Lyra aún mueve «lo
vi de lejos» del abrigo al hilo. Otra pregunta explícita842→852/14,824s conserva
fuente/duda y atribuye la visión lejana al forastero/abrigo, pero los PCs vuelven
a compartir casi toda la formulación. Esa observación no acredita una corrección
general de referentes o variedad de voz: ambas siguen abiertas.

Refinamiento posterior permite acuerdo breve si el compañero anterior respeta
fuente/dudas y exige corregir una contradicción. Rojo5/9→verde20 locales y20
Hex comprueba entrega, compacción, restart y World íntegro. Consulta852→862
con DeepSeek4.1/Decart tarda9,177s, conserva World/prefijo852/otra mesa/hero y
vuelve al humano. Las formulaciones difieren algo, pero repiten gran parte de
los datos y Lyra introduce «dijo de lejos»/«solo encontramos el botón». La
brevedad y fidelidad semánticas siguen pendientes: el testimonio original
«lo vi de lejos» tampoco explicita su referente. No se atribuye la latencia
al prompt ni se altera ese registro. Gate posterior2737/3 en92,1s sin errores
de proceso/desconexiones y con seis avisos deliberados; beta abierta.

## ✅ Entregado — envolturas de testimonio (D199), 2026-10-03

El testimonio real del zagal con envoltura doble se duplicaba al repetir sus
palabras sin comillas, renovando reloj/posición y expulsando memoria al cap30.
NPCStatement reconoce envolturas completas no ambiguas «…», “…” y comillas
ASCII simples/dobles, incluidas repeticiones y anidamiento compatible. Nuevos
registros eliminan solo la envoltura externa; citas internas/apóstrofos y
fuente/dudas siguen. Deduplicación textual devuelve el fact retenido verbatim,
con primera marca/posición o sin reloj legacy. No compara significados ni
mueve/repara registros antiguos. Un cambio de fuente/duda/contenido se registra
aparte; marca exterior estricta, texto de reloj dentro de cita sigue contenido.
Entrada vacía tras quitar envoltura se rechaza; límites80/800 vigentes antes
de desenvuelto, comparación legacy acotada. Guardas/World/Codec/Rules iguales.

AC-25.8 entregado: nueve nuevos, rojo corregido1/9 con fuente exacta D198
(hash probado), verde9/9 y43 focalizados1,6 s sin avisos. Game normal verifica
request DM y tres grafías conservan el fact37935; reinicio tras registro nuevo
reproduce tool envuelta y repetición sin envoltura conserva un único fact41535,
checkpoint/SQL/Codec/recursos/dados coherentes. Dos8/9 iniciales exponían
fixtures: se esperaba checkpoint de no-op y la pregunta «Sigues…» consumía
primero modelo humano. Se ajusta a registro nuevo/pregunta informativa y se
comprueba DM, sin cambiar flujo del producto para acomodar el test. Logs
iniciales y red con fixtures corregidas conservados.

Gate2709/3 en55,9 s,seed30343/max_cases48/salida0: cero errores/desconexiones/
warnings de compile, seis avisos deliberados. Formato/compile/diff correctos.
Sin beat LLM nuevo ni hooks: TestModel/Game/Postgres verifica la corrección.
SQL readonly antes/después conserva19425/806/World/eventos/catorce facts,
envoltura original del zagal/marca41535, recursos/inventarios/plazos/hero;
otra mesa World/eventos completos iguales. Navegación1440/375 conectada,
ficha/inventario por teclado/reload/modal oculto/lienzo, cero JS/overflow,
sin PNG nuevos. Evidencia privada testimony-quote-verification.json.

Alcance: formatos completos no ambiguos/texto normalizado, sin equivalencia
semántica, cambio de fuente/memoria oculta ni recuperar facts expulsados.
Grafía de citas legacy ya perdida no se reconstruye y envolturas simétricas
ambiguas se conservan. Voz/originalidad/dudas en más contexto, detalles solo
en prosa y adjudicaciones DM siguen pendientes; beta y objetivo activos.

## ✅ Entregado — fuentes de memoria (D198), 2026-10-03

19425 vuelve al molino772→779,900 s/14,314 s; muestra el hilo779→786,
9,146 s y añade solo un testimonio del zagal, marcado41535. La consulta
Lyra/Vex786→796 tarda4,575 s y conserva World, pero ambos atribuyen al grupo
haber visto la comparación con el abrigo: solo procede del zagal. Brief
mezclaba testimonios y pistas bajo «verdad canónica» pese a una advertencia.

Brief separa hechos establecidos/testimonios para DM/PC/TM usando el formato
atribuido existente; conserva texto, fuente, dudas, marcas y orden por sección.
No interpreta prosa ni cambia World/Codec. Una guía final después de archivo/
inventario/hechos corrige la fuente frente a prosa/resumen anterior, también
en combate, y permite primera persona del PNJ en su propia voz DM.

AC-25.7 entregado: ocho nuevos, rojo0/8 y verde8/8. Un aviso de comparación
constante en fixture generada se corrige sin cambiar producto;46 focalizados
limpios en1,8 s. Game mantiene World/SQL/Codec y un dado antiguo sin nuevas
tiradas/auxiliares; compacción DM/PC conserva fuentes actuales incluso frente
a resumen falso. TestModel verifica entrega/contexto, no obediencia semántica
libre. Gate2700/3 en55,5 s,seed30343/max_cases48/salida0: cero errores,
desconexiones/warnings de compile y seis avisos deliberados. Formato/compile/
diff correctos. No se oculta el primer aviso de fixture.

La misma pregunta real tras corrección796→806 tarda6,616 s: solo dos requests
PC, sin tools/TM/recorder/dados ni cambios World; ambos atribuyen al zagal la
comparación con el abrigo sin decir haberla visto. Detalles materiales que
solo constan en prosa siguen sin memoria durable verificada; voces muy
parecidas. Restart796/806 conserva modelos/ajustes/intents/eventos/hero y cierra
cinco auxiliares. SQL conserva prefijos772/796, recursos/inventarios/plazos,
catorce facts (trece anteriores verbatim), reloj41535 y todos los dados
nativos. Cuatro acciones772→806, cero dados nuevos. Otra mesa se observa
pausada/Thane12; no hay comparación de todo su World desde antes de estas
acciones, sí antes/después de la navegación final. Hook retirado/Show exacto;
normal1440/375 conectado, teclado ficha/inventario y dos PNG revisados, cero
JS/overflow; UI no cambia ambas mesas. Evidencia privada:
testimony-source-verification.json.

Alcance: separación del formato atribuido y caso real de comparación del
abrigo; no certifica toda semántica libre, originalidad o beta. La segunda
petición TM del regreso tiene inicio sin cierre medido por cancelación.
Comillas externas dobles del testimonio y deduplicación de envolturas quedan
para revisión separada. Sin reescribir facts legacy/narraciones anteriores,
ni cambiar Rules, datos, permisos o extraer observaciones automáticamente.
Objetivo de calidad y beta siguen activos.

## ✅ Entregado — efectos directos y progresión (D197), 2026-10-03

heal/grant_temp_hp/apply_condition/remove_condition/level_up requieren actor
dm antes de World/target/RNG/propuesta. La reproducción PC alcanza RNG, aplica
stun, elimina veneno, concede30 PG temporales propios y sube nivel sin fuente.
Error directivo remite a cast_spell, second_wind o capacidad pagada. Se restringe
el permiso de otorgarse PG temporales de D36; Rules/World/Codec no cambian.
DM conserva adjudicación directa, aura/presencia/validaciones y aviso de ficha
humana sin leer World. Esto no verifica fuente/coste de toda adjudicación DM.

AC-21.4 entregado: once nuevos,103 focalizados3,2 s sin avisos y gate completo
2692/3 en56,2 s, seed30343/max_cases48/salida0. Cero errores/desconexiones/
warnings de compile; seis avisos deliberados. Formato/compile/diff correctos.
Pure rojo3/9 (seis fallos), verde9/9; fixture antigua de aviso level_up sin actor
se adapta a DM ilegible,13/13. Dos Game normal/restart conservan veneno/aliada/
nivel y False Life pagado: temp8, un slot, una tirada, vencimiento44235.
Curación DM posterior añade solo su dado native; no vuelve a pagar/repetir el
hechizo. SQL/Codec/checkpoint/una declaración conservados.15 verdes0,4 s.
Segundo aliento también mantiene acción bonus/uso único; False Life sin slot
rechaza sin mutar. No se añaden mecanismos alternativos a esos Rules.

No hay nuevo beat LLM: TestModel/Session/Game/Postgres verifica esta corrección.
19425 sigue pausada/772 con World/eventos/recursos/hero/facts y otra mesa intactos
vía SQL readonly. Navegación normal1440/375 conectada, modal oculto/lienzo
presente, cero JS/overflow; sin hooks/PNG nuevos. Evidencia privada:
direct-effect-authority-verification.json. Un path inexistente en el comando
focalizado fue ignorado por Mix;103 cubre solo los archivos existentes, el gate
completo sí incluye toda la suite. No se ocultan ese límite ni el12/13 inicial.

Permiso aplicado a cinco tools: adjudicaciones DM, agencia, voces/dudas/memoria,
latencia y beta continúan abiertas. No certifica toda autorización ni semántica
libre/hardware/Safari/lector de pantalla. Objetivo y calidad siguen activos.

## ✅ Entregado — permiso de criaturas y combate (D196), 2026-10-03

spawn_monster/roll_initiative/end_combat exigen actor canónico dm antes de
World/RNG/propuesta, también cuando el humano resuelve con DMServer.
La reproducción pure permite crear un goblin, terminar combate y alcanzar
RNG como PC. Guardas tempranas lo rechazan conservando el estado; el DM
mantiene bestiario/refuerzo y el motor su iniciativa automática. No cambian
World/Codec, stubs de framework ni reglas puras.

AC-22.3 entregado: once nuevos,99 focalizados2,8 s sin avisos y gate final
2681/3 en55,8 s, seed30343/max_cases48/salida0. Cero errores/desconexiones/
warnings de compile; seis avisos deliberados. Formato/compile/diff correctos.
Rojo2/9 puro, verde9/9; Game normal/restart rechaza las tres llamadas humanas,
no guarda dados ni crea Invasor. DM crea Goblin una vez y el motor publica dos
iniciativas nativas, conservando recursos/checkpoint/SQL/Codec. Primera fixture
supuso orden Mara/Goblin: Actions usa Goblin/Mara; corregida,11 verdes0,4 s.
Los casos de combate previo, refuerzo y acceso antes de SharedState también pasan.

No se lanza una nueva acción LLM en esta entrega: la secuencia controlada usa
TestModel/Session/Game/Postgres.19425 sigue pausada/seq772,World/events/hero/
recursos iguales en SQL readonly y otra mesa intacta. Navegación normal1440/375
conectada, modal oculto/lienzo montado, cero JS/overflow; sin hook ni PNG nuevos.
Evidencia privada combat-authority-verification.json. Permiso aplicado a tres
tools; no certifica toda autorización del resolvedor humano ni semántica libre.
Continuar condiciones/curación/nivel, voces/dudas/memoria/latencia; beta activa.

## ✅ Entregado — autoría canónica de hechos y escenas (D195), 2026-10-03

El resolvedor humano comparte tools del DM y podía registrar una pista propia
antes de su confirmación. establish_fact/set_scene exigen ahora actor canónico
"dm" antes de leer/proponer World. Chequeos propios siguen por Rules; el DM
recibe al final del prompt una guía para confirmar descubrimientos relevantes,
separar testimonio/prueba y evitar duplicados. Se restringe ese permiso D156;
no se borran facts legacy ni se extraen automáticamente de prosa.

AC-25.6 entregado: siete nuevos, 54 focalizados en 3,0 s y gate final sin hook
2670/3 en 54,6 s, seed30343/max_cases48/salida0. Cero errores/desconexiones/
warnings de compile; seis avisos deliberados. Formato/compile/diff correctos.
Game verifica rechazo humano, confirmación DM, revisión y reinicio entre ambos
sin repetir el chequeo. Compacción DM/PC conserva pista y testimonio antiguo.
Dos fixtures anteriores pasan a confirmar la escena con DM; el primer gate
2669/2670 detectó uno de ellos y se conserva separado del gate final limpio.

19425: consulta729→739/5,585 s conserva World. Investigación739→747/18,745 s
(12+3=15vs15) revela el defecto antes de la corrección; su fact legacy se
conserva. Después, inspección747→755/14,695 s (17+3=20vs15) solo ejecuta
ability_check humano; World igual. Nuevos detalles del hilo quedan en prosa,
no en facts: no se acredita memoria durable de cada observación. Recogida
755→762/16,282 s usa grant_item DM y revisión4,783 s: hilo×1 en Mara, espina
vacía, hechos/reloj/recursos intactos. Consulta762→772/5,593 s solo Lyra/Vex,
sin tools/dados/cambios World; distinguen posesión del hilo de dueño desconocido.

Restart772/SQL conserva eventos1..772 y prefijos729/747, modelos/ajustes/
intents/hero; cierra cinco auxiliares y deja checkpoint vacío. Otra mesa
intacta. Hook retirado/Show limpio; reload normal1440/375, inventario/ficha
por teclado, dos PNG revisados y cero JS/overflow. Evidencia privada:
fact-authority-verification.json. Un cierre QA se pidió antes de pausa y dos
preparaciones de navegador fallaron antes de actuar; no se repitió ninguna
acción y se conserva su evidencia. No se mide cierre del segundo request TM.

Alcance: solo establish_fact/set_scene; auditar otros mutadores de mundo que
recibe el resolvedor humano. Voz de Lyra/Vex sigue parecida y Vex convierte
recencia tentativa en afirmada. No certifica semántica libre/hardware/Safari/
lector de pantalla ni beta lista. Calidad jugable y objetivo siguen activos.

## ✅ Entregado — dado modal y temporizadores (D194), 2026-10-03

El modal muestra DC/CA del grupo factual, ofrece «Cerrar tirada» y Escape,
contiene/restaura foco con primitivas Phoenix y mantiene montado dic_ex.
Cierre efímero con generación: cancelar/reemplazar fallback, invalidar flush
al descartar y rechazar mensajes duplicados o antiguos; cerrar limpia rolling,
cartas y timers. Snapshot conserva la generación local, sin tocar World/Codec.
AC-14.4 entregado: nueve nuevos y 59 focalizados en 4,9 s; gate final con Show
limpio 2663/3 en 54,6 s, seed30343/max_cases48/salida0. Cero errores,
desconexiones o warnings de compile; seis avisos deliberados de breaker/retry.
Formato, compile warnings-as-errors y diff correctos.

19425 investiga 713→721 en 13,477 s: 16+3=19 frente a DC15, éxito; World igual.
La pista nueva queda en narración, sin crear un fact. Probe expirado después
de acabar: Game/SQL confirman pausa/seq721 y no se repite la acción. UI reproduce
solo ese payload persistido en dos vistas 1440/375, sin nuevos dados/eventos:
DC15/total19, foco, Tab/Shift+Tab, Escape/Enter, botón44 px y lienzo conservado.
Tres PNG revisados incluyendo el defecto inicial; sin JS/overflow.

Seguimiento nuevo 721→729 en 17,729 s: 6+1=7 frente a DC15, fallo auténtico,
rastro perdido, reloj+900 s y revisión de escena3,997 s. El modal nuevo cierra
con Escape; no se fuerza éxito ni se repite tirada. Reinicio729 conserva World,
eventos/modelos/ajustes/intents/hero y cierra cinco auxiliares. SQL acredita
prefijo721/recursos/inventario/12 facts intactos, solo escena/log/reloj cambian;
otra mesa aislada. Hook retirado, Show limpio y navegación normal375/1440.

Evidencia privada: dice-dialog-verification.json. Chrome/teclado/2D probados;
no certifica hardware móvil/Safari/lector de pantalla ni identifica callbacks
3D antiguos después de un flush nuevo. La segunda petición TM tras entregar
el turno no tiene cierre medido en el probe; reinicio sí confirma reposo.
Detector revisado: seis avisos heredados fuera del cambio (estética D84 y
transición de barra). Coherencia, memoria de pistas y latencia siguen abiertas;
la beta no está declarada lista.

## 🟡 En investigación — limpieza intermitente de pruebas, 2026-10-02

El primer gate D163 pasa2462/3 (46,3 s), pero registra tres desconexiones
Postgrex por cliente/owner terminado durante la limpieza. La suite completa
con trazas (seed927614,53,6 s) y17 focalizados de autorización/visibilidad/sync
(seed534533,4,4 s) pasan sin esos errores; no se reproduce todavía la causa.
No se han añadido esperas ni cambios de producto para ocultarla. Conservar
los logs `dragonex-combat-end-commit-{full,trace}.log` y
`dragonex-combat-end-teardown-focused.log`; ampliar evidencia si reaparece.

D166 vuelve a observar dos desconexiones de clientes en el primer gate
(47,3 s, seed8106), junto a una regresión funcional ya corregida: una escena
registrada por el humano no debe revisarse otra vez. El gate final con trazas
y el mismo seed pasa2483/3 en54,4 s sin desconexiones. La causa de limpieza
sigue sin demostrarse; conservar también `dragonex-local-scene-review-
{full,full-trace}.log`. No se cambia producto ni se añaden esperas por ello.

El gate ordinario D167 pasa2490/3 en47,6 s (seed886859) sin desconexiones ni
warnings. No demuestra resuelta la causa intermitente anterior.

D168/D169 pasan2493/3 y2496/3 en47,4/47,1 s sin desconexiones ni avisos de
compilación. Registran8/10 avisos de ejecución: cinco corresponden al breaker
con errores400 simulados; el resto descubre fixtures que seguían jugando tras
su comprobación. La verificación adicional de abajo corrige esos fixtures.
La investigación de limpieza Postgrex sigue abierta.

D170 vuelve a observar tres desconexiones y dos terminaciones Game en el gate
ordinario2512/3,48,0 s/seed944912. Una traza apunta a Game.handle_call/snapshot
consultando eventos después de terminar su cliente SQL; títulos phase0/Mesa.
El gate con trazas y mismo seed pasa2512/3 en56,4 s sin esos errores, pero
usa max_cases1. Conservar `dragonex-wait-resolution-{full,full-trace}.log`;
la causa sigue abierta y no se atribuye la diferencia a una corrección.
Una repetición con `--trace --max-cases 48` vuelve a pasar2512/3 en55,3 s
con una desconexión y una terminación Game. ExUnit informa max_cases1 pese
al argumento48; no acredita ejecución concurrente. El último mensaje es
snapshot y su llamador ya ha muerto. El título SQL más cercano no identifica
con certeza el test responsable. Conservar también la traza
`dragonex-wait-resolution-full-trace-concurrent.log`.
D171 pasa2519/3 en47,0 s con el mismo seed944912/max_cases48, sin errores
ni desconexiones; cinco avisos deliberados del breaker. No demuestra cerrada
la causa anterior.

D172 pasa2529/3 en47,6 s, seed944912/max_cases48, con una desconexión de
owner SQL y un aviso de beat por TestModel agotado (CaseClauseError nil),
además de los cinco avisos deliberados del breaker. Cero terminaciones Game.
La traza serial2529/3 en55,2 s/max_cases1 no reproduce esas incidencias;
no acredita corregida su causa ni ejecución concurrente. Conservar
`dragonex-wait-scene-confirmation-{full,full-trace,full-final}.log`.

Verificación adicional2026-10-03: el aviso de multi-human se reproduce al
exigir el turno completo (Thane queda9 PG frente a6 previstos). Su fixture
ahora incluye la respuesta legítima del goblin y verifica daño, casillas,
cola vacía y World persistido. El gate instrumentado localiza otro aviso en
limbo: su fixture separa DM/PC y pausa antes de liberar la tercera respuesta,
comprobando tres voces completas, una tirada y persistencia. Ocho focalizados
en1,1 s; gate2529/3 en48,1 s/seed944912/max_cases48 sin avisos inesperados.
Registra una desconexión de cliente SQL, cero Games terminados. La instrumentación
temporal se retira y no se modifica el producto ni la dependencia. Conservar
`dragonex-{phase0-queue-completion-red,completed-fixtures-focused,
completed-fixtures-full-final,teardown-owner-full}.log`; causa SQL sigue abierta.

D173 pasa2530/3 en47,9 s/seed944912/max_cases48, con una desconexión cliente
SQL y una terminación Game al consultar snapshot; cinco avisos deliberados
del breaker, ningún aviso inesperado por modelo agotado. No se parchea el
producto para ocultar esta limpieza. `dragonex-scene-environment-full-final.log`.

D174 identifica una causa concreta con trazas de procesos: el test de ficha
del druida transformado cierra una LiveView durante su consulta SQL. El dueño
Sandbox todavía vive; la salida del cliente invalida la conexión compartida
y falla el snapshot del Game. ConnCase supervisa ahora el cierre síncrono de
las vistas montadas, esperando el callback actual antes de terminar el canal.
Dos pruebas verifican consulta retenida, snapshot en cola y dos vistas del
mismo Game. Gates ordinarios2532/3 en48,0/48,2 s, seeds944912/30343,
max_cases48, sin desconexiones ni terminaciones; solo cinco avisos breaker.
El gate intermedio49,0 s descubre un contador TMSpy que muere antes de su
petición; ahora ExUnit lo conserva hasta cerrar el Game. Instrumentación
retirada; sin cambios de producto/dependencias. Los casos históricos de
owner sin atribución exacta siguen bajo seguimiento si reaparecen; no se
declaran todos equivalentes por proximidad de títulos SQL.

## 🟡 En investigación — otras duraciones y ritmo de las esperas, 2026-10-03

19425: una espera de veinte minutos terminando el guiso falla antes del
proveedor por compresión UTF-8 (corregida en D169). Tras corregirla, la
confirmación recibe respuesta DM en6,6 s, pero omite advance_time y conserva
reloj34200. Una reconciliación explícita en segundos aplica1200 una vez y
deja35400, con recursos iguales; no prueba resuelta la omisión natural.
Conservar `beta-latency-meal_{wait,retry,clock}-runtime.json`. Revisar cómo
llega la duración declarada al DM y cómo confirmar su resolución sin depender
solo de la guía D165. Revisar también detalles del relato del goblin añadidos
por el narrador y datos nuevos del PNJ que solo permanecen en el historial.

D170 exige resolución de esperas literales nuevas con duración explícita,
incluida esa formulación de comida; no repara retroactivamente declaraciones
antiguas. Una nueva espera real de cinco minutos registra35400→35700 sin
confirmación manual. Viajes, duración compuesta, formulaciones no reconocidas
y semántica de interrupción general siguen bajo revisión. La respuesta real
tarda32,603 s, con recorder10,567 s, intento humano de advance_time rechazado
y consulta TM. Repite casi literalmente el rumor anterior; ese rumor ahora
queda en facts. Continuar reducción de peticiones y fidelidad/repetición narrativa.
D171 publica directamente una espera pasiva acotada:19425 registra180 s,
35700→35880, sin petición humana ni intento rechazado. Vuelve en17,884 s,
dos peticiones DM/una TM/una recorder; no es una comparación de latencia entre
declaraciones. TM agota tokens y usa fallback. Recorder3,853 s devuelve la
escena idéntica y deja scene_refresh_pending=true; revisar esa falsa revisión
pendiente. Maribel añade pago/monedas/herrero al rumor sin guardar esos datos
en facts; permanece la revisión de continuidad/durabilidad narrativa.

D172 permite confirmar la escena idéntica tras un intervalo aislado y
verificado, también al reiniciar. Los dos recorridos nuevos del proveedor
registran120/60 s una vez,35880→36000→36060, con recursos iguales y revisión
limpia, pero ambos reescriben la escena: la rama idéntica queda probada offline.
La escena sigue incorporando preguntas/gestos de Maribel y una jarra a medio
vaciar cuya continuidad requiere revisión. Separar entorno duradero de diálogo
y pose transitoria; mantener seguimiento de hechos PNJ, latencia y coordinador.

D173 entrega una guía de entorno físico al recorder y verifica conversación
conservada. En19425 la descripción baja915→662 caracteres y omite la pregunta/
oferta, pero conserva manos apoyadas y jarra a medio vaciar. El DM dice que el
forastero salió hacia el norte a mediodía; facts no cambia. Revisar cómo se
establece/recuerda información nueva y evitar resolver hilos por inactividad;
no se declara cerrada la calidad semántica mediante una instrucción al modelo.

D175 identifica una contradicción de ritmo: la espera reconocida era una
decisión del jugador, pero la guía DM ordinaria exigía novedades por aparente
inactividad. Game selecciona ahora una guía de espera deliberada; permite
ambiente estable e interrupciones coherentes, sin cerrar investigaciones o
retirar PNJs por novedad. Dos esperas reales15/15 s registran36090→36105→36120,
sin nuevos hechos ni cambios de recursos/escena. Ambas confirman el entorno
idéntico y limpian revisión pendiente: primera observación real de D172.
17,877/14,256 s hasta humano; la primera agota tokens TM y usa fallback,
la segunda completa TM en dos peticiones. No es un benchmark. No corrige
afirmaciones previas del forastero ni garantiza semántica del modelo: seguir
atribución/durabilidad de información PNJ, repetición sensorial y latencia.

D176 incorpora record_npc_statement: el DM guarda una afirmación con fuente
y dudas como testimonio, sin confirmar su contenido ni cambiar entorno/
presencia/recursos/reloj. En19425 Maribel registra que vio la salida, pero
atribuye la dirección al zagal de las cabras. La información ya queda en
facts con fuente explícita y sobrevive restart. Respuesta7,605 s, humano1/
DM2 peticiones, cero TM/recorder; no es benchmark. El zagal/cabras no aparecen
en el historial previo y el relato rellena una jarra sin petición del jugador:
revisar continuidad con la biblia y cambios físicos narrados. La pregunta
«¿Viste…?» pasaba por modelo humano y añadía gestos propios; D177 publica
directamente ese habla informativa acotada. El registro correcto no demuestra que todos los PNJ
llamen la tool ni que sus versiones sean ciertas. Beta sigue en preparación.

D177: «viste», «oíste» y «escuchaste», con tú opcional, conservan las palabras
del jugador sin una petición humana.19425 vuelve en4,538 s, una ejecución
DM/dos pasos, cero humano/TM/recorder, solo un testimonio nuevo en World.
La biblia de esa mesa está vacía: zagal/cabras no figuraban allí ni en history,
pero esa ausencia no convierte automáticamente un PNJ nuevo en contradicción.
Seguir continuidad de versiones del forastero y cambios físicos no registrados.
En móvil, los compañeros precedían la ficha propia dentro del cajón: abrirlos
desplazaba los detalles propios fuera de su primera pantalla; corregido D178.
D178 reabre Ficha desde los detalles propios y conserva posición mientras
se lee. D179 resuelve la crónica estrecha y los controles recortados entre
721–1023 px, además de la ficha propia oculta durante combate móvil.
D180 aclara en mesa la aparente contradicción de Maribel: distingue preguntar
de pedir un encargo, sin alterar World ni confirmar su relato. El coordinador
tenía un presupuesto256 que cortó una petición antes de decidir; ahora usa
1024 configurable. Una espera real15 s vuelve al humano sin fallback y
conserva recursos/escena. Continuar variantes con varios PCs, cambios físicos
narrados y latencia; esta muestra no acredita todavía la beta.

D181 conserva en History el crítico, el fallo de salvación de muerte y el
doble fallo natural1 ya confirmados por el motor. Dos conversaciones reales
con Lyra/Vex conservan World/recursos y vuelven al humano; ambos recuerdan el
crítico tras recibir su etiqueta completa. D182 publica las preguntas de
recuerdo/observación a compañeros sin reformularlas ni añadir gestos humanos.
Siguen abiertos el cierre DM repetitivo y la continuidad de campañas cuando
los hechos anteriores quedan fuera de la ventana reciente de400 eventos.
D183 elimina la contradicción del anti-repeat sensorial en conversaciones.
La prueba final aún añade tarde tibia: no cierra la repetición narrativa.
Seguir un cierre discreto con guardas del motor, preguntas PNJ y efectos vigentes.

D184 omite el beat DM tras una consulta informativa a PCs solo si acredita
respuestas completas, World íntegro y ninguna intervención adicional. La
medición real vuelve en5,574 s con dos runs; peticiones de acción, preguntas
nuevas de un PC, tiradas, cambios de mundo y evidencia incompleta conservan
el DM. Continuar campaña larga y consecuencias físicas narradas por PNJs;
este cierre acotado no certifica fidelidad semántica general ni beta.

D185 corrige un fallo descubierto al revisar esa memoria: History filtraba
tipos pero ignoraba visible_to. PCs/resolución humana/recorder reciben ahora
solo eventos públicos; DM conserva sus notas. Permisos seleccionados desde
el participante Game, antes de headers/compresión. Seguir recuperación de
evidencia antigua con ese mismo límite de visibilidad; beta continúa activa.

D186 recupera hasta32 tiradas previas al corte400, con visibilidad y referencias
originales, dentro del prompt actual para conservarlas tras compresión. En19425
los eventos24–25 ya estaban fuera: ambos PCs vuelven a decir veinte natural,
25 contra CA15 y daño18 sin tirar ni alterar World. Seguir evidencia más allá
de32 tiradas y continuidad PNJ; ambas voces repiten gestos de jarra, pulido abierto.

D187 alinea prefijo e instrucción/nudge PC: una respuesta no necesita otro
gesto o acción. Detector corregido a dos narraciones públicas más recientes.
Dos preguntas reales sin gesto de jarra, World intacto; fórmulas compartidas
y detalles de posibles huidas siguen bajo revisión. Próximo: nueva aventura,
continuidad PNJ/efectos físicos y recuperación de escenas/testimonios antiguos.

D188 preserva también las preguntas PC de información/opinión: una consulta
real sobre ir al molino ya no añade una espera a Maribel ni otra narración
humana. La pista del cruce queda atribuida; la era alternativa solo en prosa.
Continuar desplazamiento declarado/tiempo y fuente del zagal, sin convertir
la propuesta o el rumor en hecho objetivo. Beta sigue en preparación.

## ✅ Hecho y probado

### Testimonios con referencia temporal durable (D193 / R25), 2026-10-03

- NPCStatement guarda el elapsed_seconds vigente fuera de cada cita nueva.
  No calcula fechas ni interpreta lo narrado. La fuente y la incertidumbre
  permanecen; solo cambia facts, sin campos World/Character o migraciones.
  Un duplicado normalizado aún conservado mantiene primera marca/posición.
  Legado sin marca sigue sin fecha inferida; contenido distinto recibe marca
  propia. Cap30 permanece: un testimonio expulsado ya no tiene referencia
  recuperable. Brief DM/PC/TM explica reloj del registro frente al actual.
- Cinco regresiones nuevas: paso de un día/JSON/prompt, duplicado posterior/
  versión distinta, legado, etiqueta dentro de cita/puntuación y cap30. Game
  existente usa37935, verifica DB/checkpoint/replay/restart y compacción DM/PC
  que omite diálogo tras86400 s, conservando marca y reloj124335. Assertions
  literales anteriores se actualizan al nuevo formato sin perder contenido.
  Rojo inicial7/11;22 verdes1,4 s antes del caso cap,94 focalizados2,5 s.
  **2654/3 en54,8 s**, seed30343/max_cases48/salida0; cero errores/desconexiones/
  warnings de compile, seis avisos deliberados. Formato/compile/diff correctos.
- 19425: retorno682→689/15,299 s aplica900 s; pregunta689→696/5,599 s tiene
  solo DM/dos pasos/record_npc_statement. Nueva versión sobre ir solo queda
  atribuida con marca38835; once facts previos, reloj/recursos/escena intactos.
  Viaje696→703/17,905 s aplica900 s y deja39735, conserva marca38835. Ambos
  movimientos registran escena mediante recorder (6,491/5,387 s).
  Consulta703→713/6,097 s solo Lyra/Vex: requests incluyen marca, recuerdan
  haber oído la versión recientemente y separan testimonio de botón/huellas.
  World igual; no constituye precisión temporal o semántica general del LLM.
- Restart713 conserva World/eventos/cursor/intents/modelos/ajustes/hero y cierra
  cinco auxiliares. SQL conserva prefijo682, recursos/inventario/facts previos,
  cero dados nuevos; solo un testimonio, escena/log y1800 s. Edad de registro
  900 s; legado sin backfill. Hook retirado/Show exacto antes de navegación
  normal; reload1440/375/ficha/inventario/compañeros por teclado y dos PNG
  revisados, cero JS/overflow. Evidencia privada testimony-clock-verification.json.
- AC-25.5b entregado. No se verifica el relato ni se migra prosa antigua;
  no se amplía memoria400/32/cap30 o garantiza registro universal por el modelo.
  Continuar huellas/consecuencias físicas, voces y latencia; beta activa.

### Preguntas con preposición sin reformulación humana (D192 / R31 / R32), 2026-10-03

- «¿De qué…?», «¿Por qué…?», «¿Con quién…?» y otras formas acotadas de una
  preposición + interrogativo acentuado usan el habla literal ya existente.
  PNJ cualificado/prioridad PC, vocativos y cola conservan sus guardas.
  Acciones, magia, pagos, duración o identidad incierta siguen por modelo/tools;
  no se interpreta un efecto desde la pregunta ni se cambia el World.
- Seis regresiones nuevas en Text/Game PNJ/PC. Restart pendiente ampliado
  en ambos recorridos y False Life mixto conserva casilla/PG temporales/dado.
  Rojo20/26; verde26/26 en1,7 s y86 focalizados4,1 s. **2649/3 en55,3 s**,
  seed30343/max_cases48/salida0: cero errores/desconexiones/warnings de compile;
  seis avisos deliberados (cinco breaker, uno timeout). Formato/compile/diff.
- 19425: pregunta original651→658/11,742 s incluye narrador humano que añade
  un gesto. Corrección658→665/6,123 s publica palabras exactas: solo DM, un
  fallo transitorio/reintento y una respuesta; World intacto. No se considera
  comparación causal de latencia. Preparación inicial y métricas parciales
  fallidas conservadas; un observer expirado no llega a ejecutar acción.
- Viaje declarado665→672/15,268 s: advance_time900 y set_scene efectivos,
  reloj37035→37935 y curva del norte guardada. DM3 pasos y TM decide retorno;
  su petición posterior a la decisión se cancela por D79. No recorder nuevo.
  Pregunta PC672→682/5,056 s: habla exacta, Lyra y Vex una respuesta cada uno,
  recuerdan origen/hatillo; cero humano/DM/TM/tools, World intacto.
- Restart final preserva682 eventos/World/cursor/intents/modelos/ajustes/hero y
  cierra cinco auxiliares. SQL conserva prefijo651, personajes/inventario,
  facts anteriores y cero dados nuevos; añade un testimonio atribuido, escena/
  log y900 s. Reload1440/375, ficha/inventario/compañeros por teclado, sin
  overflow/errores JS; dos PNG revisados. Hook retirado y Show exacto antes
  de la navegación normal; evidencia privada prepositional-question-verification.json.
- AC-31.2h2/32.1b entregados. Gramática limitada, sin reducir400 eventos/32
  tiradas ni afirmar memoria ilimitada o fidelidad semántica general. La pista
  queda recordada; continuar aventura, voces, consecuencias y latencia. Beta activa.

### Esperas de mesa reales y pausa respetada durante un fallo (D191 / R16 / R19), 2026-10-03

- Beat conserva PID/etapa solo en memoria. Game acepta el inicio de revisión
  del Task/turn_id DM vigente, ignora mensajes antiguos o repetidos y expone
  busy_stage escalar. La mesa distingue narración/acción, «Actualizando la
  escena…», «Organizando el siguiente turno…» y «Reintentando el turno…».
  Status accesible/polite; revisión/relevo/backoff limpian el cursor y rechazan
  chunks tardíos. Pausa/espera ocultan el indicador; no añade campos World,
  eventos, permisos de acción ni cambios de reglas de relevo.
- El caso web de backoff descubre que faltaba publicar el cambio de etapa.
  Entradas de actor/TurnMaster/reintento ahora avisan a la vista. Otro caso
  demuestra que un error posterior a «Pausa» restauraba running: el reintento
  conserva paused y solo continúa al reanudar. World y estado SQL de pausa
  permanecen coherentes; no se reejecutan recursos confirmados.
- Ocho regresiones nuevas: Game3 (etapas/mensajes/pausa, TurnMaster y restart
  durante recorder con narración/inventario únicos), LiveView4 (dos vistas,
  reload/borrador/cursor, relevo, backoff y fallo posterior a pausa) y retry1.
  Rojo inicial0/5; dos casos de retry2/4 antes del arreglo.71 focalizados en
  7,8 s; **2643/3 en53,3 s**, seed30343/max_cases48/salida0, cero errores,
  desconexiones o warnings de compilación. Seis avisos deliberados: cinco
  breaker y uno timeout de prueba. Formato/compile warnings-as-errors/diff.
- Partida19425: reinicio inicial conserva637 eventos/World/cursor/intents/modelos/
  ajustes/hero y cierra cinco auxiliares. Dejar637→644/22,159 s registra stock0;
  recoger644→651/27,396 s deja1. Dos vistas1440/375 observan revisión y relevo
  sin cursor y conservan borrador; reload/teclado/ficha/inventario comprobados.
  Cuatro capturas revisadas. SQL conserva el prefijo637, PG/recursos/inventario
  final/facts/reloj37035/hero; solo cambian escena/log, cero dados nuevos.
  Hook retirado, Show de producto exacto y navegación normal tras el arreglo
  de reintentos. Evidencia privada busy-stage-verification.json.
- AC-16.3/19.3 entregados. La espera se explica; latencia sigue abierta y no
  se afirma aceleración. Continuar variantes de consecuencias físicas,
  aventura/pistas al norte y memoria de testimonios fuera de ventana. Beta
  global sigue en preparación.

### Inventario de aventura cuantificado y visible (D190 / R38), 2026-10-03

- Recoger el botón solo cambiaba la prosa:19425 conserva todo World560→567.
  Rules.Inventory/World y grant_item/remove_item del DM confirman posesión en
  exploración para PC presente. Nombre scrub/NFC/case/espacios, límites160/
  9999/80, suma/resta y stock insuficiente deterministas; cero elimina la pila.
  No cambia Character/Item/Codec, equipo de combate, PG/casillas/reloj o héroe
  reusable. Inventario actual en brief y ficha propia, traducido/escapado,
  desplazable por teclado; sin escritor LiveView.
- Replay normaliza identidad y conserva el efecto confirmado en otro PID.
  Cambiar posesión solicita revisión durable de escena: el recorder da
  prioridad al inventario. Confirmar descripción idéntica requiere comprobante
  del beat con huella del resto del World intacta y sin revisión anterior;
  se revalida al commit. Legacy, otros efectos o revisión ya pendiente exigen
  snapshot nuevo. Timeout mantiene pendiente y no repite ni cobra el objeto.
- Ensayos intermedios revelan entregas/dejar sobre piedra sin tool, e intento
  humano rechazado. El contrato por turno queda después del archivo de dados,
  con la última declaración visible/no respondida, saneada/acotada; DM registra
  consecuencias aunque el narrador humano las describiera. No se extrae stock
  de la prosa. Las omisiones anteriores permanecen en sus evidencias.
-22 regresiones nuevas en seis archivos;110 focalizados en2,8 s y **2635/3
  en52,6 s**, seed30343/max_cases48/salida0, cero errores/desconexiones/avisos
  inesperados; cinco breaker deliberados. Controles replay1/3, huella3/4 y
  contrato de turno3/4; fuentes restauradas. Formato/compile/diff correctos.
-19425 investiga552→560: d20 18+INT3=21 vs CD15, éxito/una tirada y dos facts;
  preparación de observer fallida, sin atribuir número/tiempo de runs. Recogida
  inicial560→567 no registra stock. Primera corrección567→574 añade1 pero deja
  escena vieja; entrega574→581 retira1 y actualiza escena/recorder5,844 s.
  Devolución588/almacenamiento595 aún omiten tool; confirmación595→602 registra1.
  Dejar602→609 falla antes del último ajuste de contexto; después609→616 retira1
  y616→623 recoge1 con set_scene. Recursos/hero/modelos íntegros.
- La formulación original de dejar se comprueba otra vez623→630: remove_item1
  correcto,44,104 s/recorder timeout20 s/revisión pendiente. Nueva recogida
 630→637 confirma grant_item1,28,626 s/recorder3,634 s/pendiente false. Reinicio
  público conserva637 eventos/World/cursor/intents/modelos/ajustes y cierra cinco
  auxiliares. SQL solo lectura,375/1440 px/reload/teclado y22 capturas revisadas;
  Show restaurado exacto, hook retirado; inventory-verification.json privado.
- Alcance R38 entregado. Seguir latencia, otras formulaciones/transferencias,
  pistas al norte y datos PNJ solo en history. No demuestra cumplimiento LLM
  universal, registro de suelo/economía/equipamiento ni beta certificada.

### Preguntas al zagal y otros oficios sin reformulación (D189), 2026-10-03

- «Le pregunto al zagal» no entraba en la ruta PNJ literal: añadía narrador
  humano y coordinación. Text comparte un vocabulario ampliado de oficios,
  con un complemento corto como «de las cabras» o «del pueblo». Conserva
  las guardas D167/D177 y el habla saneada exacta. Descripciones largas,
  acciones/hechizos añadidos y gramática incierta mantienen resolución.
- El registro Game y el habla literal reciben todos los nombres PC del World.
  Coincidencias completas/cortas, artículos, Unicode NFC y límites de palabra
  impiden que «El Zagal» jugador reserve una respuesta de PNJ. No se crea un
  registro de entidades, nuevos campos, herramientas o escrituras fuera de Game.
- Seis regresiones nuevas: tres de texto/guardas y tres Game con respuesta,
  testimonio atribuido, colisión PC y restart pendiente sin duplicados. False
  Life mixto conserva casilla/tirada reales. Rojo9/14 en2,9 s; verde14/14 en0,8 s.
  Controles oficios9/14 y sin roster13/14, restauración exacta.43 focalizados
  en2,5 s; **2613 passed / 3 excluded en52,6 s**, seed30343/max_cases48/salida0,
  sin errores/desconexiones/avisos inesperados; cinco breaker deliberados.
  Formato, compile warnings-as-errors y diff correctos.
- 19425: viaje declarado531→538/15,261 s confirma900 s una vez, reloj36135→37035
  y escena del molino registrada; solo reloj/log/escena cambian. Humano y DM
  completan uno/dos pasos; TM decide y cancela anticipadamente, recorder3,015 s.
  Primera pregunta538→545/16,811 s añade solo versión del zagal, con humano/
  DM/TM. Tras el cambio545→552/7,109 s publica pregunta exacta: una ejecución
  DM/dos pasos/record_npc_statement, cero humano/PC/TM/recorder/dados. Solo facts
  cambian, recursos/hero/modelos íntegros; scrub elimina etiquetas del DM.
- Reinicio público conserva World/events/cursor/intents/modelos/ajustes y cierra
  cinco auxiliares, sin eventos por resume/pause. SQL solo lectura, reload375/
  1440 px, teclado y ocho capturas revisadas sin JS/overflow. Hook retirado y
  Show exacto; evidencia privada npc-occupations-verification.json.
- Alcance: vocabulario/gramática acotados, versiones atribuidas sin certificar
  verdad ni memoria completa; muestras distintas sin benchmark causal de latencia.
  Seguir pistas y consecuencias físicas, continuidad fuera de ventana y aventuras
  completas. Beta sigue activa.

### Preguntas de opinión PC con las palabras del jugador (D188), 2026-10-03

- Al proponer hablar con el zagal, el narrador humano reformuló la pregunta,
  añadió jarra/luz/gestos y dijo que se esperaba a Maribel, aunque la cola
  era Lyra/Vex. Text.literal_pc_speech amplía la guía D182 de recuerdo a las
  formas informativas/opinión ya reconocidas por pc_question_only?. Una sola
  pregunta con vocativo inicial, espera pasiva opcional y cola manual completa
  coincidente se publica tras scrub. Conserva nombres, orden y pregunta; no
  pide otra narración humana. No amplía quién responde ni decide viajes.
  Peticiones de acción, cláusulas adicionales, magia, duración, combate,
  mini/re-eval/interrupción, cola parcial y nombres ambiguos conservan su ruta.
- Cuatro casos nuevos: formas informativas/opinión, guardas de cola/actor,
  request real a ambos PCs y opinión+False Life con una casilla/dado/coste
  únicos. La prueba de restart existente recorre recuerdo y opinión, termina
  run antiguo/PID distinto y no duplica habla/turno humano. El cierre de
  preferencias ahora exige ausencia de peticiones humano/DM. Los fixtures de
  historial público/archivo antiguo y narrador bloqueado/fallido añaden una
  declaración propia para seguir ejercitando esa ruta; se comprueba que el
  callback fallido realmente corre. Un oráculo excluye la escena inicial DM
  al contar las voces del intercambio. No se cambian permisos por los fallos
  de fixture. Rojo6/10 en0,7 s; control memory-only6/10 en0,7 s sin errores/
  avisos, fuente restaurada exacta.25 cercanos2,2 s, **77 focalizados4,8 s y
  2607 passed / 3 excluded en52,2 s**, seed30343/max_cases48/salida0. Cero
  errores/desconexiones/avisos inesperados; cinco breaker deliberados.
  Formato/compile warnings-as-errors/diff correctos.
- 19425: pregunta PNJ6,095 s,504→511, un run DM/dos pasos/una tool
  record_npc_statement. Maribel sitúa al zagal en el cruce; solo añade un
  testimonio atribuido, conservando el resto de World/clock36135/hero/modelos.
  «Era de los pastos» aparece solo en su prosa posterior: queda abierta la
  durabilidad de toda información añadida después de registrar el testimonio.
  Consulta de opinión antes6,109 s,511→521, tres runs/un paso: humano y dos
  PCs, World igual pero habla humana alterada. Después4,053 s,521→531, dos
  runs PC/un paso, cero humano/DM/TM/recorder/tools/dados: habla exacta una
  vez, ambas respuestas/orden y archivo24–25 conservados. World/clock/hero/
  modelos e history DM intactos. No se presenta la diferencia de muestras
  como benchmark causal ni originalidad narrativa garantizada.
- Reinicio público conserva estado/historial/cursor/intenciones/modelos/ajustes,
  cierra cinco auxiliares y no añade eventos al resume/pause. SQL solo lectura,
  UTF-8/JSON, reload375/1440/teclado/ficha/compañeros y ocho capturas revisadas
  sin JS/overflow. Hook retirado/Show exacto; evidencia privada
  pc-opinion-literal-verification.json. Propuestas aún no son partida ni viaje
  consumado. Próximo: declarar el desplazamiento al molino, tiempo/entorno y
  preguntar al zagal; seguir memoria de prosa PNJ y calidad semántica. Beta activa.

### Respuestas PC sin acciones ni gestos obligatorios (D187), 2026-10-03

- El prefijo estable exigía un gesto/propuesta incluso al contestar; el nudge
  imponía una nueva acción frente a la instrucción de responder sin tiradas.
  Ambos respetan ahora la respuesta pendiente: diálogo suficiente, datos
  confirmados repetibles, sin adornos físicos obligatorios. Game selecciona
  ese contexto desde World.conversation para un PC consciente. La ruta libre
  mantiene proactividad; no cambia reglas, tools, structs, escritores ni
  sanitización, y no filtra coincidencias o desacuerdos por similitud.
- El detector tomaba las primeras dos narraciones del bloque cronológico40.
  Ahora usa las últimas dos públicas del actor y cita la última en el nudge
  libre. Duplicados antiguos y notas privadas no fuerzan acciones ni filtran
  texto privado. Cuatro regresiones del detector y dos Game verifican ambos
  requests efectivos, prefijo propio, predecesor conservado, World íntegro y
  reinicio pendiente sin duplicar habla humana. Se amplía el contrato de voz
  existente. Rojo3/10 en0,5 s; un oráculo de reinicio se corrige para admitir
  el marcador del intento recuperado, conservando una narración por actor.
  Verde10/10 en0,5 s. Controles contexto retirado8/10 en0,4 s y filtro privado
  retirado9/10 en0,5 s, fuentes exactamente restauradas; cero errores de log.
- **96 focalizados en3,8 s y2603 passed / 3 excluded en51,1 s**, seed30343/
  max_cases48, salida0; cero errores/desconexiones/avisos inesperados, cinco
  breaker deliberados. Gate anterior2603/3 en51,0 s informó resultados verdes
  pero salió143: se conserva sin declararlo gate satisfactorio. No se ha
  demostrado la causa de esa salida. Formato/compile warnings-as-errors/diff
  correctos. Reinicios y casos de preguntas/peticiones PNJ siguen pasando.
- 19425: primer ensayo3,997 s con hook que no ejecutó por un assign incorrecto;
  conserva captura browser pero no acredita runs ni el prefijo reconstruido.
  Se corrige el hook y exige artefacto en cada etapa; reinicio previo conserva
  World/events/modelos/ajustes y cierra cinco auxiliares. Dos preguntas
  instrumentadas4,530/4,013 s,484→494→504, cada una con dos runs PC/un paso,
  cero humano/DM/TM/recorder/tools/dados. Respuestas sin el gesto de jarra;
  cifras20 natural/25 vs15/18 intactas en la primera, ambas reconocen la flecha
  en la pregunta nueva. Persistido igual a scrub/raw, UTF-8/JSON válidos y
  archivo original24–25 en el prompt actual. Nudge no activado live; su rama
  y prefijo efectivo acreditados offline. World/clock36135/hero/modelos/history
  DM íntegros. El gesto seguía presente en el ensayo anterior sin prefijo nuevo.
- Reinicio final conserva estado/historial/cursor/intenciones/modelos/ajustes,
  cierra cinco auxiliares y no añade eventos al resume/pause. Reload375/1440,
  teclado/ficha/compañeros, seis capturas revisadas sin JS/overflow. Hook retirado
  y Show restaurado byte a byte; SQL solo lectura y evidencia privada
  pc-response-pacing-verification.json. Ambas voces aún usan fórmulas parecidas
  y mencionan posibles huidas del goblin: no se certifica originalidad ni
  toda continuidad narrativa. Seguir PNJs/efectos físicos, aventura nueva y
  memoria más allá de32 tiradas/escenas; objetivo beta activo, sin SLA.

### Tiradas anteriores al contexto reciente, como evidencia histórica (D186), 2026-10-03

- Game consulta solo lectura hasta32 eventos dice anteriores al primer seq
  reciente, con filtro por partida/visibilidad antes del límite. History
  revalida audiencia, secuencias/payload, orden y duplicados; reutiliza el
  formateador factual D181/D161. Se añade al prompt del turno, junto al World,
  como selección histórica parcial y sin inferir PG/recursos actuales ni
  repetir herramientas. Compaction solo resume history previo: este archivo
  llega con el mensaje actual. No se persistirá como narración ni duplicará
  el timeline. Se omite la consulta para habla local/final recuperada sin modelo.
  Sin reglas nuevas, cambio de structs o escritor adicional.
- Migración9 añade índice parcial game_events(game_id,visible_to,seq) para
  type=dice, aplicada en dev/test. No migra datos de partidas. Seis pruebas
  puras/compresión real, dos consultas DB y dos Game verifican corte400,
  límite32 aun si se pide64, visibilidad antes del límite, grupos que cruzan
  el corte, crítico/daño/fallos de muerte/subtotal negativo, rol propio,
  humano/PCs/DM y reinicio pendiente sin volver a tirar. Un fixture comparaba
  el payload átomo recién insertado con el JSON reconsultado; se corrige el
  oráculo. La primera versión compactable se mueve al prompt actual y se
  añade prueba que fuerza Summary. Controles finales: archivo suprimido8/10
  y visibilidad antes del límite retirada9/10, ambos0,6 s limpios, fuentes
  restauradas exactas. **77 focalizados en5,2 s y2597 passed / 3 excluded
  en50,1 s**, seed30343/max_cases48. Cero errores/desconexiones/avisos
  inesperados; cinco breaker. Formato/compile warnings-as-errors/diff correctos.
- SQL previo19425: ventana55–454; crítico y daño en24–25, ya fuera. Dos
  preguntas6,615/5,057 s, dos runs PC/un paso y cero humano/DM/TM/recorder/tools/
  dados;454→464→474. Ambos prompts conservan evidencia original20+5=25 vsCA15
  y4d6(1,2,6,6)+3=18 con resultado crit, dentro del mensaje WORLD actual.
  La primera respuesta es narrativa; al pedir cifras exactas, ambos dicen
  veinte natural/25 contra15/18. World/clock36135/hero/modelos e history DM
  idénticos. No se infiere recuerdo por ausencia de contradicción: se contrastan
  los números con los eventos originales. Las dos voces repiten el mismo
  gesto de jarra; no se presenta como diversidad narrativa resuelta.
- Dos reinicios públicos cierran cinco auxiliares cada uno y conservan World/
  historial/cursor/intenciones/modelos/ajustes, sin eventos al resume/pause.
  UTF-8/JSON, SQL solo lectura y reload375/1440/teclado/ficha/compañeros; ocho
  capturas revisadas sin JS/overflow. Hooks retirados/Show exacto; evidencia
  privada roll-memory-verification.json. Captura live Server.history sin
  system efímero; compresión forzada/prefijos efectivos probados offline.
- Las32 tiradas no son memoria de campaña ilimitada, búsqueda semántica de todo
  pasado ni archivo de escenas/testimonios. Recorder mantiene contexto público
  reciente; World actual sigue prevaleciendo. Continúan PNJs/efectos físicos,
  prosa repetida y más variantes antes de beta; sin SLA/hardware/Safari.

### Visibilidad de eventos aplicada también a los agentes (D185), 2026-10-03

- History.from_events usa contexto público por defecto y permite eventos
  all/dm solo con viewer "dm" explícito. Game.Beats pasa el participante
  vigente, no el nombre del Server: la resolución humana usa el Server DM,
  pero recibe únicamente datos públicos. Filtra antes de construir headers,
  fusionar voces y comprimir. Visibilidades desconocidas/ausentes y eventos
  tool quedan fuera, con la misma política pública/DM que el feed. El recorder
  conserva el default público; las notas privadas permanecen en Postgres.
  Sin escrituras World, nuevos campos, tools ni cambios de modelos/recursos.
- Cinco pruebas puras/recorder y dos Game comprueban todos los tipos privados,
  marcadores ocultos, compresión, audiencias inválidas, requests efectivos de
  humano/Lyra/Vex/DM y recorder, prefijos propios y reinicio de Lyra con PID
  distinto sin repetir narraciones. Primer fixture agotó su script al olvidar
  que humano/DM comparten Server; se corrige la preparación. Rojo final0/7
  en0,3 s limpio. Controles negativos: filtro desactivado0/7; participante DM
  no enviado5/7, ambos0,3 s limpios y fuentes restauradas byte a byte.
  **67 focalizados en4,7 s y2587 passed / 3 excluded en50,5 s**, seed30343/
  max_cases48, sin errores/desconexiones/avisos inesperados; cinco breaker.
  Formato/compile warnings-as-errors/diff correctos.
- Navegador19425: reload375/1440 px, última respuesta Vex453 una vez, ficha/
  compañeros por teclado y PG intactos, dos capturas revisadas sin JS/overflow.
  SQL solo lectura conserva World/cursor/pausa y los454 eventos respecto D184;
 19439 sigue pausada. Sin nuevo playtest narrado/llamadas a proveedor ni hooks
  para esta corrección. Privacidad de los requests probada con TestModel;
  no atribuir esa prueba a una captura de un proveedor live.
  Evidencia privada history-visibility-verification.json. Alcance: permisos
  de game_events, no clasificación de secretos dentro de facts/story_bible.
  Continuidad fuera de400, PNJs/efectos físicos y beta siguen abiertas.

### Retorno directo tras consultas PC sin consecuencias pendientes (D184), 2026-10-03

- El Game reserva una prueba durable en la conversación existente para una
  pregunta informativa/opinión con vocativo PC, en exploración manual y espera
  pasiva opcional. Al terminar el último PC, revalida dentro de la misma
  actualización Session: huella del World completo salvo conversación y
  checkpoint, acción original y transcript reciente íntegro. Solo una respuesta
  completa por interlocutor, en orden literal, y relevos propios. Si todo
  coincide, cierra localmente y devuelve control; no crea turno, narración ni
  llamada DM. No hay escritor adicional, nuevas reglas ni campos Character.
- JSON valida quiet_close como hash SHA256 y seq de acción. Una conversación
  antigua sin prueba mantiene su camino. Dados, fallos, respuestas parciales,
  nueva pregunta PC, otra declaración humana, escena/reloj/recursos/hechos
  cambiados, mini/re-eval/interrupción, autoplay o anchor fuera de400 eventos
  conservan DM. «Vex, ¿puedes pedir agua a la posadera?» también: abre una
  petición al mundo. Las preferencias siguen usando el narrador humano;
  solo el cierre final puede omitirse. No interpreta consecuencias semánticas
  de cualquier prosa ni convierte una narración en hechos del motor.
- Seis pruebas de parser/prueba/Codec y ocho Game: voz propia/orden, reinicio
  durante Lyra sin duplicados, tirada sin cambio World, False Life con coste
  único, preferencia, pregunta nueva al PNJ, intención humana intercalada y
  fallo terminal/pregunta mixta. La regresión del encargo de agua detectó una
  admisión demasiado amplia y conserva su oráculo DM. Los tests históricos
  de habla pura esperan ahora retorno directo; D183 usa una cláusula de
  consulta al mundo para seguir comprobando el prompt DM pendiente.
  Control negativo sin transcript11/14 en1,0 s;69 focalizados en3,7 s;
  **2580 passed / 3 excluded en50,9 s**, seed30343/max_cases48. Cero errores,
  desconexiones/avisos inesperados; cinco breaker deliberados. Formato,
  compile warnings-as-errors y diff correctos.
- 19425:434→444→454, dos consultas con habla literal/una voz Lyra/Vex, sin DM
  ni dados/fallback. Primera7,642 s: observador expirado, sin atribuirle número
  de runs. Repetición5,574 s: dos runs de un paso, cero humano/DM/TM/recorder/
  tools, hash del history DM idéntico antes/después. World/clock36135/hero/
  modelos iguales; respuestas clean=persistido/UTF-8. Reinicio público cierra
  cinco auxiliares y conserva World/historial/cursor/intenciones/modelos/
  ajustes, sin eventos al reanudar/pausar. Reload375/1440 px/teclado/ficha/
  compañeros, cuatro capturas revisadas sin JS/overflow; hook retirado/Show
  exacto, SQL solo lectura. Evidencia privada quiet-conversation-verification.json.
- Continúan abiertos prosa PNJ/efectos físicos y memoria fuera de400 eventos.
  No es un SLA, clasificador universal ni prueba de hardware/Safari; beta activa.

### Guía de cierre sin instrucciones sensoriales contradictorias (D183), 2026-10-03

- El cierre de conversación ya no pide obligatoriamente frases de ambiente.
  El corrector anti-repeat recibe contexto explícito del World: en conversación
  pide respuesta/consecuencia pendiente o cierre breve; fuera conserva su guía
  habitual. Antes anteponía «cambia olor/sonido/luz» a «no añadas ambiente».
  Solo corrige instrucciones: no hay cierre silencioso, filtrado semántico de
  prosa, reglas nuevas ni cambios de World/tools/modelos.
- Tres Game verifican mensajes efectivos con narraciones previas repetidas,
  dos intercambios, reinicio del DM pendiente y respuesta PNJ/testimonio real.
  Conservan voz propia/recursos/World y una respuesta final por actor. El DM
  pendiente conserva dos marcadores de intento al reiniciar, sin repetir las
  respuestas PC. El fixture cuenta finales completos, separando apertura de
  escena e intentos; usa speaker en record_npc_statement. Control negativo
  final1/3 por guía sensorial contradictoria, sin errores/avisos.42 focalizados
  en3,3 s; **2566 passed / 3 excluded en49,6 s**, seed30343/max_cases48,
  cero errores/desconexiones/avisos inesperados, cinco breaker deliberados.
  Formato/compile warnings-as-errors/diff correctos.
- Dos conversaciones19425:7,618/7,605 s, tres runs de un paso, cero humano/TM/
  recorder/tools/dados; World entero/reloj36135/hero/modelos iguales,408→421→434.
  La primera, con solo el prompt nuevo, aún recibe la orden sensorial anterior
  y narra luz más dorada/cuenco colgado. Después de corregir el contexto, la
  última petición no lleva esa orden; el umbral no activa otro anti-repeat.
  El caso que sí activa la nueva guía se verifica con TestModel. No confundir
  selección correcta de guía con obediencia narrativa: el cierre final aún
  repite «la tarde sigue tibia» y afirma «sin fisuras». Repetición sigue abierta.
- Dos reinicios públicos preservan World/historial/cursor/intenciones/hero/
  modelos/ajustes, cierran cinco auxiliares cada uno y no añaden eventos al
  reanudar/pausar. UTF-8/JSON, reload375/1440 px/teclado/ficha/compañeros, ocho
  capturas revisadas sin JS/overflow. Hooks/probe retirados, Show exacto;
  evidencia privada `conversation-pacing-verification.json`.
-434 eventos no prueban memoria ilimitada: revisar hechos/dados que abandonan
  la ventana400. La captura live es Server.history sin system efímero; los
  requests efectivos se comprueban offline. Continúa diseñar/verificar un
  cierre discreto controlado por el motor cuando no necesita resolver el mundo,
  sin perder preguntas PNJ ni consecuencias. Beta sigue abierta; sin SLA ni
  dispositivos físicos/Safari verificados.

### Preguntas informativas a compañeros con las palabras del jugador (D182), 2026-10-03

- Un vocativo PC y una sola pregunta de recuerdo/observación, seguida como
  máximo de espera pasiva de respuestas, se publica literalmente. Conserva
  destinatarios y orden escrito, retira la espera no hablada y pasa por scrub.
  Exige exploración manual, cola completa registrada para esa misma pregunta
  y ausencia de mini/re-eval/interrupción. Peticiones, preferencias, acciones
  adicionales, magia, esperas cronometradas e identidades ambiguas conservan
  su resolución habitual. Sin nuevas reglas, fields ni escrituras LiveView.
- Tres casos de parser/guardas y tres Game: mensajes efectivos de ambos PCs
  con voz literal/rol propio, cero petición de reformulación humana, reinicio
  real durante la primera respuesta sin duplicar voz y False Life mixto con
  tirada/coste únicos. Control negativo4/6; seis pasan en0,5 s,62 focalizados
  en2,9 s; **2563 passed / 3 excluded en50,0 s**, seed30343/max_cases48,
  cero errores/desconexiones/avisos inesperados, cinco breaker deliberados.
  Formato/compile warnings-as-errors/diff correctos.
- Mesa19425: la misma pregunta de recuerdo de D181 sale exactamente como
  habla humana y recibe Lyra → Vex → DM → Mara en7,647 s. Tres runs de un
  paso (dos PCs y cierre DM), cero humano/TM/recorder/tools/dados. World entero,
  reloj36135, héroe/modelos iguales.13 eventos nuevos,395→408. Los dos
  compañeros reciben el habla literal; Vex añade un encabezado de turno que
  scrub retira, conservando el contenido. Clean=persistido para todos.
- Reinicio público conserva World/historial/actor/intenciones/hero/modelos/
  ajustes de todos los roles, cierra cinco auxiliares y no añade eventos al
  reanudar/pausar. UTF-8/JSON válidos; reload375/1440 px/ficha/compañeros por
  teclado sin JS/overflow, cuatro capturas revisadas. Hook retirado y Show
  restaurado exactamente. Evidencia privada: `pc-literal-speech-verification.json`.
- Se elimina una petición humana real respecto al flujo anterior; una muestra
  no certifica latencia general. La captura live sigue siendo Server.history,
  sin system efímero; TestModel comprueba las peticiones efectivas.408 eventos
  superan400, pero el combate aún permanece en el contexto: no acredita memoria
  de hechos ya expulsados. El DM vuelve a cuenco/postigos/tarde; continúa ese
  pulido y la campaña larga. Beta sigue abierta; sin hardware físico/Safari.

### Resultado íntegro de los dados en el contexto de los agentes (D181), 2026-10-03

- History ya distingue `crit` de `hit`, reconoce `fail` y conserva que
  `crit_fail` son dos fallos de salvación de muerte. Antes reducía los dos
  críticos de Vex a «¡ACIERTO!», omitía el fallo normal de muerte y reducía
  su fallo doble a uno genérico. No calcula reglas desde el d20 ni modifica
  tiradas, PG, recursos, eventos guardados o formato de la mesa.
- Tres casos usan Actions/RollLog reales, claves átomo y JSON: ataque/daño
  crítico, muerte con uno/dos fallos, acierto/éxito/revivir ordinarios.
  Un Game entrega los dos críticos antiguos a ambos agentes, con su prefijo
  propio en la petición efectiva, y conserva World/eventos al reiniciar sin
  nuevas tiradas. El fixture ahora detiene su Game de ExUnit antes del
  reinicio público y exige un PID distinto. Control negativo1/4;78
  focalizados en1,9 s; **2557 passed / 3 excluded en49,2 s**, seed30343/
  max_cases48, cero errores/desconexiones/avisos inesperados, cinco breaker
  deliberados. Formato/compile/diff correctos.
- Mesa19425: dos preguntas al grupo dan una intervención propia a cada PC
  y cierre DM, en orden Lyra/Vex y después Vex/Lyra.11,791/9,664 s, cuatro
  runs/un paso cada uno, sin TM/recorder/tools/dados. World entero idéntico,
  reloj36135 y héroe/modelos iguales. Historial compartido pasa de acierto
  genérico a crítico explícito; ambos PCs recuerdan el crítico en la segunda
  respuesta. Preguntas distintas: no es comparación causal de latencia.
- Reinicio conserva World/historial/actor/intenciones/hero/modelos/ajustes
  de todos los roles y cierra cinco auxiliares antiguos. UTF-8/JSON, reload
 375/1440 px, ficha/compañeros/teclado sin JS/overflow; seis capturas revisadas.
  Hook retirado y Show restaurado exactamente. Evidencia privada:
  `history-roll-outcome-verification.json`.
- La captura live de mensajes es Server.history convertido, sin el prefijo
  system efímero del request; la entrega efectiva del prefijo se verifica
  con TestModel.395 eventos siguen dentro de la ventana400: no demuestra
  memoria ilimitada ni semántica general. El narrador humano repite una
  jarra añadida a preguntas informativas y el DM repite cuenco/postigos/tarde:
  continuar esos casos. Beta sigue en preparación; sin hardware físico/SLA.

### Presupuesto del coordinador comprobado hasta la petición real (D180), 2026-10-03

- TurnMaster usa 1024 tokens por petición, configurable mediante
  `DRAGONEX_TURNMASTER_MAX_TOKENS`: entero positivo; vacío/inválido conserva
  el valor por defecto. La opción explícita del constructor tiene prioridad.
  Bootstrap ya no fuerza256. Se conservan modelo, routing, temperatura,
  tres pasos, primera decisión terminal y fallback determinista.
- Cuatro peticiones aisladas con el proveedor real alternan256/1024, sin
  modificar la mesa. Una de las dos muestras256 termina por longitud sin
  tool; una1024 decide con259 tokens. Ambas1024 deciden. Es evidencia del
  corte observado, sin garantía estadística ni diagnóstico de sus tokens
  internos de razonamiento.
- Mesa19425: pregunta literal a Maribel vuelve en8,13 s con un run DM/un
  paso, cero humano/TM/recorder y World idéntico. Después, una espera15 s
  vuelve en9,667 s con un run DM/dos pasos y un TM que decide correctamente;
  reloj36120→36135 una sola vez. Solo cambian reloj y reserva de espera.
  Escena/hechos/recursos/modelos iguales. La aclaración no confirma la
  veracidad del PNJ ni registra un testimonio nuevo.
  La espera también realiza una revisión de escena de4,261 s que conserva
  su descripción. Auditoría posterior: WorldClock marca revisión al avanzar;
  D172 exige confirmar frente al comprobante/estado/eventos y revalidar al
  guardar. Bootstrap ya usa el summarizer barato. Conservar esta protección
  al ampliar mediciones; no descartar la llamada solo por el resultado igual.
- Dos reinicios conservan World/historial/intenciones/actor/modelos y cierran
  cinco auxiliares antiguos cada uno. El segundo conserva presupuesto1024,
  UTF-8/JSON y reloj36135. Reload/teclado/fichas a375/1440 px, sin errores JS
  ni overflow; seis capturas revisadas. Instrumentación privada retirada.
- Cuatro casos nuevos; control negativo con el constructor/Bootstrap
  anteriores pasa1/4. Final77 focalizados en2,3 s y **2553 passed / 3 excluded**
  en50,2 s, seed30343/max_cases48: cero errores/desconexiones/avisos
  inesperados, cinco breaker deliberados. Formato/compile/diff correctos.
  Evidencia privada: `turnmaster-budget-verification.json`. Sin SLA,
  dispositivos físicos ni certificación de beta.

### Mesa intermedia y horizontal, controles alcanzables y ficha de combate (D179), 2026-10-03

- La mesa compacta alcanza 1023 px; desde 1024 conserva tres columnas.
  Entre 721–1023 px el texto tiene un máximo de 72ch. En horizontal con
  altura ≤600 px, la ficha ocupa un lateral de 240 px y no reduce la altura
  de la crónica ni oculta la entrada. La sala de espera conserva su corte.
- La barra puede distribuirse en filas y desplazar sus controles. TurnControls
  revela el botón entero al recibir foco, incluyendo Invitar a 375 px.
  Los controles táctiles tienen al menos 44×44 px. La ficha propia de combate
  ya no coincide con la regla que oculta duplicados; muestra PG/CA antes
  de raza y clase para que quepan también en el lateral corto.
- Chrome verifica ocho tamaños entre 375–1440 px y cuatro casos táctiles
  emulados de exploración/combate: teclado, abrir/reabrir ficha, compañeros,
  ajustes/cancelar, entrada, iniciativa y ausencia de overflow-x/errores JS.
  Siete capturas revisadas. SQL de solo lectura compara las dos partidas
  completas antes/después: World, actor, estado, ronda, intenciones e historial
  iguales; reloj de 19425 sigue en 36120. Sin dispositivos físicos probados.
- 39 focalizados en 5,9 s y gate **2549 passed / 3 excluded** en 48,2 s,
  seed30343/max_cases48: cero errores/desconexiones/avisos inesperados,
  cinco avisos deliberados del breaker. Formato, compile y diff correctos.
  El detector señala seis patrones CSS anteriores, conservados en el diseño
  D84; ninguno introducido por este cambio. Evidencia privada en
  `responsive-table-verification.json`. No certifica beta ni continuidad IA.

### Ficha móvil propia al abrir, sin perder la lectura al actualizar (D178), 2026-10-03

- Ficha propia precede a compañeros en el orden DOM del cajón. PlayerSheets
  vuelve al inicio solo en la transición cerrado→abierto; actualizaciones
  de borrador/mesa mantienen scroll y el desplegable nativo de compañeros.
  Teclado/nombres accesibles/estado expandido siguen operativos. Sin campos
  World, peticiones IA, cambios de CSS/identidad visual ni escritor adicional.
- Chrome19425 a375/720 px reproduce PG propios fuera del área visible tras
  desplegar compañeros/cerrar/reabrir. Reordenar solo no basta: conserva
  scroll209/151 px. El hook final deja scroll0 y PG14/14 visibles; escribir
  y retirar un borrador conserva la posición, compañeros siguen abiertos.
 721/1024/1440 px conservan fichas de escritorio; DM375 conserva Grupo3.
  Consulta SQL de solo lectura verifica World/actor/estado/ronda/intenciones/
  historial iguales, reloj36120. Cinco capturas revisadas, sin JS/overflow-x.
  La estrechez/controles recortados de721 px queda pendiente explícita.
- **41** focalizados en5,2 s; **2549/3 en49,3 s**, seed30343/max_cases48,
  sin errores/desconexiones/avisos inesperados; cinco deliberados breaker.
  El primer gate49,4 s descubrió un script anti-repeat que seguía tras sus
  tres respuestas; oráculo reforzado reproduce0/1 con una cuarta voz fallback.
  Ahora pausa antes de liberar la tercera respuesta DM, separa modelo PC y
  comprueba exactamente tres voces/World/DB, sin parchear producto/dependencia.
  Compile/formato/diff y detectores de los dos targets UI correctos.
  `mobile-sheet-{before,after,final,wide,verification}.json` privado.

### Preguntas sobre lo visto u oído sin reformulación humana (D177), 2026-10-03

- Amplía únicamente los inicios informativos de D167 con viste/oíste/
  escuchaste y tú opcional. Se conservan destinatario cualificado, pregunta
  única, prefijo/espera pasiva, actor manual y cola vigente; acciones extra,
  persuasión y destinatarios/gramática no reconocidos siguen ruta habitual.
  No hace actuar a PCs ni determina la veracidad de la respuesta PNJ.
- Tres casos nuevos (dos Text, uno LiveView) verifican palabras exactas,
  controles negativos y respuesta PNJ con testimonio/DB/reload sin gastos.
  Los fixtures D176 reciben ahora primero al DM; su checkpoint/replay/
  compacción sigue cubierto. El caso mixto False Life se ejecuta con pregunta
  abierta y «¿Viste…?»: conserva casilla, dado y5 PG temporales.
  Rojo1/3 por reformulación;32 focalizados en1,7 s. **2549/3 en49,6 s**,
  seed30343/max_cases48, cero errores/desconexiones/avisos inesperados;
  cinco deliberados breaker. Compile/formato/diff correctos.
- 19425/modelos conservados: «¿Oíste tú misma…?» se publica literalmente;
  DM registra atribución y responde en4,538 s. Una ejecución/dos pasos DM,
  ninguna humana/TM/recorder; reloj36120, escena/revisión/recursos/biblioteca
  iguales. Restart conserva World/historial/intenciones/modelos/UTF-8/JSON
  y cierra cinco auxiliares. Reload375/1440 px/teclado sin JS/overflow;
  cuatro capturas revisadas, hook retirado y LiveView restaurada exactamente.
  La respuesta añade una versión de conversación con el forastero: revisar
  continuidad, sin certificar semántica general ni benchmark de latencia.
  `npc-observation-verification.json`, `beta-latency-npc_observation-runtime.json`,
  `npc-observation-restart{,-browser}.json`.

### Testimonios de PNJ con fuente durable, sin confirmar su contenido (D176), 2026-10-03

- record_npc_statement(speaker, statement), solo DM, guarda «fuente afirma:
  contenido» en facts existentes: cap30/idempotencia, sin migración/campos
  nuevos. NPCStatement sanea ambos textos, normaliza Unicode/espacios y citas
  internas, limita fuente80/contenido800 y rechaza fuente PJ completa/corta,
  también con Unicode equivalente; un PNJ conocido con prefijo compartido
  conserva su identidad. No confirma la declaración ni ejecuta lo que cuenta.
  Actualiza memoria, conserva la marca de revisión anterior y no invalida
  por sí sola el entorno. Cambios físicos reales siguen por sus tools.
- Brief distingue verdad de atribución para DM/PC/TM. Prompt DM, respuesta
  PNJ y resúmenes recuerdan registrar información duradera con fuente/dudas,
  sin promover rumores a hechos objetivos. Text retira invocaciones de la
  tool escritas como prosa. Seleccionar/llamar correctamente sigue dependiendo
  del modelo; testimonios legacy no se reclasifican por inferencia.
- Diez casos nuevos (siete motor/tools, tres Game/compacción): límites,
  permisos/identidad/scrub, recursos/entorno intactos, checkpoint/replay/
  restart sin duplicación y fuente visible para DM/PC con diálogo compactado.
  Rojos0/6 inicial,0/1 escena,6/7 scrub y6/7 Unicode. **67** focalizados en1,0 s;
  **2546/3 en49,3 s**, seed30343/max_cases48, sin errores/desconexiones/avisos
  inesperados; cinco deliberados breaker. Compile/formato/diff correctos.
- 19425/modelos iguales: una declaración y una respuesta DM, testimonio
  «Maribel (tabernera) afirma…» guardado antes de narrar; fuente del relato
  y de la dirección diferenciadas. Reloj36120 y escena/fichas/recursos/
  biblioteca iguales; revisión limpia sin TM/recorder.7,605 s hasta humano.
  Restart/reload375/1440 px/ficha/compañeros por teclado conservan World/
  hechos/historial/modelos/UTF-8/JSON y cierran cinco auxiliares; sin JS/
  overflow, cuatro capturas revisadas y gancho retirado. Zagal/jarra y gestos
  del beat humano quedan en revisión, no se certifica coherencia semántica.
  `npc-statement-verification.json`, `beta-latency-npc_statement-runtime.json`,
  `npc-statement-restart{,-browser}.json`.

### Ritmo de esperas deliberadas sin avance de trama obligatorio (D175), 2026-10-03

- Game reconoce la espera mediante el mismo request D170 que obliga a resolver
  el reloj. Tras priorizar una conversación activa, selecciona guía de espera
  antes de las de atasco. Lee400 eventos como Beats y conserva los últimos40
  para las guardas existentes. El prefijo DM aclara que esperar es decidir;
  la guía de agencia condiciona cambios del entorno en vez de exigirlos.
  Reloj relativo no implica hora del día. Interrupciones, tools, guardas,
  estilos y avance de escenas realmente atascadas conservan su alcance.
- Cuatro casos Game/control nuevos: messages del proveedor antes/después de
  advance_time, escena/hechos/recursos conservados, interrupción5 s y restart,
  restart antes de resolver con voz/intervalo únicos y guía normal/atascos
  preservada. Rojo1/3 antes de implementar;25 y46 focalizados en1,7 s; siete
  tras ajustar la última frase de agencia en0,5 s. Gates **2536/3 en47,9/
  48,8 s**, seeds30343/944912/max_cases48, sin errores/desconexiones ni avisos
  inesperados; cinco deliberados breaker. Compile/formato/diff correctos.
- 19425/modelos iguales:15 s dos veces con fuentes distintas, reloj
  36090→36105→36120, hechos/escena/recursos/biblioteca iguales. Guía nueva
  comprobada en prompt real; DM2 en cada recorrido, TM1 fallido/2 completo,
  recorder3,855/3,623 s. Escena idéntica confirmada y revisión limpia, sin
  petición humana/dados/gasto. Reinicios/reloads375/1440 px/teclado preservan
  World/historial/modelos/UTF-8/JSON, cierran cinco auxiliares cada uno; sin
  JS/overflow, capturas revisadas, ganchos retirados. La muestra inicial
  conserva «tarde» del historial previo; no repara afirmaciones anteriores.
  `wait-pacing-verification.json`, `beta-latency-wait_pacing{,_final}-runtime.json`,
  `wait-pacing{,-final}-restart{,-browser}.json`. Beta sigue en preparación.

### Cierre de LiveViews de prueba después de sus consultas (D174), 2026-10-03

- La traza atribuye cliente/Game/owner al caso de ficha y recarga del druida;
  el owner se detiene después del Game. `Test.LiveViewFixture`, importado por
  ConnCase, conserva los resultados originales de live/live_isolated/
  follow_redirect y registra un supervisor de cierre después del canal.
  GenServer.stop espera el callback/SQL vigente; una navegación ya terminada
  es inocua, un timeout con vista viva sigue siendo un fallo visible.
- Dos pruebas nuevas retienen una consulta real con un advisory lock de
  PostgreSQL: el cierre espera, la consulta devuelve su conexión y el snapshot
  en cola conserva World/historial/estado pausado. Cerrar una vista deja viva
  otra del mismo Game. El contador TMSpy se supervisa antes del Game para
  sobrevivir a sus últimas peticiones. No cambia el motor ni el flujo real.
- Rojo0/1 sin supervisor de cierre; **34** focalizados en6,7 s y **45** con
  TurnMaster en7,1 s, sin errores/avisos. Gates **2532/3 en48,0/48,2 s** con
  seeds944912/30343/max_cases48, sin errores/desconexiones/avisos inesperados;
  cinco avisos deliberados breaker. El gate intermedio49,0 s queda conservado
  con el fallo de contador que motivó su corrección. Compile con
  warnings-as-errors, formato y diff correctos. El servidor existente responde
  HTTP200; esta entrega solo modifica infraestructura y fixtures de prueba.
  `live-view-shutdown-verification.json` y logs
  `dragonex-live-view-shutdown-{focused-final,and-spy-focused,full,full-second,full-final}.log`.
  Beta sigue en preparación: continuidad narrativa PNJ y latencia pendientes.

### Guía de entorno físico sin duplicar el diálogo PNJ (D173), 2026-10-03

- SceneRecorder distingue referencia del lugar/objetos/condiciones físicas
  de resumen del último turno. Recibe instrucciones de omitir diálogo, ofertas,
  rumores y gestos pasajeros del PNJ, conservar contexto físico establecido y
  no inferir objetos/cantidades/consumo por el paso del tiempo. No borra el
  historial ni sustituye facts. Schema, tools, guardas y single-writer siguen
  siendo los mismos; la calidad semántica del texto depende del modelo.
- Un smoke Game/TestModel nuevo verifica esas instrucciones en messages del
  proveedor, registro físico, diálogo completo una vez,120 s/recursos/DB/Codec
  y restart sin pérdida. Primer rojo0/1; **27** focalizados en0,7 s; gate
  **2530/3 en47,9 s**, seed944912/max_cases48. Limpieza SQL descrita arriba;
  compile con warnings-as-errors, formato global y diff correctos.
- 19425/modelos iguales: espera30 s una vez,36060→36090,21,956 s hasta humano,
  DM2/TM2/recorder1 de5,576 s, cero petición humana/dados/gasto. La escena
  omite pregunta/oferta y baja915→662 caracteres; conserva detalles transitorios
  e información de consumo previa. No demuestra compresión ni coherencia
  semántica general. La nueva información del forastero queda solo en historial.
  Restart/reload375/1440 px/ficha/compañeros por teclado conservan World/
  comprobante/historial/modelos/biblioteca/UTF-8/JSON y cierran cinco auxiliares;
  sin JS/overflow, capturas revisadas y gancho retirado.
  `scene-environment-{verification,prepare,restart,restart-browser}.json`,
  `beta-latency-scene_environment-{runtime,browser}.json`.

### Confirmación de entorno idéntico tras una espera aislada (D172), 2026-10-03

- El comprobante del intervalo añade una huella SHA-256 del World anterior
  solo si su escena estaba revisada. Excluye reloj, marca de revisión y
  comprobantes; incluye hechos, escena, recursos y demás estado. Codec conserva
  la huella válida; si es inválida, retira solo esa clave y preserva el reloj
  ya resuelto. Legacy no adquiere una huella inventada.
- SceneRefresh acepta confirmación idéntica únicamente con fuente/duración/
  reloj del intervalo y estado coincidentes. Game revalida el snapshot al
  aplicar y limpia solo la marca pendiente, sin reescribir escena/log/recursos.
  Cambios de hechos, recursos, escena, tiempo adicional o revisión previa
  conservan el rechazo. La recuperación reconoce el intervalo aunque el DM
  ya haya publicado su final; no repite narración ni tiempo.
- Diez casos nuevos, **53** focalizados en1,7 s/seed181952. Gate final
  **2529/3 en47,6 s**, seed944912/max_cases48; incidencias de limpieza/fixture
  descritas arriba. Traza serial55,2 s sin esos errores. Compile con
  warnings-as-errors, formato global y diff correctos.
- 19425/modelos iguales: esperas naturales de dos/un minutos vuelven en
  13,246/18,890 s;120/60 s DM una vez, sin petición humana ni dados/gasto.
  Recorder4,904/4,914 s actualiza ambas descripciones; no prueba la rama idéntica
  con proveedor ni una mejora general de latencia. Revisión legacy previa
  5,927 s actualiza escena sin aplicar tiempo. Dos reinicios conservan World/
  comprobante/historial/cursor/modelos/biblioteca/JSON y cierran cinco auxiliares
  cada uno. Reload375/1440 px/ficha/compañeros por teclado sin JS/overflow;
  capturas revisadas y ganchos retirados. `wait-scene-verification.json`,
  `wait-scene-{legacy-review,restart,restart-browser}.json`,
  `wait-scene-same-{restart,restart-browser}.json`,
  `beta-latency-wait_scene{,_same}-{runtime,browser}.json`.

### Declaraciones pasivas de espera sin reformulación humana (D171), 2026-10-03

- Una espera pasiva literal publica las palabras saneadas del jugador por
  Events, sin una petición al modelo humano. Conserva acción/metadatos/turno/
  historial y relevo DM; esa declaración no confirma tiempo transcurrido.
  El DM sigue sujeto a D170 para resolver duración/interrupción por el motor.
- Gramática acotada: espera/aguardo o permanencia, cantidad/unidad y ubicación
  pasiva reconocida. Formulaciones mixtas, hechizos, preguntas y condiciones
  conservan el beat humano; combate/autoplay/conversaciones/mini e interrupciones
  conservan sus controles. No se filtran tools legítimas para ahorrar peticiones.
- Siete casos nuevos: tres de gramática y cuatro Game sobre peticiones/voz
  original/recursos, restart antes del reloj, hechizo mixto con casilla/dados y
  cola pausada sin publicación anticipada. **29** focalizados en1,2 s; gate
  **2519/3 en47,0 s**, seed944912/max_cases48, sin errores/desconexiones;
  cinco avisos esperados del breaker. Compile/formato/diff correctos.
- 19425/modelos conservados: «Espero tres minutos junto a la barra.» vuelve
  en17,884 s, cero peticiones humanas, DM180 una vez y reloj35700→35880.
  PG/casillas/descansos/biblioteca intactos y cero dados. Dos peticiones DM,
  TM agota tokens con fallback y recorder3,853 s; las incidencias de arriba
  siguen abiertas. Reinicio conserva estado/comprobante/historial/modelos y
  cierra cinco auxiliares. Reload375/1440 px y compañeros/ficha por teclado
  sin JS/overflow; capturas revisadas y ganchos retirados.
  `literal-wait-{verification,prepare,restart,restart-browser}.json`,
  `beta-latency-wait_literal-{runtime,browser}.json`.

### Resolución obligatoria y durable de esperas literales (D170), 2026-10-03

- La duración estaba en el historial, pero el DM podía cerrar sin tool. El
  motor reconoce una espera afirmativa con cantidad/unidad y guarda segundos
  y reloj inicial en la acción. Preguntas/planes/condicionales/retellings,
  múltiples intervalos, rests y viajes no activan este contrato.
- El DM recibe la declaración actual y segundos calculados por el motor.
  Su respuesta final/stream no se publican mientras falte resolución. Puede
  completar el intervalo o interrumpirlo con0..duración declarada; combate
  también interrumpe. Si agota el intento sin registrar tiempo, pausa con
  declaración durable y permite reanudar, sin dar la espera por terminada.
- World.resolve_wait conserva el último comprobante wait_resolution junto
  al efecto; Codec valida/carga ese mapa y admite legacy nil. Protege llamadas
  repetidas/simultáneas y recuperación después de una interrupción parcial,
  incluso sin actor_checkpoint. No cambia structs de fichas ni builder/DB.
- Dieciséis casos nuevos: gramática/legacy/JSON/límites, omisión/final válida,
  duplicados/parallel, interrupción0/60 s, pausa/reapertura y reinicio supervisado
  tras60 s. **27** focalizados en1,4 s; gate2512/3, con incidencia de limpieza
  descrita arriba. Compilación/formato/diff y navegador se verifican aparte.
- 19425/modelos iguales: espera natural de cinco minutos vuelve en32,603 s,
  avance DM300 una vez, reloj35400→35700, comprobante ligado al turno humano.
  Intento humano rechazado; sin dados y recursos/biblioteca intactos. Cambian
  reloj/comprobante/facts/log/escena. Nuevo fact conserva el rumor ya narrado.
  Recorder10,567 s; no se presenta como mejora de latencia ni de originalidad.
- Reinicio real conserva World/comprobante/historial/cursor/intenciones/modelos,
  cierra cinco auxiliares y verifica UTF-8/JSON. Reload375/1440 px/fichas/
  compañeros por teclado sin JS/overflow; capturas revisadas, ganchos retirados.
  `wait-resolution-{prepare,restart,restart-browser}.json`,
  `wait-resolution-verification.json`,
  `beta-latency-wait_required-{runtime,browser}.json`.

### Verificación de beats completos en fixtures anteriores, 2026-10-03

- Tres casos WorldFacts esperaban solo un efecto parcial; el caso de escena
  podía pasar con la escena inicial porque ya carecía de `3/7`. Ahora esperan
  el turno humano, pausan y comprueban el cambio positivo, saneamiento,
  persistencia y ausencia de notas de fallo. El modelo de registro es propio.
- Dos casos de intenciones/reacción esperaban antes de finalizar el beat y
  reutilizaban texto del goblin para Lyra. Ahora verifican su respuesta completa
  con pausa antes de liberarla. Escudo consume una casilla y aumenta CA efectiva
  12→17 conservando base12; World y DB coinciden.
- Un caso antibucle agotaba el guion DM tras la comprobación. DM y PC reciben
  modelos distintos; se verifican exactamente tres respuestas PC diferentes
  y el beat terminado, sin fallback ni nudge. No cambia el motor ni silencia logs.
- Tres casos de narración DM separan también el PC del guion del narrador y
  terminan el beat antes de comprobar recorte/reminder/entorno legítimo.
  Son **nueve** fixtures reforzados, sin cambios de reglas de producto.
- **38** focalizados en2,0 s, seed207258, sin errores ni avisos. El control
  negativo de escena falla al retirar set_scene. El gate previo2496/3,
  seed30343/46,9 s, mostró el agotamiento que motivó el ajuste antibucle.
  El posterior2496/3,46,8 s, descubrió dos agotamientos de narración DM.
  **Gate final2496/3 en48,0 s, mismo seed30343**: cero errores, desconexiones
  o avisos inesperados; solo cinco avisos del breaker con errores400 simulados.
  Compile con warnings-as-errors, formato global y diff correctos; HTTP200,
  sin ganchos QA. La investigación Postgrex anterior sigue abierta.
  Evidencia: `dragonex-world-facts-missing-scene-red.log`,
  `dragonex-test-completion-fences-focused-final.log`,
  `dragonex-meal-iteration-full-completed-beats.log`; desglose documentado en
  el protocolo de pruebas.

### Compresión de historial que conserva Unicode (D169), 2026-10-02

- Fallo real19425 antes del proveedor: al envejecer la pregunta del menú,
  History corta el byte0xC2 del signo ¿. La entrada ya estaba saneada; el
  patrón de primera frase contaba bytes y su clase con ¡ también admitía ese
  byte líder. La sanitización anterior no protegía este recorte posterior.
- Regex Unicode con terminadores reales .!? conserva caracteres y atribución;
  sigue comprimiendo solo mensajes antiguos y mantiene doce recientes completos.
  Sin borrar conversación ni resanear el resultado para ocultar el corte.
- Tres rojos/tres casos nuevos: fixture exacto, ¿/¡/espacio inseparable y JSON
  del proveedor, más Game que cruza el umbral, aplica1200 s/escena y reinicia
  sin repetirlos. **18** focalizados; **2496 passed / 3 excluded**,47,1 s,
  sin errores ni desconexiones; avisos de ejecución descritos arriba.
  Compile/formato/diff correctos.
- Misma mesa/modelos: la siguiente respuesta DM6,6 s ya no falla al codificar.
  Omite el reloj (incidencia arriba); confirmación explícita20,451 s registra
  34200→35400, solo reloj/log/escena cambian, cero dados y recursos/biblioteca
  intactos. La llamada humana a advance_time se rechaza; solo DM la confirma.
  Recorder3,699 s, nuevo entorno con cuenco vacío. No se suman dos intervalos.
- Restart mantiene World/historial/cursor/intenciones/modelos, JSON/UTF-8 válidos
  y cierra cinco auxiliares. Reload375/1440 px/teclado sin JS/overflow, capturas
  revisadas y ganchos retirados. Siete dados históricos preservados; ninguno
  en ventana reciente. `meal-choice-{verification,restart,restart-browser}.json`.

### Voz propia en respuestas de compañeros (D168), 2026-10-02

- Comida real19425: Mara→Lyra→Vex→DM→Mara en11,739 s, World igual y sin TM;
  Vex copia casi toda la frase/gesto de Lyra, cambiando bastón por arco.
  Identidad/agentes/historial están entregados; faltaba distinguir el historial
  compartido de un guion en la instrucción específica de respuesta.
- PCAgent recuerda su personalidad de clase junto a esa pregunta y permite
  coincidir usando palabras propias, sin copiar gestos ni inventar desacuerdo/
  hechos. Solo responde el destinatario pendiente; caído/combate/turno normal
  conservan su contrato. No filtra acuerdos ni genera peticiones adicionales.
- Tres casos nuevos, dos rojos iniciales y**39** focalizados. Game verifica
  messages reales codificados, rol/voz, historia anterior intacta, cuatro actores
  una vez y recursos iguales; fixtures conservan incluso el acuerdo/copia real.
  Gate2493/3 en47,4 s, sin errores/desconexiones; ocho avisos de ejecución
  descritos arriba. El gate final D169 también cubre esta entrega.
- Nueva pregunta19425/modelos iguales:10,198 s, cuatro voces propias y World/
  reloj34200/biblioteca intactos, sin TM/recorder/tools/dados. Lyra quiere noticias
  del pueblo; Vex coincide con formulación propia. Guía entregada a ambos agentes;
  no certifica creatividad general ni una comparación de latencia entre preguntas.
  Reload375/1440 px/fichas/compañeros por teclado verificados en ese recorrido.

### Publicar preguntas informativas PNJ sin reformularlas (D167), 2026-10-02

- Las trazas D166 dedican una petición del modelo a reformular una pregunta
  humana ya explícita. Con Conversation PNJ coincidente en exploración manual,
  una gramática acotada reconoce solo interrogante informativo y espera pasiva.
  Publica ese interrogante con Events/Text.scrub, sin consultar al modelo humano;
  conserva acción original, marcador, liquidación, cola DM y retorno habitual.
- Acciones adicionales, persuasión/peticiones, prefijos inciertos, combate,
  autoplay y mini-turnos conservan su resolución. No hay parser general ni
  cambios de World/structs/migraciones. No amplía la garantía de caída sin
  comprobante D164 a la ventana publicación→relevo del humano.
- Siete casos nuevos: reconocimiento/scope, primera petición realmente al DM,
  historia exacta, restart con DM esperando y formulario/reload LiveView. Una
  pregunta con False Life mantiene resolución humana, casilla/dado únicos y
  PG temporales5. Cinco rojos iniciales; **69** focalizados, **2490 passed /
  3 excluded**,47,6 s ordinario limpio. Compile/formato/diff correctos.
- Misma mesa19425/modelos: pregunta sobre la invitación vuelve en4,536 s,
  solo una petición DM (3,911 s), sin humano/TM/recorder/tools/dados. Maribel
  confirma guiso/pan/jarra gratuitos, vino/licor aparte; no se cobra ni se
  decide consumir por el grupo. World/reloj34200/recursos/biblioteca iguales.
  Muestras de preguntas distintas; acredita una petición eliminada, sin SLA.
- Restart conserva World/historial/cursor/intenciones/modelos por rol y cierra
  cinco auxiliares. Reload375/1440 px/fichas/compañeros por teclado sin JS/
  overflow; capturas revisadas, ganchos retirados. Siete dados históricos
  preservados, uno en ventana reciente. `npc-literal-speech-{verification,
  restart,restart-browser}.json`. Continuar la elección/servicio de comida
  con voces propias IA y datos narrativos durables; revisar esperas restantes.

### Registrar cambios locales omitidos en exploración (D166), 2026-10-02

- Traza real19425: preguntar a Maribel conserva World y vuelve en8,657 s,
  sin TM. Entrar en la taberna tarda15,713 s: narraciones6,5 s y TM8,7 s;
  ambos describen el interior, pero World sigue en la plaza. Sin tiempo/facts/
  fase nuevos ni set_scene, el registro D145 no se solicitaba.
- Una declaración humana de movimiento literal guarda la escena anterior en
  su evento de acción. Tras DM, si esa escena sigue vigente, la declaración
  corresponde al turno actual y no hay conversación/mini/autoplay ni un
  set_scene confirmado del DM, se solicita la instantánea D145 sin tools de
  reglas. Una escena ya registrada por el humano también evita la consulta.
- Confirmar el mismo entorno no escribe World ni log; solo se admite cuando
  no había cambio del motor pendiente. Un fallo deja pendiente durable sin
  repetir texto/reglas. Game sigue validando el World esperado antes de aplicar.
  Sin campos nuevos de World, migraciones, coordenadas ni cálculo de viajes.
- Seis rojos iniciales; once casos nuevos con los textos reales, scope,
  confirmación, fallo/reapertura y registro humano/DM ya aplicado. El gate
  descubre ese caso humano y se añade su regresión. **68** focalizados;
  **2483 passed / 3 excluded**,54,4 s trazado limpio. Compile/formato/diff
  correctos. Las desconexiones del primer gate mantienen investigación arriba.
- Misma mesa/modelos: acercarse a la barra vuelve en22,895 s. DM no llama
  tools; registro estructurado en un paso/9,579 s corrige plaza→interior;
  solo escena/log cambian, reloj34200 y recursos/encargo/biblioteca intactos,
  cero dados nuevos. La pregunta del menú vuelve en5,026 s con World igual,
  sin TM ni registro extra. Son declaraciones distintas, sin benchmark/SLA.
- Restart mantiene World/historial/cursor/intenciones/modelos por rol y cierra
  cinco auxiliares. Reload375/1440 px/teclado sin JS/overflow y capturas
  revisadas; siete dados anteriores en crónica, uno en la ventana reciente.
  Ganchos retirados. `beta-latency-{verification,restart,restart-browser}.json`.
  Quedan reducir esperas con participación IA, otras formas de movimiento y
  continuidad: revisar la invitación gratis de Maribel frente al precio anunciado.

### Contexto operativo del reloj de exploración (D165), 2026-10-02

- Aventura real19425: la invitación recibe respuestas propias de Lyra/Vex y
  mantiene World; la marcha explícita de quince minutos llega al molino con
  escena nueva, pero conserva reloj32400. Raw DM solo llama set_scene. La
  herramienta de tiempo funciona; faltaba su obligación en el contexto DM.
- Brief añade solo para DM en exploración el contrato de advance_time para
  duración declarada realmente consumida, una vez y antes de narrar llegada.
  Escena no equivale a tiempo; preguntas, propuestas y duración orientativa
  de un camino no lo consumen. No repite tiempo ya aplicado ni el de rests.
  El motor conserva cálculo/caducidades; sin nuevos campos ni herramientas.
- Dos rojos de entrega del contrato en peticiones reales Game/TestModel;
  pruebas de viaje/caducidad y restart después del avance conservan900 s una
  vez, PG/casillas/rest_state. Un caso de scope DM/PC/TM/combate; tres nuevos,
  **35** focalizados. **2472 passed / 3 excluded**, 46,9 s limpio; compile/
  formato/diff correctos. La limpieza intermitente D163 no reaparece aquí.
- Misma mesa/modelos reales: confirma explícitamente el tramo anterior y
  registra32400→33300; la siguiente marcha llega a la plaza/taberna del Ciervo
  con33300→34200. Solo cambian reloj/log/escena; fichas, recursos, encargo,
  biblioteca y cero dados nuevos conservados. Restart y regreso al humano
  mantienen World/historial/modelos por rol; cinco auxiliares cerrados.
- Reload375/1440 px/fichas y compañeros por teclado sin JS/overflow, siete
  dados históricos conservados; capturas revisadas y ganchos retirados.
  `adventure-choice-{verification,restart,restart-browser}.json`,
  `dragonex-exploration-clock-*`. Invitación17,833 s, marcha inicial34,751 s,
  confirmación35,721 s y llegada47,54 s: datos individuales, sin SLA.
- La omisión inicial necesitó confirmación explícita; no se rellena historia
  retroactivamente. El modelo sigue eligiendo las tools: no se garantiza toda
  duración en lenguaje natural. Quedan latencia y relevo Vex/DM adicional tras
  llegada, además de recuperación incompleta y continuidad con la dueña.

### Recuperar la respuesta final ya publicada (D164), 2026-10-02

- Rojo: tras rechazar el cierre de un combate, resume y restart publican dos
  respuestas finales para el turno del golpe ganador. Events distingue una
  respuesta completa de las declaraciones con tools y de las respuestas
  truncadas/filtradas; conserva el texto saneado y el turno original.
- Si el comprobante durable del actor coincide y su respuesta completa ya
  existe, Beats retoma la liquidación sin consultar al modelo ni publicar de
  nuevo. Mantiene las intervenciones intermedias y el registro independiente
  de escena pendiente; eventos antiguos no se consideran comprobantes.
- Siete casos nuevos y cinco recuperaciones previas reforzadas; **49**
  focalizados. **2469 passed / 3 excluded**, 46,0 s sin errores/warnings;
  compile dev/formato/diff limpios. Dos expectativas antiguas de repetición
  del modelo pasan a verificar que la siguiente petición es un turno de
  monstruo legítimo, después de confirmar la iniciativa.
- VM19442: corte después de publicar la mañana y antes de registrar la escena;
  restart16,606 ms, cero peticiones nuevas al actor, descanso28800 s y sus
  límites intactos, dos intervenciones originales y un solo turno DM. Recupera
  la escena y vuelve a Thane; otra reapertura conserva World e historial.
  Reload375/1440 px y fichas por teclado sin JS/overflow; ambas capturas
  revisadas. Ganchos retirados, `narration-recovery-{runtime,browser}.json`.
- Alcance: respuesta completa con actor pendiente y comprobante válido.
  Repetición de declaraciones en intentos incompletos, actores sin comprobante,
  relevo posterior y RNG mantienen revisión propia. La incidencia intermitente
  de limpieza no reaparece en este gate, pero sigue sin causa demostrada.

### Cierre de combate confirmado con limpieza y notas (D163), 2026-10-02

- Rojo: rechazar la nota de fin o la de intención obsoleta deja Session en
  exploración aunque SQL revierte. Además, reabrir una derrota ya guardada
  puede esperar una acción sin cerrar el combate. Combat prepara fase/estados/
  intenciones/notas y los guarda juntos antes de Session/PubSub; fallo pausa
  conservando la fase, intenciones y comprobante anteriores para reintentar.
- Game liquida una victoria ya guardada antes de consumir una declaración,
  salvo que el actor necesite recuperar su comprobante y respuesta. Settlement
  conserva ese comprobante hasta confirmar el cierre. No repite el golpe ni
  sus dados; World limpia también la reserva de inicio al cambiar de fase.
- Siete casos nuevos: rechazo de ambas notas, resume/restart antes de una
  reacción obsoleta, recuperación antes del feedback y tras rechazo de cierre
  por resume/restart. Cuatro rojos principales;52 focalizados verdes.
  **2462 passed / 3 excluded**, gate con trazas53,6 s sin errores/warnings;
  compile dev/formato/diff limpios. Incidencia previa de limpieza arriba.
- VM19440 vuelve a exploración desde derrota guardada, borra solo intención
  de combate y conserva la de exploración, sin llamar al modelo ni tirar.
  VM19441 recupera golpe IA ganador antes de narrar: Goblin0, dos dados,
  turno original, notas de fin/limpieza una vez. Otra reapertura mantiene
  World/historial y no repite notas ni dados en ambas mesas.
- Adopción19425–19439 propias conserva World/historial/cursor/intenciones/
  relojes/modelos por rol, cierra56 auxiliares. Reload19440/19441 a375/1440 px
  y fichas por teclado sin JS/overflow; captura móvil revisada. `combat-end-
  commit-{runtime,paused-adoption,browser}.json`, `dragonex-combat-end-commit-*`;
  ganchos retirados. La narración y el relevo posterior no son parte de esta
  transacción; revisar sus ventanas de recuperación y continuar aventura real.


### Inicio de turno recuperable y dados completos (D162), 2026-10-02

- Rojo Postgres: rechazar el segundo grupo del aura deja daño/concentración
  aplicados en Session; la mesa puede detenerse con el primer dado publicado.
  Combat guarda `pending_turn` (nombre y tipo) antes de evaluar efectos. World
  candidato, todos sus dados y retirada del marcador se confirman juntos;
  solo entonces se actualiza Session/PubSub. Rechazo pausa con efectos intactos.
- Game reintenta ese marcador antes de cualquier actor/coordinador tras resume
  o restart. Codec valida nombre presente/tipo y admite eventos antiguos sin
  marcador. Conserva el enemigo concreto bajo controlador DM y las reacciones
  con su dueño principal; no cambia Character/Weapon/Spell/Item.
- Seis casos nuevos: rollback/publicación, resume, restart/segundo restart,
  slot DM con nombre, reacción y JSON/legacy inválido. Cuatro rojos iniciales,
  **82 focalizados** verdes; **2455 passed / 3 excluded** (45,4 s), sin errores
  ni avisos de compilación; compile dev/formato/diff limpios.
- VM19439 offline: corte con el roller esperando, después de reservar Cora y
  antes de devolver un dado; World durable aún Goblin100/concentración intacta,
  cero eventos de dados. El supervisor detiene solo esa mesa (5014,012 ms);
  restart aplica aura3/Goblin97, pierde concentración y publica save/damage/save
  una vez. El PC recibe97/100; cinco dados reales y otra reapertura sin tiradas.
- Adopción19425–19438 propias pausadas conserva World/historial/cursores/
  intenciones/relojes y modelos por rol, cierra52 auxiliares. Reload19439 a
  375/1440 px y fichas por teclado sin JS/overflow; captura de escritorio
  revisada. `dragonex-turn-start-commit-*`, `turn-start-commit-*`; ganchos retirados.
- El RNG no se revierte al rechazar una evaluación. La reserva exige escritura
  SQL disponible; no garantiza durabilidad mientras la base esté inaccesible.
  El cierre posterior del combate y las narraciones conservan revisión propia.

### Daño cero con su penalización real (D161), 2026-10-02

- La revisión móvil de D160 mostró `d4:1 -1 = 0` para FUERZA6 (modificador−2).
  El mínimo era correcto, pero el desglose reconstruía otro modificador.
  Actions conserva `raw_total` solo cuando el subtotal es negativo; RollLog
  lo lleva al jsonb. RollTotals comparte el cálculo entre crónica/modal e
  History: `d4:1 -2 = 0 (mínimo 0)`. Eventos antiguos sin subtotal mantienen
  su presentación; no se inventan ni se reescriben datos históricos.
- Cinco casos nuevos: buffer/JSON, presentación y tarjeta, metadatos inválidos,
  contexto del agente y PC/TestModel→Game→Postgres→LiveView/reload; además,
  la regresión de daño existente comprueba el subtotal. Rojo de cinco fallos,
  **50 focalizados** verdes; **2449 passed / 3 excluded** (44,3 s), sin errores
  ni avisos de compilación. Compilación dev final limpia; ganchos retirados.
- Mesa19438 offline: arma0/radiante4/Goblin6/casilla1, subtotal−1 guardado;
  restart antes del feedback conserva turno y efectos, sin nuevos dados.
  Retorno a Thane26,544 ms. Reload375/1440 px y fichas por teclado sin JS ni
  overflow; captura móvil revisada. `dragonex-damage-breakdown-*` y
  `damage-breakdown-{runtime,browser}.json`. No altera el motor ni el RNG.

### Iniciativa confirmada y daño mínimo (D159–D160), 2026-10-02

- D159 guarda World, todos los grupos de iniciativa y nota de apertura en una
  transacción antes de Session/PubSub. Rechazo del segundo INSERT revierte
  todo y pausa con comprobante para resume/restart sin duplicar spawn.
  Tres regresiones nuevas/26 focalizados; VM19436 confirma dos grupos una
  vez y recupera World/historial tras reiniciar.
- D160 limita el daño del mismo tipo a cero después de sumar sus bonos;
  Castigo divino conserva el radiante separado. Nueve regresiones, incluidas
  tools de PC/TestModel/Session;184 focalizados finales. VM19437 guarda arma0,
  radiante4/Goblin6/casilla1 antes del feedback y conserva todo al recuperar,
  sin nuevas tiradas ni gasto repetido. Retorno a Thane32,78 ms.
- Restablecido el acceso a sockets: **2444 passed / 3 excluded** (44,6 s),
  sin errores ni warnings. Una VM web nueva recupera las once mesas propias
  19425–19435 pausadas con World/historial/cursores/intenciones/relojes iguales.
  Modelos efímeros se toman de configuración vigente o TestModel explícito;
  no se acredita conservación de esos modelos tras detener la VM.
- Navegador19436/19437: reload375/1440 px, fichas propias/compañera por teclado,
  cero JS/overflow. `engine-damage-{cold-recovery,browser}.json`,
  `engine-roll-commit-runtime.json`, `negative-weapon-damage-runtime.json`.
  El inicio de turno, narraciones y rollback del RNG mantienen revisión propia;
  PubSub es best-effort. Estas entregas no acreditan por sí solas la beta.

### Pregunta literal al PNJ: respuesta y retorno reservado (D158), 2026-10-02

- Playtest19425: la posadera responde correctamente, World/biblioteca iguales,
  pero pasan unos9 s hasta el relevo; recorrido16,216 s. Rojo offline: el
  coordinador elige Lyra y añade otro ciclo antes del humano.
- Una pregunta humana literal a un rol PNJ cualificado registra una cola
  durable para DM→humano. Gramática acotada: «le pregunto a la posadera: ¿…?»
  o vocativo con artículo, prefijo espacial «desde…» y «antes de…, ¿…?».
  Menciones, planes, reportes citados, preguntas mixtas y combate mantienen
  su ruta. No expone una tool nueva ni cambia Character/World.
- Conversation/Codec admite world_recipient con destinatarios PC vacíos solo
  en etapas world/return; valida límites y sanitiza texto. Contextos DM/humano
  explican quién responde. Cola vieja PC, intervención humana, pausa/borrador
  y rechazo de sustitución por el modelo conservan sus contratos.
- **10 casos nuevos**, **55** focalizados; **2432 passed / 3 excluded**
  (43,5 s), cero errores/avisos de compilación, compile/formato/diff limpios.
  `dragonex-npc-question-*`.
- Misma19425/proveedor real: segunda pregunta a la posadera vuelve a Mara
  en8,143 s, solo voces Mara/DM; historia del coordinador sigue vacía.
  World completo/biblioteca iguales, cero dados, decisión de viajar abierta.
  DM raw trae etiquetas D7 que se guardan limpias. Reload375/1440 px/teclado
  sin JS/overflow. Son preguntas distintas, sin garantía de latencia global.
- Adopción19425–19435 propias pausadas conserva World/historial/modelos por
  rol/cursores/relojes y cierra41 auxiliares; ganchos retirados. `beta-npc-*` y
  `npc-question-paused-adoption`. Preguntas semánticas no reconocidas y grupos
  automáticos de dados fuera de tools siguen su revisión.

### Dados y efecto de la tool se confirman juntos (D157), 2026-10-02

- Rojo: Magic Missile publicaba un evento de dados mientras World aún era el
  anterior. ToolReplay asigna un RollLog por ejecución; los grupos quedan
  privados hasta guardar World/comprobante y eventos de dados en una misma
  transacción. Se publican después de aceptar también la Session.
- Los grupos de una tirada sin cambio de World se guardan con su resultado
  exitoso. Rechazo, corte previo o rollback no publica dados ni cobra recursos.
  Cada propuesta vacía solo su prefijo confirmado; salvaciones dentro del
  cambio funcionan sin pedir al Game una llamada a sí mismo.
- **10 casos nuevos**, **43** focalizados y **14** finales tras compatibilidad;
  **2422 passed / 3 excluded** (42,8 s), cero errores/avisos de compilación;
  compile/formato/diff limpios. Rollback Postgres real mediante constraint
  temporal, restart/:kill, rechazo, concentración y tirada DM sin efectos.
  `dragonex-tool-roll-commit-*`.
- VM19435 offline: preparación conserva World/cero eventos o publicaciones;
  efecto+comprobante+un grupo guardados, corte antes del feedback/restart
  conserva casilla1, Goblin14/20, marcador/turn_id originales. Humano27,299 ms.
  Reload375/1440 px/teclado y una entrada de dados, sin JS/overflow.
- Adopción19425–19434 propias pausadas conserva World/historial/modelos/
  cursores/relojes, cierra37 auxiliares. Guion inicial falló por segunda pausa;
  mesa19434 conservada como fixture separado, comprobación completa19435.
  Ganchos retirados. `tool-roll-commit-*`.
- La garantía cubre las tools anunciadas en beats de actor. Narración, tiradas
  standalone e iniciativa/efectos automáticos fuera de esas tools conservan
  sus caminos; no acredita atomicidad de todos los eventos ni rollback del RNG.

### Los hechos durables también respetan la agencia de PCs (D156), 2026-10-02

- El fixture de consenso rechazado por set_scene aún entraba por establish_fact:
  rojo con «hecho registrado». La tool ahora comprueba el mismo roster/actor
  antes de proponer. No registra acciones ajenas/grupo; conserva hechos PNJ,
  grupos cualificados, citas y acción propia. Sanitiza antes de validar/guardar.
- **5 casos nuevos**, **39** focalizados; **2412 passed / 3 excluded**
  (42,5 s), cero errores/warnings; compile/formato/diff limpios.
  Cuatro casos standalone sin DB y el bypass del fixture vía Game/Postgres.
  `dragonex-fact-agency-*`.
- VM19433 offline: rechaza consenso, acepta mapa PNJ corregido en el mismo
  beat, actualiza escena factual y devuelve control a Thane en31,705 ms.
  Mecánicas completas iguales, cero dados, World/historial iguales tras restart.
  Reload375/1440 px/ficha/compañeros por teclado sin JS/overflow.
- Adopción19425–19432 propias pausadas conserva World/historial/modelos/
  cursores/relojes, cierra28 auxiliares; ganchos retirados. `fact-agency-*`.
  Misma gramática acotada de Text; no acredita procedencia semántica de cada
  hecho ni amplía las garantías de atomicidad de dados/eventos.

### Consenso y gesto plural conservan la decisión del jugador (D155), 2026-10-02

- Playtest19425: Lyra/Vex responden en25,431 s, World/biblioteca iguales, pero
  DM raw afirma «La decisión queda tomada entre vosotros…» pese a esperar la
  decisión humana. La narración humana persistida añade «y os miráis un momento».
  Ambos textos exactos se conservan como fixtures. Text corta consenso pasivo
  ligado a vosotros/vosotras y el gesto plural acotado, conservando pregunta
  propia, entorno y voces PNJ/PC. Streaming/Events/historial comparten filtro;
  set_scene rechaza antes de World. Instrucción DM devuelve la decisión humana.
- **9 casos nuevos**, **46** focalizados; gate final **2407 passed / 3 excluded**
  (49,4 s, trace/max_cases48), cero errores/warnings, compile/formato/diff limpios.
  Preguntas, planes, grupos PNJ, citas completas/abiertas, PC solo y puntuación
  irregular no se convierten en acciones impuestas. `dragonex-group-decision-*`.
- Adopción19425 pausada conserva World/historial/modelos, cierra5 auxiliares.
  Nueva pregunta a Lyra/Vex vuelve a Mara en12,137 s: ideas propias, decisión
  abierta, World completo y biblioteca iguales. Raw de Lyra lleva etiquetas
  D7, retiradas antes de guardar; Vex/DM coinciden con lo persistido. Reload/
  fichas/compañeros por teclado375/1440 px sin JS/overflow. `beta-decision-*`.
- Ganchos retirados; historial anterior conservado. No se certifica consenso
  semántico general ni se atribuye la diferencia de latencia solo al filtro.

### Guardar el comprobante junto al efecto antes de responder (D154), 2026-10-02

- Se reproduce la ventana D153 bloqueando una tool después de guardar magia
  y antes de devolver su texto: restart gastaba otra casilla. El wrapper
  identifica cada ejecución; RuleCheckpoint incluye un comprobante saneado
  en el mismo World que su efecto. Game conserva la posición de ese resultado;
  la respuesta final lo sustituye sin añadir otra entrada. Si no llega, el
  actor recuperado recibe el comprobante y consulta World/tiradas vigentes.
- Varias propuestas de una ejecución comparten comprobante; dos llamadas
  originales siguen siendo dos. Un rechazo sin cambio no crea uno. No cambia
  Character/Codec ni evalúa reglas en el LLM. API pública de Game conservada.
- **5 casos nuevos**, **29** focalizados; **2398 passed / 3 excluded**
  (41,8 s), cero errores/warnings, compile/formato/diff correctos.
  Restart/:kill antes del resultado, sustitución precisa, varias propuestas y
  rechazo corregido. `dragonex-effect-checkpoint-recovery-*`.
- VM19432 offline interrumpe exactamente antes de devolver la tool. Efecto y
  comprobante guardados, pedido anterior cerrado, una casilla/daño6/un grupo,
  marcador y turn_id originales; actor recibe comprobante tras restart y
  Thane recupera control en29,673 ms. Reload375/1440 px/ficha/compañeros por
  teclado sin JS/overflow. Adopción19425–19431 conserva World/eventos/modelos/
  cursores/relojes y cierra24 auxiliares. Ganchos retirados.
- Cierra la ventana efecto→resultado. Dados/eventos anteriores al guardado
  del efecto y su atomicidad conjunta siguen fuera de esta garantía.

### Recuperar el beat IA confirmado entre Games (D153), 2026-10-02

- World/Codec conservan `actor_checkpoint`: actor, turn_id, resultados
  exitosos saneados, fase/mini-turn y enemigos originales. Game guarda ese
  registro antes de entregar el resultado de la tool. El actor recuperado
  reutiliza bloque/feedback sin repetir recursos/dados; el snapshot original
  mantiene la detección de combate tras un spawn anterior al reinicio.
- Éxito/fallo definitivo elimina el registro; una declaración humana nueva
  empieza otro beat. Worlds antiguos y registros inválidos no restauran una
  instrucción. No cambia Character/Weapon/Spell/Item ni el single-writer.
- **8 casos nuevos**, **45** focalizados y **2393 passed / 3 excluded**
  (41,8 s), cero errores/warnings; compile dev/formato/diff correctos.
  La prueba de timeout de SceneRefresh deja de exigir un callback antes del
  plazo global: conserva todo World y verifica el cierre si llegó a arrancar.
  `dragonex-actor-checkpoint-recovery-*`.
- VM19431 offline: Mara IA confirma cast y se reinicia mientras espera narrar;
  conserva World/1 casilla/Goblin14/20/un evento de dados, cierra petición vieja.
  Reanuda hasta Thane en25,518 ms, un marcador de Mara y turn_id original;
  registro liquidado. Reload375/1440 px, ficha/compañeros por teclado sin JS/
  overflow. No es una medición de proveedor real. Ganchos retirados.
- Adopción19425–19430 propias pausadas conserva World tras normalizar el nuevo
  campo nil, eventos/modelos/cursores/relojes; cierra20 auxiliares anteriores.
  `actor-checkpoint-recovery-*`.
- Sigue abierta la ventana entre guardar el efecto y guardar su resultado,
  así como atomicidad conjunta de dados/eventos/World. Cubre tools confirmadas,
  sin certificar todas las variantes de campaña.

### Reintentos de narración sin repetir tools ya resueltas (D152), 2026-10-02

- Un503 después de resolver magia en exploración reiniciaba el beat y
  gastaba la segunda casilla: rojo inicial0 frente a1 restante. Game guarda
  en Beat/PendingRetry los resultados exitosos de tools y los reutiliza en
  reintentos transient/max_tokens del mismo beat, sin dados ni efectos nuevos.
  Feedback indica que es un resultado anterior. Llamadas rechazadas no se
  registran; un nuevo beat ejecuta de nuevo las acciones declaradas.
- Identifica tool/argumentos, sin depender de IDs nuevos del proveedor.
  Nulos/omisiones son equivalentes; magia usa el lookup de definición del
  motor para nombres equivalentes, nivel base, enteros limpios y opcionales
  vacíos. Conserva varias llamadas originales iguales y no paga copias extra
  en el reintento. El registro de memoria usa feedback pasado por Text.scrub.
- **9 casos nuevos**, **28** focalizados y **2385 passed / 3 excluded**
  (41,3 s), cero errores/warnings; compile/formato/diff correctos.
  `dragonex-applied-action-retry-*`. La primera fixture de dos casts los
  mandaba simultáneos y chocaba con las guardas de recursos; el caso final
  los pide consecutivamente, sin cambiar esas guardas.
- VM19430 con503 simulado offline después de la tool: casillas2→1, Goblin
  20→14 PG, un evento de dados; feedback previo llega al modelo. Vuelve al
  humano en1050,311 ms, incluido backoff1 s. Reinicio después conserva
  World/historial/pausa; reload375/1440 px, ficha por teclado y reserva visible
  correctos, sin JS/overflow. Ganchos retirados. `applied-action-retry-*`.
- Adopción19425–19429 propias pausadas: World/eventos/modelos/cursores/relojes
  idénticos,17 auxiliares cerrados y tools de DM/PC verificadas con wrapper.
- Alcance: reintentos del mismo beat con Game vivo. El registro de resultados
  aún no es durable entre Games; ampliar recuperación de actor IA tras
  reinicio con efectos confirmados y atomicidad dados/eventos/World.

### Caídas aisladas por partida (D151), 2026-10-02

- Cuatro caídas rápidas de una mesa agotaban el límite del supervisor global
  y cerraban una mesa sana: rojo determinista confirmado. Cada Game pasa a
  tener un supervisor propio con límite3/5 s; agotarlo cierra solo esa mesa.
  El gestor global no reinicia esos supervisores temporales. Salida normal
  de Game retira el supervisor vacío con `auto_shutdown`; APIs devuelven
  PID de Game y el reinicio espera ambas claves de Registry.
- **6 casos nuevos**: cuatro caídas/mesa sana, cuatro mesas independientes,
  cierre normal, reinicios públicos/idempotencia, ID inexistente y caída
  después de descanso confirmado. Curación/reloj/límite/historial sobreviven
  a `:kill`, y se cancela la narración anterior. No cambia World/Codec.
- Gate **2376 passed / 3 excluded** (40,4 s), **cero errores y cero warnings**;
  compile dev limpio. Limpieza de once avisos de fixtures/asserts conserva
  las pruebas. La variante anterior registró una desconexión SQL al matar
  un reemplazo antes de acabar init; el escenario final espera respuesta
  de Game antes de la siguiente caída. `dragonex-fault-isolation-*`.
- VM web: cuatro caídas deliberadas en mesa propia19429 cierran su supervisor
  y tres auxiliares; gestor global y mesa sana19428 mantienen los mismos
  procesos, World e historial. Reapertura manual19429 conserva World/pausa.
  Reload375/1440 px y fichas por teclado en ambas sin JS/overflow.
  `fault-isolation-runtime`/`fault-isolation-browser`. Ganchos retirados.
- Adopción en19425–19428 propias pausadas conserva todos los World/eventos,
  cursores/relojes/modelos y cierra14 auxiliares anteriores. Partidas ajenas
  no reiniciadas; la compatibilidad de parada conserva Games de desarrollo
  anteriores al supervisor nuevo. Atomicidad dados/eventos/World pendiente.

### Efectos de reglas guardados antes de la narración (D150), 2026-10-02

- Un descanso aplicado durante un beat seguía solo en memoria hasta terminar
  la narración: el caso determinista inicial encontraba 8/14 PG en Postgres
  frente a 14/14 y ocho horas en la mesa. Las tools vivas pasan por Game,
  validan Session/actor/turn_id/propietario vigente y guardan el candidato
  antes de publicarlo a Session y confirmar el resultado. Las sesiones
  offline sin Game conservan SharedState y no necesitan DB.
- **7 casos nuevos**: descanso durable antes de narrar, reinicio con límite
  diario, curación humana con casilla/acción gastadas, pausa/intenciones,
  handles antiguos, cambios inválidos y ejecución en el proceso Game.
  Suite **2370 passed / 3 excluded** (40,6 s), cero errores de ejecución;
  once avisos de compilación en tests. Compile dev sin warnings.
- Mesa propia19428 con TestModel: descanso8→14 PG, reloj28800, World e
  historial iguales al reiniciar mientras espera el modelo; pedido antiguo
  cerrado. Reinicio5,575 ms observado. Continuación lee PG/reloj vigentes,
  registra amanecer, vuelve al humano y conserva límite diario sin dados.
  Reload375/1440 px y ficha por teclado sin JS/overflow; ganchos retirados.
  `dragonex-rule-checkpoint-*`/`rule-checkpoint-runtime`/`rule-checkpoint-browser`.
- Alcance: cambios de World confirmados por tools. No es una transacción
  conjunta de dados/eventos/World ni recupera el texto pendiente del proveedor.
  La prueba combinada de caídas rápidas reveló un límite de reinicios global
  compartido entre mesas; hallazgo resuelto mediante el aislamiento D151.

### Parada supervisada después de la operación del Game (D149), 2026-10-02

- Game captura señales de salida para que OTP espere la respuesta del
  callback actual antes de cerrar, dentro del plazo del supervisor. Una
  prueba bloquea una operación100 ms: antes era interrumpida; ahora responde.
  No espera la narración IA asíncrona ni cambia su cancelación D147.
- Una salida de Session/DM/TM/PC vigente reinicia Game; la salida del
  autoplay ya retirado no lo reinicia. Los informes OTP muestran campos
  operativos y excluyen los modelos, que pueden contener credenciales.
- **5 casos nuevos**, un rojo inicial, **54** focalizados y
  **2363 passed / 3 excluded** (39,0 s), cero errores de log, compile limpio,
  formato/diff correctos. `dragonex-shutdown-order-*.log`.
- VM web19427: operación retenida100 ms responde antes de la parada,
  tres auxiliares cerrados, reapertura con World/tres eventos/pausa/cursor
  idénticos. Reload375/1440 px/teclado sin JS/overflow. Ganchos retirados.
  `shutdown-order-runtime`/`shutdown-order-browser`.
- Adopción en mesas propias19425/19426 pausadas: nuevos Games con señales
  capturadas, cinco/tres auxiliares antiguos cerrados, World/130 y20 eventos/
  pausa/cursor idénticos. Relojes32400/28800 y escena vigente conservados.
  `shutdown-order-paused-adoption`. No se reinician partidas ajenas.
- Alcance: callback bajo parada supervisada, con el timeout OTP vigente.
  No protege una caída `:kill` ni prueba recuperación de tools parciales.

### Cierre ordenado de partidas y conexión en los tests (D148), 2026-10-02

- Los agentes de partidas de prueba podían seguir consultando al salir
  el dueño Sandbox. Las fixtures compartidas usan `start_owner!` separado
  hasta `on_exit`; un hijo registrado después del Game pausa y espera su
  beat antes de que ExUnit cierre el Game. Partidas de LiveView en el
  supervisor global se cierran mediante Registry, sin consultas de inventario
  al cerrar SQL. Siete módulos async conservan sus conexiones aisladas.
- **67 módulos/69 setups** compartidos y **55 módulos/147 arranques** de
  Game usan los helpers. Un caso nuevo bloquea el modelo tras aplicar un
  descanso: la limpieza permite concluir, conserva curación/reloj/World y
  narración en DB antes de cerrar. Las pruebas D147 mantienen su cancelación
  inmediata deliberada y no se sustituyen por el cierre de las fixtures.
- **71** focalizados y **49** de la variante final, sin errores. Gate final
  **2358 passed / 3 excluded** (39,2 s), **cero errores de log**, compile
  limpio, formato/diff correctos. `dragonex-sandbox-lifecycle-*.log`.
  Los gates intermedios con clientes interrumpidos y una consulta de limpieza
  fallida no se cuentan como cierre; la variante Registry es la verificada.
- Cierra el pendiente de teardown señalado en D147 para este gate.
  No cambia reglas ni prueba recuperación tras caída con efectos parciales,
  ni convierte el cierre ordenado del test en semántica de reinicio real.

### Cierre de ejecuciones IA al detener o reiniciar la partida (D147), 2026-10-02

- Una petición exAgent podía sobrevivir al Game porque su Task no está
  enlazado al Server. Monitores de Game/beat cancelan las ejecuciones y
  cierran Session/Servers incluso tras salida normal; incluyen autoplay
  creado después del arranque, TurnMaster y registro de escena.
- Las guardas comprueban el propietario antes de nuevos pedidos/tools y
  publicación de texto/dados. No añaden reglas ni escrituras al modelo.
  Pausar mantiene la semántica existente: el beat actual puede concluir;
  detener/reiniciar invalida su propietario.
- **12 casos nuevos**, tres fallos iniciales confirmados, **67** focalizados
  y **2357 passed / 3 excluded** (39,1 s), compile limpio. Parada supervisada,
  normal, reinicio, caída, PC/TM/escena, autoplay tardío, descarte de texto/
  tools y cierre del monitor comprobados. `dragonex-run-lifecycle-*.log`.
- Mesa propia19427 con TestModel bloqueado antes de tools: reinicio público
  cancela petición y cuatro auxiliares en **12,48 ms** observados, World/
  tres eventos/pausa/cursor iguales. Reload375/1440 px, ficha por teclado,
  sin JS/overflow; ganchos retirados. `run-lifecycle-*`.
- El gate final registra **11** errores de dueño Sandbox salido en teardown;
  no se afirma un log sin errores. Queda abierto su orden de cierre en tests,
  la recuperación tras efectos parciales y la cancelación aguas arriba del
  proveedor real. La medición offline no es una garantía de latencia.

### Descanso largo: feedback del cuerpo vigente al terminar (D146), 2026-10-02

- El mensaje usaba PG de bestia antes de caducar («0 PG,11→11»), aunque
  el cambio curaba el cuerpo original («23 PG,6→29»). Actions proyecta las
  ocho horas, igual que el descanso corto, para informar el mismo cuerpo
  que recibe la curación; preparar el mensaje no adelanta tiempo.
- **6 casos nuevos**, cinco rojos iniciales, **76** focalizados y
  **2345 passed / 3 excluded** (39,2 s), compile/formato/diff correctos.
  Bestia intacta/herida, Codec, límite exacto8 h, forma aún vigente,
  noche compartida y feedback al agente/Game/reapertura comprobados.
  `dragonex-rest-shape-feedback-*.log`.
- Mesa19426 propia, SylviL3: lobo11/11 conserva original10/24 y reloj0;
  noche completa devuelve cuerpo24/24, dos usos, casillas4/2 y dados3/3,
  reloj28800, cero dados y biblioteca igual. **28,24 s** al humano;
  web375/1440 px/reload correcta. Reinicio conserva World/20 eventos/pausa/
  cursor, cierra tres auxiliares y mantiene límite diario.
- El feedback humano original fue sustituido al reconstruir history para
  el DM. No se presenta una captura inexistente: replay de Actions sobre el
  World previo registrado devuelve «14 PG,10→24», sin aplicar el cambio;
  entrega al modelo se prueba con TestModel. Ganchos retirados, compile limpio.
  `rest-form-*`/`rest-form-feedback-runtime`.

### Registro verificable de la escena después de cambios confirmados (D145), 2026-10-02

- Tiempo de exploración, facts nuevos y fin de combate marcan el registro
  pendiente en World/Codec. Si el DM omite `set_scene`, un resumidor restringido
  devuelve una escena estructurada: sin tools de reglas, 40 eventos recientes,
  dos pasos/20 s/1200 caracteres. Game valida y aplica; no repite efectos.
- Una instantánea conserva la conversación y el retorno humano. `set_scene`
  mantiene la cancelación de cola al cambiar de escena. Pausa, error, timeout
  y respuesta sobre un World ya modificado conservan el estado; un fallo
  deja el registro pendiente para otro beat DM. Legacy con reloj/facts se
  revisa al rehidratar. Diálogos sin cambios no añaden llamadas.
- **16 casos nuevos**, diez rojos iniciales, **120** focalizados y
  **2339 passed / 3 excluded** (38,4 s), compile limpio, formato/diff correctos.
  Incluye resultado obligatorio, schema/reintento, frase cortada real,
  agencia PC, recursos, cola, pausa y reapertura. `dragonex-scene-refresh-*.log`.
- Primera variante real: **38,71 s**, timeout confirmado sin mutaciones.
  La variante final registra cuarto/huerto en **4,72 s**, un paso, y devuelve
  Mara en **23,89 s**. Solo cambian escena/log/marca; reloj32400, recursos,
  biblioteca, encargo y pausa/cursor iguales, cero dados. DM no llamó ninguna
  tool: el registro proviene de la fase restringida. Reinicio real conserva
  todo World/130 eventos y cierra cinco auxiliares; límite de 24 h vigente.
  Web375/1440 px sin JS/overflow; ganchos retirados, compile limpio.
  `short-adventure-manana-registro-*`/`scene-refresh-recorded-restart`.
- Alcance: señales confirmadas del motor, no reconocimiento de todo viaje
  narrativo. Guardas de prosa acotadas; el resumen puede fallar o ser impreciso.
  No certifica coherencia semántica general ni todas las escenas/campañas.

### Reloj, descanso diario y hechos vigentes en el contexto (D144), 2026-10-02

- DM/PC/TurnMaster reciben el reloj relativo del World y el cupo real de
  descanso largo. `Rest.long_rest_wait/2` comparte el cálculo con el validador:
  tras la noche, reloj32400 y espera57600 s, también tras Codec/reinicio.
  TurnMaster recibe los hechos canónicos; la escena se identifica como el
  último registro y cede ante hechos/decisiones posteriores.
- `rest_party` devuelve el reloj ya aplicado y pide registrar el entorno
  con `set_scene`, sin repetir el descanso ni decidir por los PCs.
  **6 casos nuevos**, seis rojos, **64** focalizados y **2323 passed /
  3 excluded** (38,9 s), compile/formato/diff correctos.
  `dragonex-clock-context-*.log`.
- Mañana19425: **13,65 s**, World completo y biblioteca iguales, encargo
  cerrado, cero dados; fichas375/1440 px, teclado/reload sin JS/overflow.
  El modelo vuelve a omitir `set_scene`: el registro sigue en el patio
  inicial. El contexto está verificado; el cierre persistente de la escena
  quedó abierto en esa medición; D145 lo resuelve para cambios confirmados.

### Una noche compartida completa y persistida, 2026-10-02

- Propuesta a Lyra/Vex: respuestas propias en orden y retorno Mara en
  **10,59 s**, World completo igual; no cura ni adelanta tiempo al proponer.
  Tras aceptar, completar la noche ejecuta una sola `rest_party(long)` para
  Mara/Lyra/Vex, capturada del agente DM, finish_reason=stop.
- **16,24 s** al humano: reloj3600→32400, mismo comienzo3600 para los tres,
  Mara11→14/14 PG y 1→2/2 d6, casillas nativas correctas. Vex recibe una
  entrada vacía de casillas de no-conjurador; no son recursos nuevos.
  Goblin/encargo/recompensa y biblioteca intactos, cero dados.
- Reinicio real y reapertura web conservan World/historial (109 eventos)/
  pausa/cursor/cola; anterior/cinco auxiliares terminados. El validador del
  motor rechaza inmediatamente otro descanso largo para los tres por 24 h,
  también tras rehidratar. Fichas375/1440 px y teclado sin JS/overflow.
  Ganchos retirados, compile limpio. `short-adventure-noche-*`/
  `short-adventure-long-rest-runtime`, sin cambio de código ni gate adicional.
- Brecha descubierta: World.scene sigue describiendo el patio/encargo inicial;
  DM llamó solo rest_party, no set_scene. El brief muestra ese texto como
  «Escena» y omite reloj/cupo diario. Siguiente revisión del contexto factual.

### Preguntas humanas con destinatario explícito desde el motor (D143), 2026-10-02

- La petición real de jarra terminó Human → DM → Human porque el narrador
  omitió `request_response`. Game registra ahora un vocativo inicial literal
  («Vex, ¿puedes…?» o varios nombres con comas/y/e) al consumir la declaración,
  antes del beat. Conserva nombres canónicos/cortos únicos y orden escrito;
  no enruta menciones, citas, preguntas indirectas ni destinatarios ambiguos.
- Reutiliza la cola D120 y sus guardas: solo exploración, PCs participantes
  presentes/capaces, sin self/PNJs. Una petición inválida no abre una cola
  parcial. El borrador pausado/off-turn no abre conversación hasta su turno;
  limpiar la intención la cancela. Cola existente, prioridad humana e
  iniciativa permanecen. Prompt/tool avisan de la pregunta ya registrada.
- **14 casos nuevos** (cinco Text, ocho Game, un LiveView), ocho rojos
  iniciales; **72** focalizados, **2317 passed / 3 excluded** (39,3 s), compile
  sin warnings y formato/diff correctos. Incluye persistencia antes del beat,
  modelo sin tool/fallido, reintento distinto, respuesta humana/reinicio,
  prioridad ajena, combate y composer/preview/reload.
  `dragonex-explicit-question-*.log`.
- Mesa19425: Mara → Vex → DM → Mara en **6,51 s**. Vex85 pide agua por sí
  mismo; captura del agente existente con finish_reason=stop y limpio=persistido.
  World completo, biblioteca, pausa/cursor/cola iguales, cero dados; teclado,
  recarga y fichas 375/1440 px sin JS/overflow. Gancho temporal retirado,
  compile limpio. `short-adventure-explicit-question-*`/`explicit-question-response-raw`.
  Semántica fuera de ese vocativo acotado sigue dependiendo de la tool/modelo.

### Reinicio real después del combate y descanso, 2026-10-02

- `Game.restart/1` sobre la mesa19425 propia, pausada y sin beat en vuelo:
  PID nuevo, anterior y sus cinco procesos auxiliares terminados. World,
  historial completo (79 eventos), pausa, cursor e intenciones idénticos;
  biblioteca intacta. No reinicia el servidor ni otras partidas.
- Reapertura web/teclado a 375/1440 px conserva Mara 11/14 PG, 1/2 d6 y
  tres casillas, reloj3600 y encargo/recompensa. Sin JS/overflow. Gancho
  temporal retirado y compile sin warnings; lectores sin segundo escritor.
  `short-adventure-process-restart`/`short-adventure-restart-*` en playtest.
  Verificación de persistencia existente, sin feature ni gate adicional.

### Destinatario PNJ conservado en la voz propia (D142), 2026-10-02

- La entrega de Vex quedó «le tiendo el saquito a Aquí…». Su raw original
  ya fue sustituido por el siguiente turno; una reconstrucción mínima produce
  exactamente ese mismo corte: «a la posadera—.» parece un nuevo hablante
  al detector amplio de rol/cita. No se presenta la reconstrucción como raw.
- Text exige un sujeto/etiqueta de rol en inicio, puntuación o coordinación;
  una destinataria tras «a la…» conserva nombre e inciso al cerrar el diálogo.
  La respuesta inmediata «la posadera, que responde…» sigue retirada desde
  la relativa, conservando el destinatario. Citas PNJ reales siguen cortadas
  para el PC; DM mantiene sus voces. Vocabulario/estructuras acotados.
- **9 casos nuevos** (siete Text, un Game, un LiveView), seis rojos iniciales
  y una regresión adicional de relativa; **99** focalizados,
  **2303 passed / 3 excluded** (37,2 s), compile sin warnings y formato/diff
  correctos. Streaming parcial, texto completo, historial, World/reapertura
  y preview/reload comprobados. `dragonex-npc-recipient-*.log`.
- Agradecimiento real19425 en **8,55 s**, Vex propio y DM: raw capturado en
  proceso dev pausado, finish_reason=stop, solo retira la cabecera de turno;
  texto limpio=persistido. World completo/recursos iguales, reload/fichas
  375/1440 px sin JS/overflow. El gancho temporal se retiró, compile limpio.
- Petición posterior de jarra (**13,63 s**) conserva World, pero el DM responde
  sin turno de Vex. La captura de Vex sigue siendo el agradecimiento anterior;
  no prueba una respuesta que no ocurrió. Ese fallo motiva D143, comprobado
  arriba. `short-adventure-*`/`*-recipient-response-raw`.

### Aventura corta: granero, combate, recompensa y descanso, 2026-10-02

- Mesa nueva `/games/19425`, Mara propia L2 y Lyra/Vex IA: «El saquito del
  granero», con un único goblin y final explícito. Apertura **5,01 s** hasta
  decidir, primer reconocimiento **20,63 s** sin mutar World/recursos.
- Declaración de Proyectil mágico inicia la pelea: ficha/orden reales,
  cuatro iniciativas con totales correctos y desempate DEX. Vex actúa primero,
  nat20 +3 DEX +2 competencia =25 contra CA15; crítico con Sneak Attack
  1+2+6+6+3=18, goblin 7→0, cierre automático antes de Lyra/Mara/goblin.
  **27,78 s** al humano, tres casillas de Mara sin gastar porque su conjuro
  aún no se ejecutó. Derrotado no implica muerte instantánea (fuera D78).
- Petición a Vex → devolución propia → DM en **16,17 s**. Encargo/recompensa
  registrados en dos facts durables. Propuesta de descanso aceptada por
  Lyra/Vex (**15,63 s**) no cura ni avanza tiempo; al completarlo Mara gasta
  un d6: 1+2 CON=3, 8→11/14 PG, 1/2 d6, reloj 3600 y casillas intactas.
  **21,75 s**; cierre usa fallback TM no_decision, bajo revisión de latencia.
- Oráculo independiente sobre las tiradas/World guardados; biblioteca igual,
  pausa/reload/teclado y fichas 375/1440 px sin JS/overflow. Lectores no crean
  otro Game escritor. `short-adventure-*` en `/tmp/dragonex-playtest`.
  Sin cambio de código/gate (referencia D141, 2294 passed / 3 excluded).
- La respuesta propia de Vex al devolver el objeto perdió «la posadera»
  y quedó «le tiendo el saquito a Aquí…». Siguiente diagnóstico de raw/filtro;
  este recorrido no certifica prosa, toda clase ni campañas largas.

### Gestos ajenos tras pronombres sin perder el entorno (D141), 2026-10-02

- El cierre real «Iria las recoge en silencio, asintiendo apenas» escapaba
  al predicado inmediato. Fixture exacto; Text permite un pronombre indirecto/
  reflexivo y uno de objeto antes del verbo conocido, e incorpora recoge.
  Directas, relativas/subordinadas, detector y streaming comparten ese límite.
- Separa «, y el calor…» fuera de citas para conservar la cocina y el roble
  después de retirar el gesto. Vocabulario de entorno acotado; objetos como
  «y las guarda» y citas propias del PC retirado siguen fuera. Voz propia,
  PNJs, estados pasivos y nombres ambiguos mantienen su propiedad.
- **11 casos nuevos**, nueve regresiones en rojo, **89** focalizados,
  **2294 passed / 3 excluded** (37,1 s), compile sin warnings y formato/diff
  correctos. Game/historial/World/reapertura, preview/reload y `set_scene`
  rechazado antes de mutar comprobados. `dragonex-clitic-agency-*.log`.
- Continuación real `/games/19424`: Lyra/Mara/Nera propios, cierre DM sin
  gesto de Iria y retorno humano en **15,67 s**. World completo/recursos/pausa/
  cursor/cola iguales y cero dados; teclado/reload/fichas 375/1440 px sin
  JS/overflow. `clitic-agency-*`, lectores sin segundo escritor. Este nuevo
  cierre no contiene el disparador del fixture, comprobado de forma determinista;
  no reescribe el gesto histórico ni resuelve toda agencia semántica.

### Elecciones de ASI recuperables ante datos inválidos (D140), 2026-10-02

- El evento de mejora convertía directamente característica/delta: un valor
  desconocido o incompleto cerraba la LiveView y perdía el borrador. Ahora
  acepta solo las seis características y pasos de +1/−1, y comprueba que el
  nivel incluye ASI antes de ajustar. Conserva los dos puntos y el máximo 20.
- Error local con role=alert junto a los controles, elecciones intactas y
  recuperación con un clic válido; no borra errores de confirmación distintos.
  No aplica niveles ni escribe fichas/World durante la selección.
- **5 casos nuevos**, cinco rojos iniciales, **28** focalizados y
  **2283 passed / 3 excluded** (36,9 s), compile sin warnings y formato/diff
  correctos. Incluye confirmación del nivel/atributos y evento oculto en un
  nivel sin ASI. `dragonex-asi-input-*.log`.
- Navegador `/heroes/5899/level-up`: el primer punto sobrevive al error,
  un segundo clic válido lo elimina sin reconectar ni perder elecciones.
  Biblioteca y todos los World/pausas/cursors/colas asociados iguales;
  subida sin confirmar y recarga vuelve al borrador inicial. Vistas 375/1440 px
  y teclado sin JS/overflow. `asi-input-*` en `/tmp/dragonex-playtest`.

### Observaciones propias completas sin falsos positivos (D139), 2026-10-02

- Se recuperaron las respuestas originales de Lyra/Mara/Nera desde la historia
  de sus agentes dentro del proceso dev existente, pausado y en solo lectura.
  Todas acabaron con finish_reason=stop (142/97/65 tokens): el corte no venía
  del proveedor. Tres fixtures exactos reproducen «me dice la hora/la verdad»,
  «la luz se quiebra» y la pérdida de «tiene:».
- Text exige hablante registrado, rol conocido o atribución explícita para
  tratar «dice el/la…» como voz ajena. Acota quiebra al lacre/sello/pergamino,
  y conserva colon gramatical en la limpieza de números. Las voces propias
  y metáforas sobreviven; cortes existentes de PNJs, stats y ejecución del
  sello siguen comprobados. El diagnóstico temporal quedó retirado del repo.
- **11 casos nuevos**: siete de texto, uno de Game con tres respuestas y
  tres LiveView de preview/reload. Diez rojos iniciales; **94** focalizados,
  **2278 passed / 3 excluded** (35,8 s), compile sin warnings y formato/diff
  correctos. World/colas/historial/reapertura intactos.
  `dragonex-observation-integrity-*.log`.
- Continuación `/games/19424`: pregunta a Lyra/Mara/Nera, respuestas propias,
  cierre DM y retorno Iria en **13,09 s**. Para las tres, raw=filtrado=texto
  persistido, finish_reason=stop. World completo/recursos/pausa/cursor/cola
  iguales, cero dados; reload/fichas 375/1440 px sin JS/overflow. Lectores no
  crean otro escritor. `observation-integrity-*`/`response-integrity-*`.
- No reescribe las tres narraciones históricas cortadas ni interpreta toda
  metáfora/rol. El cierre DM aún asigna un asentimiento a Iria; prosa implícita
  y semántica general de agencia continúan bajo revisión.

### Primera decisión humana tras presentar la escena (D138), 2026-10-02

- La mesa de seis D137 aún dedicaba dos DM/una IA antes de la primera
  decisión humana. ExplorationTurns identifica si los 64 marcadores recientes
  no contienen turno de ningún PC registrado (incluye combate/reacción), y
  da la primera decisión a una persona disponible en una mesa con compañeros
  IA disponibles. Empates conservan el orden humano determinista.
- Game aplica el relevo sin beat TM, con las mismas guardas/prioridades de
  preguntas explícitas, intents, conversación, re-eval y mini-turns. La vía
  muda/fallo también lo respeta. No cambia iniciativa, recursos ni World;
  después de la primera intervención siguen los ciclos D134.
- **3 casos nuevos**: dos puros y uno Game que recorre uno/cinco compañeros,
  contador TM, pausa/reapertura/reanudación y ausencia de beats duplicados.
  Cuatro pruebas de equidad ahora empiezan con una decisión humana real.
  **41** focalizados, **2267 passed / 3 excluded** (35,4 s), compile sin
  warnings, formato/diff correctos. `dragonex-exploration-opening-*.log`.
- Mesa nueva `/games/19424`, seis PCs: control inicial **6,01 s**, solo un
  turno DM y cero IA; escena original conservada. Pregunta a cinco compañeros:
  **22,72 s**, uno cada uno, DM y retorno Iria, World completo/recursos/pausa/
  cursor/cola iguales, cero dados. Reload y fichas 375/1440 px sin JS/overflow.
  `opening-control-*`, lector sin segundo escritor. Los tiempos varían.
- Tres respuestas propias aparecen cortadas a mitad de frase (Lyra/Mara/Nera).
  Queda por distinguir proveedor y sanitización; el gate del relevo no declara
  cerrada la calidad narrativa ni la tarea de largo alcance.

### Playtest de seis voces y primera decisión, 2026-10-02

- Mesa nueva `/games/19423`: Iria propia y cinco compañeros Lyra/Vex/Mara/
  Nera/Thane. Apertura **25,76 s** con dos DM y una Mara; sin repetir IA y
  escena inicial conservada. La persona aún espera esa IA antes de decidir:
  siguiente revisión acotada del arranque.
- Pregunta explícita a cinco compañeros: **14,05 s**, una intervención
  cada uno, cierre DM y vuelta Iria. World completo/recursos/pausa/cursor/
  intenciones iguales y cero dados nuevos. Reload y fichas 375/1440 px sin
  JS/overflow, cinco compañeros móviles; lector no crea otro Game escritor.
  `six-continuity-*` en `/tmp/dragonex-playtest`.
- Sin cambio de código ni gate nuevo (referencia D137). No garantiza esos
  tiempos; prosa añade muesca/sendero y «al girar la cabeza…» sin elección
  humana. La revisión semántica y de agencia continúa.

### Movimiento colectivo implícito y continuidad real (D137), 2026-10-02

- La misma apertura real aún decía «y al acercaros el destello…». Text retira
  disparadores temporales plurales acotados de acercarse/adentrarse/dirigirse/
  marcharse/alejarse/apartarse y su destino separado, conservando descripción
  del pájaro/colgante. Conserva movimiento singular propio, preguntas/planes
  y citas PNJ, incluidas las incompletas de streaming. Las palabras de una
  cita no esconden una acción posterior fuera de ella.
- Streaming, Events/historial y validación `set_scene` comparten el corte.
  La escena implícita se rechaza antes de World/log/recursos y sigue igual
  al reabrir; una invitación PNJ legítima se guarda. Normaliza el corte local
  para evitar conjunciones sueltas y conservar una frase legible.
- **9 casos nuevos** (siete Text, dos Game), más dos recorridos existentes
  reforzados de historial y LiveView/preview/reload. Siete rojos iniciales,
  **93** focalizados, **2264 passed / 3 excluded** (34,8 s), compile sin
  warnings, formato/diff correctos. `dragonex-implicit-agency-*.log`.
- Continuación real `/games/19422`: Lyra/Vex responden una vez cada uno,
  luego DM y Sylvi en **10,02 s**. World completo/escena/pausa/cursor/cola
  idénticos, cero dados; Lyra/Vex usan «Sylvi» en sus propias respuestas.
  Recarga y fichas 375/1440 px sin JS/overflow; lector sin segundo Game escritor.
  `dialogue-continuity-*` en `/tmp/dragonex-playtest`. La vuelta aquí la
  decide la conversación registrada; no prueba el parser D136 con proveedor
  ni convierte la medición en garantía. Otras alusiones/consenso siguen abiertos.

### Preguntas dirigidas por identidad y disponibilidad (D136), 2026-10-02

- El relevo reconocía solo el nombre completo, confundía prefijos de PNJs
  con PCs y podía devolver la palabra a un humano incapacitado. Text reutiliza
  las formas cortas únicas del registro, prioriza nombres largos, conserva
  Unicode/literales y no elige por orden del roster ante varios humanos.
  Una forma ambigua o un destinatario registrado ajeno no fuerzan a un humano.
- Game valida presencia/capacidad con World antes de aplicar el relevo D30.
  Para una pregunta genérica conserva el humano previo con los marcadores
  recientes de turnos si las acciones ya salieron de los últimos 24 eventos.
  Mantiene conversación, intents, interrupciones, combate y re-eval existentes;
  no cambia World ni sus recursos.
- **11 casos nuevos**: seis de Text y cinco Game/Postgres. Diez rojos iniciales;
  **77** focalizados y **2255 passed / 3 excluded** (35,0 s), compile sin
  warnings. Apertura con nombre corto sin petición TM, cambio entre dos
  humanos, PNJ homónimo, incapacitado y 220 eventos intermedios verificados.
  `/tmp/dragonex-addressed-identity-*.log`; sin nuevo playtest de proveedor.
- La clasificación de preguntas sigue acotada; no interpreta toda referencia,
  ironía o intención de la prosa. Calidad y continuidad live siguen abiertas.

### Agencia colectiva protegida en narración y escena (D135), 2026-10-02

- Fixtures exactos de `/games/19421` reproducen «El grupo cruza…» en narración
  y «Decidís cruzar…» en la escena guardada. Text corta sujetos colectivos y
  movimientos plurales explícitos cuando actúan por otro PC, conservando
  entorno, PNJs, consecuencias pasivas y propuestas/preguntas. Streaming,
  Events e historial comparten el filtro; una cita PNJ no esconde la cláusula
  colectiva que le sigue.
- `set_scene` valida contra el roster vigente y el actor del handle: rechaza
  la propuesta completa si impone una acción ajena/colectiva o queda vacía.
  Conserva World/log/cola, y devuelve una corrección al modelo. La comprobación
  usa los mismos cortes acotados, no el detector amplio de nudges; permite
  invitaciones PNJ, nombres completos frente a prefijos y movimiento local
  propio declarado. Las instrucciones de avance respetan estilo/agencia y
  dejan de ordenar un traslado automático del grupo.
- **15 casos nuevos**: seis de texto, siete Game/Postgres, una LiveView y uno
  de instrucciones. **97** focalizados, **2244 passed / 3 excluded** (34,5 s),
  compile sin warnings, formato/diff correctos. Verifica rechazo, recursos,
  log/rehidratación, preview/reload, preguntas PNJ y cola real Lyra/Vex
  intacta tras rechazo. `/tmp/dragonex-collective-agency-*.log`.
- Sin otra medición de proveedor real en esta tanda. Alusiones implícitas
  como «al acercaros» y la verificación semántica de planes/hechos continúan
  bajo D29 y revisión de calidad; las historias guardadas se conservan.

### Equidad entre compañeros IA y personas en exploración (D134), 2026-10-02

- El relevo recibía solo `last_actor = dm` tras cada respuesta del mundo;
  perdía los PCs que ya habían intervenido. `ExplorationTurns` reconstruye
  esa información con los últimos 64 marcadores de turno, independiente del
  volumen de tools/narraciones. Incluye personas disponibles y compañeros
  que ya actuaron en el contexto real de TurnMaster.
- Cada IA puede recibir una intervención ordinaria antes del siguiente
  humano. Repetirla cede al humano que lleva más tiempo sin participar;
  cuando han hablado todas, el relevo humano se aplica sin otra petición al
  modelo. Fallback tras una IA también devuelve a una persona. Declaraciones
  en cola, preguntas dirigidas y conversaciones conservan prioridad;
  combate, mini-turns, re-eval y piloto automático mantienen su camino.
- **13 casos nuevos**: seis puros y siete Game/Postgres, con repetición válida,
  compañeros distintos, contador de peticiones, reapertura tras 220 eventos,
  orden humano/pausa, TM mudo y declaración pendiente. **77** focalizados,
  **2229 passed / 3 excluded** (33,8 s), compile sin warnings, formato/diff
  correctos. `/tmp/dragonex-exploration-fairness-*.log`.
- Nueva mesa `/games/19422`, Sylvi + Lyra/Vex: **12,10 s** hasta el humano,
  una narración DM y ninguna intervención IA previa. Una pregunta explícita
  recibe ambas respuestas propias y vuelve a Sylvi en **17,61 s**; el World
  completo codificado, pausa/cursor/intenciones permanecen iguales, sin dados
  nuevos. Escena inicial conservada, reload/fichas 375/1440 px sin JS/overflow.
  `/tmp/dragonex-playtest/exploration-fairness-*`. Es evidencia de ese recorrido;
  continúa agencia colectiva y fidelidad narrativa, no se cierra la campaña.

### Estilo de partida enviado al DM (D133), 2026-10-02

- Bootstrap pasa `dm_style`, antes guardado pero omitido, al constructor DM.
  Se añade al mismo prefijo estable que las reglas/biblia y llega al modelo
  por D132. Guía tono/ritmo y eventos; tools y World mantienen las reglas.
  Vacío/nil/tipo legacy no soportado conserva el prompt previo.
- **Tres pruebas nuevas**: custom multiline desde wizard/reapertura pausada,
  todos los escenarios con biblia/estilo y compatibilidad legacy. **20**
  focalizadas, **2216 passed / 3 excluded** (32,9 s), compile sin warnings,
  formato/diff correctos. Verifica mensajes codificados, no solo DB/constructor.
  `/tmp/dragonex-dm-style-*.log`.
- Mesa nueva `/games/19421`, Sylvi propia + Lyra/Vex IA: pregunta a ambos,
  respuestas propias y **20,70 s** hasta Sylvi. Character completo, casillas,
  escena/phase/reloj/ledger/plazos/ausencia/pausa/cursor/intenciones iguales
  en Postgres, sin dados nuevos; fichas/reload 375/1440 px sin JS/overflow.
  `/tmp/dragonex-playtest/dm-style-*`.
- La apertura sigue pendiente de calidad: cinco turnos de Lyra antes de ceder
  al humano, dos chequeos y trama nueva pese a escena sin PNJs/encargos; el DM
  narró «El grupo cruza el umbral…» sin decisión humana. Tono sin amenazas
  en ese recorrido; no certifica toda obediencia. Continúan relevo y agencia.

### Instrucciones de rol llegan con el historial compartido (D132), 2026-10-02

- Game pasaba un historial de eventos no vacío; exAgent no insertaba ahí las
  instrucciones del agente y su adaptador Chat ignoraba `params.instructions`.
  DM/PC perdían el prompt de rol, aunque su constructor sí lo tuviera. Los
  rojos inspeccionan los mensajes recibidos y su codificación de proveedor.
- `AgentInstructions`, al final de las capabilities de DM/PC, antepone el
  rol vigente solo en la petición, después de compactar. Conserva resumen,
  conversación y contenido de Requests mixtos; retira duplicados del mismo
  prefijo. No cambia historial canónico ni índices de mensajes nuevos.
  TurnMaster usa historial vacío en cada decisión y ya recibía el suyo.
- **Cuatro pruebas nuevas** (Game DM/biblia, PC con eventos, compacción y
  varios pasos de tool sin duplicados), **35** focalizadas, **2213 passed /
  3 excluded** (33,1 s), compile sin warnings y formato/diff correctos.
  `/tmp/dragonex-instructions-delivery-*.log`. Sin nueva medición de proveedor.
  Continúa la conexión de `dm_style`, guardado pero omitido en Bootstrap.

### Voces registradas dentro del mismo turno (D131), 2026-10-02

- Events relee PCs/nombres del World comprometido antes de limpiar cada
  respuesta. Crear `Lyra del Muelle`/`Mara del Río` ya no borra su voz por
  confundirla con el prefijo de una PC; mantiene recorte de voces PC inventadas
  y deja explícitamente ambiguo el nombre corto compartido.
- Antes de la siguiente petición al modelo, un cambio de personajes refresca
  la mesa y el contexto del run: el streaming conoce el alta antes del final.
  No adivina registros desde argumentos de tools. Handle ausente/inválido o
  sesión cerrada conserva contexto inicial; no escribe World ni eventos antiguos.
- **Cinco pruebas nuevas** (tres Game/TestModel, una capability compatible y
  una LiveView bloqueada entre creación/narración), **60** focalizadas y
  **2209 passed / 3 excluded** (33,4 s), compile sin warnings, formato/diff
  correctos. Dos rojos: persistencia/historial y ficha/preview sin refrescar.
  Registro rechazado no gana una voz autorizada; PG/casillas/reloj/ledger
  conservados. `/tmp/dragonex-live-roster-*.log`. Sin nuevo playtest de proveedor.

### Forma activa y vitalidad original visibles en la mesa (D130), 2026-10-02

- Las fichas y el tracker identifican gato/lobo/oso negro junto al estado;
  Actions y mesa comparten el nombre de bestia. La ficha propia muestra los
  PG guardados de la forma original por separado, leyendo World, y avisa
  cómo volver a conjurar. Exploración resumida y detalle/móvil están cubiertos.
- Un snapshot incompleto indica «Sin registrar», sin inventar 0/0. La
  reversión retira distintivo/fila/aviso; resumen de compañeros no expone
  un segundo pool de PG. Se conserva el estilo D84, sin nuevos campos.
- **Tres pruebas nuevas** y ampliación del recorrido D129, **69** focalizadas,
  **2204 passed / 3 excluded** (33,0 s), compile sin warnings, formato/diff
  correctos. Segunda reproducción roja cubre el aviso omitido en exploración
  descubierto en navegador. `/tmp/dragonex-shape-sheet-*.log`.
- Sylvi propia `/heroes/5899`, `/games/19420`: creada desde web, L1 → L2,
  lobo **11/11**, luego L3 con forma original **10/24 PG**; reversión devuelve
  esos PG y CA 15. Uso **1/2**, casillas **4/2**, reloj 0, ledger vacío y
  deadline 3600 conservados al progresar; reversión retira plazo. Pausa/reload
  y fichas 375/1440 px sin JS/overflow; relevos **14,53/19,06 s**.
  `/tmp/dragonex-playtest/wild-shape-*`. El DM añade amenaza narrativa al
  claro tranquilo solicitado: no se certifica obediencia al tono de aventura.

### Progresión durante Forma salvaje conserva ambas formas (D129), 2026-10-02

- LevelUp usa CON/atributos/PG/CA/armas de la forma original guardada;
  actualiza ese snapshot y conserva el estado físico/PG de la bestia activa.
  Merge de biblioteca aplica el mismo criterio desde el World vivo, sin
  copiar la reserva llena ni sumar vitalidad nativa a los PG de bestia.
- ASI físico permanece guardado para revertir; ASI mental/hechizos/nivel
  siguen disponibles en el personaje. No puede conjurar como bestia; al
  revertir usa el hechizo nuevo. Daño sobrante alcanza solo PG originales.
- Cambiar estadísticas guardadas no es una transformación nueva: reloj
  conserva el deadline original, también al pasar L3 → L4. A mitad de hora,
  la reproducción anterior movía caducidad 3600 → 9000; ahora se conserva y
  expira recuperando la forma original progresada. No cambia Codec/structs.
- **12 pruebas nuevas** (nueve puras, dos Game/TestModel y una web), **158**
  focalizadas, **2201 passed / 3 excluded** (32,8 s), compile sin warnings,
  formato/diff correctos. Biblioteca/Game pausado/reabierto, tool DM,
  idempotencia/codec/PG/CON/DEX/CA/spells/slots/ledger/deadline y ficha desktop/
  móvil verificados. Bestia **6/11**, vuelta nativa **7/29** en fixtures;
  no se atribuyen a un nuevo playtest live. `/tmp/dragonex-wild-progression-*.log`.
  Identificación visible y vitalidad nativa entregadas después en D130.

### Reservas factuales para DM y PCs (D128), 2026-10-02

- El brief muestra disponible/máximo de los seis pools de clase desde la
  ficha viva, usando los mismos metadatos que la mesa (`ClassResources.pools`).
  Capacidad aún bloqueada no se ofrece y legacy nil se trata conservadoramente
  como cero disponible sin mutarlo. No se reconstruye una reserva llena.
- Incluye dados de golpe restantes desde el ledger de World, flags de Segundo
  aliento/Oleada de acción/Recuperación arcana/Canalizar divinidad con sus
  desbloqueos modelados, y forma de bestia activa con bloqueo de conjuros.
  Ausentes no aportan reservas a la escena; un PNJ común no adquiere dados de PC.
- **17 pruebas nuevas** (14 puras, dos smokes DM/PC y un Game), **62**
  focalizadas, **2189 passed / 3 excluded** (32,3 s), compile sin warnings,
  formato/diff correctos. Pago real, unlock, forma animal, ledger/Codec y
  siguiente beat DM con reserva agotada verificados; no se cambia ninguna regla.
  `/tmp/dragonex-resource-context-*.log`.
- Sira real `/games/19419` pregunta por su reserva agotada: respuesta propia
  coherente, **16,08 s** al turno humano; **0/2 puntos**, cuatro casillas,
  **8/14 PG**, escena/reloj/rest_state/pausa/cursor conservados en Postgres.
  Ficha/recarga 375/1440 px sin JS/overflow; `resource-context-*` en playtest.
  Continúa la progresión con Forma salvaje activa y la calidad del grupo.

### Nombres cortos y atribuciones completas en la narración (D127), 2026-10-02

- Apertura real de Sira conservada como fixture. El recorte reconoce el nombre
  corto solo cuando tiene un propietario único entre PCs/PNJs registrados;
  retira la acción acotada de `cuando Sira deja…`, conservando olor a ozono,
  mensajero y su cita. No se reescribe la apertura histórica de la partida.
- Nombres completos tienen prioridad en citas: `Lyra del Mar`/`Lyra del Muelle`
  no se confunden con `Lyra`. La limpieza del nombre propio al empezar también
  respeta esa prioridad. Voz propia, estados pasivos, preguntas y tildes
  verificados; homónimos cortos ambiguos no reciben un propietario inferido.
- Streaming de mesa, Events y guardrail reciben nombres de World. Las formas
  `cuando`/`mientras` se recortan localmente con predicado inmediato y límite
  de cláusula; otras formas/pronombres/PNJs no registrados siguen bajo D29.
- **17 pruebas nuevas** (13 texto/detector, dos Game y dos web), **114**
  focalizadas y **2172 passed / 3 excluded** (31,9 s), compile sin warnings,
  formato/diff correctos. Game/TestModel verifica persistencia/historial sin
  cambios de PG/recursos/escena/reloj/rest_state; mesa verifica la burbuja real.
  `/tmp/dragonex-short-name-*.log`. Continúa el contexto factual de reservas
  para los agentes y el seguimiento de partidas reales.

### Recursos de clase ganados y visibles al progresar (D126), 2026-10-02

- Constructor y subida dejan de divergir al desbloquear ki, Fuente de magia
  y Forma salvaje: L1 → L2 aporta dos puntos/usos. Luego ki/hechicería ganan
  solo el punto nuevo y un paladín cinco de Imposición de manos. ASI de Carisma
  amplía Inspiración bárdica/Sentido divino solo si aumenta su capacidad.
- `ClassResources` es puro y compartido por LevelUp/merge/ficha. El pool vivo
  gana la diferencia de capacidad, conservando gasto; sync repetida/codec/
  reapertura no recargan. Flags/PG/reloj/rest_state se conservan y el descanso
  real mantiene su propia recarga. No cambia Character ni añade multiclass.
- La ficha propia muestra disponible/máximo de los seis pools modelados;
  capacidades aún bloqueadas no se presentan. Estado agotado ahora legible
  con el color secundario D84; PubSub y ficha móvil conservan valores reales.
- **16 pruebas nuevas** (12 motor, dos Game/TestModel y dos web), **238**
  focalizadas, **2155 passed / 3 excluded** (32,1 s), compile sin warnings,
  formato/diff correctos. Cuatro expectativas antiguas de remaining exacto
  y una de Fuente de magia pasan al contrato de gasto conservado/capacidad
  nueva; alcance explicitado en D126. `/tmp/dragonex-class-progression-*.log`.
- Sira propia `/heroes/5898`, partida `/games/19419`: L1 → L2 desde web,
  **2/2 → 0/2 puntos**, **3 → 4 casillas** pagando Fuente de magia; **8/14 PG**,
  reloj 0/rest_state vacío y pausa/cursor conservados. **31,29 s** al siguiente
  turno humano; ficha/recarga a 375/1440 px sin JS/overflow.
  `/tmp/dragonex-playtest/class-{progression,pool}-*`. Apertura real inventa
  `Sira deja caer…` usando nombre corto; continúa como nueva regresión narrativa,
  sin reescribir eventos anteriores ni afirmar que el proveedor siempre obedezca.

### Confirmaciones vigentes y progresión durable (D125), 2026-10-02

- La web confirma el nivel que vio el jugador. Biblioteca releída/bloqueada
  dentro de transacción, compartida con concesión de XP; una pestaña anterior
  no aplica otra subida ni gasta ASI de un nivel posterior. API sin expectativa
  mantiene progresión explícita; milestone/XP no cambian de política.
- Game rechaza fichas de menor nivel antes de tocar World/snapshot. El merge
  puro también conserva el mundo ante una ficha antigua. Partidas iniciadas
  se sincronizan por su Game, rehidratándolo si falta; solo configuración
  admite escritura directa con bloqueo frente al inicio.
- Layout de LiveView muestra avisos/errores de redirección, antes invisibles:
  mensaje completo, status/alert y cierre por teclado. Confirmación deshabilitada
  durante envío. Regresiones siguen la redirección y comprueban pantalla/cierre.
- **6 pruebas nuevas**, **45** focalizadas y **2139 passed / 3 excluded**
  en base separada (31,5 s), compile sin warnings, formato/diff correctos.
  Casos anteriores en rojo/verde, sala preinicio, proceso ausente, pausa/
  reapertura, XP y baseline de ficha conservados. No se afirma carga concurrente
  de conexiones independientes. `/tmp/dragonex-level-{confirmation,monotonic,flash}-*.log`.
- Mara propia `/heroes/5164`: dos pestañas por teclado, una subida L1 → L2,
  otra rechazada con aviso visible/cerrable. Ficha **8/14 PG**, **2/2 d6**.
  Sus **seis partidas** conservan pausa/cursor/escena/reloj/PG/rest_state;
  dos pools pasan 1 → 2, los otros cuatro 2 → 3. Arena/ficha recargadas a
  375/1440 px sin JS/overflow. Postgres leído sin otro Game escritor;
  `/tmp/dragonex-playtest/level-up-*`. Continúa la revisión de recursos
  de clase y recorridos con múltiples agentes.

### Subir de nivel conserva las casillas gastadas (D124), 2026-10-02

- World/tool del DM y merge de biblioteca usan la misma ampliación de capacidad:
  maga L1 con dos usos gastados gana una casilla al llegar a L2, sin descanso
  implícito. Niveles nuevos/half-casters ganan capacidad nueva; un reintento de
  sincronización no rellena reservas. HP/condiciones/reloj/límites de descanso
  se conservan y los dados de golpe ganados se derivan del nivel.
- Pact Magic conserva el total de usos gastados al cambiar de nivel de casilla
  o ampliar su único pool. Fuente de magia conserva excedentes pagados, incluso
  niveles fuera de la tabla diaria. Legacy sin seguimiento se inicializa;
  claves ausentes dentro de un pool registrado cuentan como agotadas.
- **16 pruebas nuevas**, **89** focalizadas y **2133 passed / 3 excluded**
  en base separada (30,9 s), compile sin warnings, formato/diff correctos.
  Game/TestModel/tool DM, confirmación LiveView, pausa/reapertura, idempotencia,
  codec y descanso real verificados. Dos expectativas antiguas que exigían
  rellenar casillas se ajustan al contrato AC-8.4.
  `/tmp/dragonex-level-resources-*.log`. Recorrido de progresión real preparado
  con Mara L1 y seis partidas propias pausadas; continúa la revisión de
  confirmaciones obsoletas antes de aplicarlo desde navegador.

### Voz propia y sujetos correctos en la narración de PCs (D123), 2026-10-02

- Frase real de Iria guardada como fixture: se retira `Lyra, que sigue
  hojeando…` conservando referencia/preguntas. El recorte de acciones/citas
  ajenas se aplica también a narradores PC, excluyendo al actor real.
  Misma limpieza para streaming/Events y texto recibido por el siguiente agente.
- Predicados de acción se vinculan al sujeto inmediato, con aposición/`ya`;
  no se toma `Sena abre` para `Lyra está herida`. Relativas proactivas acotadas
  se recortan localmente; PNJs/estados pasivos/voz propia se conservan.
  Continúan los límites explícitos de D29 para otras formas de prosa libre.
- **11 pruebas nuevas**, **85** focalizadas y **2117 passed / 3 excluded**
  en base separada (30,4 s), compile sin warnings, formato/diff correctos.
  Fixture/historial de Game/TestModel, recursos y atribución comprobados;
  dos reproducciones extra evitaron un falso recorte por verbo de PNJ.
  `/tmp/dragonex-pc-{voice,subject}-*.log`.
- Mesa propia `/games/17373`, nueva variante de pregunta: **Iria → Nera →
  Lyra → DM → Iria**, **17,12 s**. Opiniones propias, PG/casillas/escena/reloj
  conservados y cola liquidada; pausa/reload a 375/1440 px sin JS/overflow.
  No se reescriben los eventos anteriores. `/tmp/dragonex-playtest/pc-voice-*`.
  La fixture determinista demuestra el recorte; la muestra live demuestra
  este recorrido y no garantiza cualquier redacción del modelo.

### Admisión recuperable y validación aislada (D121–D122), 2026-10-02

- Unión e inicio bloquean/releen la sala vigente: copias anteriores no
  admiten plazas extra, pierden fichas ni escriben el World iniciado.
  Identidad duplicada/case/DM se rechaza sin cambios; un reintento conserva
  plaza/personaje y volver a iniciar no despausa ni resetea el cursor.
- La sala muestra motivo junto al selector y refresca el estado ante plazas
  agotadas/inicio. Aviso accesible, reintento limpia el error; IDs inválidos
  conservan el socket y sala eliminada vuelve a partidas con explicación.
- Verificación visual detectó el aviso fuera de pantalla por teclado en móvil;
  ahora aparece completo junto a la elección, enlazado con `aria-describedby`.
  Dos cuentas reales en `/games/19212`: error → Enter → grupo compartido,
  recarga a 375/1440 px sin JS/overflow. Sala configurada, sin beats de IA.
  `/tmp/dragonex-playtest/lobby-admission-*`.
- Durante el gate se reprodujo que runtime heredaba `DB_NAME=dragonex_dev`
  incluso bajo test. D122 usa `dragonex_test` o `DB_TEST_NAME` explícito;
  base creada/migrada sin modificar desarrollo. Sala real sigue intacta.
- **18 pruebas nuevas** de admisión/LiveView y **3** de runtime; **35**
  focalizadas, **2106 passed / 3 excluded** en base test separada (30,3 s),
  compile sin warnings, formato/diff correctos. Las pruebas de plazas usan
  copias obsoletas deterministas, sin afirmar una carga concurrente.
  `/tmp/dragonex-lobby-isolated-{focus,full}.log`, `dragonex-repo-config-red.log`.

### Respuestas reales de los compañeros interpelados (D120), 2026-10-01

- `request_response` registra una pregunta explícita a 1–5 PCs presentes,
  capaces y participantes. El Game les da un beat en orden, cierra con DM y
  devuelve el turno al humano; el modelo no inventa sus respuestas. Origen
  IA no recibe otro turno automático y responder no abre una cadena nueva.
- Cola durable en World/Codec, pregunta scrubbed/acotada, reintento idéntico
  sin repetición. Pausa/recarga y fallos terminales conservan pendientes.
  Caídos se omiten antes del beat; intenciones humanas/re-eval/mini/combat
  conservan prioridades y escena nueva o combate cancelan el intercambio.
- **24 pruebas nuevas**, **49** focalizadas y **2085 passed / 3 excluded**
  (22,0 s), compile sin warnings, formato/diff correctos. Controles de schema,
  roles, recursos, historial compartido, compatibilidad y contador TM.
  `/tmp/dragonex-conversation-*.log`.
- Mesa propia `/games/17373`: **Iria → Nera → Lyra → DM → Iria**, **25,26 s**,
  voces verificadas por eventos. PG/casillas/escena/reloj conservados; petición
  liquidada, pausa/reload sin JS/overflow a 375/1440 px. Agentes actualizados
  desde Ajustes manteniendo selección. `/tmp/dragonex-playtest/conversation-*`.
  El modelo debe reconocer la pregunta y llamar la tool; la muestra real
  comprueba ese recorrido, sin prometer obediencia de cualquier proveedor.

### Gestos y diálogo de PCs fuera de la voz del DM (D119), 2026-10-01

- Nueva apertura real de seis PCs convertida en fixture. Predicados directos
  con aposición y `comenta` reconocidos sin tomar el verbo de un PNJ posterior
  para el PC; estados pasivos y narración propia del PC se conservan.
- Citas implícitas sucesivas/streaming mantienen el hablante retirado hasta
  una voz PNJ explícita o cláusula de mundo. Persistencia e historial usan
  el mismo recorte, sin alterar eventos anteriores.
- Nueve pruebas nuevas; **61** focalizadas y **2061 passed / 3 excluded**
  (21,5 s), compile sin warnings, formato/diff correctos. Aislada también
  fixture de login que colisionaba con correos de ejecuciones anteriores.
  `/tmp/dragonex-puppet-{gesture,speaker}-*.log`.
- En `/games/17373`, pregunta a Nera/Lyra vuelve al humano en **14,05 s**
  pasando solo por DM, sin dar turno de respuesta a esos PCs. PG/casillas
  conservados, pausa/reload sin JS/overflow. El fallo de coordinación se
  corrige en D120; la sanitización no lo sustituye.
  `/tmp/dragonex-playtest/party-dialogue-*`.

### Grupo completo y fichas de escena presentes (D118), 2026-10-01

- Los seis PCs aparecen en exploración, con la ficha propia primero y sin
  que PNJs desplacen compañeros. Ausentes se excluyen de las fichas de escena;
  PCs caídos se mantienen. Carriles con scroll y suplemento de dos no-PCs vivos.
- Cajón móvil muestra compañeros con PG/CA/estados en ambas fases; DM
  creador consulta el grupo completo. Apertura del `details` nativo conservada
  ante patches, sin bloquear las actualizaciones de datos.
- Siete pruebas nuevas, incluyendo daño por DM a través de Game/Postgres/LV;
  **26** focalizadas y **2052 passed / 3 excluded** (21,2 s), compile sin
  warnings, formato/diff correctos. `/tmp/dragonex-party-*.log`.
- Mesa propia `/games/17373`, seis PCs: 375/1024/1440 px, teclado, PubSub,
  inspección DM, pausa/reload sin JS/overflow. Nera del Camino, exploradora
  propia `/heroes/5474`, creada para completar el grupo. Diana de `/games/16629`
  retirada y ausente de la vista, ficha guardada a 8/20 y Mara con una casilla.
  `/tmp/dragonex-playtest/{party-*,presence-cards-*}`. Continúa el objetivo:
  el setup nuevo contiene diálogo de Lyra inventado por DM, próxima regresión.

### Asistentes por teclado y borrador visible (D117), 2026-10-01

- Tarjetas de héroe/partida son botones nativos con foco/selección accesibles;
  hechizos, habilidades e idiomas anuncian su estado. Controles de 44 px,
  etiquetas asociadas y compañeros ocupados deshabilitados.
- Selección conserva el valor ante metadata nativa de LiveView; regresión
  reproduce el envío real. Texto custom reaparece al volver atrás/cambiar
  escenario dentro del mismo asistente. Diseño pixel D84 conservado.
- Seis pruebas nuevas; **32** focalizadas y **2045 passed / 3 excluded**
  (19,9 s), compile sin warnings, formato/diff correctos.
- Recorrido real por Tab/Enter/Espacio: Iria del Alba, clériga humana,
  `/heroes/5425`, guardada/reabierta; partida `/games/17032` con Mara y Vex,
  título/escena/estilo conservados y pausa/reload. 375/1440 px sin JS/overflow.
  `/tmp/dragonex-wizard-*.log` y `/tmp/dragonex-playtest/wizard-*`.
  Continúa la revisión del grupo completo en mesa, esperas y juego con PCs IA.

### Iniciativa automática visible y recuperable (D116), 2026-10-01

- Tiradas automáticas registradas con el roller de Game, publicadas una vez
  en historial/PubSub/modal tras admitir el cambio de World. La iniciativa
  explícita no se duplica; enemigos preexistentes no disparan la transición.
- Un fallo terminal después de introducir un hostil abre combate antes del
  fallback, conservando resultados y el primer slot aún sin jugar.
- Cinco regresiones nuevas, **39** focalizadas y **2039 passed / 3 excluded**
  (18,7 s), compile sin warnings, formato/diff correctos. Evidencia
  `/tmp/dragonex-forced-initiative-*.log`.
- Arena propia `/games/16629`: ambas tiradas en modal y crónica al retornar
  la diana; ficha conserva 8/20 PG y Mara una casilla. Pausa/reload a 375 px
  sin errores JS/overflow. `/tmp/dragonex-playtest/forced-dice-live.log`.
  Continúan el ritmo con varios PCs, progresión y recorridos por teclado.

### Presencia de escena sin perder la ficha (D115), 2026-10-01

- DM registra salida/reentrada de no-PCs. Ficha, PG y recursos sobreviven en
  World/Codec; objetivos, iniciativa, áreas, auras y briefs excluyen ausentes.
  La salida termina concentración y su turno principal activo, sin simular
  una muerte. Retorno conserva presupuesto/ledger y entra como refuerzo final.
- Acciones preparadas rechazan un objetivo que salió; fallo del actor conserva
  una salida comprometida. Guardar/reabrir y JSON legado comprobados. Es
  presencia de escena, no una mecánica nueva de persecución/huida ni movimiento de PCs.
- 23 pruebas nuevas; **52** focalizadas y **2034 passed / 3 excluded** (18,5 s),
  compile sin warnings, formato/diff correctos. `/tmp/dragonex-scene-*.log`.
- Arena real `/games/16629`: diana a 8/20 PG tras Magic Missile, Mara con una
  casilla; retirada cierra combate y reentrada conserva ambos valores.
  Pausa/reload a 375/1440 px sin errores JS/overflow. Evidencia
  `/tmp/dragonex-playtest/presence-live.log` y capturas/estados. Continúan
  auditoría de dados automáticos (resuelta en D116), ritmo con varios PCs y UX por teclado.

### Reacción pendiente al reabrir partida (D114), 2026-10-01

- Bootstrap recupera tipo de mini-turn y dueño interrumpido desde el World
  persistido. Humano, PC IA y monstruo DM no pierden su turno principal por
  resolver una reacción después de reabrir.
- Fallo posterior a Escudo conserva casilla/postura/reacción comprometidas;
  vuelve al principal sin renovar presupuesto ni Segundo aliento.
- Cuatro regresiones rojo/verde y **42** focalizadas; **2011 passed /
  3 excluded** (18,3 s), compile sin warnings, formato/diff correctos.
  `/tmp/dragonex-reaction-rehydration-*.log`. Sigue el trabajo sostenido
  sobre presencia de enemigos, turnos reales y UX.

### Iniciativa principal sin consulta redundante (D113), 2026-10-01

- Game impone el primer slot pendiente incluso ante una decisión válida del
  TM que salta/repite un actor. El retorno de mini-turn conserva al dueño y
  sus recursos; una reacción no se convierte en turno principal adicional.
- Relevos ordinarios de combate sin petición al TM; intenciones humanas,
  re-eval e interrupciones conservan consulta. Contexto del monstruo, efectos
  de inicio/dados, cierre por aura y persistencia usan el mismo camino.
- Once pruebas nuevas, incluyendo contador de modelo, Game/Postgres y cambio
  de ronda; **76** focalizadas y **2007 passed / 3 excluded** (18,2 s), compile
  sin warnings y formato correctos. Consultas anteriores siguen probándose
  con opción explícita, sin relajar la iniciativa. Evidencia
  `/tmp/dragonex-combat-handoff-*.log`; diff correcto.
- Arena propia `/games/16225`: turnos reales de Rayo ígneo en **8,46/13,01 s**,
  fallo/impacto con 9 de daño y dos casillas conservadas. Pausa/reload a 375/1440 px
  sin errores JS/overflow. Muestra pequeña frente a 43,53 s anterior, sin
  comparación controlada. `/tmp/dragonex-playtest/handoff-live.log` y capturas.
  Calidad global sigue activa: salida de enemigos y reanudación de interrupciones.

### Mesa compartida real y declaraciones consultables (D111–D112), 2026-10-01

- Sala de espera entra en mesa aunque el aviso llegue después de que Game
  espere a un humano o se pause; dos reproducciones con socket retrasado.
- Las declaraciones se pueden desplegar por toque/Enter, con texto literal,
  foco y control de 44 px. Narración conserva párrafos, IDs/historial y escape.
- Dos cuentas propias: Mara y Lena del Río, unión desde sala, solo el creador
  inicia, intenciones en pausa separadas por usuario y ambas resueltas al
  reanudar. Invitada conserva Lena ante selectores de Mara/DM y no obtiene
  inspección DM/ajustes. Pausa/reload y lectura a 375/1440 px sin errores JS
  ni overflow horizontal. Partida propia `/games/15574`.
- Cuatro pruebas nuevas; **1996 passed / 3 excluded** (18,0 s), compile limpio,
  formato/diff correctos. Evidencia `/tmp/dragonex-shared-quality-*.log` y
  `/tmp/dragonex-playtest/shared-verify.log`/capturas. El objetivo sigue activo:
  latencia y salida canónica de enemigos requieren otro bloque.

### Recuperación de combate por slots pendientes (D110), 2026-10-01

- Fallbacks de actor/TM dejan de depender del cursor anterior a un handoff.
  Eligen el primer slot pendiente del World; ronda nueva empieza por su
  primer combatiente, enemigos derrotados se omiten y PCs caídos conservan
  su turno de salvación.
- Iniciativa y ataque dentro del beat DM registran al monstruo real, sin
  repetir daño. Abrir combate sin acción no consume un turno. Narración DM
  sin slot no adopta al dueño anterior.
- Reacción exitosa/fallida vuelve al principal aún pendiente sin refrescar
  recursos; no cierra la ronda por ocupar el último nombre de la iniciativa.
- Catorce pruebas nuevas, rojo/verde, **79** focalizadas;
  **1992 passed / 3 excluded** (16,9 s), compile/formato/diff correctos.
  Evidencia `/tmp/dragonex-combat-{fallback,quality}-*.log`. Ajustado guion
  TestModel de contexto para cerrar cada decisión, y Sessions supervisados.
- Sigue la revisión de relevos principales válidos del TM, latencia, salida
  de enemigos y mesa compartida. La recuperación corregida no cierra por sí
  sola el objetivo de calidad jugable.

### Contrato de magia y ficha factual (D108–D109), 2026-10-01

- DM/PCAgent reciben un schema de `cast_spell` con tres argumentos
  obligatorios y tres opcionales/nulos. Un selector vacío se trata como
  ausente; una condición no vacía para otro hechizo se rechaza antes del gasto.
  Corrige la raíz de dos fallos reales de Lyra con sus casillas agotadas.
- Fichas/tracker muestran CA efectiva, estado vital y salvaciones pendientes.
  La ficha propia, también compacta en exploración, enseña dados de golpe,
  casillas restantes y Segundo aliento; ausencia de registro explícita.
  Armas/hechizos en español sin cambiar claves del motor.
- Barra de combate nombra al monstruo actual; distingue espera humana de
  resolución en curso. Sin escrituras de World desde LiveView.
- 13 pruebas nuevas; **1978 passed / 3 excluded** (16,8 s), compile sin
  warnings, formato y diff correctos. Evidencia
  `/tmp/dragonex-{spell,sheet}-quality-*.log`. Creada/recuperada desde navegador
  Mara de la Bruma, maga humana; en su partida propia dos Magic Missile
  gastan las dos casillas, infligen 11/14 de daño y cierran el primer combate.
  Relevos de 31,77/42,97 s; la nueva diana conserva el gasto anterior.
- Siguen abiertos la huida solo narrada y dos variantes de fallback: combate
  iniciado dentro del beat DM y cursor heredado después de un relevo del TM.

### Equidad de ronda tras un fallo del actor (D107), 2026-10-01

- Un beat que falla después de aplicar una acción conserva sus resultados y
  registra el turno principal gastado antes del relevo. Dos monstruos DM
  consecutivos dejan de volver a elegir al primero por un ledger incompleto.
- El último fallo principal cierra la ronda; una mini-interrupción fallida no
  consume el turno principal. El rechazo fuera de turno nombra al combatiente
  vigente y devuelve al agente una instrucción para terminar la narración.
- Cinco pruebas nuevas, rojo antes del arreglo y 61 focalizadas pasadas;
  suite **1965 passed / 3 excluded** (16,6 s), compile/formato/diff correctos.
  Evidencia `/tmp/dragonex-actor-{failure,quality}-*.log`.
- Playtest propio: batalla cerrada tras dos declaraciones humanas de ataque;
  relevos de **74,92 s** y **75,61 s**. Lyra conserva **3/7 PG y 0 casillas
  de nivel 1**, Thane 12/12, Vex 10/10; los tres enemigos a 0. Pausa en
  exploración, ronda 2. Sin errores JS. La muestra no certifica mejora de
  latencia. Sigue abierta una huida narrada que no retiró al enemigo del World.

### Narración, combate y contexto vigente (D103–D106), 2026-10-01

- **Fuga narrativa real reproducida y retirada**: cita del PNJ seguida de
  acción/diálogo inventados de Lyra y asentimiento de Vex. Se conserva Borin,
  estados pasivos, nombres compuestos y voz propia de los PCs. Mismo corte
  para streaming y texto persistido; la burbuja reinicia al cambiar de actor.
- **Aura que termina combate**: el último enemigo a 0 cierra la fase antes
  de esperar al humano, con un único evento de fin y dados en su fase
  original. Cuatro rutas de decisión/fallback verificadas contra Postgres.
- **TurnMaster sin snapshots antiguos**: cada relevo recibe solo su World
  vigente; mantiene feedback de validación dentro del beat, reacción humana,
  interrupciones y avance del modelo Test. El historial del DM/PC no cambia.
- **Borrador recuperable**: texto sin enviar sobrevive reload/cambio de vista
  en la pestaña; el acuse de Game retira solo el texto aceptado, sin volver a
  enviarlo al recargar. Navegador real sin errores JS en estos recorridos.
- 17 pruebas nuevas; suite **1960 passed / 3 excluded** (16,6 s), compile
  sin warnings, formato global y diff correctos. Logs
  `/tmp/dragonex-flow-quality-{compile,full}.log`, regresiones y pruebas de
  navegador en `/tmp/dragonex-playtest/`.
- Playtest propio `/games/14025`: exploración → asaltos → emboscada de
  dos goblins y lobo; ataques/dados, turno de Vex y PG de Lyra actualizados.
  **28,69 s** hasta el siguiente turno humano en exploración; **116,90 s**
  al recorrer la emboscada. Un error de ataque fuera de turno y un fallback
  del TM observados; no se considera resuelto aún el objetivo de fluidez.


### Mesa compartida e historial estable (D101–D102), 2026-10-01

- **Cada usuario juega su personaje**: ni la URL ni un patch permiten
  asumir otro PC o ver secretos como DM. Auto-play y declaraciones usan la
  identidad autenticada; el creador conserva inspección DM y retorno al PC.
- **La crónica permanece al llegar eventos**: ventana retenida, turnos
  reagrupados entre páginas y retry que elimina su texto truncado. Las páginas
  privadas no dejan al jugador sin acceso al historial público anterior.
  Límites de 2000 eventos/400 bloques sin ocultar los turnos recientes.
- **Uso móvil/teclado**: pausa/reanudación visible, controles de 44 px,
  ficha con botón nativo y estado accesible, seguimiento del último turno
  tras resize y retorno al final al leer mensajes antiguos.
- **Declaraciones claras**: un envío fallido conserva el texto y explica la
  recuperación; enviar en blanco no elimina el plan pendiente. La inspección
  DM ofrece volver al personaje para actuar.
- 12 pruebas nuevas; suite completa **1943 passed / 3 excluded** (15,7 s),
  compile sin warnings, formato global y diff limpios. Navegador real a
  1440/390 px sin errores JS en ficha, intenciones y cambio de vista.
  Evidencia en `/tmp/dragonex-playtest/` y `/tmp/dragonex-web-quality-full.log`.
  El playtest vivo detecta diálogo/reacción inventados para PCs; sigue abierto
  el bloque de coherencia narrativa y campañas largas.

### Inicio de turno y coherencia de agentes (D100), 2026-10-01

- **Spirit Guardians consume los recursos de salvación**: Inspiración e
  Indomitable dejan de reutilizarse en concentración o en el siguiente tick.
  Consumo correcto incluso con inmunidad radiante; daño preparado valida la
  ficha original. Cuatro regresiones reproducidas en rojo antes del fix.
- **Inicio de turno compartido**: relevos del TurnMaster, sus fallbacks y el
  fallback del actor pasan por `Game.Combat.start_turn`. Tras un error del
  actor se sincronizan combatiente/cupos/efectos antes del beat siguiente.
- **Dados trazables**: repetición de Hold Person y aura/concentración de
  Spirit Guardians usan el roller de la partida; eventos `:dice` persistidos
  y publicados al modal después de aplicar la transición, con `timing` y
  combatiente. El DM y el PC automático reciben estado y dados en su petición
  real a TestModel; no se depende de que inventen la resolución.
- **Sin repetición al cargar/interrumpir**: pruebas de re-selección, reacción,
  Codec y pausa → nuevo Game → reanudación conservan PG y grupos de dados.
- 13 pruebas nuevas; focalizadas **82/82**, suite completa **1931 passed /
  3 excluded**; compile con warnings-as-errors, formato global y diff limpios.
  Se conserva el trabajo previo del checkout. El alcance
  offline no certifica campañas largas ni latencia real.
- Smoke OpenRouter real: **3/3** en `flows/live_dm_test.exs` y
  `flows/live_smoke_test.exs` (37,5 s de suite): escena vía tool, iniciativa y
  ataque resueltos por el motor. No es un playtest largo de coordinación/latencia.

### Sesión 2, oleada F — Spiritual Weapon persistente y Spirit Guardians (D99), 2026-09-27

- **Spiritual Weapon persistente (D99)**: el lanzamiento consume la acción
  adicional (casting_time RAW) y deja una postura `%{dice, mod, rounds_left:
  10}`; nueva tool `espiritual_weapon_attack` (bonus action controlada por
  TurnBudget, D82) que repite el ataque por el pipeline completo de ataque de
  conjuro (RollLog, crítico, guided D95, faerie fire D97, bless); envejece
  solo en turno nuevo (cuello D44), relanzar sustituye; PCAgent con línea
  condicional.
- **Spirit Guardians recurrente (D99)**: al lanzar marca el aura sin daño
  (fuente D97); al inicio de cada turno nuevo del lanzador mientras
  concentra, cada enemigo vivo y consciente salva SAB con el stack completo
  (gnomo, aura, inspiración, Indomitable, RollLog); fallo 3d8 radiante,
  éxito mitad; el daño rompe concentración del enemigo vía pipeline; upcast
  +1d8/nivel; limpieza por las 5 rutas de concentración.
- **Revisión E aplicada**: las salvaciones de condición (hold/faerie/charm)
  ahora dejan su grupo `:save` en el RollLog vivo. Límite documentado: la
  repetición de turno de hold person no registra (el cuello
  `set_current_combatant` no recibe log; `game.ex` congelado esa tanda).
- Implementado por GLM‑5.3 max con revisión de Grok 4.7 high. 20 pruebas
  nuevas + 1 de RollLog. Suite completa **1918 passed / 3 excluded** (+21),
  compile/formato/diff correctos a la primera.

### Sesión 2, oleada E — Mage Armor y Charm Person (D98) + revisión D97, 2026-09-27

- **Mage Armor ejecutable (D98)**: condición con plazo de 8 h sin
  concentración; CA efectiva `max(ficha, 13 + mod DES)` mientras no haya
  armadura (el escudo no cuenta); renovación al relanzar. Implementado en
  `Rules.Effects.effective_ac`, visible en el brief sin mutar la ficha.
- **Charm Person ejecutable (D98)**: salvación de SAB con ventaja en combate;
  fallo → `charmed` 1 h con desventaja solo contra el lanzador; el daño del
  lanzador o su bando rompe el encanto (un daño sin atacante no lo rompe,
  documentado); humanoide abstracto como D97.
- **Revisión cruzada de D97 (GLM)**: núcleo validado; un hallazgo medio
  corregido — las salvaciones de condición (hold/faerie/charm y su repetición
  de turno) ahora usan el mismo stack que los hechizos (Astucia gnoma D71,
  Heightened D65, aura D61, inspiración bárdica, Indomitable D68, RollLog);
  y al liberar al último objetivo de hold person se libera también la
  concentración del lanzador (antes quedaba huérfana). Cobertura ampliada
  (kobold/reptilian, aura).
- Implementado por Grok 4.7 high (P10 + fix) con revisión de GLM‑5.3 max.
  Suite completa **1897 passed / 3 excluded** (+14), compile/formato/diff
  correctos a la primera.

### Oleada noche D — Hold Person y Faerie Fire (D97), 2026-09-26

- **Hold Person ejecutable (D97)**: salvación de SAB; fallo → `paralyzed`
  vinculado a concentración (fuente `hold_person:<lanzador>`), repetición de
  la salvación solo en turno nuevo del objetivo. Simplificaciones
  documentadas: humanoide abstracto (kobold entra como reptilian y queda
  registrado), sin radio, repetición a inicio de turno.
- **Faerie Fire ejecutable (D97)**: salvación de DES; fallo → marca con
  ventaja cancelable para cualquier atacante contra el afectado, vinculada a
  concentración.
- **Limpieza por fuente generalizada**: `without_source` ya no se limita a
  bless/shield_of_faith — las condiciones de hold person y faerie fire se
  limpian por todas las rutas de fin de concentración (hallazgo de la
  revisión cruzada convertido en requisito).
- 15 pruebas nuevas (`hold_person_test.exs`, `faerie_fire_test.exs`),
  regresión de concentración/efectos/metamagia incluida. Implementado por
  Grok 4.7 high. Suite completa **1883 passed / 3 excluded**; compile/formato/diff
  correctos.

### Oleadas noche B/C — entradas inválidas, mapa de efectos, Sleep y Shield (D96), 2026-09-26

- **§7.6 entradas inválidas (D96 previa)**: 6 hallazgos con guardas tempranas y
  mensajes ES accionables (`invalid_inputs_test.exs`, 21 pruebas): heal con
  dados malformados, gramática de Dice cerrada (0d6/1d0/1d6d), rangos
  1..100 dados / 2..1000 caras dentro de `Dice.valid?`/`parse_expr` (cubren
  heal y toda ruta de expresión), **`apply_damage` con daño negativo
  aumentaba los PG temporales** (mutación real corregida), amounts no enteros
  en temp_hp/XP, spawn con nombre en blanco.
- **Mapa catálogo→ejecutable** (`tecnico/11-mapa-efectos.md`): 319 hechizos
  clasificados (28 ejecutables / 47 parciales / 244 descriptivos) con
  evidencia por rama, trampas documentadas y top 10 de candidatos con
  borradores de ADR.
- **Sleep ejecutable (D96)**: corrige el bug activo por el que el builtin
  5d8 sin tipo caía en la rama de curación y "curaba" a los enemigos. Pool
  RAW 5d8 (+2d8/nivel de casilla), enemigos vivos/conscientes ordenados por
  PG ascendente, primera criatura que no cabe detiene el reparto, 1 minuto de
  reloj, despierta al recibir daño (normal, incluido absorbido por
  temporales), sin salvación, Twinned no duplica pool.
- **Shield ejecutable (D96)**: postura de combate self-only con +5 CA
  efectiva (sin mutar `ac`, apila con Escudo de la fe y Defense), casilla
  nivel 1, expiración al inicio del siguiente turno del lanzador y en fin de
  combate, magic missile hace 0. Simplificación documentada: sin economía de
  reacción, armado en turno propio (patrón D64).
- **Revisión cruzada (oleadas A/B) y fixes**: la marca guided podía revivir
  entre combates si terminaba en la misma ronda (end_combat ahora borra las
  condiciones guided); rangos de dados unificados en `Dice`. Verificados sin
  defectos: cantrips D95 contra RAW, fixes P4 de condiciones.
- Implementado por GLM-5.3 max (P5/P7) y Grok 4.7 high (P6/P8) con gates
  serializados. Suite completa **1868 passed / 3 excluded** (+48 en B/C),
  compile/formato/diff correctos.

### Oleada noche A — trucos RAW, Guiding Bolt y auditoría de condiciones (D95), 2026-09-26

- **Escalado de trucos (D95)**: el daño escala con el nivel del personaje en
  los umbrales RAW 5/11/17 (`Rules.Cantrips`); eldritch blast simplificado a
  dados extra sobre una tirada, documentado en el ADR.
- **Hojas rancias corregidas sin migración**: `cast_spell` rellena solo campos
  `nil` de la ficha con el catálogo (builtin gana). Sacred Flame, Poison Spray
  (nuevo builtin), Vicious Mockery y Acid Splash ya tienen dados; acid splash
  simplificado a 1 objetivo.
- **Guiding Bolt ejecutable**: marca on-hit en `conditions` con caducidad
  perezosa derivada de `turn_state` (sin tocar hot paths de `world.ex`);
  consumo en la primera tirada posterior hit-o-miss de cualquier atacante;
  ventaja combinable vía `combine`; Twinned con dos marcas independientes.
  Simplificación vs RAW: caduca al INICIO del siguiente turno del lanzador
  (no al final).
- **Auditoría §7.4 condiciones y duración**: dos bugs reproducidos en rojo y
  corregidos — el inicio de turno apagaba Esquiva asombrosa (contrario a D64)
  y la carga de mundos legacy borraba Escudo de la fe (`seed_legacy` trataba
  nil→hechizo como fin de concentración). Verificados sin divergencia:
  inmunidades (una sola ruta), limpieza de bless/shield por todas las rutas
  de fin de concentración, plazos explícitos y no caducidad de condiciones
  sin plazo. No representados (documentado): distancia, alcance, cobertura,
  línea de visión, AoO.
- Implementado por GLM-5.3 max (P3) y Grok 4.7 high (P4) con ownership
  separado, reproducción en rojo previa y gates serializados. Suite completa
  **1820 passed / 3 excluded** (+44), compile/formato/diff correctos.

### Mejoras post-V1 — relevo y contexto factual (D93–D94)

- Relevo directo tras pregunta del DM al humano cuando D30 ya fuerza esa
  decisión: evita la llamada redundante al TM. Conserva consulta en combate,
  mini-turns, ambigüedad, re-evaluación e intenciones pendientes. 11 pruebas
  con contador de llamadas; ahorro en segundos aún no medido con proveedor real.
- Brief con CA efectiva, PG temporales separados, estable/caído/muerto e
  identidad canónica. Reutiliza reglas/traducciones y no muta World. 14 pruebas,
  incluidos smoke TestModel de DM y PCAgent.
- Implementado por GLM-5.3 max y Grok 4.7 high con ownership separado y gates
  serializados. Suite completa **1776 passed / 3 excluded**, compile/formato/diff
  correctos. Contrato y evidencia en
  [`producto/06-mejoras-post-v1.md`](producto/06-mejoras-post-v1.md).

### Primer corte jugable verificado — 2026-09-26

- Cuatro bloques V1.1–V1.4 verificados con alcance finito: acceso/builder,
  combate real en arena, microaventura con cierre narrativo, descanso y
  pausa/reanudación, mesa móvil y escritorio. Proveedor OpenRouter real.
- Corregidos ficha propia ausente en exploración móvil, «Actuar» durante pausa
  y nombre accesible del input. Una regresión LiveView nueva y comprobación
  de navegador; suite **1751 passed / 3 excluded**.
- Evidencia, IDs de partidas de prueba y límites en
  [`producto/05-cierre-version-jugable.md`](producto/05-cierre-version-jugable.md).
  Siguiente prioridad: latencia observada de turnos (19–42 s), no ampliar
  indefinidamente el catálogo. No certifica todas las clases ni campañas largas.

### Motor y reglas 5e
- ✅ Imposición de manos: purificación (D91/M33). `conditions_to_remove`
  opcional elimina `poisoned`/`diseased` por 5 puntos cada una; puede combinarse
  con curación en una acción. `amount: 0` solo purifica, sin estabilizar.
  Revalida fichas/plazos, conserva otros efectos y persiste reserva/acción.
  13 pruebas nuevas: 10 de motor, 2 smoke PCAgent y 1 Postgres/Game.
- ✅ Lesser Restoration ejecutable (D90/M65): elimina una condición elegida
  entre `blinded`, `deafened`, `paralyzed`, `poisoned` y `diseased`, con su plazo.
  `condition_to_remove` opcional en `cast_spell`; si hay varias exige elección.
  Una acción/casilla, sin curación, dados, concentración ni escalado; Twinned
  D65 con dos objetivos no-self. 18 pruebas nuevas: motor (15), PCAgent con
  JSON antiguo/nuevo (2), Postgres/Game con acción y plazos (1).
- ✅ False Life ampliado (D89/M23): `1d4+4`, +5 PG temporales por nivel de
  casilla superior, un solo dado y sin modificador de conjuración. Objetivo
  propio obligatorio; no activa Twinned. Una hora sin concentración; conserva
  el mayor valor y solo uno estrictamente mayor renueva fuente/plazo.
  13 pruebas nuevas: `false_life_test.exs`, `flows/false_life_test.exs` y
  `false_life_persistence_test.exs`, incluyendo RollLog y Postgres/Game.
- ✅ Spare the Dying ejecutable (D88/M64): estabiliza una criatura viva a 0 PG
  sin curarla, con una acción y ninguna casilla. Borra fallos y conserva el
  sentinel de estabilidad; rechaza muertos, constructos y no-muertos. Twinned
  admite dos objetivos distintos. PCAgent deja de pedir salvaciones al estable.
  13 pruebas nuevas entre `spare_the_dying_test.exs`,
  `flows/spare_the_dying_test.exs` y `spare_the_dying_persistence_test.exs`.
- ✅ Heal ejecutable (D87/M63): 70 PG a nivel 6, +10 por nivel superior,
  limitado al máximo y sin dados/modificador. Elimina `blinded`, `deafened`
  y enfermedad explícita `diseased`, con sus plazos; no veneno ni maldiciones.
  Una acción/casilla, sin concentración; self, caídos vivos y Twinned D65.
  Rechaza muertos/constructos/no-muertos y resultados preparados obsoletos.
  14 pruebas nuevas: `heal_spell_test.exs`, `flows/heal_spell_test.exs`
  (PCAgent/TestModel) y `heal_spell_persistence_test.exs` (Postgres/Game).
- ✅ Shield of Faith / Escudo de la fe (D86): +2 CA efectiva contra armas y
  hechizos de ataque, bonus action, una casilla y 10 minutos de concentración.
  Sin apilado entre fuentes; compatible con Defense y Twinned. CA base intacta,
  retirada por fuente y plazo persistidos. Ataque Extra recalcula y reporta
  la CA por golpe. 19 tests nuevos en `shield_of_faith_test.exs`,
  `flows/shield_of_faith_test.exs` y `shield_of_faith_persistence_test.exs`.
- ✅ Bless ejecutable (D85): +1d4 a ataques de arma/hechizo y salvaciones
  (incluidas concentración y muerte); hasta 3 objetivos a nivel 1 y uno más
  por nivel de casilla. Fuentes persistidas, sin apilado; al perder/reemplazar
  concentración o vencer el minuto desaparecen sus efectos. 23 pruebas nuevas
  entre `bless_test.exs`, `flows/bless_test.exs` y `bless_persistence_test.exs`.
- ✅ Consolidación D81–D83 (2026-09-26): daño preparado rechaza cambios de
  Inspiración/Indomitable del objetivo entre resolución y aplicación; dos
  regresiones reproducidas antes del fix. Recorrido determinista con héroe del
  builder, combate, descansos y tres arranques de `Game` desde Postgres en
  `game_engine_journey_test.exs`: conserva acción gastada, PG, dados de golpe,
  límite diario y plazo original de condiciones. Playtest visual/LLM real de
  este lote todavía pendiente.
- ✅ D81–D83: daño y concentración con una sola resolución por impacto;
  presupuesto persistido de acción/bonus/reacción y death save; interrupciones
  sin recarga de turno; dados de golpe finitos, descansos individuales y de
  grupo, límite diario y reloj de efectos persistido. Nuevas regresiones:
  `damage_pipeline_test.exs`, `turn_budget_test.exs`, `rest_clock_test.exs` y
  smoke determinista `flows/rest_clock_test.exs`. Detalle y límites en D81–D83.
- ✅ Primera pasada de invariantes de vida/actuación (D80, 2026-09-16):
  curación no resucita ni resta PG, salvaciones de muerte revalidadas en
  World, supervivencia solo al caer, concentración eliminada al caer a 0,
  bloqueo de acciones estando incapacitado y reserva de Manos impositoras
  revalidada. Cobertura y pendientes: [`tecnico/10-auditoria-motor.md`](tecnico/10-auditoria-motor.md).
- ✅ Revisión determinista de estabilización (2026-09-16): se borran los
  fallos anteriores al estabilizar y recibir daño vuelve a habilitar las
  salvaciones con contadores nuevos. Regresión en `stabilization_test.exs`,
  incluyendo críticos, daño cero y round-trip del Codec. Es una revisión
  acotada de M14, no una certificación de todas las reglas del motor.
- `Rules.Ability` (modificadores, competencia) + `Rules.Combat` (ataques,
  daño, críticos, salvaciones, chequeos, death saves, ventaja/desventaja).
- `World` — máquina de estados `:exploration`/`:combat`, change-fns puras,
   invariantes (damage floor 0, resist/vuln/immune D38, overlay Rage B/P/S D42,
   `temp_hp` absorbe primero D36, concentración D37, `controlled_by?/3`), `facts` durables
   (D16), condiciones, spell slots,
  `level_up`.
- `Rules.Conditions` — tabla M06: condición → ventaja/desventaja/auto-fallo
  en ataque, salvación y chequeo (cancelación 5e).
- Rasgos raciales y de clase automáticos (D66/D67/D68/D69/D71/D76, pasivas
    sin tool — el motor lee `Character.race`/`class` del builder D52): Lucky
   del mediano M50 (d20 efectivo 1 en ataque/salvación/chequeo → un reroll
   y se usa el nuevo; etiqueta "(Lucky: 1→N)" en el desglose; variantes
   `*_tagged` en `Rules.Combat` mantienen las firmas públicas), Resistencia
   implacable del semi-orco M51 (hook en `World.apply_damage/3` tras el
   auto-revert D63: hp 0 → 1 una vez por descanso largo; `long_rest`
   recarga, `short_rest` no), Indomitable del guerrero L9+ M52 (reroll de
   una salvación fallida —hechizo :save, turn_undead SAB, concentración
   CON, aliento D70— una vez por descanso largo, se usa el nuevo resultado;
   etiqueta "(Indomitable: X→Y)"; `long_rest` recarga), Savage Attacks del
   semi-orco M53 (en `Combat.damage_roll`, crítico melee de arma → UN dado
   del tamaño del arma extra, " (+N Savage)" en el desglose; distancia y
   hechizos no) y Astucia gnoma del gnomo M55 (ventaja en salvaciones
   INT/SAB/CAR contra magia — equivalencia: toda salvación de `cast_spell`
   :save y `turn_undead`; inyectada como fuente extra en
   `Conditions.save_mode/4`, `combine/2` la cancela contra Heightened
    D65/condiciones; etiqueta "(Astucia gnoma: ventaja)"; sin campos ni
     rests) y Resistencia enana del enano M60 (D76: mitad floor del
     daño "poison" en la capa D38 de `incoming_damage` — apilable con
     Uncanny Dodge D64: cuarto — y ventaja en la salvación :save de
     hechizos con `damage_type "poison"` vía fuente `dwarf_advantage:`
     en `Conditions.save_mode/4`; sin campos ni rests). Aliento de dragón del dragontino D70/M54: rasgo racial CON tool
    y campo `breath_weapon_used` — ver `Actions.breath_weapon` y la tool
    `breath_weapon` más abajo. Usos de Furia + Furia implacable del
    bárbaro D72/M56: `start_rage` gasta (`rage_uses_used`, tope
    `Progression.rage_count/1`, recarga sólo en long rest) y al caer a
    0 pg en furia un bárbaro L11+ salva CON vs `10 + 5 × éxitos`
     (`relentless_rage_successes`, aura D61 suma) para quedarse a 1 —
     ver más abajo. Expertise de pícaro y bardo D73/M57: tool
     `gain_expertise` (cupo por clase/nivel, doble competencia en los
     checks de skills elegidas) — ver más abajo.
 - `Actions` — puente intent→world (`attack` con Extra Attack 5e / D35,
       Sneak Attack D41, Rage D42 y Divine Smite D46, Hunter's Mark D55, Font of Magic D56, Cunning Action Hide D57, Danger Sense D58 y Evasión D59 (pasivas del motor en salvaciones), auras de paladín D61/D62 (pasivas: +CHA a salvaciones del side, inmunidad al miedo), Uncanny Dodge D64 (postura armable que mitiga el próximo daño), Metamagic D65 (armable: Empowered/Heightened/Twinned aplicadas y consumidas por el próximo hechizo que califique), `spell` automatic/attack/save + consumo de slot (upcasting D74: `cast_level` opcional escala con la tabla curada `Rules.Upcast`), False Life → temp_hp D36,
    concentración D37, resist/vuln/immune D38, `initiative`, `death_save`, `heal`,
     `second_wind`, `action_surge`, `flurry_of_blows`, `create_spell_slot`, `convert_to_sorcery_points`, `lay_on_hands`, `divine_sense`, `turn_undead`, `bardic_inspiration`,       `arcane_recovery`, `wild_shape`, `end_wild_shape`, `start_uncanny_dodge`, `breath_weapon` (D70: aliento racial del dragontino con salvación DES y daño de fuego por nivel, 1/descanso — short y long recargan), `gain_expertise` (D73: Expertise de pícaro/bardo), `short_rest`, `long_rest`, `check` — acepta skills con prof de ficha + JoaT D60, duplicada con Expertise D73). Con `RollLog` para dados estructurados.
 - `Tools` — `deftool`s que el LLM invoca: `make_attack`, `cast_spell`
    (con `cast_level` opcional para upcasting, D74),
    `roll_initiative`, `make_death_save`, `heal`, `grant_temp_hp`, `grant_xp`, `drop_concentration`, `start_rage`, `end_rage`, `start_reckless`, `end_reckless`,    `second_wind`, `action_surge`, `flurry_of_blows`, `hunters_mark`, `cunning_action_hide`, `create_spell_slot`, `convert_to_sorcery_points`, `divine_smite`, `end_smite`, `lay_on_hands`, `divine_sense`, `turn_undead`, `bardic_inspiration`, `arcane_recovery`, `ability_check`, `end_combat`,
   `short_rest`, `long_rest`, `spawn_monster`, `apply_condition`,
    `remove_condition`, `set_scene`, `establish_fact`, `level_up`, `roll_dice`, `wild_shape`, `end_wild_shape`, `start_uncanny_dodge`, `arm_metamagic`, `breath_weapon`, `gain_expertise`.
- `TurnPolicy.WorldDriven` — turno leído del World; un beat por monstruo
  (D34); el LLM no puede saltar/reordenar.
- `Codec` + `Store.Coded` — `World ↔ jsonb` simétrico (D8).
- `Dice` — RNG inyectable (`dic_ex`), `roll_expr/2` parser NdM±K.

### Partida (`Dragonex.Game`)
- GenServer on-demand por `game_id` (D5); rehidrata de Postgres, persiste
  tras cada beat (D3, D4).
- Bucle por turno: AI en `Task`s (no bloquea el GenServer), `:waiting` para
  humanos, `:paused`, `:ended`.
- **Robustez**: retries transient con backoff exponencial (1s→3s→10s, máx 3),
  retry `max_tokens` con nudge "SÉ BREVE", circuit breaker (D17), combate
  fantasma v1+v2 (D18), anti-loop PCs (Jaccard), anti-puppet DM (regla #14),
  anti-repetición DM, limbo de exploración, guardián de español, UTF-8 sanitize.
- Auto-play de PCs humanos (toggle 🤖 crea un `PCAgent`).
- Pausa/reanuda durable; rehidrata tras kill del proceso.

### Agentes
- `DM` — system prompt de 16 reglas, story bible horneada (prefijo cacheable,
  D20), tools con `max_retries: 3`, capabilities `Events` + `Compaction.Summary`.
- `PCAgent` — un agent por PC IA, personalidad por clase, tools restringidas,
  `instruction/3` adaptativa (caído→death_save, combate→targets, exploración).
- **`TurnMaster` (D25 + D27)** — orquesta turnos (`give_turn_to` / `cut_in` /
  `react` / `pass_to_dm` / `end_scene`). Micro-máquina `actor → turnmaster →
  handoff`. **No muta el World**. `WorldDriven` = fallback + circuit breaker.
  El brief lista **intenciones humanas pendientes**; un declare off-turn en
  `:waiting` ajeno re-evalúa al TM sin robar el floor si no decide. Combate
  con `acted_this_round` + mini-turnos. Modelo `Models.turnmaster/0` (barato,
  `max_tokens` 256). Spec: `TURNMASTER.md`.
- `History` — reconstruye contexto compartido desde `game_events` (D19);
  compresión de narraciones viejas, coalescing mismo-actor.
- `Brief` + `Instructions` — `world_brief` + instruction por turno.
- `Models` + `ModelConfig` — modelo-por-rol + selector runtime (D21).

### Creador de personajes (`Dragonex.Heroes`) — ex-"Fase 4"
- Builder nivel-1 → `Dragonex.Character`: razas + subrazas, clases,
  backgrounds, puntuaciones (standard array / point buy / explícito),
  equipment (grupos SRD + custom), spells (casters), skills, languages.
- Catálogos SRD: `Classes`, `Races`, `Backgrounds`, `Scoring`, `Equipment`
  (armas simple/martial, armaduras light/medium/heavy, escudos, gear),
  `Spells` (42 builtin), `SRDSpells` (**319** cargados de
  `priv/srd/spells.es.json`, generados por `scripts/import_srd_spells.py`).
- `Catalog` — capa de display/consulta: mezcla builtin + SRD + **custom**
  inyectado con `source: :builtin | :srd | :custom` (offline-safe).
- `Translations` — i18n ES/EN de todo el catálogo + tipos de daño/habilidades.
- `LevelUp` + `Progression` — subida 5e (más abajo).
- ✅ Golden SRD del creador (F6.5): 12 clases × L1/L3/L5 en
  `test/dragonex/heroes/srd_golden_test.exs`. Oráculos a mano; sin bugs
  de HP/AC/slots/saves vs SRD. Pact Magic (D40) y Sneak Attack (D41) en ✅.
     Feats / features por nivel (salvo Extra Attack D35, Pact Magic D40,
     Sneak Attack D41, Rage D42, Reckless Attack D44, Second Wind D45,
      Divine Smite D46, Action Surge D47, Fighting Style D48, Lay on Hands
      D49, Bardic Inspiration D50, Arcane Recovery D51, Divine Sense D52, Hunter's Mark D55, Font of Magic D56, Cunning Action Hide D57, Danger Sense D58, Evasión D59, Aura of Protection D61, Aura of Courage D62, Wild Shape D63, Uncanny Dodge D64, Metamagic D65, Indomitable D68 y spellcasting paladín/ranger L2) siguen en 🟡. Rasgos
      raciales: Lucky (D66), Resistencia implacable (D67) y Savage
      Attacks (D69) en ✅; Brave, Halfling Nimbleness, Darkvision y demás
      siguen 🟡.

### Contenido custom por usuario
- CRUD `custom_contents` (weapon/spell/item, unique por usuario) con
  **validación server-side** de mecánicas (dados parseables, kind de spell
  válido, ability válida, classes conocidas).
- LiveView `/mi-contenido` (3 pestañas, CRUD inline).
- Merge en `Catalog` con `source: :custom`; builder lo consume vía
  `custom: %{...}` + `extra_equipment`.

### Subida de nivel (XP 5e, D43)
- `World.grant_xp/2` + tool `grant_xp` (DM): suma XP, no sube de nivel,
  no toca hp/slots. D10 SUPERSEDED. Sin calculadora CR.
- `LevelUp.apply/2` — nivel+1 (tope 20), PG (dado medio + CON + racial),
  retro-CON, **RAW no cura** (D11), ASI a `[4,8,12,16,19]` cap 20 (D13),
  AC recalculada, hechizos nuevos (respeta `max_spell_level`), features.
- `World.level_up/2` (path DM) + `Tools.level_up` (excluye PCs humanos).
- Sync a partida viva: `Games.sync_hero_level_up` (DB) +
  `Game.sync_hero_level_up` (GenServer single-writer, D6) +
  `merge_character_level_up` (preserva hp dañado/conditions/slots/AC).
- UI: `HeroLive.LevelUp` (`/heroes/:id/level-up`) con ASI stepper + spell
  picker; `HeroLive.Show` callout si `Progression.can_level_up?/2` (tabla
  PHB; leftover UI D43 cerrado).

### Web / producto
- **Auth** — registro/login/logout (bcrypt, session cookies) vía
  `Accounts` + `UserAuth` plugs.
- **Heroes** — `/heroes` (galería), `/heroes/new` (creator 5 pasos),
  `/heroes/:id` (ficha), `/heroes/:id/edit`, `/heroes/:id/level-up`.
- **Partidas** — `/` (lobby: tuyas + con slots abiertos), `/games/new`
  (wizard 2 tabs), `/games/:id` (mesa + sala de espera multiplayer).
- **Mesa** (`GameLive.Show`): feed agrupado por turnos, dice modal (FSM),
  streaming token-a-token con anti-duplicación, paginación del log (tope 400
  bloques), modal Ajustes (provider/model/reasoning con restart), identidad
  por humano (`?as=<name>` + overlay), "Ver como DM". Responsive ≤720px
  (feed primero, ficha en drawer CSS).
- **Multiplayer** — `join_game` con slots abiertos, waiting room con share
  link, el creador pulsa "Empezar".
- **Diseño visual D84** (2026-09-26) — sistema "crónica de mazmorra en 16
  bits" en todas las páginas: ventanas pixeladas, crónica de pergamino en la
  mesa, sprites propios (`scripts/gen_pixel_sprites.py`) y fuentes
  autoalojadas. Revisado en escritorio (1440px) y móvil (390px).

### Mejoras transversales (ROADMAP) — todas hechas
- ✅ Cola de intenciones (`declare/3` off-turn, persiste en `games.intents`)
  **y alimenta al TurnMaster** (D27 + D28): brief + re-eval + anti-spam;
  fase en el intent; UI declara durante un beat; `cut_in` de reacción.
- ✅ Recorte estructural D29/D30 (voz PNJ, headers mid-prosa, pregunta del
  DM retiene el floor — cableado en `Game.Turnmaster`).
- ✅ Biblia siembra facts + PC IA no ejecuta solo en exploración (D32).
- ✅ **Refactor estructural D31** — `Game` 2273→~780 con satélites
  `Game.{Bootstrap,Beats,Settlement,Turnmaster,Combat,Persistence,Participants}`;
  `GameLive.Show` 1772→~440 (`Chat`, `Settings`, `Dice`, `Snapshot`,
  `Components`); `HeroLive.New` 1291→~500 (`Heroes.Draft` +
  `New.Components`). Sin cambio de comportamiento; suite al mismo verde que
  la recepción (605/606, el fallo es el D30 pendiente).
- ✅ Robustez del DM (`controlled_by?` directivo + `max_retries: 3`).
- ✅ Caching de prefijo (D20, medido 44–85%).
- ✅ Modelo-por-rol + `max_tokens` (D21).
- ✅ Compactación (`Compaction.Summary`, umbral 250k → efectivamente off con
  modelos de 1M; cableado y funcional).
- ✅ Iniciativa individual por monstruo (D34 / F6.4): un beat por
  combatiente; `World.current_combatant`; DM sigue como controlador.
- ✅ Concentración 5e (D37 / M24): `Character.concentrating` + Codec;
  CON save al daño; rotura a 0 hp / incapacitated-class; tool
  `drop_concentration`. D81/D83 unifican las salvaciones y añaden reloj;
   D85 añade el efecto numérico de Bless y su vínculo a objetivos.
- ✅ Resistencias 5e (D38 / M25): tres listas en `Character` + Codec;
  `apply_damage/3`; skeleton SRD; hellish resistance. Concentración
  post-resist; `temp_hp` sobre el amount modificado. Sin magic vs mundane.
- ✅ Pact Magic del warlock (D40): tabla PHB 5.1 (huecos 1º–5º del mismo
  nivel); consume el hueco de pacto, no el del hechizo; short rest
  restaura solo al brujo. Sin Mystic Arcanum (el upcast de daño entró
  en D74 para TODOS los conjuradores, warlocks incluidos vía hueco de
  pacto).
- ✅ Upcasting 5e RAW (D74 / M58): `cast_spell` gana `cast_level`
  opcional (nil = nivel base, compat hacia atrás) — gasta UNA casilla
  del nivel pedido y aplica el escalado EXACTO de la tabla curada
  `Rules.Upcast` (auditada contra RAW 2014: fireball +1d6/nivel s/3º,
  cure_wounds +1d8/n s/1º, magic_missile +1 dardo/nivel s/1º — mensaje
  con el nº real de dardos —, spiritual_weapon +1d8 cada dos niveles,
  vampiric_touch +1d6/n, prayer_of_healing/healing_word/burning_hands/
  thunderwave/shatter/lightning_bolt/blight/flame_strike). El dado
  extra se combina con la base ANTES de resolver: mismo RollLog, mitad
  de :save sobre el total escalado, crit dobla también los extra,
  Empowered D65 sobre los combinados; CD y concentración sin cambios
  (RAW). Errores NO mutan: cast_level < base, > 9, no entero, truco a
  nivel superior, sin casilla del nivel PEDIDO (el mensaje lo cita).
   Mensaje "(nivel N)" al subir. Heal añade escalado plano en D87.
   Excluidos documentados (ADR D74): mass_cure_wounds/sleep (motor sin dados reales /
  mal-modelado), multi-objetivo y multi-rayo (scorching_ray). Tests
  `upcast_test.exs` (24).
- ✅ Sneak Attack del rogue (D41): `div(level+1, 2)` d6; arma finesse o
  ranged; advantage o aliado consciente; disadvantage bloquea; primer
  hit de `Actions.attack`; crítico 2N d6. Sin grid ni once-per-turn
  entre varias llamadas.
- ✅ Rage del bárbaro (D42): `Character.raging` + Codec; melee
  `rage_damage/1` en cada hit; overlay B/P/S; no spells; STR check
  ventaja; termina en `end_rage` / 0 hp / unconscious / `end_combat`.
  Usos/día D72; reloj de 1 minuto y presupuesto bonus D82/D83.
- ✅ Reckless Attack del bárbaro (D44): `Character.reckless` + Codec;
  melee STR ventaja; cualquier ataque vs el bárbaro ventaja; expira
  al inicio de su turno (`set_current_combatant`); también
  `end_reckless` / 0 hp / unconscious / `end_combat`. Sin cupo/día.
- ✅ Second Wind del fighter (D45): `Character.second_wind_used` + Codec;
  `1d10+level` 1/rest; tool `second_wind`; `short_rest`/`long_rest`
  recargan.
- ✅ Action Surge del fighter (D47): `Character.action_surge_used` + Codec;
  tool `action_surge` = 1 Acción de Ataque extra (Extra Attack D35
  incluido) 1/rest desde L2; hit o miss gasta el uso; rest recarga.
  Sin L17 (2 usos). Sin Indomitable.
- ✅ Fighting Style del fighter (D48): `Character.fighting_style` + Codec
  (`archery` / `defense` / `dueling`); motor suma el bonus (D1); builder
  default `"defense"` sin picker. Sin Protection, TWF, GWF.
- ✅ Divine Smite del paladín (D46): `Character.smite_slot` + Codec;
  tool `divine_smite` arma pendiente (no gasta casilla); primer hit
  melee de `Actions.attack` consume el hueco y tira radiante
  (`2d8+(slot-1)d8`, tope 5d8; undead/fiend +1d8). Extra Attack: solo
  el primer swing que acierte. Sin Improved Divine Smite.
- ✅ Lay on Hands del paladín (D49): `Character.lay_on_hands_pool` +
  Codec; pool `5 * level`; tool `lay_on_hands(who, target, amount)`
  gasta `applied` y cura (self o aliado); long rest recarga, short
  rest no; undead/construct bloqueados. D91 añade purificación de enfermedad/veneno.
- ✅ Bardic Inspiration del bardo (D50): `Character.bardic_inspiration_uses`
  + `inspired` + Codec; usos `max(1, cha_mod)`; tool
  `bardic_inspiration(who, target)` gasta 1 uso y marca inspired;
  el motor aplica 1d6 al primer attack/check/save/death save (primer
  swing, hit o miss); long rest recarga usos y quita inspired, short
  rest no. Siempre d6. Sin Font of Inspiration ni colleges.
- ✅ Arcane Recovery del mago (D51): `Character.arcane_recovery_used` +
  Codec; tool `arcane_recovery(who)` restaura huecos gastados greedy
  (presupuesto `div(level+1, 2)`, ningún hueco > 5º); fuera de combate,
  1/long rest; short rest no recarga. Sin Signature Spells ni Spell
  Mastery.
- ✅ Divine Sense del paladín (D52): `Character.divine_sense_uses` +
  Codec; usos `max(1, 1 + cha_mod)`; tool `divine_sense(who)` gasta 1
  uso y reporta celestial/fiend/undead por `race`; combate permitido;
  long rest recarga, short rest no. Sin Channel Divinity ni 60 ft.
- ✅ Turn Undead del clérigo (D53): `Character.channel_divinity_used` +
  Codec; clérigo L2+ 1/rest; tool `turn_undead(who)` gasta y aplica
  frightened a no-muertos (`race`) que fallen Sabiduría vs DC
  `8+prof+wis`; combate y exploración; short y long rest recargan.
  Sin Destroy Undead, sin dominio, sin 30 ft.
- ✅ Ki + Flurry of Blows del monje (D54): `Character.ki` + Codec;
  máximo `level` (monk L2+, L1 → 0); tool `flurry_of_blows(who,
  target, mode)` gasta 1 ki y resuelve 2 golpes sin armas con el dado
  de artes marciales (`martial_arts_die/1`: 1d4/1d6/1d8/1d10 por
  tramo); combate permitido; short y long rest recargan al máximo.
  Sin Patient Defense, Step of the Wind, Stunning Strike, Deflect
  Missiles ni golpe extra de Martial Arts.
- ✅ Hunter's Mark del explorador (D55): sin campos nuevos — la marca
   vive en `concentrating` (`"hunter's mark:<presa>"`, D37) y gasta 1
   casilla de nivel 1 (`spell_slots`); tool `hunters_mark(who, target)`
   (ranger L2+, DM cualquiera, PC sólo sí mismo) valida who/target,
   caídos, ranger L2+, casilla y no-concentración antes de gastar; el
   motor suma +1d6 por impacto de arma contra la presa (crit dobla,
   tipo del arma, RollLog patrón sneak; spells y Flurry nunca; match
   exacto case-insensitive); fin sólo por las rutas existentes de
   concentración; rests sin cambios (RAW la marca persiste). Sin
   bonus action economy, tracking, múltiples presas, transferir ni
   Branding Smite.
 - ✅ Font of Magic del hechicero (D56): `Character.sorcery_points` +
    Codec (jsonb viejo → 0); máximo `level` (sorcerer L2+, L1 → 0);
    tools `create_spell_slot(who, level)` (nivel 1..5, coste RAW
    2/3/5/6/7 vía `sorcery_slot_cost/1`, puede superar el máximo
    diario) y `convert_to_sorcery_points(who, level)` (drena 1 casilla
    1..5 y recupera esos puntos con cap silencioso al máximo; el
    mensaje muestra el resultado real); DM cualquiera, PC sólo sí
    mismo; combate permitido; errores no mutan (missing who, caído, no
    hechicero, L1, nivel inválido, puntos insuficientes, sin casillas);
    SOLO long rest rellena al máximo (distinto del ki D54); level-up no
    resetea. Sin sorcerous restoration (Metamagic entró en D65).
 - ✅ Cunning Action (Hide) del pícaro (D57 / M41): sin campos nuevos —
    "hidden" vive en `conditions` (`apply_condition`, M06 le añade
    ventaja al atacar); tool `cunning_action_hide(who)` (rogue L2+, DM
    cualquiera, PC sólo sí mismo) valida who, caído, clase/nivel y no
    ya oculto antes de tirar; el motor resuelve 1d20 + DES + prof (si
    "stealth" entrenado; modo vía `check_mode`) vs la máxima
    percepción pasiva de enemigos conscientes (10 + SAB + prof si
    "perception" entrenada; DC 10 sin enemigos); éxito → "hidden" →
    ventaja en `make_attack` (cancela con desventaja, habilita Sneak
    Attack D41 sin aliado); el ataque (o hechizo de ataque) revela y
    quita "hidden" (hit o miss); RollLog patrón ability_check; errores
    no mutan. Sin Dash/Disengage (sin grid), sigilo sostenido,
    Uncanny Dodge, feats ni multiclase.
 - ✅ Danger Sense del bárbaro (D58 / M42): pasiva sin tool ni campos
    nuevos — `Rules.Conditions.save_mode/3` da ventaja en TODAS las
    salvaciones de DES del bárbaro L2+ (combinada vía `combine`: la
    desventaja de condición —restrained— se cancela a normal); corte de
    incapacitación = `@auto_fail_saves` (paralyzed/stunned/unconscious/
    petrified auto-fallan DES antes de computar la ventaja); el
    `mode_tag` existente muestra "(ventaja)"; WIS y otros saves no
    cambian.
  - ✅ Evasión del pícaro (D59 / M43): pasiva sin tool ni campos nuevos
     — en la rama `:save` de `cast_spell`, un pícaro L7+ ante un hechizo
     con salvación de DES recibe 0 daño si supera la salvación (aunque
     mitigara a mitad) y `div(full, 2)` si falla (aunque fuera daño
     completo); hechizo que ya haría 0 sigue en 0; inspiración bárdica
     aplicada antes activa Evasión; desglose "(Evasión: sin daño)" /
     "(Evasión: mitad)"; pícaro incapacitado auto-falla y no llega a
     aplicar Evasión; saves no-DES y daño sin save ignoran Evasión.
  - ✅ Proficiency de skills en ability_check + Jack of All Trades
     (D60 / M44): arregla el hueco v1 (la tool ignoraba
     `skill_proficiencies`). Nueva tabla `Rules.Skills` (18 skills SRD →
     característica, normalización espacios/guiones/mayúsculas,
     detección skill-primera — "intimidation" es CAR, no `int`); la tool
     `ability_check` mantiene arity y nombre de parámetro (compat:
     exAgent bindea args por nombre); skill entrenado → prof completa
     desde la ficha; sin entrenar y bardo L2+ → mitad (JoaT, floor);
     ability cruda → flag del caller (formato v1); mensaje ES con
     desglose ("chequeo de Sigilo (DES): 1d20(11) + DES 3 + prof 2…",
     "+ JoaT 1"); error directivo con ejemplos en desconocidos. Sin
     campos nuevos ni Codec; `cunning_action_hide` D57 intacta. Sin
      Expertise, tools/instrumentos, Reliable Talent, feats, multiclase.
   - ✅ Aura of Protection del paladín (D61 / M45): pasiva sin tool ni
      campos nuevos — todo paladín L6+ consciente suma
      `modifier(cha)` a TODAS las salvaciones de su `side` (él
      incluido): rama `:save` de `cast_spell`, `turn_undead` (SAB),
      death saves (RAW aplica; desplaza el umbral 10 sin tocar nat
      1/20 vía `Combat.death_save/2`) y concentración (CON al daño);
      varios paladines apilan; CHA < 10 → bonus negativo sin piso;
      se aplica antes de la inspiración bárdica (D50 re-deriva del
      total); desglose "+3 aura" / "(-1 aura)" en el mensaje; sin
      radio (simplificación sin-grid por side, regla genérica: un
      no-muerto aliado también lo recibe). NO a checks ni attack
      rolls. Sin Aura of Devotion/Hate, Improved Divine Smite.
    - ✅ Aura of Courage del paladín (D62 / M46): pasiva sin tool ni
       campos nuevos — `World.apply_condition` NO aplica
       "frightened" a quien comparte side con un paladín L10+
       consciente (él incluido): `{:ok, world}` sin mutar
       (inmunidad ≠ error); `Tools.apply_condition` (DM) devuelve "X
       es inmune al miedo (Aura de Coraje)" y `turn_undead` particiona
       sus fallidos en asustados/inmunes con la misma frase (doble
       hook: defensa en profundidad); regla genérica por side (un
       no-muerto aliado de un paladín L10+ es inmune, documentado);
       idempotencia y `remove_condition` intactos. Sin radio, sin
       inmunidad a charm (Aura of Devotion, futuro).
    - ✅ Wild Shape del druida (D63 / M47): `Character.wild_shape_uses`
       + `wild_shape` (mapa de forma guardada) + Codec (jsonb viejo →
       0/nil); catálogo fijo `Monsters.wild_shape_beasts/0` (cat ND 0,
       wolf ND 1/4, black_bear ND 1/2 — cat y black_bear nuevos en
       `Monsters`, también spawnables); tools `wild_shape(who, beast)`
       / `end_wild_shape(who)` (druida L2+, DM cualquiera, PC sólo sí
       mismo, errores NO mutan); al transformar gasta 1 uso SIEMPRE
       (2/rest), guarda str/dex/con/hp/max_hp/ac/weapons y aplica los
       de la bestia conservando mental/identidad/profs/condiciones/
       concentración (RAW); inventario intacto siempre; gate de CR
       L2–3 → 1/4, L4+ → 1/2; `cast_spell` bloqueado en forma (todo lo
       demás igual); revert manual restaura TODO con PG = orig exacto;
       auto-revert en `World.apply_damage/3` (cuello único): exceso =
       daño que sobra tras la bestia → `hp = max(0, orig_hp − exceso)`
       (temp_hp y resist como siempre) con nota en el log para la
        narración; short Y long rest recargan usos (como ki D54, sin
        forzar revert); level-up no toca usos ni forma. Sin duración,
        Circle of the Moon, formas volar/nadar, equipment merge.
    - ✅ Uncanny Dodge del pícaro (D64 / M48): `Character.uncanny_dodge`
       (boolean, default false; Codec tolerante a jsonb viejo) + tool
       `start_uncanny_dodge(who)` (pícaro L5+, DM cualquiera, PC sólo
       sí mismo, errores NO mutan: who inexistente, caído, no pícaro,
       L4–, ya armada); postura armable gratis en cualquier momento
       (sin reacciones ni rondas en el motor, patrón `inspired`/
       `reckless`); en `World.apply_damage/3` (cuello único): armada y
       amount > 0 → `div(amount, 2)` (floor) sobre el amount de
       entrada — antes de resistencias D38 y temp_hp D36 (orden fijado
       en D64) — y consume la flag; CUALQUIER fuente de daño; amount
       ≤ 0 no consume; apila con Evasión D59 (mitad de mitad = cuarto,
       floor); auto-revert D63 intacto (corre tras la mitigación);
        descansos NO gestionan la flag; rearmar tras consumir es
        gratis. Sin economía de reacción/ronda (1 uso por daño),
        resistencias dañinas, Deflect Missiles, feats, multiclase.
    - ✅ Metamagic del hechicero (D65 / M49): `Character.metamagic`
       (nil | `%{option, target}`, claves átomo en memoria/strings en
       Codec, jsonb viejo → nil) + tool `arm_metamagic(who, option,
       target)` (hechicero L3+, DM cualquiera, PC sólo sí mismo, UNA
       opción, SIN un-arm ni reembolso; errores NO mutan: who
       inexistente, caído, no hechicero, L2–, opción desconocida, ya
       armada, puntos insuficientes con coste exacto, heightened sin
       target, twinned sin target/inexistente/self); armar gasta 1/3/2
       puntos vía `spend_sorcery_points` (D56) y fija el mapa;
       aplicación y consumo SÓLO en `Actions.spell/5` → `resolve_spell`:
       Empowered (dados de daño — los primeros `max(1, CAR)` dados se
       tiran dos veces conservando el mayor, dos draws del roller por
       dado; crit dobla la base sin duplicar rerolls; fallo de :attack
       también consume; curación/utilidad nunca califican; etiqueta
       "(Metamagia: Empowered)"), Heightened (hechizo :save al target
       armado → salvación con desventaja como `requested` en
       `save_mode`, combinada por capas con D58-D62; otro objetivo → no
       aplica ni consume; etiqueta "(Metamagia: Heightened)"), Twinned
       (hechizo contra target ≠ lanzador → misma resolución también
       contra el segundo target armado, dados propios por resolución,
       bloque por objetivo, UNA casilla y UNA concentración; self-buff o
       twin desaparecido → no aplica ni consume); consumo-on-apply
       (divergencia menor de RAW documentada); rests y level-up NO tocan
       la metamagia (los puntos ya se recargan en long rest D56). Sin
       Quickened, Distant, Extended, Subtle, Careful (sin efecto en este
       motor), Sorcerous Restoration, Metamagic Adept, feats,
       multiclase.
    - ✅ Lucky del mediano (D66 / M50, pasiva racial sin tool): en las
       tres tiradas de d20 con personaje de `Rules.Combat`
       (`attack_roll`, `saving_throw`, `ability_check`), si el d20
       EFECTIVO (conservado tras ventaja/desventaja) es 1 → UN reroll
       y se USA el nuevo resultado (RAW "must use the new roll"; no
       keep-best; nat-1/20 del ataque sobre el dado final); el reroll
       pasa por el mismo roller (RollLog registra ambos dados);
       firmas públicas intactas vía variantes `*_tagged` que devuelven
       la etiqueta "(Lucky: 1→N)" pintada tras el dado en todos los
       desgloses (ataque, salvación de hechizo, concentración, chequeo,
       Sigilo); death saves no aplican; monstruos medianos también.
       Sin Brave/Halfling Nimbleness, feats, multiclase.
     - ✅ Resistencia implacable del semi-orco (D67 / M51, pasiva racial
        sin tool): `Character.relentless_endurance_used` (default false,
        jsonb viejo → false) + hook en `World.apply_damage/3` con orden
        de capas fijado (Uncanny Dodge D64 mitiga amount → resist D38 →
        temp_hp D36 → hp → auto-revert Wild Shape D63 → RE: hp 0 → 1
        con nota en el log "la furia semi-orca mantiene a X en pie con
        1 pg (Resistencia implacable)" → death saves); 1 uso por
        descanso largo (`long_rest` recarga vía
        `World.set_relentless_endurance/2`, `short_rest` no); ya gastada
        → 0 pg normal; al salvar a 1 no se limpian flags de caído.
        Sin Savage Attacks, Darkvision, feats, multiclase.
     - ✅ Indomitable del guerrero (D68 / M52, pasiva de clase sin tool):
        `Character.indomitable_used` (default false, jsonb viejo →
        false) + helper `maybe_indomitable/7` en `Actions` aplicado en
        los TRES sitios donde el personaje salva (hechizo `:save`,
        `turn_undead` SAB, concentración CON): fallo FINAL de un
        guerrero L9+ con el uso disponible → UN reroll con la misma
        llamada `Combat.saving_throw_tagged/5` (mismo modo de
        Heightened/Danger Sense/condiciones; el aura D61 se re-suma; el
        d6 bárdico se gastó en el primer intento; Lucky D66 puede
        dispararse gratis en el reroll) y se USA el nuevo resultado (RAW,
        no keep-best); marca `indomitable_used` vía
        `World.set_indomitable/2` (el struct actualizado viaja a la
        simulación de concentración y se hilva entre golpes de una misma
        acción — sin doble gasto); etiqueta "(Indomitable: X→Y)" en el
        desglose (totales; en turn_undead pegada al nombre); 1 uso por
        descanso largo (`long_rest` recarga, `short_rest` no); death
        saves y auto-fails fuera (no hay dado). Sin usos L13/L17,
        checks/attack rolls, feats, multiclase.
     - ✅ Savage Attacks del semi-orco (D69 / M53, pasiva racial sin
        tool, sin campos ni rests): hook en `Combat.damage_roll/4` vía
        nueva variante pública `damage_roll_tagged/4` que devuelve
        `{total, savage_die}` (firma de `damage_roll/4` intacta, patrón
        `*_tagged` D66) — `race == "half-orc"` + arma melee
        (`ranged != true`) + `:crit` → UN dado del TAMAÑO del arma (un
        2d6 añade 1d6, no otra tirada completa; nunca doblado); NO a
        distancia, hechizos ni no-críticos; apila con sneak D41 / smite
        D46 / mark D55 / rage D42; el golpe sin armas de Flurry D54
         también aplica; desglose " (+N Savage)" en el swing (patrón
         sneak). Sin Darkvision, feats, multiclase.
      - ✅ Usos de Furia + Furia implacable del bárbaro (D72 / M56):
         `Character.rage_uses_used` y `relentless_rage_successes`
         (integer default 0, Codec tolerante a jsonb viejo) +
         `Progression.rage_count/1` (L1–2 2, L3–5 3, L6–11 4, L12–16 5,
         L17+ 6). `World.start_rage/1` exige usos disponibles ("no le
         quedan furias hoy (N/N usadas)" sin mutar) y gasta 1 al ENTRAR;
         `end_rage` NO devuelve el uso; ya raging → idempotente sin
         gasto extra; sólo `long_rest` recarga. Furia implacable: hook
          `maybe_relentless_rage/5` en `World.apply_damage` (con
         parámetro opcional `roller`, hilvanado por
         `Actions.pipe_damage`), bárbaro L11+ raging a 0 pg →
         salvación CON vs `10 + 5 × successes` vía
         `Rules.Combat.saving_throw` (prof de CON + Lucky D66) + aura
         D61 (`World.aura_save_bonus/2`, movida de Actions); éxito →
         1 pg, successes+1 y nota en el log del world (sin RollLog a
         esa profundidad — la nota ES el registro); fallo → cae al
         siguiente check (RE racial D67 si semi-orco: ambas capas, el
         éxito de clase no consume la racial); orden de capas fijado
         Uncanny Dodge → resist → temp_hp → hp → revert → Furia
           implacable → RE. D81–D83 añaden pipeline único, bonus, reloj,
           Persistent Rage L15 y recuperación de la CD también en corto.
           Paths, furias ilimitadas L20, feats y multiclase siguen pendientes.
   - ✅ Expertise de pícaro y bardo (D73 / M57): `Character.expertise`
      (array de skills, default `[]`, Codec tolerante a jsonb viejo) +
      cupo `Progression.expertise_count/2` (rogue L1+ 2 / L6+ 4; bard
      L3+ 2 / L10+ 4; resto 0) + tool `gain_expertise(who, skill)` (DM
      cualquiera, PC sólo sí mismo, errores NO mutan en orden: who
      inexistente, caído, clase sin Expertise, nivel insuficiente para
      el primer cupo —bardo L1–2—, skill desconocida, skill sin
      competencia, duplicada, cupo agotado con el cupo actual y la
      lista). Elección modelada como TOOL, no en el builder/level-up
      (ADR D73: el LLM decide, el motor valida y persiste); skill
      normalizada vía `Rules.Skills`; permanente (sin rests). La
      resolución dobla la prof en `Combat.check_proficiency/3` (3er
      parámetro opcional `skill`, nueva kind `:expert`), hilvanado por
      `ability_check/7`/`ability_check_tagged/7` y consumido por las
      DOS rutas de checks con skill: `Actions.check` ("prof 4
      (experto)") y `cunning_action_hide` (D57: Sigilo doblado, "+4
      (experto)"). JoaT nunca aplica a una expertised; ability cruda
      sin skill y `passive_perception` nunca doblan. Allowlist PCAgent
      + línea condicional pícaro/bardo (sólo con cupo > elegidos) +
      línea DM. Sin Expertise en tools/instrumentos, picks 2024,
      integración con level-up choices, feats, multiclase.
    - ✅ XP 5e en partida (D43): `World.grant_xp/2` + tool `grant_xp` (DM).
   Suma XP; no auto-level-up. Subida explícita (ficha / `level_up`).
   D10 SUPERSEDED. Sin calculadora CR/encuentro.
    - ✅ Araña gigante + Resistencia enana (D75/D76, M59/M60): la
       araña (`Monsters.giant_spider/1`, key `"giant_spider"`, CR 1
       RAW: STR 15/DES 16/CON 12/INT 2/SAB 12/CAR 7, CA 14, 26 pg) es
       la PRIMERA fuente real de daño de veneno del motor — su mordida
       total es "3d8+3 poison" (dados "3d8" + mod DES +3 que el motor
       suma; simplificación ADR D75 del 1d8+3 perforante + 2d8 veneno
       con salvación CON de RAW, sin la salvación intermedia), +5 al
       ataque (DES), sin telaraña ni trepar. Con ella, la Resistencia
       enana (D76) deja de ser dead code: sin campos ni tools —
       (1) resistencia: un enano (`race == "dwarf"`) recibe la MITAD
       (floor) del daño "poison" en la capa D38 de
       `Character.incoming_damage/3` que `World.apply_damage/3-4`
       aplica tras Uncanny Dodge D64 (se apilan multiplicativamente:
       enano pícaro = cuarto, RAW; las simulaciones de concentración y
       multi-golpe quedan coherentes); (2) ventaja en la salvación de
       la rama :save de `cast_spell` cuando `damage_type == "poison"`
       (fuente `dwarf_advantage:` en `Conditions.save_mode/4`, patrón
       D71, cancelable; etiqueta "(Resistencia enana: ventaja)"; hoy
       el único hechizo así del catálogo es cloudkill del SRD).
       Tests `poison_test.exs` (14).

### Lote de corrección post-revisión (2026-09-15, FIX-1/FIX-2) ✅

Cierre de los hallazgos de la auditoría de producto+técnica (informes A y B).

- **Bestiario RAW** (FIX-1, `337fa07`): bear_bite a `1d6` (los dados de arma
  solo parsean `NdM` — un `"1d8+3"` literal crasheaba `Combat.parse_dice`;
  el motor ya suma STR +3 → 1d6+3 RAW); wolf bite `2d4` (STR 12 → 2d4+1
  motor vs 2d4+2 RAW, aproximación asumida); ogre CR 3 real (PG 59, garrote
  2d8 → 2d8+4 con STR 19; antes CR 1/PG 28/1d8 sin declarar). Test de
  regresión: atacar con CADA bestia del catálogo de wild shape + araña
  gigante.
- **Gates RAW** (FIX-1, `337fa07`): wild shape CR 1/2 desde L5 (antes L4);
  `start_reckless` exige nivel 2.
- **Hechizos builtin** (FIX-1, `2d60756`): spiritual weapon 1d8 force y
  prayer of healing 2d8 — el SRD trae `dice: null` y el motor trataba nil
  como 0 (ataque sin daño / cura nula). Upcast de prayer (+1d8/nivel) ya
  vivía en D74; ahora con base real.
- **Combate vs caído/incapacitado** (FIX-1, `da4b8ba`, ADR D78): golpes
  melee que aciertan vs `paralyzed`/`unconscious` son críticos automáticos
  (proxy melee: sin posicionamiento); se puede atacar a un caído y el daño
  con restante > 0 sobre un personaje ya a 0 pg registra fallos de
  salvación de muerte (+1/+2 crítico), respetando el orden de capas D67 —
  massive damage sigue fuera.
- **join_game con guarda de estado** (FIX-1, `84f6a9b`): exige
  `status :configuring` (`{:error, :already_started}`); `start_game` zeroa
  `open_slots`; el lobby (`open_games`) lista solo `:configuring`.
- **Gaps de ACs cerrados con tests** (FIX-2, `e8f3ce1`): paginación del
  feed (AC-13.2), dedup de chunks ante reintento (AC-16.1), rutas protegidas
  (AC-1.2), cuenta exacta SRD 319 (AC-4.2), story bible por escenario
  (AC-10.1) y join con slot/participante (AC-12.1) — recitas verificadas en
  `02-requisitos.md`.
- **Orden de providers OpenRouter vía env** (2026-09-16): nueva env
  `OPENROUTER_PROVIDER_ORDER` (CSV de slugs, `models.ex`
  `parse_provider_order/openrouter_provider_extra/request_extra`) fija el
  routing upstream (`provider.order` + `allow_fallbacks: true`, sólo con
  `DRAGONEX_PROVIDER=openrouter`) en DM, PC bots y TurnMaster; vacío/unset =
  routing default. Tests `models_provider_order_test.exs`.

---

## 🟡 Simplificaciones v1 documentadas (deudas técnicas asumidas)

| Ítem | Decisión | Ref |
|---|---|---|
| Dotes | Fuera; ASI = +2 fijo | D13 |
| `spells_known` | `nil` (sin cap estricto por clase) | D14 |
| Features por nivel | Extra Attack D35 + Sneak Attack D41 + Rage D42 (+ usos/Furia implacable D72) + Reckless Attack D44 + Second Wind D45 + Divine Smite D46 + Action Surge D47 + Fighting Style D48 + Lay on Hands D49 + Bardic Inspiration D50 + Arcane Recovery D51 + Divine Sense D52 + Turn Undead D53 + Ki/Flurry of Blows D54 + Hunter's Mark D55 + Font of Magic D56 + Cunning Action Hide D57 + Danger Sense D58 + Evasión D59 + Jack of All Trades D60 + Aura of Protection D61 + Aura of Courage D62 + Wild Shape D63 + Uncanny Dodge D64 + Metamagic D65 + Indomitable D68 + Expertise D73 + spellcasting paladín/ranger L2; el resto 🟡 | D35, D41, D42, D44, D45, D46, D47, D48, D49, D50, D51, D52, D53, D54, D55, D56, D57, D58, D59, D60, D61, D62, D63, D64, D65, D68, D72, D73 |
| Upcasting | Tabla curada RAW 2014 (`Rules.Upcast`, D74): 13 hechizos escalan dados; Bless escala objetivos (D85) y Heal curación plana (D87). Otros multi-objetivo, multi-rayo y no-modelados (mass_cure/sleep) fuera | D74, D85, D87 |
| Rasgos raciales | Lucky D66 + Resistencia implacable D67 + Savage Attacks D69 + Astucia gnoma D71 + Resistencia enana D76 (automáticos, sin tool) + Aliento de dragón D70 (tool racial); Brave, Halfling Nimbleness, Darkvision y demás 🟡 | D66, D67, D69, D70, D71, D76 |
| Empate iniciativa | DEX score desc, luego nombre; sin roll-off extra | D39 |
| Banner level-up in-game | Eliminado (D33); subida desde la ficha | D33 |
| Stub legado en `Tools` | `attack`/`roll`/`spawn_character`/`next_round` mantenidos para tests del framework exAgent | `tools.ex:36-77` |

---

## 🔴 Pendiente / fuera de v1

- **Multi-nodo** (`Horde`) — pausado (D24).

---

## Cómo se mide "hecho"

Una feature entra en ✅ cuando:
1. Tiene tests deterministas (o smoke test si toca LLM).
2. `MIX_ENV=test mix test` está verde.
3. Su decisión de diseño (si la hay) está en `docs/decisions.md`.
4. No deja `TODO`/`FIXME` sin dirección en `lib/`.

No se marca hecha por "el commit existe" sino por "se verifica".

Auditoría de calidad del lote D35–D76 (tests, arquitectura, docs):
[`tecnico/10-auditoria-motor.md`](tecnico/10-auditoria-motor.md) (D77).
