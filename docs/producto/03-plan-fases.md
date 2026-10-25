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

## Iteración vigente — 2026-10-25

Correcciones verificadas: 3152 passed / 3 excluded en local y Hex; auditoría
de ambos locks sin avisos. El resultado vigente de los gates se publica en
[`../progress.md`](../progress.md), sin sustituir las pruebas con humanos.

| Área | Cambio y criterios | Verificación focal |
|---|---|---|
| Dependencias (D246) | exAgent 2.2.2, ReqLLM 1.29.0 y Bandit 1.13.1; AC-37.5 | Compilación, suite y `mix hex.audit` en ambos grafos |
| Combate (D247) | Guiado y furtivo respetan cancelación; críticos y mínimo cero de arma espiritual; AC-22.6/22.7 | `guiding_bolt_test.exs`, `spiritual_weapon_test.exs` |
| Recuperación (D248) | Reacciones conservan su tipo y el corte por tokens no repone retries; AC-30.2e/35.6 | `game_reaction_retry_test.exs`, `game_retry_budget_test.exs` |
| Cuenta y ajustes (D249) | Solo callbacks vigentes guardan claves o cambian modelo; clave cifrada en el callback; AC-1.3/37.4 | `account_live_test.exs`, `game_settings_compatibility_test.exs` |
| Cierre de mesas (D250) | Borrar la mesa propia cierra sus procesos y conserva las demás; AC-33.3 | `game_delete_live_test.exs` |
| Medición (D251) | La última declaración también se recupera; una pausa no cuenta como éxito; AC-NFR-2b | `playtest/playtest_test.exs` |

Después: mantener el orden de [`../progress.md`](../progress.md): evidencia de
partidas humanas, inventario de misión y fiabilidad/latencia del proveedor.
Los tests offline de esta tanda no cierran esas mediciones ni R16.

## Fases entregadas ✅ (resumen; el detalle vive en `../progress-historial.md`)

| Fase | Hito | Entregables clave |
|---|---|---|
| F0 — Spike exAgent | "encaja" (`FINDINGS.md`) | 10 flujos, validación de Session/TurnPolicy/tools |
| F1 — Motor 5e | El motor manda | `Rules`+`Actions`+`World`+`Tools`+`Dice`, WorldDriven |
| F2 — Partida durable | Jugar y sobrevivir | `Game` GenServer (D5), persistencia por beat (D3/D4), Codec (D8) |
| F3 — Robustez | Nunca se rompe | retries+breaker (D17), combate fantasma (D18), history compartido (D19), anti-loops |
| F4 — Héroes | Forjar y crecer | Builder 5 pasos + catálogos SRD ES + custom (D22) + level-up (D10–D13) |
| F5 — TurnMaster | La partida fluye | Orquestador de turnos (D25) con fallback WorldDriven |

Verde de referencia (2026-10-04): **2803 passed / 3 excluded** con paquetes
hermanos; grafo Hex completo **2795 passed / 3 excluded**. Compile de Dragonex
dev/prod sin warnings; dependencias frías conservan avisos de terceros (D203).
D201 entrega AC-14.6/37.2 con dos grafos
aislados, HTTP503 con efecto único, Node/geometría, WebGL real, arranque/reload y
comparación SQL privada. Consulta posterior a continuation4:842→852/14,824s,
World y recursos iguales. La candidata local no es una versión publicada;
MiMo/io.net aún no se admite con stock ReqLLM local. D200 entrega la guía y
observa criterio distinto832→842, con cambio de modelo/adaptador como confusor;
referentes y variedad de voz generales siguen abiertos. D202 entrega AC-14.7:
watchdog10s para revelar el resultado si falta ack, hold2,6s después de revelar;
23 casos en ambos grafos y LiveView/WebGL real verifican lectura sin cierre
prematuro. D203 entrega AC-37.3: parches publicados de web/HTTP, auditoría Hex
sin avisos conocidos y módulos Phoenix/LiveView desde el paquete del servidor.
Chrome1440/721/375 sin JS/overflow;19425/852 íntegra. Beta abierta: continuar
fidelidad/voz/ritmo de PCs y duración de acciones con el proveedor real.
Refinamiento D200 probado852→862/9,177s conserva World y retorno humano;
todavía repite datos e introduce imprecisiones al interpretar «lo vi de lejos».
La entrega de la guía pasa; brevedad y fidelidad semánticas siguen pendientes.
D204 entrega AC-31.2h3: hasta tres interrogantes citados al mismo PNJ y
preámbulo de recuerdo acotado, con habla exacta, magia mixta y restart. D205
entrega AC-35.4: argumentos generados inválidos de ReqLLM usan el reintento
limitado existente y no repiten efectos confirmados. Consulta877→884/9,150s
recupera un rechazo real y conserva World; Chrome1440/375 sin JS/overflow.
D206 entrega AC-25.9: aclaración citada de palabras previas exige registro del
mismo PNJ/turno antes de publicar final o deltas. Duplicado retenido confirma
sin renovar memoria; restart recupera el comprobante.32 focalizados locales,
19 Hex y gates2751/3/2743/3. Mesa884→891/7,665s guarda solo aclaración atribuida,
conserva registros/recursos/reloj/otra mesa/hero y sobrevive restart/reload1440/375.
Prioridad beta: extender evidencia de memoria relevante a otras preguntas y
seguir verificando voz/fidelidad/ritmo con proveedor real. El comprobante no
certifica verdad o relevancia semántica; no se extraen facts automáticamente.
D207 entrega AC-14.8: el constructor3D libera recursos propios antes de
fallback2D, también intenta los restantes cuando falla una limpieza. Cinco
nuevos casos,14 Node/14 host locales/14 Hex y Chrome real rojo→verde; conserva
cara18 y un asentado. Ruta normal3D/móvil/RAF/cambio de modo comprobados.
Paquete candidato sin publicar; gates completos de referencia D206. Consulta
891→901/7,127s recupera el referente en Lyra/Vex con World íntegro, aún repite
datos y endurece una expresión. Continuar voz/fidelidad y otras preguntas.
D208 entrega AC-14.9: el modo seleccionable y mostrado refleja capacidad
instalada, con2D seguro en Hex y3D disponible en el candidato local. Hook y
evento comparten ID; preferencia anterior/per-vista se adapta sin DB/World.
Tres regresiones, gates2754/3/2746/3 y Chrome local/Hex1440/375 con teclado/
resultado19/DC15 verdes, sin agentes o escrituras a la partida901. No garantiza
WebGL en todo navegador; fallback2D posterior conserva la tirada. No publicar
el candidato ni declarar beta cerrada: voz/fidelidad y memoria de otras
preguntas mantienen prioridad.
D209 entrega AC-32.4c: intervenciones públicas completas tras la pregunta
vigente con ancla de acción exacta, sin convertirlas en hechos ni inventar
respuestas ausentes. Contexto final sobrevive restart del segundo compañero/
compacción; diálogo directo y propuestas condicionales sustituyen el formato
de novela solo al responder. Seis nuevos,27 focalizados en cada grafo y gates
2760/3/2752/3 en secuencia. Dos consultas901→911→921 conservan World/recursos/
15 facts; última sin gestos narrados, aún76/61 palabras y matices de fuente.
Continuar aclaraciones posteriores frente a versiones anteriores, brevedad y
memoria de otras preguntas. No certificar semántica/SLA/beta por esta entrega.
D210 entrega AC-25.10: última entrada retenida por nombre completo de fuente,
manteniendo cada versión y reloj literal. NFC/espacios/case no unen roles,
apodos o acentos distintos; duplicado retenido no se promueve. Guía conserva
aclaración de fuente/límite, sin decidir verdad/contradicciones. Cinco nuevos,
46 focalizados por grafo y gates2765/3/2757/3 secuenciales limpios;
archivo/compacción adversa/restart sobre Vex verdes.
Consulta921→934/15,905s mantiene World/15 facts/recursos/reloj/otra mesa/hero,
aún86/66 palabras. Pregunta doble sale de ruta literal PC de una pregunta y
añade reformulación humana/cierre DM. QA1440/375/SQL/PNG sin JS/overflow;
beta activa. Prioridad: cubrir esa forma de conversación, voz/brevedad y
otras memorias, sin extraer verdad de la prosa automáticamente.
D211 entrega AC-32.1c: hasta tres preguntas informativas consecutivas a los
mismos PCs conservan habla literal y cierre acreditado. Cada interrogativa/
espera debe calificar; no trunca cuarta pregunta, cambio de voz o acciones.
Dados, nueva pregunta PNJ, hechizos/intenciones/World distinto conservan DM.
Seis nuevos, rojo20/26,64 focalizados por grafo y gates2771/3/2763/3
secuenciales limpios; restart y magia mixta verdes.
Consulta idéntica934→944/4,061s conserva World/15 facts/reloj/recursos/otra
mesa/hero, palabras exactas de Mara y dos respuestas PC sin turno/narración DM.
QA readonly1440/375/SQL/PNG sin JS/overflow. Seguir fuentes/brevedad y campaña;
no certifica gramática universal/semántica/SLA o beta lista.
D147 cierra ejecuciones al detener/reiniciar Game, incluidos autoplay
posteriores, PC/TM/registro. Mesa19427 offline conserva World/historial al
reiniciar con modelo esperando. D148 ordena el cierre de fixtures y Sandbox;
el gate final no registra errores. Ventanas anteriores a la confirmación de
la tool siguen abiertas; D150 amplía el guardado descrito abajo.
D149 ordena la parada del callback del Game y mantiene recuperación de
auxiliares; se adopta en19425/19426 pausadas con World/historial íntegros.
D150 guarda cambios de tools antes de confirmarlos y conserva descanso/magia
al interrumpir la narración; mesa19428 offline continúa sin repetir el descanso.
Quedan ventanas anteriores a la confirmación y atomicidad de dados/eventos.
D151 aísla ese límite por partida: cuatro caídas en19429 conservan los mismos
procesos/World/historial de19428. Adopción19425–19428 propias conserva estado;
gate2376/3 sin errores ni warnings. D152 evita repetir tools exitosas dentro
  de reintentos con Game vivo; mesa19430 offline mantiene una casilla y un
  grupo de dados tras503 simulado, gate2385/3 limpio. D153 recupera el actor IA
  con resultados durables confirmados y turn_id original: VM19431 mantiene
  casilla/daño6/un grupo tras restart, gate2393/3 limpio.
  D154 cierra la ventana efecto→resultado con comprobante en el mismo World:
  VM19432 corta antes del feedback y conserva costes/turno, gate2398/3 limpio.
  Siguiente revisión: dados/eventos anteriores al guardado del efecto y
  continuación de playtest narrativo con proveedor real. D157 cierra la
  preparación de dados de tools: World/comprobante/eventos juntos, sin grupos
  tras rechazo/corte/rollback; VM19435 mantiene un grupo/casilla1/Goblin14 al
  recuperar, gate2422/3 limpio. Narraciones y grupos automáticos fuera de las
  tools conservan revisión propia. D155 protege consenso
  pasivo/gesto plural del granero; nueva conversación real12,137 s conserva
  World/biblioteca y decisión abierta. Gate2407/3 sin errores/warnings.
  D158 reserva respuesta PNJ literal y retorno humano; VM19425 real8,143 s,
  coordinador sin peticiones, World/biblioteca iguales, gate2432/3 limpio.
  D159 confirma iniciativa/World/dados/nota antes de publicar; D160 aplica
  mínimo cero después de bonos y separa Smite. Gate2444/3 limpio, VM19436/19437
  recuperan efectos sin repetir dados; nueva VM conserva once mesas propias.
  Reload375/1440 px/teclado verificados. D161 conserva el subtotal negativo
  para mostrar la penalización real y explicar el mínimo en crónica/modal/
  History; VM19438 y navegador verificados, gate2449/3 limpio. D162 reserva
  el slot/tipo de inicio de turno y confirma efectos/dados juntos, con resume/
  restart, nombres DM/reacciones y VM19439 interrumpida verificados. Adopción
  de14 mesas propias y navegador acreditados, gate2455/3 limpio. D163 confirma
  cierre/intenciones/notas juntos y recupera victoria/actor antes de actuar;
  VM19440/19441 y navegador acreditados, gate2462/3 trazado limpio. El gate
  anterior tuvo desconexiones de limpieza intermitentes aún sin causa probada.
  D164 recupera respuestas finales completas del actor pendiente sin nueva
  petición/publicación; siete casos/49 focalizados, VM19442 y navegador
  acreditados, gate2469/3 limpio. Continuar con intentos incompletos/actores sin
  comprobante/relevo posterior y viaje elegido por jugadores. D165 entrega
  obligación de reloj al DM de exploración; tres casos/35 focalizados y
  gate2472/3 limpio.19425 llega a la taberna tras decisión propia y dos tramos
  de900 s (el primero reconciliado mediante confirmación explícita), con
  reinicio/navegador acreditados. Llegada47,54 s y Vex/DM adicional: siguiente
  revisión de ritmo y continuidad con la dueña. D166 registra movimiento
  local omitido: once casos/68 focalizados, gate2483/3 trazado limpio y mesa
  real plaza→interior sin cambiar recursos/reloj. Maribel responde antes y
  después en8,657/5,026 s; movimiento22,895 s incluye recorder9,579 s y
  TM6,274 s. Restart/navegador acreditados. La primera suite vuelve a observar
  desconexiones de limpieza; investigar su causa. Siguiente: reducir esperas
  manteniendo voz IA, revisar invitación gratuita/precio y otros movimientos.
  D167 publica preguntas informativas PNJ literales sin la petición humana
  de reformulación: siete casos/69 focalizados, gate2490/3 ordinario limpio.
  19425 confirma invitación gratis en4,536 s con una petición DM y World igual;
  restart/navegador/teclado acreditados. Acciones/persuasión siguen ruta normal.
  Continuar elección/servicio de comida con voces IA, hechos durables y esperas
  restantes. La limpieza intermitente no reaparece, pero sigue abierta.
  D168 recuerda voz/acuerdo en el turno PC de respuesta: tres casos/39 focalizados,
  gate2493/3 sin errores/desconexiones,19425 formula ideas propias10,198 s sin gastar.
  D169 corrige compresión por bytes que rompía una pregunta antigua antes del
  proveedor: tres casos/18 focalizados, gate2496/3 sin errores/desconexiones,
  respuesta real6,6 s. Avisos de ejecución atribuidos en el protocolo de pruebas.
  La espera aún omite advance_time; reconciliación explícita1200 s deja35400
  con recursos intactos, restart/JSON/navegador acreditados. Siguiente: registro
  fiable de duración declarada y hechos/relato durables, además de esperas.
  Verificación2026-10-03 refuerza nueve fixtures anteriores: escena realmente
  cambiada, beat completo, reacción con casilla/CA efectiva y tres voces PC
  distintas y narración DM.38 focalizados sin errores/avisos; no modifica reglas
  de producto. Gate final2496/3 en48,0 s/seed30343, sin errores/desconexiones/
  avisos inesperados; cinco avisos deliberados del breaker simulado.
  D170 exige resolución antes de la final DM para esperas literales nuevas;
  comprobante durable admite interrupción parcial/0 s y no duplica intervalos.
  Dieciséis casos/27 focalizados, gate2512/3; reaparece limpieza intermitente,
  se conserva traza sin atribuir causa resuelta.19425 registra300 s naturalmente,
  conserva recursos/restart/reload, pero tarda32,603 s y repite el rumor.
  Siguiente: otras duraciones, menos peticiones/recorder y fidelidad narrativa.
  D171 publica esperas pasivas literales sin petición humana; siete casos/29
  focalizados y gate2519/3 sin errores/desconexiones.19425 registra180 s una
  vez,17,884 s, recursos/restart/reload intactos. TM agota tokens con fallback
  y recorder idéntico deja revisión pendiente; investigar esas dos demoras y
  datos nuevos del rumor que solo quedaron en historial. No es un benchmark.
  D172 confirma una escena idéntica únicamente con intervalo/estado anterior
  verificables y revalidación Game, también al recuperar la final DM completa.
  Diez casos/53 focalizados y gate2529/3; limpieza SQL/fixture sigue abierta.
 19425 registra120/60 s una vez,13,246/18,890 s, con recursos/modelos/restart/
  reload intactos. Ambas muestras del proveedor reescriben la escena: la rama
  idéntica está probada offline. Próximo: separar entorno durable de pregunta/
  pose PNJ, revisar continuidad de objetos/hechos y peticiones TM; conservar
  rechazo de snapshots obsoletos, descansos y hechos todavía sin revisar.
  La verificación adicional de cola multi-human/limbo completa sus fixtures:
  ocho focalizados y2529/3 en48,1 s sin avisos inesperados; una desconexión
  SQL persiste. No se considera corregida por modificar el producto.
  D173 entrega guía explícita de entorno físico, conservando la conversación;
  un smoke/27 focalizados y2530/3.19425 registra30 s una vez y omite pregunta/
  oferta en la escena915→662 caracteres; manos/consumo y nuevas afirmaciones
  del forastero siguen bajo revisión. Próximo: durabilidad y continuidad de
  información PNJ, avance de trama durante esperas y coordinador/latencia.
  D174 atribuye el fallo SQL a una LiveView de ficha/recarga terminada durante
  su consulta, con owner aún vivo. ConnCase espera el callback antes de cerrar;
  dos pruebas/34 focalizados y45 con TMSpy supervisado hasta terminar Game.
  Gates2532/3 en48,0/48,2 s, seeds944912/30343/max_cases48, sin desconexiones
  ni errores inesperados. Seguir los casos históricos de owner sin atribución
  si reaparecen; siguiente prioridad de producto: continuidad PNJ y latencia.
  D175 selecciona guía específica para la espera reconocida, manteniendo
  interrupciones y órdenes de avance fuera de ella. Cuatro casos/46
  focalizados;2536/3 en48,8 s/seed944912/max_cases48 sin errores inesperados.
 19425 registra15/15 s con escena/hechos/recursos iguales y confirma por
  primera vez entorno idéntico con proveedor.17,877/14,256 s no son benchmark;
  TM falla por tokens en el primero y completa el segundo. Próximo: atribuir
  y conservar afirmaciones PNJ, evitar repetición sensorial y mejorar latencia.
  D176 registra testimonios con fuente/dudas, sin confirmar contenido ni
  invalidar entorno; diez casos/67 focalizados y2546/3 en49,3 s limpio.
 19425 conserva versión de Maribel tras restart/reload y vuelve en7,605 s,
  humano1/DM2/cero TM/recorder, recursos/reloj/escena iguales. Próximo:
  contrastar fuente nueva del zagal con biblia/historial, cambios físicos
  narrados como el relleno de jarra y ruta de preguntas «¿Viste…?» que aún
  solicita reformulación humana. No declarar registro universal ni veracidad.
  D177 elimina esa reformulación para viste/oíste/escuchaste, con guardas
  manuales/cola/prefijo/espera D167 intactas. Tres casos/32 focalizados,
 2549/3 en49,6 s limpio;19425 vuelve en4,538 s, una ejecución DM/dos pasos,
  cero humano/TM/recorder, solo memoria cambia. Restart/modelos/375/1440 px/
  teclado acreditados. Biblia de19425 vacía: fuente nueva no equivale por
  sí sola a contradicción. Continuar versiones del forastero/cambios físicos
  y ficha propia situada después de compañeros en el cajón móvil.
  D178 pone ficha propia primero y reinicia scroll solo al abrir; patches
  conservan lectura/compañeros.375/720 px/teclado, DM375 y escritorio721/
 1024/1440 verificados con partida intacta.41 focalizados/2549/3 en49,3 s,
  limpio tras acotar fixture anti-repeat agotado. D179 adapta721–1023 px y
  paisaje: crónica72ch, ficha lateral con altura de lectura conservada,
  controles completos al enfocar y objetivos táctiles44 px. Corrige ficha
  propia oculta en combate y prioriza PG/CA. Ocho tamaños y cuatro casos
  táctiles emulados, dos mesas intactas por SQL, siete capturas revisadas;
 39 focalizados/2549/3 en48,2 s limpios. D180 verifica la aclaración literal
  de Maribel sin cambiar World y reproduce el corte256 del coordinador.
  Presupuesto1024 configurable llega al request real; control negativo1/4,
 77 focalizados y2553/3 en50,2 s limpios. Espera real15 s vuelve en9,667 s
  con decisión TM válida, reloj cobrado una vez y recursos/escena intactos.
  Dos reinicios conservan mesa/modelos,375/1440 px y seis capturas revisadas.
  Próximo: variantes con varios PCs, cambios físicos narrados y latencia;
  no declarar beta, SLA ni hardware probado.
  D181 conserva críticos y uno/dos fallos de muerte en el contexto compartido,
  con resultado tomado del motor. Cuatro casos/control negativo1/4;78
  focalizados y2557/3 en49,2 s limpios. Dos conversaciones19425 dan una voz
  por PC en orden literal y vuelven al humano11,791/9,664 s sin modificar
  World/reloj/recursos. Reinicio preserva modelos/ajustes y cierra cinco
  auxiliares; seis capturas375/1440 revisadas, hooks retirados. Próximo:
  preguntas informativas a PCs sin gestos añadidos, cierre DM menos repetido
  y continuidad más allá de400 eventos; no certificar semántica general.

  D182 conserva preguntas de recuerdo/observación a PCs sin narrador humano,
  con cola completa/guardas manuales y ruta mixta intactas. Seis casos/control
  negativo4/6,62 focalizados y2563/3 en50,0 s limpios.19425 publica las palabras
  literales, recibe Lyra/Vex/cierre DM y vuelve en7,647 s: tres runs, cero
  humano/TM/recorder/tools/dados, World igual. Reinicio/modelos/ajustes y cuatro
  capturas375/1440 px revisados. Próximo: cierre DM menos repetido y memoria
  cuando hechos del combate abandonen la ventana400;408 eventos aún conservan
  esos dados. Una muestra no certifica SLA ni semántica general.

  D183 elimina instrucciones contradictorias de cierre/anti-repeat mediante
  contexto de conversación seleccionado desde World. Tres Game/control
  negativo1/3,42 focalizados3,3 s y2566/3 en49,6 s limpios.19425 conserva World
  y vuelve7,618/7,605 s, tres runs por intercambio; dos reinicios/modelos/ajustes
  y ocho capturas375/1440 revisados. La muestra con solo prompt sigue cuenco/
  postigos; tras contexto correcto aún queda tarde tibia. Entrega del nudge
  activado probada offline, sin certificar repetición resuelta. Próximo: cierre
  discreto con guardas del motor, respuesta PNJ/efectos intactos y memoria
  cuando la evidencia sale de400 eventos; beta continúa abierta.

  D184 cierra localmente una consulta informativa/opinión PC acreditada por
  World intacto y transcript completo: retorno sin beat DM, manteniendo
  peticiones PNJ, dados/fallos/preguntas nuevas y cambios de mundo.14 casos,
  control sin transcript11/14,69 focalizados3,7 s y2580/3 en50,9 s limpios.
 19425 vuelve5,574 s con dos runs PC, history DM sin cambios y World igual;
  primera7,642 s tiene observador caducado, sin afirmar runs.434→444→454.
  Reinicio/modelos/ajustes, SQL y cuatro capturas375/1440 revisados; hook
  retirado. Próximo: hechos antiguos fuera de400 y efectos físicos PNJ;
  no certificar semántica general, SLA o beta por este cierre acotado.

  D185 corrige visible_to ignorado en el historial enviado a agentes: público
  por defecto/PC/humano/recorder; DM conserva sus notas por participante,
  sin borrar DB ni cambiar World. Siete casos/rojo0/7, controles filtro0/7/
  DM omitido5/7,67 focalizados4,7 s y2587/3 en50,5 s limpios. Reinicio durante
  Lyra acreditado offline; reload/SQL19425 conservan454 eventos, dos capturas
  revisadas sin hooks/proveedor nuevo. Próximo: recuperar evidencia del motor
  fuera de400 respetando esos permisos, y continuar PNJs/efectos físicos.
  La clasificación de secretos en facts/story_bible queda fuera del alcance.

  D186 recupera hasta32 dice anteriores al contexto400, con audiencia antes
  del límite/índice parcial, como evidencia histórica en el prompt actual
  que Summary no resume. Diez casos, controles8/10/9/10,77 focalizados5,2 s
  y2597/3 en50,1 s limpios.19425 conserva World y vuelve6,615/5,057 s con
  dos runs PC; ambos prompts tienen los datos originales24–25 y la última
  pregunta obtiene20 natural/25 vs15/daño18 de ambas voces.454→464→474, dos
  reinicios/modelos/ajustes y ocho capturas375/1440 revisados; hooks retirados.
  Migración9 dev/test, SQL solo lectura del estado final. Próximo: recuerdos
  más allá de32 tiradas/escenas/testimonios, prosa PC que copia gesto de jarra
  y consecuencias físicas PNJ. No certificar memoria ilimitada, SLA o beta.

D187: respuesta PC suficiente sin gestos/propuestas obligatorias;
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

D188: información/opinión PC simple conserva las palabras del jugador,
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

D189: preguntas al zagal/oficios y complemento corto conservan habla exacta;
  nombres PC del World protegen registro y extracción literal. Seis nuevos,
  magia mixta/restart/testimonio/colisión comprobados; controles9/14/13/14,
 43 focalizados2,5 s y2613/3 en52,6 s limpios, cinco breaker. Viaje real al
  molino registra900 s/escena,531→538; consultas538→545→552 solo añaden versiones
  atribuidas. Última7,109 s con un DM/dos pasos y cero humano/PC/TM/recorder/dados.
  Reinicio preserva estado/ajustes y cierra cinco auxiliares; SQL/reload375/1440/
  teclado/ocho capturas, hook retirado. Seguir pistas y efectos físicos/nueva
  aventura, semántica y memoria fuera de ventana; beta sigue activa.

D190 entrega R38 acotado: cantidades/stock deterministas en Rules/World y dos
  tools DM, brief/ficha propia y replay tras reinicio. Cambios solicitan revisión
  durable; confirmación idéntica requiere prueba de inventario/resto del World,
  commit exacto y sin pendiente anterior.22 nuevos/110 focalizados2,8 s y2635/3
  en52,6 s limpios, cinco breaker; formato/compile/diff correctos.19425 verifica
  entregas/dejar/recoger y stock0/1. Ensayos intermedios descubren omisiones:
  contrato por turno/contexto reciente tras el archivo de dados. Formulación
  original623→630 retira1, con recorder timeout20 s;630→637 recoge1 y confirma
  escena. Reinicio/SQL/375/1440/reload/teclado/22 capturas, recursos/hero/modelos
  conservados, hook retirado. Seguir latencia, variantes de transferencia,
  testimonios solo en history y pistas al norte; beta continúa activa.

D191 entrega AC-16.3/19.3: etapas efímeras validadas por Game distinguen acción,
  revisión, relevo y backoff sin cursor falso. Avisos al entrar en etapas y
  pausa conservada ante fallo transitorio posterior. Ocho nuevos/71 focalizados
  7,8 s y2643/3 en53,3 s limpios; seis avisos deliberados, compile/formato/diff.
 19425 reinicia sin alterar estado/modelos/ajustes; dejar y recoger637→644→651
  tarda22,159/27,396 s. Dos vistas375/1440, reload/borrador/teclado, cuatro PNG
  revisados y SQL: cero dados, recursos/inventario final/facts/clock37035/hero
  conservados. Hook retirado, Show exacto. Latencia y beta siguen abiertas.

D192 entrega AC-31.2h2/32.1b: una preposición + interrogativo conserva voz
  literal a PNJ/PC con guardas intactas. Seis nuevos/86 focalizados y2649/3
  en55,3 s limpios, seis avisos deliberados.19425 corrige pregunta al zagal
  sin narrador humano; un reintento impide comparación causal de latencia.
  Viaje900 s al norte y consulta Lyra/Vex guardan escena/reloj37935/pista;
  pregunta PC solo dos runs y World igual. Restart/SQL/375/1440/teclado/dos
  PNG, recursos/hero/modelos conservados, hook retirado/Show exacto. Continuar
  consecuencias físicas/voces/memoria y latencia; beta sigue en preparación.

D193 entrega AC-25.5b: testimonios nuevos conservan su reloj de registro fuera
  de la cita. Duplicado aún retenido conserva primera marca, legado sin backfill,
  cap30 y atribución vigentes; no interpreta fechas o verdad del relato.
  Cinco nuevos/94 focalizados2,5 s y2654/3 en54,8 s limpios; seis avisos deliberados.
  Game/restart/checkpoint/compacción tras86400 s conservan referencia.19425
  guarda versión nueva en38835, viaja900 s y ambos PCs reciben marca original,
  diferenciando testimonio/prueba. Restart713/SQL/375/1440/teclado/dos PNG,
  modelos/recursos/hero/once facts previos íntegros, hook retirado/Show exacto.
  Continuar huellas, consecuencias físicas y latencia; beta sigue activa.

D194 entrega AC-14.4: DC/CA factual, diálogo/cierre/foco y timer por generación
  local. Nueve nuevos/59 focalizados4,9 s; gate limpio2663/3 en54,6 s, seis avisos
  deliberados. Investigación713→721 da19vs15 sin World nuevo; replay solo UI en
 1440/375 acredita teclado/lienzo/44 px. Seguimiento721→729 da7vs15, pierde rastro,
  avanza900 s y vuelve en17,729 s. Restart/SQL conserva recursos/inventario/facts/
  hero/modelos/prefijo721 y cierra cinco auxiliares; hook retirado, tres PNG y
  navegación normal. Probe inicial expirado no provoca repetición. Seguir
  consecuencias del fallo, memoria de pistas solo en narración y latencia;
  beta activa, sin certificación universal 3D/hardware/accesibilidad.

D195 entrega AC-25.6: establish_fact/set_scene solo DM, incluso cuando el
  humano usa DMServer para Rules. Rechazo temprano/guía al final del prompt;
  facts legacy intactos, sin extraer prosa. Siete nuevos/54 focalizados3,0 s,
  2670/3 limpio54,6 s, seis avisos deliberados. Game/restart/compacción verdes.
  19425 inspecciona20vs15 sin confirmar facts propios, recoge hilo×1 por DM,
  recuerda dueño incierto en5,593 s sin World nuevo y reinicia772. SQL conserva
  eventos/prefijos/modelos/ajustes/hero/recursos; otra mesa aislada. Hook retirado,
  Show exacto, reload1440/375/teclado/dos PNG sin JS/overflow. Auditar otros
  mutadores que recibe humano; voz/certidumbre/memoria y beta siguen activas.

D196 entrega AC-22.3: tres tools de criaturas/fases exigen DM antes de
  World/RNG/propuesta. Once nuevos/99 focalizados2,8 s y2681/3 en55,8 s limpios;
  seis avisos deliberados. Game normal/restart rechaza llamadas humanas,
  conserva recursos/SQL y permite spawn DM con iniciativa automática nativa.
  Refuerzo no repite dados.19425/seq772 intacta vía SQL readonly; navegador
  normal1440/375 conectado/sin JS/overflow, sin hooks/PNG/acción LLM nuevos.
  Continuar los restantes mutadores y coherencia/memoria/voz/latencia/beta.

D197 entrega AC-21.4: cinco tools directas de efectos/nivel requieren DM antes
  de World/target/RNG. Once nuevos/103 focalizados3,2 s y2692/3 en56,2 s limpios;
  seis avisos deliberados. Game normal/restart conserva False Life pagado antes
  de curación DM: slot/dado/plazo únicos, veneno/compañera/nivel intactos.
  Segundo aliento conserva coste/uso único. Se restringe permiso PC D36,
  Rules/World/Codec iguales.19425/772 intacta vía SQL y navegador1440/375 sin
  JS/overflow, sin hooks/PNG/beat LLM nuevos. Seguir fuente de adjudicaciones
  DM, agencia, recorrido del hilo tras fallo, memoria/voz/dudas/latencia y beta.

D198 entrega AC-25.7: Brief separa hechos/testimonios por formato existente,
verbatim y sin mutar World; guía final conserva fuente frente a prosa/resumen
anterior. Ocho nuevos/46 focalizados y2700/3 limpio. Regreso772→779/900 s,
consulta al zagal779→786 solo añade testimonio; recuerdo786→796 mezcla fuente.
Misma pregunta tras cambio796→806/6,616 s solo PCs, comparación atribuida al
zagal, cero tools/dados/World nuevo. SQL/restart/roles/recursos/hero/facts previos
intactos, UI1440/375/teclado/dos PNG revisados sin JS/overflow. No garantiza
semántica libre ni memoria durable de detalles solo narrados; voces parecidas
y deduplicación de comillas externas quedan para próxima iteración.

D199 entrega AC-25.8: misma afirmación con envolturas completas no ambiguas
conserva el fact original/marca/posición; nuevo registro sin envoltura externa
redundante, citas internas/parciales/apóstrofos y límites intactos. Nueve nuevos,
red final1/9/hash exacto D198, verde9/9;43 focalizados1,6 s y2709/3 limpio.
Game normal/restart/replay comprueba DM y no duplica; fixtures corregidas sin
cambiar flujo del producto. Sin beat LLM/hook nuevo: SQL/UI mantiene19425/806/
14facts/World/recursos/hero y otra mesa íntegros. Memoria textual acotada,
sin equivalencia semántica ni recuperar datos expulsados; voces siguen abiertas.

## Cola actual tras D81–D83

F6 está cerrado. Daño/concentración unificados, presupuestos por turno,
descansos finitos y reloj persistido están implementados (D81–D83).
Consolidación 2026-09-26: dos regresiones de recursos de concentración y
`game_engine_journey_test.exs` (builder → combate → Postgres/Game → descansos
→ nuevos arranques). Ver alcance y evidencia en `../progress-historial.md`.

Orden de continuación:

**Prioridad tras D217/D218/D219:**19443/107 se conserva como reproducción
de regreso/entrega no declarados. Mesa nueva19444 con rechazos de envelope,
hostil narrado sin ficha y después error de control que pedía actuar como dm.
Feedback temporal y mensaje correcto entregados;44→67 ya registra skeleton
y cuatro iniciativas. Combate67→88 recorre monstruo/ronda y deja Thane4PG;
recogida88→95 guarda farol×1, regreso95→102 suma300 s y entrega102→109
retira una unidad/guarda cierre. Reinicio de agentes UI/reload conserva109.
El contexto vigente después de tools ya se entrega por D220 (cinco nuevos,
17 focales por grafo), sin eliminar prosa anterior. La aclaración nueva109→116
guarda fuente/dudas PNJ y conserva encargo/recursos; restart UI/reload íntegros.
La consulta inicial a Ada sigue fallida.19445/53 reproduce adornos de voz
humana y conserva un encargo cerrado con stock/recursos exactos. D221 publica
la acción original en el resolutor manual, conservando tools/retry/restart;
15 nuevos/93 focales por grafo. Nueva19446/42 acredita tres voces exactas y
campanilla×1 entra/sale sin gasto/curación; Vex derrota al único bandido. Pero
la intro DM publica razonamiento como prosa, añade gestos del humano y la
entrega narra cierre sin fact duradero. D222 verifica una frontera de narración
estructurada con 15 casos y otro del transporte ReqLLM stock: solo publica
output aislado/validado y requisitos
resueltos, conserva voz humana y partes nativas. La conexión DM/PCAgent/Beats
ya está escrita por defecto, con narrate, corrección/pausa acotadas y
narración/comprobante atómicos antes de Session/PubSub.19 casos nuevos y
271 focales locales/269 Hex prueban costes/RNG únicos, espera, backoff,
rechazo SQL, pausa manual respetada, transporte stock con memoria/output y
restart antes del acuse/settlement.109 archivos anteriores ya están migrados;
otros9 casos por grafo cubren espera con magia/PNJ/observaciones/iniciativa SQL.
Otros30 cubren voz/ritmo, memoria de tiradas y agencia/actualización de escena.
Más tandas local/Hex:25/23 PNJ/escena/retry stock,55/55 efectos/persistencia/
ciclo de vida,68/68 mesa web/reacciones/progresión,13/13 hechos/antibucle,
17/17 iniciativa/relevo,21/21 TurnMaster y3/3 lobby/ficha móvil.
TurnMaster exige respuesta DM
posterior al humano y retorno real, sin aceptar solo una nota inicial.
La migración conserva sus oráculos, sin bypass de TestModel ni grafo
alternativo. Gates completos local2858/3 yHex2849/3 en105,3/63,8 s,
secuenciales, sin warnings/errores/desconexiones; compiles test140/prod Hex133
forzados limpios. Verificar R16 y nueva partida live con los proveedores
estrictos; no reutilizar 19446 para borrar el defecto. Nueva19447/52 con el
contrato activo registra enemigo/iniciativa y acredita golpe humano/daño4,
magic missile14/casilla y recogida×1, sin reasoning visible en la muestra.
Entrega falla con error6300/4096; campanilla sigue en Thane, sin cierre ni
checkpoint. Restart/reload íntegros, prosa DM intermedia/final repetida.
D223 corrige offline la pérdida de causa por duplicar una respuesta parcial
en el error del paquete v2:102/58 focales del framework y23 de Dragonex;
gates posteriores completos2859/3 local y2849/3 Hex, limpios y secuenciales.
D224 verifica protocolos dinámicos en dev/test y conserva consolidación/Hex
en prod; gates de esa entrega2860/3 local y2850/3 Hex limpios y secuenciales.
La causa original de19447 no está conservada; proteger52 y probar otra mesa
tras activar la corrección. Revisar también fallback de actor sin resolución
y repetición de prosa, sin borrar eventos anteriores.
19448/48 tras activar el paquete sí retira campanilla×1 y registra cierre,
sin retry; entrega11,541s, reload/SQL intactos. No reproduce retención. Tiene
ataque del bandido antes de iniciativa y otro en combate; D225 añade admisión
antes de RNG, con dos regresiones/72 focales locales y gates actuales
2862/3 local/2852/3 Hex limpios y secuenciales. La VM nueva19449/38 con D225
activado registra cuatro iniciativas antes de atacar, orden correcto y ningún
ataque enemigo extra. Recogida×1, entrega×1/cierre único sin retry;
reload1440/375 conserva SQL/recursos/fuente. No hay evidencia pública de que
se ejercitara el rechazo; no dar esa rama por probada live. Conservar19449:
repite una cita PC y guarda testimonio PNJ indirecto.
Prosa Vex«13 más5» duplica sneak ya
incluido en total13, yDM22/23 son idénticos. Conservar también esta mesa;
revisar claridad del resultado de daño y duplicación sin borrar eventos.
D226 aclara total/componentes incluidos por golpe; smite adicional e
inspiración en ataque.8 nuevos/214 focales y gates2871/3 local/2861/3 Hex
limpios y secuenciales en DB propia,641 fuentes estables/referencias exactas.
Es prueba offline del feedback, no fidelidad semántica ni beta cerrada.
VM nueva19450/46 con D226 registra iniciativa/orden correctos, Vex10 incluido
sneak5 yThane7, recogida×1/retirada×1/cierre único.20,899/64,293/18,115/
24,238/16,615s sin retries/fallos; reload1440/375 conserva SQL/recursos/fuente.
Vex no cita números: no prueba corrección aritmética del modelo. El recibo
registra fuentes concurrentes D227; no cualifica todo ese delta por este
playtest. Conservar también19450. Siguiente: fallback sin resolución,
declaración inicial que sólo abre combate, latencia y memoria canónica;
testimonios indirectos/fact histórico con ubicación antigua siguen abiertos.
D227 pliega en Chat/History copias exactas, contenidas o casi idénticas de
voz dentro de un turno y la doble voz humana, sin tocar eventos; refuerza el
cierre para que no repita `narrate`. Paráfrasis visibles: medir en partida
nueva antes de considerar un juicio semántico.
D228 cierra offline «fallback sin resolución»: el turno fallido pausa con nota
y checkpoint, y reanudar lo completa sin repetir efectos; un segundo fallo lo
omite sin prosa inventada. D229 evita DM→DM por cursor de WorldDriven en
exploración. Falta ensayo live con fallo real del proveedor.
19451 (libro del molino) ejercita D228 live dos veces y motiva D230–D232:
aposición de fuentes, combate solo con hostiles/objetivos sin ficha e
intención humana sin reglas. Siguiente: mesa nueva para revalidar D232 y el
cierre de encargo tras entrega; conservar 19451 como reproducción.
Después seguir registro canónico de consecuencias, junto a argumentos/routing y
latencia (tres retries en ataque inicial). No corregir esto con reescritura
de eventos previos ni inferir cierre canónico desde la frase del PNJ.
No inferir obediencia universal ni cerrar beta por ese ensayo; eventos previos
fallidos se conservan. Mesas/héroe protegidos y sin publicar/desplegar.

**Reproducción anterior a D217:** recuperación68→69 y combate69→85 acreditados; Thane
falla y Lyra obtiene crítico, esqueleto0, cierre automático y recursos intactos.
Recogida85→107 adelanta viaje/entrega sin declaración durante seis beats DM.
No contar el encargo como correcto; conservar107 pausada y revisar self-handoff
pass_to_dm/give_turn_to(dm) tras respuesta ordinaria, con persona disponible.
Después repetir aventura nueva por UI, incluida iniciativa fresca y recogida,
regreso/entrega separados. Mara944, 19439/9 y héroe5164 protegidos.

**Reproducción anterior a D216:** 19443/68 pausada en combate; esqueleto 4/13 PG
tras ataque Vex de 9, pero falta en el orden de tres PCs. Reproducción pura
confirma callback de iniciativa obsoleto; D215 rechaza futuros commits cuando
varía roster/DEX, sin reescribir el estado guardado. Recuperar por el motor y
reprobar el lote spawn/iniciativa antes de seguir pelea/farol/regreso. Conservar
Mara 944, mesa 19439/9 y héroe 5164. La apertura tuvo handoff_failed y dos
retries inválidos recuperados; revisar estas variantes y fidelidad/brevedad.
Guía D214 entregada tras prosa intermedia; no oculta eventos ni prueba obediencia.

**Continuación tras D213:** 19443/28 responde Ada con voz humana exacta y
testimonio atribuido, sin retries inválidos; reloj/recursos intactos. Parser
PNJ por nombre con roster y guía backend de envelope exAgent acreditados.
No certifica toda semántica/latencia. Seguir decisiones individuales Lyra/Vex,
trayecto de cinco minutos, cobertizo/combate y regreso, conservando fuente/duda.
Mara 944 y 19439/9 pausadas. No repetir consultas a ciegas ni publicar candidato.

D212: el creador conserva instrucciones largas y valida
títulos255 antes de insertar; AC-10.5 y nueva mesa19443/3D acreditados.
Migración test/dev conserva47 estilos; producción pendiente de despliegue.
Primer diálogo a Ada6→13 conserva World, pero no responde el PNJ: nombre
propio fuera del detector y fallback tras tres reintentos inválidos. Revisar
esa ruta antes de viajar al cobertizo; preservar Mara944 y la mesa de combate.

Tras D213, la consulta 21→28 sí responde y registra testimonio; el fallo previo
queda como evidencia. El resto de campaña y semántica sigue abierto.

Diferenciar voz/opinión de Lyra/Vex y conservar
duda/recencia/fuente en más consultas. Verificar decisiones propias y utilidad
al elegir siguiente paso; no basta variar sinónimos de una misma respuesta.
La aclaración D206 está registrada; aún se mezclan matices de la versión
anterior con ella al responder. D210 presenta el orden retenido sin borrar
testimonios ni decidir su verdad mediante regex. La consulta921→934 combina
dos preguntas informativas y expone reformulación humana/cierre DM. D211
cubre hasta tres al mismo destinatario con límites/guardas de acciones y
consecuencias:934→944 conserva habla exacta/World y vuelve directo al humano.
Pasar a nuevos pasos de campaña y preguntas distintas para comprobar memoria
útil, agencia y coste, además de brevedad/fuentes. Otros detalles solo en prosa
siguen sin memoria durable verificada.
Agencia y fuente/coste de adjudicaciones DM continúan en auditoría: D195–D197
cierran permisos concretos, D198 proyección/caso de comparación y D199
envolturas textuales, no toda coherencia. Revisar más campaña/compacción,
fallos recuperables y latencia; no declarar lista beta.

**Trabajo sostenido de calidad (2026-10-01):** petición explícita del usuario
de seguir hasta que resulte agradable jugar. Criterios, evidencia y cola en
[`07-calidad-jugable.md`](07-calidad-jugable.md). D101–D199 entregados:
identidad/historial/controles, sanitización de un caso real, cierre por aura,
TurnMaster vigente, borrador recuperable, fallo de actor liquidado, argumentos
opcionales de magia, ficha factual, recuperación por slots, mesa compartida y
relevo principal impuesto sin consulta redundante. La primera batalla está cerrada y el héroe
propio guardado/recuperado y usado en mesa. Dos cuentas compartieron/resolvieron
una mesa y una nueva arena dio relevos de 8,46/13,01 s. Presencia/reentrada y
dados automáticos tras éxito/fallo están comprobados. Continúan variantes de reanudación,
latencia con más PCs, progresión y grupo completo/ajustes en mesa. Los
asistentes ya tienen recorrido de teclado, clériga guardada y partida creada.
Grupo completo de seis/compañeros móviles y presencia factual verificados;
la nueva apertura real reveló otra fuga narrativa cubierta en D119. Preguntar
a Nera/Lyra ya recibe respuestas de sus propios agentes, con cola durable y
prioridad humana (D120). La admisión ahora valida el estado vigente y muestra
errores recuperables (D121); la suite usa una base separada de desarrollo
(D122). Voz/sujeto de los demás PCs y relativa real de Iria
cubiertos por D123; D124 conserva gasto de magia al ampliar nivel. D125
rechaza pestañas/sync antiguas y verifica progresión real de Mara en seis
mesas, con avisos visibles. D126 desbloquea/amplía reservas de clase sin
reponer gasto y verifica la progresión/pago de Sira. D127 cubre el nombre corto
único y la subordinada real, protegiendo atribuciones completas de PCs/PNJs.
D128 comparte reservas factuales entre ficha/brief y verifica una consulta
real de Sira sin mutarlas. D129 conserva bestia/forma original progresada y
caducidad en subida/sync/reapertura. D130 identifica forma animal y vitalidad
original en ficha, con progresión/reversión de Sylvi real verificadas.
D131 mantiene voces registradas dentro del beat en Events/historial/preview.
D132 entrega el prefijo de rol DM/PC en los mensajes reales, también tras
compacción/historial compartido. D133 conecta estilo guardado y mide una nueva
mesa: Lyra/Vex responden, 20,70 s al humano y recursos conservados. Siguiente
revisión de aquella apertura: D134 conserva participación real, impide repetir
IA antes del humano y evita consulta al completar el ciclo. Nueva mesa da
control en 12,10 s; conversación propia en 17,61 s conserva todo el World.
D135 corta colectivos explícitos y rechaza la escena inventada sin borrar
preguntas; mantiene invitaciones PNJ y voz propia. D136 resuelve preguntas por
identidad registrada, presencia/capacidad y speaker persistido pese al volumen
de eventos. D137 retira «al acercaros…» del fixture real sin perder hechos
NPC y protege citas/preguntas. Continuación Sylvi/Lyra/Vex en 10,02 s, World
completo igual y reload/fichas 375/1440 px comprobados. D138 reserva primera
persona tras presentación DM; nueva mesa de seis en 6,01 s, pregunta a cinco
en 22,72 s con World completo igual. D139 identifica/corrige tres falsos
positivos de filtro con raw exactos; seguimiento real de tres en 13,09 s,
raw/filtrado/persistencia completos y World igual. D140 valida parámetros ASI
sin perder borrador/conexión; error junto a controles y recuperación real por
teclado, biblioteca/todas las partidas asociadas intactas. D141 cubre el gesto
real «Iria las recoge…, asintiendo» y conserva el entorno fuera de citas;
seguimiento real en 15,67 s, tres propias y DM sin gesto, World igual.
Aventura19425: combate real/crítico, encargo/recompensa durable y descanso
Mara 8→11/14 PG, un dado gastado y reloj3600, biblioteca intacta. D142
conserva el destinatario PNJ al cerrar el inciso de voz propia y mantiene
el corte de respuestas ajenas. D143 registra el vocativo humano literal al
consumir la declaración, antes del narrador, sin depender de la tool: nueva
petición de jarra da voz propia a Vex y vuelve a Mara en 6,51 s, World igual.
Reinicio real tras combate/descanso conserva World/historial/recursos y cierra
los procesos anteriores. D144 aporta reloj/cupo diario y facts vigentes; D145
registra el entorno tras cambios confirmados aunque el DM omita la tool.
Mañana real: registro4,72 s, retorno23,89 s, mecánicas intactas y escena
conservada tras reinicio. D146 alinea feedback de descanso largo con el cuerpo
vigente después de caducar la forma; noche real de Sylvi conserva recursos,
biblioteca y reapertura. No se declara cerrada la coherencia general del grupo.
Siguen otras alusiones,
semántica de preguntas/viaje acordado, fidelidad a escenario y continuidad/
latencia del grupo; el gate técnico no cierra ese objetivo.

**Corte de versión jugable:** verificados los cuatro bloques V1.1–V1.4 de
[`05-cierre-version-jugable.md`](05-cierre-version-jugable.md). Se congela la
ampliación de mecánicas durante este corte. Siguiente prioridad acotada:
latencia de turnos reales y consistencia narrativa. La lista siguiente conserva
los frentes generales; el playtest básico ya tiene evidencia en ese documento,
sin certificar campañas largas, todas las clases ni multijugador real.

**Primera mejora post-V1 entregada (D93–D94):** relevo D30 sin consulta
redundante al TM y brief factual con CA efectiva/PG temporales/estabilidad.
25 pruebas nuevas; contrato en [`06-mejoras-post-v1.md`](06-mejoras-post-v1.md).
La reducción de llamadas está comprobada offline; nueva medición live de
latencia y consistencia narrativa sigue pendiente.

**Auditoría del inicio de turno entregada (D100):** roller de Game y grupos
de dados también para Hold Person/Spirit Guardians fuera del beat de IA;
fallback del actor sincroniza el combatiente siguiente. Inspiración e
Indomitable se consumen antes de resolver concentración del daño recurrente.
13 regresiones/smokes nuevos, incluidos contexto del DM/PC automático y
recarga sin repetir daño. Conserva el alcance de D97/D99.

1. **Playtest integrado de producto**, tras el trabajo de UI en paralelo:
   crear héroe/partida, declarar acciones, combatir, descansar, pausar y
   reanudar; revisar móvil y latencia real del DM/TurnMaster. El recorrido
   automatizado verifica estado y persistencia, no sustituye esta prueba.
2. **Efectos ejecutables de hechizos y condiciones** (R24 y R28):
   **Bless entregado (D85)**, con bonus real, objetivos, fuente y caducidad;
   23 tests nuevos incluyen oráculos, Codec/Postgres y smoke de tools.
   **Shield of Faith entregado (D86)**: +2 CA efectiva, concentración y
   duración; 19 pruebas nuevas, incluida recuperación desde Postgres.
   **Heal entregado (D87)**: curación plana 70–100 PG y retirada de ceguera,
   sordera y enfermedad explícita; 14 pruebas, incluidas PCAgent y Postgres/Game.
   **Spare the Dying entregado (D88)**: estabilización sin curar, una acción
   sin casilla; 13 pruebas nuevas, incluidas PCAgent y Postgres/Game.
   **False Life ampliado (D89)**: escalado +5 PG temporales por nivel superior,
    objetivo propio y ciclo de fuente/plazo probado; 13 pruebas nuevas.
    **Lesser Restoration entregado (D90/M65)**: una condición elegible con
    selección explícita si hay varias; 18 pruebas, incluidas tools y Postgres/Game.
     **Imposición de manos ampliada (D91/M33)**: purifica veneno/enfermedad
     por 5 puntos cada una, combinable con curación en una acción; 13 pruebas nuevas.
     **Escalado de trucos + hojas rancias + Guiding Bolt (D95)**: daño de trucos
     por nivel de personaje (5/11/17), overlay builtin para trucos con `dice: null`
     (Sacred Flame, Poison Spray, Vicious Mockery, Acid Splash a 1 objetivo) y
     marcador de ventaja consumible de Guiding Bolt con caducidad perezosa.
     **Sleep y Shield (D96)**: Sleep corrige el bug que "curaba" a los enemigos
     (pool RAW 5d8 +2d8/nivel, orden por PG, despierta con daño); Shield es
     postura +5 CA efectiva con magic missile a 0. Mapa completo de los 319
     hechizos y candidatos siguientes en `tecnico/11-mapa-efectos.md`.
     **Hold Person y Faerie Fire (D97)**: paralyzed y marca de ventaja
     vinculados a concentración, con limpieza por fuente generalizada
     (`without_source` ya no limitada a bless/shield_of_faith).
     **Mage Armor y Charm Person (D98)**: CA efectiva `max(ficha, 13+DES)` 8 h
     sin armadura; `charmed` 1 h roto por daño del lanzador/bando, con
     desventaja solo contra el lanzador. Las salvaciones de condición usan el
     stack completo de las de hechizo (gnomo/auras/inspiración/Indomitable).
     **Spiritual Weapon persistente y Spirit Guardians (D99)**: postura 10
     rondas con tool de acción adicional por el pipeline completo; aura
     recurrente al turno del lanzador con SAB/mitad y upcast +1d8/nivel.
    Continuar con otros efectos descriptivos,
    definiendo antes su ADR y oráculos independientes. Las 319 entradas del
    catálogo no se cuentan como efectos ejecutables.
3. **Catálogo/progresión y entradas inválidas**: continuar los puntos 4–6
   de `../tecnico/10-auditoria-motor.md`, con reproducciones antes de fixes.
   Rasgos nuevos, límites de hechizos y elecciones del builder se concretan
   por ítem; las ampliaciones de F7 requieren su ADR.

Los apartados siguientes conservan el historial de entregas; D81–D83
actualizan las limitaciones originales sobre acciones y duración.

---

## F6 — Pulido del producto (entregado)

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

Hecho: D179 amplía el corte compacto de `game.css` hasta1023px — feed+input
primero, rail izquierdo oculto (iniciativa en topbar), ficha derecha en cajón
operable mediante botón LiveView. Entre721–1023px/altura≤600px abre en lateral;
desde1024px conserva tres columnas. PlayerSheets conserva lectura y reinicia
al abrir; TurnControls revela el botón enfocado. Dados overlay con
`max-width:100vw`. AC-20.1–20.4/20.6–20.9 y evidencia en calidad/pruebas.

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
    Action Surge D47, Fighting Style D48, Lay on Hands D49, Bardic
    Inspiration D50, Arcane Recovery D51, Divine Sense D52, Turn Undead
    D53, Ki/Flurry of Blows D54, Hunter's Mark D55, Font of Magic D56,
    Indomitable D68 y spellcasting paladín/ranger L2, `spells_known`,
    rasgos raciales salvo Lucky D66, Resistencia implacable D67, Savage
    Attacks D69, Aliento de dragón D70 y Astucia gnoma D71) quedan en 🟡.

---

## F7 — Fuera de v1 (requieren ADR nuevo para entrar)

**D190 admitido y entregado — inventario narrativo R38 acotado.** Rules/World
cuantifican posesión descriptiva, dos tools DM de exploración validan stock/
identidad/replay y Codec/progresión; ficha/brief leen ese estado. Revisión de
escena conserva pendiente ante fallo y no repite efectos. TestModel/restart/
navegador/SQL y gates completos acreditan los AC. Continuar variantes del
agente y latencia; no incluye equipamiento, efectos, economía, peso o registro
global del suelo ni supone beta certificada.

Cada uno cierra una simplificación declarada (`02-requisitos` R09/R28):

- **Extra Attack** (D35): **entregado.** `Actions.attack` resuelve N golpes
  vs el mismo objetivo; N de `Progression.attack_count/2`. No es Action
  Surge; el presupuesto de acción/bonus/reacción se añadió en D82.
- **temp_hp** (D36): **entregado.** Daño absorbe `temp_hp` primero; no
  apila; `heal` no lo toca; tool `grant_temp_hp`; False Life 1d4+4 al
   caster. D83 añade duración a False Life y limpieza al descansar largo;
   D89 añade escalado +5 por nivel superior y valida objetivo propio.
- **Concentración** (D37): **entregado.** `Character.concentrating` +
  Codec; CON save al daño; rotura a 0 hp / incapacitated-class; tool
  `drop_concentration`. D81 unifica daño/salvación y D83 añade reloj;
  D85 añade Bless con bonus y objetivos vinculados a concentración.
- **Resistencias** (D38): **entregado.** Tres listas en `Character`;
  `apply_damage/3` por tipo (inmune / resist / vuln, cancelación);
  `temp_hp` post-mod; concentración post-resist; skeleton SRD;
  hellish resistance. Sin magic vs mundane.
- **Feats** (D13): catálogo + integración en ASI (elección feat vs +2).
- **Pact Magic del warlock** (D40): **entregado.** Tabla PHB 5.1 (huecos
  1º–5º del mismo nivel); consume el hueco de pacto; short rest restaura
  solo al brujo. Sin Mystic Arcanum (el upcast de daño llegó en D74 para
  todos los conjuradores, warlocks vía hueco de pacto).
- **Sneak Attack del rogue** (D41): **entregado.** `div(level+1, 2)` d6;
  arma finesse o ranged; advantage o aliado consciente; disadvantage
  bloquea; primer hit de `Actions.attack`; crítico 2N d6. D82 limita el uso
  por turno entre varias `make_attack`. Sin grid.
- **Rage del bárbaro** (D42): **entregado.** `Character.raging` + Codec;
  bonus melee `rage_damage/1` en cada hit; overlay B/P/S; no spells;
  STR check ventaja; termina en end_rage / 0 hp / unconscious /
  end_combat. Sin usos/día, sin reloj de 1 minuto — los usos entraron
  en D72.
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
  enfermedad/veneno originalmente; D91 añade ambas por 5 puntos cada una.
  Divine Sense se entrega en D52.
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
  restante. Sin sorcerous restoration ni casillas > 5º (el gasto de
  puntos en Metamagic entró en D65).
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
- **Proficiency de skills en checks + Jack of All Trades** (D60): **entregado.**
  Arregla el hueco v1 (la tool `ability_check` ignoraba
  `skill_proficiencies` de la ficha). Nueva tabla `Rules.Skills` (18
  skills SRD → característica; `normalize/1` acepta espacios/guiones/
  mayúsculas; detección skill-PRIMERA — "intimidation" es CAR, no el
  ability `int`, porque el parse de ability es por prefijo); la tool
  `ability_check` mantiene arity y nombre de parámetro `ability`
  (exAgent bindea args por nombre: renombrarlo rompería llamadas
  viejas); `Combat.check_proficiency/2` público para que el mensaje
  muestre el mismo desglose que la tirada: skill entrenado → prof
  completa desde la ficha; sin entrenar y bardo L2+ → `div(prof, 2)`
  (JoaT, floor; también en ability cruda, RAW); resto → 0 como v1;
  nunca ambos; ability cruda → flag del caller (compat, formato v1);
  skill desconocido que tampoco es ability → error directivo con
  ejemplos; mensaje ES "chequeo de Sigilo (DES): 1d20(11) + DES 3 +
  prof 2 = 16 vs CD 15 — éxito" ("+ JoaT 1"); prompts PC/DM piden el
  nombre de skill cuando aplique (sin línea de JoaT: es pasiva). Sin
  campos nuevos ni Codec; `cunning_action_hide` D57 intacta (ya suma
  prof de stealth; sin multiclase JoaT no le aplica). Sin Expertise,
  prof de tools/instrumentos, checks pasivos ≠ perception, Reliable
  Talent, feats, multiclase.
- **Aura of Protection del paladín** (D61): **entregado.** Pasiva sin
  tool ni campos nuevos: todo paladín L6+ consciente suma
  `modifier(cha)` a TODAS las salvaciones de su `side` (él incluido)
  — rama `:save` de `cast_spell`, `turn_undead` (SAB), death saves
  (RAW aplica: `Combat.death_save/2` desplaza el umbral 10 sin tocar
  nat 1/20) y concentración (CON al daño); NO a ability checks ni
  attack rolls; varios paladines apilan (suma); CHA < 10 → bonus
  negativo sin piso (RAW); se aplica antes de la inspiración bárdica
  (D50 re-deriva el éxito del total); desglose "+3 aura" / "(-1
  aura)" en el mensaje; helper compartido `World.paladins_conscious/3`
  + `Actions.aura_save_bonus/2` privado. Simplificación sin grid: sin
  radio de 10 pies — cubre todo el side (regla genérica: un
  no-muerto aliado también lo recibe). Sin Aura of Devotion (charm),
  Aura of Hate, Improved Divine Smite, feats, multiclase.
- **Aura of Courage del paladín** (D62): **entregado.** Pasiva sin
  tool ni campos nuevos: `World.apply_condition` NO aplica
  "frightened" a quien comparte side con un paladín L10+ consciente
  (él incluido) — `{:ok, world}` sin mutar (inmunidad ≠ error;
  idempotencia y `remove_condition` intactos); los callers lo
  reportan: `Tools.apply_condition` (DM) devuelve "X es inmune al
  miedo (Aura de Coraje)" y `turn_undead` (D53) particiona sus
  fallidos en asustados/inmunes con la misma frase (doble hook =
  defensa en profundidad para callers viejos); regla genérica por
  side (un no-muerto aliado de un paladín L10+ es inmune al fear del
  clérigo propio — aceptable, documentado). Misma simplificación
  sin-grid que D61. Sin radio, inmunidad a charm (Aura of Devotion,
  futuro), feats, multiclase.
- **Wild Shape del druida** (D63): **entregado.** Dos campos nuevos
  (`wild_shape_uses` + `wild_shape` con Codec tolerante a jsonb
  viejo), catálogo fijo `Monsters.wild_shape_beasts/0` (cat ND 0 y
  black_bear ND 1/2 nuevos, wolf existente; los tres también
  spawnables), tools `wild_shape(who, beast)` / `end_wild_shape(who)`
  (druida L2+, DM cualquiera, PC sólo sí mismo, errores no mutan);
  transformar gasta 1 uso SIEMPRE (2/rest, builder druida L2+ → 2),
  guarda la forma original (str/dex/con/hp/max_hp/ac/weapons) y
  aplica la de la bestia conservando mental/identidad/profs/
  condiciones/concentración; inventario intacto siempre; gate de CR
  (L2–3 → máx 1/4, L4+ → máx 1/2); `cast_spell` bloqueado en forma
  (atacar con armas de bestia, checks y descansar funcionan igual);
  revert manual restaura todo con PG = orig exacto; auto-revert en
  `World.apply_damage/3` con sólo el exceso de daño al druida
  (`hp = max(0, orig_hp − exceso)`; temp_hp/resist como siempre; nota
  en el log para la narración; caído a 0 → death saves normales);
   short y long rest recargan los 2 usos sin forzar revert; level-up
   no toca usos ni forma. Sin duración, Circle of the Moon, formas
   volar/nadar, equipment merge, feats, multiclase.
- **Uncanny Dodge del pícaro** (D64): **entregado.** Un campo nuevo
  (`Character.uncanny_dodge` boolean con Codec tolerante a jsonb
  viejo), tool `start_uncanny_dodge(who)` (pícaro L5+, DM cualquiera,
  PC sólo sí mismo, errores no mutan: who inexistente, caído, no
  pícaro, L4–, ya armada); postura armable gratis en cualquier
  momento (sin reacciones ni rondas en el motor — patrón
  `inspired`/`reckless`); en `World.apply_damage/3` (cuello único de
  daño): armada y amount > 0 → `div(amount, 2)` (floor) sobre el
  amount de entrada — antes de resistencias D38 y temp_hp D36 (orden
  fijado en D64) — y consume la flag; aplica a CUALQUIER fuente de
  daño; amount ≤ 0 no consume; apila con Evasión D59 (mitad de mitad =
  cuarto, floor); auto-revert D63 intacto (corre tras la
  mitigación); descansos NO gestionan la flag y rearmar tras consumir
  es gratis. Sin economía de reacción/ronda (1 uso por daño, no por
  ronda), resistencias dañinas (D38 es otro sistema), Deflect
  Missiles, feats, multiclase.
- **Metamagic del hechicero** (D65): **entregado.** Un campo nuevo
  (`Character.metamagic` nil | `%{option, target}` con Codec
  tolerante a jsonb viejo), tool `arm_metamagic(who, option, target)`
  (hechicero L3+, DM cualquiera, PC sólo sí mismo, UNA opción sin
  un-arm ni reembolso, errores no mutan: who inexistente, caído, no
  hechicero, L2–, opción desconocida, ya armada, puntos
  insuficientes, heightened sin target, twinned sin target /
  inexistente / self); armar gasta 1/3/2 puntos de hechicería (D56) y
  fija el mapa; la aplicación y el consumo viven SÓLO en
  `Actions.spell/5` → `resolve_spell`: Empowered (los primeros
  `max(1, CAR)` dados de daño se tiran dos veces conservando el mayor,
  dos draws del roller por dado, crit dobla la base sin duplicar
  rerolls, fallo de :attack también consume, curación/utilidad nunca
  califican, etiqueta en el desglose), Heightened (hechizo :save al
  target armado → desventaja como `requested` en `save_mode`,
  combinada por capas con Danger Sense/Evasión/auras; otro objetivo no
  aplica ni consume) y Twinned (hechizo contra target ≠ lanzador → la
  misma resolución contra el segundo target armado con dados propios,
  mensaje en bloque por objetivo, UNA casilla y UNA concentración;
   self-buff no aplica ni consume); consumo-on-apply (divergencia
   menor de RAW documentada en el ADR); rests y level-up NO tocan la
   metamagia (los puntos ya se recargan en long rest). Sin Quickened,
   Distant, Extended, Subtle, Careful (sin efecto en este motor),
   Sorcerous Restoration, Metamagic Adept, feats, multiclase.
- **Indomitable del guerrero** (D68): **entregado.** Pasiva de clase sin
   tool ni prompt: `Character.indomitable_used` (Codec tolerante a jsonb
   viejo) + helper `maybe_indomitable/7` en `Actions` aplicado en los
   TRES sitios donde el personaje salva (hechizo `:save`, `turn_undead`
   SAB, concentración CON): fallo FINAL de un guerrero L9+ con el uso
   disponible → UN reroll con la misma llamada (mismo modo —Heightened
   D65/Danger Sense D58— y mismo bonus plano —aura D61 re-sumada—; el d6
   bárdico se gastó en el primer intento; Lucky D66 puede dispararse
   gratis en el reroll) y se USA el nuevo resultado (RAW, no keep-best);
   marca la flag vía `World.set_indomitable/2` (struct actualizado que
   viaja a la simulación de concentración y se hilva entre golpes de una
   misma acción — sin doble gasto); etiqueta "(Indomitable: X→Y)" en el
   desglose; 1 uso por descanso largo (`long_rest` recarga,
   `short_rest` no). Death saves y auto-fails fuera (no hay dado que
   rerrollear). Sin usos L13/L17, checks ni attack rolls, feats,
   multiclase.
- **Savage Attacks del semi-orco** (D69): **entregado.** Pasiva racial
   sin tool, sin campos ni rests: hook en `Combat.damage_roll/4` vía
   nueva variante pública `damage_roll_tagged/4` (`{total, savage_die}`,
   firma intacta, patrón `*_tagged` D66) — `race == "half-orc"` + arma
   melee (`ranged != true`) + `:crit` → UN dado del TAMAÑO del arma (un
   2d6 añade 1d6; nunca doblado); NO a distancia, hechizos ni
   no-críticos; apila con sneak/smite/mark/rage; el golpe sin armas de
   Flurry D54 también aplica (melee weapon attack RAW); desglose
   " (+N Savage)" en el swing. Sin Darkvision, feats, multiclase.
- **Aliento de dragón del dragontino** (D70): **entregado.** Rasgo
   racial CON tool: `breath_weapon(who, target)` (DM cualquiera, PC
   sólo sí mismo), campo `Character.breath_weapon_used` (Codec
   tolerante a jsonb viejo), dado por nivel en
   `Progression.breath_dice/1` (L1–4 2d6, L5–10 3d6, L11–16 4d6, L17+
   5d6), daño "fire" FIJO (sin ascendencia dracónica, ADR),
   salvación de DES vs CD `8 + CON + prof` del dragontino (éxito →
   mitad floor), 1 uso por descanso con short Y long recargando
   (`compose_rest`, patrón ki D54), uso gastado SIEMPRE que se
   resuelve; mismo stack de sitio de salvación que los hechizos
   (Danger Sense, Lucky, aura D61, inspiración, Indomitable D68,
   Evasión D59, concentración del objetivo); target caído permitido;
   no es hechizo (sin casillas, funciona en Forma salvaje D63, sin
   Metamagic). Allowlist PCAgent + línea de prompt dragontino (por
   raza) + línea DM. Sin ascendencia/cono de 15 pies/reacción/segundo
   aliento/Dragon Fear/Wings, feats, multiclase.
- **Astucia gnoma** (D71): **entregado.** Pasiva racial sin tool,
   campos ni rests: ventaja en salvaciones INT/SAB/CAR contra "magia"
   (equivalencia engine: toda salvación de `cast_spell` rama :save y
   `turn_undead`; DES/CON y checks/death saves fuera), inyectada como
   fuente extra `gnome_advantage:` en `Conditions.save_mode/4` (opts
   opcional, `save_mode/3` intacta) para que `combine/2` la combine —
   con Heightened D65 o desventaja de condición → normal; etiqueta
   "(Astucia gnoma: ventaja)" cuando drove el modo; Indomitable D68
   conserva la ventaja en el reroll (mismo modo); rama turn_undead
   inyectada por contrato (hoy inalcanzable: el objetivo de Expulsar
   exige `race == "undead"`). Sin Darkvision, demás rasgos, feats,
   multiclase.
- **Usos de Furia + Furia implacable del bárbaro** (D72): **entregado.**
   Economía de recursos del bárbaro: `Character.rage_uses_used`
   (integer, Codec tolerante) gastado por `World.start_rage/1` al
   ENTRAR (tope `Progression.rage_count/1`: L1–2 2, L3–5 3, L6–11 4,
   L12–16 5, L17+ 6; sin furias → error sin mutar; `end_rage` NO
   devuelve; ya raging idempotente sin gasto; sólo `long_rest`
   recarga). Furia implacable L11+: `Character.relentless_rage_successes`
   + hook `maybe_relentless_rage/4` en `World.apply_damage/4` (nuevo
   `roller` opcional hilvanado por `Actions.pipe_damage`), bárbaro
   raging a 0 pg → salvación CON vs `10 + 5 × éxitos` con
   `Rules.Combat.saving_throw` (prof CON + Lucky D66) + aura D61
   (`World.aura_save_bonus/2`, movida de Actions); éxito → 1 pg,
   siguientes CD +5, nota en el world log (sin RollLog ahí — la nota
   es el registro); fallo → cae a la RE racial D67 si semi-orco (ambas
    capas; el éxito de clase no consume la racial); `long_rest` resetea
    éxitos. Orden de capas: Uncanny Dodge → resist → temp_hp → hp →
    revert → Furia implacable → RE. Sin duración, bonus action, Paths,
    Persistent Rage L20, feats, multiclase.
- **Expertise de pícaro y bardo** (D73): **entregado.** Cierra el   subsistema de skills (D60 aplicó prof simple): duplica el bonus de
   competencia en skills entrenadas elegidas (pícaro L1: 2, L6: 4;
   bardo L3: 2, L10: 4 — `Progression.expertise_count/2`). Decisión
   clave (ADR): la elección vive en una TOOL (`gain_expertise(who,
   skill)`), NO en el builder ni en level-up — mismo patrón que el
   resto de features: el LLM decide, el motor valida y persiste
   (clase, nivel del primer cupo, skill conocida/normalizada,
   entrenada, duplicada, cupo; errores no mutan). Campo
   `Character.expertise` (array, Codec tolerante a jsonb viejo) +
   `World.add_expertise/2`; resolución en
   `Combat.check_proficiency/3` (parámetro opcional `skill`, kind
   `:expert` → `prof × 2`) consumida por `Actions.check` ("prof 4
   (experto)") y `cunning_action_hide` (Sigilo doblado); JoaT nunca
   aplica a una expertised; ability cruda y passive perception nunca
   doblan. Permanente (sin rests); allowlist PCAgent + línea
   condicional con cupo pendiente + línea DM. Sin tools/instrumentos,
   picks 2024, integración con level-up choices, feats, multiclase.
- **Upcasting 5e RAW** (D74): **entregado.** `cast_spell` gana
  `cast_level` opcional (nil = nivel base, compat hacia atrás): gasta
  UNA casilla del nivel pedido y aplica el escalado EXACTO de una tabla
  curada EN CÓDIGO (`Rules.Upcast`, auditada contra RAW 2014 — el JSON
  del SRD no trae "A niveles superiores" estructurado): fireball
  +1d6/nivel s/3º, cure_wounds +1d8/n s/1º, magic_missile +1 dardo/n
  s/1º (mensaje con el nº real de dardos), spiritual_weapon +1d8 cada
  dos niveles, vampiric_touch +1d6/n, y burning_hands, thunderwave,
  shatter, lightning_bolt, blight, flame_strike, healing_word,
  prayer_of_healing. El dado extra se combina con la base antes de
  resolver (mismo RollLog, mitad de :save sobre el total escalado,
  crit dobla los extra, Empowered D65 sobre los combinados); CD y
  concentración sin cambios (RAW). Errores no mutan (< base, > 9, no
   entero, truco, sin casilla del nivel pedido). Excluidos (ADR): heal,
    mass_cure_wounds, sleep, multi-objetivo/multi-rayo, 2024. M58.
    Heal deja de estar excluido: D87/M63 implementa su curación y escalado planos.
- **Araña gigante + Resistencia enana (D75/D76)**: **entregado.** La
   araña (`Monsters.giant_spider/1`, key `"giant_spider"`, CR 1 RAW,
   en las enumeraciones de `spawn_monster`) es la primera fuente REAL
   de daño de veneno del motor: mordida "3d8+3 poison" total (dados
   "3d8" + DES +3 que el motor suma; simplificación ADR del 1d8+3
   perforante + 2d8 veneno con salvación CON de RAW), +5 al ataque,
   sin telaraña/trepar. Con ella, la Resistencia enana (D76) tiene
   efecto medible: sin campos ni tools — mitad (floor) del daño
   "poison" en la capa D38 (`Character.incoming_damage/3`), apilable
   multiplicativamente con Uncanny Dodge D64 (enano pícaro = cuarto,
   RAW), + ventaja en la salvación :save de hechizos con
   `damage_type "poison"` (fuente `dwarf_advantage:` en
   `Conditions.save_mode/4`, patrón D71, etiqueta "(Resistencia
   enana: ventaja)"; único hechizo así hoy: cloudkill del SRD).
   M59–M60. Tests `poison_test.exs` (14).
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
   (referencia actual en `progress.md`). Si toca prompts/agentes: smoke con TestModel incluido.
5. Actualiza `../progress.md` (mueve el ítem) y este doc (marca el ítem). Si
   tomaste una decisión no trivial: ADR en `../decisions.md`.
6. Commit estilizado (`feat(motor): …`, `fix(hero): …`).
