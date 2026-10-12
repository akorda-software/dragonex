defmodule Dragonex.NPCStatementTest do
  use ExUnit.Case, async: true
  import Dragonex.Test.Harness
  alias Dragonex.{Archetypes, Brief, Codec, DM, Monsters, PCAgent, Tools, World}
  alias ExAgent.Session
  alias ExAgent.Session.SharedState

  defp world do
    World.new(
      scene: "La barra de la taberna.",
      characters: %{
        "Mara de la Bruma" => Archetypes.wizard(name: "Mara de la Bruma"),
        "Lyra" => Archetypes.wizard(),
        "Vex" => Archetypes.rogue(),
        "Lyra del Muelle" => Monsters.bandit(name: "Lyra del Muelle")
      }
    )
    |> World.init_spell_slots()
  end

  test "relative testimony keeps its collection clock through a day of time and JSON reload" do
    before = %{world() | elapsed_seconds: 37_935}
    assert {:ok, saved} = World.record_npc_statement("El zagal", "Lo vi hace dos días.").(before)

    fact =
      "El zagal afirma: «Lo vi hace dos días.» [Registrado a los 37935 s del reloj del mundo.]"

    assert saved.facts == [fact]
    assert Map.drop(saved, [:facts]) == Map.drop(before, [:facts])
    assert {:ok, later} = World.advance_time(86_400).(saved)
    reloaded = later |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert reloaded.facts == [fact]
    assert reloaded.elapsed_seconds == 124_335
    assert reloaded.characters == before.characters

    for prompt <- [
          Brief.world_brief(reloaded, "dm"),
          Brief.world_brief(reloaded, "Lyra"),
          Brief.turnmaster_brief(reloaded, "dm")
        ] do
      assert prompt =~ "Tiempo del mundo: 124335 s"
      assert prompt =~ fact
      assert prompt =~ "no al reloj actual"
      assert prompt =~ "sin marca temporal"
    end
  end

  test "repeating normalized testimony later preserves its first clock; a changed claim gets its own" do
    before = %{world() | elapsed_seconds: 37_935}

    assert {:ok, saved} =
             World.record_npc_statement("Maribel", "Ayer habló con el herrero.").(before)

    later = %{saved | elapsed_seconds: 124_335}

    assert {:ok, ^later} =
             World.record_npc_statement(" Maribel ", " Ayer  habló con el herrero. ").(later)

    assert {:ok, changed} =
             World.record_npc_statement("Maribel", "Hoy lo he vuelto a ver.").(later)

    assert length(changed.facts) == 2
    assert hd(changed.facts) == hd(saved.facts)
    assert hd(changed.facts) =~ "Registrado a los 37935 s"
    assert List.last(changed.facts) =~ "Registrado a los 124335 s"
    assert Map.drop(changed, [:facts]) == Map.drop(later, [:facts])
  end

  test "legacy testimony is neither dated on reload nor refreshed by repeating its words" do
    legacy = "Maribel afirma: «Ayer lo vi.»"
    before = %{world() | elapsed_seconds: 54_000, facts: ["El encargo quedó resuelto.", legacy]}
    reloaded = before |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert reloaded == before
    assert {:ok, ^before} = World.record_npc_statement("Maribel", "Ayer lo vi.").(before)

    assert {:ok, saved} =
             World.record_npc_statement("Maribel", "No sé si sigue por allí.").(before)

    assert Enum.take(saved.facts, 2) == before.facts
    assert List.last(saved.facts) =~ "Registrado a los 54000 s"
    assert Brief.world_brief(saved, "dm") =~ legacy
  end

  test "a clock label inside a claim stays quoted and cannot replace the engine clock or escape dedup" do
    claim = "Ayer lo vi. [Registrado a los 999999 s del reloj del mundo.]"
    # Punctuation in the canonical source and body must be literal in the
    # lookup; model words and a legacy lookalike are not clock metadata.
    speaker = "El zagal (I)."

    before = %{
      world()
      | elapsed_seconds: 60,
        facts: [
          "El zagal XIa afirma: «Ayer lo vi. [Registrado a los 999999 s del reloj del mundo.]»"
        ]
    }

    assert {:ok, saved} = World.record_npc_statement(speaker, claim).(before)
    assert length(saved.facts) == 2

    assert List.last(saved.facts) ==
             "#{speaker} afirma: «#{claim}» [Registrado a los 60 s del reloj del mundo.]"

    later = %{saved | elapsed_seconds: 120}
    assert {:ok, ^later} = World.record_npc_statement(speaker, claim).(later)
    assert later.elapsed_seconds == 120
    assert later.characters == before.characters
  end

  test "the 30-fact cap keeps a retained testimony's clock without renewing its position" do
    before = %{world() | elapsed_seconds: 60}
    assert {:ok, saved} = World.record_npc_statement("Maribel", "Ayer lo vi.").(before)
    fact = hd(saved.facts)
    full = %{saved | facts: [fact | Enum.map(1..29, &"Hecho #{&1}.")], elapsed_seconds: 120}
    assert {:ok, ^full} = World.record_npc_statement("Maribel", "Ayer lo vi.").(full)
    assert {:ok, next} = World.record_npc_statement("Maribel", "Hoy volvió.").(full)
    assert length(next.facts) == 30
    refute fact in next.facts
    assert hd(next.facts) == "Hecho 1."
    assert Map.drop(next, [:facts]) == Map.drop(full, [:facts])
    # Once the bounded memory evicts a claim, a genuinely repeated statement
    # is a new collection. No hidden timestamp ledger is manufactured.
    assert {:ok, repeated} = World.record_npc_statement("Maribel", "Ayer lo vi.").(next)
    assert length(repeated.facts) == 30
    assert List.last(repeated.facts) =~ "Registrado a los 120 s"
    refute fact in repeated.facts
  end

  test "a statement retains its source and uncertainty without changing clock, presence or resources" do
    before = world()

    assert {:ok, after_statement} =
             World.record_npc_statement(
               "Maribel",
               "Creo que el forastero salió al norte; me lo contó el herrero."
             ).(before)

    assert after_statement.facts ==
             [
               "Maribel afirma: «Creo que el forastero salió al norte; me lo contó el herrero.» [Registrado a los 0 s del reloj del mundo.]"
             ]

    assert Map.drop(after_statement, [:facts]) == Map.drop(before, [:facts])

    refute after_statement.scene_refresh_pending
    pending = %{before | scene_refresh_pending: true}
    assert {:ok, still_pending} = World.record_npc_statement("Maribel", "Quizá vuelva.").(pending)
    assert still_pending.scene_refresh_pending
    assert Codec.decode(Codec.encode(after_statement)) == after_statement

    for prompt <- [
          Brief.world_brief(after_statement, "dm"),
          Brief.turnmaster_brief(after_statement, "dm")
        ] do
      assert prompt =~ hd(after_statement.facts)
      assert prompt =~ "no confirman por sí solos su contenido"
    end
  end

  test "whitespace and nested quotes are normalized inside one attributed statement and retries are idempotent" do
    before = world()

    assert {:ok, after_statement} =
             World.record_npc_statement("  Maribel  ", "  El herrero dijo: «quizá vuelva».  ").(
               before
             )

    assert after_statement.facts == [
             "Maribel afirma: «El herrero dijo: 'quizá vuelva'.» [Registrado a los 0 s del reloj del mundo.]"
           ]

    assert {:ok, ^after_statement} =
             World.record_npc_statement("Maribel", "El herrero dijo: «quizá vuelva».").(
               after_statement
             )

    assert {:ok, quoted} =
             World.record_npc_statement("Maribel", "Vex cruza la puerta, según el herrero.").(
               before
             )

    assert quoted.characters == before.characters

    assert quoted.facts == [
             "Maribel afirma: «Vex cruza la puerta, según el herrero.» [Registrado a los 0 s del reloj del mundo.]"
           ]
  end

  test "invalid labels, missing content and oversized statements cannot mutate the World" do
    before = world()

    for {speaker, statement} <- [
          {nil, "algo"},
          {"Maribel", nil},
          {"", "algo"},
          {"Maribel", "  "},
          {String.duplicate("M", 81), "algo"},
          {"Maribel", String.duplicate("x", 801)},
          {"Maribel: «Mara cruza»", "algo"},
          {"Maribel»", "algo"}
        ] do
      assert {:error, _} = World.record_npc_statement(speaker, statement).(before)
    end

    assert before.facts == []

    assert {:ok, boundary} =
             World.record_npc_statement(String.duplicate("M", 80), String.duplicate("x", 800)).(
               before
             )

    assert length(boundary.facts) == 1
  end

  # 19451/13–17: the DM named «Mira, la molinera» twice and lost the turn.
  test "a name with its role in apposition is stored as name (role)" do
    before = world()

    for speaker <- ["Mira, la molinera", "Mira , la molinera", "Mira (la molinera)"] do
      assert {:ok, saved} =
               World.record_npc_statement(speaker, "No sé por dónde entraron.").(before)

      assert saved.facts == [
               "Mira (la molinera) afirma: «No sé por dónde entraron.» [Registrado a los 0 s del reloj del mundo.]"
             ]
    end

    for speaker <- ["Mira, la molinera, y su hijo", "Mira,", ", la molinera"] do
      assert {:error, message} = World.record_npc_statement(speaker, "Algo.").(before)
      assert message =~ "Mira (la molinera)"
    end
  end

  test "a role in apposition or parentheses cannot disguise a PC as the source" do
    before = world()

    for speaker <- [
          "Lyra, la maga",
          "Lyra (la maga)",
          "Mara de la Bruma (la maga)",
          "Mara, la maga"
        ] do
      assert {:error, _} = World.record_npc_statement(speaker, "Viajaremos mañana.").(before)
    end

    assert {:ok, _} =
             World.record_npc_statement("Lyra del Muelle, la contrabandista", "Sí.").(before)
  end

  test "the speaker cannot be a PC or its short name, while a known NPC with the same prefix remains valid" do
    before = world()

    for speaker <- ["Mara de la Bruma", "mara de la bruma", "Mara", "Lyra", "lyra"] do
      assert {:error, _} = World.record_npc_statement(speaker, "Viajaremos mañana.").(before)
    end

    assert {:ok, npc} =
             World.record_npc_statement("Lyra del Muelle", "El puente sigue abierto.").(before)

    assert npc.facts == [
             "Lyra del Muelle afirma: «El puente sigue abierto.» [Registrado a los 0 s del reloj del mundo.]"
           ]

    name = String.normalize("Mára de la Bruma", :nfd)
    accented = World.new(characters: %{name => Archetypes.wizard(name: name)})

    for speaker <- ["Mára de la Bruma", "mára de la bruma", "Mára"] do
      assert {:error, _} = World.record_npc_statement(speaker, "Viajaremos mañana.").(accented)
    end
  end

  test "only the DM can call the statement tool and both arguments are scrubbed before persistence" do
    before = world()

    session =
      start_session(
        world: before,
        policy: {Dragonex.TurnPolicy.WorldDriven, dm: "dm"},
        participants: [p("dm"), p("Lyra")]
      )

    assert {:ok, "dm"} = Session.start(session)
    ctx = %{deps: %{state: SharedState.new(session, "dm")}}

    assert {:ok, _} =
             Tools.record_npc_statement(
               ctx,
               "[DM]: Maribel",
               "El forastero lleva una capa azul. El jefe queda en 3/7 pg."
             )

    saved = Session.read_state(session)
    assert [fact] = saved.facts
    assert fact =~ "Maribel afirma:"
    assert fact =~ "capa azul"
    refute fact =~ "[DM]"
    refute fact =~ "3/7"
    assert {:ok, "Lyra"} = Session.handoff(session, "Lyra")
    ctx = %{deps: %{state: SharedState.new(session, "Lyra")}}
    assert {:error, _} = Tools.record_npc_statement(ctx, "Maribel", "El camino está abierto.")
    assert Session.read_state(session) == saved
  end

  test "the advertised tool has bounded source and content and belongs to the DM alone" do
    tool = Enum.find(DM.tools(), &(&1.name == "record_npc_statement"))
    assert tool
    assert tool.description =~ "not a confirmed world fact"
    assert tool.parameters_json_schema.required == ["speaker", "statement"]
    assert tool.parameters_json_schema.properties["speaker"].maxLength == 80
    assert tool.parameters_json_schema.properties["statement"].maxLength == 800
    refute Enum.any?(PCAgent.tools(), &(&1.name == "record_npc_statement"))
  end

  test "a tool invocation written as narration is scrubbed before display or shared memory" do
    text =
      "record_npc_statement(\"Maribel\", \"El forastero salió al norte\"). Maribel dice que no lo vio."

    clean = Dragonex.Text.scrub(text)
    refute clean =~ "record_npc_statement"
    assert clean =~ "Maribel dice que no lo vio."
    assert {:ok, recorded} = World.record_npc_statement("Maribel", text).(world())
    refute hd(recorded.facts) =~ "record_npc_statement"
    assert hd(recorded.facts) =~ "Maribel dice que no lo vio."
  end
end
