defmodule HalC2.AcpWorkspacesTest do
  use ExUnit.Case, async: false

  # Pi and Cursor keep a folder's skills under {HalC2.Acp, id, :workspaces}.
  # A re-probe (`forget/1`) keeps what the user already saw; a removed
  # instance (`drop/1`) takes it away.
  @id "acp-workspaces-test"
  @key {HalC2.Acp, @id, :workspaces}

  setup do
    :persistent_term.put(@key, %{"/w" => %{"skills" => []}})
    on_exit(fn -> :persistent_term.erase(@key) end)
  end

  test "forget keeps workspace snapshots" do
    HalC2.Acp.forget(@id)
    assert %{"/w" => _} = :persistent_term.get(@key, %{})
  end

  test "drop erases workspace snapshots" do
    HalC2.Acp.drop(@id)
    assert :persistent_term.get(@key, %{}) == %{}
  end
end
