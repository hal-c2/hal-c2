defmodule HalC2.SpaceChartPropTest do
  @moduledoc """
  What a chart's description (`HalC2.Space.Chart`) may be, whatever it says:

  - any description within the caps is taken and takes at most `Chart.max_bytes/0`, so
    the size the Space's stream is promised holds at the caps, in the worst text;
  - one forbidden thing anywhere refuses the whole description;
  - `Chart.plain/1` makes any text fit to be a label;
  - a chart's Markdown never comes back as a chart.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Space.{Chart, Markdown}

  # Bytes that cost the most once encoded, and multibyte text cut near its cap.
  defp word(max) do
    let chars <-
          non_empty(list(oneof([elements(~c"ab \"/"), elements(~c"é€"), integer(0x61, 0x7A)]))) do
      chars
      |> List.to_string()
      |> Chart.cut(max)
      |> then(&if(String.trim(&1) == "", do: "x", else: &1))
    end
  end

  defp value, do: oneof([integer(0, 1_000_000_000_000_000), float(0.0, 1.0e15)])

  defp chart do
    let [labels, names] <- [vector_range(1, 24, 40), vector_range(1, 4, 40)] do
      count = length(labels)

      let [series, title, request, source, type] <- [
            for(name <- names, do: series(name, count)),
            word(120),
            word(200),
            word(160),
            if(count >= 2, do: elements(~w(bar line)), else: exactly("bar"))
          ] do
        %{
          "type" => type,
          "title" => title,
          "request" => request,
          "source" => source,
          "labels" => labels,
          "series" => series
        }
      end
    end
  end

  defp series(name, count) do
    let values <- vector(count, value()), do: %{"name" => name, "values" => values}
  end

  defp vector_range(low, high, bytes) do
    let count <- integer(low, high), do: vector(count, word(bytes))
  end

  defp forbidden do
    elements([
      "<b>",
      "`x`",
      "[x](y)",
      "a|b",
      "a*b",
      "a\\b",
      "a\nb",
      "a​b",
      "https://x",
      "www.x.y",
      "javascript:x",
      "DATA:x"
    ])
  end

  property "a chart within its caps is taken, and fits", numtests: HalC2.Prop.numtests(200) do
    forall chart <- chart() do
      {:ok, chart} == Chart.validate(chart) and
        byte_size(JSON.encode!(chart)) <= Chart.max_bytes()
    end
  end

  property "one forbidden thing refuses the whole chart", numtests: HalC2.Prop.numtests(200) do
    forall [chart, bad, where] <- [
             chart(),
             forbidden(),
             elements(~w(title request source label name extra))
           ] do
      match?({:error, _}, Chart.validate(spoil(chart, where, bad)))
    end
  end

  property "plain makes any text a label", numtests: HalC2.Prop.numtests(200) do
    forall text <- oneof([utf8(), forbidden()]) do
      label = Chart.plain(text)

      chart = %{
        "type" => "bar",
        "title" => "t",
        "request" => "r",
        "source" => "s",
        "labels" => [label],
        "series" => [%{"name" => "s", "values" => [1]}]
      }

      match?({:ok, _}, Chart.validate(chart))
    end
  end

  property "a chart's Markdown is never a chart again", numtests: HalC2.Prop.numtests(100) do
    forall chart <- chart() do
      {_, blocks} = Markdown.parse(Chart.markdown(chart))
      Enum.all?(blocks, &(&1["kind"] != "chart"))
    end
  end

  defp spoil(chart, "label", bad), do: %{chart | "labels" => [bad | tl(chart["labels"])]}

  defp spoil(chart, "name", bad) do
    [first | rest] = chart["series"]
    %{chart | "series" => [%{first | "name" => bad} | rest]}
  end

  defp spoil(chart, "extra", bad), do: Map.put(chart, "url", bad)
  defp spoil(chart, key, bad), do: Map.put(chart, key, bad)
end
