defmodule HalC2.Orchestration.CommandPolicy do
  @moduledoc """
  Whether a provider instance can do what a command needs, decided from the
  capabilities its sessions declare (`HalC2.Orchestration.Entities`). A command
  a provider cannot satisfy is refused in the provider's name
  (`HalC2.Orchestration.UserFacingErrors`) instead of being silently downgraded.

  Ported from upstream T3 Code's `orchestration-v2/CommandPolicy.ts` (see
  `features/mc/orchestration/commands.feature`).
  """

  alias HalC2.Orchestration.{Entities, UserFacingErrors}

  @type capability ::
          :queued_messages
          | :active_steering
          | :interrupt_restart_steering
          | :interrupt
          | :native_fork
          | :fork_from_turn
          | :rollback
          | :rollback_snapshot
          | :context_handoff
          | :strong_terminal_status

  @doc "The session capabilities of a provider instance, as its sessions declare them."
  @spec capabilities(String.t()) :: map
  def capabilities(instance),
    do: Entities.capabilities(HalC2.Orchestration.driver_for(instance))

  @doc "Whether the capabilities `caps` satisfy `capability`."
  @spec supports?(map, capability) :: boolean
  def supports?(caps, capability) do
    case capability do
      :queued_messages ->
        caps["turns"]["supportsQueuedMessages"] == true

      :active_steering ->
        caps["turns"]["supportsActiveSteering"] == true

      :interrupt_restart_steering ->
        caps["turns"]["supportsSteeringByInterruptRestart"] == true

      :interrupt ->
        caps["turns"]["supportsInterrupt"] == true

      :native_fork ->
        caps["threads"]["canForkThread"] == true and
          caps["identity"]["nativeThreadIds"] == "strong"

      :fork_from_turn ->
        caps["threads"]["canForkFromTurn"] == true

      :rollback ->
        caps["threads"]["canRollbackThread"] == true and
          caps["checkpointing"]["providerCanRollbackConversation"] == true

      :rollback_snapshot ->
        caps["checkpointing"]["providerRollbackReturnsSnapshot"] == true

      :context_handoff ->
        caps["context"]["canConsumeHandoffSummaries"] == true and
          caps["context"]["acceptsSyntheticUserContext"] == true and
          (caps["context"]["supportsDeltaHandoff"] == true or
             caps["context"]["supportsFullThreadHandoff"] == true)

      :strong_terminal_status ->
        caps["turns"]["terminalStatusQuality"] == "strong"
    end
  end

  @doc "Whether provider instance `instance` satisfies `capability`."
  @spec instance_supports?(String.t(), capability) :: boolean
  def instance_supports?(instance, capability),
    do: instance |> capabilities() |> supports?(capability)

  @doc """
  `:ok` when the instance can do what the command needs, or the refusal the
  client is told.
  """
  @spec ensure(String.t(), capability) :: :ok | {:error, String.t()}
  def ensure(instance, capability) do
    if instance_supports?(instance, capability),
      do: :ok,
      else: {:error, UserFacingErrors.capability_message(instance, capability)}
  end

  @doc """
  How a message that must redirect the active run of `instance` is delivered:
  taken into the run where the provider steers, else by interrupting and
  restarting where it can do that. `force_restart` is a restart the client
  asked for by name. Neither is a refusal in the provider's name.
  """
  @spec decide_steering(String.t(), boolean) ::
          {:ok, :active_steering | :interrupt_restart} | {:error, String.t()}
  def decide_steering(instance, force_restart) do
    caps = capabilities(instance)

    cond do
      not force_restart and supports?(caps, :active_steering) ->
        {:ok, :active_steering}

      supports?(caps, :interrupt) and supports?(caps, :interrupt_restart_steering) ->
        {:ok, :interrupt_restart}

      true ->
        capability =
          if force_restart or supports?(caps, :interrupt),
            do: :interrupt_restart_steering,
            else: :active_steering

        {:error, UserFacingErrors.capability_message(instance, capability)}
    end
  end

  @doc """
  Whether a fork a caller requires to be native can be one on `instance`;
  `from_specific_turn` forks at an earlier turn rather than the latest.
  """
  @spec ensure_native_fork(String.t(), boolean) :: :ok | {:error, String.t()}
  def ensure_native_fork(instance, from_specific_turn) do
    caps = capabilities(instance)

    cond do
      not supports?(caps, :native_fork) ->
        {:error, UserFacingErrors.capability_message(instance, :native_fork)}

      from_specific_turn and not supports?(caps, :fork_from_turn) ->
        {:error, UserFacingErrors.capability_message(instance, :fork_from_turn)}

      true ->
        :ok
    end
  end
end
