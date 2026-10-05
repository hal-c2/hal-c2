defmodule Mix.Tasks.HalC2.Upgrade do
  @shortdoc "Moves running MCs to this checkout's code"
  @moduledoc """
  Upgrades running MCs from this checkout, in place where the change allows
  (`HalC2.Upgrade`):

      mix hal_c2.upgrade MC [MC ...] [--cookie COOKIE]
      mix hal_c2.upgrade --dev [MC ...] [--cookie COOKIE]
      mix hal_c2.upgrade --release

  Without `--dev`, builds the prod release and its bundle, sends the bundle to the
  first MC, and has each named MC update to it; the others fetch it over HTTP
  from a peer that already has it. MCs must run a release under `bin/hal-c2-service` for changes that
  need a restart.

  With `--dev`, compiles and has MCs run from source (`mix run`) load what
  changed. Without MC names that is the MC `mix hal_c2.server` runs on this machine
  (`mise run mc:reload`), reached over its HTTP port with its access token, so it
  needs no distribution; it loads this checkout's build even when it was started
  from another checkout or worktree.

  With `--release`, builds the prod release under a version of its own and has the
  installed MC on this machine update to it (`mise run mc:reload --release`), over
  its HTTP port with its access token as well. That MC is the one in the user's
  `hal-c2` profile, or in `HAL_C2_MC_HOME` when that is set.

  Named MCs are reached from a hidden short-name node started with `--cookie`, so
  they must run with plain distribution (`elixir --sname ... -S mix hal_c2.server`).
  A cluster's MCs (`HalC2.Cluster`) admit only their members' certificates; update
  them from a client instead.
  """

  use Mix.Task

  @chunk 256 * 1024

  @impl true
  def run(args) do
    {opts, mcs} =
      OptionParser.parse!(args, strict: [dev: :boolean, release: :boolean, cookie: :string])

    mcs = Enum.map(mcs, &String.to_atom/1)

    cond do
      opts[:release] && mcs == [] ->
        # A version of its own: an MC refuses the version it already runs.
        stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
        build("#{Mix.Project.config()[:version]}-local.#{stamp}")
        local_release(Mix.Tasks.HalC2.Bundle.bundle())

      opts[:dev] && mcs == [] ->
        Mix.Task.run("compile")
        local()

      mcs == [] ->
        Mix.raise("Name the MCs to upgrade, e.g. hal_c2_a@my-mac")

      opts[:dev] ->
        Mix.Task.run("compile")
        connect(mcs, opts[:cookie])
        dev(mcs)

      true ->
        build()
        connect(mcs, opts[:cookie])
        release(mcs, Mix.Tasks.HalC2.Bundle.bundle())
    end
  end

  defp build(version \\ nil) do
    # Earlier builds leave their lib/hal_c2-<version> behind, and the bundle packs all of lib/.
    File.rm_rf!("_build/prod/rel/hal_c2")

    {_, 0} =
      System.cmd("mix", ~w(release --overwrite),
        env: [{"MIX_ENV", "prod"}] ++ if(version, do: [{"HAL_C2_MC_VERSION", version}], else: []),
        into: IO.stream(),
        stderr_to_stdout: true
      )
  end

  defp dev(mcs) do
    for mc <- mcs do
      case :erpc.call(mc, HalC2.Upgrade, :reload_checkout, [], 60_000) do
        {:ok, %{changed: changed, needs_restart: restart}} ->
          loaded(mc, Enum.map(changed, &inspect/1), Enum.map(restart, &inspect/1))

        {:error, reason} ->
          Mix.shell().error("#{mc}: #{inspect(reason)}")
      end
    end
  end

  # The MC this checkout runs, through `POST /api/dev/reload`.
  defp local do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:inets)
    base = HalC2.Web.base_url()

    token =
      case File.read(HalC2.Web.token_path()) do
        {:ok, token} ->
          String.trim(token)

        {:error, _} ->
          Mix.raise("No MC has run from #{HalC2.Paths.data_dir()}; start one with `mise run mc`")
      end

    # This checkout's build, so an MC started from another checkout moves to it.
    body = JSON.encode!(%{"build" => Mix.Project.build_path()})

    request =
      {~c"#{base}/api/dev/reload", [{~c"authorization", ~c"Bearer #{token}"}],
       ~c"application/json", body}

    case :httpc.request(:post, request, [timeout: 60_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        report = JSON.decode!(body)
        loaded(base, report["changed"], report["needsRestart"])

      {:ok, {{_, 404, _}, _, _}} ->
        Mix.raise("The MC at #{base} runs from a release; update it with --release")

      {:ok, {{_, 409, _}, _, body}} ->
        Mix.raise("#{base}: #{JSON.decode!(body)["reason"]}")

      {:ok, {{_, status, _}, _, _}} ->
        Mix.raise("#{base} answered #{status}; is it an MC from another home?")

      {:error, _} ->
        Mix.raise("No MC answers at #{base}; start one with `mise run mc`")
    end
  end

  # The installed MC on this machine, through `POST /api/dev/reload` with a bundle.
  defp local_release(path) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:inets)

    # A checkout's own home is the dev profile; the installed MC's is the user's.
    home =
      case Application.get_env(:hal_c2, :home) do
        :dev -> nil
        home -> home
      end

    dirs = HalC2.Paths.mc_dirs(home, System.get_env(), HalC2.Paths.user_home())

    with {:ok, record} <- File.read(Path.join(dirs.state, "server-runtime.json")),
         {:ok, %{"origin" => base}} <- JSON.decode(record),
         {:ok, token} <- File.read(Path.join(dirs.data, "access-token")) do
      body = JSON.encode!(%{"bundle" => path, "version" => manifest(path)["version"]})

      request =
        {~c"#{base}/api/dev/reload", [{~c"authorization", ~c"Bearer #{String.trim(token)}"}],
         ~c"application/json", body}

      case :httpc.request(:post, request, [timeout: :timer.minutes(15)], body_format: :binary) do
        {:ok, {{_, 200, _}, _, body}} ->
          result = JSON.decode!(body)
          Mix.shell().info("#{base}: #{result["method"]} to #{result["targetVersion"]}")

        {:ok, {{_, 409, _}, _, body}} ->
          Mix.raise("#{base}: #{JSON.decode!(body)["reason"]}")

        {:ok, {{_, 404, _}, _, _}} ->
          Mix.raise(
            "The MC at #{base} runs from a checkout, or a release too old to update this way"
          )

        {:ok, {{_, status, _}, _, _}} ->
          Mix.raise("#{base} answered #{status}; is it an MC from another home?")

        {:error, _} ->
          Mix.raise("No MC answers at #{base}; is the installed MC running?")
      end
    else
      _ -> Mix.raise("No installed MC has run from #{dirs.data}")
    end
  end

  defp loaded(mc, changed, restart) do
    Mix.shell().info("#{mc}: loaded #{length(changed)} modules")
    if restart != [], do: Mix.shell().info("#{mc}: restart for #{Enum.join(restart, ", ")}")
  end

  @doc false
  # Sends the bundle at `path` to the MCs (`roll_out/2`) and prints each reply.
  def release(mcs, path) do
    for {mc, reply} <- roll_out(mcs, path) do
      case reply do
        {:ok, result} ->
          Mix.shell().info("#{mc}: #{result["method"]} to #{result["targetVersion"]}")

        {:error, %{"reason" => reason}} ->
          Mix.shell().error("#{mc}: #{reason}")
      end
    end
  end

  @doc """
  Sends the bundle at `path` to the first of `mcs` and has each update to it, in
  order; the others fetch it from a peer that has it. Returns each MC's reply.
  """
  def roll_out([first | _] = mcs, path) do
    manifest = manifest(path)
    version = manifest["version"]
    send_bundle(first, version, manifest["platform"], path)

    for mc <- mcs do
      input = [%{"targetVersion" => version}]
      {mc, :erpc.call(mc, HalC2.Upgrade, :update, input, :timer.minutes(15))}
    end
  end

  defp send_bundle(mc, version, platform, path) do
    :ok = :erpc.call(mc, HalC2.Upgrade.Source, :receive_part, [version, platform, :begin])

    path
    |> File.stream!(@chunk)
    |> Enum.each(fn data ->
      :ok =
        :erpc.call(mc, HalC2.Upgrade.Source, :receive_part, [version, platform, {:chunk, data}])
    end)

    sum = (path <> ".sha256") |> File.read!() |> String.split() |> List.first()

    :ok =
      :erpc.call(mc, HalC2.Upgrade.Source, :receive_part, [version, platform, {:finish, sum}])
  end

  defp manifest(path) do
    {:ok, files} = :erl_tar.extract(String.to_charlist(path), [:compressed, :memory])

    Enum.find_value(files, fn {name, data} ->
      if String.ends_with?(to_string(name), "upgrade.json"), do: JSON.decode!(data)
    end)
  end

  defp connect(mcs, cookie) do
    unless Node.alive?() do
      name = :"hal_c2_upgrade#{System.unique_integer([:positive])}"
      {:ok, _} = Node.start(name, name_domain: :shortnames, hidden: true)
    end

    if cookie, do: Node.set_cookie(String.to_atom(cookie))

    for mc <- mcs, do: Node.connect(mc) || Mix.raise("Could not reach #{mc}")
  end
end
