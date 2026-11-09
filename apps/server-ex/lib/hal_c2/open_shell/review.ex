defmodule HalC2.OpenShell.Review do
  @moduledoc """
  The sandboxes untrusted code reviews run in (#1412). A review thread's agent runs
  in one OpenShell sandbox of its own, over an exec stream
  (`HalC2.Subprocess.Sandboxed`), never as a program of this machine.

  `open/1` makes it: an OpenShell provider holding the model's API key (the sandbox
  gets the key as OpenShell injects it, never as an environment value), the sandbox
  under `HalC2.OpenShell.Policy.review/1` with its limits, the checkout built inside
  it from a git bundle with its HEAD and merge-base checked, and a broker token for
  the one tool the agent reports through (`HalC2.OpenShell.Broker`). What the thread
  runtimes need is its binding (`binding/1`), kept in memory only: an MC that
  restarts has none, so the thread refuses to run (`refusal/2`) instead of falling
  back to this machine.

  The sandbox goes (`close/2`) on the first report, when the review is stopped,
  discarded or run again, past its time, output or token limit, and on boot
  (`reconcile/0`). It is labelled with when its lease ends, which `reap/2` reads, so
  `hal-c2-service openshell reap` on a timer next to the gateway deletes it even
  while the MC is down (`HalC2.OpenShell.Service`).
  """

  use GenServer

  import Kernel, except: [binding: 1]

  alias HalC2.OpenShell
  alias HalC2.OpenShell.{Broker, Client, Policy, Service}
  alias HalC2.OpenShell.Proto.Openshell.V1, as: Pb

  require Logger

  @table __MODULE__
  @role_label "halc2.github.io/role"
  @expires_label "halc2.github.io/expires"
  @thread_label "halc2.github.io/thread"
  @home_label "halc2.github.io/home"
  @workdir "/sandbox/review"
  @bundle "/sandbox/review.bundle"
  @limits %{cpu: "2", memory: "4Gi"}
  @ready_ms 300_000

  # The drivers whose agent can run in a review sandbox, with the API it calls, the
  # provider profile (`profile/1`) and key holding its credential and how that key is
  # sent, and the executables in the review image (`HalC2.OpenShell.Manifest`) the
  # policy lets reach it. Every other driver refuses (`refusal/2`).
  @drivers %{
    "claudeAgent" => %{
      host: "api.anthropic.com",
      type: "hal-c2-claude",
      key: "ANTHROPIC_API_KEY",
      auth: {"header", "x-api-key"},
      command: ["claude"],
      binaries: ["/usr/local/bin/claude"]
    },
    "codex" => %{
      host: "api.openai.com",
      type: "hal-c2-codex",
      key: "OPENAI_API_KEY",
      auth: {"bearer", "authorization"},
      command: ["codex", "app-server"],
      # npm's launcher, which runs the native binary under it: OpenShell matches a
      # connection's binary by its process's ancestors too.
      binaries: ["/usr/bin/codex", "/usr/bin/node"]
    }
  }

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The drivers a review sandbox runs."
  def drivers, do: Map.keys(@drivers)

  @doc "Whether `driver`'s agent can review in a sandbox."
  def supported?(driver), do: Map.has_key?(@drivers, driver)

  @doc """
  The argv `driver`'s agent runs as in the sandbox, from the image's PATH: a host
  path in the instance's settings means nothing there.
  """
  def command(driver), do: @drivers[driver].command

  @doc """
  The live binding of sandboxed thread `thread_id`, or nil:
  `%{sandbox, workdir, home, mcp, conn, deadline, timeout_seconds, on_limit}`.
  """
  def binding(thread_id) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, {:binding, thread_id}) do
      [{_, binding}] -> binding
      _ -> nil
    end
  end

  @doc """
  What `HalC2.Subprocess.start/2` takes as `:sandbox` for a program of `binding`, in
  `environment`.
  """
  def subprocess(binding, environment \\ %{}) do
    %{
      conn: binding.conn,
      name: binding.sandbox,
      workdir: binding.workdir,
      environment:
        Map.merge(
          %{"HOME" => binding.home, "GIT_CONFIG_NOSYSTEM" => "1"},
          Map.new(environment)
        ),
      timeout_seconds: max(binding.deadline - now(), 1),
      on_limit: fn -> close(binding.thread_id, "output") end
    }
  end

  @doc """
  `turn` as its runtime runs it: a sandboxed one (`turn.sandbox`) in its sandbox's
  checkout, whose path replaces the review's checkout on this machine.
  """
  def in_sandbox(%{sandbox: true, ids: %{thread: thread_id}} = turn) do
    case binding(thread_id) do
      %{workdir: dir} -> %{turn | cwd: dir}
      nil -> turn
    end
  end

  def in_sandbox(turn), do: turn

  @doc """
  The `:sandbox` of a program of sandboxed `turn`'s agent (`subprocess/2`), or
  `{:error, message}` once its sandbox is gone.
  """
  def for_turn(%{ids: %{thread: thread_id}}, environment \\ %{}) do
    case binding(thread_id) do
      nil -> {:error, refusal(thread_id, "codex") || ended_text(nil)}
      binding -> {:ok, subprocess(binding, environment)}
    end
  end

  @doc "The broker the agent of sandboxed `turn` reports through, as `HalC2.Mcp.for_agent/2` answers."
  def mcp(%{ids: %{thread: thread_id}}) do
    case binding(thread_id) do
      %{mcp: mcp} -> mcp
      nil -> nil
    end
  end

  @doc """
  Why a turn of sandboxed thread `thread_id` on `driver` cannot run, or nil: the
  driver cannot run in a sandbox, or the thread's sandbox is gone. It never runs on
  this machine instead.
  """
  def refusal(thread_id, driver) do
    cond do
      not supported?(driver) ->
        "This review runs in a sandbox, which #{driver_name(driver)} cannot run in yet. Pick Claude or Codex for reviews."

      binding(thread_id) == nil ->
        ended_text(ended(thread_id)) <> " Run the review again."

      true ->
        nil
    end
  end

  @doc "Why the sandbox of `thread_id` was closed, or nil: `\"time\"`, `\"output\"`, `\"tokens\"`, ..."
  def ended(thread_id) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, {:ended, thread_id}) do
      [{_, reason}] -> reason
      _ -> nil
    end
  end

  @doc "A sentence for why a review's sandbox ended, for its thread and its row."
  def ended_text("time"), do: "The review ran past its time limit and its sandbox was deleted."

  def ended_text("output"),
    do: "The review's agent wrote more output than a review may, and its sandbox was deleted."

  def ended_text("tokens"), do: "The review used up its token budget and its sandbox was deleted."
  def ended_text(_), do: "This review's sandbox is gone."

  @doc """
  Opens the sandbox of review thread `thread_id`. `spec`: `%{thread_id, driver,
  instance, clone, head_ref, base_ref, head, merge_base, review, tool, minutes,
  tokens}`: the checkout is made from refs `head_ref` (at `head`) and `base_ref` of
  the git repository at `clone`, and the broker takes one call of plugin tool `tool`
  for `review`.
  `{:ok, %{sandbox, deadline}}` once the agent can start, or `{:error, message}`
  with nothing left behind.
  """
  def open(%{thread_id: thread_id, driver: driver} = spec) do
    with true <-
           Process.whereis(__MODULE__) != nil ||
             {:error, "Review sandboxes are not running on this MC."},
         {:ok, model} <- model(driver, spec.instance),
         :ok <- Service.reaped(),
         {:ok, disk} <- disk(),
         :ok <- GenServer.call(__MODULE__, {:opening, thread_id}),
         {:ok, conn} <- GenServer.call(__MODULE__, :conn, 30_000),
         {:ok, broker} <- GenServer.call(__MODULE__, :broker, 30_000) do
      name = name(thread_id)
      deadline = now() + trunc(spec.minutes * 60)
      labels = labels(thread_id, deadline)

      token =
        Broker.issue(%{
          thread_id: thread_id,
          tool: spec.tool,
          review: spec.review,
          commit: spec.head,
          deadline: deadline
        })

      policy =
        Policy.review(%{
          model: %{host: model.host, port: 443, binaries: model.binaries, provider: name},
          broker: broker
        })

      # A provider this attempt could not make is not its to delete: its name may be
      # taken by one it does not own. One whose answer was lost carries the lease
      # label, so the reaper deletes it.
      result =
        with {:made, :ok} <- {:made, Client.ensure_profile(conn, profile(model))},
             {:made, :ok} <- {:made, create_provider(conn, name, model, labels)},
             {:ok, _} <-
               Client.create_sandbox(conn, name,
                 labels: labels,
                 image: OpenShell.Manifest.images().review_workload,
                 policy: policy,
                 limits: @limits,
                 driver_config: disk,
                 providers: [name],
                 environment: %{"HOME" => Policy.home()},
                 timeout: 60_000
               ),
             :ok <- ready(conn, name, System.monotonic_time(:millisecond) + @ready_ms),
             :ok <- composed(conn, name, policy),
             :ok <- bounded(conn, name),
             :ok <- checkout(conn, name, spec, deadline) do
          binding = %{
            thread_id: thread_id,
            sandbox: name,
            workdir: @workdir,
            home: Policy.home(),
            conn: conn,
            deadline: deadline,
            commit: spec.head,
            tokens: spec.tokens,
            # `report`: the server is the broker, with the one tool and none of HAL-C2's.
            mcp: %{url: broker.url, authorization: "Bearer " <> token, report: true}
          }

          with :ok <- GenServer.call(__MODULE__, {:bind, binding}),
               do: {:ok, %{sandbox: name, deadline: deadline}}
        end

      case result do
        {:ok, _} = ok ->
          ok

        {:made, error} ->
          Broker.revoke(thread_id)
          {:error, failure(error)}

        error ->
          Broker.revoke(thread_id)
          remove(conn, name)
          {:error, failure(error)}
      end
    end
  end

  @doc """
  Closes the sandbox of `thread_id`: its broker token is revoked and its binding
  goes, and the sandbox and its provider are deleted after the call returns.
  `reason` is kept for `ended/1`.
  """
  def close(thread_id, reason \\ nil) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:close, thread_id, reason}, 60_000),
      else: :ok
  end

  @doc """
  Adds to what sandboxed thread `thread_id` has spent: `key` names one count of the
  provider's (a message, a thread total) and `tokens` is its latest value, so a count
  reported again is not added twice. Past the thread's budget its sandbox goes.
  """
  def spent(thread_id, key, tokens) when is_integer(tokens) do
    if binding(thread_id), do: GenServer.cast(__MODULE__, {:spent, thread_id, key, tokens})
    :ok
  end

  @doc """
  Deletes every review sandbox and provider of this MC: on boot no binding survives,
  so none of them can be used again.
  """
  def reconcile, do: GenServer.cast(__MODULE__, :reconcile)

  @doc """
  Deletes this home's review sandboxes whose lease ended by `now` (unix seconds), with
  their providers, over `conn`, and any provider past its lease whose sandbox never
  came. Run by `hal-c2-service openshell reap` without the MC. `{:ok, names}` of the
  sandboxes deleted, or, when any deletion failed, `{:error, {:not_deleted, names,
  failed}}` with the sandboxes deleted anyway and each `{name, reason}` that was not.
  """
  def reap(conn, now) do
    with {:ok, sandboxes} <- Client.list_sandboxes(conn, selector()),
         {:ok, providers} <- Client.providers(conn, selector()) do
      names = for sandbox <- expired(sandboxes, now), do: sandbox.name
      removed = for name <- names, do: {name, remove(conn, name)}

      # A provider of a sandbox removed above went with it.
      orphans =
        for %{name: name} <- expired(providers, now),
            name not in names,
            do: {name, Client.delete_provider(conn, name)}

      deleted = for {name, :ok} <- removed, do: name

      case for({name, {:error, reason}} <- removed ++ orphans, do: {name, reason}) do
        [] -> {:ok, deleted}
        failed -> {:error, {:not_deleted, deleted, failed}}
      end
    end
  end

  @doc "The sandboxes of `sandboxes` whose lease label ended by `now`, or that carry none."
  def expired(sandboxes, now) do
    Enum.filter(sandboxes, fn %{labels: labels} ->
      case Integer.parse(labels[@expires_label] || "") do
        {at, ""} -> at <= now
        _ -> true
      end
    end)
  end

  @doc """
  The labels of thread `thread_id`'s sandbox with its lease ending at `deadline`.
  Beside the MC's owner label (`HalC2.OpenShell.owner_label/0`, which `Client` adds),
  the home label names this HAL-C2 home (`HalC2.OpenShell.instance/0`): two homes
  that share an environment id, as a copied one does, never reap or reconcile each
  other's sandboxes on a gateway they share.
  """
  def labels(thread_id, deadline),
    do: %{
      @role_label => "review",
      @home_label => OpenShell.instance(),
      @thread_label => thread_id,
      @expires_label => to_string(deadline)
    }

  @doc "The sandbox (and provider) name of review thread `thread_id`."
  def name(thread_id), do: "review-" <> String.downcase(thread_id)

  # --- server ---------------------------------------------------------------------------

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    Broker.table()
    # No binding outlives an MC, so whatever review sandbox is left goes.
    reconcile()
    {:ok, %{conn: nil, broker: nil, listener: nil, timers: %{}, spent: %{}}}
  end

  @impl true
  def handle_call(:conn, _from, %{conn: nil} = state) do
    case Client.connect() do
      {:ok, conn} ->
        {:reply, {:ok, conn}, %{state | conn: conn}}

      {:error, :not_installed} ->
        {:reply, {:error, not_installed()}, state}

      {:error, {:shared_gateway, _} = reason} ->
        {:reply, {:error, why(reason)}, state}

      {:error, reason} ->
        {:reply, {:error, "OpenShell could not be reached: #{inspect(reason)}"}, state}
    end
  end

  def handle_call(:conn, _from, state), do: {:reply, {:ok, state.conn}, state}

  def handle_call(:broker, _from, %{broker: nil} = state) do
    case Broker.listen() do
      {:ok, broker, pid} ->
        {:reply, {:ok, broker}, %{state | broker: broker, listener: pid}}

      {:error, reason} ->
        {:reply, {:error, "The report broker could not start: #{inspect(reason)}"}, state}
    end
  end

  def handle_call(:broker, _from, state), do: {:reply, {:ok, state.broker}, state}

  # Each run has a thread of its own, so a thread closed before or while its sandbox
  # is made (its review stopped) gets none.
  def handle_call({:opening, thread_id}, _from, state) do
    if :ets.member(@table, {:ended, thread_id}),
      do: {:reply, {:error, "The review was stopped before its sandbox was made."}, state},
      else: {:reply, :ok, state}
  end

  def handle_call({:bind, binding}, _from, state) do
    if :ets.member(@table, {:ended, binding.thread_id}),
      do: {:reply, {:error, "The review was stopped while its sandbox was made."}, state},
      else: {:reply, :ok, bind(state, binding)}
  end

  def handle_call({:close, thread_id, reason}, _from, state),
    do: {:reply, :ok, end_sandbox(state, thread_id, reason)}

  defp bind(state, binding) do
    :ets.insert(@table, {{:binding, binding.thread_id}, binding})
    ms = max(binding.deadline - now(), 0) * 1000
    timer = Process.send_after(self(), {:deadline, binding.thread_id}, ms)
    put_in(state.timers[binding.thread_id], timer)
  end

  @impl true
  def handle_cast({:spent, thread_id, key, tokens}, state) do
    case binding(thread_id) do
      %{tokens: budget} ->
        counts = Map.put(Map.get(state.spent, thread_id, %{}), key, tokens)
        state = put_in(state.spent[thread_id], counts)

        if is_number(budget) and Enum.sum(Map.values(counts)) > budget,
          do: {:noreply, end_sandbox(state, thread_id, "tokens")},
          else: {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_cast(:reconcile, state) do
    case state.conn || connected() do
      nil ->
        {:noreply, state}

      conn ->
        bound = for {{:binding, _}, b} <- :ets.tab2list(@table), into: MapSet.new(), do: b.sandbox

        # Listed here, before any review opens (their calls wait behind this cast),
        # so only what was left from before is deleted; deleted off the server, as
        # `end_sandbox/3` deletes.
        sandboxes =
          case Client.list_sandboxes(conn, selector()) do
            {:ok, sandboxes} -> for %{name: name} <- sandboxes, name not in bound, do: name
            _ -> []
          end

        providers =
          case Client.list_providers(conn, selector()) do
            {:ok, providers} -> for name <- providers, name not in bound, do: name
            _ -> []
          end

        later(fn ->
          Enum.each(sandboxes, &remove(conn, &1))
          Enum.each(providers -- sandboxes, &Client.delete_provider(conn, &1))
        end)

        {:noreply, %{state | conn: conn}}
    end
  end

  @impl true
  def handle_info({:deadline, thread_id}, state),
    do: {:noreply, end_sandbox(state, thread_id, "time")}

  # The listener went: the next review starts it again.
  def handle_info({:EXIT, pid, _reason}, %{listener: pid} = state),
    do: {:noreply, %{state | broker: nil, listener: nil}}

  # Calls and streams end normally all the time; anything else may be the gRPC
  # connection going, so the next call connects again.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state) do
    if state.conn, do: Client.disconnect(state.conn)
    {:noreply, %{state | conn: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when conn != nil, do: Client.disconnect(conn)
  def terminate(_reason, _state), do: :ok

  # A thread ends once: the first reason is kept, and its sandbox, if it was made,
  # goes. One that ends with none, its review's on this machine, costs no call.
  # Deleting runs off the server, since a deletion the gateway only accepted is
  # waited on (`Client.delete_sandbox/3`); one that fails is left to the reaper.
  defp end_sandbox(state, thread_id, reason) do
    Broker.revoke(thread_id)
    binding = binding(thread_id)
    :ets.delete(@table, {:binding, thread_id})
    :ets.insert_new(@table, {{:ended, thread_id}, reason || "closed"})
    {timer, timers} = Map.pop(state.timers, thread_id)
    if timer, do: Process.cancel_timer(timer)
    if binding, do: later(fn -> remove(binding.conn, binding.sandbox) end)
    %{state | timers: timers, spent: Map.delete(state.spent, thread_id)}
  end

  defp connected do
    case Client.connect() do
      {:ok, conn} -> conn
      _ -> nil
    end
  end

  # --- making one -------------------------------------------------------------------------

  defp model(driver, instance) do
    case @drivers[driver] do
      nil ->
        {:error, refusal(nil, driver)}

      model ->
        key = HalC2.Settings.instance_env(instance)[model.key] || System.get_env(model.key)

        if is_binary(key) and key != "",
          do: {:ok, Map.put(model, :credentials, %{model.key => key})},
          else:
            {:error,
             "A review sandbox needs #{model.key} for #{driver_name(driver)}: a sign-in on this machine does not reach the sandbox. Set it in the provider's environment in Settings."}
    end
  end

  # The provider profile a review's API key is held under: the key alone, as the
  # agent's own variable, with no endpoints or binaries of its own. The review's
  # policy binds it to the one endpoint its agent calls (`Policy.review/1`), which
  # OpenShell allows only for a profile that names none, and adds nothing to it.
  defp profile(%{type: id, key: key, auth: {style, header}}) do
    %Pb.ProviderProfile{
      id: id,
      display_name: "HAL-C2 review (#{key})",
      description: "The API key of a HAL-C2 review sandbox's agent.",
      category: :PROVIDER_PROFILE_CATEGORY_AGENT,
      credentials: [
        %Pb.ProviderProfileCredential{
          name: "api_key",
          env_vars: [key],
          required: true,
          auth_style: style,
          header_name: header
        }
      ]
    }
  end

  defp create_provider(conn, name, model, labels) do
    Client.create_provider(conn, name, model.type, model.credentials, labels: labels)
  end

  defp ready(conn, name, deadline) do
    case Client.get_sandbox(conn, name) do
      {:ok, %{phase: :ready}} ->
        :ok

      {:ok, %{phase: phase}} when phase in [:error, :completed, :stopped, :deleting] ->
        {:error, "The review sandbox went #{phase} while starting."}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          # The gateway has no watch for a sandbox becoming ready that the MC uses.
          Process.sleep(1_000)
          ready(conn, name, deadline)
        else
          {:error, "The review sandbox did not start in time."}
        end
    end
  end

  # The policy the gateway composed for the sandbox, which a gateway-wide policy may
  # have widened, is the one asked for.
  defp composed(conn, name, wanted) do
    with {:ok, policy} <- Client.sandbox_policy(conn, name),
         :ok <- Policy.check(policy, wanted) do
      :ok
    else
      {:error, why} when is_binary(why) ->
        {:error, "The review sandbox's policy is wider than asked: #{why}."}

      error ->
        error
    end
  end

  # The review's disk (`Policy.writable/0`): a tmpfs of its size on each path it
  # writes, asked of the gateway's driver. Only OpenShell's Podman and Docker drivers
  # mount them; a gateway on another driver gets no review.
  defp disk do
    case OpenShell.state() do
      %{"driver" => driver} when driver in ~w(podman docker) ->
        mounts =
          for {path, bytes} <- Policy.writable(),
              do: %{"type" => "tmpfs", "target" => path, "size_bytes" => bytes, "mode" => 0o1777}

        {:ok, %{driver => %{"mounts" => mounts}}}

      _ ->
        {:error,
         "Review sandboxes need OpenShell's Podman or Docker driver, the ones that bound a review's disk."}
    end
  end

  # Each path the review writes is the tmpfs asked for, no larger, before anything is
  # put there: a driver that left one out would give the review this machine's disk.
  defp bounded(conn, name) do
    writable = Policy.writable()

    with {:ok, out} <-
           run(conn, name, [
             "stat",
             "-f",
             "-c",
             "%T %b %S",
             "--" | Enum.map(writable, &elem(&1, 0))
           ]) do
      seen = String.split(out, "\n", trim: true)

      if length(seen) == length(writable) and
           Enum.all?(Enum.zip(writable, seen), fn {{_path, bytes}, line} ->
             tmpfs?(line, bytes)
           end),
         do: :ok,
         else:
           {:error,
            "The review sandbox's disk is not bounded: its driver did not mount the tmpfs asked for."}
    end
  end

  defp tmpfs?(line, bytes) do
    with ["tmpfs", blocks, size] <- String.split(line),
         {blocks, ""} <- Integer.parse(blocks),
         {size, ""} <- Integer.parse(size) do
      blocks * size <= bytes
    else
      _ -> false
    end
  end

  # The checkout is a new repository made from a bundle of the two refs: no remote,
  # no config of the MC's, no hooks, filters or submodules, every tracked file. Its
  # HEAD and merge-base must be the ones the review is of before the agent starts.
  # Its upload has until the review's own time limit. It removes only the directory
  # `bundle/1` made.
  # sobelow_skip ["Traversal.FileModule"]
  defp checkout(conn, name, spec, deadline) do
    script = """
    set -eu
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME=#{Policy.home()}
    mkdir -p #{Policy.home()} #{@workdir}
    cd #{@workdir}
    git init -q
    git config core.hooksPath /dev/null
    git fetch -q --no-tags #{@bundle} +#{spec.head_ref}:refs/heads/review +#{spec.base_ref}:refs/review/base
    git checkout -q --no-recurse-submodules review
    rm -f #{@bundle}
    echo "head $(git rev-parse HEAD)"
    echo "base $(git merge-base HEAD refs/review/base || true)"
    """

    with {:ok, tar} <- bundle(spec),
         upload =
           Client.upload(conn, name, "/sandbox", {:file, tar},
             upload_timeout: max(deadline - now(), 1) * 1000
           ),
         File.rm_rf(Path.dirname(tar)),
         :ok <- upload,
         {:ok, out} <- run(conn, name, ["sh", "-c", script]) do
      lines = String.split(out, "\n", trim: true)

      cond do
        "head #{spec.head}" not in lines ->
          {:error, "The checkout in the review sandbox is not at #{spec.head}."}

        sha?(spec.merge_base) and "base #{spec.merge_base}" not in lines ->
          {:error,
           "The checkout in the review sandbox does not have merge-base #{spec.merge_base}."}

        true ->
          :ok
      end
    end
  end

  # A tar holding `review.bundle`, a git bundle of the review's two refs, in a
  # directory of its own the caller removes. The directory is the MC's temporary one
  # and a unique integer; nothing a client or the agent sends names it.
  # sobelow_skip ["Traversal.FileModule"]
  defp bundle(spec) do
    dir = Path.join(System.tmp_dir!(), "hal-c2-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, Path.basename(@bundle))
    tar = Path.join(dir, "review.tar")

    env = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]

    case System.cmd("git", ["bundle", "create", "-q", file, spec.head_ref, spec.base_ref],
           cd: spec.clone,
           env: env,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok =
          :erl_tar.create(to_charlist(tar), [
            {to_charlist(Path.basename(file)), to_charlist(file)}
          ])

        {:ok, tar}

      {out, _} ->
        File.rm_rf(dir)
        {:error, "The review's checkout could not be bundled: #{String.trim(out)}"}
    end
  end

  defp sha?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, value)

  # A command run to its end in the sandbox: `{:ok, stdout}` when it exits 0.
  defp run(conn, name, argv) do
    with {:ok, exec} <- Client.exec(conn, name, argv, timeout_seconds: 600) do
      collect(exec, [])
    end
  end

  defp collect(exec, out) do
    receive do
      {:openshell_exec, ^exec, {:stdout, data}} ->
        collect(exec, [out, data])

      {:openshell_exec, ^exec, {:stderr, _}} ->
        collect(exec, out)

      {:openshell_exec, ^exec, {:exit, 0}} ->
        {:ok, IO.iodata_to_binary(out)}

      {:openshell_exec, ^exec, {:exit, code}} ->
        {:error, "The checkout in the review sandbox failed (exit #{code})."}

      {:openshell_exec, ^exec, {:error, reason}} ->
        {:error, reason}
    after
      660_000 ->
        HalC2.OpenShell.Exec.cancel(exec)
        {:error, "The checkout in the review sandbox did not finish."}
    end
  end

  # Deletes off the server. The connection is the review process's: one that goes
  # with it ends the deletion, and what is left is the reaper's or the next boot's.
  defp later(fun) do
    Task.start(fn ->
      try do
        fun.()
      catch
        :exit, reason -> Logger.info("openshell: a deletion ended early: #{inspect(reason)}")
      end
    end)
  end

  # `:ok` once sandbox `name` and its provider are both gone, or the first error.
  # The provider is tried even when the sandbox is not, as its credential matters most.
  defp remove(conn, name) do
    results = [
      sandbox: Client.delete_sandbox(conn, name),
      provider: Client.delete_provider(conn, name)
    ]

    for {what, {:error, reason}} <- results,
        do: Logger.warning("openshell: deleting #{what} #{name} failed: #{inspect(reason)}")

    Enum.find(Keyword.values(results), :ok, &(&1 != :ok))
  end

  defp failure({:error, reason}), do: why(reason)
  defp failure(other), do: inspect(other)

  @doc """
  A sentence for why OpenShell would not make, fill or run a review's sandbox, for
  its row: the review fails with it, and nothing runs outside the sandbox.
  """
  def why(message) when is_binary(message), do: message

  def why(:not_owned),
    do: "The review's sandbox is not one this MC made, so nothing was run in it."

  def why(:timeout), do: "The review's checkout did not reach its sandbox in time."

  def why({:read, reason}),
    do: "The review's checkout could not be read for its sandbox: #{:file.format_error(reason)}."

  def why({:profile_differs, id}),
    do:
      "OpenShell's provider profile #{id} is not the one HAL-C2 makes, so the review's API key was not given to it. Delete that profile from the gateway and HAL-C2 makes its own."

  def why({:profile_refused, id, messages}),
    do: "OpenShell would not take HAL-C2's provider profile #{id}: #{Enum.join(messages, "; ")}"

  def why({:shared_gateway, _environments}),
    do:
      "This MC's OpenShell gateway holds another HAL-C2 environment's sandboxes, so it makes no review sandbox. Give each environment a gateway of its own."

  def why(%{message: message}) when is_binary(message),
    do: "OpenShell refused the review sandbox: #{message}"

  def why(reason), do: "OpenShell refused the review sandbox: #{inspect(reason)}"

  defp not_installed,
    do:
      "Reviews of untrusted pull requests run in an OpenShell sandbox, and OpenShell is not installed on this MC. Run `hal-c2-service openshell install`."

  defp driver_name("claudeAgent"), do: "Claude"
  defp driver_name("codex"), do: "Codex"
  defp driver_name(nil), do: "this agent"
  defp driver_name(driver), do: driver

  defp now, do: System.os_time(:second)

  # This home's review sandboxes and providers: what reap and reconcile list.
  defp selector, do: %{@role_label => "review", @home_label => OpenShell.instance()}

  @doc false
  def role_label, do: @role_label
  @doc false
  def home_label, do: @home_label
  @doc false
  def expires_label, do: @expires_label
  @doc false
  def owner, do: OpenShell.owner()
end
