defmodule Dragones.Scenarios do
  @moduledoc """
  Five original adventure scenarios inspired by classic D&D tropes.

  Each scenario provides a complete story bible (hook, tone, NPCs, locations)
  plus a suggested enemy roster the DM draws from via `spawn_monster`. The
  players never pick enemies — the DM introduces them as the story unfolds.

  These are original scenarios, not adaptations of published adventures.
  """

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
        title: "La Taberna del Dragón Rojo",
        scene: "una taberna rústica junto a un camino comercial, olor a madera y estofado",
        dm_style: "acogedor pero con tensión creciente",
        hook: "Los aventureros se conocen en una taberna. El posadero les ofrece oro por investigar unos asaltos goblin a las caravanas del camino cercano.",
        tone: "fantasía heroica clásica, comunidad amenazada",
        npcs: "Borin el posadero (humano, nervioso), la guardia Sable (humana, estoica)",
        locations: "la taberna del Dragón Rojo, el camino comercial, el campamento goblin en las colinas",
        suggested_enemies: ["goblin", "goblin", "wolf"],
        summary: "Clásico inicio de taberna: goblins asaltan caravanas y los héroes deben limpiar su campamento."
      },
      %{
        key: "crypt",
        title: "La Cripta del Rey Olvidado",
        scene: "la entrada de piedra de una cripta antigua recién desenterrada, runas mortecinas",
        dm_style: "gótico, opresivo, descriptivo de olores y frío",
        hook: "Unas excavaciones han destapado una cripta milenaria. Esta noche, luces espectrales brillan en su interior y los aldeanos han desaparecido.",
        tone: "terror gótico, tensión constante",
        npcs: "el anciano Aldric (erudito, aterrorizado), la guardiana Mira (paladín, resuelta)",
        locations: "la cripta del Rey Olvidado, la aldea de Valle Oscuro, el cementerio viejo",
        suggested_enemies: ["skeleton", "skeleton", "skeleton"],
        summary: "No-muerto en una cripta antigua. Los héroes deben descender y poner a descansar a los muertos."
      },
      %{
        key: "siege",
        title: "El Asedio a Pueblo Roble",
        scene: "un pueblo fronterizo amurallado con hogueras de orcos visibles en el horizonte al atardecer",
        dm_style: "urgente, militar, decisiones bajo presión",
        hook: "Pueblo Roble está asediado por una banda de orcos. Los héroes llegan como refuerzos justo antes del asalto final al amanecer.",
        tone: "urgencia bélica, defensa desesperada",
        npcs: "el capitán Joren (veterano curtido), la curandera Pip (halfling, decidida)",
        locations: "Pueblo Roble, la empalizada, las colinas donde acampan los orcos",
        suggested_enemies: ["orc", "orc", "goblin"],
        summary: "Defiende un pueblo de un asalto orco. Combate directo y urgente."
      },
      %{
        key: "tower",
        title: "La Torre de Aldric",
        scene: "una torre solitaria de piedra oscura, luces antinaturales parpadean en su cima",
        dm_style: "misterioso, inquietante, revelaciones graduales",
        hook: "El mago Aldric llevaba meses sin salir de su torre. Ayer, un destello de energía iluminó el cielo y desde entonces extrañas criaturas merodean los alrededores.",
        tone: "misterio arcana, exploración de lo desconocido",
        npcs: "la aprendiz Sable (joven maga, asustada), el fantasma de Aldric (aparición)",
        locations: "la torre de Aldric, el pueblo de Valle Verde, el claro encantado",
        suggested_enemies: ["bandit", "bandit", "kobold"],
        summary: "Investiga una torre de mago donde algo salió mal. Misterio y criaturas arcanas."
      },
      %{
        key: "forest",
        title: "Cazadores en el Bosque Negro",
        scene: "un sendero que se adentra en un bosque denso y oscuro, niebla entre los árboles",
        dm_style: "atmosférico, survival, tensión creciente",
        hook: "Los lobos del Bosque Negro han atacado al ganado durante semanas, pero los aldeanos sospechan que algo los controla. Los héroes deben encontrar la fuente.",
        tone: "supervivencia en naturaleza, caza y ser cazado",
        npcs: "el guardabosques Kael (elfo, conocedor del bosque), la lendra Mira (aldeana valiente)",
        locations: "el Bosque Negro, la aldea de los Claros, la cueva oculta en lo profundo",
        suggested_enemies: ["wolf", "wolf", "orc"],
        summary: "Persigue lobos en un bosque oscuro y descubre qué los controla. Supervivencia y exploración."
      }
    ]
  end

  @doc "Look up a scenario by key."
  @spec get(String.t()) :: scenario() | nil
  def get(key), do: Enum.find(all(), &(&1.key == key))

  @doc "All scenario keys."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(all(), & &1.key)

  @doc "Build a story bible map for `Games.create_game`."
  @spec bible(scenario()) :: map()
  def bible(%{hook: hook, tone: tone, npcs: npcs, locations: loc, suggested_enemies: enemies}) do
    %{
      "hook" => hook,
      "tone" => tone,
      "npcs" => npcs,
      "locations" => loc,
      "enemies" => "The DM may introduce these foes as the story calls for it: #{Enum.join(enemies, ", ")}"
    }
  end

  @doc "A list of random fantasy hero names."
  @spec random_name() :: String.t()
  def random_name do
    names = ~w(Lyra Thane Vex Bryn Dorin Kael Sylva Rhogar Pip Fizzle Gronk Aldric Mira Joren Sable Tara Corin Drask Elara Fenris Nyssa)
    Enum.random(names)
  end
end
