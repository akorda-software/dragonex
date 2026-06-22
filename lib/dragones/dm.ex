defmodule Dragones.DM do
  @moduledoc """
  The Dungeon Master agent: a strict system prompt, the bridge tool set, and a
  concise world snapshot the LLM receives each turn.

  The DM narrates, voices monsters/NPCs and referees — but it NEVER resolves an
  outcome. Every roll, attack, save and death save goes through the tools; the
  DM only reads their textual results and weaves them into the scene.
  """

  alias Dragones.{Character, Tools, World}
  alias ExAgent.{Compaction, Message, Message.Response}

  @doc """
  The DM's tool set (it referees + controls monsters + narrates).

  The rules-resolution tools (`make_attack`, `cast_spell`, …) get a larger retry
  budget: if the DM proposes as the wrong participant, the control guard returns
  a *directive* error telling it exactly who must act, and the extra retries give
  it room to self-correct instead of failing the beat.
  """
  @spec tools() :: [term()]
  def tools do
    resolution = ~w(make_attack cast_spell ability_check make_death_save heal roll_initiative)a

    Enum.map(Tools.tools(), fn tool ->
      if tool.name in resolution, do: %{tool | max_retries: 3}, else: tool
    end)
  end

  @doc """
  Build the DM agent.

  Options:

    * `:story_bible`     — the campaign's stable context (hooks, NPCs, tone). It
      is baked into the **system instructions** (a stable prefix) so the
      provider can cache it across turns rather than re-sending it each beat.
    * `:summarizer`      — a *cheap* model used by compaction to recap old
      history. When present, a `Compaction.Summary` capability is wired in.
    * `:max_tokens`      — output cap per beat (default 512).
    * `:compaction_*`    — `:compaction_threshold` (tokens, default 6000) and
      `:compaction_keep_recent` (messages kept verbatim, default 8).
  """
  @spec new(term(), keyword()) :: ExAgent.t()
  def new(model, opts \\ []) do
    story_bible = Keyword.get(opts, :story_bible, %{})

    ExAgent.new(
      model: model,
      instructions: system_prompt(story_bible),
      tools: tools(),
      model_settings: [
        max_tokens: Keyword.get(opts, :max_tokens, 512),
        temperature: 0.7
      ],
      capabilities: compaction_capabilities(opts)
    )
  end

  # Wire compaction only when a summarizer model is supplied. The summarizer runs
  # as a separate (cheap) agent when the history crosses the threshold.
  defp compaction_capabilities(opts) do
    case Keyword.get(opts, :summarizer) do
      nil ->
        []

      summarizer ->
        [
          %Compaction.Capability{
            compactor: Compaction.Summary,
            opts: [
              threshold_tokens: Keyword.get(opts, :compaction_threshold, 6000),
              keep_recent: Keyword.get(opts, :compaction_keep_recent, 8),
              summarize: fn old -> summarize_history(summarizer, old) end
            ]
          }
        ]
    end
  end

  defp summarize_history(summarizer, old_messages) do
    # Operational signal: compaction only fires when the threshold is crossed,
    # so this log is rare and confirms the cheap summarizer role is in use.
    require Logger
    Logger.info("dragones: compaction fired — summarizing #{length(old_messages)} old messages via #{ExAgent.Model.model_name(summarizer)}")

    agent = ExAgent.new(model: summarizer, instructions: summarize_instructions())

    case ExAgent.run(agent, summarize_prompt(old_messages)) do
      {:ok, %{output: text}} when is_binary(text) -> text
      _ -> "(earlier turns recap unavailable)"
    end
  end

  defp summarize_instructions do
    "You recap a D&D 5e game's earlier turns for the DM. Keep it factual and " <>
      "terse: who acted, key damage/outcomes, scene changes, any downed foes. " <>
      "2-4 sentences. No rules jargon."
  end

  # Flatten the old messages into a readable transcript for the summarizer.
  defp summarize_prompt(messages) do
    body =
      messages
      |> Enum.map_join("\n", &message_line/1)

    "Recap these earlier turns of the game:\n\n#{body}"
  end

  defp message_line(%Message.Request{parts: parts}) do
    case user_text(parts) do
      "" -> ""
      text -> "PLAYER/DM: #{text}"
    end
  end

  defp message_line(%Message.Response{} = r) do
    case Response.text(r) do
      "" -> ""
      text -> "DM NARRATION: #{text}"
    end
  end

  defp message_line(_), do: ""

  defp user_text(parts) do
    parts
    |> Enum.map_join(fn
      %Message.Part.User{content: c} when is_binary(c) -> c
      _ -> ""
    end)
    |> String.trim()
  end

  @doc "The system prompt — the contract the DM must honour, plus the campaign bible."
  @spec system_prompt() :: String.t()
  def system_prompt, do: system_prompt(%{})

  @spec system_prompt(map()) :: String.t()
  def system_prompt(story_bible) when is_map(story_bible) do
    """
    You are the Dungeon Master (DM) of a D&D 5e game. You narrate the world, voice every monster and NPC, referee the rules, and pace the scene.

    CORE RULES — never break these:
    1. You NEVER decide the outcome of a die roll, an attack, damage, a saving throw, an ability check, or a death save. These are resolved ONLY by calling the tools: `roll_initiative`, `make_attack`, `cast_spell`, `ability_check`, `make_death_save`, `heal`. The tool returns the factual result; you narrate it.
    2. Never roll or compute numbers yourself. The tools are the single source of truth. If a player attempts something with a chance of failure outside combat (force a door, persuade, spot a trap), YOU set the difficulty and call `ability_check("Thane", "str", 15)` — use DC 5 very easy, 10 easy, 15 medium, 20 hard, 25 very hard.
    3. WHO ACTS IS DECIDED BY WHOSE TURN IT IS, and the engine enforces this strictly:
       - On a PLAYER's turn (the brief says "It's <name>'s turn"), ONLY that player's character may act. When you resolve their declared action, the attacker/caster/checker MUST be that character — e.g. `make_attack("Thane", "goblin", "longsword")`, never the monster. A monster acting on a player's turn is REFUSED by the engine.
       - On YOUR turn (the brief says "It's YOUR turn (DM) -- act for: ..."), you act for the listed monsters/NPCs only — the attacker is one of yours, e.g. `make_attack("goblin", "Thane", "scimitar")`.
       Never mix the two: do not run a monster's action during a player's turn, and do not run a player's action during your turn.
    4. Follow the dice honestly. Do not protect or favour any side. Do not undo or contradict a result the tool reported.
    5. Pacing: when a fight breaks out, call `roll_initiative` once. When every enemy is down (hp 0), call `end_combat`.
    6. Advantage/disadvantage: pass `mode: "advantage"` or `mode: "disadvantage"` to `make_attack` / `ability_check` when the situation grants it (a prone foe, an ally helping, high ground, a concealed target, etc.). Otherwise pass "normal" (or omit it).
    7. Style: vivid but BRIEF. 1–3 sentences per beat. Address the player characters in second person. No lists, no game-jargon to the players — speak as the world.

    #{bible_section(story_bible)}
    """
    |> String.trim_trailing()
  end

  # The campaign bible is stable for a partida's whole life, so it lives in the
  # system prompt (the cacheable prefix) rather than re-sent per turn.
  defp bible_section(bible) when map_size(bible) == 0, do: ""

  defp bible_section(bible) do
    body =
      bible
      |> Enum.map_join("\n", fn {k, v} -> "- #{k}: #{v}" end)

    "CAMPAIGN BIBLE (stable — guides your narration and NPC voices):\n#{body}"
  end

  @doc """
  A compact, LLM-readable snapshot of the world: phase, round, scene, initiative,
  whose turn it is, and one line per character. This is what the DM "sees" to
  decide its action.

  `current` is the participant whose turn it is; `dm` is the DM participant id.
  When it's the DM's turn, the header lists the monsters it controls (since the
  policy folds all enemies onto the DM's single turn).
  """
  @spec world_brief(World.t(), String.t() | nil, String.t()) :: String.t()
  def world_brief(%World{} = w, current, dm \\ "dm") do
    phase_line =
      case w do
        %World{phase: :combat, round: round, initiative_order: order} when order != [] ->
          "Combat -- round #{round} (initiative: #{Enum.join(order, " -> ")})"

        %World{phase: :combat} ->
          "Combat -- round #{w.round}"

        _ ->
          "Exploration"
      end

    turn_line = turn_for(w, current, dm)

    chars =
      w.characters
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, c} -> describe_char(name, c, current, dm) end)
      |> Enum.join("\n")

    [phase_line, turn_line, "Scene: #{w.scene}", chars]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp turn_for(_w, nil, _dm), do: ""

  defp turn_for(%World{characters: chars}, current, dm) when current == dm do
    monsters =
      chars
      |> Enum.filter(fn {_, c} -> c.side != "pc" and c.hp > 0 end)
      |> Enum.map(fn {name, _} -> name end)
      |> Enum.sort()

    if monsters == [],
      do: "It's YOUR turn (DM).",
      else: "It's YOUR turn (DM) -- act for: #{Enum.join(monsters, ", ")}."
  end

  defp turn_for(_w, current, _dm), do: "It's #{current}'s turn (player) -- only #{current} may act now."

  @doc "Build the per-turn user message: world snapshot + a directing instruction."
  @spec turn_prompt(World.t(), String.t() | nil, String.t(), String.t()) :: String.t()
  def turn_prompt(%World{} = w, current, instruction, dm \\ "dm") do
    "WORLD:\n#{world_brief(w, current, dm)}\n\n#{instruction}"
  end

  defp describe_char(name, %Character{} = c, current, dm) do
    status = if c.hp <= 0, do: " [DOWN]", else: ""
    you = if name == current and current != dm, do: "  <- ACTS NOW", else: ""
    weapons = c.weapons |> Enum.map(& &1.name) |> Enum.join(", ")
    spells = if c.spells == [], do: [], else: c.spells |> Enum.map(& &1.name) |> Enum.join(", ")
    gear = ["Weapons: #{weapons}"] ++ if spells == [], do: [], else: ["Spells: #{spells}"]

    "- #{name} (#{c.class}, #{c.side}): #{c.hp}/#{c.max_hp} hp, AC #{c.ac}#{status}#{you} -- #{Enum.join(gear, "; ")}"
  end
end
