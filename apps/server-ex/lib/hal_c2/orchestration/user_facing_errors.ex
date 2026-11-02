defmodule HalC2.Orchestration.UserFacingErrors do
  @moduledoc """
  The words a client is told when a command is refused or fails: refusals for
  something a provider cannot do name the provider and what it cannot do, and a
  failure wrapped in the engine's general dispatch errors is reported with its
  most specific reason.

  Ported from upstream T3 Code's `orchestration-v2/UserFacingErrors.ts` (see
  `features/mc/orchestration/commands.feature`).
  """

  @generic_prefixes [
    "Failed to dispatch orchestration V2 command",
    "Failed to dispatch orchestration command",
    "Provider adapter failed while dispatching orchestration command"
  ]

  @capability_messages %{
    queued_messages: "cannot queue messages behind an active run.",
    active_steering: "cannot redirect an active run. Stop it first, then send the message.",
    interrupt_restart_steering:
      "cannot redirect an active run. Stop it first, then send the message.",
    interrupt: "cannot stop a run once it has started.",
    native_fork: "cannot fork this thread natively.",
    fork_from_turn: "cannot fork from an earlier point in this thread.",
    rollback:
      "cannot rewind its conversation, so this checkpoint cannot be restored on this thread.",
    rollback_snapshot:
      "did not report its rewound conversation state, so the checkpoint was not restored.",
    context_handoff: "cannot receive the context handoff needed for this switch.",
    strong_terminal_status: "cannot confirm when its runs finish reliably enough for this."
  }

  @doc "The refusal for `capability`, in the provider instance's name."
  @spec capability_message(String.t(), atom) :: String.t()
  def capability_message(instance, capability),
    do: "#{provider_display_name(instance)} #{Map.fetch!(@capability_messages, capability)}"

  @doc "The refusal for a delivery mode the provider supports no form of right now."
  @spec unsupported_delivery_message(String.t()) :: String.t()
  def unsupported_delivery_message(instance),
    do: "#{provider_display_name(instance)} cannot deliver a message that way right now."

  @doc """
  How a provider instance is named to the user: its display name where the MC
  has one, and after its instance otherwise — `acmeAgent` reads as "Acme".
  """
  @spec provider_display_name(String.t()) :: String.t()
  def provider_display_name(instance) when is_binary(instance) do
    case HalC2.ThreadMove.provider_name(instance) do
      ^instance -> humanize(instance)
      name -> name
    end
  end

  # The instance id with a trailing "Agent" dropped and the first letter
  # capitalized, the way a product name reads.
  defp humanize(instance) do
    instance
    |> String.replace(~r/Agent$/i, "")
    |> String.trim()
    |> String.capitalize()
  end

  @doc """
  The most specific reason in `error`: nested causes are walked to the deepest
  message, and the engine's general dispatch wrappers never reach the client.
  A capability refusal (`{:capability, instance, capability}` or its map shape)
  is told in the provider's name.
  """
  @spec message(term) :: String.t()
  def message(error) do
    messages =
      error
      |> collect([])
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))

    specific = Enum.reject(messages, &generic?/1)

    case specific do
      [] -> List.first(messages) || "The command failed."
      _ -> List.last(specific)
    end
  end

  defp generic?(message),
    do: Enum.any?(@generic_prefixes, &String.starts_with?(message, &1))

  # Every message in the error, outermost first: a capability refusal reads as
  # its user-facing sentence, a wrapper keeps the reason it wraps after it.
  defp collect({:capability, instance, capability}, acc),
    do: acc ++ [capability_message(instance, capability)]

  defp collect({:error, error}, acc), do: collect(error, acc)

  defp collect(%{"_tag" => "CommandPolicyCapabilityUnsupportedError"} = error, acc) do
    capability =
      Enum.find(
        Map.keys(@capability_messages),
        &(to_string(&1) == error["capability"])
      )

    if capability,
      do: acc ++ [capability_message(error["providerInstanceId"], capability)],
      else: collect(Map.delete(error, "_tag"), acc)
  end

  defp collect(%_{} = error, acc) do
    if is_exception(error),
      do: acc ++ [Exception.message(error)],
      else: acc
  end

  defp collect(%{} = error, acc) do
    own =
      case error["detail"] || error["message"] do
        message when is_binary(message) -> [message]
        _ -> []
      end

    acc = acc ++ own
    acc = collect(error["cause"], acc)
    acc = collect(error["error"], acc)
    collect(error["errors"], acc)
  end

  defp collect(errors, acc) when is_list(errors),
    do: Enum.reduce(errors, acc, &collect/2)

  defp collect(message, acc) when is_binary(message) do
    # A wrapper and its reason in one string ("Failed to dispatch …: reason")
    # carries both; the reason is the specific one.
    case Enum.find(@generic_prefixes, &String.starts_with?(message, &1)) do
      nil ->
        acc ++ [message]

      prefix ->
        rest =
          message
          |> String.trim_leading(prefix)
          |> String.trim_leading()
          |> String.trim_leading(":")
          |> String.trim()

        acc ++ [message] ++ if(rest == "", do: [], else: [rest])
    end
  end

  defp collect(_error, acc), do: acc
end
