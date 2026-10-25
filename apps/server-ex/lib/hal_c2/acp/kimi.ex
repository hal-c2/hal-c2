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
  """

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
end
