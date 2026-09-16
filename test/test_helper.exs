# Opt-in live tests (real LLM calls) are excluded by default.
# Run with: DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=... mix test --include integration
#
# runtime.exs may have loaded .env.dev keys into the VM. Blank them so the
# default suite stays on TestModel (NFR-2). Live runs keep the real keys.
unless System.get_env("DRAGONEX_RUN_LIVE") == "1" do
  System.put_env("OPENROUTER_API_KEY", "")
  System.put_env("OPENCODE_API_KEY", "")

  # Provider knobs too: OPENROUTER_PROVIDER_ORDER blank == unset for
  # `Models.parse_provider_order/1` (blank CSV → [] → nil extra). DRAGONEX_
  # PROVIDER is deleted (not blanked) because a blank value would trip the
  # unknown-provider fallback warning on every Models.provider/0 read.
  System.put_env("OPENROUTER_PROVIDER_ORDER", "")
  System.delete_env("DRAGONEX_PROVIDER")
end

ExUnit.start(exclude: [:integration])
