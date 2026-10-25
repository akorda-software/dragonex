# Cierre de versión jugable — alcance finito

Fecha: 2026-09-26. Estado: **primer corte jugable verificado**, alcance de abajo.

Objetivo: completar una aventura corta, conservar sus resultados y poder
reanudarla. Este cierre no exige implementar las 319 entradas SRD.

## Cuatro bloques de salida

| Bloque | Criterio de salida | Estado |
|---|---|---|
| V1.1 — Acceso y héroe | Registro/login; crear, guardar y volver a abrir un héroe de nivel 1; crear partida con él | Verificado |
| V1.2 — Partida real | DM/TurnMaster con proveedor real; declaración humana, tiradas, combate y cierre sin bloquear el turno; registrar latencias observadas | Verificado en arena + microaventura |
| V1.3 — Recursos y continuidad | Daño/curación, descanso, pausa/reanudación y recarga conservan PG, recursos y estado; sin duplicar acciones | Verificado: navegador + oráculo automatizado |
| V1.4 — Móvil y regresión | Mesa a 390×844 y escritorio; controles alcanzables, sin desbordamiento bloqueante; suite, compile y formato verdes | Verificado; también mesa a 375×812 |

## Mecánicas imprescindibles para este corte

- Héroe humano guerrero de nivel 1 como recorrido mínimo de extremo a extremo.
- Ataques, CA/PG, iniciativa, turnos y gasto de acción; segundo aliento.
- Caída, salvaciones de muerte, estabilización y curación verificadas por motor.
- Descansos, reserva de recursos, persistencia y recuperación de partida.
- Magia de apoyo del motor cubierta por pruebas existentes: Bless, Shield of
  Faith, Heal, Spare the Dying, False Life, Lesser Restoration e Imposición
  de manos. Su cobertura automatizada no implica probar todos en UI en esta partida.

No se añaden nuevos conjuros o rasgos como condición de cierre salvo que un
fallo reproducible impida este recorrido. El catálogo ampliado, progresión alta,
geometría táctica, multiclase y dotes siguen sus límites documentados.

## Reglas de aceptación

- Cada bloque necesita evidencia fechada; una suite verde no sustituye el
  recorrido de navegador ni el proveedor real.
- Cualquier bloqueo de creación, turno, persistencia o acceso a controles es
  un defecto de cierre: reproducir, corregir y volver a probar su recorrido.
- Diferenciar fallo funcional, límite deliberado y mejora estética.
- Utilizar cuenta/partida de playtest identificables; no modificar partidas ajenas.
- La versión se declara jugable cuando V1.1–V1.4 están verificados y no quedan
  defectos bloqueantes abiertos. No equivale a certificar todo el SRD.

## Evidencia y hallazgos

- Inicio: suite anterior 1750 passed / 3 excluded; colisión intermitente de
  email en fixture de ProtectedRoutesTest documentada en auditoría §14.
- Entorno local: Phoenix en el puerto ya registrado 4035, arrancado con
  `bin/dev`. Configuración local dispone de credencial OpenRouter (valor no expuesto).
- Navegador Orca dedicado al playtest; página inicial accesible.

### Recorridos reales

- Cuenta de prueba `Playtest cierre v1`: registro, logout y login comprobados.
  Héroe **Bran Cierre**, humano guerrero nivel 1, creado manualmente con los cinco
  pasos del builder, guardado y reabierto: `/heroes/4755`, 12/12 PG, CA base 18.
- **Arena**, `/games/12725`: selección de héroe propio, eliminación de compañeros,
  creación y narración real con OpenRouter `deepseek/deepseek-v4-flash-0731`.
  Petición de goblin → iniciativa → fallo de ataque → respuesta del goblin →
  segundo ataque (21 contra CA15, 9 de daño) → enemigo a 0 y fin de combate.
- Segundo aliento ejecutado y descanso corto de una hora. Estado leído desde
  Postgres: 12 PG, `elapsed_seconds: 3606`, `second_wind_used: false`;
  `hit_dice_used: 0` al descansar con PG completos. Pausa, recarga de navegador,
  reanudación y nueva pausa conservan esos valores. La recuperación tras reinicio
  de Game y curación desde PG dañados se comprueba además con
  `game_engine_journey_test.exs`; en esta arena el goblin falló su ataque.
- **Microaventura**, `/games/12731`, «El anillo del pozo»: escenario personalizado
  con objetivo finito. Investigación `d20:3 −1 = 2` contra CD10 falla; el DM ofrece
  una pista, segunda declaración recupera y devuelve el anillo, Ada agradece y
  el DM confirma el encargo completado. Cierre **narrativo**, no transición automática
  a `:ended`: la partida queda pausada por el usuario de prueba.
- Ambas partidas quedan pausadas; no se han alterado partidas ajenas.

### Defectos encontrados y corregidos

1. **Ficha móvil vacía en exploración**, bloqueante: el cajón solo mostraba los
   asientos derechos; en solo, el personaje estaba en la columna izquierda oculta.
   Ahora contiene la ficha propia completa en móvil, conservando las columnas de
   escritorio. Regresión reproducida en rojo en `mobile_player_sheet_test.exs`.
2. **«Es tu turno / Actuar» durante pausa**, mensaje contradictorio: ahora solo
   se muestra al estar `:waiting`, corresponder el turno y no procesarse un beat.
   Durante pausa sigue permitida la declaración de intención, etiquetada «Declarar».
   Segunda aserción reproducida en rojo en la misma prueba.
3. El input de acción tenía nombre accesible vacío en móvil (label solo con icono).
   Se añade `aria-label="Tu acción"`, comprobado por test y árbol de accesibilidad.

### Evidencia visual y automatizada

- Mesa real a 390×844 y 375×812: `scrollWidth == innerWidth`, input visible,
  ficha propia desplegable. Ficha de héroe y entrada del builder a 390px sin
  desbordamiento. Mesa de escritorio a 1440×900 sin desbordamiento.
- Capturas locales en `/tmp/opencode/`: `dragonex-v1-mobile.png` (inicial),
  `dragonex-v1-mobile-exploration-fixed.png`, `dragonex-v1-desktop-paused.png`
  (evidencia previa del aviso contradictorio), `dragonex-v1-story-complete.png`.
  Son artefactos temporales, no archivos versionados.
- Suite: **1751 passed / 3 excluded**; compile con `--warnings-as-errors`,
  formato y diff correctos. Log `/tmp/opencode/dragonex-v1-closure-suite.log`.
- Detector visual ejecutado: avisos sobre estilos preexistentes (animación de
  ancho, rebote, bordes). No son fallos funcionales de este corte ni se rediseña
  la identidad pixel-art durante el cierre.

### Límites y siguiente prioridad

- **Latencia perceptible**: entre el evento de declaración y el comienzo del
  siguiente turno DM: 19/42/40 segundos en arena y 30/35 segundos en microaventura.
  Son intervalos de turnos con posibles tools/TurnMaster, no latencias puras del
  proveedor ni percentiles; incluyen más de una llamada. Optimizar antes de
  pretender una experiencia ágil para más usuarios.
- El DM llamó una vez «paladín» al guerrero y creó una diana hostil por iniciativa
  narrativa propia en arena. El descanso se resolvió y volvió a exploración;
  estas inconsistencias narrativas se registran para una siguiente mejora.
- No certifica campañas largas, todas las clases/niveles, multijugador real,
  red móvil física, monedas/recompensas mecánicas ni todo el catálogo SRD.
- La colisión intermitente de email en fixture de autenticación sigue siendo
  deuda de aislamiento; no apareció en esta suite final.


## Revalidación del 2026-10-25 (D259–D264)

- Cuenta de playtest propia y héroe **Bran Octubre**, humano guerrero nivel 1,
  creados desde Chromium mediante los formularios normales. Héroe `/heroes/5901`.
- Partida real `/games/19467`, «El sello de Ada», con Lyra como compañera IA.
  OpenRouter `deepseek/deepseek-v4-flash-0731` según el entorno de desarrollo;
  no es una medición del modelo de casa fijado en producción.
- Combate: iniciativa factual, mordisco contra Bran fallido (8 contra CA19),
  Rayo ígneo de Lyra (19 contra CA12, 8 de daño), rata a 0/7 y vuelta a turno
  humano. Segundo aliento y descanso recuperan el recurso. Nadie cayó en este
  combate; esa ruta se verifica con el navegador determinista descrito abajo.
- Hallazgo real corregido: el primer descanso narró una hora pero llevó el
  reloj de 0 a 10800 s. D264 limita el intervalo del DM; tras cargar la corrección,
  repetir el descanso grupal avanzó exactamente 3600 s (10800 → 14400).
  El histórico anterior conserva lo ocurrido; no se corrigió retroactivamente.
- Inventario real: evento 51 recoge un sello de bronce del cofre, saldo 0 → 1;
  evento 59 lo entrega, saldo 1 → 0, y el DM cierra el encargo. Ese primer
  remove omitió el receptor: motivó `recipient` obligatorio nullable. En la
  comprobación posterior, evento 82 entrega el trofeo de Bran a **Ada**, con
  contraparte registrada y saldo 1 → 0. No se altera el comprobante previo.
  Un préstamo narrado con devolución inmediata no generó cambios de stock;
  D239 no garantiza trazar todos los traspasos transitorios de la prosa.
- Escritorio 1440×900 y móvil 375×812: controles operables, ficha propia con
  inventario, sin desbordamiento horizontal. Entrega desde móvil, pausa,
  recarga y reinicios del contenedor dev conservan la mesa y los movimientos.
  Estado final: pausada, reloj 14400 s, sello y trofeo fuera del inventario.
- Capturas temporales: `/tmp/dragonex-oct25-final-desktop.png`,
  `/tmp/dragonex-oct25-final-mobile.png` y
  `/tmp/dragonex-oct25-mobile-inventory.png`.

### Caída y recuperación con navegador determinista

`MIX_ENV=test bin/dev test --include browser test/browser/death_save_journey_test.exs`
verifica Endpoint/LiveView/Game/SQL desde Chromium, con TestModel y dados
controlados: 0 PG, cierre prematuro rechazado, 20 natural → 1 PG, fallo después
del pago, recarga/reinicio, replay y Segundo aliento → 7 PG. Otra pausa/recarga
con segundo reinicio conserva dos eventos de dados y una voz humana, sin
repetir salvación ni curación. Resultado integrado: **1 passed, 3,9 s**, cero
errores JS; evidencia en
`/tmp/dragonex-browser-death-save-9aa8b1fd-4cc7-4237-b897-a3287f34ed25/`.

El escenario controlado arranca a 0 PG y no usa proveedor externo. La aventura
real y este recorrido se complementan; ninguno certifica todos los conjuros,
campañas largas ni fidelidad universal del texto generado. Gates y despliegue
vigentes en `../progress.md`.


## Préstamos y devoluciones sin saldo neto — D265 (2026-10-25)

Partida nueva `/games/19468`, «El sello prestado — D265», desde el navegador
con Bran Octubre y OpenRouter `deepseek/deepseek-v4-flash-0731`. No se altera
la historia de 19467. Tres declaraciones naturales verificadas:

1. Ada presta el sello para examinarlo y lo recibe inmediatamente: eventos
   **12/13**, mismo grupo, piernas 1/2, saldos **0 → 1 → 0** y contraparte Ada.
2. Bran presta su trofeo brevemente y lo recupera: eventos **22/23**, otro
   grupo, saldos **1 → 0 → 1**. El objeto conserva su pila inicial exacta.
3. Solicita el pergamino reservado, que Ada no presta: evento **31**, decisión
   `declined` y motivo; no crea ninguna transferencia del pergamino.

Chromium tras recarga a 1440×900 y 375×812 encuentra exactamente cuatro
movimientos y una negativa, con los saldos anteriores y Ada como contraparte;
sin errores JS ni desbordamiento horizontal. Evidencia temporal:
`/tmp/dragonex-d265-browser.json`, `/tmp/dragonex-d265-1440.png` y
`/tmp/dragonex-d265-375.png`. La mesa queda pausada, con inventario final igual
al inicial. Reintentos, reinicio, carrera de commit, rollback y recuperación
legacy se comprueban además en los tests deterministas D265.

Entrega verificada en producción: `ad903ca`, con **3303 passed / 4 excluded**
en [CI 40192812765](https://github.com/akorda-software/dragonex/actions/runs/40192812765)
y promoción automática a `production`. Dokploy completó el despliegue
`ON8twpDoY0GHFFfAJ0ccx` del mismo SHA (2026-10-25, 12:29 UTC). La web pública
responde HTTP 200, conecta LiveView y a 375×812 no presenta errores JS ni
desbordamiento; captura temporal `/tmp/dragonex-d265-production.png`.
Los logs recientes confirman el arranque del Endpoint sin entradas `[error]`.
La prueba con proveedor real descrita arriba se realizó en desarrollo;
esta comprobación pública valida la entrega y conexión de la aplicación.

Esto cierra el caso observado de préstamo y devolución inmediata. No convierte
prosa histórica en eventos inventados ni promete comprender cualquier frase
posible; las reglas nuevas verifican el episodio estructurado y su persistencia.
