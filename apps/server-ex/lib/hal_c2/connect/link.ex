defmodule HalC2.Connect.Link do
  @moduledoc """
  The link an operator asked for from the command line (`hal-c2 connect link`),
  carried out when the node starts, and given back when it stops.

  At start, a saved desired link makes the node link itself through the relay
  (`HalC2.Connect.reconcile/1`). Failures the relay calls temporary (408, 429, 5xx,
  unreachable) are retried with exponential backoff, from one second up to thirty,
  for ten minutes; others stop at once, with the relay's recovery hint in
  `status/0`. A normal stop releases the managed tunnel (`HalC2.Connect.release/0`)
  so the account shows the node offline and the next start keeps its address.

  The backoff is app env `:connect_retry_delays` (`[initial, max]` in ms).
  """

  use GenServer
  require Logger

  @delays [1_000, 30_000]
  @budget :timer.minutes(10)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Where the startup link stands: `"state"` is idle (nothing asked), linking,
  retrying, linked or failed, with the last `"message"`, the `"attempts"` made and,
  while retrying, `"giveUpAt"` (ms since startup began, `"startedAt"`).
  """
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    # So a normal stop gets to release the tunnel.
    Process.flag(:trap_exit, true)
    [initial, _max] = Application.get_env(:hal_c2, :connect_retry_delays, @delays)
    now = System.system_time(:millisecond)

    state = %{
      "state" => "idle",
      "attempts" => 0,
      "startedAt" => now,
      "giveUpAt" => now + @budget,
      delay: initial
    }

    if HalC2.Connect.desired_link(),
      do: {:ok, %{state | "state" => "linking"}, {:continue, :attempt}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:attempt, state), do: {:noreply, attempt(state)}

  @impl true
  def handle_info(:attempt, state), do: {:noreply, attempt(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, Map.delete(state, :delay), state}

  @impl true
  def terminate(_reason, _state) do
    HalC2.Connect.release()
    :ok
  end

  defp attempt(state) do
    state = Map.update!(state, "attempts", &(&1 + 1))
    origin = "http://127.0.0.1:#{Application.get_env(:hal_c2, :port, 3780)}"

    case HalC2.Connect.reconcile(origin) do
      {:ok, _} ->
        Map.merge(state, %{"state" => "linked", "message" => nil})

      {:error, kind, message} ->
        [_initial, max] = Application.get_env(:hal_c2, :connect_retry_delays, @delays)
        now = System.system_time(:millisecond)
        Logger.warning("Failed to reconcile HAL-C2 Connect desired link on startup: #{message}")

        if kind == :transient and now + state.delay <= state["giveUpAt"] do
          Process.send_after(self(), :attempt, state.delay)

          Map.merge(state, %{
            "state" => "retrying",
            "message" => message,
            delay: min(state.delay * 2, max)
          })
        else
          Map.merge(state, %{"state" => "failed", "message" => message})
        end
    end
  end
end
