# Dragonex — estado

Página corta y vigente: qué funciona, qué está abierto y cómo se mide. El
detalle de cada entrega (D1–D237, playtests, gates por fecha) está en
[`progress-historial.md`](progress-historial.md); los porqués, en
[`decisions.md`](decisions.md).

**Convención:** una entrega nueva añade o actualiza **una línea** aquí (área,
qué cambia, `Dxxx`) y su detalle va al ADR. Si algo se abre o se cierra, se
mueve entre ✅/🟡/🔴. No se pegan aquí gates intermedios ni relatos de sesión.

## Último estado — 2026-10-12

- **Gates:** 3073 passed / 3 excluded en local (Hex: 3071 en el commit
  anterior, sin cambio de deps),
  `--warnings-as-errors` limpio, formato limpio.
- **Dependencias:** dev usa `../exAgent` 2.1 y `../dic_ex` 0.3; prod, las
  mismas versiones de Hex (D237). **Sin desplegar** desde ese cambio.
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
- **Partida (`Game`):** single-writer (D6), persistencia y rehidratación,
  checkpoints y recibos que evitan repetir efectos al recuperar (D150–D164),
  fallo de turno → pausa con motivo y reanudación sin duplicar (D228).
- **Agentes:** DM con narración estructurada (D222), PCs IA con voz propia,
  TurnMaster que orquesta relevos, intenciones humanas en cola, testimonios de
  PNJ con fuente durable, esperas y viajes con reloj, contexto de tiradas.
  Los PCs IA no actúan solos en exploración si no se les interpela (D32).
- **Creador de héroes y subida de nivel** (SRD 12 clases, golden L1/L3/L5;
  XP 5e D43), contenido custom por usuario.
- **Web:** mesa responsive 375–1440, dados 2D/3D, multijugador con sala de
  espera, ajustes de proveedor/modelo, home con crónica viva (D233).
- **Bilingüe es/en por partida** (D235/D236).
- **Solo exAgent 2.1:** retirado el modo de compatibilidad con 1.2
  (`Models.backend/0`, `Agent.LegacyHistory`, selector de razonamiento) (D237).

## 🟡 Abierto, por prioridad

1. **Desplegar prod con D237** (exAgent 2.1 / dic_ex 0.3). Necesita
   confirmación del usuario.
2. **Inventario de objetos de misión:** D239 exige comprobante de inventario
   antes de publicar el cierre del DM; en la tanda 19462–64 las 4 recogidas o
   entregas reales cambiaron el stock. D240 rechaza conceder otra vez un
   objeto ya poseído salvo `additional: true`. Falta medirlo en vivo.
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
   Pendiente: franja de escena/hora/PNJ.
8. **Limpieza intermitente de tests** (Postgrex/owner): en seguimiento, sin
   reaparecer en los gates de 2026-10-12.

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
