defmodule DragonexWeb.CustomContentLive do
  @moduledoc """
  Biblioteca de contenido custom del usuario: armas, hechizos y objetos que no
  existen en el SRD. CRUD inline con tres pestañas, validando las mecánicas a
  través de `Dragonex.Accounts`.
  """

  use Phoenix.LiveView, layout: {DragonexWeb.Layouts, :app}

  alias Dragonex.{Accounts, Heroes.Catalog, Heroes.Translations}
  alias Dragonex.Accounts.CustomContent

  @tabs CustomContent.kinds()

  @impl true
  def mount(_params, session, socket) do
    case Accounts.get_user(session["user_id"]) do
      nil ->
        {:ok, Phoenix.LiveView.redirect(socket, to: "/login")}

      user ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:tab, "weapon")
         |> assign(:error, nil)
         |> assign(:editing, nil)
         |> load_items()}
    end
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
        {:noreply, assign(socket, :error, "No encontrado.")}

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
            {:noreply, assign(socket, :error, "Ya tienes un contenido con ese nombre.")}

          {:error, reason} when is_binary(reason) ->
            {:noreply, assign(socket, :error, reason)}

          {:error, _} ->
            {:noreply, assign(socket, :error, "No se pudo guardar. Revisa las mecánicas.")}
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
        {:error, _} -> "No se pudo borrar."
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

  defp editing_to_attrs(nil), do: {:error, "Nada que guardar."}

  defp editing_to_attrs(%{kind: kind, name: name} = e) do
    name = String.trim(name || "")

    if name == "",
      do: {:error, "El nombre es obligatorio."},
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

  defp tab_label("weapon"), do: "Armas"
  defp tab_label("spell"), do: "Hechizos"
  defp tab_label("item"), do: "Objetos"

  defp tab_singular("weapon"), do: "arma"
  defp tab_singular("spell"), do: "hechizo"
  defp tab_singular("item"), do: "objeto"

  defp confirm_msg(name), do: "¿Borrar \"#{name}\"? Esta acción no se puede deshacer."

  defp classes_list, do: Dragonex.Heroes.Classes.keys()

  defp ability_label(a) when a in [nil, "", :none], do: "—"
  defp ability_label(a), do: Translations.ability(a, :es)

  defp damage_label(d) when d in [nil, ""], do: "—"
  defp damage_label(d), do: Translations.damage_type(d, :es)

  defp dice_label(d) when d in [nil, ""], do: "—"
  defp dice_label(d), do: d

  defp weapon_props(d) do
    []
    |> maybe_prop(d["finesse"] == true, "sutil")
    |> maybe_prop(d["ranged"] == true, "a distancia")
  end

  defp maybe_prop(list, true, label), do: list ++ [label]
  defp maybe_prop(list, _, _), do: list

  defp class_labels(nil), do: []

  defp class_labels(classes) do
    Enum.map(classes, &Translations.class(to_string(&1), :es))
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
      <.dc label="Dados" value={dice_label(@d["dice"])} />
      <.dc label="Daño" value={damage_label(@d["damage_type"])} />
      <.dc label="Ataque" value={ability_label(@d["attack_ability"])} />
      <.dc label="Propiedades" value={if @props == [], do: "—", else: Enum.join(@props, ", ")} />
    </div>
    <div :if={@notes} class="note">{@notes}</div>
    """
  end

  defp detail(%{cc: %CustomContent{kind: "spell"} = cc} = assigns) do
    d = cc.definition
    level_label = if d["level"] == 0, do: "Truco", else: "Nivel #{d["level"]}"

    assigns =
      assign(assigns,
        d: d,
        level_label: level_label,
        classes: class_labels(d["classes"]),
        notes: cc.notes
      )

    ~H"""
    <div class="detail-grid">
      <.dc label="Nivel" value={@level_label} />
      <.dc label="Tipo" value={Translations.kind(@d["kind"], :es)} />
      <.dc label="Salvación" value={ability_label(@d["save_ability"])} />
      <.dc label="Dados" value={dice_label(@d["dice"])} />
      <.dc label="Daño" value={damage_label(@d["damage_type"])} />
    </div>
    <div :if={@classes != []} class="note"><span class="note-label">Clases:</span> {Enum.join(@classes, ", ")}</div>
    <div :if={@d["effect"]} class="note">{@d["effect"]}</div>
    <div :if={@notes} class="note">{@notes}</div>
    """
  end

  defp detail(%{cc: %CustomContent{kind: "item"} = cc} = assigns) do
    assigns = assign(assigns, d: cc.definition, notes: cc.notes)

    ~H"""
    <div class="detail-grid">
      <.dc label="Cantidad" value={to_string(@d["qty"])} />
      <.dc label="Tipo" value={Catalog.item_kind_label(@d["kind"], :es)} />
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
    <div class="cc">
      <style>
        .cc{width:min(1100px,calc(100% - 3rem));margin:0 auto;padding:clamp(1rem,2vw,2rem) 0 2.5rem;font-family:Georgia,'Times New Roman',serif;color:#ccc;}
        .cc *{box-sizing:border-box;}
        .cc h1{font-size:clamp(1.4rem,2vw,1.9rem);color:#fc8;margin:.5rem 0 .2rem;}
        .cc .sub{color:#889;font-size:.9rem;margin-bottom:1rem;}
        .tabs{display:flex;gap:.4rem;margin-bottom:1rem;}
        .tab{padding:.5rem 1rem;border-radius:8px 8px 0 0;border:1px solid #333;border-bottom:none;background:#1c1c1c;color:#889;cursor:pointer;font-family:inherit;font-size:.9rem;}
        .tab.active{background:#241c14;color:#fc8;border-color:#a72;}
        .panel{background:rgba(22,22,22,.92);border:1px solid #333;border-radius:0 10px 10px;padding:1.2rem;}
        .item-row{padding:.7rem .2rem;border-bottom:1px solid #2a2a2a;}
        .item-row:last-child{border-bottom:none;}
        .item-head{display:flex;align-items:center;justify-content:space-between;gap:.6rem;flex-wrap:wrap;}
        .item-head .name{color:#fc8;font-size:1rem;}
        .detail-grid{display:flex;flex-wrap:wrap;gap:.4rem;margin-top:.5rem;}
        .dc{background:#222;border:1px solid #333;border-radius:6px;padding:.3rem .6rem;display:flex;flex-direction:column;gap:.12rem;min-width:54px;}
        .dc span{font-size:.62rem;color:#779;text-transform:uppercase;letter-spacing:.05em;}
        .dc strong{font-size:.82rem;color:#ccc;font-weight:normal;overflow-wrap:anywhere;}
        .note{font-size:.8rem;color:#889;margin-top:.35rem;line-height:1.4;overflow-wrap:anywhere;}
        .note-label{color:#667;}
        .btn{display:inline-flex;align-items:center;padding:.45rem .9rem;border-radius:8px;border:1px solid #a72;background:#3a2a1a;color:#fc8;font-size:.85rem;cursor:pointer;font-family:inherit;text-decoration:none;}
        .btn:hover{background:#4a3520;}
        .btn-sm{padding:.3rem .6rem;font-size:.75rem;}
        .btn-danger{background:#2a1a1a;border-color:#744;color:#f99;}
        .btn-danger:hover{background:#3a2222;}
        .btn-ghost{background:#202020;border-color:#3a3a3a;color:#9cd;}
        .btn-primary{background:#3a2a1a;}
        .error{margin:.8rem 0;color:#f99;background:#2a1a1a;border:1px solid #633;border-radius:8px;padding:.7rem;font-size:.85rem;}
        .empty{text-align:center;color:#666;font-style:italic;padding:2rem;}
        .form-card{margin-top:1rem;background:#181410;border:1px solid #443;border-radius:10px;padding:1.1rem;}
        .field{margin-bottom:.8rem;}
        .field label{display:block;font-size:.8rem;color:#aa9;margin-bottom:.25rem;}
        .field input,.field select,.field textarea{width:100%;padding:.5rem .6rem;background:#111;border:1px solid #333;border-radius:6px;color:#ddd;font-family:inherit;font-size:.9rem;}
        .field input:focus,.field select:focus,.field textarea:focus{outline:none;border-color:#a72;}
        .field textarea{min-height:60px;resize:vertical;}
        .hint{display:block;font-size:.74rem;margin-top:.25rem;}
        .hint.bad{color:#f99;}
        .hint.ok{color:#9c9;}
        .inline{display:grid;grid-template-columns:1fr 1fr;gap:.8rem;}
        .check{display:flex;align-items:center;gap:.4rem;font-size:.85rem;color:#aa9;}
        .chips{display:flex;flex-wrap:wrap;gap:.35rem;}
        .chip{padding:.25rem .6rem;border-radius:999px;border:1px solid #333;background:#1a1a1a;color:#889;font-size:.78rem;cursor:pointer;font-family:inherit;}
        .chip.sel{background:#3a2a1a;border-color:#a72;color:#fc8;}
        .nav-link{color:#7ab;text-decoration:none;font-size:.85rem;}
      </style>

      <div><.link navigate="/" class="nav-link">← partidas</.link></div>
      <h1>Mi contenido</h1>
      <div class="sub">Armas, hechizos y objetos que no existen en el SRD. Tu héroe puede llevarlos a la partida.</div>

      <div class="tabs">
        <%= for t <- tabs() do %>
          <button class={"tab #{if @tab == t, do: "active", else: ""}"} phx-click="tab" phx-value-tab={t}>
            {tab_label(t)}
          </button>
        <% end %>
      </div>

      <div class="panel">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.6rem;">
          <strong style="color:#aa9;">{tab_label(@tab)} ({length(@items)})</strong>
          <button class="btn btn-sm" phx-click="new" :if={is_nil(@editing)}>+ Crear {tab_singular(@tab)}</button>
        </div>

        <div :if={@error} class="error">{@error}</div>

        <form :if={@editing} phx-change="change" phx-submit="save" class="form-card">
          <.form_fields editing={@editing} />
          <div style="display:flex;gap:.5rem;margin-top:.6rem;">
            <button class="btn btn-primary" type="submit">{if @editing.id, do: "Guardar cambios", else: "Crear"}</button>
            <button class="btn btn-ghost" type="button" phx-click="cancel">Cancelar</button>
          </div>
        </form>

        <div :if={!@editing}>
          <div :for={cc <- @items} :key={cc.id} class="item-row">
            <div class="item-head">
              <div class="name">{cc.name_es}</div>
              <div style="display:flex;gap:.4rem;">
                <button class="btn btn-ghost btn-sm" phx-click="edit" phx-value-id={cc.id}>editar</button>
                <button class="btn btn-danger btn-sm" phx-click="delete" phx-value-id={cc.id} data-confirm={confirm_msg(cc.name_es)}>borrar</button>
              </div>
            </div>
            <.detail cc={cc} />
          </div>
          <div :if={@items == []} class="empty">Aún no tienes {tab_label(@tab) |> String.downcase()}.</div>
        </div>
      </div>
    </div>
    """
  end

  attr(:editing, :map, required: true)

  defp form_fields(%{editing: %{kind: "weapon"}} = assigns) do
    ~H"""
    <div class="field">
      <label>Nombre</label>
      <input type="text" name="name" value={@editing.name} />
    </div>
    <div class="inline">
      <div class="field">
        <label>Dados (p. ej. 2d6, 1d8+2)</label>
        <input type="text" name="dice" value={@editing.dice} />
        <span :if={dice_status(@editing.dice) == :invalid} class="hint bad">no válido (usa 2d6, 1d8+2…)</span>
        <span :if={dice_status(@editing.dice) == :valid} class="hint ok">✓ válido</span>
      </div>
      <div class="field">
        <label>Tipo de daño</label>
        <select name="damage_type">
          <%= for dt <- damage_types() do %>
            <option value={dt} selected={@editing.damage_type == dt}>{Translations.damage_type(dt, :es)}</option>
          <% end %>
        </select>
      </div>
    </div>
    <div class="inline">
      <div class="field">
        <label>Característica de ataque</label>
        <select name="attack_ability">
          <%= for a <- abilities() do %>
            <option value={a} selected={@editing.attack_ability == a}>{Translations.ability(a, :es)}</option>
          <% end %>
        </select>
      </div>
      <div class="field">
        <label>Propiedades</label>
        <div style="display:flex;gap:1rem;padding-top:.4rem;">
          <label class="check">
            <input type="checkbox" name="finesse" checked={@editing.finesse} /> Agilidad (finesse)
          </label>
          <label class="check">
            <input type="checkbox" name="ranged" checked={@editing.ranged} /> A distancia
          </label>
        </div>
      </div>
    </div>
    <div class="field">
      <label>Notas (opcional)</label>
      <textarea name="notes">{@editing.notes}</textarea>
    </div>
    """
  end

  defp form_fields(%{editing: %{kind: "spell"}} = assigns) do
    ~H"""
    <div class="field">
      <label>Nombre</label>
      <input type="text" name="name" value={@editing.name} />
    </div>
    <div class="inline">
      <div class="field">
        <label>Nivel (0–9)</label>
        <select name="level">
          <%= for n <- 0..9 do %>
            <option value={n} selected={@editing.level == n}>{n}</option>
          <% end %>
        </select>
      </div>
      <div class="field">
        <label>Tipo de tirada</label>
        <select name="spell_kind">
          <%= for k <- spell_kinds() do %>
            <option value={k} selected={@editing.spell_kind == k}>{Translations.kind(k, :es)}</option>
          <% end %>
        </select>
      </div>
    </div>
    <div class="inline">
      <div class="field">
        <label>Característica de salvación (si aplica)</label>
        <select name="save_ability">
          <option value="" selected={@editing.save_ability in ["", nil]}>(ninguna)</option>
          <%= for a <- abilities() do %>
            <option value={a} selected={@editing.save_ability == a}>{Translations.ability(a, :es)}</option>
          <% end %>
        </select>
      </div>
      <div class="field">
        <label>Dados (opcional)</label>
        <input type="text" name="dice" value={@editing.dice} placeholder="6d6" />
        <span :if={dice_status(@editing.dice) == :invalid} class="hint bad">no válido (usa 6d6, 3d8+2…)</span>
      </div>
    </div>
    <div class="field">
      <label>Tipo de daño (opcional)</label>
      <select name="damage_type">
        <option value="" selected={@editing.damage_type in ["", nil]}>(ninguno)</option>
        <%= for dt <- damage_types() do %>
          <option value={dt} selected={@editing.damage_type == dt}>{Translations.damage_type(dt, :es)}</option>
        <% end %>
      </select>
    </div>
    <div class="field">
      <label>Efecto / descripción</label>
      <textarea name="effect">{@editing.effect}</textarea>
    </div>
    <div class="field">
      <label>Clases que pueden elegirlo</label>
      <div class="chips">
        <%= for c <- classes_list() do %>
          <button type="button" class={chip_class(@editing.classes, c)}
                  phx-click="toggle_class" phx-value-class={c}>
            {Translations.class(c, :es)}
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp form_fields(%{editing: %{kind: "item"}} = assigns) do
    ~H"""
    <div class="field">
      <label>Nombre</label>
      <input type="text" name="name" value={@editing.name} />
    </div>
    <div class="inline">
      <div class="field">
        <label>Cantidad</label>
        <input type="number" name="qty" value={@editing.qty} min="1" />
      </div>
      <div class="field">
        <label>Tipo de objeto</label>
        <select name="item_kind">
          <%= for k <- item_kinds() do %>
            <option value={k} selected={@editing.item_kind == k}>{Catalog.item_kind_label(k, :es)}</option>
          <% end %>
        </select>
      </div>
    </div>
    <div class="field">
      <label>Efecto / notas (opcional)</label>
      <textarea name="effect">{@editing.effect}</textarea>
    </div>
    <div class="field">
      <label>Notas</label>
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
