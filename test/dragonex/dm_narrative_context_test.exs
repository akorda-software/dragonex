defmodule Dragonex.DMNarrativeContextTest do
  use ExUnit.Case, async: true

  alias Dragonex.{Actions, Brief, Character, DM, Heroes, World}
  alias Dragonex.Test.Narrator
  alias ExAgent.Server

  test "the DM prompt prioritizes the factual sheet without banning narrated gifts" do
    prompt = DM.system_prompt()

    assert prompt =~ "FICHA FACTUAL"
    assert prompt =~ "fighter/Guerrero no es paladín"
    assert prompt =~ "[ESTABLE] no pide salvaciones"
    assert prompt =~ "Puedes narrar regalos"
    assert prompt =~ "solo existe si una herramienta lo aplica"
    refute prompt =~ "elimina las alucinaciones"
  end

  test "TestModel receives the real world brief on a DM agent" do
    w = factual_world()
    prompt = Brief.turn_prompt(w, "dm", "narra el estado")
    agent = DM.new(%Narrator{text: "ok"})

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "dm-narr-#{System.unique_integer([:positive])}"}
      )

    assert {:ok, %{messages: messages}} = Server.chat(server, prompt)
    text = message_text(messages)

    assert text =~ "CA 20 (base 18)"
    assert text =~ "5 temporales"
    assert text =~ "clase fighter/Guerrero"
    assert text =~ "[ESTABLE]"
    assert instructions_text(agent) =~ "FICHA FACTUAL"
  end

  test "TestModel DM receives exhausted points and the slot paid for from those points" do
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
    agent = DM.new(%Narrator{text: "ok"})

    server =
      start_supervised!(
        {Server, agent: agent, agent_id: "dm-pool-#{System.unique_integer([:positive])}"}
      )

    assert {:ok, %{messages: messages}} =
             Server.chat(server, Brief.turn_prompt(paid, "dm", "Describe las reservas."))

    text = message_text(messages)
    assert text =~ "Puntos de hechicería: 0/2"
    assert text =~ "Casillas: N1:4"
    assert paid.characters[sheet.name].sorcery_points == 0
  end

  defp factual_world do
    caster = Character.new(name: "C", class: "cleric", hp: 10, max_hp: 10, ac: 12)

    hero =
      Character.new(
        name: "Aldric",
        race: "human",
        class: "fighter",
        level: 1,
        hp: 12,
        max_hp: 12,
        ac: 18,
        temp_hp: 5
      )

    stable =
      Character.new(
        name: "Brenna",
        race: "human",
        class: "fighter",
        level: 1,
        hp: 0,
        max_hp: 12,
        ac: 16,
        death_saves: %{successes: 3, fails: 0}
      )

    w = World.new(characters: %{"C" => caster, "Aldric" => hero, "Brenna" => stable})
    {:ok, protected} = World.shield_of_faith("C", ["Aldric"]).(w)
    protected
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
