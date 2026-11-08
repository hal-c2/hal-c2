defmodule HalC2.ClaudeAuthCachePropTest do
  @moduledoc """
  Claude's sign-in reads (`HalC2.Claude.Provider.auth_claim/2`, `auth_land/4`,
  `forget_auth/1`, `auth_lookup/1` — what `entry/1` reads and a refresh by
  hand forgets) against a model of one row per key: at most one read in flight
  per key, only the claimed read lands, a forget revokes the in-flight read
  and the landed answer for every key of its instance (and no other key), and
  a landed read leaves no token behind — the next claim always succeeds.
  Every operation is one atomic ETS update on its key's row, so any
  concurrent execution is one of these sequential interleavings.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Claude.Provider

  @keys [
    {"claudeAgent", "/a/claude", 1},
    {"claudeAgent", "/c/claude", 3},
    {"other", "/b/claude", 2}
  ]
  @instances ["claudeAgent", "other"]
  @results [:signed_in, :signed_out, :unreadable]

  # A model row: the last landed `{result, at}` (or nil) and the in-flight
  # read's token (or nil). `next` mints tokens and landing times.
  defp model, do: %{rows: Map.new(@keys, &{&1, %{landed: nil, token: nil}}), next: 1}

  property "claims, landings, forgets and entry reads never strand a token" do
    forall ops <-
             list(
               oneof([
                 {:claim, elements(@keys)},
                 {:land, elements(@keys), elements(@results), oneof([:current, :stale])},
                 {:forget, elements(@instances)},
                 {:lookup, elements(@keys)}
               ])
             ) do
      :ets.delete_all_objects(Provider.auth_table())

      final =
        Enum.reduce_while(ops, model(), fn op, model ->
          case step(model, op) do
            {:ok, model} -> {:cont, model}
            :error -> {:halt, :error}
          end
        end)

      final != :error and tokenless_where_landed(final)
    end
  end

  # After every interleaving, a key whose read landed (or was never claimed)
  # can be claimed again: no in-flight token was left behind.
  defp tokenless_where_landed(:error), do: false

  defp tokenless_where_landed(%{rows: rows, next: next}) do
    Enum.all?(rows, fn {key, %{token: token}} ->
      token != nil or Provider.auth_claim(key, next)
    end)
  end

  defp step(model, {:claim, key}) do
    row = model.rows[key]
    token = model.next

    if Provider.auth_claim(key, token) == (row.token == nil) do
      model =
        if row.token == nil,
          do: put_in(model, [:rows, key, :token], token),
          else: model

      {:ok, %{model | next: token + 1}}
    else
      :error
    end
  end

  defp step(model, {:land, key, result, which}) do
    row = model.rows[key]
    token = if which == :current, do: row.token, else: -1
    at = model.next
    expected = token != nil and token == row.token

    if Provider.auth_land(key, token || -1, result, at) == expected do
      model =
        if expected,
          do: put_in(model, [:rows, key], %{landed: {result, at}, token: nil}),
          else: model

      {:ok, %{model | next: at + 1}}
    else
      :error
    end
  end

  defp step(model, {:forget, instance}) do
    Provider.forget_auth([instance])

    rows =
      Map.new(model.rows, fn {{id, _, _} = key, row} ->
        if id == instance, do: {key, %{landed: nil, token: nil}}, else: {key, row}
      end)

    {:ok, %{model | rows: rows}}
  end

  defp step(model, {:lookup, key}) do
    if Provider.auth_lookup(key) == model.rows[key].landed, do: {:ok, model}, else: :error
  end
end
