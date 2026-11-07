defmodule HalC2.Test.CloneGate do
  @moduledoc """
  Real `git clone`s a test holds and releases (`clone_gate.py`): as an `ext::`
  transport the gate holds the fetch, as a smudge filter the checkout of a file. A
  held gate is a receipt that git is at that point, so tests never wait on time.

      port = CloneGate.listen()
      url = CloneGate.transport_url(port, "shop", CloneGate.repo(dir, %{"README.md" => "hi"}))
      # ... start a clone of url ...
      gate = CloneGate.await("shop")
      CloneGate.release(gate, "ok")   # or any other line, which git fails with
  """

  @script Path.expand("clone_gate.py", __DIR__)

  @doc "Listens for gates; each one that connects is sent to `owner` as `{:clone_gate, token, socket}`."
  def listen(owner \\ self()) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    acceptor = spawn(fn -> accept(listen, owner) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)

    # Gone with its owner, which needs no cleanup; the gates it holds close with it.
    spawn(fn ->
      ref = Process.monitor(owner)
      receive do: ({:DOWN, ^ref, _, _, _} -> Process.exit(acceptor, :kill))
    end)

    Process.put({__MODULE__, :acceptors}, [acceptor | Process.get({__MODULE__, :acceptors}, [])])
    port
  end

  @doc "Stops the listeners this process started; held gates fail once their sockets close."
  def stop do
    for acceptor <- Process.delete({__MODULE__, :acceptors}) || [],
        do: Process.exit(acceptor, :kill)

    :ok
  end

  defp accept(listen, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
             :ok <- :gen_tcp.controlling_process(socket, owner) do
          send(owner, {:clone_gate, String.trim(line), socket})
        end

        accept(listen, owner)

      {:error, _} ->
        :ok
    end
  end

  @doc "A clone address whose fetch waits at gate `token`, then serves the repository `bare`."
  def transport_url(port, token, bare),
    do: "ext::python3 #{@script} #{port} #{token} %S #{bare}"

  @doc "A smudge filter command whose files wait at gate `token` (`\"@cwd\"`: the name of the folder checked out)."
  def smudge(port, token), do: "python3 #{@script} #{port} #{token}"

  @doc "The socket of gate `token` once git reaches it."
  def await(token, timeout \\ 10_000) do
    receive do
      {:clone_gate, ^token, socket} -> socket
    after
      timeout -> raise "git never reached the gate #{token}"
    end
  end

  @doc "Lets a held git go on (`\"ok\"`) or fails it with `verdict` as its error."
  def release(socket, verdict) do
    :ok = :gen_tcp.send(socket, verdict <> "\n")
    :gen_tcp.close(socket)
  end

  @doc """
  A bare repository with one commit of `files` (path => content), made under `dir`
  at `bare` (by default a fresh name); returns its path.
  """
  def repo(dir, files, bare \\ nil) do
    work = Path.join(dir, "work-#{System.unique_integer([:positive])}")
    bare = bare || work <> ".git"

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(work, path)))
      File.write!(Path.join(work, path), content)
    end

    git(["init", "-q", "-b", "main", work])
    git(["-C", work, "add", "-A"])

    git([
      "-C",
      work,
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "init"
    ])

    git(["clone", "-q", "--bare", work, bare])
    bare
  end

  defp git(args) do
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  @doc """
  Sets git configuration (`key => value`) for every git this VM runs, through
  `GIT_CONFIG_COUNT`; returns a function that takes it away again.
  """
  def git_config(config) do
    vars =
      config
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, value}, i} ->
        [{"GIT_CONFIG_KEY_#{i}", key}, {"GIT_CONFIG_VALUE_#{i}", value}]
      end)
      |> Kernel.++([{"GIT_CONFIG_COUNT", Integer.to_string(map_size(config))}])

    System.put_env(vars)
    fn -> Enum.each(vars, fn {name, _} -> System.delete_env(name) end) end
  end
end
