defmodule HalC2.ProviderLog do
  @moduledoc """
  Native provider event logs, for debugging a provider's protocol
  (`apps/server/src/provider/Layers/EventNdjsonLogger.ts`).

  While on (`config :hal_c2, provider_event_log: true`, `HALC2_PROVIDER_EVENT_LOG=1`),
  every line a provider process sends is appended to
  `<home>/logs/provider/events.<thread>.log` as `[<iso time>] NTIVE: <json>`.
  Streaming deltas are left out; lifecycle events, responses and failures stay.
  A record larger than 64 KiB, with more than 1,024 fields or nested deeper than
  16 levels is written as a structural summary that keeps the routing ids,
  method, status and error fields. Logging never changes what the provider's
  runtime receives.
  """

  require Logger

  @max_chars 64 * 1024
  @max_fields 1_024
  @max_depth 16

  @transient_methods ~w(
    item/agentMessage/delta item/commandExecution/outputDelta item/fileChange/outputDelta
    item/plan/delta item/reasoning/summaryTextDelta item/reasoning/textDelta
    thread/realtime/outputAudio/delta thread/realtime/transcript/delta turn/diff/updated
  )
  @transient_acp_updates ~w(agent_message_chunk agent_thought_chunk)
  @summary_fields ~w(
    provider protocol kind providerSessionId direction stage type subtype method id threadId
    turnId requestId session_id status is_error api_error_status terminal_reason stop_reason
    operation code willRetry message event payload params result thread turn error turns items
    content
  )

  def enabled?, do: Application.get_env(:hal_c2, :provider_event_log, false) == true

  @doc "The log file for a thread's provider events."
  def path(thread_id) do
    segment =
      case thread_id && String.replace(thread_id, ~r/[^A-Za-z0-9_.-]+/, "-") do
        segment when segment in [nil, ""] -> "_global"
        segment -> segment
      end

    Path.join([Application.fetch_env!(:hal_c2, :home), "logs", "provider", "events.#{segment}.log"])
  end

  @doc "Logs one raw line a provider sent for `thread_id`, when logging is on."
  def native(nil, _line), do: :ok

  def native(thread_id, line) do
    if enabled?() do
      with {:ok, event} <- JSON.decode(line),
           true <- persist?(event) do
        write(thread_id, event)
      else
        _ -> :ok
      end
    end

    :ok
  rescue
    error -> Logger.warning("Failed to log a provider event: #{Exception.message(error)}")
  end

  defp write(thread_id, event) do
    payload = JSON.encode!(bound(event))

    payload =
      if byte_size(payload) > @max_chars, do: JSON.encode!(summarize(event)), else: payload

    at = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    path = path(thread_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ["[", at, "] NTIVE: ", payload, ?\n], [:append])
  end

  @doc "Whether a native event belongs in the log: streaming deltas do not."
  def persist?(%{"method" => method}) when method in @transient_methods, do: false

  def persist?(%{
        "method" => "session/update",
        "params" => %{"update" => %{"sessionUpdate" => u}}
      })
      when u in @transient_acp_updates,
      do: false

  def persist?(%{"type" => "stream_event", "event" => %{"type" => "content_block_delta"}}),
    do: false

  def persist?(%{"type" => "message.part.delta"}), do: false
  def persist?(_event), do: true

  @doc "The event itself when it fits the record budget, else its summary."
  def bound(event) do
    case fits(event, 0, {@max_chars, @max_fields}) do
      {:ok, _budget} -> event
      :error -> summarize(event)
    end
  end

  defp fits(value, _depth, {chars, fields}) when is_binary(value) do
    left = chars - String.length(value)
    if left >= 0, do: {:ok, {left, fields}}, else: :error
  end

  defp fits(_value, depth, _budget) when depth > @max_depth, do: :error

  defp fits(value, depth, {chars, fields}) when is_map(value) do
    Enum.reduce_while(value, {:ok, {chars, fields}}, fn {key, nested}, {:ok, {chars, fields}} ->
      budget = {chars - String.length(to_string(key)), fields - 1}

      with {left, fields} when left >= 0 and fields >= 0 <- budget,
           {:ok, budget} <- fits(nested, depth + 1, budget) do
        {:cont, {:ok, budget}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp fits(value, depth, {chars, fields}) when is_list(value) do
    if length(value) > fields do
      :error
    else
      Enum.reduce_while(value, {:ok, {chars, fields}}, fn nested, {:ok, {chars, fields}} ->
        case fits(nested, depth + 1, {chars, fields - 1}) do
          {:ok, budget} when elem(budget, 1) >= 0 -> {:cont, {:ok, budget}}
          _ -> {:halt, :error}
        end
      end)
    end
  end

  defp fits(_value, _depth, budget), do: {:ok, budget}

  @doc "A structural summary: routing, method, status and error fields, strings capped."
  def summarize(event) do
    {summary, _budget} = summarize(event, 0, {8 * 1024, 128})
    summary
  end

  defp summarize(value, _depth, {chars, fields}) when is_binary(value) do
    length = String.length(value)

    if length > min(1_024, chars),
      do: {%{"omittedCharacters" => length}, {chars, fields}},
      else: {value, {chars - length, fields}}
  end

  defp summarize(value, _depth, budget) when is_list(value),
    do: {%{"itemCount" => length(value)}, budget}

  defp summarize(value, depth, budget) when is_map(value) do
    if depth >= 6 do
      {%{"truncated" => true}, budget}
    else
      Enum.reduce(@summary_fields, {%{"truncated" => true}, budget}, fn key,
                                                                        {summary, {chars, fields}} ->
        case Map.fetch(value, key) do
          {:ok, nested} when fields > 0 ->
            {nested, budget} = summarize(nested, depth + 1, {chars, fields - 1})
            {Map.put(summary, key, nested), budget}

          _ ->
            {summary, {chars, fields}}
        end
      end)
    end
  end

  defp summarize(value, _depth, budget), do: {value, budget}
end
