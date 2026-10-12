defmodule DragonexWeb.CustomContentLive do
  @moduledoc """
  Biblioteca de contenido custom del usuario: armas, hechizos y objetos que no
  existen en el SRD. CRUD inline con tres pestañas, validando las mecánicas a
  través de `Dragonex.Accounts`.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}
  use Gettext, backend: Dragonex.Gettext

  alias Dragonex.{Accounts, Heroes.Catalog, Heroes.Translations, I18n}
  alias Dragonex.Accounts.CustomContent

  @tabs CustomContent.kinds()

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tab, "weapon")
     |> assign(:error, nil)
     |> assign(:editing, nil)
     |> load_items()}
  end

  defp load_items(socket) do
    items = Accounts.list_custom_content(socket.assigns.current_user, socket.assigns.tab)
    assign(socket, :items, items)
  end

  # --------------------------------------------------------- navegación

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, socket |> assign(tab: tab, editing: nil, error: nil) |> load_items()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(editing: blank_editing(socket.assigns.tab), error: nil)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case Accounts.get_custom_content(socket.assigns.current_user, id) do
      nil ->
        {:noreply, assign(socket, :error, dgettext("ui", "No encontrado."))}

      cc ->
        {:noreply,
         socket
         |> assign(tab: cc.kind, error: nil)
         |> assign(:editing, editing_from_row(cc))
         |> load_items()}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  # Campos del form serializados por LiveView (allowlist de strings para no
  # inflar la tabla de átomos). Los checkboxes (finesse/ranged) van aparte: un
  # checkbox DESMARCADO no se envía en el payload, así que se leen por presencia.
  @text_fields ~w(name notes dice damage_type attack_ability level spell_kind save_ability effect qty item_kind)
  @checkbox_fields ~w(finesse ranged)

  # --------------------------------------------------------- cambios del form

  # El <form phx-change> serializa TODOS los campos en cada cambio; los
  # mergeamos en `editing` para que sea la fuente de verdad de la UI (inputs
  # controlados: así no se resetean al re-renderizar tras un toggle/cambio).
  @impl true
  def handle_event("change", params, socket) do
    {:noreply,
     update(socket, :editing, fn
       nil -> nil
       e -> apply_form(e, params)
     end)}
  end

  @impl true
  def handle_event("toggle_class", %{"class" => class}, socket) do
    {:noreply,
     update(socket, :editing, fn
       nil -> nil
       e -> %{e | classes: toggle(e.classes, class)}
     end)}
  end

  # --------------------------------------------------------- guardar / borrar

  @impl true
  def handle_event("save", _params, socket) do
    %{editing: e, current_user: user} = socket.assigns

    case editing_to_attrs(e) do
      {:ok, attrs} ->
        result =
          if e.id do
            Accounts.update_custom_content(user, e.id, attrs)
          else
            Accounts.create_custom_content(user, attrs)
          end

        case result do
          {:ok, _} ->
            {:noreply, socket |> assign(editing: nil, error: nil) |> load_items()}

          {:error, :conflict} ->
            {:noreply,
             assign(socket, :error, dgettext("ui", "Ya tienes un contenido con ese nombre."))}

          {:error, reason} when is_binary(reason) ->
            {:noreply, assign(socket, :error, reason)}

          {:error, _} ->
            {:noreply,
             assign(socket, :error, dgettext("ui", "No se pudo guardar. Revisa las mecánicas."))}
        end

      {:error, msg} ->
        {:noreply, assign(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    error =
      case Accounts.delete_custom_content(socket.assigns.current_user, id) do
        {:ok, _} -> nil
        {:error, _} -> dgettext("ui", "No se pudo borrar.")
      end

    {:noreply, socket |> assign(:error, error) |> load_items()}
  end

  # --------------------------------------------------------- helpers de form

  defp blank_editing(kind) do
    %{
      id: nil,
      kind: kind,
      name: "",
      notes: "",
      dice: "",
      damage_type: if(kind == "weapon", do: "slashing", else: ""),
      attack_ability: "str",
      finesse: false,
      ranged: false,
      level: if(kind == "spell", do: 0, else: nil),
      spell_kind: "save",
      save_ability: "",
      effect: "",
      classes: [],
      qty: 1,
      item_kind: "magic"
    }
  end

  defp editing_from_row(%CustomContent{
         id: id,
         kind: kind,
         name_es: name,
         notes: notes,
         definition: d
       }) do
    base = blank_editing(kind)

    Map.merge(base, %{
      id: id,
      name: name || "",
      notes: notes || "",
      dice: d["dice"] || "",
      damage_type: d["damage_type"] || "",
      attack_ability: d["attack_ability"] || "str",
      finesse: d["finesse"] || false,
      ranged: d["ranged"] || false,
      level: d["level"],
      spell_kind: d["kind"] || "save",
      save_ability: d["save_ability"] || "",
      effect: d["effect"] || "",
      classes: d["classes"] || [],
      qty: d["qty"] || 1,
      item_kind: d["kind"] || "magic"
    })
  end

  defp editing_to_attrs(nil), do: {:error, dgettext("ui", "Nada que guardar.")}

  defp editing_to_attrs(%{kind: kind, name: name} = e) do
    name = String.trim(name || "")

    if name == "",
      do: {:error, dgettext("ui", "El nombre es obligatorio.")},
      else:
        {:ok, %{kind: kind, name_es: name, notes: e.notes, definition: definition_for(kind, e)}}
  end

  defp definition_for("weapon", e) do
    %{
      "dice" => e.dice,
      "damage_type" => e.damage_type,
      "attack_ability" => e.attack_ability,
      "finesse" => e.finesse == true,
      "ranged" => e.ranged == true
    }
  end

  defp definition_for("spell", e) do
    save = if e.save_ability in ["", nil], do: nil, else: e.save_ability

    %{
      "level" => e.level,
      "kind" => e.spell_kind,
      "save_ability" => save,
      "dice" => if(e.dice == "", do: nil, else: e.dice),
      "damage_type" => if(e.damage_type == "", do: nil, else: e.damage_type),
      "effect" => e.effect,
      "classes" => e.classes
    }
  end

  defp definition_for("item", e) do
    %{
      "qty" => e.qty || 1,
      "kind" => e.item_kind,
      "effect" => if(e.effect == "", do: nil, else: e.effect)
    }
  end

  # --------------------------------------------------------- helpers de render

  defp tab_label("weapon"), do: dgettext("ui", "Armas")
  defp tab_label("spell"), do: dgettext("ui", "Hechizos")
  defp tab_label("item"), do: dgettext("ui", "Objetos")

  defp create_label("weapon"), do: dgettext("ui", "+ Crear arma")
  defp create_label("spell"), do: dgettext("ui", "+ Crear hechizo")
  defp create_label("item"), do: dgettext("ui", "+ Crear objeto")

  defp empty_label("weapon"), do: dgettext("ui", "Aún no tienes armas.")
  defp empty_label("spell"), do: dgettext("ui", "Aún no tienes hechizos.")
  defp empty_label("item"), do: dgettext("ui", "Aún no tienes objetos.")

  defp confirm_msg(name),
    do: dgettext("ui", "¿Borrar \"%{name}\"? Esta acción no se puede deshacer.", name: name)

  defp classes_list, do: Dragonex.Heroes.Classes.keys()

  defp ability_label(a) when a in [nil, "", :none], do: "—"
  defp ability_label(a), do: Translations.ability(a, I18n.locale())

  defp damage_label(d) when d in [nil, ""], do: "—"
  defp damage_label(d), do: Translations.damage_type(d, I18n.locale())

  defp dice_label(d) when d in [nil, ""], do: "—"
  defp dice_label(d), do: d

  defp weapon_props(d) do
    []
    |> maybe_prop(d["finesse"] == true, dgettext("ui", "sutil"))
    |> maybe_prop(d["ranged"] == true, dgettext("ui", "a distancia"))
  end

  defp maybe_prop(list, true, label), do: list ++ [label]
  defp maybe_prop(list, _, _), do: list

  defp class_labels(nil), do: []

  defp class_labels(classes) do
    Enum.map(classes, &Translations.class(to_string(&1), I18n.locale()))
  end

  attr(:cc, :map, required: true)

  defp detail(%{cc: %CustomContent{kind: "weapon"} = cc} = assigns) do
    assigns =
      assign(assigns,
        d: cc.definition,
        props: weapon_props(cc.definition),
        notes: cc.notes
      )

    ~H"""
    <div class="detail-grid">
      <.dc label={dgettext("ui", "Dados")} value={dice_label(@d["dice"])} />
      <.dc label={dgettext("ui", "Daño")} value={damage_label(@d["damage_type"])} />
      <.dc label={dgettext("ui", "Ataque")} value={ability_label(@d["attack_ability"])} />
      <.dc label={dgettext("ui", "Propiedades")} value={if @props == [], do: "—", else: Enum.join(@props, ", ")} />
    </div>
    <div :if={@notes} class="note">{@notes}</div>
    """
  end

  defp detail(%{cc: %CustomContent{kind: "spell"} = cc} = assigns) do
    d = cc.definition

    level_label =
      if d["level"] == 0,
        do: dgettext("ui", "Truco"),
        else: dgettext("ui", "Nivel %{level}", level: d["level"])

    assigns =
      assign(assigns,
        d: d,
        level_label: level_label,
        classes: class_labels(d["classes"]),
        notes: cc.notes
      )

    ~H"""
    <div class="detail-grid">
      <.dc label={dgettext("ui", "Nivel")} value={@level_label} />
      <.dc label={dgettext("ui", "Tipo")} value={Translations.kind(@d["kind"], I18n.locale())} />
      <.dc label={dgettext("ui", "Salvación")} value={ability_label(@d["save_ability"])} />
      <.dc label={dgettext("ui", "Dados")} value={dice_label(@d["dice"])} />
      <.dc label={dgettext("ui", "Daño")} value={damage_label(@d["damage_type"])} />
    </div>
    <div :if={@classes != []} class="note"><span class="note-label">{dgettext("ui", "Clases:")}</span> {Enum.join(@classes, ", ")}</div>
    <div :if={@d["effect"]} class="note">{@d["effect"]}</div>
    <div :if={@notes} class="note">{@notes}</div>
    """
  end

  defp detail(%{cc: %CustomContent{kind: "item"} = cc} = assigns) do
    assigns = assign(assigns, d: cc.definition, notes: cc.notes)

    ~H"""
    <div class="detail-grid">
      <.dc label={dgettext("ui", "Cantidad")} value={to_string(@d["qty"])} />
      <.dc label={dgettext("ui", "Tipo")} value={Catalog.item_kind_label(@d["kind"], I18n.locale())} />
    </div>
    <div :if={@d["effect"]} class="note">{@d["effect"]}</div>
    <div :if={@notes} class="note">{@notes}</div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, default: "—")

  defp dc(assigns) do
    ~H"""
    <div class="dc">
      <span>{@label}</span>
      <strong>{@value}</strong>
    </div>
    """
  end

  defp chip_class(classes, c), do: if(c in classes, do: "chip sel", else: "chip")

  # --------------------------------------------------------- render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page cc">

      <div><.link navigate="/" class="nav-link">{dgettext("ui", "← partidas")}</.link></div>
      <header class="page-head">
        <div>
          <h1 class="page-title">{dgettext("ui", "Mi contenido")}</h1>
          <p class="sub">{dgettext("ui", "Armas, hechizos y objetos que no existen en el SRD. Tus héroes pueden llevarlos a la partida.")}</p>
        </div>
      </header>

      <div class="tabs">
        <%= for t <- tabs() do %>
          <button class={"tab #{if @tab == t, do: "active", else: ""}"} phx-click="tab" phx-value-tab={t}>
            {tab_label(t)}
          </button>
        <% end %>
      </div>

      <div class="panel">
        <div class="panel-head">
          <strong>{tab_label(@tab)} ({length(@items)})</strong>
          <button class="btn btn-primary btn-sm" phx-click="new" :if={is_nil(@editing)}>{create_label(@tab)}</button>
        </div>

        <div :if={@error} class="error">{@error}</div>

        <form :if={@editing} id="custom-content-form" phx-change="change" phx-submit="save" class="form-card">
          <.form_fields editing={@editing} />
          <div class="form-actions">
            <button class="btn btn-primary" type="submit">{if @editing.id, do: dgettext("ui", "Guardar cambios"), else: dgettext("ui", "Crear")}</button>
            <button class="btn btn-ghost" type="button" phx-click="cancel">{dgettext("ui", "Cancelar")}</button>
          </div>
        </form>

        <div :if={!@editing}>
          <div :for={cc <- @items} :key={cc.id} class="item-row">
            <div class="item-head">
              <div class="name">{cc.name_es}</div>
              <div class="item-head-actions">
                <button class="btn btn-ghost btn-sm" phx-click="edit" phx-value-id={cc.id}>{dgettext("ui", "Editar")}</button>
                <button class="btn btn-danger btn-sm" phx-click="delete" phx-value-id={cc.id} data-confirm={confirm_msg(cc.name_es)}>{dgettext("ui", "Borrar")}</button>
              </div>
            </div>
            <.detail cc={cc} />
          </div>
          <div :if={@items == []} class="empty">{empty_label(@tab)}</div>
        </div>
      </div>
    </div>
    """
  end

  attr(:editing, :map, required: true)

  defp form_fields(%{editing: %{kind: "weapon"}} = assigns) do
    ~H"""
    <div class="field">
      <label>{dgettext("ui", "Nombre")}</label>
      <input type="text" name="name" value={@editing.name} />
    </div>
    <div class="inline">
      <div class="field">
        <label>{dgettext("ui", "Dados (p. ej. 2d6, 1d8+2)")}</label>
        <input type="text" name="dice" value={@editing.dice} />
        <span :if={dice_status(@editing.dice) == :invalid} class="hint bad">{dgettext("ui", "no válido (usa 2d6, 1d8+2…)")}</span>
        <span :if={dice_status(@editing.dice) == :valid} class="hint ok">{dgettext("ui", "✓ válido")}</span>
      </div>
      <div class="field">
        <label>{dgettext("ui", "Tipo de daño")}</label>
        <select name="damage_type">
          <%= for dt <- damage_types() do %>
            <option value={dt} selected={@editing.damage_type == dt}>{Translations.damage_type(dt, I18n.locale())}</option>
          <% end %>
        </select>
      </div>
    </div>
    <div class="inline">
      <div class="field">
        <label>{dgettext("ui", "Característica de ataque")}</label>
        <select name="attack_ability">
          <%= for a <- abilities() do %>
            <option value={a} selected={@editing.attack_ability == a}>{Translations.ability(a, I18n.locale())}</option>
          <% end %>
        </select>
      </div>
      <div class="field">
        <label>{dgettext("ui", "Propiedades")}</label>
        <div class="checks">
          <label class="check">
            <input type="checkbox" name="finesse" checked={@editing.finesse} /> {dgettext("ui", "Agilidad (finesse)")}
          </label>
          <label class="check">
            <input type="checkbox" name="ranged" checked={@editing.ranged} /> {dgettext("ui", "A distancia")}
          </label>
        </div>
      </div>
    </div>
    <div class="field">
      <label>{dgettext("ui", "Notas (opcional)")}</label>
      <textarea name="notes">{@editing.notes}</textarea>
    </div>
    """
  end

  defp form_fields(%{editing: %{kind: "spell"}} = assigns) do
    ~H"""
    <div class="field">
      <label>{dgettext("ui", "Nombre")}</label>
      <input type="text" name="name" value={@editing.name} />
    </div>
    <div class="inline">
      <div class="field">
        <label>{dgettext("ui", "Nivel (0–9)")}</label>
        <select name="level">
          <%= for n <- 0..9 do %>
            <option value={n} selected={@editing.level == n}>{n}</option>
          <% end %>
        </select>
      </div>
      <div class="field">
        <label>{dgettext("ui", "Tipo de tirada")}</label>
        <select name="spell_kind">
          <%= for k <- spell_kinds() do %>
            <option value={k} selected={@editing.spell_kind == k}>{Translations.kind(k, I18n.locale())}</option>
          <% end %>
        </select>
      </div>
    </div>
    <div class="inline">
      <div class="field">
        <label>{dgettext("ui", "Característica de salvación (si aplica)")}</label>
        <select name="save_ability">
          <option value="" selected={@editing.save_ability in ["", nil]}>{dgettext("ui", "(ninguna)")}</option>
          <%= for a <- abilities() do %>
            <option value={a} selected={@editing.save_ability == a}>{Translations.ability(a, I18n.locale())}</option>
          <% end %>
        </select>
      </div>
      <div class="field">
        <label>{dgettext("ui", "Dados (opcional)")}</label>
        <input type="text" name="dice" value={@editing.dice} placeholder="6d6" />
        <span :if={dice_status(@editing.dice) == :invalid} class="hint bad">{dgettext("ui", "no válido (usa 6d6, 3d8+2…)")}</span>
      </div>
    </div>
    <div class="field">
      <label>{dgettext("ui", "Tipo de daño (opcional)")}</label>
      <select name="damage_type">
        <option value="" selected={@editing.damage_type in ["", nil]}>{dgettext("ui", "(ninguno)")}</option>
        <%= for dt <- damage_types() do %>
          <option value={dt} selected={@editing.damage_type == dt}>{Translations.damage_type(dt, I18n.locale())}</option>
        <% end %>
      </select>
    </div>
    <div class="field">
      <label>{dgettext("ui", "Efecto / descripción")}</label>
      <textarea name="effect">{@editing.effect}</textarea>
    </div>
    <div class="field">
      <label>{dgettext("ui", "Clases que pueden elegirlo")}</label>
      <div class="chips">
        <%= for c <- classes_list() do %>
          <button type="button" class={chip_class(@editing.classes, c)}
                  phx-click="toggle_class" phx-value-class={c}>
            {Translations.class(c, I18n.locale())}
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp form_fields(%{editing: %{kind: "item"}} = assigns) do
    ~H"""
    <div class="field">
      <label>{dgettext("ui", "Nombre")}</label>
      <input type="text" name="name" value={@editing.name} />
    </div>
    <div class="inline">
      <div class="field">
        <label>{dgettext("ui", "Cantidad")}</label>
        <input type="number" name="qty" value={@editing.qty} min="1" />
      </div>
      <div class="field">
        <label>{dgettext("ui", "Tipo de objeto")}</label>
        <select name="item_kind">
          <%= for k <- item_kinds() do %>
            <option value={k} selected={@editing.item_kind == k}>{Catalog.item_kind_label(k, I18n.locale())}</option>
          <% end %>
        </select>
      </div>
    </div>
    <div class="field">
      <label>{dgettext("ui", "Efecto / notas (opcional)")}</label>
      <textarea name="effect">{@editing.effect}</textarea>
    </div>
    <div class="field">
      <label>{dgettext("ui", "Notas")}</label>
      <textarea name="notes">{@editing.notes}</textarea>
    </div>
    """
  end

  defp abilities, do: CustomContent.abilities()
  defp spell_kinds, do: CustomContent.spell_kinds()
  defp item_kinds, do: CustomContent.item_kinds()
  defp tabs, do: @tabs
  defp damage_types, do: Translations.damage_types()

  defp dice_status(""), do: :empty
  defp dice_status(nil), do: :empty

  defp dice_status(dice) when is_binary(dice) do
    if Dragonex.Dice.valid?(dice), do: :valid, else: :invalid
  end

  defp normalize("level", v), do: parse_int(v)
  defp normalize("qty", v), do: parse_int(v)
  defp normalize(_, v), do: v

  # Mergea los campos del form en `editing`. Texto/selects: solo si están
  # presentes en el payload. Checkboxes: presencia = true, ausencia = false.
  defp apply_form(e, params) do
    e =
      Enum.reduce(@checkbox_fields, e, fn field, acc ->
        Map.put(acc, String.to_existing_atom(field), Map.has_key?(params, field))
      end)

    Enum.reduce(@text_fields, e, fn field, acc ->
      case Map.fetch(params, field) do
        {:ok, v} -> Map.put(acc, String.to_existing_atom(field), normalize(field, v))
        :error -> acc
      end
    end)
  end

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(v), do: v

  defp toggle(list, value) do
    if value in list, do: list -- [value], else: list ++ [value]
  end
end
