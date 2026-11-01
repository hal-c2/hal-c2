defmodule HalC2.Space.Chart do
  @moduledoc """
  What a chart block holds: a description our own drawing code draws, and data only
  (`SpaceChart` in `packages/contracts/src/space.ts`). A description is taken whole or
  refused: only these keys, within these caps, in text that can carry no link, script,
  QML or formatting. Clients still treat it as untrusted and show its text as plain text.
  """

  @keys ~w(labels request series source title type)
  @types ~w(bar line)

  @max_labels 24
  @max_series 4
  @title_bytes 120
  @label_bytes 40
  @request_bytes 200
  @source_bytes 160
  @max_value 1.0e15

  # No description reaches this within the caps above; it is what the stream is promised.
  @max_bytes 6_144

  # Markup and table syntax, and the control and format characters that hide things.
  @markup ~r/[\p{C}<>`\[\]|\\*]/u
  @link ~r/:\/\/|\bwww\.|\b(?:javascript|vbscript|data|file|qrc|mailto):(?=\S)/iu

  @doc "The most bytes a chart takes, encoded."
  def max_bytes, do: @max_bytes

  @doc "The chart `chart` describes, or why it is refused."
  def validate(chart) when is_map(chart) do
    with :ok <- keys(chart, @keys),
         :ok <- type(chart["type"], chart["labels"]),
         :ok <- text(chart["title"], @title_bytes, "title"),
         :ok <- text(chart["request"], @request_bytes, "request"),
         :ok <- text(chart["source"], @source_bytes, "source"),
         :ok <- labels(chart["labels"]),
         :ok <- series(chart["series"], chart["labels"]),
         :ok <- size(chart),
         do: {:ok, chart}
  end

  def validate(_), do: {:error, "A chart is an object."}

  @doc "What the user asked for, without its `/visualize`, or why it is refused."
  def request(request) when is_binary(request) do
    words = request |> String.replace_prefix("/visualize", "") |> String.trim()

    with :ok <- text(words, @request_bytes, "request"), do: {:ok, words}
  end

  def request(_), do: {:error, "Say what to chart."}

  @doc "`text`, written elsewhere (a thread's title), made fit to be a label."
  def plain(text) do
    text = text |> String.replace(@markup, " ") |> String.replace(@link, " ")

    case text |> String.trim() |> cut(@label_bytes) |> String.trim() do
      "" -> "Untitled"
      plain -> plain
    end
  end

  @doc "`text` in at most `bytes` bytes, whole characters only."
  def cut(text, bytes) when byte_size(text) <= bytes, do: text

  def cut(text, bytes) do
    head = binary_part(text, 0, bytes)
    if String.valid?(head), do: head, else: cut(head, bytes - 1)
  end

  @doc "What a client that does not draw charts shows, and what a page's Markdown says of it."
  def summary(%{"title" => title, "source" => source}), do: "#{title} (a chart; #{source})"

  @doc "A chart as text: what it is, a table of its numbers, and where they came from."
  def markdown(%{"title" => title, "type" => type, "source" => source} = chart) do
    head = ["" | Enum.map(chart["series"], & &1["name"])]

    rows =
      chart["labels"]
      |> Enum.with_index()
      |> Enum.map(fn {label, i} ->
        row([label | Enum.map(chart["series"], &number(Enum.at(&1["values"], i)))])
      end)

    table = [row(head), row(Enum.map(head, fn _ -> "---" end)) | rows]
    Enum.join(["#{title} (#{type} chart)", Enum.join(table, "\n"), source], "\n\n")
  end

  defp row(cells), do: "| " <> Enum.join(cells, " | ") <> " |"

  # 3.0 reads as 3, as it does on a client.
  defp number(value) when is_float(value) and trunc(value) == value, do: trunc(value)
  defp number(value), do: value

  defp keys(map, keys) do
    case Map.keys(map) -- keys do
      [] -> :ok
      extra -> {:error, "A chart cannot carry #{Enum.join(extra, ", ")}."}
    end
  end

  defp type("line", [_, _ | _]), do: :ok
  defp type("line", _), do: {:error, "A line chart needs at least two labels."}
  defp type(type, _) when type in @types, do: :ok
  defp type(_, _), do: {:error, "A chart is one of #{Enum.join(@types, ", ")}."}

  defp labels(labels) when is_list(labels) and labels != [] and length(labels) <= @max_labels do
    each(labels, &text(&1, @label_bytes, "label"))
  end

  defp labels(_), do: {:error, "A chart has 1 to #{@max_labels} labels."}

  defp series(series, labels) when is_list(series) and series != [] do
    if length(series) <= @max_series,
      do: each(series, &one_series(&1, length(labels))),
      else: {:error, "A chart has 1 to #{@max_series} series."}
  end

  defp series(_, _), do: {:error, "A chart has 1 to #{@max_series} series."}

  defp one_series(%{"name" => name, "values" => values} = one, count) when is_list(values) do
    with :ok <- keys(one, ~w(name values)),
         :ok <- text(name, @label_bytes, "series name") do
      if length(values) == count and Enum.all?(values, &value?/1),
        do: :ok,
        else: {:error, "A series has one number from 0 up per label."}
    end
  end

  defp one_series(_, _), do: {:error, "A series has a name and values."}

  defp value?(value), do: is_number(value) and value >= 0 and value <= @max_value

  defp size(chart) do
    if IO.iodata_length(JSON.encode_to_iodata!(chart)) <= @max_bytes,
      do: :ok,
      else: {:error, "A chart takes at most #{@max_bytes} bytes."}
  end

  defp text(text, bytes, what) when is_binary(text) do
    cond do
      not String.valid?(text) -> {:error, "A chart's #{what} is text."}
      String.trim(text) == "" -> {:error, "A chart's #{what} cannot be blank."}
      byte_size(text) > bytes -> {:error, "A chart's #{what} takes at most #{bytes} bytes."}
      Regex.match?(@markup, text) -> {:error, "A chart's #{what} is plain words."}
      Regex.match?(@link, text) -> {:error, "A chart's #{what} cannot carry a link."}
      true -> :ok
    end
  end

  defp text(_, _, what), do: {:error, "A chart's #{what} is text."}

  defp each(list, fun) do
    Enum.find_value(list, :ok, fn item ->
      with :ok <- fun.(item), do: nil
    end)
  end
end
