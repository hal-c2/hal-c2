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

  # A review thread from before code-review's manifest said its threads stay carries a
  # plugin mark without "stays" (as does its fork, which copies the mark: see the scenario
  # in threads/moving-between-machines.feature). The installed manifest keeps it anyway,
  # with the plugin off, and an export refuses it like a move does.
  test "a thread from before its plugin declared its threads stay is kept by the plugin's manifest",
       %{context: context, tmp_dir: dir} do
    context = World.create_thread(context, "Review")
    mark = %{"id" => "code-review", "kind" => "review", "listed" => false}
    context = World.patch_thread(context, "Review", %{"plugin" => mark})
    review = World.thread(context, "Review")

    # Not installed: ordinary threads.
    assert ThreadArchive.stays(review) == :ok

    manifest = fn extra ->
      package = Path.join(HalC2.Paths.data_dir(), "plugins/code-review")
      File.mkdir_p!(package)

      File.write!(
        Path.join(package, "plugin.json"),
        JSON.encode!(Map.merge(%{"id" => "code-review"}, extra))
      )
    end

    manifest.(%{})
    assert ThreadArchive.stays(review) == :ok

    manifest.(%{"threadsStay" => true})
    refute HalC2.Plugins.running?("code-review")
    kept = {:error, "Review was started by code-review, which keeps it on this machine."}
    assert ThreadArchive.stays(review) == kept

    assert ThreadArchive.export_file("Review", Path.join(dir, "review.hal-c2-thread")) ==
             {:error, "Review was started by code-review, which keeps it on this machine."}

    refute File.exists?(Path.join(dir, "review.hal-c2-thread"))

    # A thread that names a path rather than a plugin reads nothing outside the plugins.
    escape = %{"id" => "../code-review", "kind" => "review"}
    assert ThreadArchive.stays(%{"title" => "X", "plugin" => escape}) == :ok
  end

  # The plugin host never loaded a version of this package (it started, or the package
  # was dropped in, with the manifest broken), so only the disk can speak for it: a
  # package that is there with a manifest that says nothing keeps its threads (#1432).
  test "a thread from before its plugin's mark is kept while the plugin's manifest cannot be read",
       %{context: context, tmp_dir: dir} do
    context = World.create_thread(context, "Review")
    mark = %{"id" => "broken-keeper", "kind" => "review", "listed" => false}
    context = World.patch_thread(context, "Review", %{"plugin" => mark})
    review = World.thread(context, "Review")
    kept = {:error, "Review was started by broken-keeper, which keeps it on this machine."}

    # Not installed: an ordinary thread.
    assert ThreadArchive.stays(review) == :ok

    package = Path.join(HalC2.Paths.data_dir(), "plugins/broken-keeper")
    File.mkdir_p!(package)

    # The manifest is missing, not valid JSON, not an object or unreadable (a directory).
    for manifest <- [:missing, "{ \"id\": ", "[]", "\"threadsStay\"", :directory] do
      File.rm_rf!(Path.join(package, "plugin.json"))

      case manifest do
        :missing -> :ok
        :directory -> File.mkdir_p!(Path.join(package, "plugin.json"))
        text -> File.write!(Path.join(package, "plugin.json"), text)
      end

      refute HalC2.Plugins.running?("broken-keeper")
      assert ThreadArchive.stays(review) == kept, "manifest #{inspect(manifest)}"

      assert ThreadArchive.export_file("Review", Path.join(dir, "review.hal-c2-thread")) == kept
      refute File.exists?(Path.join(dir, "review.hal-c2-thread"))
    end

    # The copy `mix hal_c2.plugins.install` set aside speaks the same way.
    plugins = Path.dirname(package)
    aside = HalC2.Plugins.Package.aside_dir(plugins, "broken-keeper")
    File.rename!(package, aside)
    assert ThreadArchive.stays(review) == kept

    # A readable manifest says what it says again, and removing the package frees the thread.
    File.rm_rf!(Path.join(aside, "plugin.json"))
    File.write!(Path.join(aside, "plugin.json"), JSON.encode!(%{"id" => "broken-keeper"}))
    assert ThreadArchive.stays(review) == :ok
    File.write!(Path.join(aside, "plugin.json"), "{ \"id\": ")
    File.rm_rf!(aside)
    assert ThreadArchive.stays(review) == :ok

    # A plugins directory the MC cannot look into cannot say the package is gone.
    File.mkdir_p!(package)
    File.chmod!(plugins, 0o000)

    try do
      assert ThreadArchive.stays(review) == kept
    after
      File.chmod!(plugins, 0o700)
    end

    File.rm_rf!(package)
    assert ThreadArchive.stays(review) == :ok

    # A name that is no package id reads nothing, however it is spelled.
    for id <- ["", ".", "..", "a/b"] do
      assert HalC2.Plugins.Package.threads_stay?(id) == false
    end
  end

  test "a failed import takes back the worktree branch it made", %{context: context, root: root} do
    {bundle, carried} = feature_bundle(context, root)
    branches = World.git!(root, ~w(for-each-ref refs/heads))
    placed = refuse_worktree(root, bundle)

    assert placed =~ "#{carried} commit\trefs/heads/feature"
    assert World.git!(root, ~w(for-each-ref refs/heads)) == branches

    assert World.git!(root, ~w(worktree list --porcelain)) =~
             ~r/\Aworktree [^\n]+\n(?!.*worktree )/s
  end

  test "a failed import puts back a worktree branch this checkout already had",
       %{context: context, root: root} do
    # Here the branch is a commit behind the carried one: the fetch moves it on.
    World.git!(root, ~w(branch feature))
    {bundle, carried} = feature_bundle(context, root)
    branches = World.git!(root, ~w(for-each-ref refs/heads))
    refute branches =~ carried
    placed = refuse_worktree(root, bundle)

    assert placed =~ "#{carried} commit\trefs/heads/feature"
    assert World.git!(root, ~w(for-each-ref refs/heads)) == branches

    assert World.git!(root, ~w(worktree list --porcelain)) =~
             ~r/\Aworktree [^\n]+\n(?!.*worktree )/s
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

  # A bundle of the branch `feature` of a laptop's clone of `root`, a commit ahead of it,
  # and that commit.
  defp feature_bundle(context, root) do
    source = Path.join(context.mc.home, "laptop-shop")
    World.git!(context.mc.home, ["clone", "-q", root, source])
    World.git!(source, ~w(checkout -q -b feature))

    World.git!(
      source,
      ~w(-c user.email=a@example.com -c user.name=A commit -q --allow-empty -m run-1)
    )

    bundle = Path.join(context.mc.home, "worktree.bundle")
    World.git!(source, ["bundle", "create", "-q", bundle, "refs/heads/feature"])
    {bundle, World.git!(source, ~w(rev-parse HEAD))}
  end

  # Imports a thread with its worktree that the store refuses. Returns the branches `root`
  # had when the store refused it: what the import placed before it failed.

  defp refuse_worktree(root, bundle) do
    archive =
      archive(root, %{
        "thread" => %{
          "id" => "th-cart",
          "title" => "Cart",
          "projectId" => "shop-laptop",
          "projectRoot" => "/home/a/code/shop",
          "worktreePath" => "/home/a/code/shop-feature",
          "repository" => ThreadArchive.repository(root),
          "machine" => "laptop"
        },
        "worktree" => %{
          "branch" => "feature",
          "path" => "/home/a/code/shop-feature",
          "bundle" => file("worktree.bundle", File.read!(bundle))
        }
      })

    Application.put_env(:hal_c2, :store_hook, {__MODULE__, :refuse_seeing, [self(), root]})

    assert ThreadArchive.import_archive(archive, project: "shop") ==
             {:error, "The import of Cart failed: the disk is full. Nothing was imported."}

    assert_received {:placed, branches}
    branches
  end

  # As `Machines.refuse_change/3` for th-cart, telling `test` the branches `root` has then.
  @doc false
  def refuse_seeing(test, root, :append_change, "th-cart") do
    if self() == Process.whereis(HalC2.Store) do
      send(test, {:placed, World.git!(root, ~w(for-each-ref refs/heads))})
      raise "the disk is full"
    end

    :ok
  end

  def refuse_seeing(_test, _root, _stage, _stream_id), do: :ok

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
