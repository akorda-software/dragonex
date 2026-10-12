defmodule Dragonex.Codec do
  @moduledoc """
  Symmetric, field-aware encode/decode between the `Dragonex.World` struct tree
  and a JSON-safe plain map.

  Why this exists: `ExAgent.Session` persists `shared_state` through strict JSON
  (`Jason.encode!`), so a struct-based world comes back as a plain map with
  string keys and no `__struct__`. `Dragonex.Store.Coded` runs `encode/1` on
  save and `decode/1` on load, so the running game always holds real structs
  while the stored form stays portable.

  Tuples (the world `log`) are encoded as 2-element arrays; atoms (phase,
  abilities, spell kind) as strings. Everything is explicit per field — no
  generic struct-walking heuristic.
  """

  alias Dragonex.{Character, Item, Spell, Weapon, World}

  @abilities ~w(str dex con int wis cha)a

  @spec encode(World.t()) :: map()
  def encode(%World{} = w) do
    %{
      "scene" => w.scene,
      "scene_refresh_pending" => Map.get(w, :scene_refresh_pending, false),
      "actor_checkpoint" => Map.get(w, :actor_checkpoint),
      "wait_resolution" => Map.get(w, :wait_resolution),
      "phase" => Atom.to_string(w.phase),
      "round" => w.round,
      "characters" => Map.new(w.characters, fn {name, c} -> {name, encode_character(c)} end),
      "absent_characters" => Map.get(w, :absent_characters, %{}),
      "conversation" => Map.get(w, :conversation),
      "initiative_order" => w.initiative_order,
      "log" => Enum.map(w.log, fn {actor, entry} -> [actor, entry] end),
      "spell_slots" => w.spell_slots,
      "facts" => w.facts,
      "acted_this_round" => encode_acted(w.acted_this_round),
      "current_combatant" => w.current_combatant,
      "pending_turn" => Map.get(w, :pending_turn),
      "turn_state" => w.turn_state,
      "turn_kind" => w.turn_kind,
      "turn_owner" => w.turn_owner,
      "rest_state" => w.rest_state,
      "elapsed_seconds" => w.elapsed_seconds,
      "effect_expiries" => w.effect_expiries
    }
  end

  @spec decode(term()) :: World.t()
  def decode(%World{} = w), do: w

  # A nullable games.world column (or a freshly-created row) must not crash
  # rehydrate — return a pristine world instead.
  def decode(nil), do: %World{}

  def decode(%{} = m) do
    w = %World{
      scene: m["scene"],
      actor_checkpoint: if(is_map(m["actor_checkpoint"]), do: m["actor_checkpoint"], else: nil),
      wait_resolution: decode_wait_resolution(m["wait_resolution"]),
      scene_refresh_pending:
        Map.get(
          m,
          "scene_refresh_pending",
          (m["elapsed_seconds"] || 0) > 0 or (m["facts"] || []) != []
        ) == true,
      phase: decode_phase(m["phase"]),
      round: m["round"],
      characters: Map.new(m["characters"], fn {name, c} -> {name, decode_character(c)} end),
      absent_characters:
        if(is_map(m["absent_characters"]), do: m["absent_characters"], else: %{}),
      conversation: Dragonex.Conversation.decode(m["conversation"]),
      initiative_order: m["initiative_order"] || [],
      log: Enum.map(m["log"] || [], fn [actor, entry] -> {actor, entry} end),
      spell_slots: decode_spell_slots(m["spell_slots"]),
      facts: m["facts"] || [],
      acted_this_round: decode_acted(m["acted_this_round"]),
      current_combatant: m["current_combatant"],
      pending_turn: decode_pending_turn(m["pending_turn"], m),
      turn_state: m["turn_state"] || %{},
      turn_kind: m["turn_kind"] || "main",
      turn_owner: Map.get(m, "turn_owner", m["current_combatant"]),
      rest_state: m["rest_state"] || %{},
      elapsed_seconds: m["elapsed_seconds"] || 0,
      effect_expiries: m["effect_expiries"] || %{}
    }

    if Map.has_key?(m, "effect_expiries"), do: w, else: Dragonex.WorldClock.seed_legacy(w)
  end

  defp decode_wait_resolution(
         %{
           "source_turn_id" => source,
           "declared_seconds" => declared,
           "elapsed_seconds" => elapsed,
           "clock_before" => before,
           "clock_after" => after_clock
         } = receipt
       )
       when is_binary(source) and source != "" and is_integer(declared) and declared > 0 and
              declared <= 86400 and is_integer(elapsed) and elapsed >= 0 and elapsed <= declared and
              is_integer(before) and before >= 0 and after_clock == before + elapsed do
    decoded =
      Map.take(
        receipt,
        ~w(source_turn_id declared_seconds elapsed_seconds clock_before clock_after)
      )

    case receipt["scene_review_fingerprint"] do
      fingerprint when is_binary(fingerprint) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
          do: Map.put(decoded, "scene_review_fingerprint", fingerprint),
          else: decoded

      _ ->
        decoded
    end
  end

  defp decode_wait_resolution(_), do: nil

  defp decode_pending_turn(%{"combatant" => name, "kind" => kind}, world)
       when is_binary(name) and kind in ["main", "reaction"] do
    if world["phase"] == "combat" and Map.has_key?(world["characters"] || %{}, name) and
         not Map.has_key?(world["absent_characters"] || %{}, name),
       do: %{"combatant" => name, "kind" => kind}
  end

  defp decode_pending_turn(_, _), do: nil

  defp encode_acted(%MapSet{} = set), do: MapSet.to_list(set)
  defp encode_acted(list) when is_list(list), do: list
  defp encode_acted(_), do: []

  defp decode_acted(list) when is_list(list), do: MapSet.new(list)
  defp decode_acted(%MapSet{} = set), do: set
  defp decode_acted(_), do: MapSet.new()

  # spell_slots is %{name => %{level => count}} with INTEGER level keys at
  # runtime (World.has_slot?/consume_slot look up by integer). JSON/jsonb turns
  # those keys into strings ("1", "2"…), so a world rehydrated from Postgres
  # would silently report zero slots and block all casting. Re-integerize here.
  defp decode_spell_slots(slots) when is_map(slots) do
    Map.new(slots, fn {name, levels} ->
      {name, decode_slot_levels(levels)}
    end)
  end

  defp decode_spell_slots(_), do: %{}

  defp decode_slot_levels(levels) when is_map(levels) do
    Map.new(levels, fn {key, count} -> {to_slot_level(key), count} end)
  end

  defp decode_slot_levels(_), do: %{}

  defp to_slot_level(key) when is_binary(key) do
    case Integer.parse(key) do
      {n, ""} -> n
      _ -> key
    end
  end

  defp to_slot_level(key), do: key

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
      "concentrating" => c.concentrating,
      "raging" => c.raging == true,
      "reckless" => c.reckless == true,
      "second_wind_used" => c.second_wind_used == true,
      "action_surge_used" => c.action_surge_used == true,
      "fighting_style" => encode_fighting_style(c.fighting_style),
      "smite_slot" => encode_smite_slot(c.smite_slot),
      "lay_on_hands_pool" => c.lay_on_hands_pool || 0,
      "bardic_inspiration_uses" => c.bardic_inspiration_uses || 0,
      "inspired" => c.inspired == true,
      "arcane_recovery_used" => c.arcane_recovery_used == true,
      "divine_sense_uses" => c.divine_sense_uses || 0,
      "channel_divinity_used" => c.channel_divinity_used == true,
      "ki" => c.ki || 0,
      "sorcery_points" => c.sorcery_points || 0,
      "wild_shape_uses" => c.wild_shape_uses || 0,
      "wild_shape" => encode_wild_shape(c.wild_shape),
      "uncanny_dodge" => c.uncanny_dodge == true,
      "relentless_endurance_used" => c.relentless_endurance_used == true,
      "indomitable_used" => c.indomitable_used == true,
      "metamagic" => encode_metamagic(c.metamagic),
      "breath_weapon_used" => c.breath_weapon_used == true,
      "rage_uses_used" => c.rage_uses_used || 0,
      "relentless_rage_successes" => c.relentless_rage_successes || 0,
      "damage_resistances" => c.damage_resistances || [],
      "damage_vulnerabilities" => c.damage_vulnerabilities || [],
      "damage_immunities" => c.damage_immunities || [],
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
      "expertise" => c.expertise || [],
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
      level: c["level"] || 1,
      xp: c["xp"] || 0,
      hp: c["hp"] || 0,
      max_hp: c["max_hp"] || 0,
      temp_hp: c["temp_hp"] || 0,
      concentrating: c["concentrating"],
      raging: c["raging"] == true,
      reckless: c["reckless"] == true,
      second_wind_used: c["second_wind_used"] == true,
      action_surge_used: c["action_surge_used"] == true,
      fighting_style: decode_fighting_style(c["fighting_style"]),
      smite_slot: decode_smite_slot(c["smite_slot"]),
      lay_on_hands_pool: decode_lay_on_hands_pool(c["lay_on_hands_pool"]),
      bardic_inspiration_uses: decode_bardic_inspiration_uses(c["bardic_inspiration_uses"]),
      inspired: c["inspired"] == true,
      arcane_recovery_used: c["arcane_recovery_used"] == true,
      divine_sense_uses: decode_divine_sense_uses(c["divine_sense_uses"]),
      channel_divinity_used: c["channel_divinity_used"] == true,
      ki: decode_ki(c["ki"]),
      sorcery_points: decode_sorcery_points(c["sorcery_points"]),
      wild_shape_uses: decode_wild_shape_uses(c["wild_shape_uses"]),
      wild_shape: decode_wild_shape(c["wild_shape"]),
      uncanny_dodge: c["uncanny_dodge"] == true,
      relentless_endurance_used: c["relentless_endurance_used"] == true,
      indomitable_used: c["indomitable_used"] == true,
      metamagic: decode_metamagic(c["metamagic"]),
      breath_weapon_used: c["breath_weapon_used"] == true,
      rage_uses_used: decode_rage_uses_used(c["rage_uses_used"]),
      relentless_rage_successes: decode_relentless_rage_successes(c["relentless_rage_successes"]),
      damage_resistances: c["damage_resistances"] || [],
      damage_vulnerabilities: c["damage_vulnerabilities"] || [],
      damage_immunities: c["damage_immunities"] || [],
      ac: c["ac"] || 10,
      speed: c["speed"] || 30,
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
      # D73: jsonb viejo/ausente/malformado → [] (patrón arrays del codec).
      expertise: c["expertise"] || [],
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

  @fighting_styles ~w(archery defense dueling)

  defp encode_fighting_style(s) when s in @fighting_styles, do: s
  defp encode_fighting_style(_), do: nil

  defp decode_fighting_style(s) when s in @fighting_styles, do: s
  defp decode_fighting_style(_), do: nil

  defp encode_smite_slot(n) when is_integer(n) and n in 1..5, do: n
  defp encode_smite_slot(_), do: nil

  defp decode_smite_slot(n) when is_integer(n) and n in 1..5, do: n
  defp decode_smite_slot(_), do: nil

  defp decode_lay_on_hands_pool(n) when is_integer(n) and n >= 0, do: n
  defp decode_lay_on_hands_pool(_), do: 0

  defp decode_bardic_inspiration_uses(n) when is_integer(n) and n >= 0, do: n
  defp decode_bardic_inspiration_uses(_), do: 0

  defp decode_divine_sense_uses(n) when is_integer(n) and n >= 0, do: n
  defp decode_divine_sense_uses(_), do: 0

  defp decode_ki(n) when is_integer(n) and n >= 0, do: n
  defp decode_ki(_), do: 0

  defp decode_sorcery_points(n) when is_integer(n) and n >= 0, do: n
  defp decode_sorcery_points(_), do: 0

  defp decode_wild_shape_uses(n) when is_integer(n) and n >= 0, do: n
  defp decode_wild_shape_uses(_), do: 0

  # D72: jsonb viejo/ausente/malformado → 0 (patrón decode_ki).
  defp decode_rage_uses_used(n) when is_integer(n) and n >= 0, do: n
  defp decode_rage_uses_used(_), do: 0

  defp decode_relentless_rage_successes(n) when is_integer(n) and n >= 0, do: n
  defp decode_relentless_rage_successes(_), do: 0

  # D63 Wild Shape: atom keys in memory, string keys in the stored map.
  # nil (or anything malformed / absent in an old jsonb) → forma normal.
  defp encode_wild_shape(nil), do: nil

  defp encode_wild_shape(%{} = ws) do
    %{
      "beast" => ws[:beast],
      "orig_str" => ws[:orig_str],
      "orig_dex" => ws[:orig_dex],
      "orig_con" => ws[:orig_con],
      "orig_hp" => ws[:orig_hp],
      "orig_max_hp" => ws[:orig_max_hp],
      "orig_ac" => ws[:orig_ac],
      "orig_weapons" => Enum.map(ws[:orig_weapons] || [], &encode_weapon/1)
    }
  end

  defp encode_wild_shape(_), do: nil

  defp decode_wild_shape(nil), do: nil

  defp decode_wild_shape(%{} = ws) do
    %{
      beast: ws["beast"],
      orig_str: ws["orig_str"],
      orig_dex: ws["orig_dex"],
      orig_con: ws["orig_con"],
      orig_hp: ws["orig_hp"],
      orig_max_hp: ws["orig_max_hp"],
      orig_ac: ws["orig_ac"],
      orig_weapons: Enum.map(ws["orig_weapons"] || [], &decode_weapon/1)
    }
  end

  defp decode_wild_shape(_), do: nil

  # D65 Metamagic: atom keys in memory, string keys in the stored map.
  # nil (or anything malformed / absent in an old jsonb) → sin armar.
  defp encode_metamagic(nil), do: nil

  defp encode_metamagic(%{} = mm) do
    case mm[:option] do
      opt when opt in ~w(empowered heightened twinned) ->
        %{"option" => opt, "target" => mm[:target]}

      _ ->
        nil
    end
  end

  defp encode_metamagic(_), do: nil

  defp decode_metamagic(nil), do: nil

  defp decode_metamagic(%{} = mm) do
    case mm["option"] do
      opt when opt in ~w(empowered heightened twinned) ->
        %{option: opt, target: mm["target"]}

      _ ->
        nil
    end
  end

  defp decode_metamagic(_), do: nil

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
