defmodule HalC2.Acp.Kimi do
  @moduledoc """
  Kimi CLI's tool calls in the shape the other ACP agents send.

  Kimi (an `acpRegistry` instance of the registry agent "kimi") sends no `kind` and
  no `rawInput`: its title is the tool's name, with the key argument once one has
  streamed in ("Shell: ls -la"), and while the call runs its content is the
  arguments' JSON text so far. Its final update's content is the tool's result.
  See `src/kimi_cli/acp/session.py` in MoonshotAI/kimi-cli.

  Its `Agent` tool runs a subagent whose work never reaches ACP: Kimi writes it only
  to the session's record, `<share dir>/sessions/<md5 of cwd>/<session id>/wire.jsonl`,
  as `SubagentEvent`s under the Agent call's id (`wire/3`, `read/2`, `work/2`).
  """

  alias HalC2.Orchestration.NativeSubagent

  @kinds %{
    "Shell" => "execute",
    "ReadFile" => "read",
    "ReadMediaFile" => "read",
    "Glob" => "search",
    "Grep" => "search"
  }

  # The arguments that carry a file's text, which stays out of the timeline as a
  # read's does: it is too much to send to every client.
  @file_text %{"WriteFile" => ["content"], "StrReplaceFile" => ["edit"]}

  @doc "Whether a provider instance runs Kimi CLI."
  def agent?(instance) do
    HalC2.Acp.driver(instance) == "acpRegistry" and
      HalC2.Acp.setting(instance, "agentId") == "kimi"
  end

  @doc """
  A Kimi `tool_call` or `tool_call_update` with its tool's name as its title, a
  `kind` for the tools that have one, and its arguments as `rawInput` once they are
  whole JSON. Any other update is returned as it is.
  """
  def update(%{"sessionUpdate" => s} = call) when s in ["tool_call", "tool_call_update"],
    do: call |> name() |> arguments()

  def update(update), do: update

  defp name(%{"title" => title} = call) when is_binary(title) do
    [name | _] = String.split(title, ": ", parts: 2)

    case @kinds[name] do
      nil -> %{call | "title" => name}
      kind -> Map.merge(call, %{"title" => name, "kind" => kind})
    end
  end

  defp name(call), do: call

  defp arguments(%{"status" => status} = call) when status in ["completed", "failed"],
    do: call

  defp arguments(%{"content" => [%{"content" => %{"text" => text}}]} = call) do
    call = Map.delete(call, "content")

    case JSON.decode(text) do
      {:ok, %{} = input} ->
        input = Map.drop(input, @file_text[call["title"]] || [])
        call |> Map.put("rawInput", input) |> located(input)

      _ ->
        call
    end
  end

  defp arguments(call), do: call

  # A read names its file in its arguments, where the others name it in `locations`.
  defp located(%{"kind" => "read"} = call, %{"path" => path}) when is_binary(path),
    do: Map.put(call, "locations", [%{"path" => path}])

  defp located(call, _input), do: call

  # --- subagents -------------------------------------------------------------------

  @item_types %{
    command: "command_execution",
    file: "file_change",
    search: "file_search",
    web: "web_search",
    tool: "dynamic_tool"
  }

  @doc "Whether a reshaped (`update/1`) Kimi tool call is its `Agent` tool's."
  def subagent?(%{"title" => "Agent"}), do: true
  def subagent?(_call), do: false

  @doc """
  The session record Kimi keeps for `session` run in `cwd`, under `KIMI_SHARE_DIR`
  from the agent's environment `env` or the MC's, else `~/.kimi`.
  """
  def wire(env, cwd, session) do
    share =
      case List.keyfind(env, "KIMI_SHARE_DIR", 0) do
        {_, dir} when dir != "" -> dir
        _ -> System.get_env("KIMI_SHARE_DIR") || Path.expand("~/.kimi")
      end

    hash = :crypto.hash(:md5, cwd) |> Base.encode16(case: :lower)
    Path.join([share, "sessions", hash, session, "wire.jsonl"])
  end

  @doc "How far the record at `path` reaches now: where `read/2` starts from."
  def size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  @doc """
  The subagent events written to the record at `path` after `offset`, as
  `{agent tool call id, event}`, and the offset after the last whole line.
  """
  def read(path, offset) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        with {:ok, _} <- :file.position(io, offset),
             data when is_binary(data) <- IO.binread(io, :eof),
             [_ | _] = lines <- String.split(data, "\n"),
             [_ | _] = whole <- Enum.drop(lines, -1) do
          {Enum.flat_map(whole, &event/1), offset + byte_size(data) - byte_size(List.last(lines))}
        else
          _ -> {[], offset}
        end
      after
        File.close(io)
      end
    else
      _ -> {[], offset}
    end
  end

  # Most of the record is the parent's own work; only its subagents' is decoded.
  defp event(line) do
    with true <- String.contains?(line, ~s("SubagentEvent")),
         {:ok, %{"message" => %{"type" => "SubagentEvent", "payload" => payload}}} <-
           JSON.decode(line),
         %{"parent_tool_call_id" => parent, "event" => %{"type" => _} = event} <- payload do
      [{parent, event}]
    else
      _ -> []
    end
  end

  @doc "The id Kimi's record knows an ACP tool call by: ACP's is `<turn>/<id>`."
  def tool_id(acp_id), do: acp_id |> String.split("/") |> List.last()

  @doc """
  Writes one of a subagent's events (`read/2`) into its child thread (`sub`, a
  `NativeSubagent` handle): what it said and thought, and its tool calls.
  """
  def work(sub, %{"type" => "ContentPart", "payload" => %{"type" => type} = part})
      when type in ["text", "think"] do
    text = part[type]
    work = kimi(sub)

    # A part continuing the one before it adds to the same item.
    {key, said} =
      case work.part do
        {^type, key, said} -> {key, said <> (text || "")}
        _ -> {"#{sub.native}:part:#{work.n}", text || ""}
      end

    sub = put_kimi(sub, %{work | n: work.n + 1, part: {type, key, said}})

    if type == "text",
      do: NativeSubagent.item(sub, key, "assistant_message", "completed", %{"text" => said}),
      else:
        NativeSubagent.item(sub, key, "reasoning", "completed", %{
          "text" => said,
          "streaming" => false
        })
  end

  def work(sub, %{"type" => "ToolCall", "payload" => %{"id" => id, "function" => function}}) do
    work = kimi(sub)
    call = %{name: function["name"] || "tool", args: function["arguments"] || ""}

    sub
    |> put_kimi(%{work | part: nil, last: id, calls: Map.put(work.calls, id, call)})
    |> running(id)
  end

  def work(sub, %{"type" => "ToolCallPart", "payload" => %{"arguments_part" => part}})
      when is_binary(part) do
    work = kimi(sub)

    case work.calls[work.last] do
      nil ->
        sub

      call ->
        calls = Map.put(work.calls, work.last, %{call | args: call.args <> part})
        sub |> put_kimi(%{work | calls: calls}) |> running(work.last)
    end
  end

  def work(sub, %{"type" => "ToolResult", "payload" => %{"tool_call_id" => id} = result}) do
    work = kimi(sub)

    case Map.pop(work.calls, id) do
      {nil, _} ->
        sub

      {call, calls} ->
        value = result["return_value"] || %{}
        {kind, fields} = shape(call.name, input(call) || %{})
        status = if value["is_error"] == true, do: "failed", else: "completed"

        fields =
          if kind in [:command, :tool],
            do: Map.put(fields, "output", output(value)),
            else: fields

        sub
        |> put_kimi(%{work | part: nil, calls: calls})
        |> NativeSubagent.item(tool_key(sub, id), @item_types[kind], status, fields)
    end
  end

  def work(sub, _event), do: sub

  @doc "A subagent's answer from its Agent call's result, without Kimi's header."
  def result(nil), do: nil

  def result(output) do
    case String.split(output, ~r/(?:^|\n)\[summary\]\n/, parts: 2) do
      [_header, summary] -> String.trim(summary)
      [output] -> output
    end
  end

  # A tool call shows once its arguments say what it runs.
  defp running(sub, id) do
    call = kimi(sub).calls[id]

    case input(call) do
      nil ->
        sub

      input ->
        {kind, fields} = shape(call.name, input)
        NativeSubagent.item(sub, tool_key(sub, id), @item_types[kind], "running", fields)
    end
  end

  # The call's arguments once they are whole JSON.
  defp input(call) do
    case JSON.decode(call.args) do
      {:ok, %{} = input} -> Map.drop(input, @file_text[call.name] || [])
      _ -> nil
    end
  end

  defp shape(name, input) do
    path = input["path"]

    case @kinds[name] do
      "execute" ->
        {:command, %{"input" => input["command"] || "", "output" => ""}}

      "read" ->
        {:search, compact(%{"pattern" => path, "results" => path && [%{"fileName" => path}]})}

      "search" ->
        {:search, compact(%{"pattern" => input["pattern"]})}

      nil when name in ["WriteFile", "StrReplaceFile"] ->
        {:file, %{"fileName" => path || name}}

      nil when name in ["SearchWeb", "FetchURL"] ->
        {:web, %{"patterns" => Enum.filter([input["query"], input["url"]], &is_binary/1)}}

      nil ->
        {:tool, %{"toolName" => name, "input" => input}}
    end
  end

  defp compact(fields),
    do: Map.reject(fields, fn {_key, value} -> not (is_binary(value) or is_list(value)) end)

  defp output(%{"output" => output} = value) do
    text =
      case output do
        text when is_binary(text) -> text
        parts when is_list(parts) -> Enum.map_join(parts, &(&1["text"] || ""))
        _ -> ""
      end

    if text == "", do: value["message"] || "", else: text
  end

  defp output(value), do: value["message"] || ""

  defp tool_key(sub, id), do: "#{sub.native}:tool:#{id}"

  defp kimi(sub), do: Map.get(sub, :kimi, %{n: 0, part: nil, last: nil, calls: %{}})
  defp put_kimi(sub, work), do: Map.put(sub, :kimi, work)
end
