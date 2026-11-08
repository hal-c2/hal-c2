defmodule HalC2.Acp.Ordered do
  @moduledoc """
  A JSON object whose keys keep the order they were given in. Grok answers its
  questions in the order it asked them, and a map would sort them by key.
  """
  defstruct pairs: []

  def new(pairs), do: %__MODULE__{pairs: pairs}
end

defimpl JSON.Encoder, for: HalC2.Acp.Ordered do
  def encode(%{pairs: pairs}, encoder), do: :json.encode_key_value_list(pairs, encoder)
end
