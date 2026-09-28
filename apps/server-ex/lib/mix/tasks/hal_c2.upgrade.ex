defmodule Mix.Tasks.HalC2.Upgrade do
  @shortdoc "Moves running nodes to this checkout's code"
  @moduledoc """
  Upgrades running nodes from this checkout, in place where the change allows
  (`HalC2.Upgrade`):

      mix hal_c2.upgrade NODE [NODE ...] [--cookie COOKIE]
      mix hal_c2.upgrade --dev [NODE ...] [--cookie COOKIE]

  Without `--dev`, builds the prod release and its bundle, sends the bundle to the
  first node, and has each named node update to it; the others fetch it over HTTP
  from a peer that already has it. Nodes must run a release under `bin/hal-c2-service` for changes that
  need a restart.

  With `--dev`, compiles and has nodes started from this checkout (`mix run`)
  load what changed. Without node names that is the node `mix hal_c2.server` runs
  here (`mise run node:reload`), reached over its HTTP port with its access token, so
  it needs no distribution.

  Named nodes are reached from a hidden short-name node started with `--cookie`, so
  they must run with plain distribution (`elixir --sname ... -S mix hal_c2.server`).
  A cluster's nodes (`HalC2.Cluster`) admit only their members' certificates; update
  them from a client instead.
  """

  use Mix.Task

  @chunk 256 * 1024

  @impl true
  def run(args) do
    {opts, nodes} = OptionParser.parse!(args, strict: [dev: :boolean, cookie: :string])
    nodes = Enum.map(nodes, &String.to_atom/1)

    cond do
      opts[:dev] && nodes == [] ->
        Mix.Task.run("compile")
        local()

      nodes == [] ->
        Mix.raise("Name the nodes to upgrade, e.g. hal_c2_a@my-mac")

      opts[:dev] ->
        Mix.Task.run("compile")
        connect(nodes, opts[:cookie])
        dev(nodes)

      true ->
        build()
        connect(nodes, opts[:cookie])
        release(nodes, Mix.Tasks.HalC2.Bundle.bundle())
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

  defp dev(nodes) do
    for node <- nodes do
      case :erpc.call(node, HalC2.Upgrade, :reload_checkout, [], 60_000) do
        {:ok, %{changed: changed, needs_restart: restart}} ->
          loaded(node, Enum.map(changed, &inspect/1), Enum.map(restart, &inspect/1))

        {:error, reason} ->
          Mix.shell().error("#{node}: #{inspect(reason)}")
      end
    end
  end

  # The node this checkout runs, through `POST /api/dev/reload`.
  defp local do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:inets)
    base = HalC2.Web.base_url()

    token =
      case File.read(HalC2.Web.token_path()) do
        {:ok, token} ->
          String.trim(token)

        {:error, _} ->
          Mix.raise(
            "No node has run from #{HalC2.Paths.data_dir()}; start one with `mise run node`"
          )
      end

    request = {~c"#{base}/api/dev/reload", [{~c"authorization", ~c"Bearer #{token}"}], ~c"", ""}

    case :httpc.request(:post, request, [timeout: 60_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        report = JSON.decode!(body)
        loaded(base, report["changed"], report["needsRestart"])

      {:ok, {{_, 404, _}, _, _}} ->
        Mix.raise("The node at #{base} runs from a release; name it to upgrade it")

      {:ok, {{_, 409, _}, _, body}} ->
        Mix.raise("#{base}: #{JSON.decode!(body)["reason"]}")

      {:ok, {{_, status, _}, _, _}} ->
        Mix.raise("#{base} answered #{status}; is it a node from another home?")

      {:error, _} ->
        Mix.raise("No node answers at #{base}; start one with `mise run node`")
    end
  end

  defp loaded(node, changed, restart) do
    Mix.shell().info("#{node}: loaded #{length(changed)} modules")
    if restart != [], do: Mix.shell().info("#{node}: restart for #{Enum.join(restart, ", ")}")
  end

  @doc false
  # Sends the bundle at `path` to the nodes (`roll_out/2`) and prints each reply.
  def release(nodes, path) do
    for {node, reply} <- roll_out(nodes, path) do
      case reply do
        {:ok, result} ->
          Mix.shell().info("#{node}: #{result["method"]} to #{result["targetVersion"]}")

        {:error, %{"reason" => reason}} ->
          Mix.shell().error("#{node}: #{reason}")
      end
    end
  end

  @doc """
  Sends the bundle at `path` to the first of `nodes` and has each update to it, in
  order; the others fetch it from a peer that has it. Returns each node's reply.
  """
  def roll_out([first | _] = nodes, path) do
    manifest = manifest(path)
    version = manifest["version"]
    send_bundle(first, version, manifest["platform"], path)

    for node <- nodes do
      input = [%{"targetVersion" => version}]
      {node, :erpc.call(node, HalC2.Upgrade, :update, input, :timer.minutes(15))}
    end
  end

  defp send_bundle(node, version, platform, path) do
    :ok = :erpc.call(node, HalC2.Upgrade.Source, :receive_part, [version, platform, :begin])

    path
    |> File.stream!(@chunk)
    |> Enum.each(fn data ->
      :ok =
        :erpc.call(node, HalC2.Upgrade.Source, :receive_part, [version, platform, {:chunk, data}])
    end)

    sum = (path <> ".sha256") |> File.read!() |> String.split() |> List.first()

    :ok =
      :erpc.call(node, HalC2.Upgrade.Source, :receive_part, [version, platform, {:finish, sum}])
  end

  defp manifest(path) do
    {:ok, files} = :erl_tar.extract(String.to_charlist(path), [:compressed, :memory])

    Enum.find_value(files, fn {name, data} ->
      if String.ends_with?(to_string(name), "upgrade.json"), do: JSON.decode!(data)
    end)
  end

  defp connect(nodes, cookie) do
    unless Node.alive?() do
      name = :"hal_c2_upgrade#{System.unique_integer([:positive])}"
      {:ok, _} = Node.start(name, name_domain: :shortnames, hidden: true)
    end

    if cookie, do: Node.set_cookie(String.to_atom(cookie))

    for node <- nodes, do: Node.connect(node) || Mix.raise("Could not reach #{node}")
  end
end
