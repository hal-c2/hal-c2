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

    with [executable | _] <- command(id),
         path when is_binary(path) <- System.find_executable(executable) do
      %{
        "instanceId" => id,
        "driver" => "codex",
        # Turned off in settings (`providers.codex.enabled`), it stays listed so it can be
        # turned back on; clients leave it out of the model picker.
        "enabled" => enabled,
        "installed" => true,
        "version" => version(path),
        "versionAdvisory" => HalC2.ProviderUpdates.advisory("codex", path, version(path), id),
        "status" => "ready",
        "availability" => "available",
        "auth" => %{"status" => "authenticated"},
        "checkedAt" => HalC2.Orchestration.Entities.now(),
        "models" =>
          for(model <- :persistent_term.get(@key, @default_models), do: model_entry(model)),
        "slashCommands" => slash_commands(),
        "skills" => [],
        "workspaceSnapshots" =>
          {__MODULE__, id, :workspaces}
          |> :persistent_term.get(%{})
          |> Map.values()
      }
      |> with_health(id, enabled)
    else
      _ -> not_installed_or_checked(id, enabled)
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

      %{"message" => message, "installed" => installed} ->
        Map.merge(entry, %{
          "status" => "error",
          "installed" => installed,
          "availability" => "unavailable",
          "message" => message
        })
    end
  end

  # No executable a path names: not installed — unless a check already ran and
  # could not start it, which is the answer that check gave.
  defp not_installed_or_checked(id, enabled) do
    case enabled && check(id) do
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

  defp probe(id) do
    # The probe's connection is linked to it: a Codex that dies as it starts must
    # fail this check, not take the probe with it before it records anything.
    Process.flag(:trap_exit, true)
    timeout = Application.get_env(:hal_c2, :codex_probe_timeout_ms, 10_000)

    env = Enum.to_list(HalC2.Settings.instance_env(id))

    result =
      with [_ | _] = cmd <- command(id),
           {:ok, args} <- launch_args(id),
           {:ok, home} <- HalC2.Codex.Home.env(id),
           {:ok, conn} <- start_probe(cmd ++ args, home ++ env),
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
           {:ok, %{"data" => [_ | _] = models}} <-
             Connection.call(conn, "model/list", %{}, timeout) do
        if id == "codex" do
          :persistent_term.put(
            @key,
            for(
              m <- models,
              do: %{
                "slug" => m["model"] || m["id"],
                "name" => m["displayName"] || m["model"] || m["id"],
                "isDefault" => m["isDefault"] == true,
                "capabilities" => capabilities(m)
              }
            )
          )
        end

        Connection.stop(conn)
        :ok
      else
        {:spawn, _reason} ->
          {:spawn, nil}

        # A process that dies before it answers at all never started, as far as
        # the user can tell: the binary path is where to look.
        {:error, reason} when reason in [:closed, :epipe] ->
          {:spawn, nil}

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

      {:spawn, _} ->
        put_check(id, %{"installed" => false, "message" => cannot_start(id)})

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

  # Starting the app-server, told apart from it answering badly: a process that
  # never starts means the binary path is wrong, not that Codex misbehaved.
  defp start_probe(cmd, env) do
    case Connection.start_link(cmd: cmd, handler: self(), env: env) do
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
    env = Enum.to_list(HalC2.Settings.instance_env(id))

    with [_ | _] = cmd <- command(id),
         {:ok, args} <- launch_args(id),
         {:ok, home} <- HalC2.Codex.Home.env(id),
         {:ok, conn} <-
           Connection.start_link(cmd: cmd ++ args, handler: self(), cd: cwd, env: home ++ env),
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
          %{"id" => tier["id"], "label" => tier["name"] || tier["id"]}
          |> then(
            &if tier["description"] in [nil, ""],
              do: &1,
              else: Map.put(&1, "description", tier["description"])
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

  defp command(id),
    do:
      HalC2.Settings.instance_command(
        id,
        Application.get_env(:hal_c2, :codex_command, ["codex", "app-server"])
      )

  # Read once per executable, so each instance's binary path has its own.
  defp version(path) do
    versions = :persistent_term.get({__MODULE__, :version}, %{})

    case versions do
      %{^path => version} ->
        version

      _ ->
        version =
          case System.cmd(path, ["--version"], stderr_to_stdout: true) do
            {out, 0} -> out |> String.split() |> List.last() |> Kernel.||("unknown")
            _ -> "unknown"
          end

        :persistent_term.put({__MODULE__, :version}, Map.put(versions, path, version))
        version
    end
  rescue
    _ -> "unknown"
  end
end
