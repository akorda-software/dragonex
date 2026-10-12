defmodule DragonexWeb.DiceAssetsTest do
  use DragonexWeb.ConnCase, async: true

  for asset <- ["dic_ex.min.js", "dic_ex.css"] do
    test "#{asset} comes from the resolved package, independent of vendored files" do
      asset = unquote(asset)
      # A stale file remains in priv/static/assets after a different graph was
      # built. The endpoint must serve the dependency's bytes instead.
      expected = File.read!(Application.app_dir(:dic_ex, "priv/static/" <> asset))
      conn = get(build_conn(), "/assets/" <> asset)
      assert conn.status == 200
      assert :crypto.hash(:sha256, conn.resp_body) == :crypto.hash(:sha256, expected)
    end
  end
end
