defmodule HalC2.MixProject do
  use Mix.Project

  def project do
    [
      app: :hal_c2,
      # MCs carry the HAL-C2 version, so clients compare them like any server.
      version: hal_c2_version(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      # Step definitions are Cucumber glue, loaded by test_helper.exs, not test files.
      test_ignore_filters: [~r{^test/steps/}],
      aliases: [features: &features/1],
      deps: deps(),
      releases: [
        hal_c2: [
          include_executables_for: [:unix],
          strip_beams: true,
          steps: [:assemble, &stage_cursor_acp/1, &write_upgrade_manifest/1]
        ]
      ]
    ]
  end

  def cli, do: [preferred_envs: [features: :test]]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {HalC2.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:cucumber, "~> 1.0", only: :test},
      {:erlexec, "~> 2.5"},
      {:exile, "~> 0.15"},
      {:exqlite, "~> 0.41"},
      {:mint_web_socket, "~> 1.0"},
      {:tz, "~> 0.28"},
      {:websock_adapter, "~> 0.6"},
      {:x509, "~> 0.9"}
    ]
  end

  # The Cursor sidecar (packages/cursor-acp) ships in the release's priv/, bundled to
  # plain JavaScript so any Node 22+ runs it, including an Electron binary. Its SDK is
  # installed flat by npm (no symlinks, this platform's native package only), so the
  # tree survives copying into an app bundle and code signing.
  defp stage_cursor_acp(release) do
    root = Path.expand("../..", __DIR__)
    package = Path.join(root, "packages/cursor-acp")
    target = Path.join([release.path, "lib", "hal_c2-#{release.version}", "priv", "cursor-acp"])
    File.rm_rf!(target)
    File.mkdir_p!(target)

    %{"dependencies" => deps} =
      package |> Path.join("package.json") |> File.read!() |> JSON.decode!()

    manifest = %{"private" => true, "type" => "module", "dependencies" => deps}
    File.write!(Path.join(target, "package.json"), JSON.encode!(manifest))
    run!("npm", ~w(install --omit=dev --no-audit --no-fund --no-bin-links), target)

    run!(
      Path.join(package, "node_modules/.bin/esbuild"),
      ~w(src/main.ts --bundle --platform=node --format=esm --external:@cursor/sdk) ++
        ["--outfile=#{target}/main.mjs"],
      package
    )

    release
  end

  # `mix features [--backlog] [glob ...] [-- mix test args]` runs the repo's `@mc`
  # Gherkin scenarios (`features/`) and nothing else. Globs are relative to `features/`
  # and default to every file; `--backlog` (or INCLUDE_BACKLOG=1) also runs the
  # `@backlog` and `@backlog-mc` ones. See test/support/features.ex.
  defp features(args) do
    {ours, rest} = Enum.split_while(args, &(&1 != "--"))
    {flags, globs} = Enum.split_with(ours, &(&1 == "--backlog"))
    if globs != [], do: System.put_env("HAL_C2_FEATURES", Enum.join(globs, ","))
    System.put_env("HAL_C2_FEATURES", System.get_env("HAL_C2_FEATURES") || "**/*.feature")

    if flags != [] or System.get_env("INCLUDE_BACKLOG") in ["1", "true"],
      do: System.put_env("HAL_C2_FEATURES_BACKLOG", "1")

    Mix.env(:test)
    Mix.Task.run("test", ["--only", "cucumber" | Enum.drop(rest, 1)])
  end

  # `HAL_C2_MC_VERSION` names a build apart from the package's release (nightlies, local builds).
  defp hal_c2_version do
    System.get_env("HAL_C2_MC_VERSION") || package_version()
  end

  defp package_version do
    Path.expand("../server/package.json", __DIR__)
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("version")
  end

  # What a running MC compares with a new release to decide whether it can load
  # the new code in place (`HalC2.Upgrade`): which applications are HAL-C2's own code,
  # and what that code runs on, each part of which only a restart can change.
  defp write_upgrade_manifest(release) do
    rel = Path.join([release.path, "releases", release.version])
    own = Path.join([release.path, "lib", "hal_c2-#{release.version}"])

    digest = fn paths ->
      paths
      |> Enum.sort()
      # sys.config names its own release directory, which changes with every version.
      |> Enum.map(
        &{Path.relative_to(&1, release.path) |> String.replace(release.version, "{version}"),
         &1 |> File.read!() |> String.replace(release.version, "{version}")}
      )
      |> :erlang.term_to_binary()
      |> then(&Base.encode16(:crypto.hash(:sha256, &1), case: :lower))
    end

    # From the release itself: `lib/` can hold other versions' directories.
    versions = fn apps ->
      for {name, properties} <- apps,
          into: %{},
          do: {to_string(name), to_string(properties[:vsn])}
    end

    manifest = %{
      "version" => release.version,
      "otpRelease" => to_string(:erlang.system_info(:otp_release)),
      "erts" => release.erts_version |> to_string(),
      "platform" => platform(),
      "applications" => versions.(release.applications),
      "code" => ["hal_c2"],
      # Erlang's own applications come with the runtime, whose patch releases the
      # code does not depend on.
      "dependencies" =>
        versions.(
          for {name, properties} = app <- release.applications,
              name != :hal_c2 and not properties[:otp_app?],
              do: app
        ),
      # Packages installed for the build machine's platform, which no other can use.
      "packages" => digest.([Path.join(own, "priv/cursor-acp/package.json")]),
      "config" =>
        digest.(
          for f <- ~w(sys.config runtime.exs vm.args),
              File.exists?(Path.join(rel, f)),
              do: Path.join(rel, f)
        )
    }

    File.write!(Path.join(rel, "upgrade.json"), JSON.encode!(manifest))
    release
  end

  defp platform do
    os = :os.type() |> elem(1) |> to_string()
    arch = :erlang.system_info(:system_architecture) |> to_string()

    arch =
      cond do
        arch =~ ~r/aarch64|arm64/ -> "arm64"
        arch =~ ~r/x86_64|amd64/ -> "x64"
        true -> arch
      end

    "#{os}-#{arch}"
  end

  defp run!(command, args, cd) do
    {_, 0} = System.cmd(command, args, cd: cd, into: IO.stream(), stderr_to_stdout: true)
  end
end
