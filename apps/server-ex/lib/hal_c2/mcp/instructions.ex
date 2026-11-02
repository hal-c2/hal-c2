defmodule HalC2.Mcp.Instructions do
  @moduledoc """
  What an agent is told about HAL-C2 and about itself, per surface:

  - `orchestration/0` — the `hal-c2` tools (`priv/mcp_instructions.md`).
  - `browser/0` — the collaborative browser, only for a credential with the
    preview capability: an agent is never promised tools every call would refuse.
  - `runtime/1` — which harness and model the agent runs as, that it may embed
    images and videos by absolute path, and that it must link the pull
    requests it opens (`runtime` in the Node server's `RuntimeInstructions`).
  - `acp_prompt/3`, `first_run_prompt/3`, `system_prompt/1` — how those reach
    agents with no system prompt of their own, and agents that take one.
  """

  @browser """

  ## HAL-C2 collaborative browser

  You are running inside HAL-C2. The `hal-c2` MCP server is the product-native collaborative browser shared with the user. When it exposes `preview_*` tools, prefer those tools for browser navigation, inspection, interaction, screenshots, and recordings.

  For browser work, first call `preview_status`. If no automation-capable preview is attached, call `preview_open` before concluding that the browser is unavailable. Then use `preview_navigate`, `preview_snapshot`, and the focused interaction tools. Prefer snapshot-provided locators over coordinates.

  Do not switch to global browser skills, Chrome, Node REPL browser automation, standalone Playwright, or agent-browser merely because the preview is initially closed or a first call fails. Use an alternative browser system only when the HAL-C2 preview tools are absent, the user explicitly requests another browser, or `preview_open` returns an explicit unsupported/unavailable error. A failed HAL-C2 preview tool call should be inspected and retried with corrected arguments when the error is actionable.
  """

  @pull_request_linking """
  <pull_request_linking>
  When the hal-c2 MCP server exposes link_pull_request, you must use it to register every pull request you create or work on for this thread. Call link_pull_request with the full PR URL immediately after creating a PR or starting work on an existing PR. For a stack, call it for every layer, not just the current branch or the top PR. This applies when creating or updating PRs through gh, gh stack, another CLI, or the host API: those operations do not register the PRs with this thread. Linking an already-linked PR is safe. Before finishing PR work, call list_thread_pull_requests and link any PR from your work that is missing. Do not link unrelated PRs mentioned only as background. If a linking call fails, report that failure instead of claiming the PR is linked.
  </pull_request_linking>
  """

  @acp_fallback """

  ACP fallback: some ACP agents accept the injected MCP server but fail to expose its tools. When the HAL-C2 tools are absent and `HAL_C2_ACP_MCP_NODE` is present, call the same tools through the terminal: `"$HAL_C2_ACP_MCP_NODE" ${HAL_C2_ACP_MCP_ENTRYPOINT:+"$HAL_C2_ACP_MCP_ENTRYPOINT"} acp-mcp-call orchestrator_capabilities '{}'` (`HAL_C2_ACP_MCP_ENTRYPOINT` is unset when HAL-C2 runs as a standalone executable). Delegate with `acp-mcp-call delegate_task '{"task":"...","target":{"providerInstanceId":"...","model":"..."},"mode":"async","clientRequestId":"..."}'`. This is the supported HAL-C2 transport fallback, not an ordinary shell-based substitute for delegation.
  """

  @default_mode """
  ## HAL-C2 interaction mode: Default

  Prefer making reasonable assumptions and carrying out the user's request. Ask a concise question only when a missing user decision would materially change the result. Treat this mode as active until HAL-C2 supplies a different interaction-mode instruction.
  """

  @plan_mode """
  ## HAL-C2 interaction mode: Plan

  Investigate with read-only actions and do not edit files or otherwise execute the implementation. Resolve discoverable facts before asking questions. When the requirements are decision complete, return a concrete implementation plan and do not start implementing it. Treat this mode as active until HAL-C2 supplies a different interaction-mode instruction.
  """

  @doc "The orchestration instructions (`priv/mcp_instructions.md`)."
  def orchestration do
    case :persistent_term.get({__MODULE__, :orchestration}, nil) do
      nil ->
        text = File.read!(Application.app_dir(:hal_c2, "priv/mcp_instructions.md"))
        :persistent_term.put({__MODULE__, :orchestration}, text)
        text

      text ->
        text
    end
  end

  @doc "The collaborative-browser instructions, for preview-capable agents."
  def browser, do: @browser

  @doc "The pull-request linking instructions, part of `runtime/1`."
  def pull_request_linking, do: String.trim(@pull_request_linking)

  @doc """
  Shared runtime context: the harness the agent runs through, its model and
  reasoning effort when the provider does not pick them itself (`"auto"` and
  `"default"` name no model), media embedding, and pull-request linking.
  """
  def runtime(%{} = runtime) do
    harness = single_line(runtime[:harness] || runtime["harness"] || "")
    model = single_line(runtime[:model] || runtime["model"] || "")

    effort =
      single_line(runtime[:effort] || runtime["effort"] || runtime[:reasoning_effort] || "")

    model_info = if model not in ["", "auto", "default"], do: ", as #{model}", else: ""
    effort_info = if effort != "", do: " with #{effort} reasoning effort", else: ""

    "<runtime_info>In case you're asked: you are running in HAL-C2 through the #{harness} harness#{model_info}#{effort_info}. " <>
      "No need to mention this otherwise. You can embed images and videos in your response using Markdown with absolute file paths.</runtime_info>\n\n" <>
      pull_request_linking()
  end

  @doc """
  The instructions for one agent session: orchestration, the browser section
  only with the preview capability, the ACP terminal fallback only for ACP
  agents, and runtime context when the harness is known.
  """
  def for_session(opts \\ []) do
    capabilities = Keyword.get(opts, :capabilities, MapSet.new(["preview"]))

    parts =
      [orchestration()] ++
        if(MapSet.member?(capabilities, "preview"), do: [browser()], else: []) ++
        if(Keyword.get(opts, :acp, false), do: [@acp_fallback], else: []) ++
        case Keyword.get(opts, :runtime) do
          nil -> []
          runtime -> ["\n\n" <> runtime(runtime)]
        end

    Enum.join(parts)
  end

  @doc """
  An ACP prompt with HAL-C2's instructions in front of it. ACP has no
  system/developer prompt field, so the instructions ride the first prompt
  and any prompt after the interaction mode or the tools changed — never
  twice in a row for the same state, and never in front of a slash command,
  which must stay at the start.
  """
  def acp_prompt(prompt, state, previous \\ nil) do
    cond do
      String.starts_with?(String.trim_leading(prompt), "/") ->
        prompt

      previous != nil and previous[:interaction_mode] == state[:interaction_mode] and
        previous[:has_mcp] == state[:has_mcp] and
          previous[:capabilities] == state[:capabilities] ->
        prompt

      true ->
        "<hal_c2_instructions>\n#{acp_instructions(state)}\n</hal_c2_instructions>\n\n<user_request>\n#{prompt}\n</user_request>"
    end
  end

  @doc "The instruction text itself for one ACP state (mode, then tools when present)."
  def acp_instructions(state) do
    mode = if state[:interaction_mode] == "plan", do: @plan_mode, else: @default_mode

    tools =
      if state[:has_mcp] do
        [
          mode,
          for_session(
            capabilities: state[:capabilities] || MapSet.new(["preview"]),
            acp: true,
            runtime: state[:runtime]
          )
        ]
      else
        [mode]
      end

    tools |> Enum.map(&String.trim/1) |> Enum.join("\n\n")
  end

  @doc """
  A prompt for an agent with no system prompt channel: the orchestration
  instructions in front of the thread's first message only, and only when
  the agent has the `hal-c2` server.
  """
  def first_run_prompt(prompt, run_ordinal, has_mcp) do
    if run_ordinal == 1 and has_mcp do
      "<hal_c2_orchestration_instructions>#{String.trim(orchestration())}</hal_c2_orchestration_instructions>\n\n<user_request>\n#{prompt}\n</user_request>"
    else
      prompt
    end
  end

  @doc "The orchestration instructions as a system prompt, or nil without the server."
  def system_prompt(has_mcp), do: if(has_mcp, do: orchestration())

  defp single_line(value),
    do: value |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
end
