defmodule Dragonex.Heroes.Spells do
  @moduledoc """
  SRD 5.1 spell data (cantrips + 1st-level) for level-1 casters.

  Cada entrada lleva las **mecánicas** que el `Dragonex.Spell` y el motor de
  combate necesitan, **excepto** `casting_ability` — lo fija el builder desde la
  clase, pues un mismo hechizo lo pueden lanzar clases con características
  distintas.

  `classes:` indica qué clases pueden elegir el hechizo (lista SRD). El creador
  lo usa para ofrecer solo los hechizos válidos de cada clase — y para que el
  importer del SRD completo pueda inyectar más hechizos con sus propias listas.

  `kind` sigue a `Dragonex.Spell`:
    * `:save`      — el objetivo tira salvación vs `spell_save_dc`.
    * `:attack`    — el conjurador tira ataque mágico vs CA.
    * `:automatic` — sin tirada (magic missile, mejoras, curaciones).

  Solo los hechizos relevantes en combate llevan `dice`/`damage_type`; los de
  utilidad los omiten (el motor trata nil-dice como 0 daño).
  """

  @type kind :: :save | :attack | :automatic

  @type ability :: :str | :dex | :con | :int | :wis | :cha

  @type spell_data :: %{
          name: String.t(),
          level: non_neg_integer(),
          kind: kind(),
          save_ability: ability() | nil,
          dice: String.t() | nil,
          damage_type: String.t() | nil,
          effect: String.t() | nil,
          classes: [String.t()]
        }

  @doc "Look up a spell by name (case-insensitive)."
  @spec get(String.t()) :: spell_data() | nil
  def get(name) when is_binary(name) do
    normalized = String.downcase(name)
    Enum.find(all(), &(String.downcase(&1.name) == normalized))
  end

  @doc """
  Does this spell require concentration (D37)?

  Builtin entries without a flag are not concentration unless the SRD map
  carries `concentration: true` (SRD wins when the key is present).
  """
  @spec concentration?(String.t()) :: boolean()
  def concentration?(name) when is_binary(name) do
    case get(name) do
      %{concentration: true} -> true
      %{concentration: false} -> false
      data when is_map(data) -> srd_concentration?(name)
      nil -> srd_concentration?(name)
    end
  end

  @doc """
  Resolve a spell key: `custom_*` looks in the injected bundle, everything else
  falls through to the builtin/SRD catalogue.
  """
  @spec resolve(term(), map()) :: spell_data() | nil
  def resolve(name, custom \\ %{}) do
    name = to_string(name)

    if String.starts_with?(name, "custom_") do
      case Enum.find(custom[:spells] || [], &(&1.key == name)) do
        nil -> nil
        %{name: n, definition: d} -> from_custom_def(n, d)
      end
    else
      get(name)
    end
  end

  @doc "Turn catalogue/custom spell data into a `Dragonex.Spell` for the sheet."
  @spec to_character_spell(spell_data(), atom()) :: Dragonex.Spell.t()
  def to_character_spell(data, casting_ability) do
    %Dragonex.Spell{
      name: data.name,
      level: data.level,
      kind: data.kind,
      casting_ability: casting_ability,
      save_ability: data.save_ability,
      dice: data.dice,
      damage_type: data.damage_type,
      effect: data.effect
    }
  end

  defp from_custom_def(name, d) do
    save = Dragonex.MapUtil.get(d, "save_ability")

    %{
      name: name,
      level: Dragonex.MapUtil.get(d, "level"),
      kind: Dragonex.MapUtil.to_atom(Dragonex.MapUtil.get(d, "kind")),
      save_ability: save && Dragonex.MapUtil.to_atom(save),
      dice: Dragonex.MapUtil.get(d, "dice"),
      damage_type: Dragonex.MapUtil.get(d, "damage_type"),
      effect: Dragonex.MapUtil.get(d, "effect")
    }
  end

  @doc "All spells available to a given class key (any level)."
  @spec by_class(String.t()) :: [spell_data()]
  def by_class(class_key) when is_binary(class_key) do
    Enum.filter(all(), fn s -> class_key in s.classes end)
  end

  @doc "All spell data entries (builtin + SRD import, builtin wins on duplicates)."
  @spec all() :: [spell_data()]
  def all, do: merge(builtin(), Dragonex.Heroes.SRDSpells.all())

  @doc "The hand-curated builtin entries (mechanics overrides, take precedence)."
  @spec builtin() :: [spell_data()]
  def builtin do
    # --- cantrips ---
    [
      %{
        name: "fire bolt",
        level: 0,
        kind: :attack,
        save_ability: nil,
        dice: "1d10",
        damage_type: "fire",
        effect: "A streak of flame to a creature or object.",
        classes: ~w(sorcerer wizard)
      },
      %{
        name: "ray of frost",
        level: 0,
        kind: :attack,
        save_ability: nil,
        dice: "1d8",
        damage_type: "cold",
        effect: "A frigid beam; target's speed drops 10 ft.",
        classes: ~w(sorcerer wizard)
      },
      %{
        name: "acid splash",
        level: 0,
        kind: :save,
        save_ability: :dex,
        dice: "1d6",
        damage_type: "acid",
        effect: "A splash of acid at a creature.",
        classes: ~w(sorcerer wizard)
      },
      %{
        name: "sacred flame",
        level: 0,
        kind: :save,
        save_ability: :dex,
        dice: "1d8",
        damage_type: "radiant",
        effect: "Radiant light; no cover bonus.",
        classes: ~w(cleric)
      },
      %{
        name: "vicious mockery",
        level: 0,
        kind: :save,
        save_ability: :wis,
        dice: "1d4",
        damage_type: "psychic",
        effect: "Target has disadvantage on its next attack.",
        classes: ~w(bard)
      },
      %{
        name: "produce flame",
        level: 0,
        kind: :attack,
        save_ability: nil,
        dice: "1d8",
        damage_type: "fire",
        effect: "A flickering flame in your palm; can be hurled.",
        classes: ~w(druid)
      },
      %{
        name: "eldritch blast",
        level: 0,
        kind: :attack,
        save_ability: nil,
        dice: "1d10",
        damage_type: "force",
        effect: "A beam of crackling energy.",
        classes: ~w(warlock)
      },
      %{
        name: "light",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "An object shines bright light for 1 hour.",
        classes: ~w(bard cleric sorcerer wizard)
      },
      %{
        name: "mage hand",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "A spectral hand to manipulate objects.",
        classes: ~w(bard sorcerer warlock wizard)
      },
      %{
        name: "prestidigitation",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "A minor magical effect.",
        classes: ~w(bard sorcerer warlock wizard)
      },
      %{
        name: "druidcraft",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "A tiny omen or natural sensory effect.",
        classes: ~w(druid)
      },
      %{
        name: "guidance",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Target adds 1d4 to one ability check.",
        classes: ~w(cleric druid)
      },
      %{
        name: "thaumaturgy",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "A minor wonder — voice, sound, flame.",
        classes: ~w(cleric)
      },
      %{
        name: "minor illusion",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "A sound or image within 30 ft.",
        classes: ~w(bard sorcerer warlock wizard)
      },
      %{
        name: "shillelagh",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Your club or quarterstaff uses WIS and deals 1d8.",
        classes: ~w(druid)
      },
      %{
        name: "dancing lights",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Four torches of light that move at will.",
        classes: ~w(bard sorcerer wizard)
      },
      %{
        name: "resistance",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Target subtracts 1d4 from one saving throw.",
        classes: ~w(cleric druid)
      },
      %{
        name: "spare the dying",
        level: 0,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "A creature at 0 hp stabilizes.",
        classes: ~w(cleric)
      },
      # --- 1st level ---
      %{
        name: "magic missile",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: "3d4+3",
        damage_type: "force",
        effect: "Three darts of force; each deals 1d4+1 and always hits.",
        classes: ~w(sorcerer wizard)
      },
      %{
        name: "shield",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Reaction; +5 AC until the start of your next turn.",
        classes: ~w(sorcerer wizard)
      },
      %{
        name: "mage armor",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Target gains AC 13 + dex for 8 hours.",
        classes: ~w(sorcerer wizard)
      },
      %{
        name: "burning hands",
        level: 1,
        kind: :save,
        save_ability: :dex,
        dice: "3d6",
        damage_type: "fire",
        effect: "A 15-ft cone of fire.",
        classes: ~w(sorcerer wizard)
      },
      %{
        name: "thunderwave",
        level: 1,
        kind: :save,
        save_ability: :con,
        dice: "2d8",
        damage_type: "thunder",
        effect: "A wave of force; pushes targets 10 ft on a fail.",
        classes: ~w(druid sorcerer wizard)
      },
      %{
        name: "charm person",
        level: 1,
        kind: :save,
        save_ability: :wis,
        dice: nil,
        damage_type: nil,
        effect: "Target regards you as a friendly acquaintance for 1 hour.",
        classes: ~w(bard druid sorcerer warlock wizard)
      },
      %{
        name: "sleep",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: "5d8",
        damage_type: nil,
        effect: "Creatures in an area fall asleep by HP pool.",
        classes: ~w(bard sorcerer wizard)
      },
      %{
        name: "detect magic",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Sense the presence of magic within 30 ft.",
        classes: ~w(bard cleric druid paladin ranger sorcerer warlock wizard)
      },
      %{
        name: "cure wounds",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: "1d8",
        damage_type: nil,
        effect: "Restore 1d8 + casting modifier HP to a creature you touch.",
        classes: ~w(bard cleric druid paladin ranger)
      },
      %{
        name: "healing word",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: "1d4",
        damage_type: nil,
        effect: "Bonus action; restore 1d4 + casting modifier HP.",
        classes: ~w(bard cleric druid)
      },
      %{
        name: "bless",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Up to 3 allies add 1d4 to attack rolls and saves.",
        classes: ~w(cleric paladin)
      },
      %{
        name: "bane",
        level: 1,
        kind: :save,
        save_ability: :cha,
        dice: nil,
        damage_type: nil,
        effect: "Up to 3 foes subtract 1d4 from attacks and saves.",
        classes: ~w(bard cleric)
      },
      %{
        name: "guiding bolt",
        level: 1,
        kind: :attack,
        save_ability: nil,
        dice: "4d6",
        damage_type: "radiant",
        effect: "Target glows; next attack against it has advantage.",
        classes: ~w(cleric)
      },
      %{
        name: "shield of faith",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Target gains +2 AC for 10 minutes (concentration).",
        classes: ~w(cleric paladin)
      },
      %{
        name: "sanctuary",
        level: 1,
        kind: :save,
        save_ability: :wis,
        dice: nil,
        damage_type: nil,
        effect: "Foes must save or cannot target the warded creature.",
        classes: ~w(cleric)
      },
      %{
        name: "entangle",
        level: 1,
        kind: :save,
        save_ability: :str,
        dice: nil,
        damage_type: nil,
        effect: "Plants grasp creatures in a 20-ft square; restrained on fail.",
        classes: ~w(druid ranger)
      },
      %{
        name: "faerie fire",
        level: 1,
        kind: :save,
        save_ability: :dex,
        dice: nil,
        damage_type: nil,
        effect: "Objects glow; attacks vs affected foes have advantage.",
        classes: ~w(bard druid)
      },
      %{
        name: "speak with animals",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Comprehend and speak with beasts for 10 minutes.",
        classes: ~w(bard druid ranger)
      },
      %{
        name: "heroism",
        level: 1,
        kind: :automatic,
        save_ability: nil,
        dice: nil,
        damage_type: nil,
        effect: "Target is immune to fear and gains temp HP each turn.",
        classes: ~w(bard paladin)
      },
      %{
        name: "tasha's hideous laughter",
        level: 1,
        kind: :save,
        save_ability: :wis,
        dice: nil,
        damage_type: nil,
        effect: "Target falls prone, incapacitated with laughter.",
        classes: ~w(bard wizard)
      },
      %{
        name: "hex",
        level: 1,
        kind: :save,
        save_ability: :con,
        dice: "1d6",
        damage_type: "necrotic",
        effect:
          "Target takes extra 1d6 necrotic when you hit it; disadvantage on a chosen ability.",
        classes: ~w(warlock)
      },
      %{
        name: "hellish rebuke",
        level: 1,
        kind: :save,
        save_ability: :dex,
        dice: "2d10",
        damage_type: "fire",
        effect: "Reaction; searing flames punish a nearby foe.",
        classes: ~w(warlock)
      },
      %{
        name: "witch bolt",
        level: 1,
        kind: :attack,
        save_ability: nil,
        dice: "1d12",
        damage_type: "lightning",
        effect: "A beam of lightning; can deal 1d12 each turn while concentrated.",
        classes: ~w(sorcerer warlock wizard)
      },
      %{
        name: "chromatic orb",
        level: 1,
        kind: :attack,
        save_ability: nil,
        dice: "3d8",
        damage_type: "acid",
        effect: "An orb of energy; choose acid/cold/fire/lightning/poison/thunder.",
        classes: ~w(sorcerer wizard)
      }
    ]
  end

  # Mezcla builtin + SRD: enriquece el builtin con el nombre y la descripción en
  # español del SRD (si coincide por key) y añade los hechizos SRD que no sean
  # builtin. El builtin mantiene SUS mecánicas (corrige datos incompletos del
  # SRD como el dado de Magic Missile).
  defp merge(builtin, srd) do
    srd_by_name = Map.new(srd, &{&1.name, &1})

    enriched =
      Enum.map(builtin, fn b ->
        case Map.get(srd_by_name, b.name) do
          nil ->
            b

          s ->
            b
            |> Map.put(:name_es, s.name_es)
            |> Map.put(:effect, s[:effect] || b.effect)
            |> put_srd_concentration(s)
        end
      end)

    taken = MapSet.new(builtin, & &1.name)
    enriched ++ Enum.reject(srd, &MapSet.member?(taken, &1.name))
  end

  defp put_srd_concentration(b, %{concentration: v}) when is_boolean(v),
    do: Map.put(b, :concentration, v)

  defp put_srd_concentration(b, _), do: b

  defp srd_concentration?(name) do
    normalized = String.downcase(name)

    case Enum.find(Dragonex.Heroes.SRDSpells.all(), &(String.downcase(&1.name) == normalized)) do
      %{concentration: true} -> true
      _ -> false
    end
  end
end
