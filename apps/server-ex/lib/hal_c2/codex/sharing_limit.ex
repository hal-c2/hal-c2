defmodule HalC2.Codex.SharingLimit do
  @moduledoc """
  A turn Codex stopped at the limit a ChatGPT plan sets for using it in other apps
  (pingdotgg/t3code#23361, #25341). Each plan recovers its own way, so the failure
  carries ChatGPT's code: a personal plan's (`subscription_sharing_usage_limit_exceeded`)
  sends the user to their usage settings, a Business workspace member's
  (`subscription_sharing_workplace_individual_usage_limit_exceeded`) to their
  workspace admin. Clients read the code as the thread's `lastErrorCode`.
  """

  @personal "subscription_sharing_usage_limit_exceeded"
  @workspace "subscription_sharing_workplace_individual_usage_limit_exceeded"

  @messages %{
    @personal =>
      "Your ChatGPT usage limit was reached. Check ChatGPT Usage settings for your available allowance.",
    @workspace =>
      "You reached your workspace's limit for using ChatGPT in other apps. Ask your workspace admin to increase it."
  }

  @doc """
  The sharing-limit code of a Codex error (its `error` notification's or a failed
  turn's), or nil when it is not one. ChatGPT's code can come as the error's own
  `code`, inside a JSON message or its `additionalDetails`, or not at all: Codex can
  stream only ChatGPT's prose, which names a personal plan's limit.
  """
  @spec code(term) :: String.t() | nil
  def code(error) do
    error = unwrap(error)
    messages = messages(error)

    known(error) || Enum.find_value(messages, &known(unwrap(&1))) ||
      if(Enum.any?(messages, &personal_prose?/1), do: @personal)
  end

  @doc "The turn's failure for a sharing limit `code/1` found: a usage limit with no reset."
  @spec failure(String.t()) :: map
  def failure(code) do
    %{
      "class" => "usage_limit",
      "message" => @messages[code],
      "code" => code,
      "retryable" => nil,
      "resetAt" => nil
    }
  end

  defp known(%{"code" => code}), do: known(code)
  defp known(code) when is_map_key(@messages, code), do: code
  defp known(_), do: nil

  defp messages(error) when is_binary(error), do: [error]

  defp messages(%{} = error),
    do: for(key <- ["message", "additionalDetails"], is_binary(error[key]), do: error[key])

  defp messages(_), do: []

  defp personal_prose?(message) do
    lower = String.downcase(message)

    String.contains?(message, "has reached their Subscription Sharing usage limit") or
      (String.contains?(lower, "sharing") and String.contains?(lower, "usage limit"))
  end

  defp unwrap(value) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_binary(decoded) -> unwrap_error(decoded)
      _ -> value
    end
  end

  defp unwrap(value), do: unwrap_error(value)

  defp unwrap_error(%{"error" => error}), do: error
  defp unwrap_error(value), do: value
end
