defmodule Dragonex.PCAgentNarrativeContextTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Brief, Character, Heroes, PCAgent, World}
  alias Dragonex.Test.Narrator
  alias ExAgent.Server

  test "the PC prompt keeps canonical identity and does not treat a narrated gift as applied" do
    sheet = Character.new(name: "Aldric", race: "human", class: "fighter", level: 1)
    prompt = PCAgent.system_prompt(sheet)

    assert prompt =~ "guerrero"
    assert prompt =~ "resumen WORLD manda"
    assert prompt =~ "CA efectiva"
    assert prompt =~ "Narrar un regalo no lo aplica"
    assert prompt =~ "Clase de Armadura base"
  end

  test "a stable PC is not steered into a death save" do
    sheet =
      Character.new(
        name: "Aldric",
        race: "human",
        class: "fighter",
        level: 1,
        hp: 0,
        max_hp: 12,
        death_saves: %{successes: 3, fails: 0}
      )

    instr = PCAgent.instruction("Aldric", sheet, World.new())
    assert instr =~ "ESTABLE"
    refute instr =~ "make_death_save"
  end

  test "TestModel receives the real world brief on a PC agent" do
    sheet =
      Character.new(
        name: "Aldric",
        race: "human",
        class: "fighter",
        level: 1,
        hp: 12,
        max_hp: 12,
        ac: 18
      )

    w = World.new(characters: %{"Aldric" => %{sheet | temp_hp: 5}})
    prompt = Brief.turn_prompt(w, "Aldric", PCAgent.instruction("Aldric", sheet, w))
    agent = PCAgent.new(%Narrator{text: "ok"}, sheet)

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "pc-narr-#{System.unique_integer([:positive])}"}
      )

    assert {:ok, %{messages: messages}} = Server.chat(server, prompt)
    text = message_text(messages)

    assert text =~ "clase fighter/Guerrero"
    assert text =~ "5 temporales"
    assert text =~ "CA 18"
    assert instructions_text(agent) =~ "resumen WORLD manda"
  end

  test "TestModel PC receives the live spent reserve even if its construction sheet had full points" do
    {:ok, sheet} =
      Heroes.build(%{
        name: "Sira",
        race: "human",
        class: "sorcerer",
        level: 2,
        background: "sage"
      })

    w = World.new(characters: %{sheet.name => sheet}) |> World.init_spell_slots()
    {:ok, _, change} = Actions.create_spell_slot(w, sheet.name, 1)
    {:ok, paid} = change.(w)
    agent = PCAgent.new(%Narrator{text: "ok"}, sheet)

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "pc-pool-#{System.unique_integer([:positive])}"}
      )

    prompt =
      Brief.turn_prompt(
        paid,
        sheet.name,
        PCAgent.instruction(sheet.name, paid.characters[sheet.name], paid)
      )

    assert {:ok, %{messages: messages}} = Server.chat(server, prompt)
    text = message_text(messages)
    assert text =~ "Puntos de hechicería: 0/2"
    assert text =~ "Casillas: N1:4"
    assert sheet.sorcery_points == 2
    assert paid.characters[sheet.name].sorcery_points == 0
  end

  defp instructions_text(%{instructions: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{content: content} when is_binary(content) -> content
      _ -> ""
    end)
  end

  defp message_text(messages) do
    Enum.map_join(messages, "\n", fn
      %{parts: parts} when is_list(parts) ->
        Enum.map_join(parts, "\n", fn
          %{content: content} when is_binary(content) -> content
          _ -> ""
        end)

      _ ->
        ""
    end)
  end
end
