defmodule HalC2.SettingsPropTest do
  @moduledoc """
  `HalC2.Settings` against a model of its document: the settings, the version the
  next `put/2` must name, what settings.json holds, and the notifications a watcher
  is owed. Commands write through the RPC a client uses (validate, then a versioned
  put), merge and drop keys with `update/1`, edit the file from outside as
  `mix hal_c2.theme` does, break it, and restart the server, which must keep the
  document but starts counting versions again. A second property races writers on
  one version.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  import HalC2.Prop.Generators

  alias HalC2.Settings

  @moduletag timeout: :infinity

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
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, [sequential, parallel], :parallel, result)))
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

  # file: what settings.json holds, a document or :garbage. pending: the documents a
  # watcher has been sent and not yet drained, newest first.
  def initial_state,
    do: %{doc: %{}, version: 0, file: %{}, watching: false, pending: [], parallel: false}

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
            {2, {:call, __MODULE__, :external_edit, [doc()]}},
            {1, {:call, __MODULE__, :external_garbage, [oneof(["{not json", "[]", "7", ""])]}},
            {2, {:call, __MODULE__, :saved, []}},
            {2, {:call, __MODULE__, :watch, []}},
            {1, {:call, __MODULE__, :unwatch, []}},
            {4, {:call, __MODULE__, :drain, []}},
            {2, {:call, __MODULE__, :restart, []}}
          ]
        end
    )
  end

  # Versions only grow while a server runs, so -1 is stale whatever races with it.
  defp stale_version(%{parallel: true}), do: -1

  defp stale_version(%{version: version}),
    do: oneof([-1, version + 1, version + 7] ++ if(version > 0, do: [version - 1], else: []))

  defp doc, do: resize(4, entity())

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :put_retry, [doc]}), do: accepted(state, doc)

  def next_state(state, _result, {:call, _, :merge, [patch]}),
    do: accepted(state, Map.merge(state.doc, patch))

  def next_state(state, _result, {:call, _, :drop, [keys]}),
    do: accepted(state, Map.drop(state.doc, keys))

  def next_state(state, _result, {:call, _, :external_edit, [doc]}) do
    if doc == state.doc do
      %{state | file: doc}
    else
      state |> accepted(doc) |> Map.put(:file, doc)
    end
  end

  def next_state(state, _result, {:call, _, :external_garbage, [text]}) do
    case JSON.decode(text) do
      {:ok, %{}} -> state
      _ -> %{state | file: :garbage}
    end
  end

  def next_state(state, _result, {:call, _, :watch, []}), do: %{state | watching: true}
  def next_state(state, _result, {:call, _, :unwatch, []}), do: %{state | watching: false}
  def next_state(state, _result, {:call, _, :drain, []}), do: %{state | pending: []}

  def next_state(state, _result, {:call, _, :restart, []}) do
    doc = if state.file == :garbage, do: %{}, else: state.file
    %{state | doc: doc, version: 0, watching: false}
  end

  def next_state(state, _result, _call), do: state

  # A change that was accepted: the document, the file, the version, and the watcher's mail.
  defp accepted(state, doc) do
    %{
      state
      | doc: doc,
        file: doc,
        version: state.version + 1,
        pending: if(state.watching, do: [doc | state.pending], else: state.pending)
    }
  end

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

  def postcondition(state, {:call, _, :read, _}, {{doc, version}, via_settings, alive?}),
    do: alive? and doc == state.doc and via_settings == state.doc and version == state.version

  def postcondition(state, {:call, _, :saved, _}, result) do
    case state.file do
      :garbage -> match?({:error, _}, result)
      file -> result == {:ok, file}
    end
  end

  def postcondition(state, {:call, _, :drain, _}, result),
    do: result == Enum.reverse(state.pending)

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
    {Settings.get(), Settings.settings(), is_pid(server) and Process.alive?(server)}
  end

  def saved, do: Settings.saved()

  # What `mix hal_c2.theme` does beside a live MC: replace the file, atomically.
  def external_edit(doc) do
    write_file(JSON.encode!(doc))
    check()
  end

  def external_garbage(text) do
    write_file(text)
    check()
  end

  defp write_file(text) do
    path = Path.join(HalC2.Paths.config_dir(), "settings.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".ext", text)
    File.rename!(path <> ".ext", path)
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
