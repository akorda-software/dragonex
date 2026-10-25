"""JSON-line driver for death_save_journey_test.exs; not a standalone app."""

import json
import re
import sys
import traceback
from pathlib import Path
from urllib.parse import urlparse

from playwright.sync_api import expect, sync_playwright


def main():
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        context = browser.new_context(viewport={"width": 1440, "height": 1000}, locale="es-ES")
        context.tracing.start(screenshots=True, snapshots=True, sources=True)
        page = context.new_page()
        page.set_default_timeout(12000)
        page_errors = []
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        artifacts = None
        steps = []
        trace_stopped = False

        # All application assets are local. Fail closed on accidental external
        # requests; the fixture never uses a provider or a third-party login.
        context.route(
            "**/*",
            lambda route: route.continue_()
            if urlparse(route.request.url).hostname in {"localhost", "127.0.0.1"}
            else route.abort(),
        )

        def connected():
            expect(page.locator("[data-phx-main]")).to_have_class(re.compile(r"phx-connected"))

        def hp(value):
            expect(page.locator(".combat-player-sheet .card.mine .card-stats")).to_contain_text(f"HP {value}/12")

        def dismiss_dice():
            close = page.locator("#dice-close")
            if close.is_visible():
                close.click()
                expect(close).to_have_count(0)

        def capture(step):
            path = artifacts / f"{len(steps) + 1:02d}-{step}.png"
            page.screenshot(path=str(path), full_page=True)
            steps.append({"step": step, "screenshot": str(path)})
            assert not page_errors, page_errors

        def recovered_history():
            rolls = page.locator("#log .msg-roll")
            expect(rolls).to_have_count(2)
            expect(rolls.filter(has_text="salvación de muerte")).to_have_count(1)
            expect(rolls.filter(has_text="salvación de muerte")).to_contain_text("d20:20")
            expect(rolls.filter(has_text="Segundo aliento")).to_have_count(1)
            expect(rolls.filter(has_text="Segundo aliento")).to_contain_text("d10:5")

        try:
            for line in sys.stdin:
                command = json.loads(line)
                step = command["step"]
                try:
                    if step == "open":
                        artifacts = Path(command["artifacts"])
                        artifacts.mkdir(parents=True, exist_ok=True)
                        page.goto(command["url"] + "/login")
                        page.locator("#login-email").fill(command["email"])
                        page.locator("#login-password").fill(command["password"])
                        page.locator("form[action='/login'] button[type=submit]").click()
                        page.wait_for_url(command["url"] + "/")
                        page.goto(f"{command['url']}/games/{command['game_id']}")
                        connected()
                        hp(0)
                        expect(page.locator(".combat-player-sheet .card.mine")).to_contain_text("Caído")
                        expect(page.locator("button[phx-click=resume]")).to_be_visible()
                        capture(step)
                    elif step == "declare":
                        page.locator("button[phx-click=resume]").click()
                        expect(page.locator("#player-input.is-my-turn")).to_be_visible()
                        page.locator("#player-input-text").fill(command["text"])
                        page.locator("#player-input button[type=submit]").click()
                        hp(1)
                        expect(page.locator("button[phx-click=resume]")).to_be_visible()
                        dismiss_dice()
                        expect(page.locator(".combat-player-sheet .card.mine")).not_to_contain_text("Caído")
                        capture(step)
                    elif step == "reload_paid":
                        page.reload()
                        connected()
                        hp(1)
                        expect(page.locator("button[phx-click=resume]")).to_be_visible()
                        capture(step)
                    elif step == "recover":
                        page.reload()
                        connected()
                        hp(1)
                        page.locator("button[phx-click=resume]").click()
                        hp(7)
                        expect(page.locator("button[phx-click=pause]")).to_be_visible()
                        dismiss_dice()
                        expect(page.locator(".combat-player-sheet [data-resource=second-wind]")).to_contain_text("Gastado")
                        recovered_history()
                        capture(step)
                    elif step == "pause_reload":
                        page.locator("button[phx-click=pause]").click()
                        expect(page.locator("button[phx-click=resume]")).to_be_visible()
                        page.reload()
                        connected()
                        hp(7)
                        expect(page.locator("button[phx-click=resume]")).to_be_visible()
                        recovered_history()
                        capture(step)
                    elif step == "final_reload":
                        page.reload()
                        connected()
                        hp(7)
                        expect(page.locator("button[phx-click=resume]")).to_be_visible()
                        expect(page.locator(".combat-player-sheet [data-resource=second-wind]")).to_contain_text("Gastado")
                        recovered_history()
                        capture(step)
                    elif step == "close":
                        context.tracing.stop(path=str(artifacts / "trace.zip"))
                        trace_stopped = True
                        (artifacts / "browser.json").write_text(json.dumps({"steps": steps, "page_errors": page_errors}, indent=2))
                        print(json.dumps({"ok": True, "step": step}), flush=True)
                        break
                    else:
                        raise AssertionError(f"Unknown step: {step}")
                    print(json.dumps({"ok": True, "step": step}), flush=True)
                except Exception:
                    if artifacts:
                        page.screenshot(path=str(artifacts / "failure.png"), full_page=True)
                        context.tracing.stop(path=str(artifacts / "failure-trace.zip"))
                        trace_stopped = True
                    print(json.dumps({"ok": False, "step": step, "error": traceback.format_exc(), "page_errors": page_errors}), flush=True)
                    break
        finally:
            if artifacts and not trace_stopped:
                context.tracing.stop(path=str(artifacts / "failure-trace.zip"))
            context.close()
            browser.close()


if __name__ == "__main__":
    main()
