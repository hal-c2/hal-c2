defmodule HalC2.TerminalPropTest.Client do
  @moduledoc false
  # A stand-in for a client socket: attaches to terminals from its own process (so the
  # snapshot is handled before any later event, as a real stream does), rebuilds each
  # terminal's text from the snapshot and the output events, and answers questions
  # about it. `:stall` makes it stop reading its mailbox, a slow client.

  alias HalC2.Terminal

  def start, do: spawn(fn -> loop(%{terms: %{}, hub: nil, waiting: []}) end)

  defp loop(st) do
    receive do
      {:hal_c2_terminal, key, event} ->
        loop(st |> event(key, event) |> settle())

      {:hal_c2_terminals, _node, event} ->
        loop(%{st | hub: hub_event(st.hub, event)})

      {:attach, from, ref, input} ->
        key = {input["threadId"], input["terminalId"]}
        result = Terminal.attach(input, self())
        send(from, {ref, result})

        st =
          case result do
            {:ok, snap} ->
              term = %{
                text: snap["history"],
                status: snap["status"],
                seq: snap["sequence"],
                bad: []
              }

              put_in(st.terms[key], term)

            _ ->
              st
          end

        loop(settle(st))

      {:detach, from, ref, {thread_id, terminal_id} = key} ->
        Terminal.detach(thread_id, terminal_id, self())
        send(from, {ref, :ok})
        loop(%{st | terms: Map.delete(st.terms, key)})

      {:watch, from, ref} ->
        summaries = HalC2.Terminal.Hub.watch(self())
        send(from, {ref, :ok})
        loop(%{st | hub: Map.new(summaries, &{{&1["threadId"], &1["terminalId"]}, &1["status"]})})

      {:unwatch, from, ref} ->
        HalC2.Terminal.Hub.unwatch(self())
        send(from, {ref, :ok})
        loop(%{st | hub: nil})

      {:await, from, ref, key, conds} ->
        loop(settle(%{st | waiting: st.waiting ++ [{from, ref, key, conds}]}))

      {:get, from, ref, key} ->
        send(from, {ref, Map.get(st.terms, key)})
        loop(st)

      {:get_hub, from, ref} ->
        send(from, {ref, st.hub})
        loop(st)

      {:stall, from, ref} ->
        send(from, {ref, :ok})

        receive do
          :resume -> loop(st)
        end
    end
  end

  # Only terminals this client is attached to count; a stray event after a detach is
  # one the terminal sent before it processed the detach.
  defp event(st, key, ev) do
    case st.terms do
      %{^key => term} ->
        seq = ev["sequence"]

        bad =
          if is_integer(seq) and seq <= term.seq,
            do: [{:seq, term.seq, ev} | term.bad],
            else: term.bad

        term = %{
          term
          | seq: if(is_integer(seq), do: max(seq, term.seq), else: term.seq),
            bad: bad
        }

        put_in(st.terms[key], apply_event(term, ev))

      _ ->
        st
    end
  end

  defp apply_event(term, %{"type" => "output", "data" => data}),
    do: %{term | text: term.text <> data}

  defp apply_event(term, %{"type" => type, "snapshot" => snap})
       when type in ~w(snapshot restarted),
       do: %{term | text: snap["history"], status: snap["status"]}

  defp apply_event(term, %{"type" => "cleared"}), do: %{term | text: ""}
  defp apply_event(term, %{"type" => "exited"}), do: %{term | status: "exited"}
  defp apply_event(term, %{"type" => "closed"}), do: %{term | status: "closed"}
  defp apply_event(term, _), do: term

  defp hub_event(nil, _), do: nil

  defp hub_event(hub, %{"type" => "upsert", "terminal" => t}),
    do: Map.put(hub, {t["threadId"], t["terminalId"]}, t["status"])

  defp hub_event(hub, %{"type" => "remove", "threadId" => th, "terminalId" => te}),
    do: Map.delete(hub, {th, te})

  defp hub_event(hub, _), do: hub

  defp settle(st) do
    {ready, waiting} =
      Enum.split_with(st.waiting, fn {_, _, key, conds} -> met?(st.terms[key], conds) end)

    for {from, ref, _, _} <- ready, do: send(from, {ref, :ready})
    %{st | waiting: waiting}
  end

  defp met?(nil, _), do: false

  defp met?(term, conds) do
    Enum.all?(conds, fn
      {:tokens, tokens} -> Enum.all?(tokens, fn {str, k} -> count(term.text, str) >= k end)
      :exited -> term.status == "exited"
    end)
  end

  def count(text, str), do: length(String.split(text, str)) - 1
end

defmodule HalC2.TerminalPropTest do
  @moduledoc """
  `HalC2.Terminal` and its hub against a model of which terminals exist, what each has
  printed, and who is attached. The shell is `cat` on a PTY: a written line comes back
  twice (the terminal's echo, then cat), and ^D ends it, so every line is output the
  model can predict. `inject` hands the terminal output as if the shell had printed it,
  which lands inside the batching window so attaches and clears race the pending batch.

  The promises: every attached client rebuilds exactly the terminal's scrollback from
  its snapshot and the events after (in order, nothing twice, nothing lost); a closed
  terminal, a replaced shell and a crashed terminal leave no OS process; the registry
  and the hub list exactly the terminals that exist, also after the hub restarts or a
  client crashes; a client that stops reading does not stall the others.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Terminal
  alias HalC2.Terminal.{History, Hub}
  alias HalC2.TerminalPropTest.Client

  @moduletag timeout: :infinity

  @keys [{"th1", "a"}, {"th1", "b"}, {"th2", "a"}]
  @registry HalC2.Terminal.Registry
  @wait 15_000

  property "terminals, their clients and the hub agree with the model",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        HalC2.Prop.scratch_home("terminal")
        shell = System.get_env("SHELL")
        System.put_env("SHELL", System.find_executable("cat"))
        Process.put(:seen_pids, MapSet.new())
        Process.put(:clients, [])

        HalC2.Prop.start_services([
          {Registry, keys: :unique, name: @registry},
          {DynamicSupervisor, name: HalC2.Terminal.Supervisor, strategy: :one_for_one},
          Hub
        ])

        {history, state, result} = run_commands(__MODULE__, cmds)
        note_pids()
        for pid <- Process.get(:clients), do: Process.exit(pid, :kill)
        HalC2.Prop.stop_services()
        leaked = Enum.reject(Process.get(:seen_pids), &gone?/1)
        if shell, do: System.put_env("SHELL", shell), else: System.delete_env("SHELL")

        (result == :ok and leaked == [])
        |> when_fail(
          IO.puts(
            HalC2.Prop.report(cmds, history, state, result) <>
              "\nleaked OS pids: #{inspect(leaked)}"
          )
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  property "history keeps the newest output within its bounds",
    numtests: HalC2.Prop.numtests(100),
    max_size: 60 do
    forall {chunks, max_lines, max_bytes} <-
             {list(resize(40, text_chunk())), integer(1, 8), integer(8, 120)} do
      history =
        Enum.reduce(chunks, History.new("", max_lines: max_lines, max_bytes: max_bytes), fn c,
                                                                                            h ->
          History.append(h, c)
        end)

      value = History.value(history)
      all = Enum.join(chunks)

      bounded = byte_size(value) <= max_bytes and history.bytes == byte_size(value)
      newest = String.ends_with?(all, value)

      lines =
        length(String.split(value, "\n")) - if(String.ends_with?(value, "\n"), do: 1, else: 0)

      (bounded and newest and lines <= max_lines and history.lines == count(value, "\n"))
      |> when_fail(IO.inspect({value, history}, label: "history"))
    end
  end

  property "history does not depend on how the output is chunked",
    numtests: HalC2.Prop.numtests(100),
    max_size: 60 do
    forall {chunks, cuts} <- {list(resize(30, escape_chunk())), list(integer(1, 7))} do
      whole = Enum.join(chunks)
      history = History.append(History.new(), whole)

      split =
        Enum.reduce(cut(whole, cuts), History.new(), fn piece, h -> History.append(h, piece) end)

      History.value(split) == History.value(history) and split.pending == history.pending
    end
  end

  defp text_chunk,
    do: resize(20, list(oneof([range(?a, ?e), ?\n, ?\n, ?é, ?\r]))) |> let_to_string()

  defp escape_chunk do
    oneof([
      text_chunk(),
      elements(["\e[6n", "\e[?u", "\e]11;?\a", "\e[1;31m", "\e[0c", "\e[", "\e]", "\ex"])
    ])
  end

  defp let_to_string(gen), do: let(chars <- gen, do: List.to_string(chars))

  defp cut(binary, []), do: [binary]

  defp cut(binary, [n | rest]) when byte_size(binary) > n do
    <<head::binary-size(^n), tail::binary>> = binary
    [head | cut(tail, rest)]
  end

  defp cut(binary, _), do: [binary]

  defp count(text, str), do: Client.count(text, str)

  # --- model ----------------------------------------

  # terms: key => %{status: :running | :exited, tokens: [{text, times}], attached: [pid]}
  # disk: key => tokens a closed terminal saved. clients: pid => %{stalled, watching}
  def initial_state, do: %{terms: %{}, disk: %{}, clients: %{}, n: 0}

  def command(s) do
    keys = @keys
    live = Map.keys(s.terms)
    running = for {k, %{status: :running}} <- s.terms, do: k
    free = for {pid, %{stalled: false}} <- s.clients, do: pid
    attachments = for {k, t} <- s.terms, pid <- t.attached, free?(s, pid), do: {pid, k}
    token = "t#{s.n}"

    entries =
      [
        {4, {:call, __MODULE__, :open, [elements(keys)]}},
        {2, {:call, __MODULE__, :new_client, []}},
        {2, {:call, __MODULE__, :restart_hub, []}},
        {2, {:call, __MODULE__, :resize, [elements(keys), integer(10, 200), integer(5, 60)]}},
        {2, {:call, __MODULE__, :restart, [elements(keys)]}},
        {2,
         let(
           key <- elements(keys),
           do: {:call, __MODULE__, :close, [key, boolean(), tokens_of(s, key)]}
         )},
        {4, {:call, __MODULE__, :write, [elements(keys), token]}},
        {3,
         let(key <- elements(keys), do: {:call, __MODULE__, :clear, [key, tokens_of(s, key)]})},
        {3, {:call, __MODULE__, :check, [check_args(s)]}},
        {4, {:call, __MODULE__, :sync, [sync_args(s)]}}
      ] ++
        if(running != [],
          do: [
            {4, {:call, __MODULE__, :inject, [elements(running), "i#{s.n}"]}},
            {2,
             let(
               key <- elements(running),
               do: {:call, __MODULE__, :die, [key, elements([:eof, :kill]), tokens_of(s, key)]}
             )}
          ],
          else: []
        ) ++
        if(live != [], do: [{1, {:call, __MODULE__, :crash, [elements(live)]}}], else: []) ++
        if(free != [],
          do: [
            {5,
             {:call, __MODULE__, :attach, [elements(free), elements(keys), boolean(), boolean()]}},
            {2, {:call, __MODULE__, :stall, [elements(free)]}},
            {2, {:call, __MODULE__, :kill_client, [elements(free)]}},
            {2, {:call, __MODULE__, :watch, [elements(free)]}},
            {1, {:call, __MODULE__, :unwatch, [elements(free)]}}
          ],
          else: []
        ) ++
        if(attachments != [],
          do: [{3, {:call, __MODULE__, :detach, [elements(attachments)]}}],
          else: []
        ) ++
        if(Enum.any?(s.clients, fn {_, c} -> c.stalled end),
          do: [
            {2,
             {:call, __MODULE__, :resume,
              [elements(for({p, %{stalled: true}} <- s.clients, do: p))]}}
          ],
          else: []
        )

    frequency(entries)
  end

  # Terminals in the model with who is attached, and what the hub should list.
  defp check_args(s) do
    {for({k, t} <- s.terms, do: {k, t.status, t.attached}),
     for({pid, %{watching: true, stalled: false}} <- s.clients, do: pid),
     for({pid, %{stalled: true}} <- s.clients, do: pid),
     for({pid, %{watching: true}} <- s.clients, do: pid)}
  end

  defp sync_args(s) do
    for {k, t} <- s.terms,
        pid <- t.attached,
        s.clients[pid].stalled == false,
        do: {pid, k, t.tokens, t.status == :exited}
  end

  def precondition(s, {:call, _, :write, [_, token]}), do: token == "t#{s.n}"

  def precondition(s, {:call, _, :inject, [key, token]}),
    do: running?(s, key) and token == "i#{s.n}"

  def precondition(s, {:call, _, :die, [key, _, tokens]}),
    do: running?(s, key) and tokens == tokens_of(s, key)

  def precondition(s, {:call, _, :clear, [key, tokens]}), do: tokens == tokens_of(s, key)
  def precondition(s, {:call, _, :close, [key, _, tokens]}), do: tokens == tokens_of(s, key)
  def precondition(s, {:call, _, :crash, [key]}), do: Map.has_key?(s.terms, key)

  def precondition(s, {:call, _, :attach, [pid, key, cwd?, _]}) do
    free?(s, pid) and (cwd? or Map.has_key?(s.terms, key))
  end

  def precondition(s, {:call, _, name, [pid]})
      when name in [:stall, :kill_client, :watch, :unwatch],
      do: free?(s, pid)

  def precondition(s, {:call, _, :resume, [pid]}), do: match?(%{stalled: true}, s.clients[pid])

  def precondition(s, {:call, _, :detach, [{pid, key}]}),
    do:
      free?(s, pid) and match?(%{attached: attached} when is_list(attached), s.terms[key]) and
        pid in s.terms[key].attached

  def precondition(s, {:call, _, :check, [args]}), do: args == check_args(s)
  def precondition(s, {:call, _, :sync, [args]}), do: args == sync_args(s)
  def precondition(_, _), do: true

  defp tokens_of(s, key), do: if(s.terms[key], do: s.terms[key].tokens, else: [])

  defp running?(s, key), do: match?(%{status: :running}, s.terms[key])
  defp free?(s, pid), do: match?(%{stalled: false}, s.clients[pid])

  def next_state(s, pid, {:call, _, :new_client, []}),
    do: put_in(s.clients[pid], %{stalled: false, watching: false})

  def next_state(s, _, {:call, _, :kill_client, [pid]}) do
    terms = Map.new(s.terms, fn {k, t} -> {k, %{t | attached: List.delete(t.attached, pid)}} end)
    %{s | clients: Map.delete(s.clients, pid), terms: terms}
  end

  def next_state(s, _, {:call, _, :stall, [pid]}), do: put_in(s.clients[pid].stalled, true)
  def next_state(s, _, {:call, _, :resume, [pid]}), do: put_in(s.clients[pid].stalled, false)
  def next_state(s, _, {:call, _, :watch, [pid]}), do: put_in(s.clients[pid].watching, true)
  def next_state(s, _, {:call, _, :unwatch, [pid]}), do: put_in(s.clients[pid].watching, false)

  def next_state(s, _, {:call, _, :restart_hub, []}),
    do: %{s | clients: Map.new(s.clients, fn {p, c} -> {p, %{c | watching: false}} end)}

  def next_state(s, _, {:call, _, :open, [key]}) do
    case s.terms[key] do
      nil -> start(s, key)
      %{status: :exited} = t -> put_in(s.terms[key], %{t | status: :running, tokens: []})
      _ -> s
    end
  end

  def next_state(s, _, {:call, _, :attach, [pid, key, cwd?, restart?]}) do
    s =
      case s.terms[key] do
        nil ->
          start(s, key)

        %{status: :exited} = t when cwd? and restart? ->
          put_in(s.terms[key], %{t | status: :running, tokens: []})

        _ ->
          s
      end

    update_in(s.terms[key].attached, &Enum.uniq(&1 ++ [pid]))
  end

  def next_state(s, _, {:call, _, :detach, [{pid, key}]}),
    do: update_in(s.terms[key].attached, &List.delete(&1, pid))

  def next_state(s, _, {:call, _, :write, [key, token]}) do
    s = %{s | n: s.n + 1}

    if running?(s, key),
      do: update_in(s.terms[key].tokens, &(&1 ++ [{token <> "\r\n", 2}])),
      else: s
  end

  def next_state(s, _, {:call, _, :inject, [key, token]}) do
    s = %{s | n: s.n + 1}
    update_in(s.terms[key].tokens, &(&1 ++ [{token <> "\r\n", 1}]))
  end

  def next_state(s, _, {:call, _, :clear, [key, _]}) do
    if s.terms[key], do: update_in(s.terms[key].tokens, fn _ -> [] end), else: s
  end

  def next_state(s, _, {:call, _, :restart, [key]}) do
    case s.terms[key] do
      nil -> start(s, key, [])
      t -> put_in(s.terms[key], %{t | status: :running, tokens: []})
    end
  end

  def next_state(s, _, {:call, _, :close, [key, delete?, _]}) do
    disk =
      case {s.terms[key], delete?} do
        {_, true} -> Map.delete(s.disk, key)
        {nil, false} -> s.disk
        {t, false} -> Map.put(s.disk, key, t.tokens)
      end

    %{s | terms: Map.delete(s.terms, key), disk: disk}
  end

  def next_state(s, _, {:call, _, :die, [key, _, _]}), do: put_in(s.terms[key].status, :exited)

  # A killed terminal never saved, so what the disk holds is unknown: expect nothing.
  def next_state(s, _, {:call, _, :crash, [key]}),
    do: %{s | terms: Map.delete(s.terms, key), disk: Map.put(s.disk, key, [])}

  def next_state(s, _, _call), do: s

  defp start(s, key, disk \\ nil) do
    tokens = disk || Map.get(s.disk, key, [])
    put_in(s.terms[key], %{status: :running, tokens: tokens, attached: []})
  end

  def postcondition(s, {:call, _, :open, [key]}, result) do
    next = next_state(s, nil, {:call, nil, :open, [key]})
    match?({:ok, %{status: "running"}}, result) and next.terms[key].status == :running
  end

  def postcondition(s, {:call, _, :attach, [_, key, _, _]} = call, result) do
    next = next_state(s, nil, call)
    {:ok, %{status: status}} = result
    status == Atom.to_string(next.terms[key].status)
  end

  def postcondition(s, {:call, _, :write, [key, _]}, result) do
    case s.terms[key] do
      nil -> lookup_error?(result)
      %{status: :running} -> result == {:ok, nil}
      %{status: :exited} -> match?({:error, %{"_tag" => "TerminalNotRunningError"}}, result)
    end
  end

  def postcondition(s, {:call, _, name, [key | _]}, result) when name in [:resize, :clear] do
    if s.terms[key], do: result == {:ok, nil}, else: lookup_error?(result)
  end

  def postcondition(_, {:call, _, :restart, _}, result),
    do: match?({:ok, %{status: "running"}}, result)

  def postcondition(_, {:call, _, :close, _}, result), do: result == {:ok, nil}

  def postcondition(_, {:call, _, name, _}, result) when name in [:new_client, :kill_client],
    do: is_pid(result) or result == :ok

  def postcondition(_, _call, result), do: result == :ok

  defp lookup_error?(result),
    do: match?({:error, %{"_tag" => "TerminalSessionLookupError"}}, result)

  # --- wrappers ----------------------------------------

  defp input(key, extra \\ %{}) do
    {thread_id, terminal_id} = key
    Map.merge(%{"threadId" => thread_id, "terminalId" => terminal_id}, extra)
  end

  defp launch(key, extra \\ %{}),
    do: input(key, Map.merge(%{"cwd" => File.cwd!(), "cols" => 80, "rows" => 24}, extra))

  defp slim({:ok, %{"status" => status}}), do: {:ok, %{status: status}}
  defp slim({:ok, _} = ok), do: ok
  defp slim(other), do: other

  defp pid_of(key) do
    [{pid, _}] = Registry.lookup(@registry, key)
    pid
  end

  defp term_state(key), do: :sys.get_state(pid_of(key))

  # Remembers the OS process of every shell, so one that outlives its terminal is found.
  defp note_pids do
    for {_, pid, _} <- registered(), os = os_pid(pid) do
      Process.put(:seen_pids, MapSet.put(Process.get(:seen_pids), os))
    end

    :ok
  end

  defp os_pid(pid) do
    :sys.get_state(pid).os_pid
  catch
    :exit, _ -> nil
  end

  defp registered,
    do: Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])

  # `tail --pid` returns once the process is gone and reaped: a signal, not a sleep.
  # A shell still there after 5 s is leaked.
  defp gone?(os_pid) do
    {_, status} =
      System.cmd("timeout", ["5", "tail", "--pid=#{os_pid}", "-f", "/dev/null"],
        stderr_to_stdout: true
      )

    status == 0
  end

  defp alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        [state | _] = stat |> String.split(") ", parts: 2) |> List.last() |> String.split(" ")
        state != "Z"

      {:error, _} ->
        false
    end
  end

  def open(key) do
    note_pids()
    slim(Terminal.open(launch(key)))
  end

  def restart(key) do
    note_pids()
    slim(Terminal.restart(launch(key)))
  end

  def write(key, token) do
    note_pids()
    Terminal.write(input(key, %{"data" => token <> "\n"}))
  end

  def resize(key, cols, rows), do: Terminal.resize(input(key, %{"cols" => cols, "rows" => rows}))
  # Output of writes still on its way would land after the clear; wait for it first.
  def clear(key, tokens) do
    settle(key, tokens)
    Terminal.clear(input(key))
  end

  defp settle(key, tokens) do
    with pid when is_pid(pid) <-
           Registry.lookup(@registry, key) |> List.first() |> then(&(&1 && elem(&1, 0))),
         %{status: "running"} <- :sys.get_state(pid) do
      {thread_id, terminal_id} = key
      {:ok, %{"history" => text}} = Terminal.attach(input(key), self())
      settle_loop(key, tokens, text)
      Terminal.detach(thread_id, terminal_id, self())
      :sys.get_state(pid)
      drain()
    end

    :ok
  end

  defp settle_loop(key, tokens, text) do
    if Enum.all?(tokens, fn {str, k} -> Client.count(text, str) >= k end) do
      :ok
    else
      receive do
        {:hal_c2_terminal, ^key, %{"type" => "output", "data" => data}} ->
          settle_loop(key, tokens, text <> data)

        {:hal_c2_terminal, ^key, _} ->
          settle_loop(key, tokens, text)
      after
        @wait -> flunk("output of #{inspect(key)} did not arrive: #{inspect(tokens)}")
      end
    end
  end

  # The scrollback a close saves holds what the shell printed before it; a line the
  # shell had not printed yet when it was stopped is not lost output.
  def close(key, delete?, tokens) do
    note_pids()
    settle(key, tokens)
    Terminal.close(input(key, %{"deleteHistory" => delete?}))
  end

  # Output the shell "printed": into the scrollback and the pending batch.
  def inject(key, token) do
    state = term_state(key)
    send(pid_of(key), {:stdout, state.os_pid, token <> "\r\n"})
    :ok
  end

  # The shell ends on its own (^D) or is killed from outside, once it printed what
  # earlier writes asked for; returns once the terminal has told a subscriber so.
  def die(key, how, tokens) do
    note_pids()
    settle(key, tokens)
    pid = pid_of(key)
    os_pid = :sys.get_state(pid).os_pid
    {thread_id, terminal_id} = key
    {:ok, _} = Terminal.attach(input(key), self())

    case how do
      :eof -> {:ok, nil} = Terminal.write(input(key, %{"data" => <<4>>}))
      :kill -> {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    end

    wait_exit(key)
    Terminal.detach(thread_id, terminal_id, self())
    :sys.get_state(pid)
    drain()
    :ok
  end

  defp wait_exit(key) do
    receive do
      {:hal_c2_terminal, ^key, %{"type" => "exited"}} -> :ok
      {:hal_c2_terminal, _, _} -> wait_exit(key)
    after
      @wait -> flunk("shell of #{inspect(key)} did not exit")
    end
  end

  defp drain do
    receive do
      {:hal_c2_terminal, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  def crash(key) do
    note_pids()
    pid = pid_of(key)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      @wait -> flunk("terminal did not die")
    end

    # A killed process is dropped from the registry by its partition, asynchronously.
    for {_, partition, _, _} <- Supervisor.which_children(@registry),
        is_pid(partition),
        do: :sys.get_state(partition)

    :ok
  end

  def new_client do
    pid = Client.start()
    Process.put(:clients, [pid | Process.get(:clients)])
    pid
  end

  def kill_client(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp ask(pid, tag, args \\ []) do
    ref = make_ref()
    send(pid, List.to_tuple([tag, self(), ref | args]))

    receive do
      {^ref, reply} -> reply
    after
      @wait -> :timeout
    end
  end

  def attach(client, key, cwd?, restart?) do
    extra = if cwd?, do: %{"cwd" => File.cwd!()}, else: %{}
    extra = if restart?, do: Map.put(extra, "restartIfNotRunning", true), else: extra
    note_pids()
    slim(ask(client, :attach, [input(key, extra)]))
  end

  def detach({client, key}), do: ask(client, :detach, [key])
  def stall(client), do: ask(client, :stall)

  def resume(client),
    do:
      (
        send(client, :resume)
        :ok
      )

  def watch(client), do: ask(client, :watch)
  def unwatch(client), do: ask(client, :unwatch)

  def restart_hub do
    HalC2.Prop.restart_service(Hub)
    # `summaries` runs after the hub asked every terminal to report again.
    Hub.summaries()
    :ok
  end

  # Waits until every attached, reading client has seen the model's output, then
  # compares what each rebuilt with the terminal's scrollback.
  def sync(entries) do
    Enum.find_value(entries, :ok, fn {client, key, tokens, exited?} ->
      conds = [{:tokens, tokens}] ++ if(exited?, do: [:exited], else: [])

      case ask(client, :await, [key, conds]) do
        :ready -> compare(client, key)
        :timeout -> {:error, {:timeout, client, key, tokens, ask(client, :get, [key])}}
      end
    end)
  end

  defp compare(client, key) do
    %{text: text, bad: bad} = ask(client, :get, [key])
    history = History.value(term_state(key).history)

    cond do
      bad != [] -> {:error, {:sequence_not_increasing, bad}}
      text != history -> {:error, {:client_differs, client, key, text, history}}
      true -> nil
    end
  end

  def check({terms, watchers, stalled, all_watchers}) do
    note_pids()
    live = for {key, _, _} <- terms, do: pid_of(key)
    for pid <- live, do: :sys.get_state(pid)

    expected = terms |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    registry = for({key, _, _} <- registered(), do: key) |> Enum.sort()
    _ = {watchers, stalled}
    summaries = Hub.summaries()
    hub = for(s <- summaries, do: {s["threadId"], s["terminalId"]}) |> Enum.sort()
    hub_state = :sys.get_state(Hub)

    problems =
      [
        {registry != expected, {:registry, registry, expected}},
        {hub != expected, {:hub_lists, hub, expected}},
        {Enum.sort(Map.keys(hub_state.watchers)) != Enum.sort(all_watchers),
         {:hub_watchers, Map.keys(hub_state.watchers), all_watchers}},
        {map_size(hub_state.terminals) != length(expected), :hub_terminals}
      ] ++
        for(
          {key, status, attached} <- terms,
          do: terminal_problems(key, status, attached, summaries)
        ) ++
        for(pid <- watchers, do: watcher_problem(pid, terms)) ++
        os_problems(terms)

    case for({true, problem} <- problems, do: problem) |> List.flatten() do
      [] -> :ok
      found -> {:error, found}
    end
  end

  defp terminal_problems(key, status, attached, summaries) do
    state = term_state(key)
    summary = Enum.find(summaries, &({&1["threadId"], &1["terminalId"]} == key))
    want = Atom.to_string(status)

    [
      {state.status != want, {:status, key, state.status, want}},
      {Enum.sort(Map.keys(state.subscribers)) != Enum.sort(attached),
       {:subscribers, key, Map.keys(state.subscribers), attached}},
      {summary == nil or summary["status"] != want, {:hub_status, key, summary, want}},
      {state.output != [] and state.output_timer == nil, {:output_without_timer, key}}
    ]
  end

  defp watcher_problem(pid, terms) do
    want = Map.new(terms, fn {key, status, _} -> {key, Atom.to_string(status)} end)
    got = ask(pid, :get_hub)
    {got != want, {:watcher_differs, pid, got, want}}
  end

  # A shell exists exactly while its terminal is running.
  defp os_problems(terms) do
    running =
      for {key, :running, _} <- terms, do: term_state(key).os_pid

    exited = for {key, :exited, _} <- terms, do: term_state(key).os_pid
    seen = MapSet.to_list(Process.get(:seen_pids))
    stale = Enum.reject(seen -- running, &gone?/1)
    dead = Enum.reject(running, &alive?/1)

    [
      {stale != [], {:os_process_left_over, stale}},
      {dead != [], {:os_process_missing, for(p <- dead, do: {p, File.read("/proc/#{p}/stat")})}},
      {Enum.any?(exited, &(&1 != nil)), {:exited_with_pid, exited}}
    ]
  end
end
