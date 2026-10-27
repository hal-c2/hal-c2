defmodule HalC2.SettingsPropTest do
  @moduledoc """
  `HalC2.Settings` against a model of its document: the settings, the version the
  next `put/2` must name, what settings.json holds, and the notifications a watcher
  is owed. Commands write through the RPC a client uses (validate, then a versioned
  put), merge and drop keys with `update/1`, edit the file from outside as
  `mix hal_c2.theme` does, break it, and restart the server, which must keep the
  document but starts counting versions again. Some keys are shared with the cluster
  (`HalC2.Settings.Shared`), and so are the keybinding rules: every change to one is
  stamped, and members' records arrive in any order, from clocks behind or ahead of
  this one, and win only when newer; a keybinding edit queued behind them is made on
  top of them. While the document cannot be read the shared keys stand in for it,
  so a write then resets none it left alone. A second property races writers on one
  version.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  import HalC2.Prop.Generators

  alias HalC2.Settings

  @moduletag timeout: :infinity

  # A few shared keys, and two members whose ids sort either side of this MC's, so a
  # tie in time goes either way.
  @shared ~w(defaultRuntimeMode worktreeSubmodules responseStreamingMode)
  @own "mc-m"
  # Members' clocks are far behind (1..3) or far ahead (from here) of this one's.
  @future 4_000_000_000_000

  setup do
    previous = :persistent_term.get({HalC2.Environment, :id}, nil)
    :persistent_term.put({HalC2.Environment, :id}, @own)

    on_exit(fn ->
      if previous,
        do: :persistent_term.put({HalC2.Environment, :id}, previous),
        else: :persistent_term.erase({HalC2.Environment, :id})
    end)
  end

  property "settings are versioned, merged, notified in order and survive restart",
    numtests: HalC2.Prop.numtests(100),
    max_size: 40 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  property "writers racing on one version: one wins, nothing is lost",
    numtests: HalC2.Prop.numtests(100),
    max_size: 30 do
    forall cmds <- parallel_commands(__MODULE__.Parallel) do
      trap_exit do
        setup()
        {sequential, parallel, result} = run_parallel_commands(__MODULE__.Parallel, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, sequential, parallel, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # The file check is driven by hand (`check/0`), never by a timer.
  defp setup do
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    HalC2.Prop.scratch_home("settings")
    HalC2.Prop.start_services([Settings])
  end

  # --- model ------------------------------------------------------------------

  # file: what settings.json holds, a document or :garbage, and exists whether there is
  # one at all. pending: the documents a watcher has been sent and not yet drained,
  # newest first. records: the shared keys' records, a local stamp taken from the
  # clock as :local. held: the document could not be read at start, so members'
  # records wait. rules: what keybindings.json holds, and bound whether there is one.
  def initial_state,
    do: %{
      doc: %{},
      version: 0,
      file: %{},
      exists: false,
      watching: false,
      pending: [],
      parallel: false,
      records: %{},
      held: false,
      rules: [],
      bound: false
    }

  def command(state) do
    frequency(
      [
        {6, {:call, __MODULE__, :put_retry, [doc()]}},
        {3, {:call, __MODULE__, :put_stale, [stale_version(state), doc()]}},
        {2, {:call, __MODULE__, :put_invalid, [doc()]}},
        {3, {:call, __MODULE__, :merge, [doc()]}},
        {2, {:call, __MODULE__, :drop, [resize(3, list(field()))]}},
        {2, {:call, __MODULE__, :update_raises, []}},
        {4, {:call, __MODULE__, :read, []}}
      ] ++
        if state.parallel do
          []
        else
          [
            {2, {:call, __MODULE__, :external_edit, [doc(), boolean()]}},
            {1, {:call, __MODULE__, :external_garbage, [oneof(["{not json", "[]", "7", ""])]}},
            {2, {:call, __MODULE__, :saved, []}},
            {2, {:call, __MODULE__, :watch, []}},
            {1, {:call, __MODULE__, :unwatch, []}},
            {4, {:call, __MODULE__, :drain, []}},
            {2, {:call, __MODULE__, :restart, []}},
            {4, {:call, __MODULE__, :gossip, [incoming()]}},
            {2, {:call, __MODULE__, :records, []}},
            {2, {:call, __MODULE__, :bind, [rule_key()]}},
            {2, {:call, __MODULE__, :bind_racing, [rule_key(), incoming_rules()]}},
            {1, {:call, __MODULE__, :bind_unwritable, [rule_key()]}},
            {1, {:call, __MODULE__, :rules, []}}
          ]
        end
    )
  end

  # Versions only grow while a server runs, so -1 is stale whatever races with it.
  defp stale_version(%{parallel: true}), do: -1

  defp stale_version(%{version: version}),
    do: oneof([-1, version + 1, version + 7] ++ if(version > 0, do: [version - 1], else: []))

  # Documents sometimes carry the subagents choice, which `Settings.hal_c2_subagents?/0` reads.
  defp doc do
    let {entity, shared, choice} <-
          {resize(4, entity()), resize(2, map(oneof(@shared), shared_value())),
           oneof([:unset, "provider", "hal-c2"])} do
      doc = Map.merge(entity, shared)
      if choice == :unset, do: doc, else: Map.put(doc, "nativeSubagents", choice)
    end
  end

  defp shared_value, do: oneof(["x", "y", true])

  # What a member sends: a record per shared key, some of them resets, and sometimes
  # its keybinding rules.
  defp incoming do
    let {settings, rules} <- {incoming_settings(), oneof([%{}, incoming_rules()])},
        do: Map.merge(settings, rules)
  end

  defp incoming_settings do
    let pairs <-
          resize(
            3,
            list(
              {oneof(@shared), oneof([range(1, 3), range(@future, @future + 3)]),
               oneof(["mc-a", "mc-z"]), oneof([:unset, false, shared_value()])}
            )
          ) do
      Map.new(pairs, fn
        {key, at, by, :unset} -> {key, %{"at" => at, "by" => by}}
        {key, at, by, value} -> {key, %{"at" => at, "by" => by, "value" => value}}
      end)
    end
  end

  defp rule_key, do: oneof(["k", "j", "p"])
  defp rule(key), do: %{"key" => "mod+" <> key, "command" => "c"}

  # A member's keybinding rules, or their reset.
  defp incoming_rules do
    let {at, by, value} <-
          {oneof([range(1, 3), range(@future, @future + 3)]), oneof(["mc-a", "mc-z"]),
           oneof([:unset, list(rule_key())])} do
      case value do
        :unset -> %{"keybindings" => %{"at" => at, "by" => by}}
        keys -> %{"keybindings" => %{"at" => at, "by" => by, "value" => rules(keys)}}
      end
    end
  end

  # What `HalC2.Keybindings.upsert/1` makes of keys bound one after another.
  defp rules(keys), do: Enum.reduce(keys, [], &bound(&2, &1))
  defp bound(rules, key), do: Enum.reject(rules, &(&1 == rule(key))) ++ [rule(key)]

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :put_retry, [doc]}), do: accepted(state, doc)

  def next_state(state, _result, {:call, _, :merge, [patch]}),
    do: accepted(state, Map.merge(state.doc, patch))

  def next_state(state, _result, {:call, _, :drop, [keys]}),
    do: accepted(state, Map.drop(state.doc, keys))

  def next_state(state, _result, {:call, _, :external_edit, [doc, _in_place?]}) do
    if doc == state.doc and not state.held do
      %{state | file: doc, exists: true}
    else
      state |> accepted(doc) |> Map.put(:file, doc)
    end
  end

  def next_state(state, _result, {:call, _, :external_garbage, [text]}) do
    case JSON.decode(text) do
      {:ok, %{}} -> state
      _ -> %{state | file: :garbage, exists: true}
    end
  end

  def next_state(%{held: true} = state, _result, {:call, _, :gossip, _}), do: state
  def next_state(state, _result, {:call, _, :gossip, [incoming]}), do: gossiped(state, incoming)

  def next_state(state, _result, {:call, _, :bind, [key]}), do: bound_rules(state, key)

  # The member's rules are taken up first, and the edit is made on whatever they leave.
  def next_state(%{held: true} = state, _result, {:call, _, :bind_racing, [key, _incoming]}),
    do: bound_rules(state, key)

  def next_state(state, _result, {:call, _, :bind_racing, [key, incoming]}),
    do: state |> gossiped(incoming) |> bound_rules(key)

  def next_state(state, _result, {:call, _, :watch, []}), do: %{state | watching: true}
  def next_state(state, _result, {:call, _, :unwatch, []}), do: %{state | watching: false}
  def next_state(state, _result, {:call, _, :drain, []}), do: %{state | pending: []}

  # Records outlive a restart, unless their file is gone: then the machine learns them
  # from the members again. A document that cannot be read is stood in for by the shared
  # keys' records.
  def next_state(state, _result, {:call, _, :restart, []}) do
    records = if state.exists, do: state.records, else: Map.take(state.records, ["keybindings"])
    records = if state.bound, do: records, else: Map.delete(records, "keybindings")

    doc =
      if state.file == :garbage,
        do:
          for(
            {key, %{"value" => value}} <- Map.take(records, @shared),
            into: %{},
            do: {key, value}
          ),
        else: state.file

    %{
      state
      | doc: doc,
        version: 0,
        watching: false,
        held: state.file == :garbage,
        records: records
    }
  end

  def next_state(state, _result, _call), do: state

  # A member's records taken up: the newer ones win, the document takes their keys,
  # and the rules file their rules.
  defp gossiped(state, incoming) do
    # No rules arrive as an unset, as this MC records them.
    incoming =
      Map.new(incoming, fn
        {"keybindings", %{"value" => []} = record} -> {"keybindings", Map.delete(record, "value")}
        other -> other
      end)

    records =
      Map.merge(state.records, incoming, fn _key, ours, theirs ->
        if order(theirs) > order(ours), do: theirs, else: ours
      end)

    doc =
      Enum.reduce(Map.take(records, @shared), state.doc, fn
        {key, %{"value" => value}}, doc -> Map.put(doc, key, value)
        {key, _reset}, doc -> Map.delete(doc, key)
      end)

    rules = (records["keybindings"] || %{})["value"] || []

    state =
      if records["keybindings"] == state.records["keybindings"] or rules == state.rules,
        do: state,
        else: %{state | rules: rules, bound: true}

    state = %{state | records: records}
    if doc == state.doc, do: state, else: accepted(state, doc)
  end

  defp bound_rules(state, key) do
    rules = bound(state.rules, key)
    values = if rules == [], do: %{}, else: %{"keybindings" => rules}
    %{state | rules: rules, bound: true, records: stamp(state.records, values, ["keybindings"])}
  end

  # A change that was accepted: the document, the file, the version, the watcher's mail,
  # and a stamp on every shared key whose value is not the one its record holds.
  defp accepted(state, doc) do
    %{
      state
      | doc: doc,
        file: doc,
        exists: true,
        held: false,
        version: state.version + 1,
        pending: if(state.watching, do: [doc | state.pending], else: state.pending),
        records: stamp(state.records, doc, @shared)
    }
  end

  defp stamp(records, values, units) do
    # After the latest time held when that is a member's clock running ahead.
    at =
      case for(%{"at" => at} when is_integer(at) and at >= @future <- Map.values(records), do: at) do
        [] -> :local
        ahead -> Enum.max(ahead) + 1
      end

    Enum.reduce(units, records, fn key, acc ->
      held = Map.fetch(acc[key] || %{}, "value")

      case Map.fetch(values, key) do
        ^held -> acc
        {:ok, value} -> Map.put(acc, key, %{"at" => at, "by" => @own, "value" => value})
        :error -> Map.put(acc, key, %{"at" => at, "by" => @own})
      end
    end)
  end

  # A clock behind this MC's, this MC's, a clock ahead; then the writer; then the rest.
  defp order(%{"at" => :local} = record), do: {1, 0, record["by"], record}
  defp order(%{"at" => at} = record) when at >= @future, do: {2, at, record["by"], record}
  defp order(%{"at" => at} = record), do: {0, at, record["by"], record}

  def postcondition(state, {:call, _, :put_retry, _}, result),
    do: result == {:ok, state.version + 1}

  def postcondition(state, {:call, _, op, _}, result) when op in [:merge, :drop],
    do: result == {:ok, state.version + 1}

  def postcondition(_state, {:call, _, :put_stale, _}, result),
    do: result == {:error, :stale}

  def postcondition(_state, {:call, _, :put_invalid, _}, result),
    do: match?({:error, %{"_tag" => "ServerSettingsError"}}, result)

  # The server survives a function that raises, and keeps the document as it was.
  def postcondition(_state, {:call, _, :update_raises, _}, result),
    do: match?({:error, _}, result)

  # Likewise a rules file it cannot write, and keeps the rules and their record.
  def postcondition(_state, {:call, _, :bind_unwritable, _}, result),
    do: match?({:error, _}, result)

  # `settings/0` reads the table a second time, and so does `hal_c2_subagents?/0`, so a
  # racing writer can land in between.
  def postcondition(
        state,
        {:call, _, :read, _},
        {{doc, version}, via_settings, alive?, hal_c2_subagents?}
      ) do
    alive? and doc == state.doc and version == state.version and
      (state.parallel or
         (via_settings == state.doc and
            hal_c2_subagents? == (state.doc["nativeSubagents"] == "hal-c2")))
  end

  def postcondition(state, {:call, _, :saved, _}, result) do
    case state.file do
      :garbage -> match?({:error, _}, result)
      file -> result == {:ok, file}
    end
  end

  def postcondition(state, {:call, _, :rules, _}, result), do: result == state.rules

  def postcondition(state, {:call, _, :drain, _}, result),
    do: result == Enum.reverse(state.pending)

  # A local stamp is this MC's clock: only its writer and value are known.
  def postcondition(state, {:call, _, :records, _}, result) do
    Map.keys(result) == Map.keys(state.records) and
      Enum.all?(state.records, fn
        {key, %{"at" => :local} = record} ->
          %{"at" => at, "by" => by} = result[key]

          is_integer(at) and at < @future and by == @own and
            Map.fetch(result[key], "value") == Map.fetch(record, "value")

        {key, record} ->
          result[key] == record
      end)
  end

  def postcondition(_state, _call, result), do: result in [:ok, true]

  # --- system under test --------------------------------------------------------

  # What a client does: validate, then put with the version it read.
  defp write(doc, version),
    do: HalC2.Rpc.handle("hal-c2.writeSettings", %{"settings" => doc, "version" => version})

  # A writer that reads the version and writes, again if another writer got in between.
  def put_retry(doc) do
    {_, version} = Settings.get()

    case write(doc, version) do
      {:ok, %{"version" => version}} -> {:ok, version}
      {:error, %{"_tag" => "StaleSettings"}} -> put_retry(doc)
    end
  end

  def put_stale(version, doc) do
    case write(doc, version) do
      {:error, %{"_tag" => "StaleSettings"}} -> {:error, :stale}
      other -> other
    end
  end

  # A provider variable name no shell accepts.
  def put_invalid(doc) do
    {_, version} = Settings.get()

    bad = %{
      "providerInstances" => %{
        "p" => %{
          "environment" => [%{"name" => Enum.random(["1x", "a b", "a-b"]), "value" => "v"}]
        }
      }
    }

    write(Map.merge(doc, bad), version)
  end

  def merge(patch), do: Settings.update(&Map.merge(&1, patch))
  def drop(keys), do: Settings.update(&Map.drop(&1, keys))

  def update_raises do
    Settings.update(fn _ -> raise "boom" end)
  catch
    :exit, reason -> {:exit, reason}
  end

  def read do
    server = Process.whereis(Settings)

    {Settings.get(), Settings.settings(), is_pid(server) and Process.alive?(server),
     Settings.hal_c2_subagents?()}
  end

  def saved, do: Settings.saved()

  # What `mix hal_c2.theme` does beside a live MC, replacing the file atomically, or
  # an editor that writes over it in place.
  def external_edit(doc, in_place?) do
    write_file(JSON.encode!(doc), in_place?)
    check()
  end

  def external_garbage(text) do
    write_file(text, false)
    check()
  end

  defp write_file(text, in_place?) do
    path = Path.join(HalC2.Paths.config_dir(), "settings.json")
    File.mkdir_p!(Path.dirname(path))

    if in_place? do
      File.write!(path, text)
    else
      File.write!(path <> ".ext", text)
      File.rename!(path <> ".ext", path)
    end
  end

  # The file check, run now and waited for: a call after it is handled after it.
  defp check do
    send(Settings, :check)
    :sys.get_state(Settings)
    :ok
  end

  def watch, do: Settings.watch(self())

  def unwatch do
    Settings.unwatch(self())
    :sys.get_state(Settings)
    :ok
  end

  def drain, do: drain([])

  defp drain(acc) do
    receive do
      {:hal_c2_settings, _node, settings} -> drain([settings | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def restart, do: HalC2.Prop.restart_service(Settings)

  # What `HalC2.Cluster` hands on from a member, waited for.
  def gossip(records) do
    Settings.merge_shared(records)
    :sys.get_state(Settings)
    :ok
  end

  def records, do: Settings.shared_records()

  def bind(key) do
    {:ok, _} = HalC2.Keybindings.upsert(rule(key))
    :sys.get_state(Settings)
    :ok
  end

  # A member's rules reach the server just ahead of a client's edit.
  def bind_racing(key, incoming) do
    :ok = :sys.suspend(Settings)
    Settings.merge_shared(incoming)
    edit = Task.async(fn -> HalC2.Keybindings.upsert(rule(key)) end)
    :ok = :sys.resume(Settings)
    {:ok, _} = Task.await(edit)
    :ok
  end

  # A client's edit when the rules cannot be written: `<path>.tmp` is a directory.
  def bind_unwritable(key) do
    tmp = HalC2.Keybindings.path() <> ".tmp"
    File.mkdir_p!(tmp)
    HalC2.Keybindings.upsert(rule(key))
  after
    File.rm_rf!(HalC2.Keybindings.path() <> ".tmp")
  end

  def rules, do: HalC2.Keybindings.rules()

  defmodule Parallel do
    @moduledoc false
    # The same model with the commands that race: no restarts, no mailbox.
    alias HalC2.SettingsPropTest, as: Model

    def initial_state, do: %{Model.initial_state() | parallel: true}

    defdelegate command(state), to: Model
    defdelegate precondition(state, call), to: Model
    defdelegate next_state(state, result, call), to: Model
    defdelegate postcondition(state, call, result), to: Model
  end
end
