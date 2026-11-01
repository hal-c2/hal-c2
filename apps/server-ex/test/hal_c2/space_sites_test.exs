defmodule HalC2.SpaceSitesTest do
  use ExUnit.Case, async: true

  alias HalC2.{Patch, StreamState}
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

    {[{"site", token, patch}], {:ok, site}} = Sites.publish(state, "p", @reached, at: at)
    state = StreamState.apply_event(state, %{seq: 2, kind: "site", entity: token, patch: patch})

    assert {[], {:ok, ^site}} = Sites.publish(state, "p", @reached, at: at)
  end
end
