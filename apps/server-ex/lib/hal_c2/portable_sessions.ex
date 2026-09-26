defmodule HalC2.PortableSessions do
  @moduledoc """
  An agent's own session carried in a thread file, so the agent picks up where it
  left off on another machine instead of receiving a handoff.
  """

  @doc "The session a thread file carries for a thread, or `nil`."
  def export(_state, _thread, _cwd), do: nil

  @doc "Places a carried session on this machine: `{changes, notes}`."
  def place(_session, _root, _archive), do: {[], []}
end
