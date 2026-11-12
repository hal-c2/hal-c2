defmodule HalC2.Codex.Provider do
  @moduledoc """
  The Codex entry in this MC's `ServerConfig.providers`, which is what lets a
  client's composer send to Codex here.

  The entry appears when the `codex` command is on the MC's PATH. Its model list
  comes from `codex app-server`'s `model/list`, read once in the background at boot
  (`load/0`); until then a single default model is offered.
  """

  alias HalC2.JsonRpc.Connection

  @key {__MODULE__, :models}
  @status {__MODULE__, :status}
  @default_models [%{"slug" => "gpt-5.5", "name" => "GPT-5.5", "isDefault" => true}]

  @doc """
  The entries of every Codex instance: the built-in `codex` and each instance the
  settings add for the `codex` driver, which runs its own `binaryPath`.
  """
  @spec entries() :: [map]
  def entries do
    for id <- ["codex" | HalC2.Settings.instances_of("codex")], entry = entry(id), do: entry
  end

  @doc """
  The entry of Codex instance `id`, or nil when Codex is not installed on this MC.
  An instance whose `binaryPath` names nothing is listed as not installed, so the
  user sees why it cannot run and can correct the path.
  """
  @spec entry(String.t()) :: map | nil
  def entry(id \\ "codex") do
    enabled = HalC2.Settings.instance_enabled?(id, "codex")
    # Off on this MC but on for some project, it is checked as an enabled one is, so
    # that project's turns can run on it.
    checked? = enabled or HalC2.Settings.provider_on_in_a_project?(id)

    with [executable | _] <- command(id),
         path when is_binary(path) <- System.find_executable(executable) do
      version = version(path)

      %{
        "instanceId" => id,
        "driver" => "codex",
        # Turned off in settings (`providers.codex.enabled`), it stays listed so it can be
        # turned back on; clients leave it out of the model picker.
        "enabled" => enabled,
        "installed" => true,
        "version" => version,
        "versionAdvisory" => HalC2.ProviderUpdates.advisory("codex", path, version, id),
        "status" => "ready",
        "availability" => "available",
        "auth" => %{"status" => "authenticated"},
        "checkedAt" => HalC2.Orchestration.Entities.now(),
        "models" => for(model <- entry_models(id), do: model_entry(model)),
        "slashCommands" => slash_commands(),
        "skills" => [],
        "workspaceSnapshots" =>
          {__MODULE__, id, :workspaces}
          |> :persistent_term.get(%{})
          |> Map.values()
      }
      |> with_health(id, checked?)
    else
      _ -> not_installed_or_checked(id, enabled, checked?)
    end
    |> with_continuation(id)
  end

  # What the last check (`load/0`) found, in the entry's own terms: a Codex nobody
  # has checked this session warns rather than claims ready, one that failed its
  # check says why, and a turned-off one says that instead (`checkCodexProviderStatus`).
  defp with_health(entry, _id, false) do
    Map.merge(entry, %{
      "status" => "disabled",
      "message" => "Codex is disabled in HAL-C2 settings."
    })
  end

  defp with_health(entry, id, true) do
    case check(id) do
      nil ->
        Map.merge(entry, %{
          "status" => "warning",
          "message" => "Codex provider status has not been checked in this session yet."
        })

      :ok ->
        entry

      # Signed in and usable, but its model list did not arrive: the entry
      # warns and keeps offering the last list it read.
      %{"warning" => message} ->
        Map.merge(entry, %{"status" => "warning", "message" => message})

      %{"message" => message, "installed" => _installed} ->
        # This branch is only reached with an executable on the path, so Codex
        # is installed here even when its check could not start it: its version
        # (and with it any compatibility advisory and update offer) still reads.
        Map.merge(entry, %{
          "status" => "error",
          "availability" => "unavailable",
          "message" => message
        })
    end
  end

  # No executable a path names: not installed — unless a check already ran and
  # could not start it, which is the answer that check gave.
  defp not_installed_or_checked(id, enabled, checked?) do
    case checked? && check(id) do
      %{"message" => message, "installed" => installed} ->
        %{
          "instanceId" => id,
          "driver" => "codex",
          "enabled" => enabled,
          "installed" => installed,
          "version" => nil,
          "status" => "error",
          "availability" => "unavailable",
          "message" => message,
          "auth" => %{"status" => "unknown"},
          "checkedAt" => HalC2.Orchestration.Entities.now(),
          "models" => [],
          "slashCommands" => [],
          "skills" => []
        }

      _ ->
        HalC2.Settings.not_installed_entry(id, "codex", "Codex")
    end
  end

  # Instances on one Codex home share a continuation group (`codexContinuationIdentity`):
  # a thread can move between those accounts, and only between those.
  defp with_continuation(nil, _id), do: nil

  defp with_continuation(entry, id) do
    home = HalC2.Codex.Home.shared(id) || Path.join(HalC2.Paths.user_home(), ".codex")
    Map.put(entry, "continuation", %{"groupKey" => "codex:home:#{home}"})
  end

  defp check(id), do: :persistent_term.get(@status, %{})[id]

  @doc """
  What instance `id`'s last check found, without starting a new one: `:ok`,
  `:failed`, or `:pending` when no check has finished this session. Text
  generation reads it so a writer that failed its check is not asked to write.
  """
  def check_state(id) do
    case check(id) do
      nil -> :pending
      :ok -> :ok
      # A check that only warned (a slow model list) still found a usable Codex.
      %{"warning" => _} -> :ok
      %{} -> :failed
    end
  end

  @doc """
  Records what a check of instance `id` found (`:ok`, a failure map as
  `probe/1` writes, or `nil` for no finished check), as the probe does.
  """
  def record_check(id, nil) do
    :persistent_term.put(@status, Map.delete(:persistent_term.get(@status, %{}), id))
    :ok
  end

  def record_check(id, value), do: put_check(id, value)

  defp put_check(id, value) do
    :persistent_term.put(@status, Map.put(:persistent_term.get(@status, %{}), id, value))
    :ok
  end

  @doc """
  Checks every Codex instance against its `codex app-server` and reads the model
  list; run once at boot and on a refresh. A missing binary stops the connection
  in `init`, which would take the linked caller with it, so the check runs in its
  own process. What it finds is what `entry/1` reports until the next check.
  """
  def load do
    {_pid, ref} =
      spawn_monitor(fn ->
        for id <- ["codex" | HalC2.Settings.instances_of("codex")], do: probe(id)
      end)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end

    # No notify here: a refresh probes every agent and tells clients once they
    # are all read (`HalC2.Environment.probe/2`), and a list told mid-refresh
    # would show an agent being re-read with no models yet. The boot check
    # tells clients itself (`boot/0`).
  end

  @doc """
  The boot check, run once as the MC starts: a client that connected while
  the MC booted still holds the unchecked entry, so what the check found is
  told again — there is no refresh to tell it for this one.
  """
  def boot do
    load()
    HalC2.Settings.notify_providers()
  end

  # The whole check, from starting the app-server to its last answer, has twice the
  # budget other providers' checks get: it starts a server and reads the account,
  # models and config (pingdotgg/t3code#15945). `:codex_probe_timeout_ms` replaces
  # the budget and `:codex_probe_time_scale` scales it (tests run it shorter).
  @check_budget_ms 20_000
  @config_read_ms 3_000
  @catalog_wait_ms 3_000
  @catalog_poll_ms 100

  defp probe(id) do
    # The probe's connection is linked to it: a Codex that dies as it starts must
    # fail this check, not take the probe with it before it records anything.
    Process.flag(:trap_exit, true)
    spawned_at = System.os_time(:millisecond)
    deadline = System.monotonic_time(:millisecond) + check_budget()

    env = HalC2.Codex.Home.instance_env(id)

    result =
      with [_ | _] = cmd <- command(id),
           {:ok, args} <- launch_args(id),
           {:ok, home} <- HalC2.Codex.Home.env(id),
           {:ok, conn} <- start_probe(cmd ++ args, app_server_env(home ++ env)),
           {:ok, %{} = init} <- initialize(conn, remaining(deadline)),
           :ok <- Connection.notify(conn, "initialized", nil) do
        # The account and binary checked out; only the model list can still be
        # slow. That must not throw the successful check away: the entry warns
        # and keeps the last list (`with_health/3`).
        result =
          case list_models(conn, init, spawned_at, deadline) do
            {:ok, models} ->
              tier = configured_tier(conn, deadline)

              record_models(
                id,
                for(
                  m <- models,
                  do: %{
                    "slug" => m["model"] || m["id"],
                    "name" => m["displayName"] || m["model"] || m["id"],
                    "isDefault" => m["isDefault"] == true,
                    "capabilities" => m |> capabilities() |> with_configured_tier(tier)
                  }
                )
              )

              :ok

            :error ->
              {:warning,
               "Codex did not answer its model list in time; showing the last one it gave."}
          end

        Connection.stop(conn)
        result
      else
        {:spawn, _reason} ->
          {:spawn, nil}

        # A process that dies before it answers at all never started, as far as
        # the user can tell: the binary path is where to look.
        {:error, reason} when reason in [:closed, :epipe] ->
          {:spawn, nil}

        # What the spawner says when the program is not there is not Codex speaking.
        {:error,
         %{"message" => "Codex App Server process exited" <> _, "stderr" => "[spawner]" <> _}} ->
          {:spawn, nil}

        # What the process said, unless it is the spawner's own report of a command
        # it could not exec, which only sometimes arrives before the exit is read.
        {:error, %{"message" => "Codex App Server process exited" <> _ = exit, "stderr" => said}}
        when said != "" ->
          if exit =~ "code 125" and said =~ "execvp(): failed",
            do: {:spawn, nil},
            else: {:exited, "#{exit}. It said:\n#{said}"}

        {:error, %{"message" => "Codex App Server process exited" <> _}} ->
          {:spawn, nil}

        {:error, %{"message" => message}} ->
          {:failed, message}

        {:error, message} when is_binary(message) ->
          {:failed, message}

        {:error, reason} ->
          {:failed, inspect(reason)}

        {:ok, _other} ->
          {:failed, "invalid response"}

        _ ->
          {:failed, "invalid response"}
      end

    case result do
      :ok ->
        put_check(id, :ok)

      {:warning, message} ->
        put_check(id, %{"warning" => message})

      {:spawn, _} ->
        put_check(id, %{"installed" => false, "message" => cannot_start(id)})

      {:exited, message} ->
        put_check(id, %{"installed" => true, "message" => message})

      {:failed, message} ->
        put_check(id, %{
          "installed" => true,
          "message" => "Codex app-server provider probe failed: #{message}."
        })
    end
  rescue
    # Starting the app-server is where a check can raise (a port that will not
    # open at all): that, too, is a Codex that could not be started.
    _error -> put_check(id, %{"installed" => false, "message" => cannot_start(id)})
  catch
    :exit, {:timeout, _} ->
      put_check(id, %{
        "installed" => true,
        "message" => "Timed out while checking Codex app-server provider status."
      })

    :exit, _reason ->
      put_check(id, %{"installed" => false, "message" => cannot_start(id)})

    _, _ ->
      put_check(id, %{
        "installed" => true,
        "message" => "Codex app-server provider probe failed: invalid response."
      })
  end

  # A Codex that dies at once can stop its connection before this call reaches it;
  # the call then fails with its exit and what it printed (`Connection.gone/2`).
  defp initialize(conn, timeout) do
    Connection.call(
      conn,
      "initialize",
      %{
        "clientInfo" => %{
          "name" => "hal_c2_desktop",
          "title" => "HAL-C2 Desktop",
          "version" => "0.1.0"
        }
      },
      timeout
    )
  catch
    :exit, reason -> Connection.gone(conn, reason)
  end

  defp check_budget do
    budget = Application.get_env(:hal_c2, :codex_probe_timeout_ms, @check_budget_ms)
    round(budget * Application.get_env(:hal_c2, :codex_probe_time_scale, 1))
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # The model list, as fetched for HAL-C2 (pingdotgg/t3code#18200). `model/list`
  # answers from `<codexHome>/models_cache.json` while it is fresh, and every Codex
  # client on the machine shares that file, though the backend tailors the catalog
  # to each client: the plain CLI's has no Ultrafast. A ChatGPT account's app-server
  # refreshes the catalog as it starts, so the first answer can be another client's;
  # once a write newer than this app-server's start lands, the list is read again.
  # No refresh within a few seconds keeps the first answer; the next check corrects it.
  defp list_models(conn, init, spawned_at, deadline) do
    chatgpt_home =
      with home when is_binary(home) and home != "" <- init["codexHome"],
           {:ok, %{"account" => %{"type" => "chatgpt"}}} <-
             safe_call(conn, "account/read", %{}, remaining(deadline)) do
        home
      else
        _ -> nil
      end

    case model_list(conn, remaining(deadline)) do
      {:ok, %{"data" => [_ | _] = models}} ->
        wait_until = min(deadline, System.monotonic_time(:millisecond) + @catalog_wait_ms)

        with home when is_binary(home) <- chatgpt_home,
             true <- catalog_refreshed?(home, spawned_at, wait_until),
             {:ok, %{"data" => [_ | _] = fresh}} <- model_list(conn, remaining(deadline)) do
          {:ok, fresh}
        else
          _ -> {:ok, models}
        end

      _ ->
        :error
    end
  end

  defp catalog_refreshed?(home, spawned_at, wait_until) do
    cond do
      catalog_fetched_at(home) >= spawned_at ->
        true

      System.monotonic_time(:millisecond) >= wait_until ->
        false

      true ->
        # Codex writes the file from its own process and says nothing when it does.
        Process.sleep(@catalog_poll_ms)
        catalog_refreshed?(home, spawned_at, wait_until)
    end
  end

  # When Codex last wrote its model catalog, in epoch milliseconds; -1 when unreadable.
  # `home` is the `codexHome` the app-server this MC started reports for itself, and
  # only its catalog file is read.
  # sobelow_skip ["Traversal.FileModule"]
  defp catalog_fetched_at(home) do
    with {:ok, text} <- File.read(Path.join(home, "models_cache.json")),
         {:ok, %{"fetched_at" => stamp}} when is_binary(stamp) <- JSON.decode(text),
         {:ok, at, _offset} <- DateTime.from_iso8601(stamp) do
      DateTime.to_unix(at, :millisecond)
    else
      _ -> -1
    end
  end

  # The service tier Codex's own config sets (`service_tier`), which its turns run
  # at when the thread picks none; nil when it sets none or will not say.
  defp configured_tier(conn, deadline) do
    case safe_call(
           conn,
           "config/read",
           %{"includeLayers" => false},
           min(remaining(deadline), @config_read_ms)
         ) do
      {:ok, %{"config" => %{"service_tier" => tier}}} when is_binary(tier) and tier != "" -> tier
      _ -> nil
    end
  end

  defp safe_call(conn, method, params, timeout) do
    Connection.call(conn, method, params, timeout)
  catch
    :exit, _ -> {:error, :timeout}
  end

  defp model_list(conn, timeout) do
    Connection.call(conn, "model/list", %{}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :closed}
  end

  @doc """
  The environment every `codex app-server` the MC starts runs with. Codex sends
  its client name as the `originator` the backend tailors the model catalog to,
  and it fetches that catalog before `initialize` names the client, so the name is
  set at spawn (`CODEX_INTERNAL_ORIGINATOR_OVERRIDE`). A value the user set, in the
  instance's environment or the MC's own, wins.
  """
  @spec app_server_env([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def app_server_env(env) do
    if List.keymember?(env, "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", 0) or
         System.get_env("CODEX_INTERNAL_ORIGINATOR_OVERRIDE") not in [nil, ""],
       do: env,
       else: [{"CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "hal_c2_desktop"} | env]
  end

  # Starting the app-server, told apart from it answering badly: a process that
  # never starts means the binary path is wrong, not that Codex misbehaved.
  # What a Codex that died on start printed is the only account of why (a missing
  # optional dependency of the npm package, say), so the check keeps its stderr's end.
  defp start_probe(cmd, env) do
    case Connection.start_link(
           cmd: cmd,
           handler: self(),
           env: env,
           program: "Codex App Server",
           stderr_tail: true,
           eof_grace: 250
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:spawn, reason}
    end
  catch
    :exit, reason -> {:spawn, reason}
  end

  @doc """
  Reads the skills Codex loads in `cwd` (`skills/list` on a short-lived
  app-server) and keeps them as the instance's snapshot for that folder. A
  Codex that does not answer within 20 seconds fails the read naming the
  folder; the instance's checked status is not the read's to hold up.
  """
  @spec refresh_workspace(String.t(), String.t()) :: :ok | {:error, String.t()}
  def refresh_workspace(id, cwd) do
    timeout = Application.get_env(:hal_c2, :codex_skills_timeout_ms, 20_000)
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:skills, read_skills(id, cwd, timeout)}) end)

    receive do
      {:skills, {:ok, skills}} ->
        Process.demonitor(ref, [:flush])

        snapshot = %{
          "cwd" => cwd,
          "checkedAt" => HalC2.Orchestration.Entities.now(),
          "slashCommands" => slash_commands(),
          "skills" => skills
        }

        workspaces = :persistent_term.get({__MODULE__, id, :workspaces}, %{})
        :persistent_term.put({__MODULE__, id, :workspaces}, Map.put(workspaces, cwd, snapshot))
        HalC2.Settings.notify_providers()
        :ok

      {:skills, {:error, _reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, "Failed to probe Codex skills for '#{cwd}'"}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:error, "Failed to probe Codex skills for '#{cwd}'"}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {:error, "Failed to probe Codex skills for '#{cwd}'"}
    end
  end

  defp read_skills(id, cwd, timeout) do
    env = HalC2.Codex.Home.instance_env(id)

    with [_ | _] = cmd <- command(id),
         {:ok, args} <- launch_args(id),
         {:ok, home} <- HalC2.Codex.Home.env(id),
         {:ok, conn} <-
           Connection.start_link(
             cmd: cmd ++ args,
             handler: self(),
             cd: cwd,
             env: app_server_env(home ++ env)
           ),
         {:ok, _} <-
           Connection.call(
             conn,
             "initialize",
             %{
               "clientInfo" => %{
                 "name" => "hal_c2_desktop",
                 "title" => "HAL-C2 Desktop",
                 "version" => "0.1.0"
               }
             },
             timeout
           ),
         :ok <- Connection.notify(conn, "initialized", nil),
         {:ok, %{"data" => entries}} when is_list(entries) <-
           Connection.call(conn, "skills/list", %{"cwds" => [cwd]}, timeout) do
      Connection.stop(conn)

      skills =
        Enum.find(entries, &(&1["cwd"] == cwd)) ||
          %{"skills" => Enum.flat_map(entries, &(&1["skills"] || []))}

      {:ok, Enum.map(skills["skills"] || [], &skill_entry/1)}
    else
      other -> {:error, other}
    end
  catch
    _, reason -> {:error, reason}
  end

  defp skill_entry(skill) do
    short = skill["shortDescription"] || get_in(skill, ["interface", "shortDescription"])

    %{"name" => skill["name"], "path" => skill["path"], "enabled" => skill["enabled"] == true}
    |> maybe_put("description", skill["description"])
    |> maybe_put("scope", skill["scope"])
    |> maybe_put("displayName", get_in(skill, ["interface", "displayName"]))
    |> maybe_put("shortDescription", short)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp slash_commands do
    [
      %{
        "name" => "compact",
        "description" => "Summarize the conversation and reduce context usage"
      },
      %{
        "name" => "feedback",
        "description" => "Send this thread and Codex logs to OpenAI",
        "input" => %{"hint" => "Describe the issue (optional)"}
      }
    ]
  end

  defp cannot_start(id) do
    case HalC2.Settings.instance_setting(id, "binaryPath") do
      path when is_binary(path) and path != "" ->
        "Could not start Codex CLI (`#{String.trim(path)}`). Check Settings → Providers → Codex → Binary path on the server. Make sure the configured executable exists and can be run."

      _ ->
        "Could not start Codex CLI (`codex`). Check Settings → Providers → Codex → Binary path on the server. Installing ChatGPT or Codex desktop may not add codex to PATH."
    end
  end

  @doc """
  The launch arguments set on a Codex instance (`launchArgs`), split as a shell
  would. Every Codex process the MC starts for the instance takes them: its sessions
  and this check after `app-server`, and `codex exec` those it has (`exec_args/1`).
  """
  @spec launch_args(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def launch_args(instance) do
    # The MC's own environment can pin the arguments (`codexLaunchArgs.ts`): it wins
    # over the instance's, so a deployment fixes them without touching settings.
    configured =
      case System.get_env("HAL_C2_CODEX_LAUNCH_ARGS") do
        args when is_binary(args) and args != "" ->
          args

        _ ->
          HalC2.Settings.instance_setting(instance, "launchArgs") || ""
      end

    {:ok, OptionParser.split(configured)}
  rescue
    RuntimeError -> {:error, "the launch arguments in settings have a quote that is never closed"}
  end

  @doc """
  The launch arguments `codex exec` takes: config overrides and feature switches
  (`--strict-config`, `-c`/`--config`, `--enable`, `--disable`). The rest belong to
  `app-server` alone.
  """
  @spec exec_args([String.t()]) :: [String.t()]
  def exec_args(["--strict-config" = arg | rest]), do: [arg | exec_args(rest)]

  def exec_args([arg, value | rest]) when arg in ~w(--config -c --enable --disable) do
    if String.starts_with?(value, "-"),
      do: exec_args([value | rest]),
      else: [arg, value | exec_args(rest)]
  end

  def exec_args([arg | rest]) do
    if String.starts_with?(arg, ["--config=", "-c=", "--enable=", "--disable="]),
      do: [arg | exec_args(rest)],
      else: exec_args(rest)
  end

  def exec_args([]), do: []

  # Names older threads and settings saved a model under (`MODEL_SLUG_ALIASES_BY_PROVIDER`).
  @aliases %{
    "gpt-5-codex" => "gpt-5.4",
    "5.4" => "gpt-5.4",
    "5.3" => "gpt-5.3-codex",
    "gpt-5.3" => "gpt-5.3-codex",
    "5.3-spark" => "gpt-5.3-codex-spark",
    "gpt-5.3-spark" => "gpt-5.3-codex-spark"
  }

  @doc """
  `{version, recommended}` when the Codex installed for `instance` is one this
  HAL-C2 release marks broken, else nil. A broken verdict re-reads the version
  first: the user may have updated Codex since it was last read, and the next
  turn should run on the new one.
  """
  @spec broken_version(String.t()) :: {String.t(), String.t() | nil} | nil
  def broken_version(instance \\ "codex") do
    case advisory_of(instance) do
      %{"status" => "broken"} ->
        forget_version(instance)

        case advisory_of(instance) do
          %{"status" => "broken"} = advisory ->
            {entry(instance)["version"],
             advisory["recommendedRange"] || advisory["recommendedVersion"]}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp advisory_of(instance) do
    case entry(instance) do
      %{} = entry -> HalC2.ProviderCompatibility.put(entry)["compatibilityAdvisory"]
      _ -> nil
    end
  end

  defp forget_version(instance) do
    with [executable | _] <- command(instance),
         path when is_binary(path) <- System.find_executable(executable) do
      versions = :persistent_term.get({__MODULE__, :version}, %{})
      :persistent_term.put({__MODULE__, :version}, Map.delete(versions, path))
    end

    :ok
  end

  @doc """
  The models the last check of Codex instance `id` read from `codex app-server`
  (`model/list`), or nil when no check has read them this session. Each instance
  is on its own account, so each has its own list. Text generation resolves the
  model it asks for against the writing instance's list.
  """
  def listed_models(id \\ "codex"), do: :persistent_term.get(models_key(id), nil)

  @doc """
  Records the models a check of instance `id` read, as `probe/1` does; `nil`
  forgets them. The `codex` instance's list is also the catalog clients are shown.
  """
  def record_models(id \\ "codex", models)

  def record_models(id, nil) do
    :persistent_term.erase(models_key(id))
    :ok
  end

  def record_models(id, models) when is_list(models) do
    :persistent_term.put(models_key(id), models)
    :ok
  end

  # The instance's own list (its account's models and configured tier); an instance
  # not checked yet shows the built-in instance's, else the defaults.
  defp entry_models(id),
    do: listed_models(id) || :persistent_term.get(@key, @default_models)

  defp models_key("codex"), do: @key
  defp models_key(id), do: {@key, id}

  @doc "The name Codex's model list gives `slug`, or nil when the list does not have it."
  def model_name(slug) do
    slug = current_slug(slug)

    Enum.find_value(:persistent_term.get(@key, @default_models), fn model ->
      if model["slug"] == slug, do: model["name"]
    end)
  end

  @doc """
  The value instance `id`'s list marks as the default for `model`'s option `option`
  (`"reasoningEffort"`, say), or nil when the list does not know the model or the
  option has no default.
  """
  def default_option(id, model, option) do
    slug = current_slug(model)

    with %{"capabilities" => %{"optionDescriptors" => descriptors}} <-
           Enum.find(entry_models(id), &(&1["slug"] == slug)),
         %{"options" => options} <- Enum.find(descriptors, &(&1["id"] == option)),
         %{"id" => value} <- Enum.find(options, & &1["isDefault"]) do
      value
    else
      _ -> nil
    end
  end

  @doc "The model Codex knows `model` as today: an older alias names its current id."
  def current_slug(model), do: Map.get(@aliases, model, model)

  defp model_entry(model),
    do: %{
      "slug" => model["slug"],
      "name" => model["name"],
      # Clients show a thread saved under an alias by the model's current name.
      "aliases" => for({alias, slug} <- Enum.sort(@aliases), slug == model["slug"], do: alias),
      "isCustom" => false,
      "isDefault" => model["isDefault"] == true,
      "capabilities" => model["capabilities"]
    }

  @effort_labels %{
    "none" => "None",
    "minimal" => "Minimal",
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High",
    "xhigh" => "Extra High",
    "max" => "Max",
    "ultra" => "Ultra"
  }

  # The reasoning levels and service tiers a model offers, as the composer's options.
  defp capabilities(model) do
    case Enum.reject([reasoning(model), service_tier(model)], &is_nil/1) do
      [] -> nil
      descriptors -> %{"optionDescriptors" => descriptors}
    end
  end

  defp reasoning(%{"supportedReasoningEfforts" => [_ | _] = efforts} = model) do
    default = model["defaultReasoningEffort"]

    options =
      for %{"reasoningEffort" => id} <- efforts do
        option = %{"id" => id, "label" => @effort_labels[id] || id}
        if id == default, do: Map.put(option, "isDefault", true), else: option
      end

    descriptor = %{
      "id" => "reasoningEffort",
      "label" => "Reasoning",
      "type" => "select",
      "options" => options
    }

    if Enum.any?(options, & &1["isDefault"]),
      do: Map.put(descriptor, "currentValue", default),
      else: descriptor
  end

  defp reasoning(_model), do: nil

  # What HAL-C2 says of a tier in place of the catalog's own words.
  @tier_descriptions %{"ultrafast" => "Even faster, more expensive"}

  # Standard ("default") plus the model's faster tiers; older CLIs only name speed tiers.
  defp service_tier(model) do
    tiers =
      case model["serviceTiers"] do
        [_ | _] = tiers ->
          tiers

        _ ->
          for id <- model["additionalSpeedTiers"] || [],
              do: %{"id" => id, "name" => if(id == "fast", do: "Fast", else: id)}
      end

    if tiers != [] do
      default =
        if Enum.any?(tiers, &(&1["id"] == model["defaultServiceTier"])),
          do: model["defaultServiceTier"],
          else: "default"

      options =
        for tier <- [%{"id" => "default", "name" => "Standard"} | tiers] do
          description = @tier_descriptions[tier["id"]] || tier["description"]

          %{"id" => tier["id"], "label" => tier["name"] || tier["id"]}
          |> then(
            &if description in [nil, ""], do: &1, else: Map.put(&1, "description", description)
          )
          |> then(&if tier["id"] == default, do: Map.put(&1, "isDefault", true), else: &1)
        end

      %{
        "id" => "serviceTier",
        "label" => "Service Tier",
        "type" => "select",
        "options" => options,
        "currentValue" => default
      }
    end
  end

  # The tier Codex's own config sets shows as the model's selected one, where the
  # model offers it ("fast" is the "priority" tier by its old name); a model that
  # does not keeps its own default (pingdotgg/t3code#15623).
  defp with_configured_tier(%{"optionDescriptors" => descriptors} = capabilities, tier)
       when is_binary(tier) do
    descriptors =
      for descriptor <- descriptors do
        with %{"id" => "serviceTier", "options" => options} <- descriptor,
             %{"id" => value} <-
               Enum.find(
                 options,
                 &(&1["id"] == tier or (tier == "fast" and &1["id"] == "priority"))
               ) do
          %{
            descriptor
            | "options" =>
                for(
                  option <- options,
                  do:
                    if(option["id"] == value,
                      do: Map.put(option, "isDefault", true),
                      else: Map.delete(option, "isDefault")
                    )
                )
          }
          |> Map.put("currentValue", value)
        else
          _ -> descriptor
        end
      end

    %{capabilities | "optionDescriptors" => descriptors}
  end

  defp with_configured_tier(capabilities, _tier), do: capabilities

  defp command(id), do: HalC2.Codex.Installation.command(id)

  # Read once per executable, so each instance's binary path has its own. A read that
  # missed its deadline is "unknown" until `:codex_version_retry_ms` (a minute) has
  # passed, then read again: a CLI that stays hung costs one deadline a minute, not one
  # per server config.
  defp version(path) do
    versions = :persistent_term.get({__MODULE__, :version}, %{})
    now = System.monotonic_time(:millisecond)

    case versions do
      %{^path => {:retry_at, at}} when at > now ->
        "unknown"

      %{^path => version} when is_binary(version) ->
        version

      _ ->
        {kept, version} =
          case probe_version(path) do
            :timeout ->
              {{:retry_at, now + Application.get_env(:hal_c2, :codex_version_retry_ms, 60_000)},
               "unknown"}

            version ->
              {version, version}
          end

        :persistent_term.put({__MODULE__, :version}, Map.put(versions, path, kept))
        version
    end
  end

  # A client waits on this for its server config, so the run has a deadline. Exile
  # signals the CLI when the task is killed; a wrapper that forks must pass that on to
  # its child, or the child outlives the read.
  defp probe_version(path) do
    task = Task.async(fn -> run_version(path) end)
    timeout = Application.get_env(:hal_c2, :codex_version_timeout_ms, 5_000)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, version} -> version
      _ -> :timeout
    end
  end

  defp run_version(path) do
    [path, "--version"]
    |> Exile.stream(stderr: :redirect_to_stdout, ignore_epipe: true)
    |> Enum.reduce({[], nil}, fn
      {:exit, status}, {out, _} -> {out, status}
      data, {out, status} when is_binary(data) -> {[out, data], status}
      _, acc -> acc
    end)
    |> case do
      {out, {:status, 0}} ->
        out |> IO.iodata_to_binary() |> String.split() |> List.last() |> Kernel.||("unknown")

      _ ->
        "unknown"
    end
  rescue
    _ -> "unknown"
  end
end
