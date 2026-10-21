defmodule HalC2.PairTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :home, previous),
        else: Application.delete_env(:hal_c2, :home)
    end)

    %{home: home}
  end

  test "minting ahead of a first start makes the store's directory", %{home: home} do
    refute File.exists?(home)

    assert {:ok, [link]} = HalC2.Pair.command(["http://127.0.0.1:3780"])
    assert String.starts_with?(link, "http://127.0.0.1:3780/?token=")
    assert File.exists?(Path.join(home, "hal-c2.sqlite"))
  end

  test "a refused address is echoed without its credentials" do
    assert {:error, message} = HalC2.Pair.command(["http://user:pass@127.0.0.1:3780"])
    assert message =~ "BASE_URL must be an http or https address"
    refute message =~ "user:pass"
    assert message =~ "redacted@127.0.0.1"
  end

  test "addresses that parse leniently are refused before any token is minted", %{home: home} do
    for address <- [
          "http://host:abc",
          "http://host:",
          "http://host:/path",
          "http://[::1]:",
          "http://exa|mple.com",
          "http://host/\e[31mred"
        ] do
      assert {:error, message} = HalC2.Pair.command([address]), address
      assert message =~ "BASE_URL must be an http or https address", address
      refute message =~ "\e", address
    end

    refute File.exists?(Path.join(home, "hal-c2.sqlite"))
  end

  test "a refused option is named, but echoed printable-only" do
    assert {:error, message} = HalC2.Pair.command(["--tailscale-serve-port=foo"])
    assert message =~ "--tailscale-serve-port=foo"

    assert {:error, message} = HalC2.Pair.command(["--tailscale-serve-port=\e[31mred"])
    assert message =~ "--tailscale-serve-port="
    refute message =~ "\e"
  end

  test "a refused address echoes neither scheme-less credentials nor a token in its query or fragment" do
    for {address, secret} <- [
          {"user:pass@127.0.0.1:3780", "user:pass"},
          {"https://box.example/?token=s3cret", "s3cret"},
          {"https://box.example/#s3cret", "s3cret"}
        ] do
      assert {:error, message} = HalC2.Pair.command([address]), address
      assert message =~ "BASE_URL must be an http or https address", address
      refute message =~ secret, address
    end
  end

  test "pairing the installed MC over Tailscale refuses a mapping that fronts the caller's MC",
       %{tmp_dir: dir} do
    caller_port = fake_mc("caller-id")
    {installed, _port} = cross_profile(dir, fn _ -> "http://127.0.0.2:#{caller_port}" end)

    assert {:error, message} = HalC2.Pair.command(["--release", "--tailscale"])
    assert message =~ "already fronts a different HAL-C2 server"
    refute File.exists?(Path.join(installed.data, "hal-c2.sqlite"))
  end

  test "pairing the installed MC over Tailscale reuses a mapping that fronts it under another address",
       %{tmp_dir: dir} do
    {installed, _port} = cross_profile(dir, &"http://127.0.0.2:#{&1}")

    assert {:ok, [link, _note]} = HalC2.Pair.command(["--release", "--tailscale"])
    assert link =~ "https://box.tail.ts.net/?token="
    assert File.exists?(Path.join(installed.data, "hal-c2.sqlite"))
  end

  test "a mapping is not blessed when neither side has an identity to check", %{tmp_dir: dir} do
    # The installed MC's identity file is empty and it answers "" at its
    # origin, as does the mapping's target: "" must not match "".
    {installed, _port} = cross_profile(dir, &"http://127.0.0.2:#{&1}", "")

    assert {:error, message} = HalC2.Pair.command(["--release", "--tailscale"])
    assert message =~ "could not be verified as this one"
    refute File.exists?(Path.join(installed.data, "hal-c2.sqlite"))
  end

  # A caller in the dev profile (`HalC2.Environment.id/0` answers "caller-id")
  # and an installed MC under a fake user home: its runtime record, its
  # "installed-id" identity file, and a fake answering as it at its recorded
  # origin. Tailscale Serve on 443 already maps to `mapping_target` of the
  # installed MC's port. Returns the installed MC's dirs and port.
  defp cross_profile(dir, mapping_target, installed_id \\ "installed-id") do
    vars =
      ~w(HOME HAL_C2_HOME HAL_C2_MC_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME)

    saved = for name <- vars, do: {name, System.get_env(name)}
    caller_id = :persistent_term.get({HalC2.Environment, :id}, nil)
    tailscale = Application.get_env(:hal_c2, :tailscale_command)

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      if caller_id,
        do: :persistent_term.put({HalC2.Environment, :id}, caller_id),
        else: :persistent_term.erase({HalC2.Environment, :id})

      if tailscale,
        do: Application.put_env(:hal_c2, :tailscale_command, tailscale),
        else: Application.delete_env(:hal_c2, :tailscale_command)
    end)

    for name <- vars -- ["HOME"], do: System.delete_env(name)
    System.put_env("HOME", Path.join(dir, "user"))
    Application.put_env(:hal_c2, :home, :dev)
    :persistent_term.put({HalC2.Environment, :id}, "caller-id")

    installed_port = fake_mc(installed_id)
    dirs = HalC2.Paths.mc_dirs(nil, System.get_env(), HalC2.Paths.user_home())
    File.mkdir_p!(dirs.state)
    File.mkdir_p!(dirs.data)
    File.write!(Path.join(dirs.data, "environment-id"), "#{installed_id}\n")

    record = %{
      "version" => 1,
      "pid" => String.to_integer(System.pid()),
      "port" => installed_port,
      "origin" => "http://127.0.0.1:#{installed_port}",
      "startedAt" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(Path.join(dirs.state, "server-runtime.json"), JSON.encode!(record))

    state = Path.join(dir, "tailscale.json")

    File.write!(
      state,
      JSON.encode!(%{
        "self" => %{"DNSName" => "box.tail.ts.net."},
        "serve" => %{"box.tail.ts.net:443" => mapping_target.(installed_port)}
      })
    )

    Application.put_env(:hal_c2, :tailscale_command, [
      "env",
      "FAKE_TAILSCALE_STATE=#{state}",
      Path.expand("../support/fake_tailscale.py", __DIR__)
    ])

    {dirs, installed_port}
  end

  # A loopback HTTP server answering every request as an MC whose environment
  # id is `id`. Returns its port.
  defp fake_mc(id) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    body = JSON.encode!(%{"environmentId" => id})

    response =
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

    {:ok, _pid} = Task.start(fn -> serve_fake(listen, response) end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    port
  end

  defp serve_fake(listen, response) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        serve_fake(listen, response)

      {:error, _} ->
        :ok
    end
  end
end
