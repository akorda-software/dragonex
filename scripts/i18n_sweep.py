#!/usr/bin/env python3
"""Find user-facing Spanish string literals left outside Gettext (D236).

Heuristic sweep, not a parser: reports literals in lib/ that look like Spanish
prose (accents, ¿¡, or common Spanish words) and are not the msgid of a
dgettext/dngettext call. Skips comments, @doc/@moduledoc blocks, Logger
calls, regexes and sigils. Run: python3 scripts/i18n_sweep.py [paths...]
"""
import json
import re
import sys
from pathlib import Path

SPANISH = re.compile(
    r"[áéíóúñ¿¡]|\b(el|la|los|las|de|del|que|con|para|por|una|un|su|sus|tu|es|está|"
    r"turno|daño|tirada|partida|hechizo|personaje|objetivo|ataque|se|en|ya|sin|al|hay|puede|tiene|no hay|ningún|ninguna)\b",
    re.IGNORECASE,
)
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
SKIP_LINE = re.compile(r"^\s*(#|@doc|@moduledoc|Logger\.|require Logger)")
GETTEXT = re.compile(r"d?n?gettext\(\s*$|d?n?gettext\(\s*\"[^\"]*\",\s*$|d?n?gettext\(")


def known_msgids():
    """Every msgid already extracted (multi-line literals included)."""
    ids = set()
    for pot in Path("priv/gettext").glob("*.pot"):
        text = pot.read_text()
        for block in re.findall(r'^msgid (".*"(?:\n".*")*)', text, re.M):
            ids.add("".join(json.loads(l) for l in block.splitlines()))
    return ids


MSGIDS = None


def is_msgid(text, concatenated=False):
    global MSGIDS
    if MSGIDS is None:
        MSGIDS = known_msgids()
    try:
        literal = json.loads('"' + text + '"')
    except ValueError:
        literal = text
    if literal in MSGIDS:
        return True
    # A piece of a "a" <> "b" chain inside dgettext is a substring of its msgid.
    return concatenated and any(literal in m for m in MSGIDS)


def candidates(path):
    lines = path.read_text().splitlines()
    in_heredoc = False
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.count('"""') % 2 == 1:
            in_heredoc = not in_heredoc
            continue
        if in_heredoc or SKIP_LINE.match(line) or "~r" in line or "~w" in line:
            continue
        previous = lines[number - 2] if number > 1 else ""
        for match in STRING.finditer(line):
            text = match.group(1)
            if len(text) < 4 or " " not in text and not re.search(r"[áéíóúñ¿¡]", text):
                continue
            chained = "<>" in line or previous.rstrip().endswith("<>")
            if not SPANISH.search(text) or is_msgid(text, chained):
                continue
            head = line[: match.start()]
            if "gettext(" in head or GETTEXT.search(previous.strip()) and head.strip() == "":
                continue
            yield number, text


def main():
    roots = [Path(p) for p in sys.argv[1:]] or [Path("lib")]
    total = 0
    for root in roots:
        files = [root] if root.is_file() else sorted(root.rglob("*.ex"))
        for path in files:
            for number, text in candidates(path):
                total += 1
                print(f"{path}:{number}: {text[:110]}")
    print(f"\n{total} candidate literal(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
