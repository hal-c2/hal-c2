defmodule HalC2.RuntimeRespond do
  @moduledoc """
  The one way the bundled runtimes ask their own process to answer a pending
  request (a question, an approval, a dialog) for the user.

  A runtime busy with earlier work (committing a turn's events behind a busy
  stream, say) still holds the answer in its mailbox and hands it over when it
  gets to it, so this call's own timeout is answered `:ok`: the answer is on
  its way, and the request resolves on the thread's stream when it lands.
  Reporting it as a failure told the user an answer had failed that the agent
  then received. If the request is gone by the time the runtime reads the
  answer, it was already resolved or cancelled, which the thread shows.

  As with `HalC2.RuntimeSteer`, only this call's own timeout is pinned: any
  other exit (the runtime dying mid-call, a nested provider call's timeout
  that takes it down) propagates to the caller. Where a handler blocks in a
  nested call, the budget must outlive that call's.
  """

  @doc "How long a runtime may take to answer before its answer counts as held."
  def timeout, do: Application.get_env(:hal_c2, :runtime_respond_timeout_ms, 15_000)

  @spec call(pid(), String.t(), map(), timeout()) :: :ok | {:error, term()}
  def call(pid, request_id, response, timeout \\ timeout()) do
    GenServer.call(pid, {:respond, request_id, response}, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [^pid, {:respond, _, _}, _]}} -> :ok
  end
end
