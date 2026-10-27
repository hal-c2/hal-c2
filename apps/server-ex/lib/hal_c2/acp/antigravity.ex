defmodule HalC2.Acp.Antigravity do
  @moduledoc """
  Google's Antigravity ACP agent (`agy_acp_server`), as `HalC2.Acp` runs it.

  The MC installs Google's published runtime itself (`HalC2.Acp.Antigravity.Installation`)
  under `<home>/tools/antigravity-acp/<platform>-<arch>`, unless an instance names its
  own executable (`binaryPath`, with its `localharness_external` helper beside it).
  Every instance runs with a private Google profile under
  `<home>/providers/antigravity/<sha256(instance id)>`: the agent keeps its Google
  login there, and only the instance's configured sign-in method reaches it, never
  the MC's ambient Google variables.

  Signing in is `HalC2.Acp.Antigravity.Auth`. Once an instance's session opens, the
  account it used and its models are kept in the profile (`hal-c2-account.json`), so
  the provider list shows the account across MC restarts.

  Test seams (application env): `:antigravity_platform` (`{os, arch}`),
  `:antigravity_release` (a release map, or `:none`), `:antigravity_node`
  (the Node.js executable, or `false` for none), `:antigravity_setup_dir`
  (the workspace a model refresh checks in), and the timeouts
  `:antigravity_health_timeout_ms`, `:antigravity_model_refresh_timeout_ms`
  and `:antigravity_cancel_timeout_ms`.
  """

  alias HalC2.Acp.Antigravity.SessionFiles
  alias HalC2.JsonRpc.Connection

  @version "agy_acp_server_1.1.1"
  # Google's published builds (the ACP Registry's `antigravity-acp` entry).
  @releases %{
    {"darwin", "arm64"} => %{
      version: @version,
      url:
        "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-agy_acp_server_1.1.1-darwin-arm64.zip",
      sha256: "fdfa915652cdb7ba8085cc8fffed072cbe009251aa2c951aabdda07a8c28a189",
      archive_bytes: 316_014_828,
      executable: {"agy_acp_server.par", 802_163_856},
      harness: {"localharness_external", 116_766_704}
    },
    {"linux", "x64"} => %{
      version: @version,
      url:
        "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-agy_acp_server_1.1.1-linux-x86_64.zip",
      sha256: "38f62d01b32deb0907b3d39a71ec301fd36369f6ffd1cf262d4af385177f79df",
      archive_bytes: 681_969_407,
      executable: {"agy_acp_server.par", 1_880_360_328},
      harness: {"localharness_external", 128_966_920}
    },
    {"linux", "arm64"} => %{
      version: @version,
      url:
        "https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-agy_acp_server_1.1.1-linux-arm64.zip",
      sha256: "ed69e64b308fcb123ab54bf3277bf9cb0d651064f885ea5aab0ff520c7175398",
      archive_bytes: 656_572_786,
      executable: {"agy_acp_server.par", 1_862_073_131},
      harness: {"localharness_external", 122_158_704}
    },
    {"win32", "x64"} => %{
      version: @version,
      url:
        "https://dl.google.com/agy-extensions/releases/windows/agy-acp-server-agy_acp_server_1.1.1-windows-x86_64.zip",
      sha256: "47cb50eef14f0a4655d78cfcfda869bcea7aaee5f9787e936bc2935ea612c3b8",
      archive_bytes: 468_238_392,
      executable: {"agy_acp_server.exe", 430_801_616},
      harness: {"localharness_external.exe", 130_971_800}
    },
    {"win32", "arm64"} => %{
      version: @version,
      url:
        "https://dl.google.com/agy-extensions/releases/windows/agy-acp-server-agy_acp_server_1.1.1-windows-arm64.zip",
      sha256: "35f4b1f47ba6a3fea7b0a3e30010df5ea73a64b4f0e7cf991cddc673ddfbcafc",
      archive_bytes: 468_521_191,
      executable: {"agy_acp_server.exe", 435_075_816},
      harness: {"localharness_external.exe", 122_455_704}
    }
  }

  @methods ~w(oauth-personal oauth-business gemini-api-key agent-platform)

  # Google variables the MC may carry that must not decide an instance's account.
  @removed_env ~w(GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS
    GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_CLOUD_QUOTA_PROJECT
    GOOGLE_GENAI_USE_VERTEXAI GCLOUD_PROJECT CLOUDSDK_CORE_PROJECT AGY_ACP_CCPA_PROJECT
    AGY_ACP_ENABLE_OAUTH GEMINI_HOME AGY_ACP_FORCE_FILE_STORAGE ANTIGRAVITY_HARNESS_PATH
    BROWSER PYTHONUNBUFFERED ELECTRON_RUN_AS_NODE)

  @doc "The line the agent prints when it wants a browser sign-in: on stderr from 1.1.1, stdout before."
  def auth_prefix, do: "Open the following link to authenticate the ACP server: "

  @doc "Why a normal launch stopped: the agent wants a sign-in only Settings runs."
  def sign_in_required, do: "Sign in to Antigravity in Settings before you continue."

  @doc "The provider's message while an instance is signed out."
  def sign_in_message, do: "Sign in with Google to use Antigravity."

  # --- platform and release -------------------------------------------------------

  @doc "This host's OS and CPU as `{\"linux\" | \"darwin\" | \"win32\", \"x64\" | \"arm64\"}`."
  def platform do
    Application.get_env(:hal_c2, :antigravity_platform) ||
      {os(), arch(to_string(:erlang.system_info(:system_architecture)))}
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:win32, _} -> "win32"
      {:unix, name} -> to_string(name)
    end
  end

  defp arch("x86_64" <> _), do: "x64"
  defp arch("amd64" <> _), do: "x64"
  defp arch("aarch64" <> _), do: "arm64"
  defp arch("arm64" <> _), do: "arm64"
  defp arch(other), do: other |> String.split("-") |> hd()

  @doc "Google's runtime for this host, or nil where Google publishes none."
  def release do
    case Application.get_env(:hal_c2, :antigravity_release) do
      :none -> nil
      %{} = release -> release
      nil -> @releases[platform()]
    end
  end

  @doc "The platform's name in messages, such as `darwin-x64`."
  def platform_name do
    {os, arch} = platform()
    "#{os}-#{arch}"
  end

  @doc "The executable and helper file names on this platform."
  def names do
    case platform() do
      {"win32", _} -> {"agy_acp_server.exe", "localharness_external.exe"}
      _ -> {"agy_acp_server.par", "localharness_external"}
    end
  end

  @doc "Where the managed runtime lives on this MC."
  def managed_dir,
    do:
      Path.join([
        HalC2.Paths.cache_dir(),
        "tools",
        "antigravity-acp",
        platform_name()
      ])

  def versions_dir, do: Path.join(managed_dir(), "versions")
  def active_path, do: Path.join(managed_dir(), "active.json")

  # --- resolving the executable ---------------------------------------------------

  @doc """
  The executable an instance runs: its `binaryPath` (with the helper beside it),
  else the managed runtime, else `agy_acp_server.par` on PATH. `{:ok, %{executable,
  harness, version, source}}` or `{:error, detail}`.
  """
  def resolve(binary_path) do
    {exe, _harness} = names()

    case trim(binary_path) do
      nil ->
        cond do
          File.exists?(active_path()) ->
            with {:ok, %{"releaseId" => id}} when is_binary(id) <- read_json(active_path()),
                 {:ok, found} <- completed(id) do
              {:ok, found}
            else
              _ -> {:error, "The managed Antigravity runtime is incomplete. Reinstall it."}
            end

          found = Enum.find_value(path_candidates(exe), &external(&1, "path")) ->
            {:ok, found}

          release() ->
            {:error, "Antigravity is not installed or its executable could not be found."}

          true ->
            {:error,
             "Google does not publish an Antigravity runtime for #{platform_name()}. Use a supported environment or a custom executable."}
        end

      path ->
        candidates =
          if String.contains?(path, "/"), do: [Path.expand(path)], else: path_candidates(path)

        case Enum.find_value(candidates, &external(&1, "override")) do
          nil ->
            {:error,
             "The custom Antigravity executable or its localharness_external sibling is missing or not executable."}

          found ->
            {:ok, found}
        end
    end
  end

  defp path_candidates(name),
    do:
      for(
        dir <- String.split(System.get_env("PATH") || "", ":", trim: true),
        do: Path.join(dir, name)
      )

  defp external(candidate, source) do
    {_exe, harness} = names()

    if executable?(candidate) and executable?(Path.join(Path.dirname(candidate), harness)) do
      %{
        executable: candidate,
        harness: Path.join(Path.dirname(candidate), harness),
        version: nil,
        source: source,
        dir: nil
      }
    end
  end

  @doc "A completed managed release: its record matches the files beside it."
  def completed(release_id) do
    {exe, harness} = names()
    dir = Path.join(versions_dir(), release_id)

    with {:ok, record} <- read_json(Path.join(dir, ".install-complete.json")),
         %{
           "releaseId" => ^release_id,
           "version" => version,
           "executable" => %{"name" => ^exe, "bytes" => exe_bytes},
           "harness" => %{"name" => ^harness, "bytes" => harness_bytes}
         }
         when is_binary(version) and is_integer(exe_bytes) and exe_bytes > 0 and
                is_integer(harness_bytes) and harness_bytes > 0 <- record,
         true <- executable?(Path.join(dir, exe), exe_bytes),
         true <- executable?(Path.join(dir, harness), harness_bytes) do
      {:ok,
       %{
         executable: Path.join(dir, exe),
         harness: Path.join(dir, harness),
         version: version,
         source: "managed",
         dir: dir
       }}
    else
      _ -> {:error, "The managed Antigravity runtime is incomplete. Reinstall it."}
    end
  end

  @doc "Whether `path` is an executable regular file (of `bytes`, when given)."
  def executable?(path, bytes \\ nil) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size, mode: mode}} ->
        (bytes == nil or size == bytes) and Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, value} <- JSON.decode(body),
         do: {:ok, value}
  end

  # --- instance configuration -----------------------------------------------------

  @doc """
  An instance's Antigravity settings: `authMethod` (default `oauth-personal`),
  `apiKey`, `gcpProject`, `gcpLocation` and `binaryPath`, from its
  `providerInstances` config, or `providers.antigravity` for the built-in one.
  """
  def config(instance) do
    settings = HalC2.Settings.settings()
    entry = (settings["providerInstances"] || %{})[instance]

    raw =
      case entry do
        %{"config" => %{} = config} -> config
        _ -> get_in(settings, ["providers", "antigravity"]) || %{}
      end

    method = raw["authMethod"]

    %{
      "authMethod" => if(method in @methods, do: method, else: "oauth-personal"),
      "apiKey" => trim(raw["apiKey"]),
      "gcpProject" => trim(raw["gcpProject"]),
      "gcpLocation" => trim(raw["gcpLocation"]),
      "binaryPath" => trim(raw["binaryPath"])
    }
  end

  @doc "What a sign-in method still needs from the settings, or nil."
  def config_issue(%{"authMethod" => "oauth-business"} = c) do
    if c["gcpProject"] && c["gcpLocation"],
      do: nil,
      else:
        "Gemini Enterprise needs a GCP project and location in the Antigravity provider settings."
  end

  def config_issue(%{"authMethod" => "gemini-api-key"} = c),
    do:
      if(c["apiKey"],
        do: nil,
        else: "Enter a Gemini API key in the Antigravity provider settings."
      )

  def config_issue(%{"authMethod" => "agent-platform"} = c) do
    if c["apiKey"] || (c["gcpProject"] && c["gcpLocation"]),
      do: nil,
      else:
        "Agent Platform needs an API key, or a GCP project and location, in the Antigravity provider settings."
  end

  def config_issue(_config), do: nil

  @doc "A sign-in method's name as the provider shows it."
  def label("oauth-business"), do: "Gemini Enterprise"
  def label("gemini-api-key"), do: "Gemini API key"
  def label("agent-platform"), do: "Agent Platform"
  def label(_method), do: "Google account"

  @doc "Whether a method signs in through Google's page in a browser."
  def browser?(method), do: method in ~w(oauth-personal oauth-business)

  # --- the profile ----------------------------------------------------------------

  @doc "An instance's private Google profile (the agent's `GEMINI_HOME`)."
  def profile(instance) do
    hash = :crypto.hash(:sha256, instance) |> Base.encode16(case: :lower)
    Path.join([HalC2.Paths.data_dir(), "providers", "antigravity", hash])
  end

  @doc "The agent's saved Google login in a profile."
  def token_path(instance),
    do: Path.join([profile(instance), "antigravity-acp", "acp_token.json"])

  # Sign-in runs its browser helper on Node.js, as upstream's does; without it
  # a session cannot be prepared at all.
  defp require_node do
    found =
      case Application.get_env(:hal_c2, :antigravity_node, :find) do
        :find -> System.find_executable("node")
        false -> nil
        path -> path
      end

    if found,
      do: :ok,
      else:
        {:error,
         "Antigravity sign-in requires Node.js. Install Node.js and make sure node is on PATH, then retry."}
  end

  # Owner-only directories, this process's runtime temp directory, the user's
  # skill folders linked in, and the method's `settings.json`, which never
  # holds a key. Each step that can fail names itself.
  defp prepare_profile(instance, config) do
    acp = Path.join(profile(instance), "antigravity-acp")

    with {:ok, tmp} <- SessionFiles.runtime_dir(profile(instance)) do
      for dir <- [profile(instance), acp, SessionFiles.temp_dir(profile(instance))],
          do: File.chmod(dir, 0o700)

      gcp =
        %{"project" => config["gcpProject"], "location" => config["gcpLocation"]}
        |> Map.reject(fn {_k, v} -> v == nil end)

      settings =
        %{"auth" => %{"type" => config["authMethod"]}}
        |> then(&if(gcp == %{}, do: &1, else: Map.put(&1, "gcp", gcp)))

      case File.write(Path.join(acp, "settings.json"), JSON.encode!(settings) <> "\n") do
        :ok ->
          link_user_skills(profile(instance))
          {:ok, tmp}

        _ ->
          SessionFiles.release(tmp)
          {:error, "Could not prepare the Antigravity provider status."}
      end
    end
  end

  # The agent resolves its user skill folders under its profile, so they link
  # back to the user's own `~/.gemini`.
  defp link_user_skills(profile) do
    home = System.get_env("HOME") || System.user_home() || "/nonexistent"

    for rel <- [["config", "skills"], ["antigravity-cli", "skills"]] do
      link = Path.join([profile | rel])
      target = Path.join([home, ".gemini" | rel])

      case File.lstat(link) do
        {:error, _} ->
          File.mkdir_p(Path.dirname(link))
          File.ln_s(target, link)

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  The command and environment that start an instance's agent: the resolved
  executable with its profile, and only the configured method's credential.
  Exile adds the MC's own environment, so the Google variables the MC carries
  are removed with `env -u` first.
  """
  def command(instance, extra_env \\ []) do
    config = config(instance)

    with {:ok, found} <- resolve(config["binaryPath"]),
         :ok <- require_node(),
         {:ok, tmp} <- prepare_profile(instance, config) do
      credential =
        case config do
          %{"authMethod" => "gemini-api-key", "apiKey" => key} when is_binary(key) ->
            [{"GEMINI_API_KEY", key}]

          %{"authMethod" => "agent-platform", "apiKey" => key} when is_binary(key) ->
            [{"GOOGLE_API_KEY", key}]

          _ ->
            []
        end

      env =
        credential ++
          [
            {"GEMINI_HOME", profile(instance)},
            {"AGY_ACP_FORCE_FILE_STORAGE", "1"},
            # A launched session never opens a browser; sign-in runs from Settings.
            {"BROWSER", "true"},
            {"PYTHONUNBUFFERED", "1"},
            {"ELECTRON_RUN_AS_NODE", "1"},
            {"TMPDIR", tmp},
            {"ANTIGRAVITY_HARNESS_PATH", found.harness}
          ] ++ extra_env

      set = MapSet.new(env, &elem(&1, 0))
      unset = for key <- @removed_env, not MapSet.member?(set, key), do: ["-u", key]
      args = if elem(platform(), 0) == "linux", do: ["--uid="], else: []

      {:ok, [System.find_executable("env") | List.flatten(unset)] ++ [found.executable | args],
       env}
    end
  end

  # --- the saved account ----------------------------------------------------------

  defp account_path(instance), do: Path.join(profile(instance), "hal-c2-account.json")

  @doc "The account an instance last opened a session with, for its current method."
  def account(instance) do
    method = config(instance)["authMethod"]

    case read_json(account_path(instance)) do
      {:ok, %{"type" => ^method} = account} -> account
      _ -> nil
    end
  end

  @doc "Records the account and models an opened session showed."
  def put_account(instance, models) do
    method = config(instance)["authMethod"]
    File.mkdir_p!(profile(instance))

    File.write!(
      account_path(instance),
      JSON.encode!(%{"type" => method, "label" => label(method), "models" => models})
    )

    HalC2.Acp.forget(instance)
    HalC2.Settings.notify_providers()
  end

  @doc "Forgets an instance's account (signed out, or the agent asked for a sign-in)."
  def drop_account(instance) do
    File.rm(account_path(instance))
    HalC2.Acp.put_unauthenticated(instance)
  end

  # --- the provider entry ---------------------------------------------------------

  @doc "The Antigravity parts of an instance's provider entry (`HalC2.Acp.entry/1`)."
  def entry_fields(entry, id) do
    config = config(id)
    account = account(id)

    entry =
      Map.merge(entry, %{
        "displayName" => entry["displayName"] || "Antigravity",
        "supportsConversationRollback" => false,
        "supportsTextGeneration" => false,
        "setup" => %{"canAuthenticate" => true, "canInstall" => true},
        "workspaceSnapshots" => workspaces(id)
      })

    cond do
      not entry["enabled"] ->
        Map.merge(entry, %{
          # Disabled is not checked, but the runtime is either on this machine or it is not.
          "installed" => match?({:ok, _}, resolve(config["binaryPath"])),
          "status" => "disabled",
          "models" => (account || %{})["models"] || [],
          "message" => "Antigravity is disabled in HAL-C2 settings."
        })

      match?({:error, _}, resolve(config["binaryPath"])) ->
        {:error, detail} = resolve(config["binaryPath"])

        Map.merge(entry, %{
          "installed" => false,
          "status" => "error",
          "models" => [],
          "message" => detail,
          "auth" => Map.put(entry["auth"], "status", "unknown")
        })

      failure = :persistent_term.get({HalC2.Acp, id, :error}, nil) ->
        Map.merge(entry, %{"status" => "error", "message" => failure, "models" => []})

      account && not :persistent_term.get({HalC2.Acp, id, :unauthenticated}, false) ->
        entry
        |> Map.merge(%{"status" => "ready", "models" => account["models"] || []})
        |> Map.delete("message")
        |> Map.update!(
          "auth",
          &Map.merge(&1, %{
            "status" => "authenticated",
            "type" => account["type"],
            "label" => account["label"]
          })
        )

      :persistent_term.get({HalC2.Acp, id, :unauthenticated}, false) ->
        Map.merge(entry, %{
          "status" => "warning",
          "models" => [],
          "message" => sign_in_message(),
          "auth" => Map.put(entry["auth"], "status", "unauthenticated")
        })

      true ->
        Map.merge(entry, %{
          "status" => "warning",
          "models" => [],
          "message" =>
            if(:persistent_term.get({HalC2.Acp, id, :models}, nil) == nil,
              do: "Checking Antigravity availability.",
              else:
                config_issue(config) ||
                  "Antigravity is installed. Google account access is not checked yet."
            ),
          "auth" => Map.put(entry["auth"], "status", "unknown")
        })
    end
  end

  # --- timeouts and the preferred model ------------------------------------------

  @doc "How long a health check waits for the runtime, in milliseconds."
  def health_timeout, do: Application.get_env(:hal_c2, :antigravity_health_timeout_ms, 90_000)

  @doc "How long a model refresh waits for the runtime, in milliseconds."
  def model_refresh_timeout,
    do: Application.get_env(:hal_c2, :antigravity_model_refresh_timeout_ms, 90_000)

  @doc "How long a stopped turn's process is given to confirm before it is stopped."
  def cancel_timeout, do: Application.get_env(:hal_c2, :antigravity_cancel_timeout_ms, 15_000)

  @doc "The model HAL-C2 ships as Antigravity's default (the manifest's chat default)."
  def preferred_model do
    case HalC2.ModelManifest.catalog("antigravity") do
      %{} = catalog -> get_in(catalog, ["defaults", "chat"])
      _ -> nil
    end
  end

  # --- refreshing the account's models --------------------------------------------

  @doc """
  Reads the account's models again in a disposable session, as upstream's
  model refresh does: `:ok` with the new list recorded, or `{:error, detail}`
  leaving the previous list unchanged.
  """
  def refresh_models(instance) do
    config = config(instance)
    method = config["authMethod"]

    cond do
      issue = config_issue(config) ->
        {:error, issue}

      browser?(method) and not File.exists?(token_path(instance)) ->
        {:error, "Sign in to Antigravity in provider settings before refreshing models."}

      true ->
        case setup_workspace() do
          {:ok, cwd} -> refresh_in(instance, config, cwd)
          {:error, _} = error -> error
        end
    end
  end

  # The workspace is chosen here, and the session reports its runtime
  # directory and session id as it makes them, so a task killed at the
  # deadline is still cleaned up: its own `after` block never runs.
  defp refresh_in(instance, config, cwd) do
    saved = File.read(account_path(instance))
    caller = self()
    task = Task.async(fn -> refresh_session(instance, config, cwd, caller) end)

    result =
      case Task.yield(task, model_refresh_timeout()) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, _} ->
          {:error, could_not_refresh()}

        nil ->
          {:error, "Antigravity model refresh timed out. Try again or check Google sign-in."}
      end

    # Drained on every path: a finished session already cleaned up after
    # itself, and its reports must not sit in the caller's mailbox.
    {tmp, session} = collect_refresh(nil, nil)

    if result != :ok do
      clean_refresh(instance, cwd, tmp, session)
      restore_account(instance, saved)
    end

    result
  end

  defp clean_refresh(instance, cwd, tmp, session) do
    SessionFiles.remove_session_files(profile(instance), session, cwd)
    SessionFiles.release(tmp)
    File.rm_rf(cwd)
  end

  defp collect_refresh(tmp, session) do
    receive do
      {:antigravity_refresh, :tmp, dir} -> collect_refresh(dir, session)
      {:antigravity_refresh, :session, id} -> collect_refresh(tmp, id)
    after
      0 -> {tmp, session}
    end
  end

  defp could_not_refresh,
    do: "Could not refresh Antigravity models. The previous model list is unchanged."

  # A failed refresh changes nothing the list shows, even where trying it
  # learned the login had gone.
  defp restore_account(instance, {:ok, body}) do
    File.write(account_path(instance), body)
    HalC2.Acp.forget(instance)
    :persistent_term.put({HalC2.Acp, instance, :models}, [])
  end

  defp restore_account(_instance, _saved), do: :ok

  defp refresh_session(instance, config, cwd, caller) do
    try do
      with {:ok, command, env} <- command(instance),
           _ <- Process.put(:antigravity_refresh_tmp, tmp_of(env)),
           _ <- send(caller, {:antigravity_refresh, :tmp, tmp_of(env)}),
           {:ok, conn} <-
             Connection.start_link(
               cmd: command,
               handler: self(),
               cd: cwd,
               env: env,
               dialect: :v2,
               stderr_prefix: auth_prefix()
             ),
           _ <- Process.put(:antigravity_refresh_conn, conn),
           {:ok, _init} <-
             Connection.call(conn, "initialize", HalC2.Acp.initialize_params(), 60_000),
           :ok <- refresh_authenticate(conn, instance, config),
           {:ok, %{} = session} <-
             Connection.call(conn, "session/new", %{"cwd" => cwd, "mcpServers" => []}, 60_000) do
        Process.put(:antigravity_refresh_session, session["sessionId"])
        send(caller, {:antigravity_refresh, :session, session["sessionId"]})
        put_account(instance, HalC2.Acp.session_models(session))
        :ok
      else
        {:error, detail} when is_binary(detail) -> {:error, detail}
        {:error, _} -> {:error, could_not_refresh()}
      end
    after
      if conn = Process.get(:antigravity_refresh_conn), do: Connection.stop(conn)

      SessionFiles.remove_session_files(
        profile(instance),
        Process.get(:antigravity_refresh_session),
        cwd
      )

      SessionFiles.release(Process.get(:antigravity_refresh_tmp))
      File.rm_rf(cwd)
    end
  end

  defp refresh_authenticate(conn, instance, _config) do
    case HalC2.Acp.Antigravity.Session.authenticate(conn, instance) do
      :ok ->
        :ok

      {:error, message} ->
        if message == sign_in_required(),
          do: {:error, "Sign in to Antigravity in provider settings before refreshing models."},
          else: {:error, could_not_refresh()}
    end
  end

  defp tmp_of(env) do
    case List.keyfind(env, "TMPDIR", 0) do
      {"TMPDIR", dir} -> dir
      _ -> nil
    end
  end

  @doc "The `TMPDIR` a command's environment carries, for releasing it when its process ends."
  def runtime_tmp(env) when is_list(env), do: tmp_of(env)
  def runtime_tmp(_env), do: nil

  # The folder a disposable check runs in, made for it and removed with it.
  defp setup_workspace do
    dir =
      Application.get_env(:hal_c2, :antigravity_setup_dir) ||
        Path.join(
          System.tmp_dir!(),
          "hal-c2-antigravity-setup-#{System.unique_integer([:positive])}"
        )

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      _ -> {:error, "Could not create an Antigravity setup workspace."}
    end
  end

  # --- sessions -------------------------------------------------------------------

  @doc "The pids of an instance's running thread sessions."
  def sessions(instance) do
    Registry.select(HalC2.Acp.Registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {pid, value} -> if value == instance, do: [pid], else: [] end)
  catch
    _, _ -> []
  end

  @doc "Stops an instance's sessions (a thread's next message starts a new one)."
  def stop_sessions(instance, except \\ nil) do
    for pid <- sessions(instance), pid != except do
      try do
        GenServer.call(pid, :close, 15_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # --- workspaces and skills ------------------------------------------------------

  defp workspaces(id) do
    for {cwd, snapshot} <- :persistent_term.get({HalC2.Acp, id, :workspaces}, %{}),
        do: Map.put(snapshot, "cwd", cwd)
  end

  @doc """
  Reads the skills Antigravity offers in `cwd` and keeps them on the entry:
  `:ok`, or `{:error, detail}` with no snapshot kept, so a failed read never
  leaves a partial skill list behind.
  """
  def refresh_workspace(id, cwd) do
    case skills(cwd) do
      {:ok, found} ->
        snapshot = %{
          "checkedAt" => HalC2.Orchestration.Entities.now(),
          "slashCommands" => [],
          "skills" => found
        }

        workspaces = :persistent_term.get({HalC2.Acp, id, :workspaces}, %{})
        :persistent_term.put({HalC2.Acp, id, :workspaces}, Map.put(workspaces, cwd, snapshot))
        HalC2.Settings.notify_providers()
        :ok

      {:error, _detail} = error ->
        error
    end
  end

  # The scan's budget, as upstream's `AntigravitySkills.ts` keeps it: a skill
  # file over 1 MB, over 8 MB of skill files, or over 10,000 folder entries
  # stops the whole search instead of cutting it short.
  @skill_file_bytes 1_000_000
  @skill_scan_bytes 8_000_000
  @skill_scan_entries 10_000

  @doc """
  The skills the agent loads in `cwd`, in its own order: the first skill of a
  name wins across `~/.gemini/config/skills`, `.gemini/skills`,
  `~/.gemini/antigravity-cli/skills`, `.agents/skills` and `.agent/skills`;
  `~/.agents/skills` is not read. A folder holds its own skill or skills one
  folder below it, no deeper. `{:ok, skills}` or `{:error, detail}` naming
  where reading failed.
  """
  def skills(cwd, home \\ System.get_env("HOME") || System.user_home()) do
    gemini = Path.join(home || "/nonexistent", ".gemini")

    roots = [
      {Path.join([gemini, "config", "skills"]), "user"},
      {Path.join([cwd, ".gemini", "skills"]), "project"},
      {Path.join([gemini, "antigravity-cli", "skills"]), "user"},
      {Path.join([cwd, ".agents", "skills"]), "project"},
      {Path.join([cwd, ".agent", "skills"]), "project"}
    ]

    budget = %{bytes: @skill_scan_bytes, entries: @skill_scan_entries}

    case Enum.reduce_while(roots, {:ok, budget, %{}}, fn {dir, scope}, {:ok, budget, found} ->
           case scan(dir, scope, true, budget, found) do
             {:ok, budget, found} -> {:cont, {:ok, budget, found}}
             {:error, _} = error -> {:halt, error}
           end
         end) do
      {:ok, _budget, found} -> {:ok, found |> Map.values() |> Enum.sort_by(& &1["name"])}
      {:error, _} = error -> error
    end
  end

  defp scan(dir, scope, children?, budget, found) do
    case File.ls(dir) do
      {:ok, entries} ->
        if length(entries) > budget.entries do
          scan_limit(dir)
        else
          budget = %{budget | entries: budget.entries - length(entries)}
          entries = Enum.sort(entries)

          case Enum.find(entries, &(String.downcase(&1) == "skill.md")) do
            nil when children? ->
              Enum.reduce_while(entries, {:ok, budget, found}, fn entry, {:ok, budget, found} ->
                case scan(Path.join(dir, entry), scope, false, budget, found) do
                  {:ok, budget, found} -> {:cont, {:ok, budget, found}}
                  {:error, _} = error -> {:halt, error}
                end
              end)

            nil ->
              {:ok, budget, found}

            file ->
              read_skill(Path.join(dir, file), dir, scope, budget, found)
          end
        end

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, budget, found}

      {:error, _reason} ->
        {:error, "Antigravity could not read skills at '#{dir}'."}
    end
  end

  defp read_skill(path, dir, scope, budget, found) do
    limit = min(@skill_file_bytes, budget.bytes)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > limit ->
        scan_limit(path)

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, body} when byte_size(body) > limit ->
            scan_limit(path)

          {:ok, body} ->
            budget = %{budget | bytes: budget.bytes - byte_size(body)}

            found =
              with %{"name" => name} = skill <- frontmatter(body, Path.basename(dir)),
                   false <- Map.has_key?(found, name) do
                Map.put(
                  found,
                  name,
                  Map.merge(skill, %{"path" => path, "scope" => scope, "enabled" => true})
                )
              else
                _ -> found
              end

            {:ok, budget, found}

          {:error, :enoent} ->
            {:ok, budget, found}

          _ ->
            {:error, "Antigravity could not read skills at '#{path}'."}
        end

      {:error, :enoent} ->
        {:ok, budget, found}

      {:ok, %File.Stat{}} ->
        {:ok, budget, found}

      _ ->
        {:error, "Antigravity could not read skills at '#{path}'."}
    end
  end

  defp scan_limit(path),
    do: {:error, "Antigravity skill discovery exceeded its scan limit at '#{path}'."}

  # A skill file's header block: `name` (its folder's name when it states
  # none) and `description`. A header that does not parse as those strings,
  # or a name with a space before or after it, describes no skill.
  defp frontmatter(body, folder) do
    case String.split(body, "---", parts: 3) do
      [_, yaml, _] ->
        case yaml_fields(yaml) do
          {:ok, fields} ->
            name = if fields["name"] in [nil, ""], do: folder, else: fields["name"]

            if name == "" or name != String.trim(name) do
              nil
            else
              %{"name" => name}
              |> then(
                &if(fields["description"] in [nil, ""],
                  do: &1,
                  else: Map.put(&1, "description", String.trim(fields["description"]))
                )
              )
            end

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  defp yaml_fields(yaml) do
    lines =
      yaml
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, fields} ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          case yaml_value(String.trim(value)) do
            {:ok, parsed} ->
              {:cont, {:ok, Map.put(fields, key, parsed)}}

            :error ->
              if key in ["name", "description"], do: {:halt, :error}, else: {:cont, {:ok, fields}}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  # A quoted scalar keeps its inner spaces; a plain one that YAML would read
  # as something other than a string is not a string.
  defp yaml_value(<<quote, _::binary>> = value) when quote in [?", ?'] do
    if byte_size(value) >= 2 and String.ends_with?(value, <<quote>>),
      do: {:ok, String.slice(value, 1..-2//1)},
      else: :error
  end

  defp yaml_value(value) do
    cond do
      value == "" -> {:ok, nil}
      String.starts_with?(value, ["[", "{"]) -> :error
      Regex.match?(~r/^-?\d+(\.\d+)?$/, value) -> :error
      value in ~w(true false null ~) -> :error
      true -> {:ok, value}
    end
  end

  # --- attachments ----------------------------------------------------------------

  @mib 1024 * 1024
  @images ~w(image/bmp image/jpeg image/png image/webp)
  @audio ~w(audio/aac audio/flac audio/mp3 audio/mpeg audio/mp4 audio/m4a audio/x-m4a
    audio/ogg audio/wav audio/x-wav audio/webm)
  @text_mimes ~w(application/json application/javascript application/typescript
    application/xml application/yaml application/x-yaml application/x-sh)
  @text_exts ~w(.txt .md .markdown .json .jsonl .yaml .yml .toml .xml .csv .tsv .log .ini
    .cfg .conf .env .js .jsx .mjs .cjs .ts .tsx .py .rb .go .rs .java .kt .swift .c .h
    .cc .cpp .hpp .cs .php .sh .bash .zsh .fish .sql .html .htm .css .scss .less .vue
    .svelte .ex .exs .erl .lua .r .pl .dart .scala .graphql .proto)

  @doc """
  Checks a turn's attachments against what Antigravity takes, reading each
  as it will be sent: `:ok` or `{:error, message}` naming what is wrong.
  The check remembers each file's size for this turn's prompt, so one that
  grows past its limit between the check and the sending is reported as
  changed while being read.
  """
  def check_attachments(attachments) do
    Process.put(:antigravity_attachment_sizes, %{})

    case blocks(attachments, true) do
      {:ok, _blocks} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  The prompt blocks carrying a turn's attachments, in a form Antigravity
  takes: an image or audio clip itself, a PDF as a link without its bytes,
  a text file's text, and a long pasted text kept apart (the message names
  where it is saved, and the agent reads it there). Text files up to 1 MiB,
  images up to 10 MiB, audio up to 20 MiB, and 50 MiB in all. Ported from
  upstream's `buildAntigravityPrompt`.
  """
  def attachment_blocks(attachments), do: blocks(attachments, false)

  defp blocks(attachments, record?) do
    Enum.reduce_while(attachments, {:ok, [], 0}, fn attachment, {:ok, blocks, total} ->
      case attachment_block(attachment, total, record?) do
        {:ok, nil, total} -> {:cont, {:ok, blocks, total}}
        {:ok, block, total} -> {:cont, {:ok, blocks ++ [block], total}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, blocks, _total} -> {:ok, blocks}
      {:error, _} = error -> error
    end
  end

  defp attachment_block(attachment, total, record?) do
    name = attachment.name

    with {:kind, kind} when not is_nil(kind) <- {:kind, kind(attachment)},
         {:path, path} when is_binary(path) <- {:path, attachment_path(attachment)},
         {:ok, %File.Stat{type: type, size: size}} <- stat(path, name) do
      if record?,
        do:
          Process.put(
            :antigravity_attachment_sizes,
            Map.put(Process.get(:antigravity_attachment_sizes, %{}), path, size)
          )

      known = Process.get(:antigravity_attachment_sizes, %{})[path]

      cond do
        pasted_text?(attachment) ->
          if type == :regular,
            do: {:ok, nil, total},
            else: {:error, "Could not read attachment '#{name}'."}

        size > limit(kind) and is_integer(known) and known <= limit(kind) and not record? ->
          {:error, "Attachment '#{name}' changed while being read and is too large."}

        type != :regular or size > limit(kind) or total + size > 50 * @mib ->
          {:error, too_large(name)}

        kind == :pdf ->
          {:ok,
           %{
             "type" => "resource_link",
             "uri" => "file://" <> path,
             "name" => name,
             "mimeType" => "application/pdf"
           }, total + size}

        true ->
          read_block(attachment, kind, path, size, total)
      end
    else
      {:kind, nil} ->
        {:error,
         "Antigravity does not support '#{name}' (#{attachment.mime_type}). Attach a BMP, JPEG, PNG, WebP, PDF, audio, or text file."}

      {:path, nil} ->
        {:error, invalid_or_missing(attachment)}

      {:error, _} = error ->
        error
    end
  end

  defp read_block(attachment, kind, path, size, total) do
    name = attachment.name
    limit = limit(kind)

    case read_at_most(path, limit + 1) do
      {:ok, bytes} ->
        total = total + byte_size(bytes)

        cond do
          byte_size(bytes) > limit or total > 50 * @mib ->
            if size <= limit and total - byte_size(bytes) + size <= 50 * @mib,
              do: {:error, "Attachment '#{name}' changed while being read and is too large."},
              else: {:error, too_large(name)}

          kind == :image ->
            {:ok,
             %{"type" => "image", "mimeType" => mime(attachment), "data" => Base.encode64(bytes)},
             total}

          kind == :audio ->
            {:ok,
             %{"type" => "audio", "mimeType" => mime(attachment), "data" => Base.encode64(bytes)},
             total}

          not String.valid?(bytes) ->
            {:error, "Attachment '#{name}' is not a UTF-8 text file."}

          String.contains?(bytes, <<0>>) ->
            {:error, "Attachment '#{name}' contains binary data."}

          true ->
            {:ok,
             %{
               "type" => "resource",
               "resource" => %{
                 "uri" => "file://" <> path,
                 "mimeType" => mime(attachment),
                 "text" => bytes
               }
             }, total}
        end

      _ ->
        {:error, "Could not read attachment '#{name}'."}
    end
  end

  defp read_at_most(path, max) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, max) do
            data when is_binary(data) -> {:ok, data}
            _ -> {:error, :read}
          end
        after
          File.close(file)
        end

      error ->
        error
    end
  end

  defp stat(path, name) do
    case File.stat(path) do
      {:ok, _} = ok -> ok
      _ -> {:error, "Could not read attachment '#{name}'."}
    end
  end

  # An attachment whose stored id cannot name a file is invalid; one whose
  # upload is simply gone could not be read.
  defp invalid_or_missing(attachment) do
    if HalC2.Attachments.valid_id?(Map.get(attachment, :id)),
      do: "Could not read attachment '#{attachment.name}'.",
      else: "Invalid attachment '#{attachment.name}'."
  end

  defp attachment_path(attachment) do
    cond do
      is_binary(Map.get(attachment, :path)) ->
        attachment.path

      HalC2.Attachments.valid_id?(Map.get(attachment, :id)) ->
        HalC2.Attachments.path(%{"id" => attachment.id})

      true ->
        nil
    end
  end

  defp pasted_text?(attachment),
    do:
      attachment.type == "file" and
        get_in(attachment, [Access.key(:source), "_tag"]) == "pasted-text"

  defp mime(attachment) do
    (attachment.mime_type || "text/plain")
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> hd()
  end

  defp too_large(name),
    do:
      "Attachment '#{name}' is too large. Antigravity accepts text files up to 1 MiB, images up to 10 MiB, audio up to 20 MiB, and 50 MiB total attachments."

  defp limit(:image), do: 10 * @mib
  defp limit(:audio), do: 20 * @mib
  defp limit(:pdf), do: 50 * @mib
  defp limit(:text), do: @mib

  defp kind(%{type: type, mime_type: raw_mime, name: name}) do
    mime = (raw_mime || "") |> String.downcase() |> String.split(";", parts: 2) |> hd()

    cond do
      type == "image" and mime in @images -> :image
      type == "file" and mime in @audio -> :audio
      type == "file" and mime == "application/pdf" -> :pdf
      type == "file" and (String.starts_with?(mime, "text/") or mime in @text_mimes) -> :text
      type == "file" and String.downcase(Path.extname(name || "")) in @text_exts -> :text
      # Attachments built before they carried a type are still classified.
      type == nil and mime in @images -> :image
      type == nil and mime in @audio -> :audio
      true -> nil
    end
  end

  # --- tools ----------------------------------------------------------------------

  @doc "Whether a tool call starts Antigravity subagents (not an MCP tool of that name)."
  def subagent?(call) do
    call["title"] in ["Running start_subagent", "Run start_subagent?"] and
      call["kind"] in [nil, "other"] and
      get_in(call, ["_meta", "is_mcp_tool_call"]) != true
  end

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trim(_value), do: nil
end
