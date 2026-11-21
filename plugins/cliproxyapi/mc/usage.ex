defmodule HalC2Plugins.CliProxyApi.Usage do
  @moduledoc """
  What the proxy's accounts used, summed per day × account × model from the records
  its usage queue hands out (`GET /v8/management/observability/usage/queue`), as
  plain functions over a map `%{{day, account, model} => totals}`.

  It stays bounded: only the last `@days` days are kept, so it holds at most days ×
  accounts × models rows however many requests there were. A record names its account
  by `auth_id`, or failing that `source` (an API key's group), and its model by
  `alias` or else `model`.
  """

  @days 30
  @fields ~w(requests failed inputTokens outputTokens cachedTokens reasoningTokens totalTokens)

  @doc "Days of usage kept, today included."
  def days, do: @days

  @doc "No usage yet."
  def new, do: %{}

  @doc """
  `usage` with `records` added and anything older than `@days` days before `today`
  (a `Date`) dropped. A record that is not a map, or has no timestamp it can read, is
  left out.
  """
  def add(usage, records, today) when is_list(records) do
    records
    |> Enum.reduce(usage, fn record, usage ->
      case key(record) do
        nil -> usage
        key -> Map.update(usage, key, totals(record), &sum(&1, totals(record)))
      end
    end)
    |> prune(today)
  end

  def add(usage, _records, today), do: prune(usage, today)

  @doc "`usage` without the days older than `@days` days before `today`."
  def prune(usage, today) do
    oldest = today |> Date.add(1 - @days) |> Date.to_iso8601()
    Map.filter(usage, fn {{day, _, _}, _} -> day >= oldest end)
  end

  @doc """
  The rows of the last `days` days, newest day first and each day's busiest first:
  `%{"day", "account", "model", "requests", "failed", "inputTokens", ...}`, with
  `account` the label `labels` gives the account id (its email, say), else the id.
  """
  def rows(usage, today, days, labels \\ %{}) do
    oldest = today |> Date.add(1 - days) |> Date.to_iso8601()

    usage
    |> Enum.filter(fn {{day, _, _}, _} -> day >= oldest end)
    |> Enum.sort_by(fn {{day, account, model}, totals} ->
      {day, -totals["totalTokens"], -totals["requests"], account, model}
    end)
    |> Enum.sort_by(fn {{day, _, _}, _} -> day end, :desc)
    |> Enum.map(fn {{day, account, model}, totals} ->
      Map.merge(totals, %{
        "day" => day,
        "account" => Map.get(labels, account, account),
        "model" => model
      })
    end)
  end

  @doc "The map kept on disk: a list of rows, as JSON holds them."
  def dump(usage) do
    for {{day, account, model}, totals} <- Enum.sort(usage),
        do: Map.merge(totals, %{"day" => day, "account" => account, "model" => model})
  end

  @doc "`dump/1` read back; anything that is not such a row is left out."
  def load(rows) when is_list(rows) do
    for %{"day" => day, "account" => account, "model" => model} = row <- rows,
        is_binary(day) and is_binary(account) and is_binary(model),
        into: %{},
        do: {{day, account, model}, Map.new(@fields, &{&1, count(row[&1])})}
  end

  def load(_other), do: %{}

  defp key(%{"timestamp" => at} = record) when is_binary(at) do
    with {:ok, time, _} <- DateTime.from_iso8601(at) do
      account = text(record["auth_id"]) || text(record["source"]) || "unknown"
      model = text(record["alias"]) || text(record["model"]) || "unknown"
      {time |> DateTime.to_date() |> Date.to_iso8601(), account, model}
    else
      _ -> nil
    end
  end

  defp key(_record), do: nil

  defp totals(record) do
    tokens = if is_map(record["tokens"]), do: record["tokens"], else: %{}
    input = count(tokens["input_tokens"])
    output = count(tokens["output_tokens"])

    %{
      "requests" => 1,
      "failed" => if(record["failed"] == true, do: 1, else: 0),
      "inputTokens" => input,
      "outputTokens" => output,
      "cachedTokens" => count(tokens["cached_tokens"]),
      "reasoningTokens" => count(tokens["reasoning_tokens"]),
      # A record without a total counts what went in and came out.
      "totalTokens" =>
        case count(tokens["total_tokens"]) do
          0 -> input + output
          total -> total
        end
    }
  end

  defp sum(a, b), do: Map.new(@fields, &{&1, a[&1] + b[&1]})

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_n), do: 0

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil
end
