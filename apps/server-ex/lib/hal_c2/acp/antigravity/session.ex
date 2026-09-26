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
