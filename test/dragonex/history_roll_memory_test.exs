defmodule Dragonex.HistoryRollMemoryTest do
  use ExUnit.Case, async: true

  alias Dragonex.{DM, History}
  alias ExAgent.{Message, Models.Test, Server}
  alias Dragonex.Games.GameEvent
  alias Dragonex.Test.ModelMessages

  defp roll(seq, opts \\ []) do
    %GameEvent{
      type: :dice,
      actor: "Vex",
      seq: seq,
      visible_to: Keyword.get(opts, :visibility, "all"),
      payload: %{
        "who" => "Vex",
        "kind" => "attack",
        "reason" => "ataque a goblin con shortbow",
        "dice" => [[20, 20]],
        "total" => 25,
        "against" => ["ac", 15],
        "outcome" => "crit",
        "round" => 1,
        "phase" => "combat"
      }
    }
  end

  defp current(seq \\ 1000),
    do: [
      %GameEvent{
        type: :narration,
        actor: "Lyra",
        seq: seq,
        payload: %{"text" => "—Prefiero esperar."}
      }
    ]

  defp memory(events, rolls, viewer \\ nil),
    do: History.roll_archive(events, rolls, viewer)

  test "old critical attack and damage are explicitly historical evidence separate from current state" do
    attack = roll(24)

    damage = %{
      roll(25)
      | payload: %{
          "who" => "Vex",
          "kind" => "damage",
          "reason" => "daño piercing a goblin",
          "dice" => [[6, 1], [6, 2], [6, 6], [6, 6]],
          "total" => 18,
          "outcome" => "crit",
          "round" => 1,
          "phase" => "combat"
        }
    }

    for historical <- [
          [attack, damage],
          [attack, damage]
          |> Enum.map(&%{&1 | payload: &1.payload |> Jason.encode!() |> Jason.decode!()})
        ] do
      archive = memory(current(), historical)
      assert archive =~ "ARCHIVO DE TIRADAS"
      assert archive =~ "selección parcial"
      assert archive =~ "no son acciones pendientes"
      assert archive =~ "World vigente"
      assert archive =~ "evento 24 · R1 · combate"
      assert archive =~ "d20:20 +5 = 25 vs CA 15 → ¡CRÍTICO!"
      assert archive =~ "evento 25 · R1 · combate"
      assert archive =~ "d6:1 d6:2 d6:6 d6:6 +3 = 18 → ¡CRÍTICO!"
    end
  end

  test "archive is bounded and chronological after visibility, with no duplicate sequences" do
    public = Enum.map(1..40, &roll/1)
    private = Enum.map(41..90, &roll(&1, visibility: "dm"))
    archive = memory(current(), Enum.reverse(public ++ private) ++ [roll(40)])

    seqs =
      Regex.scan(~r/\[evento (\d+)/, archive, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)

    assert seqs == Enum.to_list(9..40)
    dm_archive = memory(current(), public ++ private, "dm")

    dm_seqs =
      Regex.scan(~r/\[evento (\d+)/, dm_archive, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)

    assert dm_seqs == Enum.to_list(59..90)
  end

  test "recent, unknown, malformed and non-dice entries never become older roll evidence" do
    hidden = roll(1, visibility: "dm")
    unsupported = roll(2, visibility: "Lyra")

    old_prose = %GameEvent{
      seq: 3,
      type: :narration,
      actor: "dm",
      payload: %{"text" => "InventedPastMarker"}
    }

    missing_seq = %{roll(4) | seq: nil}
    invalid_payload = %{roll(5) | payload: nil}
    recent_roll = roll(1000)
    events = [recent_roll | current(1001)]

    assert memory(events, [
             hidden,
             unsupported,
             old_prose,
             missing_seq,
             invalid_payload,
             recent_roll,
             roll(1002)
           ]) ==
             ""

    assert memory([], [roll(1)]) == ""

    assert memory([%{hd(current()) | seq: nil}], [roll(1)]) ==
             ""
  end

  test "the same old roll split from a recent damage group is included once without replay or reordering" do
    attack = roll(24)

    damage = %{
      roll(25)
      | payload: %{
          "who" => "Vex",
          "kind" => "damage",
          "reason" => "daño piercing",
          "dice" => [[6, 4], [6, 4]],
          "total" => 11,
          "outcome" => "crit"
        }
    }

    archive = memory([damage | current(26)], [attack, damage, attack])
    [recent | _] = History.from_events([damage | current(26)]) |> ModelMessages.project()
    assert length(Regex.scan(~r/\[evento 24 ·/, archive)) == 1
    refute archive =~ "daño piercing"
    assert recent["content"] =~ "[🎲 Vex] daño piercing"
    assert recent["content"] =~ "= 11 → ¡CRÍTICO!"
  end

  test "stored death outcomes and a negative damage subtotal survive without recalculating old rules" do
    death = %{
      roll(1)
      | payload: %{
          "kind" => "death_save",
          "reason" => "salvación de muerte",
          "who" => "Thane",
          "dice" => [[20, 1]],
          "total" => 1,
          "outcome" => "crit_fail"
        }
    }

    damage = %{
      roll(2)
      | payload: %{
          "kind" => "damage",
          "who" => "Thane",
          "reason" => "daño del arma",
          "dice" => [[4, 1]],
          "total" => 0,
          "raw_total" => -1,
          "outcome" => "hit"
        }
    }

    archive = memory(current(), [death, damage])
    assert archive =~ "dos fallos de salvación de muerte"
    assert archive =~ "d4:1 -2 = 0 (mínimo 0)"
    assert archive =~ "→ ¡ACIERTO!"
    assert String.valid?(archive)
  end

  test "old roll evidence in the current prompt survives actual compaction and preserves the role prefix" do
    parent = self()

    model = %Test{
      script: [
        fn messages, _ ->
          send(parent, {:archive_compacted_request, ModelMessages.project(messages)})
          Dragonex.Test.Harness.narration("El registro del combate permanece disponible.")
        end
      ]
    }

    agent =
      DM.new(model,
        summarizer: %Test{label: "La taberna está en calma."},
        compaction_threshold: 1,
        compaction_keep_recent: 1
      )

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "archive-compact-#{System.unique_integer([:positive])}"}
      )

    history =
      for n <- 1..20,
          do: Message.new_request([%Message.Part.User{content: "Crónica anterior #{n}"}])

    archive = memory(current(), [roll(24)])

    assert {:ok, _} =
             Dragonex.Agent.chat(server, "WORLD:\nEstado vigente.\n\n" <> archive,
               message_history: history
             )

    assert_receive {:archive_compacted_request, messages}
    assert [%{"role" => "system", "content" => role} | _] = messages
    assert role == DM.system_prompt() <> "\n\n" <> Dragonex.Narration.Contract.instruction()

    assert Enum.any?(
             messages,
             &(&1["content"] =~ "Summary of earlier conversation" and
                 &1["content"] =~ "La taberna está en calma.")
           )

    assert List.last(messages)["role"] == "user"
    assert List.last(messages)["content"] =~ archive
    assert List.last(messages)["content"] =~ "d20:20 +5 = 25 vs CA 15 → ¡CRÍTICO!"
  end
end
