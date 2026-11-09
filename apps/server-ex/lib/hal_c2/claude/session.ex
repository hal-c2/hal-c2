defmodule HalC2.Claude.Session do
  @moduledoc """
  Owns one `claude` CLI process speaking the stream-json control protocol.

  The session sends `initialize` on start, and passes its reply (which names the
  signed-in account) to the `:handler` as `{:claude, session, {:initialized, reply}}`.
  Transcript messages go to the handler as `{:claude, session, {:message, map}}`. Tool permission prompts arrive as
  `{:claude, session, {:permission, request_id, tool_name, input, context}}` and are
  answered with `answer_permission/3`. A dialog Claude asks the host to show (only the
  kinds named at `initialize`) arrives as `{:claude, session, {:dialog, request_id, kind,
  payload}}` and is answered with `answer_dialog/3`. `control/3` sends any control request
  (`"interrupt"`, `"set_model"`, `"set_permission_mode"`, ...) and waits for its reply.

  With `:mcp` (`%{url, authorization}`) the session hands Claude HAL-C2's MCP server
  over stdin right after `initialize` (`mcp_set_servers`), and holds the user's
  messages until Claude has answered it. A control sent after a held message waits
  behind it, so an interrupt reaches Claude after the message it stops, and is answered
  `:held` at once; questions about the session (`mcp_status`, `get_usage`) are asked
  at once. A server Claude refuses or cannot reach leaves the session without HAL-C2's
  tools; no answer in 90 s ends the session. What is held goes in the durable
  checkpoint, so an adopted session sends it once Claude answers.

  With `:durable` (a thread id) the CLI outlives the MC: the handler gets
  `{:claude, session, {:checkpoint, checkpoint}}` after each batch to save with its state
  (`HalC2.Subprocess.Durable.save/3`), and `:adopt` starts a session on a CLI an earlier
  MC saved so. No `initialize` is sent then: it already answered one.
  """

  use GenServer

  require Logger

  alias HalC2.Claude.{McpConfig, Protocol}
  alias HalC2.Subprocess

  @mcp_deadline_ms 90_000
  # Controls that ask about the session rather than act on its conversation: never held.
  @questions ["mcp_status", "get_usage"]

  @state_version 1

  # The dialogs the MC can show; Claude sends no other kind. `resume_return` asks
  # whether to compact a long, old conversation before continuing it.
  @dialog_kinds ["resume_return"]

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, hibernate_after: 15_000)

  @spec send_message(GenServer.server(), String.t() | [map], keyword) :: :ok
  def send_message(session, content, opts \\ []),
    do: GenServer.cast(session, {:user_message, content, opts})

  @spec answer_permission(
          GenServer.server(),
          String.t(),
          :allow | {:allow, map} | {:allow_session, [map]} | {:deny, String.t()} | :cancel
        ) :: :ok
  def answer_permission(session, request_id, decision),
    do: GenServer.cast(session, {:answer_permission, request_id, decision})

  @doc "Answers an MCP elicitation with its action and content."
  @spec answer_elicitation(GenServer.server(), String.t(), map) :: :ok
  def answer_elicitation(session, request_id, answer),
    do: GenServer.cast(session, {:answer_elicitation, request_id, answer})

  @doc "Answers a dialog with the user's choice, or `:cancelled` for the dialog's default."
  @spec answer_dialog(GenServer.server(), String.t(), {:completed, term} | :cancelled) :: :ok
  def answer_dialog(session, request_id, result),
    do: GenServer.cast(session, {:answer_dialog, request_id, result})

  @spec control(GenServer.server(), String.t(), map, timeout) ::
          {:ok, map} | :held | {:error, term}
  def control(session, subtype, params \\ %{}, timeout \\ 30_000),
    do: GenServer.call(session, {:control, subtype, params}, timeout)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, sub, mcp_wait} <- subprocess(opts) do
      channel = get_in(opts, [:adopt, :channel]) || %{next_id: 1, permissions: %{}}
      # A CLI an earlier MC left waiting on its servers still owes that answer.
      mcp_wait = mcp_wait or Map.get(channel, :mcp_wait, false)
      # `:mcp_deadline` (ms) shortens the wait, in tests.
      deadline = Keyword.get(opts, :mcp_deadline, @mcp_deadline_ms)
      if mcp_wait, do: Process.send_after(self(), :mcp_deadline, deadline)

      {:ok,
       %{
         v: @state_version,
         sub: sub,
         handler: Keyword.fetch!(opts, :handler),
         next_id: channel.next_id,
         pending: %{},
         offset: get_in(opts, [:adopt, :offset]) || 0,
         # Tool input is echoed back on "allow", so keep it until the prompt is answered.
         permissions: channel.permissions,
         log: Keyword.get(opts, :log),
         # Waiting on Claude's answer to `mcp_set_servers`, with the user messages held
         # until then, oldest first.
         mcp_wait: mcp_wait,
         held: Map.get(channel, :held, [])
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp subprocess(opts) do
    case opts[:adopt] do
      %{dir: dir, offset: offset} ->
        with {:ok, sub} <- Subprocess.adopt(dir, offset), do: {:ok, sub, false}

      nil ->
        # `:command` replaces the `claude` executable (with its own leading args), e.g. in tests.
        executable = Keyword.get(opts, :command, [Keyword.get(opts, :executable, "claude")])
        cmd = fn _durable_dir -> executable ++ Protocol.cli_args(opts) end

        with {:ok, sub} <-
               Subprocess.start(cmd, Keyword.take(opts, [:cd, :env, :durable, :sandbox])) do
          HalC2.ProviderLog.options(Keyword.get(opts, :log), opts)

          init =
            Protocol.control_request("init", "initialize", %{
              "supportedDialogKinds" => @dialog_kinds
            })

          servers =
            if opts[:mcp],
              do: [
                Protocol.control_request("mcp", "mcp_set_servers", %{
                  "servers" => Protocol.mcp_servers(opts[:mcp])
                })
              ],
              else: []

          case Enum.reduce_while([init | servers], :ok, fn line, :ok ->
                 case Subprocess.write_line(sub, line) do
                   :ok -> {:cont, :ok}
                   error -> {:halt, error}
                 end
               end) do
            :ok ->
              {:ok, sub, servers != []}

            {:error, _reason} = error ->
              Subprocess.stop(sub)
              error
          end
        end
    end
  end

  @impl true
  def handle_call({:control, subtype, params}, _from, %{held: [_ | _]} = state)
      when subtype not in @questions do
    id = "hal-c2-#{state.next_id}"
    line = Protocol.control_request(id, subtype, params)
    {:reply, :held, checkpoint(%{state | next_id: state.next_id + 1, held: state.held ++ [line]})}
  end

  def handle_call({:control, subtype, params}, from, state) do
    id = "hal-c2-#{state.next_id}"
    :ok = Subprocess.write_line(state.sub, Protocol.control_request(id, subtype, params))

    {:noreply,
     checkpoint(%{state | next_id: state.next_id + 1, pending: Map.put(state.pending, id, from)})}
  end

  @impl true
  def handle_cast({:user_message, content}, state),
    do: handle_cast({:user_message, content, []}, state)

  # Saved at once, as a message written is: lost, the restored turn would never end.
  def handle_cast({:user_message, content, opts}, %{mcp_wait: true} = state),
    do:
      {:noreply,
       checkpoint(%{state | held: state.held ++ [Protocol.user_message(content, opts)]})}

  def handle_cast({:user_message, content, opts}, state) do
    :ok = Subprocess.write_line(state.sub, Protocol.user_message(content, opts))
    {:noreply, checkpoint(state)}
  end

  def handle_cast({:answer_permission, id, decision}, state) do
    case Map.pop(state.permissions, id) do
      {nil, _} ->
        {:noreply, state}

      {input, permissions} ->
        :ok = Subprocess.write_line(state.sub, Protocol.permission_reply(id, decision, input))
        {:noreply, checkpoint(%{state | permissions: permissions})}
    end
  end

  def handle_cast({:answer_elicitation, id, answer}, state) do
    :ok = Subprocess.write_line(state.sub, Protocol.elicitation_reply(id, answer))
    {:noreply, checkpoint(state)}
  end

  def handle_cast({:answer_dialog, id, result}, state) do
    :ok = Subprocess.write_line(state.sub, Protocol.dialog_reply(id, result))
    {:noreply, checkpoint(state)}
  end

  @impl true
  def handle_info({:subprocess_lines, _reader, lines}, state) do
    state = Enum.reduce(lines, state, &handle_line/2)
    Subprocess.ack(state.sub)
    {:noreply, state}
  end

  def handle_info({:subprocess_offset, _reader, offset}, state),
    do: {:noreply, checkpoint(%{state | offset: offset}, false)}

  def handle_info(:mcp_deadline, %{mcp_wait: true} = state),
    do: {:stop, :mcp_servers_unanswered, state}

  def handle_info({:subprocess_eof, _reader}, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :closed})

    try do
      Subprocess.stop(state.sub)
    after
      cleanup_config(state)
    end
  end

  # A session from an MC that still wrote Claude's MCP config to a file
  # (`HalC2.Claude.McpConfig`); durable ones go with their durable directory.
  defp cleanup_config(%{sub: %{durable: nil}} = state),
    do: McpConfig.remove(Map.get(state, :mcp_config_dir))

  defp cleanup_config(_state), do: :ok

  @impl true
  def code_change(_old_vsn, state, _extra),
    do:
      {:ok,
       state
       |> Map.put_new(:offset, 0)
       |> Map.put_new(:mcp_wait, false)
       |> Map.put_new(:held, [])
       |> Map.put(:v, @state_version)}

  # After what the CLI wrote and after what it was sent.
  defp checkpoint(state, wrote \\ true)

  defp checkpoint(%{sub: %{durable: %{dir: dir}}} = state, wrote) do
    notify(
      state,
      {:checkpoint,
       %{
         dir: dir,
         wrote: wrote,
         offset: state.offset,
         channel: %{
           next_id: state.next_id,
           permissions: state.permissions,
           mcp_wait: state.mcp_wait,
           held: state.held
         }
       }}
    )

    state
  end

  defp checkpoint(state, _wrote), do: state

  defp handle_line(line, state) do
    HalC2.ProviderLog.native(Map.get(state, :log), line)

    case Protocol.decode(line) do
      {:control_response, "init", reply} ->
        notify(state, {:initialized, reply})
        state

      {:control_response, "mcp", reply} ->
        mcp_answered(state, reply)

      {:control_response, id, reply} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, reply)
        %{state | pending: pending}

      {:permission, id, tool, input, context} ->
        notify(state, {:permission, id, tool, input, context})
        %{state | permissions: Map.put(state.permissions, id, input)}

      {:control_cancel, id} ->
        notify(state, {:permission_cancelled, id})
        %{state | permissions: Map.delete(state.permissions, id)}

      {:control_request, id, %{"subtype" => "request_user_dialog", "dialog_kind" => kind} = r}
      when kind in @dialog_kinds ->
        notify(state, {:dialog, id, kind, r["payload"] || %{}})
        state

      {:control_request, id, %{"subtype" => "elicitation"} = request} ->
        notify(state, {:elicitation, id, request})
        state

      {:control_request, id, request} ->
        # Hooks and MCP-over-control are not wired yet; refuse rather than hang the turn.
        Subprocess.write_line(
          state.sub,
          JSON.encode_to_iodata!(%{
            "type" => "control_response",
            "response" => %{
              "subtype" => "error",
              "request_id" => id,
              "error" => "unsupported: #{request["subtype"]}"
            }
          })
        )

        state

      {:message, message} ->
        notify(state, {:message, message})
        state

      {:invalid, _} ->
        state
    end
  end

  # Claude has HAL-C2's server, or runs without it: the held messages go in now.
  # Only server names are logged, as an error's text can echo the header.
  defp mcp_answered(state, reply) do
    refused =
      case reply do
        {:ok, %{"errors" => %{} = errors}} -> Map.keys(errors)
        {:ok, _} -> []
        {:error, _} -> ["hal-c2"]
      end

    if refused != [],
      do:
        Logger.warning("Claude runs without MCP servers it refused: #{Enum.join(refused, ", ")}")

    for line <- state.held, do: :ok = Subprocess.write_line(state.sub, line)
    checkpoint(%{state | mcp_wait: false, held: []})
  end

  defp notify(state, event), do: send(state.handler, {:claude, self(), event})
end
