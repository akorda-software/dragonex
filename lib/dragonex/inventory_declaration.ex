defmodule Dragonex.InventoryDeclaration do
  @moduledoc """
  Reconoce declaraciones de jugador que piden recoger o entregar un objeto
  («cojo el libro», «se lo doy a Mira», «aquí tienes tu libro»). Solo detecta
  la intención: el DM decide si el cambio ocurre y lo registra con
  `grant_item`/`remove_item`, o confirma que no cambia nada con
  `confirm_inventory_unchanged` (D239).

  Es deliberadamente amplio: un falso positivo cuesta una llamada de
  confirmación; uno negativo deja el inventario desincronizado de la prosa.
  Gestos que no mueven objetos («le doy un tajo», «tomo aire», «guardo la
  espada») se excluyen.
  """

  # Armas y gestos: desenvainar/envainar o «dar un golpe» no cambia posesión.
  @es_weapons "(?:espada|daga|hacha|maza|arco|ballesta|lanza|cimitarra|estoque|bast[oó]n|martillo|arma|armas|hoja|escudo|cuchillo|pu[nñ]al|hoz|garrote|honda)"
  @es_gestures "(?:un|una)\\s+(?:(?:buen[oa]?|gran|peque[nñ][oa]|liger[oa]|fuerte|seco|seca|suave)\\s+)?(?:paso|pasos|golpe|tajo|corte|mandoble|estocada|patada|pu[nñ]etazo|grito|salto|vuelta|rodeo|respingo|empuj[oó]n|tir[oó]n|sorbo|trago|vistazo|pisot[oó]n|palmada|codazo|cabezazo|manotazo|abrazo|beso)"

  @es_exclusions [
    # Negaciones: «no avanzo ni recojo nada», «sin entregárselo».
    ~r/\b(?:no|ni|sin|nunca)\s+(?:(?:me|te|se|le|les|lo|la|los|las)\s+){0,2}(?:cojo|recojo|tomo|agarro|guardo|entrego|doy|devuelvo|llevo|saco|entreg[aá]rse\p{L}*|d[aá]rse\p{L}*)\b[^.,;:]*/iu,
    # «saco» sustantivo: «en un saco de harina», «me levanto del saco».
    ~r/\b(?:un|el|del|al|los|unos|ese|este|aquel|cada)\s+sacos?\b/iu,
    ~r/\b(?:doy|damos)\s+#{@es_gestures}/iu,
    ~r/\b(?:le|les)\s+(?:doy|damos)\s+(?:#{@es_gestures}|las\s+gracias|la\s+raz[oó]n|la\s+mano|la\s+espalda|un\s+abrazo)/iu,
    ~r/\b(?:doy|damos)\s+(?:las\s+gracias|la\s+vuelta|media\s+vuelta|la\s+orden|la\s+se[nñ]al|la\s+alarma)/iu,
    ~r/\bme\s+doy\s+cuenta/iu,
    ~r/\b(?:tomo|tomamos|cojo)\s+(?:aire|aliento|nota|posici[oó]n|asiento|la\s+palabra|carrerilla|impulso|una\s+decisi[oó]n)/iu,
    ~r/\b(?:levanto|alzo)\s+(?:la\s+)?(?:vista|mirada|mano|manos|cabeza|voz|ceja)/iu,
    ~r/\bguardo\s+silencio/iu,
    ~r/\b(?:saco|guardo|envaino|desenvaino|enfundo|desenfundo)\s+(?:mi|la|el)\s+#{@es_weapons}/iu
  ]

  @es_pickup ~r/\b(?:cojo|recojo|tomo|agarro|atrapo|saco|guardo|recupero|me\s+(?:guardo|llevo)|(?:me\s+)?(?:lo|la|los|las)\s+(?:cojo|recojo|tomo|agarro|guardo|llevo)|meto\s+[^.!?]{0,50}\ben\s+(?:la\s+|mi\s+)?(?:mochila|bolsa|zurr[oó]n|alforja|morral|faltriquera))\b/iu

  @es_delivery ~r/\b(?:entrego|le\s+entrego|se\s+(?:lo|la|los|las)\s+(?:doy|entrego|paso|devuelvo|tiendo|dejo)|(?:le|les)\s+(?:doy|paso|tiendo|devuelvo|dejo)|devuelvo|aqu[ií]\s+(?:tienes|ten[eé]is)|tom[ae]d?\s*[,:]|ten\s*[,:]|dejo\s+(?:el|la|los|las|mis?|sus?)\s+\p{L}+[^.!?;]{0,40}?\s+(?:sobre|en|junto)\b)/iu

  @en_weapons "(?:sword|dagger|axe|mace|bow|crossbow|spear|scimitar|rapier|staff|hammer|weapon|blade|shield)"

  @en_exclusions [
    ~r/\btake\s+(?:a\s+(?:deep\s+)?(?:breath|step|look|moment|seat|swing|stab)|cover|aim|position|note|charge|heart)/iu,
    ~r/\bgive\s+(?:(?:him|her|them|it)\s+)?(?:a|an)\s+(?:nod|shout|look|smile|signal|push|shove|kick|wave|glance)/iu,
    ~r/\b(?:give|offer)\s+(?:my\s+)?thanks/iu,
    ~r/\b(?:draw|sheathe|stow|put\s+away|ready|raise)\s+(?:my|the)\s+#{@en_weapons}/iu
  ]

  @en_pickup ~r/\b(?:pick(?:s)?\s+(?:it\s+|them\s+)?up|take|grab|pocket|stash|stow|collect|retrieve|keep|put\s+[^.!?]{0,50}\b(?:in|into)\s+my\s+(?:pack|bag|backpack|pouch|satchel))\b/iu

  @en_delivery ~r/\b(?:hand(?:s)?\s+(?:it|them|over|the|her|him)|give\s+(?:it|them|her|him|the)|return\s+(?:it|them|the)|here\s+(?:you\s+(?:go|are)|it\s+is|is\s+your|'s\s+your)|here's\s+your)\b/iu

  @type kind :: :pickup | :delivery | :both

  @doc "`:pickup`, `:delivery`, `:both` o `nil` para la declaración en ese idioma."
  @spec kind(String.t() | nil, atom()) :: kind() | nil
  def kind(text, locale \\ :es)

  def kind(text, locale) when is_binary(text) do
    {exclusions, pickup, delivery} = patterns(locale)
    cleaned = Enum.reduce(exclusions, text, &Regex.replace(&1, &2, " "))

    case {Regex.match?(pickup, cleaned), Regex.match?(delivery, cleaned)} do
      {true, true} -> :both
      {true, false} -> :pickup
      {false, true} -> :delivery
      _ -> nil
    end
  end

  def kind(_, _), do: nil

  defp patterns(:en), do: {@en_exclusions, @en_pickup, @en_delivery}
  defp patterns(_), do: {@es_exclusions, @es_pickup, @es_delivery}
end
