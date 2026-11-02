defmodule HalC2.Terminal.OutputWindow do
  @moduledoc """
  How much terminal output one subscription may have unacknowledged, for a client
  that asked to acknowledge what it has handled (`"acks": true` on its `sub`).

  Output is let through until `@limit` bytes wait; a subscription over that is
  `behind`, and what the terminal prints from then on is not sent or buffered for it.
  Once it has acknowledged everything it was sent, it `:caught_up`, and the socket
  sends a new snapshot, which holds what it missed from the terminal's bounded
  scrollback. The shell is never slowed: another client may be keeping up.

  A snapshot starts the window over. Its history does not count, or output would be
  held right after any snapshot of more than `@limit` and a client keeping up with a
  busy shell would be sent nothing but snapshots; it stays unacknowledged until the
  client says so, so what one subscription holds is one snapshot and `@limit` of output.
  """

  @limit 64 * 1024

  defstruct pending: [], bytes: 0, behind: false

  @type t :: %__MODULE__{
          # Newest first: {sequence, bytes}.
          pending: [{integer, non_neg_integer}],
          bytes: non_neg_integer,
          behind: boolean
        }

  @doc "How many unacknowledged bytes hold a subscription's output back."
  def limit, do: @limit

  def new, do: %__MODULE__{}

  @doc "Whether `event` goes to the subscription (`:send`) or is left out of it (`:hold`)."
  def offer(_window, %{"snapshot" => %{"sequence" => seq}}),
    do: {:send, %__MODULE__{pending: [{seq, 0}]}}

  def offer(_window, %{"type" => "closed"}), do: {:send, new()}

  def offer(%{behind: true} = window, %{"type" => "output"}), do: {:hold, window}

  def offer(%{bytes: bytes} = window, %{"type" => "output"}) when bytes >= @limit,
    do: {:hold, %{window | behind: true}}

  def offer(window, %{"type" => "output", "data" => data, "sequence" => seq}) do
    size = byte_size(data)
    {:send, %{window | pending: [{seq, size} | window.pending], bytes: window.bytes + size}}
  end

  def offer(window, _event), do: {:send, window}

  @doc """
  The client has handled everything up to `sequence`. `:caught_up` when it was
  behind and now holds nothing unacknowledged.
  """
  def ack(window, sequence) do
    pending = Enum.filter(window.pending, fn {seq, _} -> seq > sequence end)
    bytes = pending |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    window = %{window | pending: pending, bytes: bytes}

    if window.behind and pending == [], do: {:caught_up, window}, else: {:ok, window}
  end
end
