defmodule HalC2.Streams.Unrecorded do
  @moduledoc """
  A commit the store could not record (a full disk, say): the store recorded none of
  its changes and the stream stays as it was. `error` is what the store raised;
  `message` is its message, so a caller that reports the failure says what the store
  said.
  """

  defexception [:message, :error]

  @doc "The exception for the store's `error`."
  def of(error) when is_exception(error),
    do: %__MODULE__{message: Exception.message(error), error: error}

  def of(error),
    do: %__MODULE__{
      message: "the store could not record the changes: #{inspect(error)}",
      error: error
    }
end
