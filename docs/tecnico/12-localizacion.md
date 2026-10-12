# Localización: motor bilingüe es/en (D236)

Una partida se juega en un idioma (`games.locale`, `es` o `en`). Todo lo que
produce esa partida —mensajes del motor, prompts de los agentes, interfaz de
la mesa— sale en ese idioma.

## Piezas

- **`Dragonex.I18n`**: locale **por proceso** (`put_locale/1`, `with_locale/2`,
  `adopt/1`). El proceso `Game` la fija desde `games.locale`; los beats la
  heredan explícitamente (`table_locale`) y viaja en `deps.locale`, que
  adoptan herramientas y capacidades (corren en procesos de exAgent).
- **`Dragonex.Terms`**: vocabulario del juego dentro de frases (armas,
  hechizos, daño, condiciones) según la locale.
- **`Dragonex.Gettext`**: catálogo de frases. Dominios:
  - `engine`: feedback de reglas, errores, motivos de tirada, notas de sistema.
  - `prompts`: instrucciones a los agentes (DM, PC, TurnMaster, brief).
  - `ui`: textos de las LiveViews.

## Convención de conversión

1. El **msgid es el texto castellano actual**. Con locale `es` la salida debe ser
   **idéntica byte a byte** a la anterior: la suite existente lo vigila.
2. En cada módulo: `use Gettext, backend: Dragonex.Gettext`.
3. Interpolaciones `#{expr}` → marcadores `%{nombre}` con bindings explícitos:

   ```elixir
   # antes
   "#{caster} conjura #{Terms.spell(spell.name)}; #{target} recibe #{dmg} de #{Terms.damage(type)}."
   # después
   dgettext("engine", "%{caster} conjura %{spell}; %{target} recibe %{amount} de %{damage}.",
     caster: caster, spell: Terms.spell(spell.name), target: target, amount: dmg,
     damage: Terms.damage(type))
   ```

   Nombres de binding en inglés, `snake_case`, descriptivos y estables
   (`caster`, `target`, `spell`, `weapon`, `damage`, `amount`, `dc`, `total`…).
4. **Una frase completa por msgid**, con el orden de palabras dentro: el inglés
   puede reordenar los marcadores. No partas una frase en trozos traducibles si
   se puede evitar. Los fragmentos que se componen (etiquetas como
   `" (ventaja)"`) van cada uno en su propio `dgettext`.
5. El msgid debe ser un **literal** (Gettext lo extrae en compilación): nada de
   variables ni `#{}` dentro de la llamada. Una cadena de literales unidos con
   `<>` sí vale (el macro la junta en compilación), y es la forma habitual en
   prompts largos.
6. **No se traducen**: claves de datos (`"longsword"`, `"poisoned"`), valores
   que el modelo debe enviar a una herramienta (listas de opciones válidas en
   un error se mantienen con las claves), nombres de herramientas y campos
   (`cast_spell`, `condition_to_remove`), mensajes de `Logger`, átomos,
   expresiones regulares ni texto que escribió el usuario o el modelo.
7. Plurales: si el código ya elige entre singular y plural, usa dos msgids o
   `dngettext` con el mismo texto castellano.
8. Las frases dirigidas al modelo en prompts usan el dominio `prompts`; las de
   la interfaz, `ui`.

## Catálogo inglés

`mix gettext.extract` genera `priv/gettext/*.pot`;
`mix gettext.merge priv/gettext --locale en` actualiza
`priv/gettext/en/LC_MESSAGES/*.po`. Cada `msgstr` debe estar traducido: un test
de completitud falla si queda alguno vacío.

Flujo para traducir lo nuevo:

```sh
MIX_ENV=test bin/dev gettext.extract
MIX_ENV=test bin/dev gettext.merge priv/gettext --locale en
python3 scripts/i18n_po.py export engine 1 /tmp/i18n   # JSON con lo pendiente
# traducir: {"<id>": "<msgstr>"} (o ["singular", "plural"])
python3 scripts/i18n_po.py merge engine /tmp/i18n/engine-1.en.json
python3 scripts/i18n_po.py check engine
```

`merge` rechaza traducciones que no conservan los mismos `%{marcadores}`.
`scripts/i18n_sweep.py` lista literales que parecen castellano y no son msgid
de ningún `.pot`. Los aciertos en `Heroes.Translations`, `Terms` y los
lexicones son mapas bilingües o patrones, y los de `Logger` son
intencionados.

## Contenido y descripciones de tools

- **Hechizos**: `priv/srd/spells.es.json` lleva `effect` (castellano) y
  `effect_en` (original del SRD, `scripts/import_srd_spells.py --english`).
  Los integrados que no son SRD llevan `effect` en inglés y `effect_es`.
  `Heroes.Catalog` elige según la locale. `Dragonex.Spell` no cambia de forma.
- **Escenarios y topónimos**: un solo nombre inglés por lugar en todos los
  dominios (Oakton, Black Forest, Darkvale, Greenvale).
- **Descripciones de tools** (`@doc` de `deftool`): se fijan en compilación y
  van en inglés neutro para ambos idiomas. Si piden texto al modelo, dicen «in
  the language of the game», nunca un idioma fijo.

## Verificación

- `test/dragonex/i18n_catalog_test.exs`: completitud y marcadores.
- `test/dragonex/game_english_table_test.exs`: mesa inglesa de extremo a
  extremo (prompt del DM, returns de tools, tiradas y notas).
- `test/dragonex/engine_english_messages_test.exs`: turno, descanso, reservas,
  concentración y efectos de catálogo.
