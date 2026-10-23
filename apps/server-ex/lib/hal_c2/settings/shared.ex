defmodule HalC2.Settings.Shared do
  @moduledoc """
  Which settings follow the person across their cluster, and how members agree on them.

  A setting is shared when it says how the person likes to work and means the same on
  every machine. One that names this machine's paths, binaries, ports, hardware,
  provider instances, projects or secrets stays on its MC, and so does any key not
  listed here: the list is an allowlist, so a key added to `ServerSettings` stays put
  until someone decides otherwise. Plugin settings stay too: a plugin's options can
  name paths and ports, and which plugins run differs between machines.

  Each shared unit (a settings key, or `"keybindings"` for the whole keybindings.json
  rule list) carries a record `%{"at" => ms, "by" => environment id, "value" => v}`,
  kept in `<config>/settings-shared.json` beside the document. A record without
  `"value"` is an unset, so a reset is a stamped write like any other and nothing an
  older record holds comes back. Members keep, per unit, the record that sorts last by
  `{at, by, record}` (`merge/2`): a total order, so they agree whatever order the
  records reach them in.
  """

  # Shared: how the person works, the same on every machine. Everything else in
  # `ServerSettings`, and the `plugins` key the MC adds, stays on its MC: providers,
  # providerInstances and usageLimitSources (binary paths, environments, sealed
  # secrets), observability endpoints, storage and background activity, device and
  # agent access to this machine, environmentIcon, addProjectBaseDirectory,
  # defaultAutoPull and defaultProjectScripts, project overrides, the model selections
  # (they name provider instances, which are this MC's) and defaultTheme (it names
  # palettes this machine's desktop publishes).
  @document ~w(defaultRuntimeMode defaultThreadEnvMode newWorktreesStartFromOrigin
               worktreeSubmodules worktreeCleanup responseStreamingMode
               sidebarAutoSettleAfterDays sidebarAutoSettleOnMerge snoozeLimitedThreads
               autoResumeLimitedThreads sourceControlWritingStyle pullRequestMergeMethod
               usagePriceOverrides)
  @units ["keybindings" | @document]

  # The keys `HalC2.ProviderSecrets.seal/2` and `HalC2.UsageLimitSources.seal_keys/2`
  # take secrets out of. None of them may ever be shared.
  @sealed ~w(providers providerInstances usageLimitSources)
  for key <- @sealed, key in @units, do: raise("#{key} holds secrets and cannot be shared")

  @doc "Every shared unit: the settings keys and `\"keybindings\"`."
  def units, do: @units

  @doc "The shared keys of the settings document."
  def document_keys, do: @document

  @doc "The keys whose secrets the MC seals, which are never shared."
  def sealed_keys, do: @sealed

  @doc """
  The records with a local write, stamped `at` by `by`, for each of `units` whose value
  in `values` (unit => value, absent when unset) is not the one its record holds.
  """
  def local(records, values, units, at, by) do
    Enum.reduce(units, records, fn unit, acc ->
      held = Map.fetch(acc[unit] || %{}, "value")

      case Map.fetch(values, unit) do
        ^held -> acc
        {:ok, value} -> Map.put(acc, unit, %{"at" => at, "by" => by, "value" => value})
        :error -> Map.put(acc, unit, %{"at" => at, "by" => by})
      end
    end)
  end

  @doc """
  Per unit, the record that sorts last by `{at, by, record}`. Commutative, associative
  and idempotent, so members that have seen the same records hold the same ones.
  """
  def merge(ours, theirs) do
    Map.merge(ours, theirs, fn _unit, a, b -> if order(b) > order(a), do: b, else: a end)
  end

  defp order(record), do: {record["at"], record["by"], record}

  @doc """
  The well-formed records in `records` for units this MC shares. What another member
  sends is not trusted to be either: it may run a version that shares more, or less.
  """
  def sanitize(records) when is_map(records) do
    for {unit, %{"at" => at, "by" => by} = record} <- records,
        unit in @units and is_integer(at) and at >= 0 and is_binary(by),
        record = Map.take(record, ~w(at by value)),
        valid?(unit, record),
        into: %{},
        do: {unit, record}
  end

  def sanitize(_records), do: %{}

  defp valid?(unit, record) do
    case Map.fetch(record, "value") do
      :error -> true
      {:ok, rules} when unit == "keybindings" -> is_list(rules) and Enum.all?(rules, &rule?/1)
      {:ok, value} -> json?(value)
    end
  end

  # A keybinding rule as `HalC2.Keybindings.rules/0` reads it back.
  defp rule?(%{"key" => key, "command" => command} = rule)
       when is_binary(key) and is_binary(command) do
    case rule do
      %{"when" => condition} -> is_binary(condition) and map_size(rule) == 3
      _ -> map_size(rule) == 2
    end
  end

  defp rule?(_rule), do: false

  # Whether `value` is something settings.json can hold: a member could send any term.
  defp json?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp json?(nil), do: true
  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)

  defp json?(%{} = map),
    do: not is_struct(map) and Enum.all?(map, fn {k, v} -> is_binary(k) and json?(v) end)

  defp json?(_value), do: false

  @doc "The settings document with each shared key as its record says."
  def apply(settings, records) do
    Enum.reduce(@document, settings, fn key, acc ->
      case records[key] do
        nil -> acc
        %{"value" => value} -> Map.put(acc, key, value)
        %{} -> Map.delete(acc, key)
      end
    end)
  end

  @doc "The latest time any record holds, 0 for none."
  def newest(records),
    do: Enum.reduce(records, 0, fn {_unit, %{"at" => at}}, latest -> max(at, latest) end)

  @doc """
  The time to stamp a local write at: `now`, or just after the latest time the records
  hold when a member's clock ran ahead, so the write outranks everything it has seen.
  """
  def stamp(records, now), do: max(now, newest(records) + 1)
end
