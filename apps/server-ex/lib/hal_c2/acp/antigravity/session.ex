defmodule HalC2.Acp.Antigravity.Session do
  @moduledoc """
  Antigravity's parts of a thread session (`HalC2.Acp.ThreadRuntime`); each is a no-op
  for other agents.

  A session authenticates with the instance's configured method right after
  `initialize`. A Google login that is missing or expired makes the agent print a
  sign-in link instead of answering; a thread never opens that link (sign-in runs
  from Settings, `HalC2.Acp.Antigravity.Auth`), so the turn fails and the instance
  shows as signed out. An opened session records the account's models and gets
  the thread's access mode as an Antigravity mode.
  """

  alias HalC2.Acp.Antigravity
  alias HalC2.JsonRpc.Connection

  @doc "Whether an instance runs Antigravity."
  def antigravity?(instance), do: HalC2.Acp.driver(instance) == "antigravity"

  @doc """
  What a turn needs before its session: `:ok`, `:logout` for `/logout` alone, or
  `{:error, message}` for attachments Antigravity does not take.
  """
  def check_turn(turn) do
    attachments = Map.get(turn, :attachments, [])

    cond do
      not antigravity?(turn.ids.driver) -> :ok
      attachments == [] and String.trim(turn.text || "") == "/logout" -> :logout
      true -> Antigravity.check_attachments(attachments)
    end
  end

  # Antigravity reports a spent quota as the turn's whole reply, not as an error.
  @reply_limit 1024
  @quota ~r/\A\s*Usage Limit Reached\s+(You have reached your current quota\b.*?)\s*\z/s
  @reset_in ~r/(\d+)\s+(day|hour|minute|second)s?\b/
  @unit_ms %{"day" => 86_400_000, "hour" => 3_600_000, "minute" => 60_000, "second" => 1000}

  @doc "Keeps the start of an Antigravity turn's reply, where `usage_limit/2` looks."
  def reply(turn, text) do
    if antigravity?(turn.ids.driver) do
      reply = Map.get(turn, :reply, "")
      if byte_size(reply) > @reply_limit, do: turn, else: Map.put(turn, :reply, reply <> text)
    else
      turn
    end
  end

  @doc """
  The `usage_limit` failure of a turn whose whole reply was Antigravity's quota notice,
  resetting after the time it names from `now_ms`; nil for any other reply.
  """
  def usage_limit(turn, now_ms) do
    with reply when is_binary(reply) and byte_size(reply) <= @reply_limit <- turn[:reply],
         [_, message] <- Regex.run(@quota, reply) do
      reset_ms =
        case Regex.run(~r/reset in ([^.]*)/, message) do
          [_, after_] ->
            for [_, n, unit] <- Regex.scan(@reset_in, after_),
                reduce: 0,
                do: (ms -> ms + String.to_integer(n) * @unit_ms[unit])

          nil ->
            0
        end

      %{
        "class" => "usage_limit",
        "message" => message,
        "code" => "quota_exhausted",
        "retryable" => nil,
        "resetAt" => if(reset_ms > 0, do: HalC2.Projection.JS.iso(now_ms + reset_ms))
      }
    else
      _ -> nil
    end
  end

  @doc "The stderr lines a thread's agent connection passes on: Antigravity's sign-in link."
  def stderr_prefix(instance), do: if(antigravity?(instance), do: Antigravity.auth_prefix())

  @doc "Authenticates a new connection with the instance's method: `:ok` or `{:error, message}`."
  def authenticate(conn, instance) do
    if antigravity?(instance) do
      method = Antigravity.config(instance)["authMethod"]

      task =
        Task.async(fn ->
          Connection.call(conn, "authenticate", %{"methodId" => method}, 60_000)
        end)

      case await(conn, task) do
        {:ok, _} ->
          :ok

        :sign_in ->
          Antigravity.drop_account(instance)
          {:error, Antigravity.sign_in_required()}

        {:error, _reason} ->
          if Antigravity.browser?(method) do
            Antigravity.drop_account(instance)
            {:error, Antigravity.sign_in_required()}
          else
            {:error, "Antigravity could not authenticate with the configured credentials."}
          end
      end
    else
      :ok
    end
  end

  defp await(conn, task) do
    prefix = Antigravity.auth_prefix()

    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:json_rpc, ^conn, {:invalid, line}} when is_binary(line) ->
        if String.starts_with?(line, prefix) do
          Task.shutdown(task, :brutal_kill)
          :sign_in
        else
          await(conn, task)
        end
    end
  end

  @doc """
  After a session opens: records the account's `models` and sets the thread's
  access mode (full access is `yolo`, auto-accept edits `auto_edit`).
  """
  def opened(conn, session_id, instance, runtime_mode, models) do
    if antigravity?(instance) do
      Registry.update_value(HalC2.Acp.Registry, self_key(), fn _ -> instance end)

      mode =
        case runtime_mode do
          "full-access" -> "yolo"
          "auto-accept-edits" -> "auto_edit"
          _ -> "default"
        end

      Connection.call(conn, "session/set_mode", %{"sessionId" => session_id, "modeId" => mode})

      account = Antigravity.account(instance)

      if models != [] and
           (account == nil or account["models"] != models or
              :persistent_term.get({HalC2.Acp, instance, :unauthenticated}, false)),
         do: Antigravity.put_account(instance, models)
    end

    :ok
  end

  # The thread id this process is registered under.
  defp self_key do
    [key | _] = Registry.keys(HalC2.Acp.Registry, self())
    key
  end

  @doc """
  Checks the thread's model against the models the account's session lists:
  `:ok` or `{:error, message}`.
  """
  def check_model(instance, model, models) do
    slugs = for %{"slug" => slug} <- models || [], do: slug

    if antigravity?(instance) and is_binary(model) and model not in ["", "default"] and
         slugs != [] and model not in slugs,
       do:
         {:error,
          "Antigravity model '#{model}' is unavailable for this Google account. Select an available model."},
       else: :ok
  end

  @doc "A session's start failure, as the thread shows it."
  def failure(instance, %{"code" => -32000} = reason) do
    if antigravity?(instance) do
      Antigravity.drop_account(instance)
      Antigravity.sign_in_required()
    else
      reason
    end
  end

  def failure(_instance, reason), do: reason
end
