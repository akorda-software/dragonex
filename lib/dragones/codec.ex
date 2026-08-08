defmodule Dragones.Codec do
  @moduledoc """
  Symmetric, field-aware encode/decode between the `Dragones.World` struct tree
  and a JSON-safe plain map.

  Why this exists: `ExAgent.Session` persists `shared_state` through strict JSON
  (`Jason.encode!`), so a struct-based world comes back as a plain map with
  string keys and no `__struct__`. `Dragones.Store.Coded` runs `encode/1` on
  save and `decode/1` on load, so the running game always holds real structs
  while the stored form stays portable.

  Tuples (the world `log`) are encoded as 2-element arrays; atoms (phase,
  abilities, spell kind) as strings. Everything is explicit per field — no
  generic struct-walking heuristic.
  """

  alias Dragones.{Character, Item, Spell, Weapon, World}

  @abilities ~w(str dex con int wis cha)a

  @spec encode(World.t()) :: map()
  def encode(%World{} = w) do
    %{
      "scene" => w.scene,
      "phase" => Atom.to_string(w.phase),
      "round" => w.round,
      "characters" => Map.new(w.characters, fn {name, c} -> {name, encode_character(c)} end),
      "initiative_order" => w.initiative_order,
      "log" => Enum.map(w.log, fn {actor, entry} -> [actor, entry] end),
      "spell_slots" => w.spell_slots,
      "facts" => w.facts
    }
  end

  @spec decode(term()) :: World.t()
  def decode(%World{} = w), do: w

  def decode(%{} = m) do
    %World{
      scene: m["scene"],
      phase: decode_phase(m["phase"]),
      round: m["round"],
      characters: Map.new(m["characters"], fn {name, c} -> {name, decode_character(c)} end),
      initiative_order: m["initiative_order"] || [],
      log: Enum.map(m["log"] || [], fn [actor, entry] -> {actor, entry} end),
      spell_slots: m["spell_slots"] || %{},
      facts: m["facts"] || []
    }
  end

  # ------------------------------------------------------------- character

  @doc """
  Encode a single `Character` sheet to a JSON-safe map, without wrapping it in
  a `World`. Use this for standalone storage (the `characters.sheet` and
  `heroes.sheet` jsonb columns); use `encode/1` for a whole world.
  """
  @spec encode_character(Character.t()) :: map()
  def encode_character(%Character{} = c) do
    %{
      "name" => c.name,
      "race" => c.race,
      "class" => c.class,
      "sex" => c.sex,
      "side" => c.side,
      "level" => c.level,
      "xp" => c.xp,
      "hp" => c.hp,
      "max_hp" => c.max_hp,
      "temp_hp" => c.temp_hp,
      "ac" => c.ac,
      "speed" => c.speed,
      "str" => c.str,
      "dex" => c.dex,
      "con" => c.con,
      "int" => c.int,
      "wis" => c.wis,
      "cha" => c.cha,
      "backstory" => c.backstory,
      "weapons" => Enum.map(c.weapons, &encode_weapon/1),
      "spells" => Enum.map(c.spells, &encode_spell/1),
      "inventory" => Enum.map(c.inventory, &encode_item/1),
      "conditions" => c.conditions,
      "death_saves" => encode_saves(c.death_saves),
      "saving_proficiencies" => c.saving_proficiencies,
      "skill_proficiencies" => c.skill_proficiencies || [],
      "languages" => c.languages || [],
      "racial_traits" => c.racial_traits || [],
      "class_features" => c.class_features || [],
      "background_feature" => c.background_feature
    }
  end

  @doc "Decode a stored sheet map back into a `Character` struct."
  @spec decode_character(map()) :: Character.t()
  def decode_character(%{} = c) do
    %Character{
      name: c["name"],
      race: c["race"],
      class: c["class"],
      sex: c["sex"],
      side: c["side"],
      level: c["level"],
      xp: c["xp"],
      hp: c["hp"],
      max_hp: c["max_hp"],
      temp_hp: c["temp_hp"],
      ac: c["ac"],
      speed: c["speed"],
      str: c["str"],
      dex: c["dex"],
      con: c["con"],
      int: c["int"],
      wis: c["wis"],
      cha: c["cha"],
      backstory: c["backstory"],
      weapons: Enum.map(c["weapons"] || [], &decode_weapon/1),
      spells: Enum.map(c["spells"] || [], &decode_spell/1),
      inventory: Enum.map(c["inventory"] || [], &decode_item/1),
      conditions: c["conditions"] || [],
      death_saves: decode_saves(c["death_saves"]),
      saving_proficiencies: c["saving_proficiencies"] || [],
      skill_proficiencies: c["skill_proficiencies"] || [],
      languages: c["languages"] || [],
      racial_traits: c["racial_traits"] || [],
      class_features: c["class_features"] || [],
      background_feature: c["background_feature"]
    }
  end

  # --------------------------------------------------------------- weapon

  defp encode_weapon(%Weapon{} = w) do
    %{
      "name" => w.name,
      "dice" => w.dice,
      "damage_type" => w.damage_type,
      "attack_ability" => Atom.to_string(w.attack_ability),
      "finesse" => w.finesse,
      "ranged" => w.ranged
    }
  end

  defp decode_weapon(%{} = w) do
    %Weapon{
      name: w["name"],
      dice: w["dice"],
      damage_type: w["damage_type"],
      attack_ability: ability(w["attack_ability"]),
      finesse: w["finesse"],
      ranged: w["ranged"]
    }
  end

  # ---------------------------------------------------------------- spell

  defp encode_spell(%Spell{} = s) do
    %{
      "name" => s.name,
      "level" => s.level,
      "kind" => Atom.to_string(s.kind),
      "casting_ability" => Atom.to_string(s.casting_ability),
      "save_ability" => s.save_ability && Atom.to_string(s.save_ability),
      "dice" => s.dice,
      "damage_type" => s.damage_type,
      "effect" => s.effect
    }
  end

  defp decode_spell(%{} = s) do
    %Spell{
      name: s["name"],
      level: s["level"],
      kind: ability_or_kind(s["kind"]),
      casting_ability: ability(s["casting_ability"]),
      save_ability: s["save_ability"] && ability(s["save_ability"]),
      dice: s["dice"],
      damage_type: s["damage_type"],
      effect: s["effect"]
    }
  end

  # ----------------------------------------------------------------- item

  defp encode_item(%Item{} = i) do
    %{"name" => i.name, "qty" => i.qty, "kind" => Atom.to_string(i.kind)}
  end

  defp decode_item(%{} = i) do
    %Item{name: i["name"], qty: i["qty"], kind: String.to_atom(i["kind"])}
  end

  # -------------------------------------------------------------- helpers

  defp encode_saves(%{successes: s, fails: f}), do: %{"successes" => s, "fails" => f}
  defp decode_saves(nil), do: %{successes: 0, fails: 0}
  defp decode_saves(%{} = s), do: %{successes: s["successes"], fails: s["fails"]}

  defp decode_phase("combat"), do: :combat
  defp decode_phase(_), do: :exploration

  defp ability(name) when name in @abilities, do: name
  defp ability(name) when is_binary(name), do: String.to_atom(name)

  # spell kind shares the ability namespace for :save/:attack/:automatic.
  # Uses to_atom (not to_existing_atom) because the atoms may not be loaded
  # yet when decoding a stored hero sheet early in the app lifecycle.
  defp ability_or_kind(name) when is_binary(name), do: String.to_atom(name)
end
