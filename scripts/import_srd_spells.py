#!/usr/bin/env python3
"""
Importer del SRD 5.1 (spells) para Dragonex.

Descarga los ~319 hechizos del System Reference Document 5.1 desde la API de
open5e (v2), normaliza sus mecánicas al esquema que usa `Dragonex.Heroes.Spells`
y traduce nombre + descripción al español en lote con un LLM (OpenRouter).

Salida: `priv/srd/spells.es.json` — un array de objetos que el módulo
`Dragonex.Heroes.SRDSpells` carga en tiempo de compilación y el `Catalog`
mezcla con el catálogo builtin.

Requisitos:
  - Python 3 (stdlib: urllib, json)
  - OPENROUTER_API_KEY en el entorno
  - Opcional: TRANSLATE_MODEL (default deepseek/deepseek-v4-flash),
    TRANSLATE_BATCH (default 20)

Es idempotente y reanudable: cachea las traducciones en
`priv/srd/.cache/spells_translations.json`, así re-ejecutar solo traduce lo
nuevo. Se puede forzar re-traducir borrando la cache.

Uso:
  export $(grep OPENROUTER_API_KEY .env | xargs)
  python3 scripts/import_srd_spells.py

  python3 scripts/import_srd_spells.py --english
    Solo rellena `effect_en` (descripción original del SRD) en el JSON
    existente, sin traducir ni tocar el resto de campos (D236). No necesita
    OPENROUTER_API_KEY.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "priv" / "srd" / "spells.es.json"
CACHE = ROOT / "priv" / "srd" / ".cache" / "spells_translations.json"

SRD_DOC_KEY = "srd-2014"
API = "https://api.open5e.com/v2/spells/"
OPENROUTER = "https://openrouter.ai/api/v1/chat/completions"
MODEL = os.environ.get("TRANSLATE_MODEL", "deepseek/deepseek-v4-flash")
BATCH = int(os.environ.get("TRANSLATE_BATCH", "20"))
PAGE_LIMIT = 50

# full-word save ability -> nuestro atom de 3 letras
SAVE_MAP = {
    "strength": "str",
    "dexterity": "dex",
    "constitution": "con",
    "intelligence": "int",
    "wisdom": "wis",
    "charisma": "cha",
}

CLASSES_12 = {
    "barbarian",
    "bard",
    "cleric",
    "druid",
    "fighter",
    "monk",
    "paladin",
    "ranger",
    "rogue",
    "sorcerer",
    "warlock",
    "wizard",
}


# --------------------------------------------------------------- fetch

def _get(url, accept="application/json"):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "dragonex-srd-importer/1.0 (+https://github.com/anomalyco/opencode)",
            "Accept": accept,
        },
    )
    return urllib.request.urlopen(req, timeout=60)


def fetch_all_srd_spells():
    """Pagina la API de open5e y devuelve la lista cruda de hechizos SRD 5.1."""
    out = []
    url = f"{API}?document__key={SRD_DOC_KEY}&limit={PAGE_LIMIT}"
    page = 1
    while url:
        print(f"  fetch page {page}: {url}", file=sys.stderr)
        with _get(url) as r:
            data = json.loads(r.read().decode("utf-8"))
        out.extend(data["results"])
        nxt = data.get("next")
        url = nxt
        page += 1
    return out


# --------------------------------------------------------------- normalize

def normalize(raw: dict) -> dict:
    """Mapea un hechizo de open5e a nuestro esquema (mecánicas, sin traducir)."""
    name_en = raw.get("name", "").strip()
    key = name_en.lower()

    attack = bool(raw.get("attack_roll", False))
    save_raw = (raw.get("saving_throw_ability") or "").strip().lower()
    save_ability = SAVE_MAP.get(save_raw)

    if attack:
        kind = "attack"
    elif save_ability:
        kind = "save"
    else:
        kind = "automatic"

    dice = (raw.get("damage_roll") or "").strip() or None
    dmg_types = raw.get("damage_types") or []
    damage_type = dmg_types[0].lower() if dmg_types else None

    classes = []
    for c in raw.get("classes") or []:
        ck = (c.get("key") or "").replace("srd_", "")
        if ck in CLASSES_12:
            classes.append(ck)

    school = ((raw.get("school") or {}).get("name") or "").lower()

    return {
        "key": key,
        "name": name_en,
        "level": int(raw.get("level", 0) or 0),
        "school": school,
        "kind": kind,
        "save_ability": save_ability,
        "dice": dice,
        "damage_type": damage_type,
        "desc_en": (raw.get("desc") or "").strip(),
        "classes": classes,
        "range_text": raw.get("range_text") or "",
        "casting_time": raw.get("casting_time") or "",
        "duration": raw.get("duration") or "",
        "concentration": bool(raw.get("concentration", False)),
        "ritual": bool(raw.get("ritual", False)),
    }


# --------------------------------------------------------------- translate

def load_cache() -> dict:
    if CACHE.exists():
        return json.loads(CACHE.read_text("utf-8"))
    return {}


def save_cache(cache: dict) -> None:
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), "utf-8")


def call_llm(batch: list[dict]) -> dict:
    """
    Traduce un lote de {key, name, desc} -> {key: {name_es, desc_es}}.
    Reintenta hasta 3 veces si el JSON de respuesta no parsea.
    """
    sys_prompt = (
        "Eres traductor experto en D&D 5e (SRD 5.1 al español). "
        "Recibes una lista de hechizos en inglés. Para cada uno devuelve el "
        "NOMBRE canónico en español del SRD 5.1 (p.ej. 'Fireball' -> 'Bola de fuego', "
        "'Magic Missile' -> 'Proyectil mágico', 'Misty Step' -> 'Paso brumoso') y "
        "la DESCRIPCIÓN traducida fielmente al español, manteniendo las mecánicas "
        "(dados, distancias en pies, condiciones, tipos de daño). "
        "No añadas notas; traduce solo. Devuelve un único objeto JSON."
    )
    user_prompt = (
        "Traduce estos hechizos. Devuelve EXACTAMENTE este formato JSON:\n"
        '{"<key>": {"name": "<nombre en español>", "desc": "<descripción en español>"}, ...}\n\n'
        "Hechizos:\n"
        + json.dumps(batch, ensure_ascii=False)
    )

    payload = {
        "model": MODEL,
        "temperature": 0.2,
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
    }

    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        sys.exit("ERROR: falta OPENROUTER_API_KEY en el entorno")

    req = urllib.request.Request(
        OPENROUTER,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    last_err = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                data = json.loads(r.read().decode("utf-8"))
            content = data["choices"][0]["message"]["content"].strip()
            content = _strip_fences(content)
            return json.loads(content)
        except Exception as e:  # noqa: BLE001
            last_err = e
            print(f"    llm attempt {attempt + 1} failed: {e}", file=sys.stderr)
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"LLM falló tras reintentos: {last_err}")


def _strip_fences(text: str) -> str:
    t = text.strip()
    if t.startswith("```"):
        # quita ```json ... ``` o ``` ... ```
        t = t.split("\n", 1)[1] if t.startswith("```") and "\n" in t else t[3:]
        if t.endswith("```"):
            t = t[: -3]
    return t.strip()


def translate_missing(spells: list[dict], cache: dict) -> dict:
    """Traduce solo las keys que faltan en cache; devuelve cache actualizado."""
    pending = [s for s in spells if s["key"] not in cache]
    print(f"  traducir: {len(pending)} nuevos ({len(spells) - len(pending)} en cache)", file=sys.stderr)

    total_batches = (len(pending) + BATCH - 1) // BATCH
    for i in range(0, len(pending), BATCH):
        chunk = pending[i : i + BATCH]
        batch_payload = [{"key": s["key"], "name": s["name"], "desc": s["desc_en"]} for s in chunk]
        b = i // BATCH + 1
        print(f"    batch {b}/{total_batches} ({len(chunk)} hechizos) [cache={len(cache)}]", file=sys.stderr)
        translated = call_llm(batch_payload)
        for s in chunk:
            t = translated.get(s["key"])
            if not t:
                # el modelo puede haber devuelto el nombre en vez del key; busca por nombre
                t = translated.get(s["name"]) or translated.get(s["name"].lower())
            if t and t.get("name"):
                cache[s["key"]] = {
                    "name_es": t["name"].strip(),
                    "desc_es": (t.get("desc") or "").strip(),
                }
            else:
                # fallback: nombre original, desc original (mejor que perderlo)
                cache[s["key"]] = {"name_es": s["name"], "desc_es": s["desc_en"]}
                print(f"      sin traducción para {s['key']}, fallback", file=sys.stderr)
        save_cache(cache)  # resumible
        # escribe salida parcial tras cada lote (utilizable aunque se interrumpa)
        _write_output(spells, cache)
    return cache


# --------------------------------------------------------------- build output

def build_output(spells: list[dict], cache: dict) -> list[dict]:
    out = []
    for s in spells:
        t = cache.get(s["key"], {})
        out.append(
            {
                "key": s["key"],
                "name": s["name"],  # inglés, stable key interna
                "name_es": t.get("name_es") or s["name"],
                "level": s["level"],
                "school": s["school"],
                "kind": s["kind"],
                "save_ability": s["save_ability"],
                "dice": s["dice"],
                "damage_type": s["damage_type"],
                "effect": t.get("desc_es") or s["desc_en"],  # descripción en español
                "effect_en": s["desc_en"],  # descripción original del SRD (D236)
                "classes": s["classes"],
                "range": s["range_text"],
                "casting_time": s["casting_time"],
                "duration": s["duration"],
                "concentration": s["concentration"],
                "ritual": s["ritual"],
                "source": "srd",
            }
        )
    # orden estable: por nivel y luego nombre
    out.sort(key=lambda x: (x["level"], x["name"].lower()))
    return out


# --------------------------------------------------------------- main

def _write_output(spells: list[dict], cache: dict) -> None:
    out = build_output(spells, cache)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), "utf-8")
    return None


def add_english() -> None:
    """Rellena `effect_en` en el JSON existente sin re-traducir nada."""
    english = {}
    for r in fetch_all_srd_spells():
        s = normalize(r)
        if s["key"] and s["desc_en"]:
            english[s["key"]] = s["desc_en"]
    out = json.loads(OUT.read_text("utf-8"))
    missing = []
    for entry in out:
        desc = english.get(entry["key"])
        if desc:
            entry["effect_en"] = desc
        else:
            missing.append(entry["key"])
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), "utf-8")
    print(f"==> effect_en en {len(out) - len(missing)}/{len(out)} hechizos", file=sys.stderr)
    for key in missing:
        print(f"    sin descripción inglesa: {key}", file=sys.stderr)


def main():
    if "--english" in sys.argv[1:]:
        add_english()
        return
    print("==> descargando SRD 5.1 spells…", file=sys.stderr)
    raw = fetch_all_srd_spells()
    print(f"==> {len(raw)} hechizos crudos", file=sys.stderr)

    spells = [normalize(r) for r in raw]
    # sanity: descarta entradas sin nombre/desc
    spells = [s for s in spells if s["key"] and s["desc_en"]]

    cache = load_cache()
    cache = translate_missing(spells, cache)

    _write_output(spells, cache)
    out = json.loads(OUT.read_text("utf-8"))
    print(f"==> escrito {OUT} ({len(out)} hechizos)", file=sys.stderr)
    print(f"    nivel 0 (trucos): {sum(1 for s in out if s['level'] == 0)}", file=sys.stderr)
    print(f"    nivel 1: {sum(1 for s in out if s['level'] == 1)}", file=sys.stderr)


if __name__ == "__main__":
    main()
