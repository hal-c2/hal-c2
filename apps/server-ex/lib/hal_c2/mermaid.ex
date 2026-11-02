defmodule HalC2.Mermaid do
  @moduledoc """
  Draws Mermaid diagrams for every client (`mermaid.render`): an SVG for the desktop
  and the phone, text for the terminal. The drawing is done by the bundled helper
  (native/mermaid), one short run per diagram, so a page, a reply and a file showing
  the same diagram on any surface get the same picture. See
  docs/internals/mermaid.md for why it is drawn here and not in the clients.

  A result is a map in the wire's shape, `"status"` one of:

  - `"drawn"`, with `"svg"`, `"width"` and `"height"`, or `"text"`;
  - `"unsupported"`, a type (or, for text, a type's drawing) the helper lacks;
  - `"invalid"`, a mistake in the source, with its 1-based `"line"` and `"column"`
    when known;
  - `"failed"`, when no drawing came back: the helper is missing, crashed or took
    too long.

  Every result has the diagram's `"kind"` (nil when there is none) and, unless drawn,
  a `"reason"` to show the user.

  What the helper says about a source is kept, by its hash, for the next caller: a
  diagram is drawn once however often it is shown. Callers asking for one being drawn
  wait for that drawing. At most `:limit` drawings run at once, the rest in the order
  asked for; one still waiting for its turn after `:wait` ms is dropped and its callers
  told the MC is busy, so every caller is answered well inside `render/2`'s call timeout.
  A diagram not started yet whose callers have all gone (a caller's process, or the
  socket it asks for, ended) is dropped; one being drawn is finished and kept. A `"failed"` result is not kept, so
  the next caller tries again.
  """
  use GenServer

  @max_source 65_536
  # Longer than :wait plus :timeout, so the server answers first.
  @call_timeout 60_000
  @name "hal-c2-mermaid"
  # Built by `vp run build:mermaid` in a checkout; a release bundles it in priv/bin.
  @checkout Path.expand("../../../../native/mermaid/target", __DIR__)

  @type request :: %{source: String.t(), format: String.t(), theme: String.t()}

  @doc """
  Starts the server. Options: `:name` (nil for none), `:draw` (in place of `draw/1`),
  `:limit` drawings at once, `:cache_size` results kept, `:timeout` per drawing and
  `:wait` for a turn to draw, in ms.
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Serves `mermaid.render`: `{"source", "format"?: "svg" | "text", "theme"?: "light" |
  "dark"}`, for `owner` (the asking socket) when given.
  """
  @spec handle(term, pid | nil) :: {:ok, map} | {:error, String.t()}
  def handle(input, owner \\ nil) do
    case request(input) do
      {:ok, request} -> {:ok, render(__MODULE__, request, owner)}
      {:error, _} = error -> error
    end
  end

  @doc "The request in `input`, with its defaults."
  @spec request(term) :: {:ok, request} | {:error, String.t()}
  def request(%{"source" => source} = input) when is_binary(source) do
    format = Map.get(input, "format") || "svg"
    theme = Map.get(input, "theme") || "light"

    cond do
      format not in ~w(svg text) -> {:error, "format must be \"svg\" or \"text\""}
      theme not in ~w(light dark) -> {:error, "theme must be \"light\" or \"dark\""}
      true -> {:ok, %{source: source, format: format, theme: theme}}
    end
  end

  def request(_input), do: {:error, "source must be a string"}

  @doc """
  Draws `request`, or returns what was drawn for it before. The caller waits while
  `owner` (by default the caller) lives; when it ends, a diagram no one else waits for is
  not drawn.
  """
  @spec render(GenServer.server(), request, pid | nil) :: map
  def render(server \\ __MODULE__, request, owner \\ nil)

  def render(_server, %{source: source}, _owner) when byte_size(source) > @max_source,
    do: result("invalid", nil, "This diagram is too long to draw.")

  def render(server, request, owner) do
    GenServer.call(server, {:render, request, owner}, @call_timeout)
  catch
    :exit, {:timeout, _} -> failed("This diagram took too long to draw.")
  end

  @doc """
  Draws `request` with the helper: `{:ok, result}` for what the helper said, or
  `{:error, result}` (a `"failed"` one) when it said nothing.
  """
  @spec draw(request) :: {:ok, map} | {:error, map}
  def draw(request) do
    case helper() do
      nil ->
        {:error, failed("This install has no diagram renderer; reinstall HAL-C2.")}

      helper ->
        input =
          JSON.encode!(%{source: request.source, format: request.format, theme: request.theme})

        run(helper, input)
    end
  end

  defp run(helper, input) do
    # mmdr keeps the font it measures text with under XDG_CACHE_HOME.
    cache = Application.get_env(:hal_c2, :mermaid_font_cache) || HalC2.Paths.cache_dir()

    {out, status} =
      [helper]
      |> Exile.stream(
        input: [input],
        env: [{"XDG_CACHE_HOME", cache}],
        stderr: :consume,
        ignore_epipe: true
      )
      |> Enum.reduce({[], nil}, fn
        {:stdout, data}, {out, status} -> {[out, data], status}
        {:stderr, _}, acc -> acc
        {:exit, status}, {out, _} -> {out, status}
      end)

    with {:status, 0} <- status,
         {:ok, %{"status" => _} = result} <- JSON.decode(IO.iodata_to_binary(out)) do
      {:ok, result}
    else
      _ -> {:error, failed("The diagram renderer failed.")}
    end
  rescue
    error -> {:error, failed("The diagram renderer could not start: #{Exception.message(error)}")}
  end

  @doc "The helper binary: the configured one, the release's, or the checkout's."
  @spec helper() :: String.t() | nil
  def helper do
    [
      Application.get_env(:hal_c2, :mermaid_helper),
      Application.app_dir(:hal_c2, "priv/bin/#{@name}"),
      Path.join([@checkout, "release", @name]),
      Path.join([@checkout, "debug", @name])
    ]
    |> Enum.find(&(is_binary(&1) and File.regular?(&1)))
  end

  defp failed(reason), do: result("failed", nil, reason)

  defp result(status, kind, reason),
    do: %{"status" => status, "kind" => kind, "reason" => reason, "line" => nil, "column" => nil}

  # --- the server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok,
     %{
       tasks: tasks,
       draw: Keyword.get(opts, :draw, &draw/1),
       limit: Keyword.get(opts, :limit, 2),
       cache_size: Keyword.get(opts, :cache_size, 256),
       timeout: Keyword.get(opts, :timeout, 15_000),
       wait: Keyword.get(opts, :wait, 30_000),
       # key => result, and the keys oldest first, to forget the oldest past cache_size
       cache: %{},
       order: :queue.new(),
       # key => {caller, monitor} waiting for it, queued or being drawn
       waiting: %{},
       # monitor => key, for each waiting caller
       callers: %{},
       # {key, request, ref} not started yet, oldest first; ref names its wait timer
       queued: :queue.new(),
       # task ref => {key, task pid, timer}
       running: %{}
     }}
  end

  @impl true
  def handle_call({:render, request}, from, state),
    do: handle_call({:render, request, nil}, from, state)

  def handle_call({:render, request, owner}, {caller, _} = from, state) do
    owner = owner || caller
    key = :crypto.hash(:sha256, [request.format, 0, request.theme, 0, request.source])

    cond do
      Map.has_key?(state.cache, key) ->
        {:reply, state.cache[key], state}

      Map.has_key?(state.waiting, key) ->
        {:noreply, wait(state, key, from, owner)}

      true ->
        ref = make_ref()
        Process.send_after(self(), {:waited_too_long, ref}, state.wait)
        state = %{state | queued: :queue.in({key, request, ref}, state.queued)}
        {:noreply, start_next(wait(state, key, from, owner))}
    end
  end

  @impl true
  def handle_info({ref, outcome}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])

    case outcome do
      {:ok, result} -> {:noreply, finish(state, ref, result, true)}
      {:error, result} -> {:noreply, finish(state, ref, result, false)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.running, ref),
      do: {:noreply, finish(state, ref, failed("The diagram renderer failed."), false)}

  # A caller gone, or its socket: its caller, if alive, is let go. A diagram not started
  # with no one left is dropped.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when is_map_key(state.callers, monitor) do
    {key, callers} = Map.pop(state.callers, monitor)
    {[{from, _}], left} = Enum.split_with(state.waiting[key], &match?({_, ^monitor}, &1))
    GenServer.reply(from, failed("The client asking for this diagram has gone."))
    state = %{state | callers: callers, waiting: Map.put(state.waiting, key, left)}

    case {left, Enum.split_with(:queue.to_list(state.queued), &match?({^key, _, _}, &1))} do
      {[], {[_], queued}} ->
        {:noreply,
         %{state | queued: :queue.from_list(queued), waiting: Map.delete(state.waiting, key)}}

      _ ->
        {:noreply, state}
    end
  end

  # Killing the task stops the helper with it (Exile).
  def handle_info({:too_long, ref}, state) when is_map_key(state.running, ref) do
    {_key, pid, _timer} = state.running[ref]
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, finish(state, ref, failed("This diagram took too long to draw."), false)}
  end

  # Still queued: drop it. Already started (or done), the timer is stale.
  def handle_info({:waited_too_long, ref}, state) do
    case Enum.split_with(:queue.to_list(state.queued), &match?({_, _, ^ref}, &1)) do
      {[{key, _, _}], queued} ->
        busy = failed("The MC is busy drawing other diagrams; try again.")
        {:noreply, answer(%{state | queued: :queue.from_list(queued)}, key, busy)}

      {[], _} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_next(state) do
    with true <- map_size(state.running) < state.limit,
         {{:value, {key, request, _ref}}, queued} <- :queue.out(state.queued) do
      draw = state.draw
      task = Task.Supervisor.async_nolink(state.tasks, fn -> draw.(request) end)
      timer = Process.send_after(self(), {:too_long, task.ref}, state.timeout)
      running = Map.put(state.running, task.ref, {key, task.pid, timer})
      start_next(%{state | queued: queued, running: running})
    else
      _ -> state
    end
  end

  defp finish(state, ref, result, keep?) do
    {{key, _pid, timer}, running} = Map.pop(state.running, ref)
    Process.cancel_timer(timer)
    state = answer(%{state | running: running}, key, result)
    state = if keep?, do: keep(state, key, result), else: state
    start_next(state)
  end

  # Watches the owner, so a caller gone does not keep its diagram queued.
  defp wait(state, key, from, owner) do
    monitor = Process.monitor(owner)

    %{
      state
      | waiting: Map.update(state.waiting, key, [{from, monitor}], &[{from, monitor} | &1]),
        callers: Map.put(state.callers, monitor, key)
    }
  end

  defp answer(state, key, result) do
    {waiters, waiting} = Map.pop(state.waiting, key, [])

    for {from, monitor} <- waiters do
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, result)
    end

    monitors = Enum.map(waiters, &elem(&1, 1))
    %{state | waiting: waiting, callers: Map.drop(state.callers, monitors)}
  end

  defp keep(state, key, result) do
    state = %{
      state
      | cache: Map.put(state.cache, key, result),
        order: :queue.in(key, state.order)
    }

    if map_size(state.cache) > state.cache_size do
      {{:value, oldest}, order} = :queue.out(state.order)
      %{state | cache: Map.delete(state.cache, oldest), order: order}
    else
      state
    end
  end
end
