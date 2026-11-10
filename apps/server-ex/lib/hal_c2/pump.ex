defmodule HalC2.Pump do
  @moduledoc """
  The loop a process we spawn ourselves waits in, so a hot code update never finds it
  waiting in code that changes (`HalC2.Frozen`).

  The logic is `mod.step(state, event)`, called by name once per event, so each event
  runs the newest `mod`. It answers what to wait for next:

    * `{:call, {m, f, a}, state}`: `apply(m, f, a)`, a blocking read say. The next
      event is `{:called, result}`.
    * `{:receive, tags, timeout, state}`: the next message whose tag (the message
      itself if an atom, else a tuple's first element) is a key of the map `tags`,
      as `{:message, message}`; other messages stay in the mailbox. `:timeout` after
      `timeout`.
    * `{:done, value}`: the loop returns `value`, and a process spawned here ends.

  The first event is `:start`. The state crosses versions of `mod`, so a new version
  takes the state an old one left. It holds no funs either: a fun runs the code it
  was made in, and holding one keeps that module's old version in use.
  """

  use HalC2.Frozen

  @doc "Spawns a process linked to the caller that runs `mod` from `state`."
  @spec spawn_link(module, term) :: pid
  def spawn_link(mod, state), do: :erlang.spawn_link(__MODULE__, :run, [mod, state])

  @doc "Spawns a process that runs `mod` from `state`."
  @spec spawn(module, term) :: pid
  def spawn(mod, state), do: :erlang.spawn(__MODULE__, :run, [mod, state])

  @doc "Runs `mod` from `state` in the calling process until a step is `{:done, value}`."
  def run(mod, state), do: resume(mod, mod.step(state, :start))

  @doc """
  Carries on from `action`, what a step answered. A loop that ran in `mod`'s own code
  before it had steps hands its process over with this.
  """
  def resume(mod, {:call, {m, f, a}, state}),
    do: resume(mod, mod.step(state, {:called, apply(m, f, a)}))

  def resume(mod, {:receive, tags, timeout, state}) do
    receive do
      message when is_atom(message) and is_map_key(tags, message) ->
        resume(mod, mod.step(state, {:message, message}))

      message
      when is_tuple(message) and tuple_size(message) > 0 and is_map_key(tags, elem(message, 0)) ->
        resume(mod, mod.step(state, {:message, message}))
    after
      timeout -> resume(mod, mod.step(state, :timeout))
    end
  end

  def resume(_mod, {:done, value}), do: value
end
