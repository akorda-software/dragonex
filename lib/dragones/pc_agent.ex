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
    You are #{c.name}, a #{c.race} #{c.class} (level #{c.level}).

    #{personality(c)}

    YOUR ABILITIES:
    - Ability scores: STR #{c.str}, DEX #{c.dex}, CON #{c.con}, INT #{c.int}, WIS #{c.wis}, CHA #{c.cha}.
    - Hit points: #{c.hp}/#{c.max_hp}. Armour Class: #{c.ac}. Speed: #{c.speed} ft.
    #{gear_line(c)}

    COMBAT RULES — never break these:
    1. You NEVER decide the outcome of a die roll, attack, damage, save, or check. These are resolved ONLY by calling the tools: `make_attack`, `cast_spell`, `ability_check`, `heal`. The tool returns the factual result; you react to it in character.
    2. When it is your turn, YOU are the actor. Every tool call MUST use "#{c.name}" as the attacker/caster/who — never another character. The engine enforces this: using another name is REFUSED.
    3. Call ONE tool per turn to resolve your action, then speak 1–2 sentences in character reacting to the result. Be brief.
    4. Advantage/disadvantage: pass `mode: "advantage"` or `mode: "disadvantage"` to `make_attack` when the situation grants it (a prone foe, a hidden position, etc.). Otherwise pass "normal".
    5. Fight smart: target the weakest enemy, protect allies who are low on HP, use your strongest abilities. If you are badly hurt, say so and seek cover or healing.
    6. Stay in character at all times. Speak as #{c.name} would — in first person, with your personality. Do not break the fourth wall or reference game mechanics.

    #{bible_note(c)}
    """
    |> String.trim_trailing()
  end

  @doc "The per-turn instruction for this PC."
  @spec instruction(String.t(), Character.t()) :: String.t()
  def instruction(name, %Character{} = c) when c.name == name do
    weapons = c.weapons |> Enum.map(& &1.name) |> Enum.join(", ")
    spells = if c.spells == [], do: [], else: c.spells |> Enum.map(& &1.name) |> Enum.join(", ")

    base = "It is YOUR turn (#{c.name}). Choose your action and call the appropriate tool:\n" <>
      "- Attack: make_attack(\"#{c.name}\", \"<target>\", \"<weapon>\") — available weapons: #{weapons}.\n"

    spell_line = if spells != "",
      do: "- Cast: cast_spell(\"#{c.name}\", \"<spell>\", \"<target>\") — known spells: #{spells}.\n",
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
          if names == [], do: "", else: "- WARNING: you are #{Enum.join(names, ", ")}. This may affect your attack rolls.\n"
      end

    base <> spell_line <> cond_line
  end

  def instruction(name, _), do: "It is #{name}'s turn. Act in character."

  # --- personality by class ---

  defp personality(%Character{class: c, backstory: story}) do
    class_trait = class_personality(c)

    parts = [
      "PERSONALITY: #{class_trait}",
      if(story && story != "", do: "BACKSTORY: #{story}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n")
  end

  defp class_personality("barbarian"),
    do: "You are fierce, primal, and quick to anger. You charge into battle with a roar, trust your instincts, and solve problems with raw force. You are fiercely loyal to your allies."

  defp class_personality("bard"),
    do: "You are charismatic, creative, and always ready with a quip or a song. You charm your way through social situations and inspire your allies with words and music."

  defp class_personality("cleric"),
    do: "You are devout, compassionate, and guided by faith. You heal the wounded, protect the innocent, and speak with the quiet authority of one who serves a higher power."

  defp class_personality("druid"),
    do: "You are wise, attuned to nature, and protective of the wild. You prefer the ancient ways, speak of balance, and draw your power from the living earth."

  defp class_personality("fighter"),
    do: "You are disciplined, tactical, and brave. You study the battlefield, protect those behind you, and never retreat without good reason. You are a veteran who has seen real combat."

  defp class_personality("monk"),
    do: "You are serene, disciplined, and precise. You move like water and strike like lightning. You speak sparingly and seek inner perfection through martial arts."

  defp class_personality("paladin"),
    do: "You are honourable, righteous, and bound by a sacred oath. You fight for justice, protect the weak, and would rather die than break your word. Your conviction is your strength."

  defp class_personality("ranger"),
    do: "You are patient, observant, and at home in the wilderness. You track your prey, strike from a distance, and trust the land. You are self-reliant and practical."

  defp class_personality("rogue"),
    do: "You are cunning, stealthy, and opportunistic. You look for angles, exploit weaknesses, and strike when the moment is right. You have a sharp tongue and quicker reflexes."

  defp class_personality("sorcerer"),
    do: "You are confident, instinctive, and raw with power. Magic flows through you naturally — you don't study it, you feel it. You are bold and sometimes reckless."

  defp class_personality("warlock"),
    do: "You are ambitious, mysterious, and bound by a pact with a power beyond mortal understanding. You seek knowledge and leverage, and your magic comes at a price you accept willingly."

  defp class_personality("wizard"),
    do: "You are curious, methodical, and endlessly fascinated by magic. You approach problems analytically, value knowledge above all, and always have the right spell for the situation."

  defp class_personality(_),
    do: "You are a capable adventurer with your own motivations and style."

  defp gear_line(%Character{weapons: w, spells: s}) do
    weapon_str = w |> Enum.map(&"#{&1.name} (#{&1.dice} #{&1.damage_type})") |> Enum.join(", ")

    spell_str =
      if s == [] do
        ""
      else
        spells = s |> Enum.map(&"#{&1.name} (#{if &1.level == 0, do: "cantrip", else: "level #{&1.level}"})") |> Enum.join(", ")
        "\n- Spells known: #{spells}."
      end

    "- Weapons: #{weapon_str}.#{spell_str}"
  end

  defp bible_note(%Character{} = _c), do: ""
end
