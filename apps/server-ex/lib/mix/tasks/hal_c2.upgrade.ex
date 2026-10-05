defmodule Mix.Tasks.HalC2.Upgrade do
  @shortdoc "Moves running MCs to this checkout's code"
  @moduledoc """
  Upgrades running MCs from this checkout, in place where the change allows
  (`HalC2.Upgrade`):

      mix hal_c2.upgrade MC [MC ...] [--cookie COOKIE]
      mix hal_c2.upgrade --dev [MC ...] [--cookie COOKIE]

  Without `--dev`, builds the prod release and its bundle, sends the bundle to the
  first MC, and has each named MC update to it; the others fetch it over HTTP
  from a peer that already has it. MCs must run a release under `bin/hal-c2-service` for changes that
  need a restart.

  With `--dev`, compiles and has MCs run from source (`mix run`) load what
  changed. Without MC names that is the MC `mix hal_c2.server` runs on this machine
  (`mise run mc:reload`), reached over its HTTP port with its access token, so it
  needs no distribution; it loads this checkout's build even when it was started
  from another checkout or worktree.

  Named MCs are reached from a hidden short-name node started with `--cookie`, so
  they must run with plain distribution (`elixir --sname ... -S mix hal_c2.server`).
  A cluster's MCs (`HalC2.Cluster`) admit only their members' certificates; update
  them from a client instead.
  """

  use Mix.Task

  @chunk 256 * 1024

  @impl true
  def run(args) do
    {opts, mcs} = OptionParser.parse!(args, strict: [dev: :boolean, cookie: :string])
    mcs = Enum.map(mcs, &String.to_atom/1)

    cond do
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

  defp build do
    {_, 0} =
      System.cmd("mix", ~w(release --overwrite),
        env: [{"MIX_ENV", "prod"}],
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
        Mix.raise("The MC at #{base} runs from a release; name it to upgrade it")

      {:ok, {{_, 409, _}, _, body}} ->
        Mix.raise("#{base}: #{JSON.decode!(body)["reason"]}")

      {:ok, {{_, status, _}, _, _}} ->
        Mix.raise("#{base} answered #{status}; is it an MC from another home?")

      {:error, _} ->
        Mix.raise("No MC answers at #{base}; start one with `mise run mc`")
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
