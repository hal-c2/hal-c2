defmodule HalC2.ThreadArchiveTest do
  # An import that fails takes back what it placed, and only that.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 2]

  alias HalC2.{Attachments, Orchestration, ThreadArchive}
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

  # A thread run in a review sandbox (#1412) stays with the sandbox, whatever its
  # plugin's manifest says: no move, export or import takes it off this machine.
  test "a sandboxed thread is kept on its machine", %{context: context, root: root, tmp_dir: dir} do
    context = World.create_thread(context, "Sandboxed")
    mark = %{"id" => "notes", "kind" => "review", "sandboxed" => true}
    context = World.patch_thread(context, "Sandboxed", %{"plugin" => mark})
    kept = {:error, "Sandboxed was started by notes, which keeps it on this machine."}
    assert ThreadArchive.stays(World.thread(context, "Sandboxed")) == kept

    assert ThreadArchive.export_file("Sandboxed", Path.join(dir, "s.hal-c2-thread")) == kept
    refute File.exists?(Path.join(dir, "s.hal-c2-thread"))

    cart = %{"id" => "th-cart", "title" => "Cart", "plugin" => mark}
    file = archive(root, %{"entities" => [["thread", "th-cart", cart]]})

    assert ThreadArchive.import_archive(file, project: "shop") ==
             {:error,
              "Cart was started by notes, which keeps it on the machine it started on. Cart was not imported."}

    assert ThreadArchive.local_thread("th-cart") == nil
  end

  # An MC from before plugins kept their threads sends such a thread on, by a move or a
  # file, so the MC it reaches refuses it: by its mark, or by the plugin's manifest here.
  test "a thread its plugin keeps on its machine is not imported", %{root: root} do
    with_mark = fn mark ->
      archive(root, %{
        "entities" => [
          [
            "thread",
            "th-cart",
            %{
              "id" => "th-cart",
              "title" => "Cart",
              "projectId" => "shop-laptop",
              "plugin" => mark
            }
          ]
        ]
      })
    end

    refused =
      {:error,
       "Cart was started by code-review, which keeps it on the machine it started on. Cart was not imported."}

    stays = %{"id" => "code-review", "kind" => "review", "stays" => true}
    assert ThreadArchive.import_archive(with_mark.(stays), project: "shop") == refused
    assert ThreadArchive.local_thread("th-cart") == nil

    package = Path.join(HalC2.Paths.data_dir(), "plugins/code-review")
    File.mkdir_p!(package)

    File.write!(
      Path.join(package, "plugin.json"),
      JSON.encode!(%{"id" => "code-review", "threadsStay" => true})
    )

    old_mark = %{"id" => "code-review", "kind" => "review"}
    assert ThreadArchive.import_archive(with_mark.(old_mark), project: "shop") == refused
    assert ThreadArchive.local_thread("th-cart") == nil

    other = %{"id" => "notes", "kind" => "note"}

    assert {:ok, %{thread: "th-cart"}} =
             ThreadArchive.import_archive(with_mark.(other), project: "shop")

    assert ThreadArchive.local_thread("th-cart")["plugin"] == nil
  end

  # A version 1 archive carries the thread as events, not entities, and an event's
  # payload can name the plugin: what they fold into is read, so the format's version
  # gets no kept thread past, and a mark no MC writes is taken as damage.
  test "a version 1 archive of a thread its plugin keeps is not imported either",
       %{root: root} do
    with_mark = fn mark -> legacy(root, %{"plugin" => mark}) end

    refused =
      {:error,
       "Legacy was started by code-review, which keeps it on the machine it started on. Legacy was not imported."}

    stays = %{"id" => "code-review", "kind" => "review", "stays" => true}
    assert ThreadArchive.import_archive(with_mark.(stays), project: "shop") == refused
    assert ThreadArchive.local_thread("th-legacy") == nil

    package = Path.join(HalC2.Paths.data_dir(), "plugins/code-review")
    File.mkdir_p!(package)

    File.write!(
      Path.join(package, "plugin.json"),
      JSON.encode!(%{"id" => "code-review", "threadsStay" => true})
    )

    old_mark = %{"id" => "code-review", "kind" => "review"}
    assert ThreadArchive.import_archive(with_mark.(old_mark), project: "shop") == refused
    assert ThreadArchive.local_thread("th-legacy") == nil

    damaged =
      {:error,
       "The file is damaged: Legacy names the plugin that started it in a form HAL-C2 does not write. Nothing was imported."}

    assert ThreadArchive.import_archive(with_mark.("code-review"), project: "shop") == damaged
    assert ThreadArchive.local_thread("th-legacy") == nil

    # The same for a version 2 archive's entities.
    cart = %{"id" => "th-cart", "title" => "Cart", "plugin" => "code-review"}
    cart_archive = archive(root, %{"entities" => [["thread", "th-cart", cart]]})

    assert ThreadArchive.import_archive(cart_archive, project: "shop") ==
             {:error,
              "The file is damaged: Cart names the plugin that started it in a form HAL-C2 does not write. Nothing was imported."}

    # A version 2 archive without its entities has no thread to read: it is not one.
    assert ThreadArchive.import_archive(archive(root, %{"entities" => nil}), project: "shop") ==
             {:error,
              "The file is damaged: it is not a HAL-C2 thread file. Nothing was imported."}

    # Another plugin's thread arrives as an ordinary one, as a version 2 archive's does.
    other = %{"id" => "notes", "kind" => "note"}

    assert {:ok, %{thread: "th-legacy"}} =
             ThreadArchive.import_archive(with_mark.(other), project: "shop")

    assert ThreadArchive.local_thread("th-legacy")["plugin"] == nil
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

    # The manifest is missing, not valid JSON, not an object, unreadable (a directory), or
    # fails validation with a `threadsStay` that is no boolean.
    invalid = JSON.encode!(%{"id" => "broken-keeper", "threadsStay" => "yes"})

    for manifest <- [:missing, "{ \"id\": ", "[]", "\"threadsStay\"", :directory, invalid] do
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

  # An install cut off between its two renames leaves the package aside with nothing in
  # its place. The next install, cut off in turn while it copies (a crash, a full disk:
  # here a file it cannot read), must not leave the package missing, which would read as
  # uninstalled and let a thread from before the mark be exported with no MC running.
  test "a thread its plugin keeps is kept through installs that are cut off",
       %{context: context, tmp_dir: dir} do
    context = World.create_thread(context, "Review")
    mark = %{"id" => "keeper", "kind" => "review", "listed" => false}
    context = World.patch_thread(context, "Review", %{"plugin" => mark})
    review = World.thread(context, "Review")
    kept = {:error, "Review was started by keeper, which keeps it on this machine."}
    manifest = JSON.encode!(%{"id" => "keeper", "threadsStay" => true})

    plugins = Path.join(HalC2.Paths.data_dir(), "plugins")
    installed = Path.join(plugins, "keeper")
    File.mkdir_p!(installed)
    File.write!(Path.join(installed, "plugin.json"), manifest)

    checkout = Path.join(dir, "checkout")
    package = Path.join(checkout, "plugins/keeper")
    File.mkdir_p!(Path.join(package, "mc"))
    File.write!(Path.join(package, "plugin.json"), manifest)
    locked = Path.join(package, "mc/keeper.ex")
    File.write!(locked, "defmodule Keeper do\nend\n")
    World.git!(checkout, ~w(init -q))
    Application.put_env(:hal_c2, :plugins_install_checkout, checkout)
    on_exit(fn -> Application.delete_env(:hal_c2, :plugins_install_checkout) end)

    File.rename!(installed, HalC2.Plugins.Package.aside_dir(plugins, "keeper"))
    assert ThreadArchive.stays(review) == kept

    File.chmod!(locked, 0o000)

    try do
      assert_raise File.CopyError, fn ->
        Mc.run_task(Mix.Tasks.HalC2.Plugins.Install, ["keeper"])
      end
    after
      File.chmod!(locked, 0o644)
    end

    assert ThreadArchive.stays(review) == kept
    file = Path.join(dir, "review.hal-c2-thread")
    assert ThreadArchive.export_file("Review", file) == kept
    refute File.exists?(file)
    # The version before is back in its place.
    assert File.read!(Path.join(installed, "plugin.json")) == manifest

    Mc.run_task(Mix.Tasks.HalC2.Plugins.Install, ["keeper"])
    assert File.exists?(Path.join(installed, "mc/keeper.ex"))
    refute File.exists?(HalC2.Plugins.Package.aside_dir(plugins, "keeper"))
    refute File.exists?(HalC2.Plugins.Package.staged_dir(plugins, "keeper"))
    assert ThreadArchive.stays(review) == kept
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

  # An export or a move used to carry the attachments of messages only, so the MCP app
  # document and the tool image a turn item names were missing where the thread arrived.
  test "an archive carries the app document and tool images its turn items name",
       %{context: context} do
    context = World.create_thread(context, "Forecast")
    id = World.thread_id(context, "Forecast")
    File.mkdir_p!(Attachments.dir())
    segment = Attachments.thread_segment(id)
    app = segment <> "-mcp-app-abc123"
    shot = segment <> "-shot-1"
    extra = segment <> "-shot-2"
    File.write!(Path.join(Attachments.dir(), app <> ".html"), "<p>forecast</p>")
    File.write!(Path.join(Attachments.dir(), shot <> ".png"), "png-1")
    File.write!(Path.join(Attachments.dir(), extra <> ".png"), "png-2")

    :ok =
      HalC2.Streams.transact(id, :thread, fn state ->
        items = [
          {"app",
           %{"mcpApp" => %{"attachmentId" => app, "server" => "weather", "tool" => "forecast"}}},
          {"output", %{"output" => [%{"type" => "image", "id" => shot}, %{"type" => "text"}]}},
          {"images", %{"images" => [%{"type" => "image", "id" => extra}]}}
        ]

        {for(
           {item, fields} <- items,
           do:
             Orchestration.upsert(state, "turn-item", item, fn _ ->
               Map.put(fields, "id", item)
             end)
         ), :ok}
      end)

    file = Path.join(context.mc.home, "forecast.hal-c2-thread")
    assert {:ok, %{attachments: 3}} = ThreadArchive.export_file(id, file, session: false)
    names = [app <> ".html", shot <> ".png", extra <> ".png"]

    # The destination has none of the files: the import places them where the
    # attachments are found, and serves the app inline in its sandbox.
    for name <- names, do: File.rm!(Path.join(Attachments.dir(), name))

    assert {:ok, _} = ThreadArchive.import_file(file, replace: true)
    assert File.read!(Attachments.path(%{"id" => app})) == "<p>forecast</p>"
    assert File.read!(Attachments.path(%{"id" => shot})) == "png-1"
    assert File.read!(Attachments.path(%{"id" => extra})) == "png-2"

    {:ok, %{"relativeUrl" => url}} =
      Attachments.create_url(%{
        "resource" => %{"_tag" => "attachment", "attachmentId" => app, "disposition" => "inline"}
      })

    served = conn(:get, url) |> HalC2.Web.Router.call([])
    assert served.status == 200
    assert served.resp_body =~ "<p>forecast</p>"

    assert ["sandbox allow-scripts" <> _] =
             Plug.Conn.get_resp_header(served, "content-security-policy")
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

  # Four events, one entity each, as an earlier install exported them; `thread` is
  # merged into the thread's.
  defp legacy(root, thread \\ %{}) do
    at = "2026-09-01T00:00:00.000Z"
    id = "th-legacy"

    events = [
      event(
        id,
        "thread.created",
        Map.merge(
          %{
            "id" => id,
            "title" => "Legacy",
            "projectId" => "shop-old",
            "createdAt" => at,
            "updatedAt" => at
          },
          thread
        )
      ),
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
