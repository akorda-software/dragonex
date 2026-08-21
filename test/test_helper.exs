# Opt-in live tests (real LLM calls) are excluded by default.
# Run with: DRAGONEX_RUN_LIVE=1 OPENROUTER_API_KEY=... mix test --include integration
ExUnit.start(exclude: [:integration])
