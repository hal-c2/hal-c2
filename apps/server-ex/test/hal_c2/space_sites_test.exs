defmodule HalC2.SpaceSitesTest do
  use ExUnit.Case, async: true

  alias HalC2.{Patch, StreamState, Web}
  alias HalC2.Space.Sites

  @reached %{"address" => "http://mc.test:1", "localOnly" => false}

  defp state_with(entities) do
    Enum.reduce(entities, %StreamState{}, fn {kind, id, entity}, state ->
      StreamState.apply_event(state, %{
        seq: state.seq + 1,
        kind: kind,
        entity: id,
        patch: Patch.diff(nil, entity)
      })
    end)
  end

  @page %{"id" => "p", "spaceId" => "s", "title" => "Roadmap", "trashedAt" => nil}

  # Found by the Space property: the empty patch crashed the Space's stream.
  test "publishing again in the same instant with nothing changed writes nothing" do
    state = state_with([{"page", "p", @page}])
    at = "2026-11-01T00:00:00.000Z"

    {[{"site", token, patch}], {:ok, site}} = Sites.publish(state, "p", @reached, at)
    state = StreamState.apply_event(state, %{seq: 2, kind: "site", entity: token, patch: patch})

    assert {[], {:ok, ^site}} = Sites.publish(state, "p", @reached, at)
  end

  describe "the network address of an MC listening on every interface" do
    defp up(ip), do: {"if", [flags: [:up], addr: ip]}

    test "a home or office network comes before a bridge, and that before anything else" do
      assert Web.network_ip({:ok, [up({100, 64, 0, 1}), up({192, 168, 1, 20})]}) == "192.168.1.20"
      assert Web.network_ip({:ok, [up({172, 17, 0, 1}), up({10, 0, 0, 5})]}) == "10.0.0.5"
      assert Web.network_ip({:ok, [up({100, 64, 0, 1}), up({172, 17, 0, 1})]}) == "172.17.0.1"
      assert Web.network_ip({:ok, [up({100, 64, 0, 1})]}) == "100.64.0.1"
    end

    test "loopback, link-local, IPv6 and interfaces that are down do not count" do
      assert Web.network_ip({:ok, [up({127, 0, 0, 1}), up({169, 254, 0, 1})]}) == nil
      assert Web.network_ip({:ok, [up({0, 0, 0, 0, 0, 0, 0, 1})]}) == nil
      assert Web.network_ip({:ok, [{"if", [flags: [], addr: {192, 168, 1, 20}]}]}) == nil
      assert Web.network_ip({:error, :enotsup}) == nil
    end
  end
end
