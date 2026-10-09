defmodule HalC2.PluginsPropTest do
  @moduledoc """
  `HalC2.Plugins`, the plugin host, against a model of what it holds: the packages on
  disk, the version of each it loaded (compiled, waiting to compile, or refused), what
  runs, the settings document's `plugins.<id>` (enabled, granted, settings) and the
  secret store, and the topics clients follow.

  Commands write packages (good ones, new versions, ones whose manifest is broken or
  whose code does not compile, updates that ask for more or fewer permissions), rescan,
  enable with whatever a client sends as accepted permissions, disable, restart, save
  settings, call the running plugin, read its files, follow, publish and drop topics,
  kill a client, crash a plugin's process once or until its supervisor gives up, crash
  a worker announced the way a host from before an update in place heard of them, and
  kill the host itself. After every step the listing, the document, the code that is
  loaded and running, what the packages' code did at compile time, and the host's
  monitors must agree with the model.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Plugins
  alias __MODULE__.{Client, Packages}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @ids ["alpha", "beta", "Gamma"]
  @code_ids ["alpha", "beta"]
  @marker "••••••"
  @defaults %{"count" => 1, "mode" => "a", "tags" => []}
  @valid [:ok, :ui, :compile_error, :two_modules, :second_broken]

  setup do
    saved =
      for key <- [:bundled_plugins, :settings_check_ms],
          do: {key, Application.fetch_env(:hal_c2, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:hal_c2, key, value)
          :error -> Application.delete_env(:hal_c2, key)
        end
      end
    end)
  end

  property "the plugin host loads, runs, refuses and restores packages as the model says",
    numtests: HalC2.Prop.numtests(100),
    max_size: 60 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        problems = Process.get({__MODULE__, :problems})
        stop()

        (result == :ok)
        |> when_fail(
          IO.puts("""
          #{HalC2.Prop.report(cmds, history, state, result)}
          Mismatches:
          #{inspect(problems, pretty: true, limit: :infinity)}
          """)
        )
        |> aggregate(command_names(cmds))
      end
    end
  end

  # The file check of the settings document is driven by nobody: the host is the only writer.
  defp start do
    Process.delete({__MODULE__, :problems})
    Application.put_env(:hal_c2, :settings_check_ms, nil)
    Application.put_env(:hal_c2, :bundled_plugins, [])
    home = HalC2.Prop.scratch_home("plugins")
    File.write!(Path.join(home, "outside.txt"), "outside every package")
    File.mkdir_p!(plugins_dir())
    Process.put({__MODULE__, :marks}, {Path.join(home, "marks.log"), 0})
    HalC2.Prop.start_services([HalC2.Settings, Plugins])
    sync()
    Process.put({__MODULE__, :clients}, %{0 => Client.start(), 1 => Client.start()})
  end

  defp stop do
    for {_, pid} <- Process.delete({__MODULE__, :clients}) || %{}, do: Process.exit(pid, :kill)
    HalC2.Prop.stop_services()
  end

  # --- model ------------------------------------------------------------------

  # disk: the package each directory holds, `{variant, version, permissions}`.
  # held: what the host holds for each id (`entry/2`). config: `plugins.<id>` of the
  # settings document, with the secret the store holds. accepted: every permission a
  # client accepted for an id. last: what each topic last carried; subs and inbox:
  # what each client follows and has been sent.
  def initial_state,
    do: %{
      disk: %{},
      held: %{},
      config: %{},
      accepted: %{},
      last: %{},
      subs: %{0 => MapSet.new(), 1 => MapSet.new()},
      inbox: %{0 => [], 1 => []}
    }

  def command(state) do
    workers =
      for {id, %{running: true, desc: {:ok, _, _}, st: :compiled}} <- state.held, do: id

    held = held_id(state)

    frequency(
      [
        {2, {:call, __MODULE__, :write, [id(), desc()]}},
        {5, {:call, __MODULE__, :install, [id(), desc()]}},
        {1, {:call, __MODULE__, :remove, [id()]}},
        {4, {:call, __MODULE__, :rescan, []}},
        {6, let(id <- held, do: {:call, __MODULE__, :enable, [id, consent(state, id)]})},
        {2, {:call, __MODULE__, :disable, [held]}},
        {1, {:call, __MODULE__, :restart, [held]}},
        {3, {:call, __MODULE__, :save_settings, [held, settings_input()]}},
        {3, {:call, __MODULE__, :call_plugin, [held]}},
        {2, {:call, __MODULE__, :file, [held, path()]}},
        {2, {:call, __MODULE__, :subscribe, [client(), topic_id(), topic()]}},
        {1, {:call, __MODULE__, :unsubscribe, [client(), topic_id(), topic()]}},
        {2, {:call, __MODULE__, :publish, [topic_id(), topic(), integer(1, 9)]}},
        {2, {:call, __MODULE__, :inbox, [client()]}},
        {1, {:call, __MODULE__, :kill_client, [client()]}},
        {1, {:call, __MODULE__, :kill_plugins, []}},
        {1, {:call, __MODULE__, :stale_worker, [held]}}
      ] ++
        if workers == [] do
          []
        else
          [
            {2, {:call, __MODULE__, :crash, [oneof(workers)]}},
            {1, {:call, __MODULE__, :crash_hard, [oneof(workers)]}}
          ]
        end
    )
  end

  defp id, do: frequency([{5, "alpha"}, {4, "beta"}, {1, "Gamma"}])

  # Mostly an id the host holds, so the commands that need one reach it.
  defp held_id(%{held: held}) when held == %{}, do: id()
  defp held_id(%{held: held}), do: frequency([{4, oneof(Map.keys(held))}, {1, id()}])

  # Mostly what the held version asks for, sometimes anything a client might send.
  defp consent(state, id) do
    case state.held[id] do
      nil -> accepted()
      e -> frequency([{4, perms(e)}, {1, accepted()}])
    end
  end

  defp topic_id, do: oneof(@code_ids)
  defp topic, do: oneof(["t1", "t2"])
  defp client, do: oneof([0, 1])

  defp desc do
    let [
      variant <-
        frequency([
          {8, :ok},
          {2, :ui},
          {1, :bad_json},
          {1, :wrong_shape},
          {1, :escape},
          {1, :bad_default},
          {1, :id_mismatch},
          {1, :compile_error},
          {1, :two_modules},
          {1, :second_broken}
        ]),
      version <- oneof(["1", "2"]),
      permissions <-
        oneof([[], ["projects:read"], ["threads:read"], ["projects:read", "threads:read"]])
    ] do
      {variant, version, permissions}
    end
  end

  # What a client sends as `acceptPermissions`; nil sends none.
  defp accepted,
    do:
      oneof([
        nil,
        [],
        ["projects:read"],
        ["threads:read"],
        ["projects:read", "threads:read"],
        "projects:read",
        [1]
      ])

  defp settings_input do
    let pairs <-
          resize(
            4,
            list(
              oneof([
                {"count", oneof([5, 500, "x", @marker, nil])},
                {"mode", oneof(["a", "b", "c", "z", @marker, nil])},
                {"token", oneof(["s1", "s2", "", @marker, nil, 3])},
                {"tags", oneof([["t"], [1], [], nil])},
                {"extra", 1}
              ])
            )
          ) do
      Map.new(pairs)
    end
  end

  defp path,
    do:
      oneof([
        "ui/main.qml",
        "icon.svg",
        "inner.txt",
        "ui/../icon.svg",
        "link.txt",
        "../../outside.txt",
        "/etc/hostname",
        "missing.txt"
      ])

  def precondition(state, {:call, _, op, [id]}) when op in [:crash, :crash_hard] do
    case state.held[id] do
      %{running: true, st: :compiled, desc: {:ok, _, _}, crashes: crashes} ->
        op == :crash_hard or crashes < 3

      _ ->
        false
    end
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, call), do: state |> step(call) |> elem(0)

  # The step's reply must be the one the model expects, and what the host holds
  # afterwards the model's next state.
  def postcondition(state, call, {reply, observed}) do
    {next, expect} = step(state, call)
    problems = reply_problems(expect, reply) ++ problems(next, observed)

    if problems != [], do: Process.put({__MODULE__, :problems}, problems)
    problems == []
  end

  # `{next state, the reply expected}`.
  defp step(s, {:call, _, :write, [id, desc]}), do: {put_in(s.disk[id], desc), :ok}
  defp step(s, {:call, _, :remove, [id]}), do: {%{s | disk: Map.delete(s.disk, id)}, :ok}
  defp step(s, {:call, _, :rescan, []}), do: {scan(s), :ok}
  defp step(s, {:call, _, :install, [id, desc]}), do: {scan(put_in(s.disk[id], desc)), :ok}

  # A restarted host remembers nothing it held, only the document and the disk.
  defp step(s, {:call, _, :kill_plugins, []}), do: {scan(%{s | held: %{}}), :ok}

  defp step(s, {:call, _, :enable, [id, accepted]}) do
    cond do
      not (is_nil(accepted) or (is_list(accepted) and Enum.all?(accepted, &is_binary/1))) ->
        {s, :error_text}

      s.held[id] == nil ->
        {s, {:tag, "PluginNotFound"}}

      s.held[id].st in [:error_code, :error_manifest] ->
        {s, {:tag, "PluginUnavailable"}}

      (missing = perms(s.held[id]) -- (conf(s, id).granted ++ (accepted || []))) != [] ->
        {s, {:consent, missing}}

      true ->
        e = s.held[id]

        s =
          s
          |> put_conf(id, &%{&1 | enabled: true, granted: perms(e)})
          |> update_in(
            [:accepted],
            &Map.update(&1, id, accepted || [], fn a -> a ++ (accepted || []) end)
          )
          |> put_in([:held, id], %{e | failed: false})
          |> reconcile()

        if s.held[id].st == :error_code,
          do: {s, {:tag, "PluginUnavailable"}},
          else: {s, :ok}
    end
  end

  defp step(s, {:call, _, :disable, [id]}) do
    case s.held[id] do
      nil ->
        {s, {:tag, "PluginNotFound"}}

      e ->
        s =
          s |> put_conf(id, &%{&1 | enabled: false}) |> put_in([:held, id], %{e | failed: false})

        {reconcile(s), :ok}
    end
  end

  defp step(s, {:call, _, :restart, [id]}) do
    case s.held[id] do
      nil ->
        {s, {:tag, "PluginNotFound"}}

      e ->
        if runnable?(s, id, e) do
          {s
           |> put_in([:held, id], %{e | running: false, failed: false, crashes: 0})
           |> reconcile(), :ok}
        else
          {s, :error_text}
        end
    end
  end

  defp step(s, {:call, _, :save_settings, [id, input]}) do
    case s.held[id] do
      nil -> {s, {:tag, "PluginNotFound"}}
      e -> save(s, id, e, input)
    end
  end

  defp step(s, {:call, _, :call_plugin, [id]}) do
    case s.held[id] do
      nil ->
        {s, {:tag, "PluginNotFound"}}

      %{running: false} ->
        {s, {:tag, "PluginNotRunning"}}

      %{desc: {:ui, _, _}} ->
        {s, {:tag, "PluginCallFailed"}}

      e ->
        settings = effective(conf(s, id))

        {s,
         {:exactly,
          {:ok, %{"version" => version(e), "settings" => settings, "worker" => settings}}}}
    end
  end

  defp step(s, {:call, _, :file, [id, path]}) do
    case s.held[id] do
      nil ->
        {s, {:tag, "PluginNotFound"}}

      e ->
        # A package shows its icon while it is off; the rest only while it runs.
        shown = e.st != :error_manifest and path == "icon.svg"

        if e.running or shown,
          do: {s, served(id, version(e), path)},
          else: {s, {:tag, "PluginNotRunning"}}
    end
  end

  defp step(s, {:call, _, :subscribe, [c, id, topic]}),
    do:
      {update_in(s.subs[c], &MapSet.put(&1, {id, topic})), {:exactly, {:ok, s.last[{id, topic}]}}}

  defp step(s, {:call, _, :unsubscribe, [c, id, topic]}),
    do: {update_in(s.subs[c], &MapSet.delete(&1, {id, topic})), :ok}

  defp step(s, {:call, _, :publish, [id, topic, value]}) do
    inbox =
      Map.new(s.inbox, fn {c, messages} ->
        if MapSet.member?(s.subs[c], {id, topic}),
          do: {c, messages ++ [{id, topic, value}]},
          else: {c, messages}
      end)

    {%{s | last: Map.put(s.last, {id, topic}, value), inbox: inbox}, :ok}
  end

  defp step(s, {:call, _, :inbox, [c]}),
    do: {put_in(s.inbox[c], []), {:exactly, s.inbox[c]}}

  defp step(s, {:call, _, :kill_client, [c]}),
    do: {%{s | subs: Map.put(s.subs, c, MapSet.new()), inbox: Map.put(s.inbox, c, [])}, :ok}

  defp step(s, {:call, _, :crash, [id]}) do
    e = s.held[id]

    {put_in(s.held[id], %{e | crashes: e.crashes + 1, restarts: e.restarts && e.restarts + 1}),
     :ok}
  end

  # A worker of the running supervisor, if there is one, is charged to the plugin; with
  # none it is no one's.
  defp step(s, {:call, _, :stale_worker, [id]}) do
    case s.held[id] do
      %{running: true} = e ->
        {put_in(s.held[id], %{e | restarts: e.restarts && e.restarts + 1}), :ok}

      _ ->
        {s, :ok}
    end
  end

  # Killed until its supervisor gives up: how many kills that took is not known.
  defp step(s, {:call, _, :crash_hard, [id]}) do
    e = s.held[id]
    {put_in(s.held[id], %{e | running: false, failed: true, crashes: 0, restarts: nil}), :ok}
  end

  # A version of a package as the host holds it. st: :compiled (its code loaded, or a
  # package of UI parts only), :uncompiled (waits for the user to let it run),
  # :error_code (its code did not load) or :error_manifest (its manifest is refused).
  defp entry(desc, st),
    do: %{
      desc: desc,
      st: st,
      running: false,
      failed: false,
      reload_error: false,
      crashes: 0,
      restarts: 0
    }

  defp valid?(id, {variant, _, _}), do: id != "Gamma" and variant in @valid
  defp code?({variant, _, _}), do: variant != :ui
  defp compiles?({variant, _, _}), do: variant in [:ok, :ui]

  defp perms(%{st: :error_manifest}), do: []
  defp perms(%{desc: {_, _, permissions}}), do: permissions
  defp version(%{st: :error_manifest}), do: nil
  defp version(%{desc: {_, version, _}}), do: version

  defp conf(s, id),
    do: Map.get(s.config, id, %{enabled: nil, granted: [], stored: %{}, secret: nil})

  defp put_conf(s, id, fun), do: put_in(s.config[id], fun.(conf(s, id)))

  defp runnable?(s, id, e),
    do:
      e.st in [:compiled, :uncompiled] and conf(s, id).enabled == true and
        perms(e) -- conf(s, id).granted == []

  # The packages on disk as a scan loads them, then what is enabled started.
  defp scan(s) do
    held = Map.new(s.disk, fn {id, desc} -> {id, load(s, id, s.held[id], desc)} end)

    # A version that stops asking for a permission gives it up.
    s =
      Enum.reduce(held, s, fn {id, e}, s ->
        if e.st in [:compiled, :uncompiled],
          do:
            put_conf(s, id, fn c -> %{c | granted: Enum.filter(c.granted, &(&1 in perms(e)))} end),
          else: s
      end)

    reconcile(%{s | held: held})
  end

  defp load(s, id, held, desc) do
    cond do
      held != nil and held.desc == desc ->
        if valid?(id, desc), do: %{held | reload_error: false}, else: held

      valid?(id, desc) ->
        new = entry(desc, if(code?(desc), do: :uncompiled, else: :compiled))

        cond do
          not runnable?(s, id, new) -> new
          compiles?(desc) -> %{new | st: :compiled}
          true -> keep(held, %{new | st: :error_code})
        end

      true ->
        keep(held, entry(desc, :error_manifest))
    end
  end

  # A version that does not load leaves the one that did as it was.
  defp keep(%{st: :compiled} = held, _refused), do: %{held | reload_error: true}
  defp keep(_held, refused), do: refused

  # Starts what is enabled and stopped (unless it failed), stops what is not enabled.
  defp reconcile(s) do
    Enum.reduce(s.held, s, fn {id, e}, s ->
      cond do
        e.running and not runnable?(s, id, e) ->
          put_in(s.held[id], %{e | running: false, crashes: 0})

        not e.running and not e.failed and runnable?(s, id, e) ->
          start(s, id, e)

        true ->
          s
      end
    end)
  end

  defp start(s, id, %{st: :uncompiled} = e) do
    if compiles?(e.desc),
      do: start(s, id, %{e | st: :compiled}),
      else: put_in(s.held[id], %{e | st: :error_code})
  end

  defp start(s, id, e), do: put_in(s.held[id], %{e | running: true, failed: false, crashes: 0})

  defp save(s, id, e, input) do
    c = conf(s, id)
    keys = if e.st == :error_manifest, do: [], else: ["count", "mode", "token", "tags"]
    input = Map.take(input, keys)

    # The marker in a secret field keeps what the store holds.
    input =
      if input["token"] == @marker, do: Map.put(input, "token", c.stored["token"]), else: input

    next = c.stored |> Map.merge(input) |> Map.reject(fn {_, value} -> value == nil end)
    module? = e.st == :compiled and code?(e.desc)

    cond do
      Enum.any?(input, fn {key, value} -> value != nil and not typed?(key, value) end) ->
        {s, {:tag, "PluginSettingsInvalid"}}

      module? and Map.get(next, "count", 1) > 100 ->
        {s, {:tag, "PluginSettingsInvalid"}}

      true ->
        {stored, secret} =
          case next["token"] do
            @marker ->
              {next, c.secret}

            token when is_binary(token) and token != "" ->
              {Map.put(next, "token", @marker), token}

            _ ->
              {Map.delete(next, "token"), nil}
          end

        s = put_conf(s, id, &%{&1 | stored: stored, secret: secret})

        s =
          if e.running,
            do: s |> put_in([:held, id], %{e | running: false, crashes: 0}) |> reconcile(),
            else: s

        {s, :ok}
    end
  end

  defp typed?("count", value), do: is_number(value)
  defp typed?("mode", value), do: value in ["a", "b"]
  defp typed?("token", value), do: is_binary(value)
  defp typed?("tags", value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  # The settings a plugin runs with: defaults, then what was saved, the secret revealed.
  defp effective(c) do
    stored =
      if c.stored["token"] == @marker, do: Map.put(c.stored, "token", c.secret), else: c.stored

    Map.merge(@defaults, stored)
  end

  defp served(id, version, path) when path in ["ui/main.qml", "inner.txt"],
    do: {:file, Packages.main(id, version)}

  defp served(id, version, path) when path in ["icon.svg", "ui/../icon.svg"],
    do: {:file, Packages.icon(id, version)}

  defp served(_id, _version, _path), do: {:tag, "PluginFileNotFound"}

  # --- checks -------------------------------------------------------------------

  defp reply_problems(:ok, :ok), do: []
  defp reply_problems(:ok, {:ok, _}), do: []
  defp reply_problems({:tag, tag}, {:error, %{"_tag" => tag}}), do: []
  defp reply_problems(:error_text, {:error, message}) when is_binary(message), do: []

  defp reply_problems(
         {:consent, missing},
         {:error, %{"_tag" => "PluginConsentRequired", "permissions" => missing}}
       ),
       do: []

  defp reply_problems({:exactly, value}, value), do: []
  defp reply_problems({:file, content}, {:ok, %{"content" => content}}), do: []
  defp reply_problems(expect, reply), do: [{:reply, expect, reply}]

  defp problems(s, observed) do
    []
    |> check(:list, listing(s), restarts_known(observed.list, s))
    |> check(:config, Map.new(@ids, &{&1, model_config(s, &1)}), observed.config)
    |> check(
      :code,
      Map.new(@code_ids, &{&1, model_code(s, &1, observed.code[&1])}),
      observed.code
    )
    |> check(:monitors, monitors(s), observed.monitors)
    |> check(
      :granted_was_accepted,
      [],
      for(id <- @ids, p <- conf(s, id).granted, p not in Map.get(s.accepted, id, []), do: {id, p})
    )
    |> check(
      :granted_is_declared,
      [],
      for(
        {id, %{st: st} = e} <- s.held,
        st in [:compiled, :uncompiled],
        p <- observed.config[id].granted,
        p not in perms(e),
        do: {id, p}
      )
    )
    |> check(
      :settings_fit_the_manifest,
      [],
      for(
        {id, c} <- observed.config,
        {key, value} <- c.stored,
        not (key == "token" and value == @marker) and
          not (key in ["count", "mode", "tags"] and typed?(key, value)),
        do: {id, key, value}
      )
    )
    |> check(
      :compiled_only_when_enabled,
      [],
      for({id, _version} <- observed.marks, conf(s, id).enabled != true, do: id)
    )
  end

  defp check(problems, _label, same, same), do: problems
  defp check(problems, label, expected, actual), do: problems ++ [{label, expected, actual}]

  defp listing(s) do
    for {id, e} <- Enum.sort(s.held) do
      c = conf(s, id)

      status =
        cond do
          e.st in [:error_code, :error_manifest] -> "error"
          e.running -> "running"
          e.failed -> "failed"
          c.enabled == true and perms(e) -- c.granted != [] -> "awaitingConsent"
          true -> "disabled"
        end

      %{
        "id" => id,
        "version" => version(e),
        "enabled" => c.enabled == true,
        "status" => status,
        "error" => e.st in [:error_code, :error_manifest],
        "reloadError" => e.reload_error,
        "permissions" => for(p <- perms(e), do: {p, p in c.granted}),
        "settings" =>
          if(e.st == :error_manifest, do: c.stored, else: Map.merge(@defaults, c.stored)),
        "restarts" => e.restarts
      }
    end
  end

  defp restarts_known(list, s) do
    for entry <- list do
      if s.held[entry["id"]] && s.held[entry["id"]].restarts == nil,
        do: %{entry | "restarts" => nil},
        else: entry
    end
  end

  defp model_config(s, id), do: Map.take(conf(s, id), [:enabled, :granted, :stored, :secret])

  # The version whose code is loaded matters only for a compiled package with code;
  # its process runs exactly while it does; no refused version's modules stay loaded.
  defp model_code(s, id, observed) do
    e = s.held[id]
    compiled? = match?(%{st: :compiled, desc: {:ok, _, _}}, e)

    %{
      loaded: if(compiled?, do: version(e), else: observed.loaded),
      worker: compiled? and e.running,
      extras: false
    }
  end

  defp monitors(s) do
    plugins =
      for {_, %{running: true} = e} <- s.held,
          do: if(e.st == :compiled and code?(e.desc), do: 2, else: 1)

    Enum.sum(plugins) + Enum.sum(for {_, subs} <- s.subs, do: MapSet.size(subs))
  end

  # --- system under test --------------------------------------------------------

  def write(id, desc) do
    put_package(id, desc)
    {:ok, observe()}
  end

  # A package written and the directory scanned, as a user installing one does.
  def install(id, desc) do
    put_package(id, desc)
    {Plugins.handle("rescan", %{}), observe()}
  end

  defp put_package(id, desc) do
    {marks, _seen} = Process.get({__MODULE__, :marks})
    Packages.write(Path.join(plugins_dir(), id), id, desc, marks)
  end

  def remove(id) do
    File.rm_rf!(Path.join(plugins_dir(), id))
    {:ok, observe()}
  end

  def rescan, do: {Plugins.handle("rescan", %{}), observe()}

  def enable(id, nil), do: {Plugins.handle("enable", %{"id" => id}), observe()}

  def enable(id, accepted),
    do: {Plugins.handle("enable", %{"id" => id, "acceptPermissions" => accepted}), observe()}

  def disable(id), do: {Plugins.handle("disable", %{"id" => id}), observe()}
  def restart(id), do: {Plugins.handle("restart", %{"id" => id}), observe()}

  def save_settings(id, input),
    do: {Plugins.handle("saveSettings", %{"id" => id, "settings" => input}), observe()}

  def call_plugin(id),
    do: {Plugins.handle("call", %{"id" => id, "method" => "about"}), observe()}

  def file(id, path), do: {Plugins.handle("file", %{"id" => id, "path" => path}), observe()}

  def subscribe(c, id, topic), do: {ask(c, {:subscribe, id, topic}), observe()}
  def unsubscribe(c, id, topic), do: {ask(c, {:unsubscribe, id, topic}), observe()}

  def publish(id, topic, value) do
    Plugins.publish(id, topic, value)
    {:ok, observe()}
  end

  def inbox(c) do
    sync()
    {ask(c, :inbox), observe()}
  end

  def kill_client(c) do
    clients = Process.get({__MODULE__, :clients})
    pid = clients[c]
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    Process.put({__MODULE__, :clients}, Map.put(clients, c, Client.start()))
    {:ok, observe()}
  end

  # The plugin's process is killed once; its supervisor starts it again.
  def crash(id) do
    worker = Process.whereis(plugin_module(id))
    sup = parent(worker)
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    :sys.get_state(sup)
    {:ok, observe()}
  end

  # A worker announced in the form a host from before an update in place took, queued
  # across the update, crashes.
  def stale_worker(id) do
    worker = spawn(fn -> receive do: (:never -> :ok) end)
    ref = Process.monitor(worker)
    GenServer.cast(Plugins, {:worker, id, worker})
    :sys.get_state(Plugins)
    Process.exit(worker, :boom)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    {:ok, observe()}
  end

  # The plugin's process is killed until its supervisor gives up.
  def crash_hard(id) do
    sup = parent(Process.whereis(plugin_module(id)))
    ref = Process.monitor(sup)
    kill_until_down(plugin_module(id), sup, ref, 10)
    {:ok, observe()}
  end

  defp kill_until_down(_module, _sup, _ref, 0), do: raise("the plugin's supervisor never gave up")

  defp kill_until_down(module, sup, sup_ref, left) do
    if worker = Process.whereis(module) do
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end

      try do
        :sys.get_state(sup)
      catch
        :exit, _ -> :ok
      end
    end

    receive do
      {:DOWN, ^sup_ref, _, _, _} -> :ok
    after
      0 -> kill_until_down(module, sup, sup_ref, left - 1)
    end
  end

  # The host stops and starts again under its supervisor, its heir left running. A
  # stop, not a kill: kills would count toward the supervisor's restart limit.
  def kill_plugins do
    :ok = Supervisor.terminate_child(HalC2.Plugins.Supervisor, Plugins)
    {:ok, _} = Supervisor.restart_child(HalC2.Plugins.Supervisor, Plugins)
    {:ok, observe()}
  end

  defp parent(worker) do
    {:dictionary, dictionary} = Process.info(worker, :dictionary)
    hd(dictionary[:"$ancestors"])
  end

  defp ask(c, message) do
    pid = Process.get({__MODULE__, :clients})[c]
    ref = Process.monitor(pid)
    send(pid, {message, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, _, _, reason} ->
        {:client_died, reason}
    end
  end

  # Casts the host was sent before this are handled; twice, for what its own
  # handling of them sent it (a started worker reports itself).
  defp sync do
    :sys.get_state(Plugins)
    :sys.get_state(Plugins)
    :ok
  end

  defp observe do
    sync()

    %{
      list: Plugins |> GenServer.call(:list) |> Enum.map(&project/1),
      config: Map.new(@ids, &{&1, observed_config(&1)}),
      code: Map.new(@code_ids, &{&1, code(&1)}),
      marks: new_marks(),
      monitors: observed_monitors()
    }
  end

  defp project(entry) do
    %{
      "id" => entry["id"],
      "version" => entry["version"],
      "enabled" => entry["enabled"],
      "status" => entry["status"],
      "error" => entry["error"] != nil,
      "reloadError" => entry["reloadError"] != nil,
      "permissions" => for(p <- entry["permissions"], do: {p["id"], p["granted"]}),
      "settings" => entry["settings"],
      "restarts" => entry["restarts"]
    }
  end

  defp observed_config(id) do
    c = get_in(HalC2.Settings.settings(), ["plugins", id]) || %{}

    secret =
      case File.read(secret_path(id)) do
        {:ok, value} -> value
        {:error, _} -> nil
      end

    %{
      enabled: c["enabled"],
      granted: c["granted"] || [],
      stored: c["settings"] || %{},
      secret: secret
    }
  end

  defp secret_path(id) do
    name = Base.url_encode64("#{id}/token", padding: false)
    Path.join([HalC2.Paths.data_dir(), "secrets", "plugin-#{name}.bin"])
  end

  defp code(id) do
    module = plugin_module(id)

    %{
      loaded: if(:code.is_loaded(module), do: module.version()),
      worker: Process.whereis(module) != nil,
      extras:
        Enum.any?(
          [Module.concat(module, Extra), Module.concat(module, Broken)],
          &(:code.is_loaded(&1) != false)
        )
    }
  end

  defp new_marks do
    {path, seen} = Process.get({__MODULE__, :marks})

    case File.read(path) do
      {:ok, text} ->
        Process.put({__MODULE__, :marks}, {path, byte_size(text)})

        text
        |> binary_part(seen, byte_size(text) - seen)
        |> String.split("\n", trim: true)
        |> Enum.map(&List.to_tuple(String.split(&1, " ")))

      {:error, _} ->
        []
    end
  end

  defp observed_monitors do
    {:monitors, monitors} = Process.info(Process.whereis(Plugins), :monitors)
    length(monitors)
  end

  defp plugins_dir, do: Path.join(HalC2.Paths.data_dir(), "plugins")
  defp plugin_module(id), do: Packages.plugin_module(id)

  defmodule Client do
    @moduledoc false
    # A stand-in for a client socket following plugin topics: subscribes from its own
    # process, as a socket does, and keeps what it was sent until asked.

    def start, do: spawn(fn -> loop([]) end)

    defp loop(inbox) do
      receive do
        {:hal_c2_plugin_topic, _node, id, topic, value} ->
          loop(inbox ++ [{id, topic, value}])

        {{:subscribe, id, topic}, from, ref} ->
          send(from, {ref, HalC2.Plugins.subscribe_topic(self(), id, topic)})
          loop(inbox)

        {{:unsubscribe, id, topic}, from, ref} ->
          HalC2.Plugins.unsubscribe_topic(self(), id, topic)
          send(from, {ref, :ok})
          loop(inbox)

        {:inbox, from, ref} ->
          send(from, {ref, inbox})
          loop([])
      end
    end
  end

  defmodule Packages do
    @moduledoc false
    # Writes the package `{variant, version, permissions}` to a directory, replacing
    # what it held. Every package has a page, an icon, a link to one of its files and a
    # link that leads out of it. Its plugin module writes `<id> <version>` to the marks
    # file when it compiles and answers `about` with its version and settings.

    @settings [
      %{"key" => "count", "label" => "Count", "type" => "number", "default" => 1},
      %{
        "key" => "mode",
        "label" => "Mode",
        "type" => "choice",
        "default" => "a",
        "options" => [
          %{"value" => "a", "label" => "A"},
          %{"value" => "b", "label" => "B"},
          %{"value" => "c", "label" => "C", "disabled" => true}
        ]
      },
      %{"key" => "token", "label" => "Token", "type" => "secret"},
      %{"key" => "tags", "label" => "Tags", "type" => "list", "default" => []}
    ]

    def plugin_module(id), do: Module.concat(HalC2PropPlugin, Macro.camelize(id))
    def main(id, version), do: "#{id} #{version} main"
    def icon(id, version), do: "<svg>#{id} #{version}</svg>"

    def write(dir, id, {variant, version, permissions}, marks) do
      File.rm_rf!(dir)
      File.mkdir_p!(Path.join(dir, "ui"))
      File.write!(Path.join(dir, "plugin.json"), manifest(id, variant, version, permissions))
      File.write!(Path.join(dir, "ui/main.qml"), main(id, version))
      File.write!(Path.join(dir, "icon.svg"), icon(id, version))
      File.ln_s!("ui/main.qml", Path.join(dir, "inner.txt"))
      File.ln_s!("../../outside.txt", Path.join(dir, "link.txt"))

      for {name, source} <- sources(id, variant, version, marks) do
        File.mkdir_p!(Path.join(dir, "mc"))
        File.write!(Path.join([dir, "mc", name]), source)
      end

      :ok
    end

    defp manifest(id, variant, version, permissions) do
      base = %{
        "id" => id,
        "name" => "Prop #{id}",
        "version" => version,
        "description" => "A package the property installs.",
        "apiVersion" => 1,
        "icon" => "icon.svg",
        "permissions" =>
          for(p <- permissions, do: %{"id" => p, "reason" => "The property asks."}),
        "settings" => @settings,
        "contributes" => %{
          "pages" => [%{"id" => "main", "title" => "Main", "qml" => "ui/main.qml"}]
        }
      }

      case variant do
        :bad_json ->
          "{not json #{version}"

        :wrong_shape ->
          JSON.encode!(%{base | "icon" => 7})

        :escape ->
          JSON.encode!(%{base | "icon" => "../outside.svg"})

        :bad_default ->
          JSON.encode!(%{base | "settings" => [bad_count() | tl(@settings)]})

        :id_mismatch ->
          JSON.encode!(%{base | "id" => if(id == "alpha", do: "beta", else: "alpha")})

        _ ->
          JSON.encode!(base)
      end
    end

    defp bad_count,
      do: %{"key" => "count", "label" => "Count", "type" => "number", "default" => "x"}

    defp sources(_id, :ui, _version, _marks), do: []

    defp sources(id, :compile_error, _version, _marks),
      do: [{"a.ex", broken(plugin_module(id))}]

    defp sources(id, :two_modules, version, marks),
      do: [{"a.ex", plugin(id, version, marks) <> extra(Module.concat(plugin_module(id), Extra))}]

    defp sources(id, :second_broken, version, marks),
      do: [
        {"a.ex", plugin(id, version, marks)},
        {"b.ex", broken(Module.concat(plugin_module(id), Broken))}
      ]

    defp sources(id, _variant, version, marks), do: [{"a.ex", plugin(id, version, marks)}]

    defp plugin(id, version, marks) do
      """
      defmodule #{inspect(plugin_module(id))} do
        @moduledoc false
        @behaviour HalC2.Plugins.Extension
        use GenServer

        File.write!(#{inspect(marks)}, #{inspect("#{id} #{version}\n")}, [:append])

        def version, do: #{inspect(version)}

        def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

        def init(settings), do: {:ok, settings}

        def handle_call(:settings, _from, settings), do: {:reply, settings, settings}

        def validate_settings(%{"count" => count}) when is_number(count) and count > 100,
          do: {:error, "count is at most 100"}

        def validate_settings(_settings), do: :ok

        def call("about", _input, context) do
          {:ok,
           %{
             "version" => #{inspect(version)},
             "settings" => context.settings,
             "worker" => GenServer.call(__MODULE__, :settings)
           }}
        end

        def call(method, _input, _context), do: {:error, "no method " <> method}
      end
      """
    end

    defp extra(module) do
      """
      defmodule #{inspect(module)} do
        @moduledoc false
        @behaviour HalC2.Plugins.Extension
        def call(_method, _input, _context), do: {:ok, nil}
      end
      """
    end

    defp broken(module) do
      """
      defmodule #{inspect(module)} do
        def broken(, do: :x
      end
      """
    end
  end
end
