#!/usr/bin/env python3
"""Export/merge the English Gettext catalog through JSON chunks (D236).

  export <domain> <chunks> <outdir>   write untranslated entries as JSON chunks
  merge  <domain> <json>...            fill msgstr from translation JSON files
  check  <domain>                      report empty, fuzzy or placeholder-mismatched entries

Translation JSON: {"<id>": "<msgstr>"} or {"<id>": ["<singular>", "<plural>"]}.
Placeholders (%{name}) must match the msgid exactly; mismatches are rejected.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

PO = Path("priv/gettext/en/LC_MESSAGES")
PLACEHOLDER = re.compile(r"%\{(\w+)\}")


def unquote(lines):
    return "".join(json.loads(line) for line in lines)


def quote(text):
    if "\n" not in text[:-1]:
        return [json.dumps(text, ensure_ascii=False)]
    parts = text.split("\n")
    out = ['""']
    for index, part in enumerate(parts):
        piece = part + ("\n" if index < len(parts) - 1 else "")
        if piece:
            out.append(json.dumps(piece, ensure_ascii=False))
    return out


def parse(path):
    """Entries as dicts preserving comments/refs; header is entry 0."""
    entries, current, key = [], {"comments": [], "flags": []}, None
    for line in path.read_text().splitlines():
        if not line.strip():
            if "msgid" in current:
                entries.append(current)
            current, key = {"comments": [], "flags": []}, None
            continue
        if line.startswith("#,"):
            current["flags"] += [f.strip() for f in line[2:].split(",")]
        elif line.startswith("#"):
            current["comments"].append(line)
        elif line.startswith("msgid_plural "):
            key = "msgid_plural"
            current[key] = [line[len("msgid_plural "):]]
        elif line.startswith("msgid "):
            key = "msgid"
            current[key] = [line[len("msgid "):]]
        elif line.startswith("msgstr["):
            index = int(line[7])
            key = ("msgstr", index)
            current.setdefault("msgstr_plural", {})[index] = [line[line.index("]") + 2:]]
        elif line.startswith("msgstr "):
            key = "msgstr"
            current[key] = [line[len("msgstr "):]]
        elif line.startswith('"'):
            if isinstance(key, tuple):
                current["msgstr_plural"][key[1]].append(line)
            else:
                current[key].append(line)
    if "msgid" in current:
        entries.append(current)
    return entries


def render(entries):
    blocks = []
    for e in entries:
        lines = list(e["comments"])
        flags = [f for f in e["flags"] if f]
        if flags:
            lines.append("#, " + ", ".join(flags))
        lines += ["msgid " + l if i == 0 else l for i, l in enumerate(e["msgid"])]
        if "msgid_plural" in e:
            lines += ["msgid_plural " + l if i == 0 else l for i, l in enumerate(e["msgid_plural"])]
            for index in sorted(e["msgstr_plural"]):
                lines += [f"msgstr[{index}] " + l if i == 0 else l
                          for i, l in enumerate(e["msgstr_plural"][index])]
        else:
            lines += ["msgstr " + l if i == 0 else l for i, l in enumerate(e["msgstr"])]
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks) + "\n"


def entry_id(e):
    return hashlib.md5(unquote(e["msgid"]).encode()).hexdigest()[:10]


def translated(e):
    if "msgid_plural" in e:
        return all(unquote(v) for v in e["msgstr_plural"].values()) and "fuzzy" not in e["flags"]
    return bool(unquote(e["msgstr"])) and "fuzzy" not in e["flags"]


def export(domain, chunks, outdir):
    entries = [e for e in parse(PO / f"{domain}.po") if unquote(e["msgid"])]
    todo = [e for e in entries if not translated(e)]
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    size = -(-len(todo) // chunks)
    for n in range(chunks):
        part = todo[n * size:(n + 1) * size]
        data = [{"id": entry_id(e), "msgid": unquote(e["msgid"]),
                 "msgid_plural": unquote(e["msgid_plural"]) if "msgid_plural" in e else None,
                 "refs": [c[3:] for c in e["comments"] if c.startswith("#:")][:3]}
                for e in part]
        (out / f"{domain}-{n + 1}.json").write_text(json.dumps(data, ensure_ascii=False, indent=1))
        print(f"{domain}-{n + 1}.json: {len(part)} entries")


def placeholders(text):
    return sorted(set(PLACEHOLDER.findall(text)))


def merge(domain, files):
    path = PO / f"{domain}.po"
    entries = parse(path)
    translations = {}
    for name in files:
        translations.update(json.loads(Path(name).read_text()))
    filled, rejected = 0, []
    for e in entries:
        msgid = unquote(e["msgid"])
        value = translations.get(entry_id(e)) if msgid else None
        if value is None:
            continue
        expected = placeholders(msgid)
        values = value if isinstance(value, list) else [value]
        if any(placeholders(v) != expected for v in values) or not all(v.strip() for v in values):
            rejected.append((msgid[:70], values))
            continue
        if "msgid_plural" in e:
            if not isinstance(value, list) or len(value) != 2:
                rejected.append((msgid[:70], value))
                continue
            e["msgstr_plural"] = {0: quote(value[0]), 1: quote(value[1])}
        else:
            e["msgstr"] = quote(value if isinstance(value, str) else value[0])
        e["flags"] = [f for f in e["flags"] if f != "fuzzy"]
        filled += 1
    path.write_text(render(entries))
    print(f"{domain}: filled {filled}, rejected {len(rejected)}")
    for msgid, value in rejected:
        print(f"  REJECTED {msgid!r} -> {value!r}")


def check(domain):
    entries = [e for e in parse(PO / f"{domain}.po") if unquote(e["msgid"])]
    bad = [unquote(e["msgid"])[:80] for e in entries if not translated(e)]
    print(f"{domain}: {len(entries)} entries, {len(bad)} untranslated/fuzzy")
    for msgid in bad[:20]:
        print("  -", msgid)
    return len(bad)


if __name__ == "__main__":
    command, domain, *rest = sys.argv[1:]
    if command == "export":
        export(domain, int(rest[0]), rest[1])
    elif command == "merge":
        merge(domain, rest)
    elif command == "check":
        sys.exit(1 if check(domain) else 0)
