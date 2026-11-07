defmodule HalC2.ThreadArchiveTest do
  # An import that fails takes back what it placed, and only that.
  use ExUnit.Case, async: false

  alias HalC2.ThreadArchive
  alias HalC2.Test.{Machines, Mc}
  alias HalC2.Test.Mc.World

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @checkpoints "refs/hal-c2/orchestration-v2/checkpoints/th-cart"

  setup %{tmp_dir: dir} do
    previous = System.get_env("CODEX_HOME")
    codex = Path.join(dir, "codex")
    System.put_env("CODEX_HOME", codex)
    context = %{mc: Mc.start(Path.join(dir, "mc")), clients: %{}, projects: %{}, threads: %{}}
    context = World.create_project(context, "shop")
    root = World.project(context, "shop").root
    World.git!(root, ~w(remote add origin git@github.com:acme/shop.git))

    on_exit(fn ->
      Application.delete_env(:hal_c2, :store_hook)

      if previous,
        do: System.put_env("CODEX_HOME", previous),
        else: System.delete_env("CODEX_HOME")
    end)

    %{context: context, root: root, codex: codex}
  end

  test "a failed import takes back the checkpoints and the session it placed and keeps what was there",
       %{context: context, root: root, codex: codex} do
    # The thread's checkpoints: one new here, one this checkout points elsewhere, and
    # one of another thread the import never names.
    source = World.git_repo(context, "laptop-shop")
    World.git!(source, ~w(commit -q --allow-empty -m run-1))
    run1 = World.git!(source, ~w(rev-parse HEAD))
    World.git!(source, ~w(commit -q --allow-empty -m run-2))
    run2 = World.git!(source, ~w(rev-parse HEAD))
    World.git!(source, ["update-ref", "#{@checkpoints}/1", run1])
    World.git!(source, ["update-ref", "#{@checkpoints}/2", run2])
    bundle = Path.join(context.mc.home, "checkpoints.bundle")

    World.git!(source, [
      "bundle",
      "create",
      "-q",
      bundle,
      "#{@checkpoints}/1",
      "#{@checkpoints}/2"
    ])

    head = World.git!(root, ~w(rev-parse HEAD))
    World.git!(root, ["update-ref", "#{@checkpoints}/2", head])
    World.git!(root, ["update-ref", "refs/hal-c2/orchestration-v2/checkpoints/th-other/1", head])
    refs_before = World.git!(root, ~w(for-each-ref refs/hal-c2))

    # The session: its rollout is new here, the index Codex keeps already is.
    rollout = "sessions/2026/09/26/rollout-2026-09-26T10-00-00-abc.jsonl"
    File.mkdir_p!(codex)
    File.write!(Path.join(codex, "session_index.jsonl"), "mine\n")

    archive =
      archive(root, %{
        "checkpoints" => %{
          "refs" => ["#{@checkpoints}/1", "#{@checkpoints}/2"],
          "bundle" => file("checkpoints.bundle", File.read!(bundle))
        },
        "session" => %{
          "driver" => "codex",
          "instanceId" => "codex",
          "providerThreadId" => "pt-cart",
          "nativeId" => "abc",
          "cwd" => "/home/a/code/shop",
          "files" => [
            file(rollout, ~s({"type":"session_meta","payload":{"id":"abc"}}\n)),
            file("session_index.jsonl", "theirs\n")
          ]
        }
      })

    Application.put_env(:hal_c2, :store_hook, {Machines, :refuse_change, ["th-cart"]})

    assert ThreadArchive.import_archive(archive, project: "shop") ==
             {:error, "The import of Cart failed: the disk is full. Nothing was imported."}

    assert World.git!(root, ~w(for-each-ref refs/hal-c2)) == refs_before
    refute File.exists?(Path.join(codex, "sessions"))
    assert File.read!(Path.join(codex, "session_index.jsonl")) == "mine\n"
    assert ThreadArchive.local_thread("th-cart") == nil
  end

  test "a thread from an earlier install reaches the store in one write", %{root: root} do
    # Room for five changes: its four entities fit in one write. An import that stored
    # its events (five changes) and then took its provider thread's session in a write
    # of its own ran out between the two and kept the events.
    room = :counters.new(1, [])
    :counters.put(room, 1, 5)
    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :room, [room, "th-legacy"]})

    assert {:ok, %{thread: "th-legacy", session: false}} =
             ThreadArchive.import_archive(legacy(root), project: "shop")

    assert %{"title" => "Legacy"} = ThreadArchive.local_thread("th-legacy")

    [pt] = Machines.entities("th-legacy", "provider-thread")
    assert pt["nativeThreadRef"] == nil
  end

  test "a thread from an earlier install that cannot be stored leaves no event behind",
       %{root: root} do
    Application.put_env(:hal_c2, :store_hook, {Machines, :refuse_change, ["th-legacy"]})

    assert ThreadArchive.import_archive(legacy(root), project: "shop") ==
             {:error, "The import of Legacy failed: the disk is full. Nothing was imported."}

    refute Enum.any?(HalC2.Store.list_streams(HalC2.Store.path()), &(&1.id == "th-legacy"))
    assert ThreadArchive.local_thread("th-legacy") == nil
  end

  @doc false
  def room(room, id, :append_change, id) do
    if self() == Process.whereis(HalC2.Store) do
      if :counters.get(room, 1) == 0, do: raise("the disk is full")
      :counters.sub(room, 1, 1)
    end

    :ok
  end

  def room(_room, _id, _stage, _stream_id), do: :ok

  defp archive(root, fields) do
    Map.merge(
      %{
        "format" => "hal-c2-thread-export",
        "version" => 2,
        "thread" => %{
          "id" => "th-cart",
          "title" => "Cart",
          "projectId" => "shop-laptop",
          "projectRoot" => "/home/a/code/shop",
          "repository" => ThreadArchive.repository(root),
          "machine" => "laptop"
        },
        "updatedAt" => System.os_time(:millisecond),
        "entities" => [
          [
            "thread",
            "th-cart",
            %{"id" => "th-cart", "title" => "Cart", "projectId" => "shop-laptop"}
          ],
          [
            "provider-thread",
            "pt-cart",
            %{"id" => "pt-cart", "appThreadId" => "th-cart", "driver" => "codex"}
          ]
        ],
        "attachments" => [],
        "terminalLogs" => [],
        "checkpoints" => nil,
        "worktree" => nil,
        "session" => nil
      },
      fields
    )
  end

  # Four events, one entity each, as an earlier install exported them.
  defp legacy(root) do
    at = "2026-09-01T00:00:00.000Z"
    id = "th-legacy"

    events = [
      event(id, "thread.created", %{
        "id" => id,
        "title" => "Legacy",
        "projectId" => "shop-old",
        "createdAt" => at,
        "updatedAt" => at
      }),
      event(id, "message.updated", %{
        "id" => "m1",
        "threadId" => id,
        "role" => "user",
        "text" => "Can you fix the cart?",
        "createdAt" => at
      }),
      event(id, "message.updated", %{
        "id" => "m2",
        "threadId" => id,
        "role" => "assistant",
        "text" => "The cart is fixed.",
        "createdAt" => at
      }),
      event(id, "provider-thread.updated", %{
        "id" => "pt-legacy",
        "appThreadId" => id,
        "driver" => "codex",
        "nativeThreadRef" => %{"driver" => "codex", "nativeId" => "thr-mc"}
      })
    ]

    %{
      "format" => "hal-c2-thread-export",
      "version" => 1,
      "exportedAt" => at,
      "thread" => %{
        "id" => id,
        "title" => "Legacy",
        "sourceProjectId" => "shop-old",
        "sourceWorkspaceRoot" => root
      },
      "events" => events,
      "attachments" => [],
      "terminalLogs" => []
    }
  end

  defp event(stream, type, payload) do
    %{
      "aggregateKind" => "thread",
      "streamId" => stream,
      "eventType" => type,
      "payloadJson" => JSON.encode!(payload),
      "occurredAt" => "2026-09-01T00:00:00.000Z",
      "applicationEventVersion" => 2
    }
  end

  defp file(name, data) do
    %{
      "fileName" => name,
      "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
      "dataBase64" => Base.encode64(data)
    }
  end
end
