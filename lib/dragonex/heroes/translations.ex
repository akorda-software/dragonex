defmodule Dragonex.Heroes.Translations do
  @moduledoc """
  Traducciones de los catálogos D&D 5e (SRD 5.1).

  Centraliza las **etiquetas** (texto visible) de razas, clases, trasfondos,
  armas, armaduras, hechizos, equipo, habilidades, tipos de daño y clases de
  efecto, indexadas por la `key` estable que usa el motor.

  ## Por qué un módulo aparte

    * Los módulos de mecánica (`Races`, `Classes`, `Equipment`, `Spells`…)
      quedan intactos: cero riesgo para el motor, los tests y el codec.
    * Toda la localización vive en un solo sitio — fácil de revisar, mantener y
      **ampliar** cuando se importe el SRD completo o se añada contenido custom.
    * El contenido **custom de usuario** vendrá de DB (vía `Catalog`), no de aquí;
      este módulo solo cubre el catálogo **builtin** del SRD.

  Cada entrada es `%{es: "...", en: "..."}`. Si falta una traducción, el
  resolvedor (`Dragonex.I18n.label/3`) cae al otro idioma y luego a la `key`.
  """

  alias Dragonex.I18n

  @type labels :: %{es: String.t(), en: String.t()}

  # ============================================================ razas

  @races %{
    "dwarf" => %{es: "Enano", en: "Dwarf"},
    "elf" => %{es: "Elfo", en: "Elf"},
    "halfling" => %{es: "Mediano", en: "Halfling"},
    "human" => %{es: "Humano", en: "Human"},
    "dragonborn" => %{es: "Dracónido", en: "Dragonborn"},
    "gnome" => %{es: "Gnomo", en: "Gnome"},
    "half-elf" => %{es: "Semielfo", en: "Half-Elf"},
    "half-orc" => %{es: "Semiorco", en: "Half-Orc"},
    "tiefling" => %{es: "Tiefling", en: "Tiefling"}
  }

  # subrazas indexadas por la sub-key (única dentro de su raza)
  @subraces %{
    "mountain" => %{es: "Enano de Montaña", en: "Mountain Dwarf"},
    "hill" => %{es: "Enano de las Colinas", en: "Hill Dwarf"},
    "high elf" => %{es: "Alto Elfo", en: "High Elf"},
    "wood elf" => %{es: "Elfo de los Bosques", en: "Wood Elf"},
    "dark elf" => %{es: "Elfo Oscuro (Drow)", en: "Dark Elf (Drow)"},
    "lightfoot" => %{es: "Mediano Piesligeros", en: "Lightfoot Halfling"},
    "stout" => %{es: "Mediano Recio", en: "Stout Halfling"},
    "forest gnome" => %{es: "Gnomo de los Bosques", en: "Forest Gnome"},
    "rock gnome" => %{es: "Gnomo de las Rocas", en: "Rock Gnome"}
  }

  @stored_subrace_names %{
    "mountain dwarf" => "mountain",
    "hill dwarf" => "hill",
    "dark elf (drow)" => "dark elf",
    "lightfoot halfling" => "lightfoot",
    "stout halfling" => "stout"
  }

  @doc "Etiqueta de una raza según la locale."
  @spec race(String.t(), atom()) :: String.t()
  def race(key, locale \\ I18n.locale()), do: I18n.label(Map.get(@races, key), locale, key)

  @doc "Etiqueta de una subraza según la locale."
  @spec subrace(String.t(), atom()) :: String.t()
  def subrace(key, locale \\ I18n.locale()), do: I18n.label(Map.get(@subraces, key), locale, key)

  @doc """
  Etiqueta compuesta de raza+subraza para un personaje. Si recibe solo raza,
  devuelve su etiqueta; si recibe subraza, devuelve la etiqueta de la subraza.

  Acepta el valor almacenado en `Character.race` (que puede ser la `key` de la
  raza —p. ej. `"human"`— o el nombre de la subraza —p. ej. `"high elf"`—),
  ya que el builder actual guarda el nombre en minúsculas.
  """
  @spec race_display(String.t() | nil, atom()) :: String.t()
  def race_display(nil, _locale), do: ""

  def race_display(value, locale) do
    value = value |> String.trim() |> String.downcase()
    stored_key = Map.get(@stored_subrace_names, value)

    cond do
      Map.has_key?(@subraces, value) -> subrace(value, locale)
      stored_key -> subrace(stored_key, locale)
      Map.has_key?(@races, value) -> race(value, locale)
      true -> String.capitalize(value)
    end
  end

  # ============================================================ clases

  @classes %{
    "barbarian" => %{es: "Bárbaro", en: "Barbarian"},
    "bard" => %{es: "Bardo", en: "Bard"},
    "cleric" => %{es: "Clérigo", en: "Cleric"},
    "druid" => %{es: "Druida", en: "Druid"},
    "fighter" => %{es: "Guerrero", en: "Fighter"},
    "monk" => %{es: "Monje", en: "Monk"},
    "paladin" => %{es: "Paladín", en: "Paladin"},
    "ranger" => %{es: "Explorador", en: "Ranger"},
    "rogue" => %{es: "Pícaro", en: "Rogue"},
    "sorcerer" => %{es: "Hechicero", en: "Sorcerer"},
    "warlock" => %{es: "Brujo", en: "Warlock"},
    "wizard" => %{es: "Mago", en: "Wizard"}
  }

  @doc "Etiqueta de una clase según la locale."
  @spec class(String.t(), atom()) :: String.t()
  def class(key, locale \\ I18n.locale()), do: I18n.label(Map.get(@classes, key), locale, key)

  # ============================================================ trasfondos

  @backgrounds %{
    "acolyte" => %{es: "Acólito", en: "Acolyte"},
    "criminal" => %{es: "Criminal", en: "Criminal"},
    "folk hero" => %{es: "Héroe del Pueblo", en: "Folk Hero"},
    "noble" => %{es: "Noble", en: "Noble"},
    "sage" => %{es: "Sabio", en: "Sage"},
    "soldier" => %{es: "Soldado", en: "Soldier"},
    "charlatan" => %{es: "Charlatán", en: "Charlatan"},
    "entertainer" => %{es: "Animador", en: "Entertainer"},
    "hermit" => %{es: "Ermitaño", en: "Hermit"},
    "outlander" => %{es: "Forastero", en: "Outlander"}
  }

  @doc "Etiqueta de un trasfondo según la locale."
  @spec background(String.t(), atom()) :: String.t()
  def background(key, locale \\ I18n.locale()),
    do: I18n.label(Map.get(@backgrounds, key), locale, key)

  # ============================================================ armas

  @weapons %{
    # simple melee
    "club" => %{es: "Maza", en: "Club"},
    "dagger" => %{es: "Daga", en: "Dagger"},
    "greatclub" => %{es: "Maza grande", en: "Greatclub"},
    "handaxe" => %{es: "Hacha de mano", en: "Handaxe"},
    "javelin" => %{es: "Jabalina", en: "Javelin"},
    "light hammer" => %{es: "Martillo ligero", en: "Light Hammer"},
    "mace" => %{es: "Maza de armas", en: "Mace"},
    "quarterstaff" => %{es: "Bastón", en: "Quarterstaff"},
    "sickle" => %{es: "Hoz", en: "Sickle"},
    "spear" => %{es: "Lanza", en: "Spear"},
    # simple ranged
    "light crossbow" => %{es: "Ballesta ligera", en: "Light Crossbow"},
    "dart" => %{es: "Dardo", en: "Dart"},
    "shortbow" => %{es: "Arco corto", en: "Shortbow"},
    "sling" => %{es: "Honda", en: "Sling"},
    # martial melee
    "battleaxe" => %{es: "Hacha de batalla", en: "Battleaxe"},
    "flail" => %{es: "Mangual", en: "Flail"},
    "glaive" => %{es: "Glaive", en: "Glaive"},
    "greataxe" => %{es: "Hacha grande", en: "Greataxe"},
    "greatsword" => %{es: "Espada larga a dos manos", en: "Greatsword"},
    "halberd" => %{es: "Alabarda", en: "Halberd"},
    "lance" => %{es: "Lanza de jinete", en: "Lance"},
    "longsword" => %{es: "Espada larga", en: "Longsword"},
    "maul" => %{es: "Martillo de guerra", en: "Maul"},
    "morningstar" => %{es: "Estrella matutina", en: "Morningstar"},
    "pike" => %{es: "Pica", en: "Pike"},
    "rapier" => %{es: "Estoque", en: "Rapier"},
    "scimitar" => %{es: "Cimitarra", en: "Scimitar"},
    "shortsword" => %{es: "Espada corta", en: "Shortsword"},
    "trident" => %{es: "Tridente", en: "Trident"},
    "war pick" => %{es: "Pico de guerra", en: "War Pick"},
    "warhammer" => %{es: "Martillo de guerra", en: "Warhammer"},
    "whip" => %{es: "Látigo", en: "Whip"},
    # martial ranged
    "hand crossbow" => %{es: "Ballesta de mano", en: "Hand Crossbow"},
    "heavy crossbow" => %{es: "Ballesta pesada", en: "Heavy Crossbow"},
    "longbow" => %{es: "Arco largo", en: "Longbow"},
    "blowgun" => %{es: "Cerbatana", en: "Blowgun"}
  }

  @doc "Etiqueta de un arma según la locale."
  @spec weapon(String.t(), atom()) :: String.t()
  def weapon(key, locale \\ I18n.locale()), do: I18n.label(Map.get(@weapons, key), locale, key)

  # ============================================================ armaduras

  @armors %{
    "padded armor" => %{es: "Armadura acolchada", en: "Padded Armor"},
    "leather armor" => %{es: "Armadura de cuero", en: "Leather Armor"},
    "studded leather armor" => %{es: "Armadura de cuero tachonado", en: "Studded Leather Armor"},
    "hide armor" => %{es: "Armadura de pieles", en: "Hide Armor"},
    "chain shirt" => %{es: "Cota de malla ligera", en: "Chain Shirt"},
    "scale mail" => %{es: "Cota de escamas", en: "Scale Mail"},
    "breastplate" => %{es: "Coraza", en: "Breastplate"},
    "half plate" => %{es: "Semiplaca", en: "Half Plate"},
    "ring mail" => %{es: "Cota de anillas", en: "Ring Mail"},
    "chain mail" => %{es: "Cota de malla", en: "Chain Mail"},
    "splint armor" => %{es: "Armadura de bandas", en: "Splint Armor"},
    "plate armor" => %{es: "Armadura de placas", en: "Plate Armor"},
    "shield" => %{es: "Escudo", en: "Shield"}
  }

  @doc "Etiqueta de una armadura/escudo según la locale."
  @spec armor(String.t(), atom()) :: String.t()
  def armor(key, locale \\ I18n.locale()), do: I18n.label(Map.get(@armors, key), locale, key)

  # ============================================================ hechizos

  @spells %{
    # cantrips
    "fire bolt" => %{es: "Rayo ígneo", en: "Fire Bolt"},
    "ray of frost" => %{es: "Rayo de escarcha", en: "Ray of Frost"},
    "acid splash" => %{es: "Salpicadura de ácido", en: "Acid Splash"},
    "sacred flame" => %{es: "Llama sagrada", en: "Sacred Flame"},
    "vicious mockery" => %{es: "Burla vil", en: "Vicious Mockery"},
    "produce flame" => %{es: "Producir llama", en: "Produce Flame"},
    "eldritch blast" => %{es: "Descargo sobrenatural", en: "Eldritch Blast"},
    "light" => %{es: "Luz", en: "Light"},
    "mage hand" => %{es: "Mano de mago", en: "Mage Hand"},
    "prestidigitation" => %{es: "Prestidigitación", en: "Prestidigitation"},
    "druidcraft" => %{es: "Truco druídico", en: "Druidcraft"},
    "guidance" => %{es: "Guía", en: "Guidance"},
    "thaumaturgy" => %{es: "Taumaturgia", en: "Thaumaturgy"},
    "minor illusion" => %{es: "Ilusión menor", en: "Minor Illusion"},
    "shillelagh" => %{es: "Shillelagh", en: "Shillelagh"},
    "dancing lights" => %{es: "Luces danzantes", en: "Dancing Lights"},
    "resistance" => %{es: "Resistencia", en: "Resistance"},
    "spare the dying" => %{es: "Auxilio mortal", en: "Spare the Dying"},
    # nivel 1
    "magic missile" => %{es: "Proyectil mágico", en: "Magic Missile"},
    "shield" => %{es: "Escudo", en: "Shield"},
    "mage armor" => %{es: "Armadura de mago", en: "Mage Armor"},
    "burning hands" => %{es: "Manos ardientes", en: "Burning Hands"},
    "thunderwave" => %{es: "Onda de trueno", en: "Thunderwave"},
    "charm person" => %{es: "Encantar persona", en: "Charm Person"},
    "sleep" => %{es: "Sueño", en: "Sleep"},
    "detect magic" => %{es: "Detectar magia", en: "Detect Magic"},
    "cure wounds" => %{es: "Curar heridas", en: "Cure Wounds"},
    "healing word" => %{es: "Palabra curativa", en: "Healing Word"},
    "bless" => %{es: "Bendición", en: "Bless"},
    "bane" => %{es: "Perdición", en: "Bane"},
    "guiding bolt" => %{es: "Rayo guía", en: "Guiding Bolt"},
    "shield of faith" => %{es: "Escudo de la fe", en: "Shield of Faith"},
    "sanctuary" => %{es: "Santuario", en: "Sanctuary"},
    "entangle" => %{es: "Enredar", en: "Entangle"},
    "faerie fire" => %{es: "Fuego de hadas", en: "Faerie Fire"},
    "speak with animals" => %{es: "Hablar con los animales", en: "Speak with Animals"},
    "heroism" => %{es: "Heroísmo", en: "Heroism"},
    "tasha's hideous laughter" => %{es: "Risa histérica de Tasha", en: "Tasha's Hideous Laughter"},
    "hex" => %{es: "Maleficio", en: "Hex"},
    "hellish rebuke" => %{es: "Reprensión infernal", en: "Hellish Rebuke"},
    "witch bolt" => %{es: "Rayo brujo", en: "Witch Bolt"},
    "chromatic orb" => %{es: "Orbe cromático", en: "Chromatic Orb"}
  }

  @doc "Etiqueta de un hechizo según la locale."
  @spec spell(String.t(), atom()) :: String.t()
  def spell(key, locale \\ I18n.locale()), do: I18n.label(Map.get(@spells, key), locale, key)

  # ============================================================ equipo / gear

  @gear %{
    "explorer's pack" => %{es: "Equipo de explorador", en: "Explorer's Pack"},
    "diplomat's pack" => %{es: "Equipo de diplomático", en: "Diplomat's Pack"},
    "priest's pack" => %{es: "Equipo de sacerdote", en: "Priest's Pack"},
    "dungeoneer's pack" => %{es: "Equipo de mazmorreo", en: "Dungeoneer's Pack"},
    "scholar's pack" => %{es: "Equipo de erudito", en: "Scholar's Pack"},
    "burglar's pack" => %{es: "Equipo de ladrón", en: "Burglar's Pack"},
    "component pouch" => %{es: "Bolsa de componentes", en: "Component Pouch"},
    "arcane focus" => %{es: "Foco arcano", en: "Arcane Focus"},
    "holy symbol" => %{es: "Símbolo sagrado", en: "Holy Symbol"},
    "druidic focus" => %{es: "Foco druídico", en: "Druidic Focus"},
    "spellbook" => %{es: "Grimorio", en: "Spellbook"},
    "lute" => %{es: "Laúd", en: "Lute"},
    "musical instrument" => %{es: "Instrumento musical", en: "Musical Instrument"},
    "thieves' tools" => %{es: "Herramientas de ladrón", en: "Thieves' Tools"},
    "artisan's tools" => %{es: "Herramientas de artesano", en: "Artisan's Tools"},
    "herbalism kit" => %{es: "Equipo de herboristería", en: "Herbalism Kit"},
    "disguise kit" => %{es: "Kit de disfraces", en: "Disguise Kit"},
    "javelins" => %{es: "Jabalinas", en: "Javelins"},
    "arrows" => %{es: "Flechas", en: "Arrows"},
    "bolts" => %{es: "Saetas", en: "Bolts"},
    "darts" => %{es: "Dardos", en: "Darts"},
    "daggers" => %{es: "Dagas", en: "Daggers"},
    "prayer book" => %{es: "Libro de oraciones", en: "Prayer Book"},
    "sticks of incense" => %{es: "Varas de incienso", en: "Sticks of Incense"},
    "vestments" => %{es: "Vestimentas", en: "Vestments"},
    "clothes, common" => %{es: "Ropa común", en: "Clothes, Common"},
    "clothes, traveler's" => %{es: "Ropa de viajero", en: "Clothes, Traveler's"},
    "clothes, fine" => %{es: "Ropa fina", en: "Clothes, Fine"},
    "dark, common clothes with hood" => %{
      es: "Ropa común con capucha",
      en: "Dark Common Clothes with Hood"
    },
    "crowbar" => %{es: "Palanca", en: "Crowbar"},
    "shovel" => %{es: "Pala", en: "Shovel"},
    "iron pot" => %{es: "Olla de hierro", en: "Iron Pot"},
    "fine clothes" => %{es: "Ropa fina", en: "Fine Clothes"},
    "signet ring" => %{es: "Anillo de sello", en: "Signet Ring"},
    "scroll of pedigree" => %{es: "Pergamino de linaje", en: "Scroll of Pedigree"},
    "bottle of black ink" => %{es: "Frasco de tinta negra", en: "Bottle of Black Ink"},
    "quill" => %{es: "Pluma", en: "Quill"},
    "letters" => %{es: "Cartas", en: "Letters"},
    "rank insignia" => %{es: "Insignia de rango", en: "Rank Insignia"},
    "trophy" => %{es: "Trofeo", en: "Trophy"},
    "tools of the con" => %{es: "Utensilios de timo", en: "Tools of the Con"},
    "favor of an admirer" => %{es: "Recuerdo de un admirador", en: "Favor of an Admirer"},
    "scroll case" => %{es: "Estuche de pergaminos", en: "Scroll Case"},
    "winter blanket" => %{es: "Manta de invierno", en: "Winter Blanket"},
    "staff" => %{es: "Bastón", en: "Staff"},
    "hunting trap" => %{es: "Trampa de caza", en: "Hunting Trap"}
  }

  @doc "Etiqueta de un objeto de equipo según la locale."
  @spec gear(String.t(), atom()) :: String.t()
  def gear(key, locale \\ I18n.locale()), do: I18n.label(Map.get(@gear, key), locale, key)

  @doc """
  Etiqueta de un objeto de inventario genérico. Prueba arma, armadura, equipo y
  si no, capitaliza.
  """
  @spec item(String.t(), atom()) :: String.t()
  def item(name, locale \\ I18n.locale()) do
    cond do
      Map.has_key?(@weapons, name) -> weapon(name, locale)
      Map.has_key?(@armors, name) -> armor(name, locale)
      Map.has_key?(@gear, name) -> gear(name, locale)
      true -> String.capitalize(name)
    end
  end

  # ============================================================ habilidades (skills)

  @skills %{
    "acrobatics" => %{es: "Acróbata", en: "Acrobatics"},
    "animal_handling" => %{es: "Trato con animales", en: "Animal Handling"},
    "arcana" => %{es: "Arcano", en: "Arcana"},
    "athletics" => %{es: "Atletismo", en: "Athletics"},
    "deception" => %{es: "Engaño", en: "Deception"},
    "history" => %{es: "Historia", en: "History"},
    "insight" => %{es: "Perspicacia", en: "Insight"},
    "intimidation" => %{es: "Intimidación", en: "Intimidation"},
    "investigation" => %{es: "Investigación", en: "Investigation"},
    "medicine" => %{es: "Medicina", en: "Medicine"},
    "nature" => %{es: "Naturaleza", en: "Nature"},
    "perception" => %{es: "Percepción", en: "Perception"},
    "performance" => %{es: "Interpretación", en: "Performance"},
    "persuasion" => %{es: "Persuasión", en: "Persuasion"},
    "religion" => %{es: "Religión", en: "Religion"},
    "sleight_of_hand" => %{es: "Juego de manos", en: "Sleight of Hand"},
    "stealth" => %{es: "Sigilo", en: "Stealth"},
    "survival" => %{es: "Supervivencia", en: "Survival"}
  }

  @doc "Etiqueta de una habilidad (skill) según la locale."
  @spec skill(String.t() | atom(), atom()) :: String.t()
  def skill(key, locale \\ I18n.locale()),
    do: I18n.label(Map.get(@skills, to_string(key)), locale, to_string(key))

  @doc "Todas las claves de habilidades (para el picker de clase con skill_list :any)."
  @spec skill_keys() :: [String.t()]
  def skill_keys, do: Map.keys(@skills)

  # ============================================================ características (abilities)

  @abilities %{
    "str" => %{es: "Fuerza", en: "Strength"},
    "dex" => %{es: "Destreza", en: "Dexterity"},
    "con" => %{es: "Constitución", en: "Constitution"},
    "int" => %{es: "Inteligencia", en: "Intelligence"},
    "wis" => %{es: "Sabiduría", en: "Wisdom"},
    "cha" => %{es: "Carisma", en: "Charisma"}
  }

  @ability_short %{
    "str" => %{es: "FUE", en: "STR"},
    "dex" => %{es: "DES", en: "DEX"},
    "con" => %{es: "CON", en: "CON"},
    "int" => %{es: "INT", en: "INT"},
    "wis" => %{es: "SAB", en: "WIS"},
    "cha" => %{es: "CAR", en: "CHA"}
  }

  @doc "Etiqueta larga de una característica."
  @spec ability(String.t() | atom(), atom()) :: String.t()
  def ability(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@abilities, to_string(key)), locale, to_string(key))
  end

  @doc "Etiqueta corta de una característica (FUE, DES…)."
  @spec ability_short(String.t() | atom(), atom()) :: String.t()
  def ability_short(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@ability_short, to_string(key)), locale, String.upcase(to_string(key)))
  end

  # ============================================================ tipos de daño

  @damage_types %{
    "bludgeoning" => %{es: "contundente", en: "bludgeoning"},
    "piercing" => %{es: "perforante", en: "piercing"},
    "slashing" => %{es: "cortante", en: "slashing"},
    "acid" => %{es: "ácido", en: "acid"},
    "cold" => %{es: "frío", en: "cold"},
    "fire" => %{es: "fuego", en: "fire"},
    "force" => %{es: "por fuerza", en: "force"},
    "lightning" => %{es: "rayo", en: "lightning"},
    "necrotic" => %{es: "necrótico", en: "necrotic"},
    "poison" => %{es: "veneno", en: "poison"},
    "psychic" => %{es: "psíquico", en: "psychic"},
    "radiant" => %{es: "radiante", en: "radiant"},
    "thunder" => %{es: "trueno", en: "thunder"}
  }

  @doc "Etiqueta de un tipo de daño según la locale."
  @spec damage_type(String.t() | nil, atom()) :: String.t()
  def damage_type(key, locale \\ I18n.locale())
  def damage_type(nil, _locale), do: ""

  def damage_type(key, locale) do
    I18n.label(Map.get(@damage_types, to_string(key)), locale, to_string(key))
  end

  @doc "Lista de tipos de daño canónicos (SRD 5e), ordenada."
  @spec damage_types() :: [String.t()]
  def damage_types, do: @damage_types |> Map.keys() |> Enum.sort()

  # ============================================================ clases de efecto

  @kinds %{
    "save" => %{es: "salvación", en: "save"},
    "attack" => %{es: "ataque", en: "attack"},
    "automatic" => %{es: "automático", en: "automatic"}
  }

  @doc "Etiqueta del `kind` de un hechizo (:save | :attack | :automatic)."
  @spec kind(atom() | String.t(), atom()) :: String.t()
  def kind(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@kinds, to_string(key)), locale, to_string(key))
  end

  # ============================================================ ranuras de equipo

  @kinds_item %{
    "weapon" => %{es: "arma", en: "weapon"},
    "armor" => %{es: "armadura", en: "armor"},
    "gear" => %{es: "equipo", en: "gear"},
    "ammo" => %{es: "munición", en: "ammo"},
    "focus" => %{es: "foco", en: "focus"},
    "consumable" => %{es: "consumible", en: "consumible"}
  }

  @doc "Etiqueta del `kind` de un objeto de inventario."
  @spec item_kind(atom() | String.t(), atom()) :: String.t()
  def item_kind(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@kinds_item, to_string(key)), locale, to_string(key))
  end

  # ============================================================ rasgos raciales

  @racial_traits %{
    "darkvision" => %{es: "Visión en la oscuridad", en: "Darkvision"},
    "dwarven_resilience" => %{es: "Resiliencia enana", en: "Dwarven Resilience"},
    "stonecunning" => %{es: "Conocimiento de la piedra", en: "Stonecunning"},
    "tool_proficiency" => %{es: "Competencia con herramientas", en: "Tool Proficiency"},
    "dwarven_armor_training" => %{
      es: "Entrenamiento en armaduras (enano)",
      en: "Dwarven Armor Training"
    },
    "dwarven_toughness" => %{es: "Dureza enana", en: "Dwarven Toughness"},
    "fey_ancestry" => %{es: "Linaje feérico", en: "Fey Ancestry"},
    "trance" => %{es: "Trance", en: "Trance"},
    "elf_weapon_training" => %{es: "Entrenamiento con armas élficas", en: "Elf Weapon Training"},
    "cantrip" => %{es: "Truco (alto elfo)", en: "Cantrip (High Elf)"},
    "extra_language" => %{es: "Idioma adicional", en: "Extra Language"},
    "mask_of_the_wild" => %{es: "Máscara de la naturaleza", en: "Mask of the Wild"},
    "fleet_of_foot" => %{es: "Ligerito", en: "Fleet of Foot"},
    "superior_darkvision" => %{es: "Visión en la oscuridad superior", en: "Superior Darkvision"},
    "sunlight_sensitivity" => %{es: "Sensibilidad a la luz solar", en: "Sunlight Sensitivity"},
    "drow_magic" => %{es: "Magia drow", en: "Drow Magic"},
    "drow_weapon_training" => %{es: "Entrenamiento con armas drow", en: "Drow Weapon Training"},
    "lucky" => %{es: "Suerte", en: "Lucky"},
    "brave" => %{es: "Valentía", en: "Brave"},
    "halfling_nimbleness" => %{es: "Agilidad mediana", en: "Halfling Nimbleness"},
    "naturally_stealthy" => %{es: "Sigilo natural", en: "Naturally Stealthy"},
    "stout_resilience" => %{es: "Resiliencia recia", en: "Stout Resilience"},
    "gnome_cunning" => %{es: "Astucia gnoma", en: "Gnome Cunning"},
    "natural_illusionist" => %{es: "Ilusionista nato", en: "Natural Illusionist"},
    "speak_with_small_beasts" => %{
      es: "Hablar con bestias pequeñas",
      en: "Speak with Small Beasts"
    },
    "artificers_lore" => %{es: "Sabiduría del artífice", en: "Artificer's Lore"},
    "tinker" => %{es: "Trasteo", en: "Tinker"},
    "draconic_ancestry" => %{es: "Ascendencia dracónica", en: "Draconic Ancestry"},
    "breath_weapon" => %{es: "Arma de aliento", en: "Breath Weapon"},
    "damage_resistance" => %{es: "Resistencia al daño", en: "Damage Resistance"},
    "menacing" => %{es: "Intimidante", en: "Menacing"},
    "relentless_endurance" => %{es: "Resistencia implacable", en: "Relentless Endurance"},
    "savage_attacks" => %{es: "Ataques salvajes", en: "Savage Attacks"},
    "skill_versatility" => %{es: "Versatilidad en habilidades", en: "Skill Versatility"},
    "hellish_resistance" => %{es: "Resistencia infernal", en: "Hellish Resistance"},
    "infernal_legacy" => %{es: "Legado infernal", en: "Infernal Legacy"}
  }

  @doc "Etiqueta de un rasgo racial."
  @spec trait(String.t() | atom(), atom()) :: String.t()
  def trait(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@racial_traits, to_string(key)), locale, to_string(key))
  end

  # ============================================================ características de clase

  @class_features %{
    "rage" => %{es: "Rabia", en: "Rage"},
    "unarmored_defense" => %{es: "Defensa sin armadura", en: "Unarmored Defense"},
    "bardic_inspiration" => %{es: "Inspiración bardica", en: "Bardic Inspiration"},
    "spellcasting" => %{es: "Conjuración", en: "Spellcasting"},
    "divine_domain" => %{es: "Dominio divino", en: "Divine Domain"},
    "druidic" => %{es: "Druídico", en: "Druidic"},
    "wild_shape" => %{es: "Forma salvaje", en: "Wild Shape"},
    "fighting_style" => %{es: "Estilo de combate", en: "Fighting Style"},
    "second_wind" => %{es: "Segundo aliento", en: "Second Wind"},
    "martial_arts" => %{es: "Artes marciales", en: "Martial Arts"},
    "divine_sense" => %{es: "Sentido divino", en: "Divine Sense"},
    "lay_on_hands" => %{es: "Manos impositoras", en: "Lay on Hands"},
    "favored_enemy" => %{es: "Enemigo predilecto", en: "Favored Enemy"},
    "natural_explorer" => %{es: "Explorador natural", en: "Natural Explorer"},
    "expertise" => %{es: "Pericia", en: "Expertise"},
    "sneak_attack" => %{es: "Ataque furtivo", en: "Sneak Attack"},
    "thieves_cant" => %{es: "Jerga de ladrones", en: "Thieves' Cant"},
    "sorcerous_origin" => %{es: "Origen hechicero", en: "Sorcerous Origin"},
    "font_of_magic" => %{es: "Fuente de magia", en: "Font of Magic"},
    "eldritch_invocations" => %{es: "Invocaciones sobrenaturales", en: "Eldritch Invocations"},
    "pact_magic" => %{es: "Magia de pacto", en: "Pact Magic"},
    "otherworldly_patron" => %{es: "Patrón sobrenatural", en: "Otherworldly Patron"},
    "arcane_recovery" => %{es: "Recuperación arcana", en: "Arcane Recovery"},
    "ritual_casting" => %{es: "Conjuración ritual", en: "Ritual Casting"}
  }

  @doc "Etiqueta de una característica de clase."
  @spec feature(String.t() | atom(), atom()) :: String.t()
  def feature(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@class_features, to_string(key)), locale, to_string(key))
  end

  # ============================================================ características de trasfondo

  @background_features %{
    "shelter_of_the_faithful" => %{es: "Refugio de los fieles", en: "Shelter of the Faithful"},
    "criminal_contact" => %{es: "Contacto criminal", en: "Criminal Contact"},
    "rustic_hospitality" => %{es: "Hospitalidad rústica", en: "Rustic Hospitality"},
    "position_of_privilege" => %{es: "Posición de privilegio", en: "Position of Privilege"},
    "researcher" => %{es: "Investigador", en: "Researcher"},
    "military_rank" => %{es: "Rango militar", en: "Military Rank"},
    "false_identity" => %{es: "Identidad falsa", en: "False Identity"},
    "by_popular_demand" => %{es: "Por demanda popular", en: "By Popular Demand"},
    "discovery" => %{es: "Descubrimiento", en: "Discovery"},
    "wanderer" => %{es: "Errante", en: "Wanderer"}
  }

  @doc "Etiqueta de la característica de un trasfondo."
  @spec background_feature(String.t() | atom(), atom()) :: String.t()
  def background_feature(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@background_features, to_string(key)), locale, to_string(key))
  end

  # ============================================================ idiomas

  @languages %{
    "common" => %{es: "Común", en: "Common"},
    "dwarvish" => %{es: "Enano", en: "Dwarvish"},
    "elvish" => %{es: "Élfico", en: "Elvish"},
    "giant" => %{es: "Gigante", en: "Giant"},
    "gnomish" => %{es: "Gnomo", en: "Gnomish"},
    "goblin" => %{es: "Goblin", en: "Goblin"},
    "halfling" => %{es: "Mediano", en: "Halfling"},
    "orc" => %{es: "Orco", en: "Orc"},
    "abyssal" => %{es: "Abisal", en: "Abyssal"},
    "celestial" => %{es: "Celestial", en: "Celestial"},
    "draconic" => %{es: "Dracónico", en: "Draconic"},
    "deep_speech" => %{es: "Lenguaje profundo", en: "Deep Speech"},
    "infernal" => %{es: "Infernal", en: "Infernal"},
    "primordial" => %{es: "Primordial", en: "Primordial"},
    "sylvan" => %{es: "Silvano", en: "Sylvan"},
    "undercommon" => %{es: "Común de la Suboscuridad", en: "Undercommon"}
  }

  @doc "Claves de todos los idiomas del SRD."
  @spec languages() :: [String.t()]
  def languages, do: Map.keys(@languages)

  @doc "Etiqueta de un idioma."
  @spec language(String.t() | atom(), atom()) :: String.t()
  def language(key, locale \\ I18n.locale()) do
    I18n.label(Map.get(@languages, to_string(key)), locale, to_string(key))
  end
end
