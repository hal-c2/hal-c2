defmodule T3.Traces do
  @moduledoc """
  The trace file clients forward their spans to, and what Settings → Diagnostics
  reads from it (`server.getTraceDiagnostics`).

  Clients post OTLP JSON to `POST /api/observability/v1/traces`; each span
  becomes one `otlp-span` line in `<home>/logs/server.trace.ndjson`, the record
  the TS server writes (`decodeOtlpTraceRecords` in packages/shared). The node
  traces none of its own work, so the file holds only what clients sent. It
  rolls over to `.1` past 10 MB.
  """

  @max_bytes 10 * 1024 * 1024
  @slow_ms 1_000
  @top 10
  @recent 20
  @kinds %{1 => "internal", 2 => "server", 3 => "client", 4 => "producer", 5 => "consumer"}

  def path, do: Path.join([Application.fetch_env!(:t3, :home), "logs", "server.trace.ndjson"])

  @doc "Appends the spans of an OTLP JSON export to the trace file."
  def record(%{"resourceSpans" => resource_spans}) when is_list(resource_spans) do
    lines =
      for resource_span <- resource_spans,
          resource = attributes(get_in(resource_span, ["resource", "attributes"])),
          scope_span <- resource_span["scopeSpans"] || [],
          scope = scope_span["scope"] || %{},
          span <- scope_span["spans"] || [] do
        [JSON.encode_to_iodata!(span_record(span, resource, scope)), ?\n]
      end

    file = path()
    File.mkdir_p!(Path.dirname(file))

    case File.stat(file) do
      {:ok, %{size: size}} when size > @max_bytes -> File.rename(file, file <> ".1")
      _ -> :ok
    end

    File.write(file, lines, [:append])
  end

  def record(_), do: {:error, :invalid}

  @doc "`server.getTraceDiagnostics`, aggregated as `TraceDiagnostics.ts` does."
  def diagnostics do
    file = path()
    scanned = [file <> ".1", file]
    texts = for path <- scanned, {:ok, text} <- [File.read(path)], do: text
    base = empty(file, scanned)

    if texts == [] do
      Map.put(
        base,
        "error",
        some(%{
          "kind" => "trace-file-not-found",
          "message" => "This node does not record traces."
        })
      )
    else
      {records, errors} =
        texts
        |> Enum.flat_map(&String.split(&1, ~r/\r?\n/, trim: true))
        |> Enum.map(&parse/1)
        |> Enum.split_with(&is_map/1)

      Map.merge(base, aggregate(records, length(errors)))
    end
  end

  # --- recording ---------------------------------------------------------------

  defp span_record(span, resource, scope) do
    start = span["startTimeUnixNano"] || "0"
    stop = span["endTimeUnixNano"] || "0"
    status = span["status"] || %{}

    %{
      "type" => "otlp-span",
      "name" => span["name"],
      "traceId" => span["traceId"],
      "spanId" => span["spanId"],
      "parentSpanId" => span["parentSpanId"],
      "sampled" => true,
      "kind" => Map.get(@kinds, span["kind"], "internal"),
      "startTimeUnixNano" => start,
      "endTimeUnixNano" => stop,
      "durationMs" => (nanos(stop) - nanos(start)) / 1_000_000,
      "attributes" => attributes(span["attributes"]),
      "resourceAttributes" => resource,
      "scope" =>
        %{"name" => scope["name"], "version" => scope["version"]}
        |> Map.reject(fn {_, v} -> is_nil(v) end)
        |> Map.put("attributes", attributes(scope["attributes"])),
      "events" =>
        for event <- span["events"] || [] do
          %{
            "name" => event["name"],
            "timeUnixNano" => event["timeUnixNano"],
            "attributes" => attributes(event["attributes"])
          }
        end,
      "links" =>
        for link <- span["links"] || [] do
          Map.put(
            Map.take(link, ["traceId", "spanId"]),
            "attributes",
            attributes(link["attributes"])
          )
        end,
      "status" =>
        Map.reject(%{"code" => to_string(status["code"] || 0), "message" => status["message"]}, fn
          {_, v} -> v in [nil, ""]
        end)
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp attributes(list) when is_list(list),
    do: Map.new(list, fn attribute -> {attribute["key"], value(attribute["value"])} end)

  defp attributes(_), do: %{}

  defp value(%{"arrayValue" => %{"values" => values}}), do: Enum.map(values, &value/1)
  defp value(%{"kvlistValue" => %{"values" => values}}), do: attributes(values)

  defp value(%{} = value) do
    Enum.find_value(~w(stringValue boolValue intValue doubleValue bytesValue), fn key ->
      Map.get(value, key)
    end)
  end

  defp value(_), do: nil

  # --- reading -----------------------------------------------------------------

  defp parse(line) do
    with {:ok, %{} = record} <- JSON.decode(line),
         name when is_binary(name) and name != "" <- record["name"],
         trace when is_binary(trace) <- record["traceId"],
         span when is_binary(span) <- record["spanId"],
         duration when is_number(duration) <- record["durationMs"],
         ended when is_integer(ended) <- millis(record["endTimeUnixNano"]) do
      %{
        name: name,
        trace: trace,
        span: span,
        duration: duration,
        ended: ended,
        started: millis(record["startTimeUnixNano"]),
        outcome: outcome(record),
        events: if(is_list(record["events"]), do: record["events"], else: [])
      }
    else
      _ -> :error
    end
  end

  # Effect spans carry an exit; OTLP spans from clients carry a status, 2 being an error.
  defp outcome(%{"exit" => %{"_tag" => "Failure"} = exit}), do: {:failure, cause(exit["cause"])}
  defp outcome(%{"exit" => %{"_tag" => "Interrupted"}}), do: :interrupted

  defp outcome(%{"status" => %{"code" => code} = status}) when code in ["2", 2],
    do: {:failure, cause(status["message"])}

  defp outcome(_), do: :ok

  defp cause(text) when is_binary(text) and text != "", do: String.trim(text)
  defp cause(_), do: "Failure"

  defp aggregate(records, parse_errors) do
    occurrence = fn r ->
      %{
        "name" => r.name,
        "durationMs" => r.duration,
        "endedAt" => iso(r.ended),
        "traceId" => r.trace,
        "spanId" => r.span
      }
    end

    failures = for %{outcome: {:failure, cause}} = r <- records, do: {r, cause}

    logs =
      for r <- records,
          %{} = event <- r.events,
          level = get_in(event, ["attributes", "effect.logLevel"]),
          is_binary(level),
          do: {r, event, level}

    %{
      "recordCount" => length(records),
      "parseErrorCount" => parse_errors,
      "firstSpanAt" =>
        case for(%{started: s} <- records, is_integer(s), do: s) do
          [] -> none()
          starts -> some(iso(Enum.min(starts)))
        end,
      "lastSpanAt" =>
        case records do
          [] -> none()
          _ -> some(iso(records |> Enum.map(& &1.ended) |> Enum.max()))
        end,
      "failureCount" => length(failures),
      "interruptionCount" => Enum.count(records, &(&1.outcome == :interrupted)),
      "slowSpanCount" => Enum.count(records, &(&1.duration >= @slow_ms)),
      "logLevelCounts" => logs |> Enum.map(&elem(&1, 2)) |> Enum.frequencies(),
      "topSpansByCount" =>
        records
        |> Enum.group_by(& &1.name)
        |> Enum.map(fn {name, spans} ->
          total = spans |> Enum.map(& &1.duration) |> Enum.sum()

          %{
            "name" => name,
            "count" => length(spans),
            "failureCount" => Enum.count(spans, &match?({:failure, _}, &1.outcome)),
            "totalDurationMs" => total,
            "averageDurationMs" => total / length(spans),
            "maxDurationMs" => spans |> Enum.map(& &1.duration) |> Enum.max()
          }
        end)
        |> Enum.sort_by(&{-&1["count"], -&1["maxDurationMs"]})
        |> Enum.take(@top),
      "slowestSpans" =>
        records |> Enum.sort_by(& &1.duration, :desc) |> Enum.take(@top) |> Enum.map(occurrence),
      "commonFailures" =>
        failures
        |> Enum.group_by(fn {r, cause} -> {r.name, cause} end)
        |> Enum.map(fn {{name, cause}, seen} ->
          {latest, _} = Enum.max_by(seen, fn {r, _} -> r.ended end)

          %{
            "name" => name,
            "cause" => cause,
            "count" => length(seen),
            "lastSeenAt" => iso(latest.ended),
            "traceId" => latest.trace,
            "spanId" => latest.span,
            ended: latest.ended
          }
        end)
        |> Enum.sort_by(&{-&1["count"], -&1.ended})
        |> Enum.take(@top)
        |> Enum.map(&Map.delete(&1, :ended)),
      "latestFailures" =>
        failures
        |> Enum.sort_by(fn {r, _} -> -r.ended end)
        |> Enum.take(@recent)
        |> Enum.map(fn {r, cause} -> Map.put(occurrence.(r), "cause", cause) end),
      "latestWarningAndErrorLogs" =>
        logs
        |> Enum.filter(fn {_, _, level} ->
          String.downcase(level) in ~w(warning warn error fatal)
        end)
        |> Enum.map(fn {r, event, level} ->
          seen = millis(event["timeUnixNano"]) || r.ended

          %{
            "spanName" => r.name,
            "level" => level,
            "message" => cause_or(event["name"], "Log event"),
            "seenAt" => iso(seen),
            "traceId" => r.trace,
            "spanId" => r.span,
            seen: seen
          }
        end)
        |> Enum.sort_by(&(-&1.seen))
        |> Enum.take(@recent)
        |> Enum.map(&Map.delete(&1, :seen))
    }
  end

  defp cause_or(text, _fallback) when is_binary(text) and text != "", do: String.trim(text)
  defp cause_or(_, fallback), do: fallback

  defp empty(file, scanned) do
    %{
      "traceFilePath" => file,
      "scannedFilePaths" => scanned,
      "readAt" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "recordCount" => 0,
      "parseErrorCount" => 0,
      "firstSpanAt" => none(),
      "lastSpanAt" => none(),
      "failureCount" => 0,
      "interruptionCount" => 0,
      "slowSpanThresholdMs" => @slow_ms,
      "slowSpanCount" => 0,
      "logLevelCounts" => %{},
      "topSpansByCount" => [],
      "slowestSpans" => [],
      "commonFailures" => [],
      "latestFailures" => [],
      "latestWarningAndErrorLogs" => [],
      "partialFailure" => none(),
      "error" => none()
    }
  end

  defp nanos(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp nanos(n) when is_integer(n), do: n
  defp nanos(_), do: 0

  defp millis(value) when is_binary(value) or is_integer(value) do
    case nanos(value) do
      0 -> nil
      n -> div(n, 1_000_000)
    end
  end

  defp millis(_), do: nil

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  defp some(value), do: %{"_tag" => "Some", "value" => value}
  defp none, do: %{"_tag" => "None"}
end
