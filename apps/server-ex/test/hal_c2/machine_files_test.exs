defmodule HalC2.MachineFilesTest do
  # Uses app env to reach the fake helper.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HalC2.MachineFiles

  # The helper as this test plays it: the test process is its port, so what the MC
  # sends it arrives here and what it sends the MC is sent from here.
  defmodule FakeHelper do
    @moduledoc false
    def available, do: Application.get_env(:hal_c2, :machine_files_fake_available, :ok)
    def prepare(_root), do: :ok
    def unmount(_root), do: :ok
    def close(_port), do: :ok

    def open(root, _opts) do
      test = Application.fetch_env!(:hal_c2, :machine_files_fake)
      Kernel.send(test, {:opened, root})
      {:ok, test, 4242}
    end

    def send(test, iodata), do: Kernel.send(test, {:to_helper, IO.iodata_to_binary(iodata)})
  end

  @root "/state/machines"
  @devbox %{"environmentId" => "env-devbox", "label" => "devbox"}

  setup do
    Application.put_env(:hal_c2, :machine_files_fake, self())

    on_exit(fn ->
      Application.delete_env(:hal_c2, :machine_files_fake)
      Application.delete_env(:hal_c2, :machine_files_fake_available)
    end)

    {:ok, cluster} = Agent.start_link(fn -> [] end)
    %{cluster: cluster}
  end

  defp start(%{cluster: cluster}) do
    start_supervised!(
      {MachineFiles,
       enabled: true,
       subscribe: false,
       name: nil,
       root: @root,
       helper: FakeHelper,
       environments: fn -> Agent.get(cluster, & &1) end}
    )
  end

  # The cluster changes as `HalC2.Shell` would tell of it.
  defp put_cluster(%{cluster: cluster}, server, environments) do
    Agent.update(cluster, fn _ -> environments end)
    send(server, {:hal_c2_shell, {:mc, :changed, :up}})
    MachineFiles.sync(server)
  end

  defp t(server, tag, type, body) do
    send(
      server,
      {self(), {:data, <<byte_size(body) + 7::32-little, type, tag::16-little>> <> body}}
    )

    assert_receive {:to_helper, <<_size::32-little, kind, ^tag::16-little, reply::binary>>}, 5_000
    {kind, reply}
  end

  defp s(value), do: <<byte_size(value)::16-little>> <> value

  defp attach(server) do
    {101, _} = t(server, 0xFFFF, 100, <<8192::32-little>> <> s("9P2000.L"))

    {105, _} =
      t(
        server,
        1,
        104,
        <<0::32-little, 0xFFFFFFFF::32-little>> <> s("me") <> s("") <> <<1000::32-little>>
      )

    :ok = MachineFiles.await_ready(server)
  end

  defp walk(server, fid \\ 0, newfid, names) do
    body =
      <<fid::32-little, newfid::32-little, length(names)::16-little>> <>
        Enum.map_join(names, &s/1)

    t(server, 2, 110, body)
  end

  test "names each member's folder after its label, apart when two share one" do
    folders =
      MachineFiles.folders([
        {:a@h, %{"environmentId" => "aaaaaaaa-1", "label" => "devbox"}},
        {:b@h, %{"environmentId" => "bbbbbbbb-2", "label" => "devbox"}},
        {:c@h, %{"environmentId" => "cccccccc-3", "label" => "lab/one"}},
        {:d@h, %{"environmentId" => "dddddddd-4", "label" => ".."}}
      ])

    assert Map.keys(folders) |> Enum.sort() ==
             ["dddddddd-4", "devbox-aaaaaaaa", "devbox-bbbbbbbb", "lab-one"]
  end

  test "no member's folder takes another's name" do
    members = [
      {:a@h, %{"environmentId" => "aaaaaaaa-1", "label" => "devbox"}},
      {:b@h, %{"environmentId" => "bbbbbbbb-2", "label" => "devbox"}},
      {:c@h, %{"environmentId" => "cccccccc-3", "label" => "devbox-aaaaaaaa"}}
    ]

    folders = MachineFiles.folders(members)
    assert map_size(folders) == 3
    assert folders["devbox-aaaaaaaa"].node == :a@h
    assert folders["devbox-aaaaaaaa-cccccccc-3"].node == :c@h
    assert MachineFiles.folders(Enum.reverse(members)) == folders
  end

  test "a member's folder appears when it joins and goes when it is removed", ctx do
    server = start(ctx)

    assert MachineFiles.local_path("env-devbox", "/home/me/shop/a.ts", server) ==
             {:error, :not_a_member, nil}

    # Nothing is mounted for a cluster of one.
    refute_received {:opened, _}

    put_cluster(ctx, server, [{node(), @devbox}])
    assert_received {:opened, @root}

    assert MachineFiles.local_path("env-devbox", "/home/me/shop/a.ts", server) ==
             {:error, :not_ready, "devbox"}

    attach(server)
    assert {111, <<1::16-little, _qid::binary-size(13)>>} = walk(server, 1, ["devbox"])

    assert MachineFiles.local_path("env-devbox", "/home/me/shop/a.ts", server) ==
             {:ok, "/state/machines/devbox/home/me/shop/a.ts"}

    put_cluster(ctx, server, [])
    assert {7, <<2::32-little>>} = walk(server, 2, ["devbox"])

    assert MachineFiles.local_path("env-devbox", "/home/me/shop/a.ts", server) ==
             {:error, :not_a_member, nil}
  end

  test "a member that is down fails what is asked of it at once, and is said so once", ctx do
    server = start(ctx)
    put_cluster(ctx, server, [{:devbox@nowhere, @devbox}])
    attach(server)

    # The folder itself is this machine's; what is in it is the member's.
    assert {111, <<1::16-little, _qid::binary-size(13)>>} = walk(server, 1, ["devbox"])

    log =
      capture_log(fn ->
        assert {7, <<112::32-little>>} = walk(server, 1, 2, ["home"])
        assert {7, <<112::32-little>>} = walk(server, 1, 2, ["home", "me"])
      end)

    assert length(String.split(log, "devbox is unavailable")) == 2

    assert MachineFiles.local_path("env-devbox", "/home/me/a.ts", server) ==
             {:error, :unavailable, "devbox"}

    assert MachineFiles.message(:unavailable, "devbox") ==
             "The file is on \"devbox\". \"devbox\" is unavailable."
  end

  test "a helper that exits is started again, with a new connection", ctx do
    server = start(ctx)
    put_cluster(ctx, server, [{node(), @devbox}])
    assert_received {:opened, @root}
    attach(server)

    capture_log(fn ->
      send(server, {self(), {:exit_status, 1}})
      assert_receive {:opened, @root}, 5_000
    end)

    assert MachineFiles.local_path("env-devbox", "/home/me/a.ts", server) ==
             {:error, :not_ready, "devbox"}

    # The new helper's fids start over: the old one's are gone.
    {101, _} = t(server, 0xFFFF, 100, <<8192::32-little>> <> s("9P2000.L"))
    assert {7, <<9::32-little>>} = walk(server, 1, ["devbox"])
  end

  test "a machine without FUSE says what to install", ctx do
    Application.put_env(:hal_c2, :machine_files_fake_available, {:error, :no_fuse})
    server = start(ctx)

    capture_log(fn -> put_cluster(ctx, server, [{node(), @devbox}]) end)
    refute_received {:opened, _}

    assert {:error, :no_fuse} = MachineFiles.await_ready(server)

    assert MachineFiles.local_path("env-devbox", "/home/me/a.ts", server) ==
             {:error, :no_fuse, "devbox"}

    assert MachineFiles.message(:no_fuse, "devbox") ==
             "The file is on \"devbox\". To open it here, install FUSE 3 (fuse3)."
  end

  test "files.localPath answers with the path, or the reason and the machine", ctx do
    server = start(ctx)
    put_cluster(ctx, server, [{node(), @devbox}])
    input = %{"environmentId" => "env-devbox", "path" => "/home/me/shop/../shop/a.ts"}

    assert MachineFiles.handle_rpc(input, server) ==
             {:ok,
              %{
                "reason" => "not_ready",
                "machine" => "devbox",
                "message" => MachineFiles.message(:not_ready, "devbox")
              }}

    attach(server)

    assert MachineFiles.handle_rpc(input, server) ==
             {:ok, %{"path" => "/state/machines/devbox/home/me/shop/a.ts"}}

    assert {:ok, %{"reason" => "not_a_member"} = answer} =
             MachineFiles.handle_rpc(%{input | "environmentId" => "env-other"}, server)

    refute Map.has_key?(answer, "machine")

    assert {:error, %{"_tag" => "FilesLocalPathError", "path" => "shop/a.ts"}} =
             MachineFiles.handle_rpc(%{input | "path" => "shop/a.ts"}, server)
  end

  test "this machine's own files are where they are" do
    assert MachineFiles.local_path(HalC2.Environment.id(), "/home/me/a.ts") ==
             {:ok, "/home/me/a.ts"}
  end
end
