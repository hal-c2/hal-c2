defmodule T3.Trace do
  @moduledoc """
  The node's local trace file and the client spans it accepts (Settings → Diagnostics).

  While tracing is on (`config :t3, trace: true`, `T3CODE_TRACE=1`), `span/3` appends
  one `effect-span` record per finished span to `<home>/logs/server.trace.ndjson`,
  rotating at 10 MiB into `.1` … `.10`, in the record shape of
  `packages/shared/src/observability.ts`. Clients post OTLP JSON to
  `/api/observability/v1/traces`; `accept/1` keeps those spans as `otlp-span`
  records and, when `T3CODE_OTLP_TRACES_URL` names a collector, forwards the
  payload there. `diagnostics/0` reads the files back into
  `ServerTraceDiagnosticsResult` (`server.getTraceDiagnostics`).
  """

  require Logger

  @max_bytes 10 * 1024 * 1024
  @max_files 10
  @slow_ms 1_000
  @top 10
  @recent 20

  @doc "Whether this node records spans."
  def enabled?, do: Application.get_env(:t3, :trace, false) == true

  @doc "The collector client spans are forwarded to, if any."
  def otlp_url, do: Application.get_env(:t3, :otlp_traces_url)

  def path, do: Path.join([Application.fetch_env!(:t3, :home), "logs", "server.trace.ndjson"])

  @doc """
  Runs `fun` and, while tracing is on, records it as a span named `name`. A result of
  `{:error, reason}` or a raise records a failure; the result is returned unchanged.
  """
  def span(name, attributes \\ %{}, fun) do
    if enabled?() do
      started = System.system_time(:nanosecond)

      try do
        result = fun.()

        exit =
          case result do
            {:error, reason} -> %{"_tag" => "Failure", "cause" => cause(reason)}
            _ -> %{"_tag" => "Success"}
          end

        record_span(name, attributes, started, System.system_time(:nanosecond), exit)
        result
      rescue
        error ->
          exit = %{"_tag" => "Failure", "cause" => Exception.message(error)}
          record_span(name, attributes, started, System.system_time(:nanosecond), exit)
          reraise error, __STACKTRACE__
      end
    else
      fun.()
    end
  end

  @doc "Records a span that already happened, from `started_ms` until now."
  def finished(name, attributes, started_ms, exit \\ %{"_tag" => "Success"}) do
    if enabled?(),
      do:
        record_span(
          name,
          attributes,
          started_ms * 1_000_000,
          System.system_time(:nanosecond),
          exit
        )

    :ok
  end

  defp record_span(name, attributes, started, ended, exit) do
    append(%{
      "type" => "effect-span",
      "name" => name,
      "kind" => "internal",
      "traceId" => hex(16),
      "spanId" => hex(8),
      "sampled" => true,
      "startTimeUnixNano" => Integer.to_string(started),
      "endTimeUnixNano" => Integer.to_string(ended),
      "durationMs" => (ended - started) / 1_000_000,
      "attributes" => attributes,
      "events" => [],
      "links" => [],
      "exit" => exit
    })
  end

  @doc """
  Client spans (an OTLP JSON `TraceData` payload): kept in the trace file while tracing
  is on, and forwarded to the configured collector. `:ok`, or `{:error, :export}`
  when the collector refused them.
  """
  def accept(payload) do
    if enabled?() do
      try do
        payload |> decode_otlp() |> Enum.each(&append/1)
      rescue
        error ->
          Logger.warning("Failed to decode client OTLP traces: #{Exception.message(error)}")
      end
    end

    case otlp_url() do
      nil -> :ok
      url -> export(url, payload)
    end
  end

  defp export(url, payload) do
    headers =
      for {key, value} <- Application.get_env(:t3, :otlp_headers, %{}),
          do: {String.to_charlist(key), String.to_charlist(value)}

    request = {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(payload)}

    case :httpc.request(:post, request, [timeout: 10_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      other ->
        Logger.warning("Failed to export client OTLP traces to #{url}: #{inspect(other)}")
        {:error, :export}
    end
  end

  # --- OTLP JSON -> otlp-span records (decodeOtlpTraceRecords) -----------------------

  @kinds %{1 => "internal", 2 => "server", 3 => "client", 4 => "producer", 5 => "consumer"}

  defp decode_otlp(%{"resourceSpans" => resource_spans}) do
    for resource_span <- resource_spans,
        resource = attributes(get_in(resource_span, ["resource", "attributes"])),
        scope_span <- resource_span["scopeSpans"] || [],
        scope = scope_span["scope"] || %{},
        span <- scope_span["spans"] || [] do
      started = nanos(span["startTimeUnixNano"])
      ended = nanos(span["endTimeUnixNano"])
      status = span["status"] || %{}

      %{
        "type" => "otlp-span",
        "name" => span["name"],
        "traceId" => span["traceId"],
        "spanId" => span["spanId"],
        "sampled" => true,
        "kind" => Map.get(@kinds, span["kind"], "internal"),
        "startTimeUnixNano" => Integer.to_string(started),
        "endTimeUnixNano" => Integer.to_string(ended),
        "durationMs" => (ended - started) / 1_000_000,
        "attributes" => attributes(span["attributes"]),
        "resourceAttributes" => resource,
        "scope" =>
          %{"attributes" => attributes(scope["attributes"])}
          |> put_present("name", scope["name"])
          |> put_present("version", scope["version"]),
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
            %{
              "traceId" => link["traceId"],
              "spanId" => link["spanId"],
              "attributes" => attributes(link["attributes"])
            }
          end,
        "status" =>
          %{"code" => to_string(status["code"] || 0)} |> put_present("message", status["message"])
      }
      |> put_present("parentSpanId", span["parentSpanId"])
    end
  end

  defp decode_otlp(_), do: []

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp attributes(nil), do: %{}
  defp attributes(list), do: Map.new(list, &{&1["key"], value(&1["value"])})

  defp value(%{"stringValue" => v}), do: v
  defp value(%{"boolValue" => v}), do: v
  defp value(%{"intValue" => v}), do: v
  defp value(%{"doubleValue" => v}), do: v
  defp value(%{"bytesValue" => v}), do: v
  defp value(%{"arrayValue" => %{"values" => values}}), do: Enum.map(values, &value/1)
  defp value(%{"kvlistValue" => %{"values" => values}}), do: attributes(values)
  defp value(_), do: nil

  defp nanos(value) when is_integer(value), do: value

  defp nanos(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp nanos(_), do: 0

  # --- the file --------------------------------------------------------------------

  defp append(record) do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    rotate(path)
    File.write!(path, [JSON.encode!(record), ?\n], [:append])
  rescue
    error -> Logger.warning("Failed to write a trace record: #{Exception.message(error)}")
  end

  defp rotate(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= @max_bytes ->
        File.rm("#{path}.#{@max_files}")

        for n <- (@max_files - 1)..1//-1,
            do: File.rename("#{path}.#{n}", "#{path}.#{n + 1}")

        File.rename(path, "#{path}.1")

      _ ->
        :ok
    end
  end

  # --- diagnostics (aggregateTraceDiagnostics) ---------------------------------------

  @doc "`server.getTraceDiagnostics` for the node's trace files."
  def diagnostics do
    path = path()
    paths = for(n <- @max_files..1//-1, do: "#{path}.#{n}") ++ [path]
    files = for p <- paths, {:ok, text} <- [File.read(p)], do: {p, text}
    base = empty(path, paths)

    if files == [] do
      Map.put(
        base,
        "error",
        some(%{"kind" => "trace-file-not-found", "message" => "No local trace files were found."})
      )
    else
      aggregate(base, files)
    end
  end

  defp empty(path, paths) do
    %{
      "traceFilePath" => path,
      "scannedFilePaths" => paths,
      "readAt" => iso_now(),
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

  defp aggregate(base, files) do
    {spans, errors} =
      for {_path, text} <- files,
          line <- String.split(text, ~r/\r?\n/, trim: true),
          reduce: {[], 0} do
        {spans, errors} ->
          case parse(line) do
            {:ok, span} -> {[span | spans], errors}
            :error -> {spans, errors + 1}
          end
      end

    spans = Enum.reverse(spans)
    failures = Enum.filter(spans, &(&1.exit == "Failure"))

    top =
      spans
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {name, group} ->
        total = group |> Enum.map(& &1.duration) |> Enum.sum()

        %{
          "name" => name,
          "count" => length(group),
          "failureCount" => Enum.count(group, &(&1.exit == "Failure")),
          "totalDurationMs" => total,
          "averageDurationMs" => total / length(group),
          "maxDurationMs" => group |> Enum.map(& &1.duration) |> Enum.max()
        }
      end)
      |> Enum.sort_by(&{-&1["count"], -&1["maxDurationMs"]})
      |> Enum.take(@top)

    common =
      failures
      |> Enum.group_by(&{&1.name, &1.cause})
      |> Enum.map(fn {{name, cause}, group} ->
        latest = Enum.max_by(group, & &1.ended)

        %{
          "name" => name,
          "cause" => cause,
          "count" => length(group),
          "lastSeenAt" => iso(latest.ended),
          "traceId" => latest.trace_id,
          "spanId" => latest.span_id
        }
      end)
      |> Enum.sort(&({&1["count"], &1["lastSeenAt"]} >= {&2["count"], &2["lastSeenAt"]}))
      |> Enum.take(@top)

    %{
      base
      | "recordCount" => length(spans),
        "parseErrorCount" => errors,
        "firstSpanAt" =>
          spans |> Enum.map(& &1.started) |> Enum.min(fn -> nil end) |> maybe_iso(),
        "lastSpanAt" => spans |> Enum.map(& &1.ended) |> Enum.max(fn -> nil end) |> maybe_iso(),
        "failureCount" => length(failures),
        "interruptionCount" => Enum.count(spans, &(&1.exit == "Interrupted")),
        "slowSpanCount" => Enum.count(spans, &(&1.duration >= @slow_ms)),
        "topSpansByCount" => top,
        "slowestSpans" =>
          spans
          |> Enum.sort_by(& &1.duration, :desc)
          |> Enum.take(@top)
          |> Enum.map(&occurrence/1),
        "commonFailures" => common,
        "latestFailures" =>
          failures
          |> Enum.sort_by(& &1.ended, :desc)
          |> Enum.take(@recent)
          |> Enum.map(&Map.put(occurrence(&1), "cause", &1.cause))
    }
  end

  defp occurrence(span) do
    %{
      "name" => span.name,
      "durationMs" => span.duration,
      "endedAt" => iso(span.ended),
      "traceId" => span.trace_id,
      "spanId" => span.span_id
    }
  end

  defp parse(line) do
    with {:ok, %{} = record} <- JSON.decode(line),
         name when is_binary(name) and name != "" <- record["name"],
         trace_id when is_binary(trace_id) <- record["traceId"],
         span_id when is_binary(span_id) <- record["spanId"],
         duration when is_number(duration) <- record["durationMs"],
         ended when ended > 0 <- nanos(record["endTimeUnixNano"]) do
      exit = get_in(record, ["exit", "_tag"])

      {:ok,
       %{
         name: name,
         trace_id: trace_id,
         span_id: span_id,
         duration: duration,
         started: div(nanos(record["startTimeUnixNano"]), 1_000_000),
         ended: div(ended, 1_000_000),
         exit: exit,
         cause: String.trim(get_in(record, ["exit", "cause"]) || "Failure")
       }}
    else
      _ -> :error
    end
  end

  defp cause(reason) when is_binary(reason), do: reason
  defp cause(%{"message" => message}) when is_binary(message), do: message
  defp cause(%{"_tag" => tag}), do: tag
  defp cause(reason), do: inspect(reason)

  defp hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  defp maybe_iso(nil), do: none()
  defp maybe_iso(ms), do: some(iso(ms))
  defp iso_now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  defp some(value), do: %{"_tag" => "Some", "value" => value}
  defp none, do: %{"_tag" => "None"}
end
