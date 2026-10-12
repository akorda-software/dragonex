defmodule Dragonex.Scenarios do
  @moduledoc """
  Five original adventure scenarios inspired by classic D&D tropes.

  Each scenario provides a complete story bible (hook, tone, NPCs, locations)
  plus a suggested enemy roster the DM draws from via `spawn_monster`. The
  players never pick enemies — the DM introduces them as the story unfolds.

  These are original scenarios, not adaptations of published adventures.

  Texts are resolved at runtime in the current locale (D236): `title` and
  `summary` are picker labels (`ui`), the rest feeds the story bible (`prompts`).
  """

  use Gettext, backend: Dragonex.Gettext

  @type scenario :: %{
          key: String.t(),
          title: String.t(),
          scene: String.t(),
          dm_style: String.t(),
          hook: String.t(),
          tone: String.t(),
          npcs: String.t(),
          locations: String.t(),
          suggested_enemies: [String.t()],
          summary: String.t()
        }

  @spec all() :: [scenario()]
  def all do
    [
      %{
        key: "tavern",
        title: dgettext("ui", "La Taberna del Dragón Rojo"),
        scene:
          dgettext(
            "prompts",
            "una taberna rústica junto a un camino comercial, olor a madera y estofado"
          ),
        dm_style: dgettext("prompts", "acogedor pero con tensión creciente"),
        hook:
          dgettext(
            "prompts",
            "Los aventureros se conocen en una taberna. El posadero les ofrece oro por investigar unos asaltos goblin a las caravanas del camino cercano."
          ),
        tone: dgettext("prompts", "fantasía heroica clásica, comunidad amenazada"),
        npcs:
          dgettext(
            "prompts",
            "Borin el posadero (humano, nervioso), la guardia Sable (humana, estoica)"
          ),
        locations:
          dgettext(
            "prompts",
            "la taberna del Dragón Rojo, el camino comercial, el campamento goblin en las colinas"
          ),
        suggested_enemies: ["goblin", "goblin", "wolf"],
        summary:
          dgettext(
            "ui",
            "Clásico inicio de taberna: goblins asaltan caravanas y los héroes deben limpiar su campamento."
          )
      },
      %{
        key: "crypt",
        title: dgettext("ui", "La Cripta del Rey Olvidado"),
        scene:
          dgettext(
            "prompts",
            "la entrada de piedra de una cripta antigua recién desenterrada, runas mortecinas"
          ),
        dm_style: dgettext("prompts", "gótico, opresivo, descriptivo de olores y frío"),
        hook:
          dgettext(
            "prompts",
            "Unas excavaciones han destapado una cripta milenaria. Esta noche, luces espectrales brillan en su interior y los aldeanos han desaparecido."
          ),
        tone: dgettext("prompts", "terror gótico, tensión constante"),
        npcs:
          dgettext(
            "prompts",
            "el anciano Aldric (erudito, aterrorizado), la guardiana Mira (paladín, resuelta)"
          ),
        locations:
          dgettext(
            "prompts",
            "la cripta del Rey Olvidado, la aldea de Valle Oscuro, el cementerio viejo"
          ),
        suggested_enemies: ["skeleton", "skeleton", "skeleton"],
        summary:
          dgettext(
            "ui",
            "No-muerto en una cripta antigua. Los héroes deben descender y poner a descansar a los muertos."
          )
      },
      %{
        key: "siege",
        title: dgettext("ui", "El Asedio a Pueblo Roble"),
        scene:
          dgettext(
            "prompts",
            "un pueblo fronterizo amurallado con hogueras de orcos visibles en el horizonte al atardecer"
          ),
        dm_style: dgettext("prompts", "urgente, militar, decisiones bajo presión"),
        hook:
          dgettext(
            "prompts",
            "Pueblo Roble está asediado por una banda de orcos. Los héroes llegan como refuerzos justo antes del asalto final al amanecer."
          ),
        tone: dgettext("prompts", "urgencia bélica, defensa desesperada"),
        npcs:
          dgettext(
            "prompts",
            "el capitán Joren (veterano curtido), la curandera Pip (halfling, decidida)"
          ),
        locations:
          dgettext("prompts", "Pueblo Roble, la empalizada, las colinas donde acampan los orcos"),
        suggested_enemies: ["orc", "orc", "goblin"],
        summary:
          dgettext("ui", "Defiende un pueblo de un asalto orco. Combate directo y urgente.")
      },
      %{
        key: "tower",
        title: dgettext("ui", "La Torre de Aldric"),
        scene:
          dgettext(
            "prompts",
            "una torre solitaria de piedra oscura, luces antinaturales parpadean en su cima"
          ),
        dm_style: dgettext("prompts", "misterioso, inquietante, revelaciones graduales"),
        hook:
          dgettext(
            "prompts",
            "El mago Aldric llevaba meses sin salir de su torre. Ayer, un destello de energía iluminó el cielo y desde entonces extrañas criaturas merodean los alrededores."
          ),
        tone: dgettext("prompts", "misterio arcana, exploración de lo desconocido"),
        npcs:
          dgettext(
            "prompts",
            "la aprendiz Sable (joven maga, asustada), el fantasma de Aldric (aparición)"
          ),
        locations:
          dgettext("prompts", "la torre de Aldric, el pueblo de Valle Verde, el claro encantado"),
        suggested_enemies: ["bandit", "bandit", "kobold"],
        summary:
          dgettext(
            "ui",
            "Investiga una torre de mago donde algo salió mal. Misterio y criaturas arcanas."
          )
      },
      %{
        key: "forest",
        title: dgettext("ui", "Cazadores en el Bosque Negro"),
        scene:
          dgettext(
            "prompts",
            "un sendero que se adentra en un bosque denso y oscuro, niebla entre los árboles"
          ),
        dm_style: dgettext("prompts", "atmosférico, survival, tensión creciente"),
        hook:
          dgettext(
            "prompts",
            "Los lobos del Bosque Negro han atacado al ganado durante semanas, pero los aldeanos sospechan que algo los controla. Los héroes deben encontrar la fuente."
          ),
        tone: dgettext("prompts", "supervivencia en naturaleza, caza y ser cazado"),
        npcs:
          dgettext(
            "prompts",
            "el guardabosques Kael (elfo, conocedor del bosque), la lendra Mira (aldeana valiente)"
          ),
        locations:
          dgettext(
            "prompts",
            "el Bosque Negro, la aldea de los Claros, la cueva oculta en lo profundo"
          ),
        suggested_enemies: ["wolf", "wolf", "orc"],
        summary:
          dgettext(
            "ui",
            "Persigue lobos en un bosque oscuro y descubre qué los controla. Supervivencia y exploración."
          )
      },
      %{
        key: "arena",
        title: dgettext("ui", "Arena de Pruebas"),
        scene:
          dgettext(
            "prompts",
            "una arena de entrenamiento cerrada con maniquíes de paja, dianas, barriles, un círculo de invocación para criaturas de prueba y carteles que delimitan cada zona de práctica"
          ),
        dm_style:
          dgettext(
            "prompts",
            "metódico y didáctico: guía al jugador por cada mecánica del motor, una a una. Anima a experimentar con ventaja, desventaja, condiciones, magia y descansos. Usa spawn_monster para invocar diferentes enemigos y prueba cada tipo de arma y hechizo"
          ),
        hook:
          dgettext(
            "prompts",
            "ESTO NO ES UNA AVENTURA — es un campo de pruebas cerrado para ejercitar TODAS las mecánicas del motor. " <>
              "El objetivo no es la narrativa sino verificar que cada sistema funciona.\n" <>
              "LÍMITES DE LA ESCENA (crítico): la arena es una única sala cerrada. NO hay puertas secretas, " <>
              "pasillos ocultos, tabernas, ni mundo exterior. Si un PC dice 'me voy', 'salgo de la arena', " <>
              "'voy a la taberna' o similar, reconduce: el mayordomo le detiene, las puertas están selladas, " <>
              "la arena está aislada por un campo mágico. NO inventes trama externa (guardias, jefes, cajas, " <>
              "puertas oeste) — no existen. Lo único que existe es la arena y lo que en ella hay.\n" <>
              "OBJETOS VÁLIDOS PARA PRÁCTICA: cuando un PC quiera atacar un maniquí o diana, usa " <>
              "spawn_monster(\"training_dummy\", \"maniquí1\") o spawn_monster(\"archery_target\", \"diana1\") " <>
              "para crear el objetivo y luego el PC hace make_attack contra ese nombre. NUNCA tires un d20 " <>
              "tú mismo por un ataque a un objeto — siempre a través de make_attack.\n" <>
              "Lista de mecánicas a probar (avanza metódicamente, UNA por turno, sin repetir el menú):\n" <>
              "• COMBATE: ataques melee con STR (longsword), ataques a distancia con DEX (shortbow, javelin), armas finesse (scimitar, shortsword), " <>
              "ataques con ventaja (mode: advantage) y desventaja (mode: disadvantage), críticos (nat 20) y pifias (nat 1).\n" <>
              "• MAGIA: hechizos de ataque vs CA (firebolt), hechizos automáticos que siempre impactan (magic missile), " <>
              "hechizos de salvación (saving throw), reacciones (shield +5 CA).\n" <>
              "• TIRADAS: ability checks con y sin competencia a varias CDs (5 fácil, 10 media, 15 difícil, 20 muy difícil), " <>
              "saving throws de cada característica (str, dex, con, int, wis, cha).\n" <>
              "• MUERTE Y CAÍDAS: dejar un personaje a 0 HP y probar make_death_save " <>
              "(nat 20 revive a 1 HP, nat 1 cuenta doble, 3 fallos = muerto, 3 éxitos = estable).\n" <>
              "• CURACIÓN: heal con expresión de dados (1d8+3), comprobar tope de max_hp.\n" <>
              "• CONDICIONES: apply_condition y remove_condition (prone, blinded, poisoned, stunned, restrained) — " <>
              "observa cómo conceden ventaja/desventaja automáticamente.\n" <>
              "• DESCANSOS: short_rest (gastar hit die) y long_rest (recuperar todo HP y casillas de hechizo).\n" <>
              "• PROGRESIÓN: grant_xp para otorgar experiencia (sin subir de nivel) y level_up cuando puedan subir.\n" <>
              "• TÁCTICO: roll_initiative para iniciar combate, spawn_monster para refuerzos " <>
              "(probar cada CR: goblin, kobold, bandit, skeleton, wolf, orc, hobgoblin, ogre, giant_spider), end_combat para terminar.\n" <>
              "Empieza preguntando al jugador qué mecánica quiere probar primero."
          ),
        tone:
          dgettext(
            "prompts",
            "experimental y didáctico, sin stakes narrativos — lo que importa es ejercitar mecánicas, no la historia"
          ),
        npcs:
          dgettext(
            "prompts",
            "maniquíes de práctica (objetos inertes para atacar — crear vía spawn_monster), dianas, un mayordomo de arena neutral que explica las opciones disponibles"
          ),
        locations:
          dgettext(
            "prompts",
            "ÚNICAMENTE la Arena de Pruebas: zona de cuerpo a cuerpo, zona de tiro al blanco, círculo de invocación, zona de magia, zona de descanso. Nada más."
          ),
        suggested_enemies: [
          "goblin",
          "kobold",
          "bandit",
          "skeleton",
          "wolf",
          "orc",
          "hobgoblin",
          "ogre"
        ],
        summary:
          dgettext(
            "ui",
            "Campo de pruebas: no es una aventura. Ejercita todas las mecánicas (combate, magia, salvaciones, condiciones, descansos, niveles, refuerzos) en un entorno controlado. Sin trama externa, sin salida."
          )
      }
    ]
  end

  @doc "Look up a scenario by key."
  @spec get(String.t()) :: scenario() | nil
  def get(key), do: Enum.find(all(), &(&1.key == key))

  @doc "Build a story bible map for `Games.create_game`."
  @spec bible(scenario()) :: map()
  def bible(%{hook: hook, tone: tone, npcs: npcs, locations: loc, suggested_enemies: enemies}) do
    %{
      "hook" => hook,
      "tone" => tone,
      "npcs" => npcs,
      "locations" => loc,
      "enemies" =>
        dgettext(
          "prompts",
          "El DM puede introducir estos enemigos cuando la historia lo pida: %{enemies}",
          enemies: Enum.join(enemies, ", ")
        )
    }
  end

  @doc """
  Canonical facts seeded into `world.facts` at create (D32). The DM reads
  them every turn, so the bible's posadero stays Borin instead of Grimm.
  """
  @spec seed_facts(map()) :: [String.t()]
  def seed_facts(bible) when is_map(bible) do
    npcs = bible["npcs"] || bible[:npcs] || ""
    locs = bible["locations"] || bible[:locations] || ""
    hook = bible["hook"] || bible[:hook] || ""
    enemies = bible["enemies"] || bible[:enemies] || ""

    parse_npc_facts(npcs) ++
      parse_location_facts(locs) ++
      parse_hook_facts(hook) ++
      parse_enemy_facts(enemies)
  end

  def seed_facts(_), do: []

  defp parse_npc_facts(npcs) when is_binary(npcs) and npcs != "" do
    npcs
    |> split_npc_chunks()
    |> Enum.map(&npc_fact/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_npc_facts(_), do: []

  defp split_npc_chunks(text) do
    {chunks, cur, _depth} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        "(", {acc, cur, d} -> {acc, cur <> "(", d + 1}
        ")", {acc, cur, d} -> {acc, cur <> ")", max(d - 1, 0)}
        ",", {acc, cur, 0} -> {[String.trim(cur) | acc], "", 0}
        g, {acc, cur, d} -> {acc, cur <> g, d}
      end)

    Enum.reverse([String.trim(cur) | chunks]) |> Enum.reject(&(&1 == ""))
  end

  defp npc_fact(chunk) do
    core = chunk |> String.replace(~r/\s*\([^)]*\)/u, "") |> String.trim()

    # English games parse English NPC strings first ("Borin the innkeeper",
    # "the guard Sable"); Spanish keeps its exact grammar (and a Spanish custom
    # bible inside an English game still parses through it).
    if Dragonex.I18n.locale() == :en,
      do: npc_fact_en(core) || npc_fact_es(core) || npc_fact_en_mention(core),
      else: npc_fact_es(core)
  end

  defp npc_fact_en(core) do
    cond do
      m = Regex.run(~r/^(\p{Lu}[\w'’-]*)\s+the\s+(.+)$/u, core) ->
        [_, name, role] = m
        dgettext("prompts", "El %{role} se llama %{name}.", role: role, name: name)

      m = Regex.run(~r/^the\s+(.+?)\s+(\p{Lu}[\w'’-]*)$/iu, core) ->
        [_, role, name] = m

        # "the ghost of Aldric" names a role relative to someone, not a title.
        if Regex.match?(~r/\s(?:of|from)$/iu, role) do
          nil
        else
          dgettext("prompts", "%{article} %{role} se llama %{name}.",
            article: "The",
            role: role,
            name: name
          )
        end

      true ->
        nil
    end
  end

  # Fallback: any capitalized word names someone present ("old Aldric",
  # "the ghost of Aldric").
  defp npc_fact_en_mention(core) do
    case Regex.run(~r/(?:^|\s)(\p{Lu}[\w'’-]*)/u, core) do
      [_, name] -> dgettext("prompts", "%{name} está en esta aventura.", name: name)
      _ -> nil
    end
  end

  defp npc_fact_es(core) do
    cond do
      m = Regex.run(~r/^([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)\s+el\s+(.+)$/u, core) ->
        [_, name, role] = m
        dgettext("prompts", "El %{role} se llama %{name}.", role: role, name: name)

      m = Regex.run(~r/^([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)\s+la\s+(.+)$/u, core) ->
        [_, name, role] = m
        dgettext("prompts", "La %{role} se llama %{name}.", role: role, name: name)

      m = Regex.run(~r/^(el|la)\s+(.+?)\s+([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)$/u, core) ->
        [_, art, role, name] = m

        dgettext("prompts", "%{article} %{role} se llama %{name}.",
          article: String.capitalize(art),
          role: role,
          name: name
        )

      m = Regex.run(~r/^([A-ZÁÉÍÓÚÑ][\wáéíóúñ]+)/u, core) ->
        [_, name] = m
        dgettext("prompts", "%{name} está en esta aventura.", name: name)

      true ->
        nil
    end
  end

  defp parse_location_facts(loc) when is_binary(loc) and loc != "" do
    first = loc |> String.split(",") |> List.first() |> String.trim()

    if first == "",
      do: [],
      else: [dgettext("prompts", "El lugar inicial es %{place}.", place: first)]
  end

  defp parse_location_facts(_), do: []

  defp parse_hook_facts(hook) when is_binary(hook) and hook != "" do
    trimmed = String.trim(hook)

    if trimmed == "",
      do: [],
      else: [dgettext("prompts", "Gancho de la biblia: %{hook}", hook: trimmed)]
  end

  defp parse_hook_facts(_), do: []

  defp parse_enemy_facts(enemies) when is_binary(enemies) and enemies != "" do
    case Regex.run(~r/:\s*(.+)$/u, enemies) do
      [_, list] ->
        names =
          list
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.join(", ")

        if names == "",
          do: [],
          else: [dgettext("prompts", "Los enemigos previstos son: %{names}.", names: names)]

      _ ->
        []
    end
  end

  defp parse_enemy_facts(_), do: []

  @doc "A list of random fantasy hero names."
  @spec random_name() :: String.t()
  def random_name do
    names =
      ~w(Lyra Thane Vex Bryn Dorin Kael Sylva Rhogar Pip Fizzle Gronk Aldric Mira Joren Sable Tara Corin Drask Elara Fenris Nyssa)

    Enum.random(names)
  end
end
