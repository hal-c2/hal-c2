defmodule HalC2.Acp.Kimi do
  @moduledoc """
  Kimi Code CLI: the build the registry agent "kimi" runs, and its tool calls in the
  shape the other ACP agents send.

  The ACP Registry's "kimi" is Kimi CLI, which Moonshot archived for Kimi Code. While
  the entry is still Kimi CLI, `registry_entry/1` swaps in a pinned Kimi Code release,
  checked against its sha256 like any registry archive; once the registry moves, its
  own entry runs. Kimi Code keeps its sign-in under
  `KIMI_CODE_HOME` (`~/.kimi-code`), so moving from Kimi CLI means signing in again.

  Kimi Code names a call's kind and input, but while the call runs its content is the
  arguments' JSON text (streamed in, then whole), and a call's location is only an
  absolute path. See `packages/acp-server/src/events-map.ts` in MoonshotAI/kimi-code.

  Its `Agent` tool runs a subagent whose work never reaches ACP. Kimi Code writes it
  only to the session's records (`session_dir/2`): the main agent's names each
  subagent it spawned under the Agent call's id and how it ended (`subagent.*`), and
  the subagent's own holds its messages (`work/2`). See
  `packages/agent-core-v2/docs/wire-manifest.d.ts`.
  """

  alias HalC2.Orchestration.NativeSubagent

  @kimi_cli "https://github.com/MoonshotAI/kimi-cli"
  @version "2.3.1"
  @release "https://github.com/MoonshotAI/kimi-code/releases/download/%40moonshot-ai%2Fkimi-code%40#{@version}"
  @builds %{
    "darwin-aarch64" =>
      {"darwin-arm64", "ab2c3cd38b6a100ab66107e0255ebdf68d1fec1efd193afee9d077fb9255bb93"},
    "darwin-x86_64" =>
      {"darwin-x64", "c2e58b1efd3b67fbc729d322a9d3e598f88c73e77764e5bbfcc59e07dd33727c"},
    "linux-aarch64" =>
      {"linux-arm64", "6ef2af316d3b7fe28313bbd6aa3fdc0e5943e43958cbf7f6a564e48acec355f0"},
    "linux-x86_64" =>
      {"linux-x64", "0dbc7d771ce4d761acc150ade72325bcd8fc51973d481f7040295f4cf062fdbe"},
    "windows-aarch64" =>
      {"win32-arm64", "0ee8dbce2a61fb35fdcb0bd4a23023646ac69cd11137de8aaa5e027aa5e69e55"},
    "windows-x86_64" =>
      {"win32-x64", "91514bebccf75019e5815eb405ff2063a4439d34e6d5bbd63fcb0863f6aa4400"}
  }

  @doc "Whether a provider instance runs Kimi Code."
  def agent?(instance) do
    HalC2.Acp.driver(instance) == "acpRegistry" and
      HalC2.Acp.setting(instance, "agentId") == "kimi"
  end

  @doc "A registry agent as HAL-C2 runs it: Kimi Code in place of the registry's Kimi CLI."
  def registry_entry(%{"id" => "kimi", "repository" => @kimi_cli} = agent) do
    binary =
      Map.new(@builds, fn {platform, {asset, sha256}} ->
        cmd = if String.starts_with?(platform, "windows"), do: "./kimi.exe", else: "./kimi"

        {platform,
         %{
           "archive" => "#{@release}/kimi-code-#{asset}.tar.gz",
           "cmd" => cmd,
           "args" => ["acp"],
           "sha256" => sha256
         }}
      end)

    Map.merge(agent, %{
      "name" => "Kimi Code",
      "version" => @version,
      "description" => "Moonshot AI's coding agent",
      "repository" => "https://github.com/MoonshotAI/kimi-code",
      "website" => "https://github.com/MoonshotAI/kimi-code",
      "license_url" => "https://github.com/MoonshotAI/kimi-code/blob/main/LICENSE",
      "distribution" => %{"binary" => binary}
    })
  end

  def registry_entry(agent), do: agent

  @doc """
  A Kimi `tool_call` or `tool_call_update` without the arguments' text while it runs,
  and with a read's or edit's file from its input. Any other update is returned as it is.
  """
  def update(%{"sessionUpdate" => s} = call) when s in ["tool_call", "tool_call_update"],
    do: call |> arguments() |> located()

  def update(update), do: update

  # The result replaces the arguments when the call ends; a diff stays.
  defp arguments(%{"status" => status} = call) when status in ["completed", "failed"],
    do: call

  defp arguments(%{"content" => content} = call) when is_list(content) do
    case Enum.reject(content, &(&1["type"] == "content")) do
      [] -> Map.delete(call, "content")
      content -> %{call | "content" => content}
    end
  end

  defp arguments(call), do: call

  # A file named by a relative path is in the input but not in `locations`. A search
  # names a directory, not the file it found.
  defp located(%{"kind" => kind, "rawInput" => %{} = input} = call)
       when kind in ["read", "edit"] and not is_map_key(call, "locations") do
    path = input["path"] || input["file_path"]

    if is_binary(path) and path != "" and not is_map_key(input, "pattern"),
      do: Map.put(call, "locations", [%{"path" => path}]),
      else: call
  end

  defp located(call), do: call

  # --- subagents -------------------------------------------------------------------

  @item_types %{
    command: "command_execution",
    file: "file_change",
    search: "file_search",
    web: "web_search",
    tool: "dynamic_tool"
  }

  @doc """
  Whether a Kimi tool call is its `Agent` tool's: created under the tool's name while
  its arguments stream in, else under its description with the whole input.
  """
  def subagent?(%{"title" => "Agent"}), do: true

  def subagent?(%{"rawInput" => %{"prompt" => p, "description" => d}})
      when is_binary(p) and is_binary(d),
      do: true

  def subagent?(_call), do: false

  @doc """
  The directory Kimi keeps `session`'s records in, under `KIMI_CODE_HOME` from the
  agent's environment `env` or the MC's, else `~/.kimi-code`: one `wire.jsonl` per
  agent, the main agent's and each subagent's (`wire/2`). Nil until Kimi made it.
  """
  def session_dir(env, session) do
    home =
      case List.keyfind(env, "KIMI_CODE_HOME", 0) do
        {_, dir} when dir != "" -> dir
        _ -> System.get_env("KIMI_CODE_HOME") || Path.expand("~/.kimi-code")
      end

    # Sessions are kept per workspace: sessions/<workspace id>/<session id>.
    case File.ls(Path.join(home, "sessions")) do
      {:ok, workspaces} ->
        workspaces
        |> Enum.map(&Path.join([home, "sessions", &1, session]))
        |> Enum.find(&File.dir?/1)

      _ ->
        nil
    end
  end

  @doc "The record of the agent `agent` (\"main\", or a subagent's id) in `dir`."
  def wire(dir, agent), do: Path.join([dir, "agents", agent, "wire.jsonl"])

  @doc "How far the record at `path` reaches now: where `read/3` starts from."
  def size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  @doc """
  The records of a type starting with `prefix` written to `path` after `offset`, and
  the offset after the last whole line.
  """
  def read(path, offset, prefix) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        with {:ok, _} <- :file.position(io, offset),
             data when is_binary(data) <- IO.binread(io, :eof),
             [_ | _] = lines <- String.split(data, "\n"),
             [_ | _] = whole <- Enum.drop(lines, -1) do
          records = Enum.flat_map(whole, &record(&1, prefix))
          {records, offset + byte_size(data) - byte_size(List.last(lines))}
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

  # Most of a record is other bookkeeping; only lines naming the type are decoded.
  defp record(line, prefix) do
    with true <- String.contains?(line, ~s("type":") <> prefix),
         {:ok, %{"type" => type} = record} <- JSON.decode(line),
         true <- String.starts_with?(type, prefix) do
      [record]
    else
      _ -> []
    end
  end

  @doc "The id Kimi's records know an ACP tool call by: ACP's is `<turn>:<id>`."
  def tool_id(acp_id) do
    case String.split(acp_id, ":", parts: 2) do
      [_turn, id] -> id
      [id] -> id
    end
  end

  @doc """
  Writes one message of a subagent's record (`context.append_message`) into its
  child thread (`sub`, a `NativeSubagent` handle): what it said and thought, its tool
  calls, and their results. Its task, the first user message, is the thread's already.
  """
  def work(sub, %{"message" => %{"role" => "assistant"} = message}) do
    work = kimi(sub)

    parts =
      for %{"type" => type} = part <- List.wrap(message["content"]),
          type in ["text", "think"],
          is_binary(part[type]) and part[type] != "",
          do: {type, part[type]}

    {sub, n} =
      Enum.reduce(parts, {sub, work.n}, fn {type, text}, {sub, n} ->
        key = "#{sub.native}:part:#{n}"

        sub =
          if type == "text",
            do:
              NativeSubagent.item(sub, key, "assistant_message", "completed", %{"text" => text}),
            else:
              NativeSubagent.item(sub, key, "reasoning", "completed", %{
                "text" => text,
                "streaming" => false
              })

        {sub, n + 1}
      end)

    called =
      for %{"id" => id, "name" => name} = call <- List.wrap(message["toolCalls"]),
          is_binary(id) and is_binary(name),
          do: {id, {name, input(call["arguments"])}}

    sub = put_kimi(sub, %{work | n: n, calls: Map.merge(work.calls, Map.new(called))})

    Enum.reduce(called, sub, fn {id, {name, input}}, sub ->
      {kind, fields} = shape(name, input)
      NativeSubagent.item(sub, tool_key(sub, id), @item_types[kind], "running", fields)
    end)
  end

  def work(sub, %{"message" => %{"role" => "tool", "toolCallId" => id} = message}) do
    work = kimi(sub)

    case Map.pop(work.calls, id) do
      {nil, _} ->
        sub

      {{name, input}, calls} ->
        {kind, fields} = shape(name, input)
        status = if message["isError"] == true, do: "failed", else: "completed"

        fields =
          if kind in [:command, :tool],
            do: Map.put(fields, "output", text(message["content"])),
            else: fields

        sub
        |> put_kimi(%{work | calls: calls})
        |> NativeSubagent.item(tool_key(sub, id), @item_types[kind], status, fields)
    end
  end

  def work(sub, _record), do: sub

  defp input(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, %{} = input} -> input
      _ -> %{}
    end
  end

  defp input(_args), do: %{}

  defp text(content) when is_list(content),
    do: Enum.map_join(content, &if(&1["type"] == "text", do: &1["text"] || "", else: ""))

  defp text(content) when is_binary(content), do: content
  defp text(_content), do: ""

  defp shape(name, input) do
    path = input["path"]

    case name do
      n when n in ["Bash", "Terminal"] ->
        {:command, %{"input" => input["command"] || "", "output" => ""}}

      "Read" ->
        {:search, compact(%{"pattern" => path, "results" => path && [%{"fileName" => path}]})}

      n when n in ["Grep", "Glob"] ->
        {:search, compact(%{"pattern" => input["pattern"]})}

      n when n in ["Write", "Edit"] ->
        {:file, %{"fileName" => path || name}}

      n when n in ["WebSearch", "WebFetch"] ->
        {:web, %{"patterns" => Enum.filter([input["query"], input["url"]], &is_binary/1)}}

      _ ->
        {:tool, %{"toolName" => name, "input" => input}}
    end
  end

  defp compact(fields),
    do: Map.reject(fields, fn {_key, value} -> not (is_binary(value) or is_list(value)) end)

  defp tool_key(sub, id), do: "#{sub.native}:tool:#{id}"

  defp kimi(sub), do: Map.get(sub, :kimi, %{n: 0, calls: %{}})
  defp put_kimi(sub, work), do: Map.put(sub, :kimi, work)
end
