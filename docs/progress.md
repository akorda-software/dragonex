# Dragonex — estado

Página corta y vigente: qué funciona, qué está abierto y cómo se mide. El
detalle histórico de entregas (D1–D237, playtests, gates por fecha) está en
[`progress-historial.md`](progress-historial.md); los porqués, en
[`decisions.md`](decisions.md).

**Convención:** una entrega nueva añade o actualiza **una línea** aquí (área,
qué cambia, `Dxxx`) y su detalle va al ADR. Si algo se abre o se cierra, se
mueve entre ✅/🟡/🔴. No se pegan aquí gates intermedios ni relatos de sesión.

## Último estado — 2026-10-25

- **Gates:** 3266 passed / 4 excluded en ambos grafos (local y Hex).
  Código propio sin warnings, formato limpio; dependencias frías conservan
  avisos de terceros documentados en `tecnico/09-estrategia-pruebas.md`.
- **Producción verificada:** `59b362e`, desplegado el 2026-10-25 tras
  [CI 40185544102](https://github.com/akorda-software/dragonex/actions/runs/40185544102)
  verde (3266/4) y promoción automática a `production`. Dokploy confirmó ese
  SHA; HTTP 200, LiveView conectado y móvil sin errores JS ni desbordamiento.
- **Dependencias:** dev usa `../exAgent` 2.2.2 y `../dic_ex` 0.3; el lock de
  producción adopta exAgent 2.2.2, ReqLLM 1.29.0 y Bandit 1.13.1. Ambos locks
  pasan `mix hex.audit` sin avisos (D246). Tanda D259–D264 validada local/Hex y
  navegador. [CI y promociones](https://github.com/akorda-software/dragonex/actions/workflows/ci.yml)
  registran el SHA probado que recibe Dokploy desde `production` (D262).
- **Medición:** `bin/dev dragonex.metrics --last 10` (partidas guardadas) y
  `bin/dev dragonex.playtest` (mesa real sin interfaz, gasta tokens) (D238).

| Medida (proveedor real) | Mesas del 4-oct (7) | Playtest 19455 (12-oct) | Tanda D239 19462–64 (12-oct) |
|---|---|---|---|
| Fallos por turno IA | 9,1 % | 0 % (2 reintentos TM recuperados) | 1,9 % (1 `narrate` vacío, reanudado) |
| Ida y vuelta humana p50 / p90 | 22 s / 42 s | 12 s / 52 s | 10 s / 22 s |
| Turno DM p50 | 13 s | 8 s | 7 s |
| Turno PC IA p50 | 7 s | 3 s | 3 s |
| Recogidas/entregas con stock al día | — | — | 4/5; la 5.ª era un plan y no cambiaba nada |

## ✅ Funciona

- **V1 jugable** (2026-09-26): cuenta, héroe, partida con DM real, combate,
  descanso, pausa/recarga y móvil verificados ([`producto/05`](producto/05-cierre-version-jugable.md)).
- **Motor 5e determinista:** ataques, daño y tipos, críticos, salvaciones,
  muerte/estabilización, condiciones → ventaja, concentración, iniciativa por
  criatura, presupuesto de acción/bonus/reacción, descansos y dados de golpe,
  reloj de efectos, inventario cuantificado. Rasgos de clase y raza de D35–D76,
  hechizos ejecutables (Bless, Heal, Shield of Faith, Sleep, Hold Person…) y
  upcasting curado (D74). El LLM no calcula resultados (D1).
- **Precisión de combate (D247):** Guiado respeta todas las fuentes de ventaja
  y desventaja y habilita furtivo cuando procede; Arma espiritual tira dados
  independientes en crítico y muestra daño mínimo cero.
- **Partida (`Game`):** single-writer (D6), persistencia y rehidratación,
  checkpoints y recibos que evitan repetir efectos al recuperar (D150–D164),
  fallo de turno → pausa con motivo y reanudación sin duplicar (D228).
- **Reintentos (D248):** una reacción conserva su turno y recursos principales;
  el corte por tokens no repone el presupuesto de fallos transitorios.
- **Recursos y replay (D255/D258):** Recuperación arcana revalida el plan al
  confirmar; aliases de armas equivalentes recuperan el ataque pagado y los
  recibos antiguos ambiguos piden su argumento exacto antes de tirar.
- **Descansos (D259/D264):** revalidan el cuerpo al confirmar; el DM agrupa
  participantes en un solo intervalo y no vuelve a sumar su duración.
- **Humano caído (D253):** debe resolver su salvación de muerte antes de
  cerrar el turno principal; 20 natural permite actuar y reiniciar no repite dados.
- **Inventario trazable (D261):** movimiento durable con objeto, cantidad,
  saldos y contraparte declarada; retry/restart no duplica. Entrega real a Ada
  comprobada; destinatario obligatorio nullable en la tool.
- **Agentes:** DM con narración estructurada (D222), PCs IA con voz propia,
  TurnMaster que orquesta relevos, intenciones humanas en cola, testimonios de
  PNJ con fuente durable, esperas y viajes con reloj, contexto de tiradas.
  Los PCs IA no actúan solos en exploración si no se les interpela (D32).
- **Creador de héroes y subida de nivel** (SRD 12 clases, golden L1/L3/L5;
  XP 5e D43), contenido custom por usuario.
- **Edición de héroes (D257):** conserva progreso, ASI, PG y gasto; previews
  no acumulan beneficios y una pestaña obsoleta no sobrescribe la ficha nueva.
- **Web:** mesa responsive 375–1440, dados 2D/3D, multijugador con sala de
  espera, home con crónica viva (D233).
- **Operaciones web (D249–D250/D256):** cancelar ajustes o quitar una clave
  impide aplicar comprobaciones tardías; borrar una mesa cierra sus agentes;
  nombres repetidos al crear muestran un error sin perder el formulario.
- **Playtest y métricas (D251–D252):** recuperación también en la última
  declaración; los relevos de emergencia no suman deliberación humana a la
  latencia IA y los retornos históricos ambiguos se excluyen.
- **Quién paga la IA (D242):** la casa solo paga DeepSeek v4.1 Flash, servido
  por Decart (D243; el más barato triplicaba la latencia). Con su propia clave (OpenRouter,
  OpenCode Go, OpenAI, Google, Anthropic; guardada cifrada en «Tu cuenta»),
  cada jugador elige cualquier modelo compatible en Ajustes de IA. La
  elección se guarda por partida y sobrevive a reinicios.
- **Retirada de claves (D260):** cancela peticiones, pausa mesas abiertas o
  dormidas y rota a la casa; comprobaciones antiguas no restauran la clave.
- **Validación web (D263):** aventura real 19467 en escritorio/móvil y fixture
  Chromium 0→1→7 PG con dos reinicios sin repetir dados/curación
  ([evidencia](producto/05-cierre-version-jugable.md#revalidación-del-2026-10-25-d259d264)).
- **CI (D262):** primer gate remoto verde; Dokploy sigue `production`, protegida
  por el check de pruebas. Solo una CI verde de master puede promoverla.
- **Acceso (D245):** Entrar y Crear cuenta en una ventana con pestañas y el
  wordmark; el registro pide repetir la contraseña y marca cada error en su
  campo; «Continuar con Google» (OIDC + PKCE) cuando hay cliente OAuth.
- **Bilingüe es/en por partida** (D235/D236).
- **exAgent 2.2.2 (D246):** conserva la retirada del modo de compatibilidad con 1.2
  (`Models.backend/0`, `Agent.LegacyHistory`, selector de razonamiento) (D237).

## 🟡 Abierto, por prioridad

1. **Betas con humanos en prod:** `https://dragones.kukapu.dev` (Dokploy,
   Oracle Madrid), repo `akorda-software/dragonex`, casa fija
   (`DRAGONEX_SERVER_MODELS=fixed`). El despliegue sigue `production` tras CI
   verde (D262). Recoger fallos de partidas reales con `dragonex.metrics`.
2. **Inventario de objetos de misión:** D239 exige comprobante de inventario
   antes de publicar el cierre del DM; en la tanda 19462–64 las 4 recogidas o
   entregas reales cambiaron el stock. D240 rechaza duplicados salvo
   `additional: true`; D261 registra movimientos y se comprobó en 19467.
   Sigue abierta la correspondencia semántica universal entre prosa y objeto,
   incluido préstamo/devolución transitorios sin cambio neto de stock.
3. **Fiabilidad del proveedor:** argumentos de tool inválidos (DM y TM),
   retención de 4 KiB (19447) y caídas. El `narrate` vacío de 19463 ya no
   tumba el turno (D240). Medir con `dragonex.playtest --games N`
   antes de corregir.
4. **Narración en vivo (R16, D234):** decidir el proveedor por defecto; Decart
   entrega los argumentos de golpe y fireworks sí los trocea.
5. **Latencia:** p90 de ida y vuelta humana ~50 s; los picos coinciden con
   beats del DM con varias tools.
6. **Prosa:** paráfrasis que repiten la voz humana, el DM añade gestos al PC,
   ataques narrados sin tirada (visto antes de D232; no reproducido en 19455).
7. **UI/UX de la mesa** (auditoría con capturas, 2026-10-12). Hecho: ficha
   completa propia en exploración, vista DM con todas las fichas, turnos de
   monstruo con su nombre, pausa con motivo y «Reanudar» junto a la entrada,
   casillas con máximo y sin traspasos de turno repetidos; las tiradas ajenas
   caen en una bandeja que no bloquea (modal solo para las tuyas); en móvil la
   iniciativa muestra bando, PG y caídos, el cajón abre el rastreador de
   combate sobre la crónica y la barra de controles avisa de que desplaza.
   Las tiradas muestran los PG que dejaron (D241) y las salvaciones de muerte
   de un PC caído se ven en el rastreador y en las fichas del grupo.
   En combate, la ficha y el aviso de turno marcan acción, adicional y
   reacción disponibles o gastadas (`TurnBudget.remaining/2`).
   Sobre la crónica, una franja plegable con la escena confirmada, el tiempo
   transcurrido y quién más está presente; el jugador tiene su ficha sola a
   la izquierda y a todos sus compañeros a la derecha. «cerrar sesión» ya no
   se confunde con «Salir» de la mesa, los botones desactivados son planos y
   legibles, el DM aparece como narrador en la sala de espera y la cabecera
   cabe a 375 px; la capitular de la crónica usa la letra legible de la
   portada.
8. **Limpieza intermitente de tests** (Postgrex/owner): en seguimiento, sin
   reaparecer en los gates de 2026-10-12.
9. **CI (D254):** workflow Hex offline preparado y validado localmente;
   falta publicar y observar el primer check remoto. No gobierna el autodeploy.

## 🟡 Simplificaciones v1 asumidas

| Ítem | Decisión | Ref |
|---|---|---|
| Dotes | Fuera; ASI = +2 fijo | D13 |
| `spells_known` | `nil` (sin cap estricto por clase) | D14 |
| Rasgos por nivel | Los de D35–D73 implementados; el resto sin mecánica | D35–D73 |
| Upcasting | Tabla curada (13 hechizos + Bless/Heal); el resto fuera | D74, D85, D87 |
| Rasgos raciales | Lucky, Resistencia implacable, Savage Attacks, Astucia gnoma, Resistencia enana, Aliento; Brave, Darkvision y demás sin mecánica | D66–D76 |
| Catálogo SRD | 319 hechizos en el creador; solo una parte ejecutable | — |
| Empate de iniciativa | DES y nombre; sin tirada extra | D39 |

## 🔴 Fuera de v1

- Multi-nodo (`Horde`), D24. Geometría táctica, multiclase, dotes, niveles
  altos certificados, campañas largas.

## Cómo se mide «hecho»

1. Tests deterministas (o smoke con `TestModel` si toca LLM).
2. `MIX_ENV=test bin/dev test` verde en local y, si cambian deps, en Hex.
3. Si toca el flujo con el modelo: `bin/dev dragonex.playtest` y comparar
   métricas con la tabla de arriba.
4. Decisión no trivial en `decisions.md`; una línea aquí.
