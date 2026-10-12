defmodule DragonexWeb.PhoenixAssetsTest do
  use DragonexWeb.ConnCase, async: true

  for {application, asset} <- [
        {:phoenix, "phoenix.mjs"},
        {:phoenix_live_view, "phoenix_live_view.esm.js"}
      ] do
    test "#{asset} matches the server package in the current dependency graph" do
      application = unquote(application)
      asset = unquote(asset)
      expected = File.read!(Application.app_dir(application, "priv/static/" <> asset))
      conn = get(build_conn(), "/assets/" <> asset)
      assert conn.status == 200
      assert :crypto.hash(:sha256, conn.resp_body) == :crypto.hash(:sha256, expected)

      assert get_resp_header(conn, "content-type")
             |> Enum.any?(&String.contains?(&1, "javascript"))
    end
  end

  test "the page loads both clients from this server" do
    conn = get(build_conn(), "/")
    assert conn.status == 200
    assert conn.resp_body =~ ~s(import { Socket } from "/assets/phoenix.mjs")
    assert conn.resp_body =~ ~s(import { LiveSocket } from "/assets/phoenix_live_view.esm.js")
    refute conn.resp_body =~ "esm.sh/phoenix"
  end

  # Browsers otherwise request /favicon.ico, a 404 in every page's console.
  test "every page declares a served icon" do
    assert get(build_conn(), "/").resp_body =~
             ~s(<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml")

    conn = get(build_conn(), "/assets/favicon.svg")
    assert conn.status == 200
    assert conn.resp_body =~ "<svg"
  end
end
