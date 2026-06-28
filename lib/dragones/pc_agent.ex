defmodule Dragones.PCAgent do
  @moduledoc """
  An independent AI agent for an AI-controlled player character.

  Unlike the DM (one agent that referees + narrates + runs monsters), each AI PC
  gets its **own** agent with a personality-driven system prompt. The PC agent
  roleplays as its character: it speaks in first person, uses its own gear, and
  fights enemies — but still resolves every roll through the tools (it never
  computes outcomes itself).

  The personality is derived deterministically from the character's class and
  background (no LLM generation needed). This gives each AI PC a distinct voice:
  a rogue is cunning and opportunistic, a paladin is honourable and protective,
  a wizard is curious and methodical.
  """

  alias Dragones.{Character, Tools}

  @doc """
  The PC's tool set — a restricted subset of the game tools.

  PCs can attack, cast spells, make ability checks, death-save, and rest.
  They CANNOT: set the scene, spawn monsters, roll initiative, end combat,
  level up, or apply conditions (the DM and the engine handle those).
  """
  @spec tools() :: [term()]
  def tools do
    pc_tools = ~w(make_attack cast_spell ability_check make_death_save short_rest long_rest)

    Tools.tools()
    |> Enum.filter(fn tool -> tool.name in pc_tools end)
    |> Enum.map(fn tool ->
      if tool.name in ~w(make_attack cast_spell)a, do: %{tool | max_retries: 3}, else: tool
    end)
  end

  @doc """
  Build an ExAgent for an AI PC, with a personality-based system prompt baked
  into the instructions (a cacheable stable prefix).

  Options:
    * `:max_tokens` — output cap per turn (default 384 — PCs are terser than the DM).
  """
  @spec new(term(), Character.t(), keyword()) :: ExAgent.t()
  def new(model, %Character{} = sheet, opts \\ []) do
    ExAgent.new(
      model: model,
      instructions: system_prompt(sheet),
      tools: tools(),
      model_settings: [
        max_tokens: Keyword.get(opts, :max_tokens, 384),
        temperature: 0.8
      ]
    )
  end

  @doc "The PC's system prompt — identity, personality, gear, and the tool contract."
  @spec system_prompt(Character.t()) :: String.t()
  def system_prompt(%Character{} = c) do
    """
    Eres #{c.name}, un #{race_es(c.race)} #{class_es(c.class)} de nivel #{c.level}.

    IDIOMA: hablas y respondes SIEMPRE en castellano. Todo lo que digas debe estar en español.

    #{personality(c)}

    TUS ATRIBUTOS:
    - Puntuaciones: FUE #{c.str}, DES #{c.dex}, CON #{c.con}, INT #{c.int}, SAB #{c.wis}, CAR #{c.cha}.
    - Puntos de golpe: #{c.hp}/#{c.max_hp}. Clase de Armadura: #{c.ac}. Desplazamiento: #{c.speed} pies.
    #{gear_line(c)}

    REGLAS DE COMBATE — no las rompas nunca:
    1. NUNCA decides tú el resultado de una tirada, ataque, daño, salvación o chequeo. Eso lo resuelven EXCLUSIVAMENTE las herramientas: `make_attack`, `cast_spell`, `ability_check`, `heal`. La herramienta devuelve el resultado factual; tú reaccionas a él en personaje.
    2. Cuando sea tu turno, TÚ eres el actor. CADA llamada a una herramienta DEBE usar "#{c.name}" como atacante/conjurador/quien — nunca otro personaje. El motor lo impone: usar otro nombre es RECHAZADO.
    3. Llama a UNA herramienta por turno para resolver tu acción, luego habla 1–2 frases en personaje reaccionando al resultado. Sé breve.
    4. Ventaja/desventaja: pasa `mode: "advantage"` o `mode: "disadvantage"` a `make_attack` cuando la situación lo conceda (un enemigo caído, una posición oculta, etc.). En caso contrario pasa "normal".
    5. Pelea con inteligencia: ataca al enemigo más débil, protege a los aliados con poca vida, usa tus habilidades más fuertes. Si estás muy herido, dilo y busca cobertura o curación.
    6. Mantente siempre en personaje. Habla como lo haría #{c.name} — en primera persona, con tu personalidad. No rompas la cuarta pared ni menciones mecánicas del juego.

    #{bible_note(c)}
    """
    |> String.trim_trailing()
  end

  @doc "The per-turn instruction for this PC."
  @spec instruction(String.t(), Character.t()) :: String.t()
  def instruction(name, %Character{} = c) when c.name == name do
    # A downed (0 hp) character can only make a death saving throw on its turn —
    # it cannot attack, cast, or act. Steer the agent there explicitly so it
    # doesn't try to fight while unconscious.
    if c.max_hp not in [nil, 0] and (c.hp || 0) <= 0 do
      "Es TU turno (#{c.name}). Estás CAÍDO (0 pg) e inconsciente: lo único que " <>
        "puedes hacer es una salvación de muerte. Llama a " <>
        "make_death_save(\"#{c.name}\") y reacciona en personaje (1 frase). Responde en castellano."
    else
      weapons = c.weapons |> Enum.map(& &1.name) |> Enum.join(", ")
      spells = if c.spells == [], do: [], else: c.spells |> Enum.map(& &1.name) |> Enum.join(", ")

      base = "Es TU turno (#{c.name}). Elige tu acción y llama a la herramienta adecuada:\n" <>
        "- Atacar: make_attack(\"#{c.name}\", \"<objetivo>\", \"<arma>\") — armas disponibles: #{weapons}.\n"

      spell_line = if spells != "",
        do: "- Conjurar: cast_spell(\"#{c.name}\", \"<hechizo>\", \"<objetivo>\") — hechizos conocidos: #{spells}.\n",
        else: ""

      # Conditions reminder
      cond_line =
        case c.conditions || [] do
          [] -> ""
          conds ->
            names = Enum.map(conds, fn
              %{condition: cd} -> cd
              %{"condition" => cd} -> cd
              cd when is_binary(cd) -> cd
              _ -> nil
            end) |> Enum.reject(&is_nil/1)
            if names == [], do: "", else: "- AVISO: estás #{Enum.join(names, ", ")}. Esto puede afectar a tus tiradas de ataque.\n"
        end

      base <> spell_line <> cond_line <> "Responde en castellano."
    end
  end

  def instruction(name, _), do: "Es el turno de #{name}. Actúa en personaje. Responde en castellano."

  # --- personality by class ---

  defp personality(%Character{class: c, backstory: story}) do
    class_trait = class_personality(c)

    parts = [
      "PERSONALIDAD: #{class_trait}",
      if(story && story != "", do: "TRASFONDO: #{story}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n")
  end

  defp class_personality("barbarian"),
    do: "Eres fiero, primitivo y te enfadas con facilidad. Cargas al combate con un rugido, confías en tus instintos y resuelves los problemas con fuerza bruta. Eres ferozmente leal a tus aliados."

  defp class_personality("bard"),
    do: "Eres carismático, creativo y siempre tienes una frase o una canción a punto. Encantas en las situaciones sociales e inspiras a tus aliados con palabras y música."

  defp class_personality("cleric"),
    do: "Eres devoto, compasivo y te guía la fe. Curas a los heridos, proteges a los inocentes y hablas con la autoridad serena de quien sirve a un poder superior."

  defp class_personality("druid"),
    do: "Eres sabio, sintonizado con la naturaleza y protector de lo salvaje. Prefieres las formas antiguas, hablas de equilibrio y extraes tu poder de la tierra viva."

  defp class_personality("fighter"),
    do: "Eres disciplinado, táctico y valiente. Estudias el campo de batalla, proteges a quien tienes detrás y nunca retrocedes sin un buen motivo. Eres un veterano que ha visto combate real."

  defp class_personality("monk"),
    do: "Eres sereno, disciplinado y preciso. Te mueves como el agua y golpeas como el rayo. Hablas con parquedad y buscas la perfección interior a través de las artes marciales."

  defp class_personality("paladin"),
    do: "Eres honorable, justo y estás vinculado por un juramento sagrado. Luchas por la justicia, proteges a los débiles y preferirías morir antes que romper tu palabra. Tu convicción es tu fuerza."

  defp class_personality("ranger"),
    do: "Eres paciente, observador y te sientes en casa en la naturaleza. Rastreas a tu presa, golpeas a distancia y confías en la tierra. Eres autosuficiente y práctico."

  defp class_personality("rogue"),
    do: "Eres astuto, sigiloso y oportunista. Buscas el ángulo, aprovechas los puntos débiles y golpeas cuando llega el momento. Tienes la lengua afilada y los reflejos aún más."

  defp class_personality("sorcerer"),
    do: "Eres seguro, intuitivo y desbordas poder crudo. La magia fluye por ti de forma natural — no la estudias, la sientes. Eres audaz y a veces temerario."

  defp class_personality("warlock"),
    do: "Eres ambicioso, misterioso y estás atado por un pacto con un poder más allá del entendimiento mortal. Buscas conocimiento y ventaja, y tu magia tiene un precio que aceptas de buen grado."

  defp class_personality("wizard"),
    do: "Eres curioso, metódico y estás fascinado sin fin por la magia. Afrontas los problemas de forma analítica, valoras el conocimiento por encima de todo y siempre tienes el hechizo adecuado para la situación."

  defp class_personality(_),
    do: "Eres un aventurero capaz con tus propias motivaciones y estilo."

  defp gear_line(%Character{weapons: w, spells: s}) do
    weapon_str = w |> Enum.map(&"#{&1.name} (#{&1.dice} #{&1.damage_type})") |> Enum.join(", ")

    spell_str =
      if s == [] do
        ""
      else
        spells = s |> Enum.map(&"#{&1.name} (#{if &1.level == 0, do: "truco", else: "nivel #{&1.level}"})") |> Enum.join(", ")
        "\n- Hechizos conocidos: #{spells}."
      end

    "- Armas: #{weapon_str}.#{spell_str}"
  end

  # Spanish glosses for race/class used in the opening identity line.
  defp race_es(nil), do: "aventurero"
  defp race_es(r), do: r

  @classes_es %{
    "barbarian" => "bárbaro",
    "bard" => "bardo",
    "cleric" => "clérigo",
    "druid" => "druida",
    "fighter" => "guerrero",
    "monk" => "monje",
    "paladin" => "paladín",
    "ranger" => "explorador",
    "rogue" => "pícaro",
    "sorcerer" => "hechicero",
    "warlock" => "brujo",
    "wizard" => "mago"
  }

  defp class_es(nil), do: "aventurero"
  defp class_es(c), do: Map.get(@classes_es, c, c)

  defp bible_note(%Character{} = _c), do: ""
end
