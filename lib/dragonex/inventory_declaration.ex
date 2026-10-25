defmodule Dragonex.InventoryDeclaration do
  @moduledoc """
  Reconoce declaraciones de jugador que piden recoger o entregar un objeto
  («cojo el libro», «se lo doy a Mira», «aquí tienes tu libro»). Solo detecta
  la intención: el DM decide si el cambio ocurre y lo registra con
  `grant_item`/`remove_item`, o confirma que no cambia nada con
  `confirm_inventory_unchanged` (D239).

  Una entrega temporal con retorno en el mismo episodio selecciona
  `:round_trip`: exige dos tramos atómicos o una negativa tipada, aunque el
  saldo final sea idéntico. No identifica el objeto ni decide si se presta.

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

  # A temporary loan is an episode with two custody changes, even when the
  # final stock is identical. These bounded intent patterns select a stricter
  # receipt contract; they never extract quantities or decide that a loan occurs.
  @es_loan ~r/\b(?:prest(?:o|as?|amos|an|e|es)|(?:pido|tomo|cojo|recibo)\b[^.!?;]{0,80}\bprestad[oa]s?)\b/iu
  @es_temporary ~r/\b(?:un\s+(?:instante|momento|segundo)|brevemente|temporalmente|solo\s+para\s+(?:ver|mirar|examinar|inspeccionar))\b/iu
  @es_return ~r/\b(?:devuelvo|devuelve[ns]?|devolvemos|devolver[eé])\b/iu
  @es_immediate_return ~r/(?:\b(?:devuelvo|devuelve[ns]?|devolvemos|devolver[eé])\b[^.!?;]{0,100}\b(?:inmediatamente|enseguida|en\s+seguida|al\s+instante|acto\s+seguido)|\b(?:inmediatamente|enseguida|en\s+seguida|acto\s+seguido)\b[^.!?;]{0,60}\b(?:devuelvo|devuelve[ns]?|devolvemos|devolver[eé])\b)/iu
  @es_no_return ~r/\b(?:no|ni|sin|nunca)\s+(?:(?:me|te|se|le|les|lo|la|los|las)\s+){0,3}(?:devuelv\p{L}*|devolv\p{L}*)\b[^.,;:]*/iu
  @es_future_return ~r/\b(?:ma[nñ]ana|otro\s+d[ií]a|m[aá]s\s+tarde|la\s+semana\s+que\s+viene|despu[eé]s\s+de\s+la\s+aventura)\b/iu

  @en_loan ~r/\b(?:borrow|lend|lends|loan|loans)\b/iu
  @en_temporary ~r/\b(?:a\s+(?:moment|second)|briefly|temporarily|just\s+to\s+(?:look|see|examine|inspect))\b/iu
  @en_return ~r/\b(?:return(?:s)?|(?:give|gives|hand|hands|get|gets)\b[^.!?;]{0,60}\bback)\b/iu
  @en_immediate ~r/\b(?:immediately|straight\s+away|right\s+away|at\s+once)\b/iu
  @en_no_return ~r/\b(?:not|never|don't|doesn't|do\s+not|does\s+not|without)\s+(?:return\w*|giv\w*|hand\w*|get\w*)\b[^.,;:]*/iu
  @en_future_return ~r/\b(?:tomorrow|later|another\s+day|next\s+week|after\s+the\s+adventure)\b/iu

  @type kind :: :pickup | :delivery | :both | :round_trip

  @doc "`:pickup`, `:delivery`, `:both`, `:round_trip` o `nil` para la declaración."
  @spec kind(String.t() | nil, atom()) :: kind() | nil
  def kind(text, locale \\ :es)

  def kind(text, locale) when is_binary(text) do
    {exclusions, pickup, delivery} = patterns(locale)
    cleaned = Enum.reduce(exclusions, text, &Regex.replace(&1, &2, " "))

    if round_trip?(cleaned, locale) do
      :round_trip
    else
      ordinary_kind(cleaned, pickup, delivery)
    end
  end

  def kind(_, _), do: nil

  @doc "D239 classification for a resumed checkpoint created before the captured inventory contract."
  def legacy_kind(text, locale \\ :es)

  def legacy_kind(text, locale) when is_binary(text) do
    {exclusions, pickup, delivery} = patterns(locale)
    cleaned = Enum.reduce(exclusions, text, &Regex.replace(&1, &2, " "))
    ordinary_kind(cleaned, pickup, delivery)
  end

  def legacy_kind(_, _), do: nil

  defp ordinary_kind(text, pickup, delivery) do
    case {Regex.match?(pickup, text), Regex.match?(delivery, text)} do
      {true, true} -> :both
      {true, false} -> :pickup
      {false, true} -> :delivery
      _ -> nil
    end
  end

  defp round_trip?(text, :en) do
    text = Regex.replace(@en_no_return, text, " ")

    (Regex.match?(@en_loan, text) or
       (Regex.match?(@en_pickup, text) and Regex.match?(@en_temporary, text))) and
      Regex.match?(@en_return, text) and
      (Regex.match?(@en_immediate, text) or Regex.match?(@en_temporary, text)) and
      not Regex.match?(@en_future_return, text)
  end

  defp round_trip?(text, _) do
    text = Regex.replace(@es_no_return, text, " ")

    (Regex.match?(@es_loan, text) or
       (Regex.match?(@es_pickup, text) and Regex.match?(@es_temporary, text))) and
      Regex.match?(@es_return, text) and
      (Regex.match?(@es_immediate_return, text) or Regex.match?(@es_temporary, text)) and
      not Regex.match?(@es_future_return, text)
  end

  defp patterns(:en), do: {@en_exclusions, @en_pickup, @en_delivery}
  defp patterns(_), do: {@es_exclusions, @es_pickup, @es_delivery}
end
