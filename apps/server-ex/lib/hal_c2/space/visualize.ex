defmodule HalC2.Space.Visualize do
  @moduledoc """
  Answers a request for a chart from real numbers, or not at all. A model left with no
  data invents some, so it decides only what to draw:

  - From what this MC counts (`@datasets`): the model picks the count, type and title,
    and the numbers are the MC's own, never the model's.
  - From the page: the model reads the labels and values off the page's text, and every
    value has to be a number written there. That proves the number is on the page, not
    that it belongs to its label.

  Anything else is refused. The source a chart names is written here, not by the model.
  """

  alias HalC2.Space.Chart
  alias HalC2.{Store, StreamState, TextGeneration}

  @page_bytes 8_000
  @weeks 12
  @bars 12

  @datasets %{
    "turns_by_week" => "how many turns users took per week, last 12 weeks",
    "turns_by_thread" => "how many turns users took per thread, last 12 weeks",
    "turns_by_project" => "how many turns users took per project, last 12 weeks",
    "threads_by_week" => "how many threads were started per week, last 12 weeks",
    "threads_by_project" => "how many threads each project has"
  }

  @page_source "Numbers from this page"
  @not_typed ~w(senderThreadId scheduledTaskId notification delegatedCompletion providerWake)

  @unanswerable "No chart was drawn: only numbers written on this page, and the turns and " <>
                  "threads on this MC, can be charted, and neither answers that."

  @doc """
  The chart that answers `request` on a page holding `blocks`. Errors are
  `{:error, :chart_unavailable | :chart_failed | :chart_unanswerable, message}`.
  """
  def answer(request, page, blocks) do
    text = page_text(page, blocks)

    case TextGeneration.chart(request, text, @datasets) do
      {:ok, reply} ->
        reply |> chart(request, text) |> refused()

      {:error, {:unavailable, message}} ->
        {:error, :chart_unavailable, "No chart was drawn: #{message}"}

      {:error, message} ->
        {:error, :chart_failed, "No chart was drawn: #{message}"}
    end
  end

  defp refused({:ok, chart}), do: {:ok, chart}
  defp refused(:unanswerable), do: {:error, :chart_unanswerable, @unanswerable}
  defp refused({:error, message}), do: {:error, :chart_failed, "No chart was drawn. #{message}"}

  @doc "The text a chart of this page may take its numbers from: not a chart's, not a link's."
  def page_text(page, blocks) do
    [page["title"] | for(b <- blocks, b["kind"] not in ~w(chart subpage_link), do: b["text"])]
    |> Enum.join("\n")
    |> Chart.cut(@page_bytes)
  end

  defp chart(%{"source" => "none"}, _request, _text), do: :unanswerable

  defp chart(%{"source" => "page"} = reply, request, text) do
    with {:ok, data} <- page_data(reply["chart"]),
         {:ok, chart} <- describe(reply, data, request, @page_source),
         :ok <- stated(chart, text),
         do: {:ok, chart}
  end

  defp chart(%{"source" => id} = reply, request, _text) when is_map_key(@datasets, id) do
    case counted(id, Date.utc_today()) do
      {labels, name, values, source} ->
        data = %{"labels" => labels, "series" => [%{"name" => name, "values" => values}]}
        describe(reply, data, request, source)

      nil ->
        :unanswerable
    end
  end

  defp chart(_reply, _request, _text), do: {:error, "The model did not say where to look."}

  defp describe(reply, data, request, source) do
    Map.merge(data, %{
      "type" => reply["type"],
      "title" => reply["title"],
      "request" => request,
      "source" => source
    })
    |> Chart.validate()
  end

  # The model's labels and series and nothing else: the MC writes the other keys.
  defp page_data(json) do
    case decode(json) do
      {:ok, %{"labels" => _, "series" => _} = data} when map_size(data) == 2 -> {:ok, data}
      _ -> {:error, "The model's chart is not a chart."}
    end
  end

  defp decode(json) when is_binary(json), do: JSON.decode(json)
  defp decode(_), do: :error

  defp stated(chart, text) do
    stated = numbers(text)
    values = Enum.flat_map(chart["series"], & &1["values"])

    if Enum.all?(values, &MapSet.member?(stated, &1 * 1.0)),
      do: :ok,
      else: {:error, "The chart holds numbers this page does not state."}
  end

  # Each number whole, as written: not the 35 in 350, the 3 in Q3, the 3 in 3k or 3.5k, any
  # part of 1.000.000 or 2.1.0, or the 5 in -5, which a chart cannot show. A dash after a
  # digit is a range's, so 10-20 is two numbers, and a comma before one is a list's, so
  # 1,2,3 is three. One too large for a float is not read.
  defp numbers(text) do
    ~r/(?<![\w.])(?<!(?<!\d)[-−])(?>(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(?!\w|\.\d)/u
    |> Regex.scan(text)
    |> Enum.flat_map(fn [number] ->
      case number |> String.replace(",", "") |> Float.parse() do
        {value, _} -> [value]
        :error -> []
      end
    end)
    |> MapSet.new()
  end

  # --- what this MC counts -----------------------------------------------------------

  # `{labels, series name, values, source}`, or nil with nothing to count. A turn is a
  # message a user typed; these are this MC's threads only, not a cluster peer's, and
  # none of the workers the sidebar leaves out.
  defp counted(id, today) do
    threads = threads()
    since = today |> Date.add(-7 * (@weeks - 1)) |> Date.beginning_of_week()

    {labels, name, values} =
      case id do
        "turns_by_week" -> weekly("Turns", turns(threads, since), today)
        "turns_by_thread" -> ranked("Turns", by_thread(turns(threads, since), threads))
        "turns_by_project" -> ranked("Turns", by_project(turns(threads, since), threads))
        "threads_by_week" -> weekly("Threads", started(threads, since), today)
        "threads_by_project" -> ranked("Threads", by_project(one_each(threads), threads))
      end

    if Enum.any?(values, &(&1 > 0)), do: {labels, name, values, source(id, threads, today)}
  end

  defp source(id, threads, today) do
    count = map_size(threads)
    of = "#{count} #{if count == 1, do: "thread", else: "threads"}"

    if String.ends_with?(id, "_project") and String.starts_with?(id, "threads"),
      do: "Counted by this MC from its #{of} on #{today}",
      else: "Counted by this MC from its #{of}, #{@weeks} weeks to #{today}"
  end

  defp threads do
    for {{mc, id}, {"thread", row}} <- HalC2.Shell.rows(),
        mc == node() and row["deletedAt"] == nil,
        get_in(row, ["lineage", "relationshipToParent"]) != "subagent",
        into: %{},
        do: {id, row}
  end

  # `{thread id, day, 1}`s. The index says which threads to read, but not who sent a
  # message: only its entity does, so each is read from the log, not its running stream.
  defp turns(threads, since) do
    path = Store.path()
    since = Date.to_iso8601(since)

    for id <- Store.threads_messaged_since(path, since),
        is_map_key(threads, id),
        %{"createdAt" => <<day::binary-size(10), _::binary>>} = message <-
          path |> StreamState.load(id) |> StreamState.list("message"),
        day >= since and typed?(message),
        do: {id, day, 1}
  end

  # What an agent, a schedule or the MC sent has the role of a user's message too.
  defp typed?(%{"role" => "user"} = message),
    do: not Enum.any?(@not_typed, &(message[&1] != nil))

  defp typed?(_message), do: false

  defp started(threads, since) do
    since = Date.to_iso8601(since)

    for {id, %{"createdAt" => <<day::binary-size(10), _::binary>>}} <- threads,
        day >= since,
        do: {id, day, 1}
  end

  defp one_each(threads), do: for({id, _} <- threads, do: {id, nil, 1})

  defp weekly(name, rows, today) do
    weeks =
      for back <- (@weeks - 1)..0//-1,
          do: today |> Date.add(-7 * back) |> Date.beginning_of_week()

    counts =
      Enum.reduce(rows, %{}, fn {_id, day, count}, acc ->
        week = day |> Date.from_iso8601!() |> Date.beginning_of_week()
        Map.update(acc, week, count, &(&1 + count))
      end)

    {Enum.map(weeks, &Calendar.strftime(&1, "%b %-d")), name,
     Enum.map(weeks, &Map.get(counts, &1, 0))}
  end

  defp by_thread(rows, threads) do
    Enum.group_by(rows, &elem(&1, 0), &elem(&1, 2))
    |> Enum.map(fn {id, counts} -> {threads[id]["title"] || "", Enum.sum(counts)} end)
  end

  defp by_project(rows, threads) do
    projects =
      for {{mc, id}, {"project", row}} <- HalC2.Shell.rows(),
          mc == node(),
          into: %{},
          do: {id, row["title"]}

    Enum.group_by(rows, &projects[threads[elem(&1, 0)]["projectId"]], &elem(&1, 2))
    |> Enum.map(fn {title, counts} -> {title || "No project", Enum.sum(counts)} end)
  end

  # The largest first; past `@bars` the smallest fold into "Other", so the numbers still add up.
  defp ranked(name, rows) do
    rows =
      rows
      |> Enum.map(fn {label, n} -> {Chart.plain(label), n} end)
      |> Enum.sort_by(&{-elem(&1, 1), elem(&1, 0)})

    {shown, rest} = if length(rows) > @bars, do: Enum.split(rows, @bars - 1), else: {rows, []}

    other =
      if rest == [], do: [], else: [{"Other", rest |> Enum.map(&elem(&1, 1)) |> Enum.sum()}]

    rows = shown ++ other
    {Enum.map(rows, &elem(&1, 0)), name, Enum.map(rows, &elem(&1, 1))}
  end
end
