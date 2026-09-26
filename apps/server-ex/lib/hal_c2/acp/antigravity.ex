defmodule HalC2.Acp.Antigravity do
  @moduledoc """
  Google's Antigravity ACP agent (`agy_acp_server`), as `HalC2.Acp` runs it.

  The node installs Google's published runtime itself (`HalC2.Acp.Antigravity.Installation`)
  under `<home>/tools/antigravity-acp/<platform>-<arch>`, unless an instance names its
  own executable (`binaryPath`, with its `localharness_external` helper beside it).
  Every instance runs with a private Google profile under
  `<home>/providers/antigravity/<sha256(instance id)>`: the agent keeps its Google
  login there, and only the instance's configured sign-in method reaches it, never
  the node's ambient Google variables.

  Signing in is `HalC2.Acp.Antigravity.Auth`. Once an instance's session opens, the
  account it used and its models are kept in the profile (`hal-c2-account.json`), so
  the provider list shows the account across node restarts.

  Test seams (application env): `:antigravity_platform` (`{os, arch}`),
  `:antigravity_release` (a release map, or `:none`).
  """

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

  # Google variables the node may carry that must not decide an instance's account.
  @removed_env ~w(GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS
    GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_CLOUD_QUOTA_PROJECT
    GOOGLE_GENAI_USE_VERTEXAI GCLOUD_PROJECT CLOUDSDK_CORE_PROJECT AGY_ACP_CCPA_PROJECT
    AGY_ACP_ENABLE_OAUTH GEMINI_HOME AGY_ACP_FORCE_FILE_STORAGE ANTIGRAVITY_HARNESS_PATH
    BROWSER PYTHONUNBUFFERED ELECTRON_RUN_AS_NODE)

  @doc "The line the agent prints when it wants a browser sign-in."
  def auth_prefix, do: "Open the following link to authenticate the ACP server: "

  @doc "Why a normal launch stopped: the agent wants a sign-in only Settings runs."
  def sign_in_required, do: "Sign in to Antigravity in Settings before you continue."

  @doc "The provider's message while an instance is signed out."
  def sign_in_message, do: "Sign in with Google to use Antigravity."

  # --- platform and release -------------------------------------------------------

  @doc "This host as Node names it: `{\"linux\" | \"darwin\" | \"win32\", \"x64\" | \"arm64\"}`."
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

  @doc "Where the managed runtime lives on this node."
  def managed_dir,
    do:
      Path.join([Application.fetch_env!(:hal_c2, :home), "tools", "antigravity-acp", platform_name()])

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
            {:error,
             "Antigravity is not installed. Install it in this environment or set a custom executable path."}

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
    Path.join([Application.fetch_env!(:hal_c2, :home), "providers", "antigravity", hash])
  end

  @doc "The agent's saved Google login in a profile."
  def token_path(instance),
    do: Path.join([profile(instance), "antigravity-acp", "acp_token.json"])

  # Owner-only directories and the method's `settings.json`, which never holds a key.
  defp prepare_profile(instance, config) do
    acp = Path.join(profile(instance), "antigravity-acp")
    tmp = Path.join(acp, "tmp")
    File.mkdir_p!(tmp)
    for dir <- [profile(instance), acp, tmp], do: File.chmod(dir, 0o700)

    gcp =
      %{"project" => config["gcpProject"], "location" => config["gcpLocation"]}
      |> Map.reject(fn {_k, v} -> v == nil end)

    settings =
      %{"auth" => %{"type" => config["authMethod"]}}
      |> then(&if(gcp == %{}, do: &1, else: Map.put(&1, "gcp", gcp)))

    File.write!(Path.join(acp, "settings.json"), JSON.encode!(settings) <> "\n")
    tmp
  end

  @doc """
  The command and environment that start an instance's agent: the resolved
  executable with its profile, and only the configured method's credential.
  Exile adds the node's own environment, so the Google variables the node carries
  are removed with `env -u` first.
  """
  def command(instance, extra_env \\ []) do
    config = config(instance)

    with {:ok, found} <- resolve(config["binaryPath"]) do
      tmp = prepare_profile(instance, config)

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
    :persistent_term.put({HalC2.Acp, instance, :unauthenticated}, true)
    HalC2.Settings.notify_providers()
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
            config_issue(config) ||
              "Antigravity is installed. Google account access is not checked yet.",
          "auth" => Map.put(entry["auth"], "status", "unknown")
        })
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

  @doc "Reads the skills Antigravity offers in `cwd` and keeps them on the entry."
  def refresh_workspace(id, cwd) do
    snapshot = %{
      "checkedAt" => HalC2.Orchestration.Entities.now(),
      "slashCommands" => [],
      "skills" => skills(cwd)
    }

    workspaces = :persistent_term.get({HalC2.Acp, id, :workspaces}, %{})
    :persistent_term.put({HalC2.Acp, id, :workspaces}, Map.put(workspaces, cwd, snapshot))
    HalC2.Settings.notify_providers()
  end

  @doc """
  The skills the agent loads in `cwd`, in its own order: the first skill of a
  name wins across `~/.gemini/config/skills`, `.gemini/skills`,
  `~/.gemini/antigravity-cli/skills`, `.agents/skills` and `.agent/skills`.
  """
  def skills(cwd, home \\ System.get_env("HOME") || System.user_home()) do
    gemini = Path.join(home || "/nonexistent", ".gemini")

    [
      {Path.join([gemini, "config", "skills"]), "user"},
      {Path.join([cwd, ".gemini", "skills"]), "project"},
      {Path.join([gemini, "antigravity-cli", "skills"]), "user"},
      {Path.join([cwd, ".agents", "skills"]), "project"},
      {Path.join([cwd, ".agent", "skills"]), "project"}
    ]
    |> Enum.reduce(%{}, fn {dir, scope}, found -> scan(dir, scope, true, found) end)
    |> Map.values()
    |> Enum.sort_by(& &1["name"])
  end

  defp scan(dir, scope, children?, found) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries = Enum.sort(entries)

        case Enum.find(entries, &(String.downcase(&1) == "skill.md")) do
          nil when children? ->
            Enum.reduce(entries, found, &scan(Path.join(dir, &1), scope, false, &2))

          nil ->
            found

          file ->
            path = Path.join(dir, file)

            with {:ok, body} <- File.read(path),
                 %{"name" => name} = skill <- frontmatter(body, file),
                 false <- Map.has_key?(found, name) do
              Map.put(
                found,
                name,
                Map.merge(skill, %{"path" => path, "scope" => scope, "enabled" => true})
              )
            else
              _ -> found
            end
        end

      _ ->
        found
    end
  end

  defp frontmatter(body, file) do
    case String.split(body, "---", parts: 3) do
      [_, yaml, _] ->
        fields =
          for line <- String.split(yaml, "\n"),
              [key, value] <- [String.split(line, ":", parts: 2)],
              into: %{},
              do: {String.trim(key), value |> String.trim() |> String.trim("\"")}

        name = if fields["name"] in [nil, ""], do: Path.rootname(file), else: fields["name"]

        %{"name" => name}
        |> then(
          &if(fields["description"] in [nil, ""],
            do: &1,
            else: Map.put(&1, "description", fields["description"])
          )
        )

      _ ->
        nil
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
  Checks a turn's attachments against Antigravity's limits: text files up to 1 MiB,
  images up to 10 MiB, audio up to 20 MiB, PDFs, and 50 MiB in all. `:ok` or
  `{:error, message}`.
  """
  def check_attachments(attachments) do
    Enum.reduce_while(attachments, {:ok, 0}, fn attachment, {:ok, total} ->
      size = file_size(attachment.path)

      case kind(attachment) do
        nil ->
          {:halt,
           {:error,
            "Antigravity does not support '#{attachment.name}' (#{attachment.mime_type}). Attach a BMP, JPEG, PNG, WebP, PDF, audio, or text file."}}

        kind ->
          if size > limit(kind) or total + size > 50 * @mib,
            do: {:halt, {:error, too_large(attachment.name)}},
            else: {:cont, {:ok, total + size}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp too_large(name),
    do:
      "Attachment '#{name}' is too large. Antigravity accepts text files up to 1 MiB, images up to 10 MiB, audio up to 20 MiB, and 50 MiB total attachments."

  defp limit(:image), do: 10 * @mib
  defp limit(:audio), do: 20 * @mib
  defp limit(:pdf), do: 50 * @mib
  defp limit(:text), do: @mib

  defp kind(%{mime_type: mime, name: name}) do
    mime = String.downcase(mime || "")

    cond do
      mime in @images -> :image
      mime in @audio -> :audio
      mime == "application/pdf" -> :pdf
      String.starts_with?(mime, "text/") or mime in @text_mimes -> :text
      String.downcase(Path.extname(name || "")) in @text_exts -> :text
      true -> nil
    end
  end

  defp file_size(path) do
    case File.stat(path || "") do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  @doc "The prompt blocks carrying a turn's attachments."
  def attachment_blocks(attachments) do
    Enum.flat_map(attachments, fn attachment ->
      case {kind(attachment), File.read(attachment.path || "")} do
        {:image, {:ok, data}} ->
          [
            %{
              "type" => "image",
              "mimeType" => attachment.mime_type,
              "data" => Base.encode64(data)
            }
          ]

        {:audio, {:ok, data}} ->
          [
            %{
              "type" => "audio",
              "mimeType" => attachment.mime_type,
              "data" => Base.encode64(data)
            }
          ]

        {:pdf, {:ok, _}} ->
          [
            %{
              "type" => "resource_link",
              "uri" => "file://" <> attachment.path,
              "name" => attachment.name,
              "mimeType" => "application/pdf"
            }
          ]

        {:text, {:ok, text}} ->
          if String.valid?(text) and not String.contains?(text, <<0>>),
            do: [
              %{
                "type" => "resource",
                "resource" => %{
                  "uri" => "file://" <> attachment.path,
                  "mimeType" => attachment.mime_type || "text/plain",
                  "text" => text
                }
              }
            ],
            else: []

        _ ->
          []
      end
    end)
  end

  # --- tools ----------------------------------------------------------------------

  @doc "Whether a tool call starts Antigravity subagents (not an MCP tool of that name)."
  def subagent?(call) do
    call["title"] in ["Running start_subagent", "Run start_subagent?"] and
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
