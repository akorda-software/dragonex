# Mapa catálogo → ejecutable (SRD 5.1)

> Nota (coordinador, 2026-09-26): las citas `actions.ex:NNNN` de este mapa se
> tomaron sobre el árbol antes de D96 y derivan con cada lote — las caras
> semánticas siguen válidas; localiza los sitios por nombre de función si la
> línea ya no cuadra. Verificado por muestreo en la revisión cruzada de la
> oleada C. Los borradores de hold person y faerie fire se implementan en D97
> con un requisito extra detectado en revisión: extender la limpieza por
> fuente (`without_source`) más allá de bless/shield_of_faith.

Fecha: 2026-09-26. Alcance: los 319 hechizos de `priv/srd/spells.es.json`,
clasificados contra lo que `cast_spell` resuelve hoy. No implementa nada.
El catálogo efectivo es builtin (`heroes/spells.ex:120`, 45 entradas) encima
del JSON: `overlay_catalog` (`actions.ex:3694`) rellena dados, salvación y
tipo; el `kind` de la ficha sale del mismo merge.

## 1. Resumen

| Categoría | N | Criterio |
|---|---:|---|
| EJECUTABLE | 28 | El efecto principal (daño, cura, +CA, +1d4, estabilizar, quitar condición, marca guided) lo aplica el motor |
| PARCIAL | 47 | Hay dados o una rama, pero falta escalado, duración recurrente, efecto secundario o el modelo es de un solo objetivo cuando el hechizo es un área que se repite |
| DESCRIPTIVO | 244 | Narración (`noop`, `actions.ex:2541`) o una tirada que no impone la condición. Tener `dice` en el JSON no basta |

| Nivel | Ejecutables | Parciales | Descriptivos | Total |
|---:|---:|---:|---:|---:|
| 0 | 7 | 4 | 13 | 24 |
| 1 | 7 | 5 | 37 | 49 |
| 2 | 2 | 9 | 43 | 54 |
| 3 | 2 | 5 | 35 | 42 |
| 4 | 1 | 5 | 25 | 31 |
| 5 | 2 | 5 | 30 | 37 |
| 6 | 3 | 7 | 21 | 31 |
| 7 | 2 | 2 | 16 | 20 |
| 8 | 1 | 3 | 12 | 16 |
| 9 | 1 | 2 | 12 | 15 |

Ejecutables (28): acid splash, eldritch blast, fire bolt, poison spray, produce flame, sacred flame, spare the dying, bless, burning hands, cure wounds, false life, healing word, magic missile, shield of faith, lesser restoration, shatter, fireball, lightning bolt, blight, cone of cold, flame strike, circle of death, freezing sphere, heal, fire storm, prismatic spray, sunburst, meteor swarm.

Trampas (no son el hechizo aunque el catálogo tenga dados o `kind`):

- **sleep** no duerme. El builtin pone `5d8` sin tipo (`spells.ex:375`) y la rama automatic lo **cura** (`actions.ex:2503`).
- **charm person, hold person, bane, entangle, haste, web** y el resto de `kind` save/attack sin dados no aplican charmed, paralyzed ni restrained. La salvación, si llega a tirarse, aplica 0 de daño (`actions.ex:2964`).
- **shield** (el truco de reacción, +5 CA) no es **shield of faith**. El primero es descriptivo. El segundo sí suma +2 a la CA efectiva.
- **hunter's mark** por `cast_spell` no suma +1d6. Esa suma está en la tool `hunters_mark` (`tools.ex:574`), fuera de la rama de conjuro.
- **inflict wounds** y **spike growth** tienen dados en el JSON con `kind` automatic: el motor pegaría un daño único sin ataque ni terreno.
- **forbiddance** (5d10) y **teleport** (3d10) también caerían en daño automático. No son ese hechizo: el primero es un sello, el segundo una tabla de percance. Quedan descriptivos a propósito.
- Área, alcance, cobertura y línea de visión no existen. Un fireball ejecutable sigue siendo un solo objetivo. Eso no baja la categoría si el daño y la salvación sí se resuelven; sí la baja si el hechizo *es* el muro, la nube o el daño cada turno.

Ramas, en orden (`actions.ex:399`):

1. Nombre propio: false life, bless, shield of faith, spare the dying, lesser restoration, heal.
2. `:automatic` con dados y sin tipo → cura (`actions.ex:2503`).
3. `:automatic` con dados y tipo → daño sin tirada (`actions.ex:2519`).
4. `:automatic` sin dados → texto y `noop` (`actions.ex:2541`).
5. `:attack` → d20 vs CA y daño (`actions.ex:2550`). Guiding bolt añade la marca (`actions.ex:3718`).
6. `:save` → salvación, daño completo o mitad (`actions.ex:2771`).
7. Si `Spells.concentration?/1` es true, se guarda el nombre en `concentrating` (`actions.ex:3315`). Eso no crea el efecto.

Escalado de casilla solo en `rules/upcast.ex:38` (13 hechizos). Escalado de trucos solo en `rules/cantrips.ex:23` (10 trucos; eldritch blast suma dados, no rayos). El JSON no trae el bloque «a niveles superiores», así que un ejecutable ausente de esa tabla no escala: no se ha inventado la fila.

## 2. Tabla

| Nv | Clave | Cat | Rama | Qué hace hoy |
|---:|---|---|---|---|
| 0 | acid splash | EJECUTABLE | save 1d6 | kind save + 1d6 acid; escala con el nivel del lanzador (cantrips.ex:23); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 0 | chill touch | PARCIAL | attack 1d8 | daño necrótico sí; falta impedir curación y desventaja contra el lanzador si el objetivo es no-muerto |
| 0 | dancing lights | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | druidcraft | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | eldritch blast | EJECUTABLE | attack 1d10 | kind attack + 1d10 force; escala con el nivel del lanzador (cantrips.ex:23); un objetivo; sin área ni cobertura; attack actions.ex:2550 |
| 0 | fire bolt | EJECUTABLE | attack 1d10 | kind attack + 1d10 fire; escala con el nivel del lanzador (cantrips.ex:23); un objetivo; sin área ni cobertura; attack actions.ex:2550 |
| 0 | guidance | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | light | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 0 | mage hand | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | mending | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | message | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | minor illusion | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | poison spray | EJECUTABLE | save 1d12 | kind save + 1d12 poison; escala con el nivel del lanzador (cantrips.ex:23); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 0 | prestidigitation | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | produce flame | EJECUTABLE | attack 1d8 | kind attack + 1d8 fire; escala con el nivel del lanzador (cantrips.ex:23); un objetivo; sin área ni cobertura; attack actions.ex:2550 |
| 0 | ray of frost | PARCIAL | attack 1d8 | daño frío sí; falta −10 pies de velocidad |
| 0 | resistance | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | sacred flame | EJECUTABLE | save 1d8 | kind save + 1d8 radiant; escala con el nivel del lanzador (cantrips.ex:23); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 0 | shillelagh | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | shocking grasp | PARCIAL | attack 1d8 | 1d8 sí; falta impedir reacciones hasta su siguiente turno |
| 0 | spare the dying | EJECUTABLE | automatic  | caso spare the dying actions.ex:423; estabiliza; rechaza no-muerto y constructo |
| 0 | thaumaturgy | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | true strike | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 0 | vicious mockery | PARCIAL | save 1d4 | 1d4 psíquico sí (builtin spells.ex:164); falta desventaja en el siguiente ataque |
| 1 | alarm | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | animal friendship | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | bane | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | bless | EJECUTABLE | automatic  | caso bless actions.ex:405 → World.bless; +1d4, concentración 1 min, upcast de objetivos |
| 1 | burning hands | EJECUTABLE | save 3d6 | kind save + 3d6 fire; escala por casilla (upcast.ex:38); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 1 | charm person | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | color spray | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | command | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | comprehend languages | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | create or destroy water | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | cure wounds | EJECUTABLE | automatic 1d8 | automatic + 1d8 sin tipo → cura dados+mod (actions.ex:2503); escala D74 |
| 1 | detect evil and good | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | detect magic | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | detect poison and disease | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | disguise self | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | divine favor | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | entangle | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | expeditious retreat | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | faerie fire | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | false life | EJECUTABLE | automatic  | caso false life actions.ex:402 y :2462; 1d4+4 temporales, +5/nivel, plazo 1 h |
| 1 | feather fall | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | find familiar | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | floating disk | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | fog cloud | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | goodberry | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | grease | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | guiding bolt | PARCIAL | attack 4d6 | 4d6 radiante y marca guided al impactar (actions.ex:3718); falta +1d6 por nivel (ausente de upcast.ex:38) |
| 1 | healing word | EJECUTABLE | automatic 1d4 | automatic + 1d4 sin tipo → cura dados+mod (actions.ex:2503); escala D74 |
| 1 | hellish rebuke | PARCIAL | save 2d10 | 2d10 + salvación DES sí; falta el disparador al recibir daño y +1d10/nivel |
| 1 | heroism | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | hideous laughter | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | hunter's mark | PARCIAL | automatic  | cast_spell no suma +1d6; la mecánica vive en la tool hunters_mark (tools.ex:574, D55) |
| 1 | identify | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | illusory script | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | inflict wounds | PARCIAL | automatic 3d10 | 3d10 necrótico automático (kind automatic del JSON); falta la tirada de ataque y +1d10/nivel |
| 1 | jump | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | longstrider | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | mage armor | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | magic missile | EJECUTABLE | automatic 3d4+3 | automatic + 3d4+3 force → daño sin tirada (actions.ex:2519) |
| 1 | protection from evil and good | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | purify food and drink | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | sanctuary | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 1 | shield | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | shield of faith | EJECUTABLE | automatic  | caso shield of faith actions.ex:412 → World.shield_of_faith; +2 CA, 10 min, concentración |
| 1 | silent image | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | sleep | DESCRIPTIVO | automatic 5d8 | TRAMPA: builtin 5d8 sin tipo (spells.ex:375) entra en la rama de CURACIÓN actions.ex:2503. El pool de sueño no existe |
| 1 | speak with animals | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 1 | thunderwave | PARCIAL | save 2d8 | 2d8 + salvación CON + escalado D74; falta empujón de 10 pies (no hay grid) |
| 1 | unseen servant | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | acid arrow | PARCIAL | attack 4d4 | 4d4 al impactar; falta 2d4 al final del turno siguiente |
| 2 | aid | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | alter self | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | animal messenger | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | arcane lock | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | arcanist's magic aura | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | augury | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | barkskin | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | blindness/deafness | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | blur | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | branding smite | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | calm emotions | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | continual flame | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | darkness | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | darkvision | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | detect thoughts | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | enhance ability | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | enlarge/reduce | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | enthrall | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | find steed | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | find traps | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | flame blade | PARCIAL | attack 3d6 | un ataque 3d6; falta el arma convocada y repetir el ataque |
| 2 | flaming sphere | PARCIAL | save 2d6 | un disparo 2d6 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 2 | gentle repose | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | gust of wind | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | heat metal | PARCIAL | save 2d8 | un disparo 2d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 2 | hold person | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | invisibility | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | knock | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | lesser restoration | EJECUTABLE | automatic  | caso lesser restoration actions.ex:430; quita blinded, deafened, paralyzed, poisoned o diseased |
| 2 | levitate | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | locate animals or plants | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | locate object | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | magic mouth | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | magic weapon | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | mirror image | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | misty step | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | moonbeam | PARCIAL | save 2d10 | un disparo 2d10 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 2 | pass without trace | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | prayer of healing | PARCIAL | automatic 2d8 | cura 2d8+mod a un objetivo y escala; RAW cura hasta 6 criaturas |
| 2 | protection from poison | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | ray of enfeeblement | DESCRIPTIVO | attack  | kind attack sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | rope trick | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | scorching ray | PARCIAL | attack 2d6 | un solo ataque de 2d6; RAW son 3 rayos y +1 rayo por nivel |
| 2 | see invisibility | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | shatter | EJECUTABLE | save 3d8 | kind save + 3d8 thunder; escala por casilla (upcast.ex:38); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 2 | silence | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | spider climb | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | spike growth | PARCIAL | automatic 2d4 | kind automatic + 2d4: un daño único, no terreno difícil ni 2d4 por cada 5 pies |
| 2 | spiritual weapon | PARCIAL | attack 1d8 | un ataque 1d8 force + escalado cada 2 niveles (upcast.ex:47); falta el arma persistente de acción adicional durante 1 minuto. RAW no es concentración |
| 2 | suggestion | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | warding bond | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 2 | web | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 2 | zone of truth | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | animate dead | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | beacon of hope | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | bestow curse | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | blink | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | call lightning | PARCIAL | save 3d10 | un disparo 3d10 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (10 minutes) |
| 3 | clairvoyance | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | conjure animals | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | counterspell | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | create food and water | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | daylight | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | dispel magic | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | fear | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | fireball | EJECUTABLE | save 8d6 | kind save + 8d6 fire; escala por casilla (upcast.ex:38); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 3 | fly | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | gaseous form | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | glyph of warding | PARCIAL | save 5d8 | un 5d8 no prepara el glifo ni la runa explosiva |
| 3 | haste | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | hypnotic pattern | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | lightning bolt | EJECUTABLE | save 8d6 | kind save + 8d6 lightning; escala por casilla (upcast.ex:38); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 3 | magic circle | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | major image | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | mass healing word | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | meld into stone | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | nondetection | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | phantom steed | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | plant growth | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | protection from energy | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | remove curse | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | revivify | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | sending | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | sleet storm | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | slow | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | speak with dead | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | speak with plants | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | spirit guardians | PARCIAL | save 3d8 | un disparo 3d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (10 minutes) |
| 3 | stinking cloud | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 3 | tiny hut | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | tongues | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | vampiric touch | PARCIAL | attack 3d6 | 3d6 necrótico + escalado; falta curar la mitad y repetir el ataque |
| 3 | water breathing | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | water walk | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 3 | wind wall | PARCIAL | save 3d8 | un disparo 3d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 4 | arcane eye | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | banishment | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 4 | black tentacles | PARCIAL | save 3d6 | un disparo 3d6 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 4 | blight | EJECUTABLE | save 8d8 | kind save + 8d8 necrotic; escala por casilla (upcast.ex:38); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 4 | compulsion | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 4 | confusion | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 4 | conjure minor elementals | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | conjure woodland beings | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | control water | PARCIAL | save 2d8 | el 2d8 no controla el agua |
| 4 | death ward | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | dimension door | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | divination | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | dominate beast | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 4 | fabricate | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | faithful hound | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | fire shield | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | freedom of movement | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | giant insect | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | greater invisibility | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | guardian of faith | PARCIAL | save 20 | dice «20» no es el guardián de 20 pg por proximidad |
| 4 | hallucinatory terrain | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | ice storm | PARCIAL | save 2d8 | un 2d8; RAW es 2d8 contundente + 4d6 frío y terreno difícil |
| 4 | locate creature | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | phantasmal killer | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 4 | polymorph | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 4 | private sanctum | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | resilient sphere | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 4 | secret chest | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | stone shape | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | stoneskin | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 4 | wall of fire | PARCIAL | save 5d8 | un disparo 5d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 5 | animate objects | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | antilife shell | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | arcane hand | PARCIAL | attack 4d8 | un 4d8; faltan las opciones de la mano |
| 5 | awaken | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | cloudkill | PARCIAL | save 5d8 | un disparo 5d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (10 minutes) |
| 5 | commune | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | commune with nature | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | cone of cold | EJECUTABLE | save 8d8 | kind save + 8d8 cold; sin fila en Upcast; el JSON no trae el bloque de niveles superiores; un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 5 | conjure elemental | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | contact other plane | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | contagion | DESCRIPTIVO | attack  | kind attack sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | creation | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | dispel evil and good | DESCRIPTIVO | attack  | kind attack sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | dominate person | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | dream | PARCIAL | save 3d6 | el 3d6 no es el mensajero onírico |
| 5 | flame strike | EJECUTABLE | save 4d6 | kind save + 4d6 fire; escala por casilla (upcast.ex:38); un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 5 | geas | PARCIAL | save 5d10 | el 5d10 psíquico no impone la orden |
| 5 | greater restoration | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | hallow | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | hold monster | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | insect plague | PARCIAL | save 4d10 | un disparo 4d10 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (10 minutes) |
| 5 | legend lore | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | mass cure wounds | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | mislead | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | modify memory | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | passwall | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | planar binding | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | raise dead | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | reincarnate | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | scrying | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | seeming | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 5 | telekinesis | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | telepathic bond | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | teleportation circle | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | tree stride | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | wall of force | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 5 | wall of stone | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 6 | blade barrier | PARCIAL | save 6d10 | un disparo 6d10 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (10 minutes) |
| 6 | chain lightning | PARCIAL | save 10d8 | un objetivo; RAW salta a tres objetivos más |
| 6 | circle of death | EJECUTABLE | save 8d6 | kind save + 8d6 necrotic; sin fila en Upcast; el JSON no trae el bloque de niveles superiores; un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 6 | conjure fey | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | contingency | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | create undead | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | disintegrate | PARCIAL | save 10d6+40 | 10d6+40 sí; falta desintegrar si queda a 0 |
| 6 | eyebite | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 6 | find the path | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | flesh to stone | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 6 | forbiddance | DESCRIPTIVO | automatic 5d10 | TRAMPA: el 5d10 necrótico no es el sello; la rama automatic (actions.ex:2519) pegaría un daño único |
| 6 | freezing sphere | EJECUTABLE | save 10d6 | kind save + 10d6 cold; sin fila en Upcast; el JSON no trae el bloque de niveles superiores; un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 6 | globe of invulnerability | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | guards and wards | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | harm | PARCIAL | save 14d6 | 14d6 necrótico sí; falta reducir el máximo de PG |
| 6 | heal | EJECUTABLE | automatic  | caso heal actions.ex:442; 70 PG +10 por nivel y quita blinded, deafened y diseased |
| 6 | heroes' feast | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 6 | instant summons | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | irresistible dance | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 6 | magic jar | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 6 | mass suggestion | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 6 | move earth | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | planar ally | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | programmed illusion | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | sunbeam | PARCIAL | save 6d8 | un disparo 6d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 6 | transport via plants | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | true seeing | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | wall of ice | PARCIAL | save 10d6 | un disparo 10d6 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (10 minutes) |
| 6 | wall of thorns | PARCIAL | save 7d8 | un disparo 7d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (10 minutes) |
| 6 | wind walk | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 6 | word of recall | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | arcane sword | PARCIAL | attack 3d10 | un 3d10; falta el arma persistente |
| 7 | conjure celestial | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | delayed blast fireball | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 7 | divine word | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 7 | etherealness | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | finger of death | PARCIAL | save 7d8+30 | 7d8+30 sí; falta el zombi si el humanoide muere |
| 7 | fire storm | EJECUTABLE | save 7d10 | kind save + 7d10 fire; sin fila en Upcast; el JSON no trae el bloque de niveles superiores; un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 7 | forcecage | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 7 | magnificent mansion | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | mirage arcane | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | plane shift | DESCRIPTIVO | attack  | kind attack sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 7 | prismatic spray | EJECUTABLE | save 10d6 | kind save + 10d6 fire; sin fila en Upcast; el JSON no trae el bloque de niveles superiores; un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 7 | project image | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | regenerate | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | resurrection | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | reverse gravity | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 7 | sequester | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | simulacrum | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 7 | symbol | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 7 | teleport | DESCRIPTIVO | automatic 3d10 | TRAMPA: el 3d10 de fuerza es la tabla de percance, no un ataque; la rama automatic pegaría daño al objetivo |
| 8 | animal shapes | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | antimagic field | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | antipathy/sympathy | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 8 | clone | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | control weather | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | demiplane | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | dominate monster | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 8 | earthquake | PARCIAL | save 5d6 | un disparo 5d6 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 8 | feeblemind | PARCIAL | save 4d6 | 4d6 psíquico sí; falta dejar INT y CAR en 1 |
| 8 | glibness | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | holy aura | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 8 | incendiary cloud | PARCIAL | save 10d8 | un disparo 10d8 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 8 | maze | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | mind blank | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 8 | power word stun | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 8 | sunburst | EJECUTABLE | save 12d6 | kind save + 12d6 radiant; sin fila en Upcast; el JSON no trae el bloque de niveles superiores; un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 9 | astral projection | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 9 | foresight | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 9 | gate | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 9 | imprisonment | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 9 | mass heal | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 9 | meteor swarm | EJECUTABLE | save 20d6 | kind save + 20d6 fire; sin fila en Upcast; el JSON no trae el bloque de niveles superiores; un objetivo; sin área ni cobertura; save actions.ex:2771 |
| 9 | power word kill | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 9 | prismatic wall | PARCIAL | save 10d6 | un 10d6 no es el muro de 10 minutos ni sus capas; un solo objetivo |
| 9 | shapechange | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 9 | storm of vengeance | PARCIAL | save 2d6 | un disparo 2d6 por kind save; actions.ex:3315 solo marca concentración, no repite el efecto (1 minute) |
| 9 | time stop | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 9 | true polymorph | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 9 | true resurrection | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |
| 9 | weird | DESCRIPTIVO | save  | kind save sin dados: la salvación o el ataque no imponen la condición; dice nil aplica 0 (actions.ex:2964) |
| 9 | wish | DESCRIPTIVO | automatic  | automatic sin dados → noop narrativo (actions.ex:2541); sin rama propia |

## 3. Diez siguientes (nivel 1–3, mesa real)

No están aquí los que ya resuelven el efecto (cure wounds, healing word, bless, shield of faith, false life, magic missile, burning hands, fireball, lightning bolt). Hunter's mark ya tiene tool; unificarla con `cast_spell` es deuda, no el siguiente hueco.

### 1. shield (nivel 1, reacción, +5 CA)

Falta el +5 hasta el inicio del siguiente turno, incluso contra el ataque que lo dispara, y la inmunidad a *magic missile*. Hoy: noop.

Modelo: postura booleana al estilo de Divine Smite (D46) y Esquiva asombrosa (D64), leída por `Rules.Effects.effective_ac/1` (+5, no muta `c.ac`). Caduca en `set_current_combatant` del lanzador (inicio de su turno). Coste de reacción vía `TurnBudget` (el JSON ya dice reaction). *Magic missile* contra un objetivo con la postura aplica 0.

Borrador: Shield es una postura de reacción, no un cambio de ficha. +5 CA hasta el inicio del turno del lanzador. No se acumula consigo misma. Magic missile no hace daño mientras está activa. Sin grid: vale contra cualquier ataque, no solo el desencadenante si el motor no puede nombrar «el ataque que lo disparó»; el primer ataque resuelto contra el lanzador en esa ventana es el desencadenante.

Oráculo: +5 CA; duración hasta el inicio del siguiente turno del lanzador; 0 daño de magic missile; casilla de nivel 1, sin escalado.

### 2. mage armor (nivel 1, 8 horas, sin concentración)

Falta sustituir la CA base por 13 + DES si no lleva armadura. Hoy: noop.

Modelo: condición `mage_armor` con plazo 8 h (`WorldClock.track`, 28800 s), no concentración. `effective_ac` usa `max(c.ac, 13 + mod DES)` solo si el inventario no tiene armadura (`kind: :armor`). Disipar es `remove_condition` o ponerse armadura.

Borrador: Mage Armor no toca `c.ac`. La CA efectiva es 13+DES mientras la condición viva y no haya armadura. 8 horas de reloj, sin concentración. Termina si el objetivo se equipa una armadura.

Oráculo: CA 13 + modificador de Destreza; 8 horas; sin concentración; termina al vestir armadura.

### 3. sleep (nivel 1) — y dejar de curar

Falta el pool de PG. Hoy el builtin lo manda a la rama de cura (`actions.ex:2503`). Hay que excluirlo de esa rama antes de modelarlo.

Modelo: tirar `5d8` (+2d8 por nivel de casilla, fila nueva en `Upcast`). Ordenar criaturas vivas del lado enemigo por PG actuales (sin grid: todos los enemigos conscientes, documentado). Aplicar `unconscious` con `apply_condition` hasta agotar el pool. Plazo 1 minuto (60 s) o 10 rondas; el daño ya despierta porque `apply_damage` no quita unconscious — habría que quitarlo al recibir daño, como el hidden se quita al atacar.

Borrador: Sleep no cura. Un pool de 5d8 (+2d8/nivel) deja inconscientes a enemigos vivos de menor a mayor PG hasta agotar el pool. Duración 1 minuto. El daño despierta. Sin área de 20 pies hasta que exista grid.

Oráculo: 5d8 al nivel 1; +2d8 por nivel superior; ignora inconscientes; orden ascendente de PG actuales; 1 minuto; el daño termina el efecto.

### 4. hold person (nivel 2, concentración)

Falta paralyzed. Hoy una salvación de Sabiduría sin dados no impone nada, aunque `compose_concentration` guarde el nombre.

Modelo: salvación de SAB; fallo → `apply_condition(objetivo, "paralyzed")` con fuente, bajo la concentración del lanzador (`clear_sourced_effects` al soltarla, patrón Bless D85). Al empezar el turno del objetivo (`set_current_combatant`), repetir la salvación; éxito quita paralyzed. Raza humanoid; si el JSON no trae tipo de criatura, aceptar humanoide por `race` o documentar «cualquier criatura» como simplificación. Upcast +1 objetivo queda fuera, como hold person en D74.

Borrador: Hold Person impone paralyzed si falla SAB, solo mientras el lanzador concentra. Salvación nueva al inicio del turno del objetivo. Soltar concentración limpia el paralyzed de esa fuente. Sin radio ni «que puedas ver».

Oráculo: salvación de Sabiduría; paralyzed; repetición al final de cada turno del objetivo (aquí: inicio de su turno, mismo cuello que D44); concentración 1 minuto; humanoide.

### 5. haste (nivel 3, concentración)

El JSON lo marca `kind: save` sin dados. No concede prisa: o no hace nada útil o tira una salvación de 0.

Modelo: aliado voluntario. Mientras concentra el lanzador: +2 en `effective_ac`, ventaja en salvaciones de DES (`Conditions.save_mode`), y un ataque de arma extra por turno (flag en `TurnBudget`, no una acción completa). Al romperse, el objetivo pierde su siguiente turno (no renovar presupuesto, o `ended: true`). Velocidad doble: no hay grid; no se modela. 1 minuto.

Borrador: Haste es una condición de concentración sobre un aliado. +2 CA, ventaja en DES, un ataque de arma extra por turno. Al caer la concentración, el objetivo no actúa en su siguiente turno. La velocidad no se modela.

Oráculo: +2 CA; ventaja en salvaciones de Destreza; una acción extra limitada a un ataque de arma; 1 minuto, concentración; letargo al terminar.

### 6. spirit guardians (nivel 3, concentración)

Hoy un 3d8 radiante de un solo disparo (`kind` save + dice) y el flag de concentración. No es el aura.

Modelo: al empezar el turno del lanzador, cada enemigo vivo (otro `side`, sin grid: todos, como el aura de paladín D62) tira SAB. Fallo 3d8, éxito mitad. Tipo radiante por defecto (el clérigo no elige bueno/maligno en la ficha). +1d8 por nivel en `Upcast`. Velocidad a la mitad: no hay grid, queda fuera. Designar inmunes: lista corta en la tool o «aliados del mismo side» por defecto.

Borrador: Spirit Guardians no es un proyectil. Cada inicio de turno del lanzador, los enemigos vivos tiran SAB contra 3d8 (mitad si superan), mientras concentre. Sin radio de 15 pies. Upcast +1d8/nivel.

Oráculo: 3d8 radiante o necrótico; salvación de Sabiduría, mitad; radio 15 pies (aquí: todos los enemigos); 10 minutos, concentración; +1d8 por nivel superior.

### 7. faerie fire (nivel 1, concentración)

Falta la ventaja en ataques contra el objetivo. La salvación de Destreza sin dados no ilumina a nadie.

Modelo: salvación de DES; fallo → condición `faerie_fire` con fuente. `Conditions.attack_mode` da ventaja contra quien la tenga (mismo gancho que `hidden`, al revés). Concentración del lanzador limpia la condición. 1 minuto. Sin cubo de 20 pies: un objetivo, upcast de objetivos fuera hasta que Bless-like `additional_targets` se generalice.

Borrador: Faerie Fire es una condición de concentración. Quien falle DES concede ventaja en ataques contra él durante 1 minuto. Sin área. La luz tenue no se modela.

Oráculo: salvación de Destreza; ventaja en tiradas de ataque contra el afectado; 1 minuto, concentración; cubo de 20 pies (aquí: un objetivo).

### 8. spiritual weapon (nivel 2, sin concentración)

Hoy un ataque de 1d8 force y el escalado cada dos niveles. No queda un arma para la acción adicional de los turnos siguientes. El JSON dice `concentration: false` (correcto en 2014).

Modelo: ficha de postura en el lanzador (`spiritual_weapon: %{dice, mod, rounds_left}`), no concentración. El primer ataque sale al lanzar (ya existe). En turnos posteriores, una tool de acción adicional repite el ataque cuerpo a cuerpo (1d8 + mod de lanzamiento, force) mientras no hayan pasado 10 rondas (1 minuto) o se vuelva a lanzar. El escalado de `Upcast` se conserva.

Borrador: Spiritual Weapon no concentra. Persiste 1 minuto como postura del lanzador. Acción adicional: un ataque de conjuro cuerpo a cuerpo, 1d8+mod force. Relanzar sustituye la anterior. Sin los 5 pies de alcance.

Oráculo: 1d8 + modificador de característica; force; acción adicional; 1 minuto; no concentración; +1d8 cada dos niveles de casilla.

### 9. charm person (nivel 1, 1 hora, sin concentración)

No aplica charmed. La ventaja «si estáis luchando» no tiene bandera de combate hostil más allá de `phase == :combat`.

Modelo: salvación de SAB, con ventaja si `phase == :combat`. Fallo → condición `charmed` con `source` = lanzador, plazo 1 h (3600 s), sin concentración. `apply_damage` del lanzador o de su `side` quita la condición (gancho junto al daño, no un hechizo nuevo). No cambia facción ni impide atacar: el motor no tiene «no puede atacarte». El valor de juego es la condición nombrada para la narración y, si se quiere un diente, desventaja del encantado al atacar al lanzador.

Borrador: Charm Person impone charmed 1 hora si falla SAB (ventaja en combate). No es concentración. El daño del lanzador o de sus aliados la quita. No reescribe `side`.

Oráculo: salvación de Sabiduría, ventaja si el grupo lucha contra el objetivo; 1 hora; termina si el lanzador o sus compañeros lo dañan; humanoide.

### 10. counterspell (nivel 3, reacción)

No interrumpe un conjuro. Es automatic sin dados.

Modelo: reacción (`TurnBudget`, el JSON dice reaction). Solo tiene sentido si otro personaje está resolviendo `cast_spell` — hoy el bucle no anida eso. Propuesta mínima: tool que el DM o un PC en turno de reacción llama *antes* de aceptar el conjuro enemigo, con el nivel declarado. Si el nivel del conjuro ≤ nivel de la casilla gastada (base 3), el cambio del conjuro se sustituye por `noop` y no gasta casilla del objetivo. Si es mayor, prueba de característica de lanzamiento CD 10 + nivel. Sin «que puedas ver».

Borrador: Counterspell es una reacción que anula un conjuro cuyo nivel sea ≤ al de la casilla (3 por defecto). Por encima, prueba de característica CD 10+nivel. No se tiran dados del conjuro anulado. Requiere un gancho en `cast_spell` para rechazar el change si hay un counterspell pendiente; si ese gancho cae fuera de este mapa, el ADR lo nombra y no se finge que ya existe.

Oráculo: automático si el conjuro es de nivel 3 o inferior (o ≤ casilla usada); si es mayor, prueba CD 10 + nivel del conjuro; reacción; instantáneo.

## 4. Lo que no merece modelo mecánico

El mundo no tiene distancias, cobertura ni línea de visión (`10-auditoria-motor.md`, frente 4). Un efecto cuyo único diente es moverse, ver más lejos o decorar la escena se queda en narración. No es deuda de `cast_spell`.

- **Trucos de color:** prestidigitation, druidcraft, thaumaturgy, light, dancing lights, minor illusion, mage hand, mending, message. No cambian PG, CA ni tiradas.
- **Información:** detect magic, identify, comprehend languages, speak with animals, locate object, legend lore, scrying, contact other plane. El DM ya puede decir lo que se ve. Una tirada de 0 no aporta.
- **Viaje sin mapa:** misty step, dimension door, teleport, fly, levitate, longstrider, jump, expeditious retreat, tree stride, wind walk. Hasta que haya grid, son una frase.
- **Conjurar ficha que no existe:** find familiar, unseen servant, floating disk, conjure animals, animate dead. Sin plantilla de criatura, no hay a quién añadir al mundo.
- **Ilusión que no impone salvación resuelta:** silent image, major image, disguise self, invisibility como «no te ven» sin penalizar tiradas. Invisibility *sí* merecería condición (ventaja para atacar, como hidden) más adelante; no está en esta lista de «nunca». Está en la tabla como DESCRIPTIVO a propósito.

Quedan fuera de esta lista, y sí merecen modelo cuando toque, los que imponen paralyzed, restrained, charmed, frightened, o un bonificador de tirada (hold person, entangle, web, bane, command, hypnotic pattern, fear, slow, banishment). Hoy son descriptivos porque no hay condición; no porque la narración baste.
