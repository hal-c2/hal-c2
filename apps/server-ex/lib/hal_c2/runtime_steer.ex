defmodule HalC2.RuntimeSteer do
  @moduledoc """
  The one way the bundled runtimes ask their own process to steer a turn,
  except Pi's: its runtime replies on an answer timer of its own and its
  caller waits without a budget (`HalC2.Pi.ThreadRuntime.steer/3`).

  Every runtime here answers a steer the same way, and the orchestration layer
  depends on the semantics staying identical: only this call's own timeout
  means the runtime (or the provider ahead of it) still holds the request
  and hands it over when it gets to it, so that case alone is answered
  `:ok`. The pin on `pid` and the steer request is what says so: a timeout
  from a call nested inside the runtime (its provider `Connection.call`)
  that takes the runtime down surfaces as a different exit and propagates,
  so the caller counts it as a refusal and takes the reserved message back
  out instead of leaving it in a failed turn.

  Two costs are part of the contract. The explicit budget (per runtime,
  env-overridable where the runtime sets it) blocks the dispatching
  process for up to `timeout` on a stuck runtime, where the `GenServer.call`
  default used to exit after 5s. And a steer the handler only reaches
  after this call timed out is handed over only if that turn is still its
  current one; if the turn guard fails by then, the handler's refusal
  reply goes to a caller that already answered `:ok`, so the message
  stays in the turn unread and nobody learns — the accepted loss the
  orchestration layer documents at `reserve_steer/3`.

  This call is not total, `call/4`'s spec notwithstanding: any exit other
  than this call's own timeout — the runtime dying mid-call, a nested-call
  timeout that takes it down — propagates to the caller, who must treat it
  as a refusal. The same holds for every runtime's `steer/3` built on it.
  Budgets must be ordered for that to work: where a handler blocks in a
  nested call, the outer budget must outlive the inner one, or the outer
  timeout (answered `:ok`) always fires first.
  """

  @spec call(pid(), String.t(), map(), timeout()) :: :ok | {:error, term()}
  def call(pid, run_id, message, timeout) do
    GenServer.call(pid, {:steer, run_id, message}, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [^pid, {:steer, _, _}, _]}} -> :ok
  end
end
