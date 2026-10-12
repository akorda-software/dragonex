# Mejoras post-V1 — primera tanda orquestada

Fecha: 2026-09-26. Estado: **implementado y verificado offline; revisión cruzada sin hallazgos bloqueantes**.

## Objetivo y alcance

Mejorar el recorrido ya verificado en `05-cierre-version-jugable.md` con dos
entregas acotadas. Referencia inicial: 1751 pruebas pasadas y 3 excluidas.

### P1 — Relevo forzado sin consulta redundante al TurnMaster

Responsable: GLM-5.3 **max**. Investigar y reutilizar las reglas de relevo
existentes; omitir la consulta únicamente cuando su resultado ya sería
sobrescrito por una decisión determinista equivalente en exploración.

- Probar con contador/spy de TestModel la llamada evitada.
- Conservar consulta en casos ambiguos, combate y mini-turns/reacciones.
- Respetar elegibilidad, intención pendiente, precedencia entre humanos,
  pausa, persistencia y guardas contra bucles.
- No certificar segundos ahorrados sin medición real nueva.

Área exclusiva: `game.ex`, `game/{turnmaster,settlement,beats}.ex`,
`turn_master_loop_test.exs`, `turnmaster_fast_path_test.exs`.

### P2 — Contexto narrativo fiel al estado efectivo

Responsable: Grok 4.7 **high**. El brief debe presentar las reglas ya resueltas:
CA efectiva, PG temporales separados, estabilidad a 0 PG e identidad canónica.

- CA base 18 + Shield of Faith da 20 en el brief, sin mutar la ficha base.
- Fin/caducidad del efecto vuelve a mostrar 18.
- PG temporales no se suman a PG normales ni a máximos.
- Distinguir estable, caído pendiente de salvaciones y muerto.
- Mantener clase/raza/nivel y tolerar datos opcionales ausentes en NPC.
- Reutilizar APIs del motor; ninguna regla paralela dentro del presenter.
- Las instrucciones al narrador no se consideran garantía contra alucinaciones.

Área exclusiva: `brief.ex`, `dm.ex`, `pc_agent.ex`, pruebas de brief/contexto
narrativo. No modificar reglas ni estructuras persistentes.

## Protocolo de entrega

- Ambos agentes conservan el WIP previo y tienen prohibido editar archivos
  ajenos. Cambios de ownership se consultan al coordinador.
- Los workers implementan y preparan pruebas; anuncian `EDITS_DONE` antes
  de compilar/probar. El coordinador serializa los gates del checkout compartido.
- Gate: revisión de cambios, pruebas focalizadas, suite completa
  `MIX_ENV=test mix test`, `mix compile --warnings-as-errors`,
  `mix format --check-formatted` y `git diff --check`.
- Sin commits, instalaciones, despliegues, reinicios ni inferencia real de prueba.

## Evidencia

Modelos/esfuerzos comprobados en las
sesiones OpenCode antes del Dispatch: GLM-5.3 Z.AI Coding Plan / max;
Grok 4.7 xAI / high. Detalles recuperables del Run en `ORCA_CHECKPOINT.md`.

- P1 entregado: 11 pruebas en `turnmaster_fast_path_test.exs`, con contador de
  invocaciones del modelo y casos de pausa/intents/mini-turns. Cambio limitado a
  `Game.advance` y helpers de `Game.Turnmaster`; preserva WIP previo.
- P2 entregado: 14 pruebas en `brief_effective_state_test.exs`,
  `dm_narrative_context_test.exs`, `pc_agent_narrative_context_test.exs`;
  tres expectativas actualizadas en `dm_test.exs` con ownership autorizado.
- Gate focalizado de los dos bloques y compatibilidad: **71/71**.
- Suite completa independiente del coordinador: **1776 passed / 3 excluded**,
  log `/tmp/opencode/dragonex-post-v1-full.log`. Compile con warnings-as-errors,
  formato y diff correctos. Advertencias de tests ya presentes en el log de V1.
- Detectados y corregidos durante integración: aridad de traducción de raza,
  guardas explícitas de interrupción del DM, assertions del tipo `Part.System`
  y fixture de reacción que consumía un guion compartido incorrecto.
- Decisiones documentadas: D93 (relevo forzado) y D94 (brief factual).
- Revisión cruzada de solo lectura: Grok revisó el relevo de GLM y GLM el
  brief de Grok, sin defectos bloqueantes. Límite de cobertura: la exclusión
  del mini-turn del DM al finalizar combate se prueba por sus flags, no con
  otro escenario integrado de transición. Incidencia administrativa del
  cierre de un Dispatch registrada en `ORCA_CHECKPOINT.md`.
- Sin nueva prueba live: ni reducción de segundos ni eliminación de
  inconsistencias narrativas certificadas. Sí se verifica la llamada evitada
  y el contenido factual entregado a los agentes.
