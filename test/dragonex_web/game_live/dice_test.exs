defmodule DragonexWeb.GameLive.DiceTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias DragonexWeb.GameLive.Dice

  defp entry,
    do: %{
      who: "Mara",
      reason: "Investigación",
      dice: [{20, 16}],
      total: 19,
      against: {:dc, 15},
      outcome: :success
    }

  defp socket do
    assign(%Phoenix.LiveView.Socket{},
      dice_hand: [],
      dice_groups: [],
      dice_show: false,
      dice_rolling: false,
      dice_token: 0,
      dice_flush_ref: nil,
      dice_hide_ref: nil,
      dice_hide_token: nil,
      dice_engine: "2d"
    )
  end

  defp flushed do
    {:noreply, s} = Dice.group_landed(socket(), entry())
    {:noreply, s} = Dice.flush(s, s.assigns.dice_token)
    s
  end

  test "a close deadline cannot conceal a roll whose animation is still running" do
    s = flushed()
    assert s.assigns.dice_rolling
    assert {:noreply, ^s} = Dice.hide(s, s.assigns.dice_hide_token)
    Dice.dismiss(%{}, s)
  end

  test "settling cancels fallback; only its replacement generation may close" do
    s = flushed()
    old_ref = s.assigns.dice_hide_ref
    old_token = s.assigns.dice_hide_token
    {:noreply, settled} = Dice.settled(%{}, s)
    assert Process.read_timer(old_ref) == false
    assert is_reference(settled.assigns.dice_hide_token)
    refute old_token == settled.assigns.dice_hide_token
    assert {:noreply, ^settled} = Dice.hide(settled, old_token)
    assert {:noreply, ^settled} = Dice.animation_timeout(settled, old_token)
    {:noreply, closed} = Dice.hide(settled, settled.assigns.dice_hide_token)
    refute closed.assigns.dice_show
    Dice.dismiss(%{}, closed)
  end

  test "an already fired close from an earlier burst cannot hide the next group" do
    first = flushed()
    old_token = first.assigns.dice_hide_token
    {:noreply, next} = Dice.group_landed(first, %{entry() | dice: [{20, 9}], total: 12})
    assert {:noreply, ^next} = Dice.hide(next, old_token)
    assert next.assigns.dice_show
    assert length(next.assigns.dice_groups) == 2
    Dice.dismiss(%{}, next)
  end

  test "dismiss invalidates a cancelled flush already delivered to the mailbox" do
    {:noreply, open} = Dice.group_landed(socket(), entry())
    token = open.assigns.dice_token
    {:noreply, closed} = Dice.dismiss(%{}, open)
    refute closed.assigns.dice_token == token
    assert {:noreply, ^closed} = Dice.flush(closed, token)
  end

  test "a duplicate flush cannot push another tumble or renew its hold" do
    s = flushed()
    assert {:noreply, ^s} = Dice.flush(s, s.assigns.dice_token)
    Dice.dismiss(%{}, s)
  end

  test "client landing faces cannot replace the committed roll or its outcome" do
    s = flushed()
    {:noreply, landed} = Dice.landed(%{"values" => [1]}, s)
    assert landed.assigns.dice_hand == [%{sides: 20, value: 16}]
    assert landed.assigns.dice_groups == [entry()]
    refute landed.assigns.dice_rolling
    Dice.dismiss(%{}, landed)
  end

  test "a settle report carrying an earlier roll's nonce cannot reveal the next one" do
    first = flushed()
    old_nonce = first.assigns.dice_token
    {:noreply, next} = Dice.group_landed(first, %{entry() | dice: [{6, 5}], total: 5})
    {:noreply, next} = Dice.flush(next, next.assigns.dice_token)
    assert {:noreply, ^next} = Dice.settled(%{"nonce" => old_nonce}, next)
    assert {:noreply, ^next} = Dice.landed(%{"values" => [3], "nonce" => old_nonce}, next)
    assert next.assigns.dice_rolling

    {:noreply, done} = Dice.landed(%{"values" => [5], "nonce" => next.assigns.dice_token}, next)
    refute done.assigns.dice_rolling
    Dice.dismiss(%{}, done)
  end

  test "a missing hook reveals the committed result before its reading window closes" do
    s = flushed()
    ref = s.assigns.dice_hide_ref
    assert Process.read_timer(ref) > 9000
    old_token = s.assigns.dice_hide_token
    {:noreply, revealed} = Dice.animation_timeout(s, old_token)
    assert revealed.assigns.dice_show
    refute revealed.assigns.dice_rolling
    assert revealed.assigns.dice_hand == s.assigns.dice_hand
    assert revealed.assigns.dice_groups == s.assigns.dice_groups
    assert Process.read_timer(ref) == false
    refute revealed.assigns.dice_hide_token == old_token
    assert {:noreply, ^revealed} = Dice.hide(revealed, old_token)
    assert {:noreply, ^revealed} = Dice.animation_timeout(revealed, old_token)
    {:noreply, closed} = Dice.hide(revealed, revealed.assigns.dice_hide_token)
    refute closed.assigns.dice_show
    refute closed.assigns.dice_rolling
    assert closed.assigns.dice_groups == []
    assert closed.assigns.dice_hand == []
    assert closed.assigns.dice_flush_ref == nil
    assert closed.assigns.dice_hide_ref == nil
    assert closed.assigns.dice_hide_token == nil
    assert Process.read_timer(ref) == false
  end

  test "late hook callbacks after dismiss or before a new flush do not arm a hold" do
    s = flushed()
    timeout_token = s.assigns.dice_hide_token
    {:noreply, closed} = Dice.dismiss(%{}, s)
    assert {:noreply, ^closed} = Dice.settled(%{}, closed)
    assert {:noreply, ^closed} = Dice.landed(%{"values" => [20]}, closed)
    assert {:noreply, ^closed} = Dice.animation_timeout(closed, timeout_token)
    {:noreply, open} = Dice.group_landed(closed, entry())
    assert {:noreply, ^open} = Dice.settled(%{}, open)
    assert {:noreply, ^open} = Dice.landed(%{"values" => [1]}, open)
    assert {:noreply, ^open} = Dice.animation_timeout(open, timeout_token)
    Dice.dismiss(%{}, open)
  end

  test "an earlier animation deadline cannot reveal the next burst prematurely" do
    first = flushed()
    token = first.assigns.dice_hide_token
    {:noreply, next} = Dice.group_landed(first, %{entry() | dice: [{6, 5}], total: 5})
    {:noreply, next} = Dice.flush(next, next.assigns.dice_token)
    assert {:noreply, ^next} = Dice.animation_timeout(next, token)
    assert next.assigns.dice_rolling
    Dice.dismiss(%{}, next)
  end

  test "the real modal card shows DC or CA from the factual group" do
    json = %{
      "who" => "Mara",
      "dice" => [[20, 16]],
      "total" => 19,
      "against" => ["dc", 15],
      "outcome" => "success"
    }

    for {g, expected} <- [
          {entry(), "vs DC 15"},
          {Map.put(entry(), :against, {:ac, 14}), "vs CA 14"},
          {json, "vs DC 15"}
        ] do
      html = render_component(&Dice.group_card/1, g: g)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".dg-against")
             |> LazyHTML.text()
             |> String.trim() == expected

      assert html =~ "= 19"
    end
  end

  test "labelled keyboard dialog hides while its dic_ex renderer stays mounted" do
    for show <- [true, false] do
      html =
        render_component(&Dice.stage/1,
          show: show,
          rolling: false,
          hand: [],
          groups: [entry()],
          engine: "2d"
        )

      dom = LazyHTML.from_fragment(html)
      assert Enum.count(LazyHTML.query(dom, "#dice-dialog[role=dialog][aria-modal=true]")) == 1

      assert LazyHTML.attribute(LazyHTML.query(dom, "#dice-dialog"), "aria-hidden") == [
               to_string(not show)
             ]

      assert Enum.count(LazyHTML.query(dom, "#dice-stage-2d[phx-hook=DiceRoller2D]")) == 1
      assert Enum.count(LazyHTML.query(dom, "#dice-stage-2d-canvas[phx-update=ignore]")) == 1
      assert Enum.count(LazyHTML.query(dom, "#dice-close")) == if(show, do: 1, else: 0)

      if show do
        assert Enum.count(
                 LazyHTML.query(dom, "[phx-window-keydown=dismiss_dice][phx-key=escape]")
               ) == 1

        assert html =~ "push_focus"
        assert html =~ "pop_focus"
      end
    end
  end
end
