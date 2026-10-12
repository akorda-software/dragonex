defmodule Dragonex.NarrationPreviewTest do
  use ExUnit.Case, async: true
  alias Dragonex.Narration.Preview

  test "the text field is read as far as it has been generated, envelope or not" do
    assert Preview.text_so_far(~s({"text":"Las ratas)) == "Las ratas"

    assert Preview.text_so_far(~s({"arguments":{"text":"Las ratas chillan"}})) ==
             "Las ratas chillan"

    assert Preview.text_so_far(~s({"arguments":{"te)) == ""
    assert Preview.text_so_far(~s({"text" :  "Hola)) == "Hola"
    assert Preview.text_so_far("") == ""
  end

  test "escapes decode, and an escape cut at the end waits for its next fragment" do
    assert Preview.text_so_far(~s({"text":"—¡Quieto! —dice.\\nY \\"calla\\")) ==
             "—¡Quieto! —dice.\nY \"calla\""

    assert Preview.text_so_far(~s({"text":"a\\)) == "a"
    assert Preview.text_so_far(~s({"text":"a\\u00f)) == "a"
    assert Preview.text_so_far(~s({"text":"a\\u00f1o)) == "año"
    assert Preview.text_so_far(~s({"text":"fin"} )) == "fin"
  end

  test "fragments accumulate per tool call and only new text is emitted" do
    acc = Preview.new()
    {acc, ""} = Preview.push(acc, %{index: 0, name: "final_result", fragment: ""})
    {acc, "La"} = Preview.push(acc, %{index: 0, name: nil, fragment: ~s({"text":"La)})
    {acc, " rata"} = Preview.push(acc, %{index: 0, name: nil, fragment: ~s( rata)})
    {acc, ""} = Preview.push(acc, %{index: 0, name: nil, fragment: ~s("})})

    # Other tools never preview; a new call at the same index starts over.
    {acc, ""} = Preview.push(acc, %{index: 1, name: "make_attack", fragment: ~s({"text":"x"})})
    {acc, ""} = Preview.push(acc, %{index: 0, name: "narrate", fragment: ""})
    assert {_acc, "Otra"} = Preview.push(acc, %{index: 0, name: nil, fragment: ~s({"text":"Otra)})
  end
end
