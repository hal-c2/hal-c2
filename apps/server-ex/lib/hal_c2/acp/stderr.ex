defmodule HalC2.Acp.Stderr do
  @moduledoc """
  What an ACP agent wrote to its error output, fit to show in a failure and the MC's
  log: its last 4,096 characters, with the user's home directory shortened to `~`
  and pairing links, authorization values, API key headers and provider-looking
  keys replaced. Upstream's `AcpStderr.ts`, with #24015's fix: a key's body may hold
  `_` (`sk-ant-api03-AbC_dEf`), and is redacted whole.
  """

  @max 4_096

  @doc "How much of an agent's error output is kept: 4,096 characters."
  def max, do: @max

  @patterns [
    {~r"https?://[^\s]*/pair#[^\s]*"i, "[pairing-url]"},
    {~r"\bBearer\s+[A-Za-z0-9._\-+=/]+"i, "Bearer [redacted]"},
    {~r"\bAuthorization:\s*Basic\s+\S+"i, "Authorization: Basic [redacted]"},
    {~r"\bx-api-key:\s*\S+"i, "x-api-key: [redacted]"},
    {~r"\b(?:sk-[A-Za-z0-9][A-Za-z0-9_-]{7,}|ghp_[A-Za-z0-9]+|xox[a-zA-Z]-[A-Za-z0-9-]+)",
     "[redacted]"}
  ]

  @doc "The shown form of `text`, its last `max` characters; `\"\"` when nothing is left."
  @spec sanitize(String.t() | nil, non_neg_integer) :: String.t()
  def sanitize(text, max \\ @max)
  def sanitize(nil, _max), do: ""

  def sanitize(text, max) do
    text = text |> String.replace_invalid() |> String.replace("\0", "")
    text = Enum.reduce(homes(), text, &String.replace(&2, &1, "~"))

    @patterns
    |> Enum.reduce(text, fn {pattern, with}, text -> Regex.replace(pattern, text, with) end)
    |> last(max)
    |> String.trim()
  end

  defp last(text, count) do
    length = String.length(text)
    if length > count, do: String.slice(text, length - count, count), else: text
  end

  # Longest first, so a home inside another is shortened whole.
  defp homes do
    [System.get_env("HOME"), System.get_env("USERPROFILE"), System.user_home()]
    |> Enum.filter(&(is_binary(&1) and String.length(&1) > 1))
    |> Enum.map(&String.trim_trailing(&1, "/"))
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
  end
end
