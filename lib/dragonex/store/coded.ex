defmodule Dragonex.Store.Coded do
  @moduledoc """
  A thin `ExAgent.Store` wrapper that runs the `Dragonex.Codec` over a session's
  `shared_state` on the storage boundary, delegating everything else to the
  underlying ETS store.

  The Session always holds a real `Dragonex.World` struct; only the persisted
  form is a JSON-safe map. Use it as:

      Session.start_link(store: {Dragonex.Store.Coded, ExAgent.Store.ETS}, ...)

  Al cargar devuelve el snapshot tal cual: con
  `shared_state_codec: Dragonex.Store.WorldCodec`, la Session reconstruye el
  World después de validar el snapshot portable completo.

  The `config` is the ETS table name (defaults to `ExAgent.Store.ETS`).
  """

  @behaviour ExAgent.Store

  alias ExAgent.{Server.Snapshot, Store.ETS}
  alias ExAgent.Session.Snapshot, as: SessionSnapshot
  alias Dragonex.Codec

  @default_table ExAgent.Store.ETS

  # --- agent snapshots: pass through unchanged (no world here) -------------

  @impl true
  def save_agent_snapshot(table \\ @default_table, %Snapshot{} = snap),
    do: ETS.save_agent_snapshot(table, snap)

  @impl true
  def load_agent_snapshot(table \\ @default_table, agent_id),
    do: ETS.load_agent_snapshot(table, agent_id)

  @impl true
  def list_agent_snapshots(table \\ @default_table),
    do: ETS.list_agent_snapshots(table)

  @impl true
  def delete_agent_snapshot(table \\ @default_table, agent_id),
    do: ETS.delete_agent_snapshot(table, agent_id)

  # --- session snapshots: codec on the shared_state boundary ---------------

  @impl true
  def save_session_snapshot(table \\ @default_table, %SessionSnapshot{shared_state: ws} = snap) do
    encoded = if match?(%Dragonex.World{}, ws), do: Codec.encode(ws), else: ws
    ETS.save_session_snapshot(table, %{snap | shared_state: encoded})
  end

  @impl true
  def load_session_snapshot(table \\ @default_table, session_id),
    do: ETS.load_session_snapshot(table, session_id)

  @impl true
  def delete_session_snapshot(table \\ @default_table, session_id),
    do: ETS.delete_session_snapshot(table, session_id)
end
