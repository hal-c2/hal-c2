defmodule HalC2.Steps.Platform.StorageMigration do
  @moduledoc """
  Steps for features/mc/platform/storage-migration.feature: the MC's one-shot copy
  from `~/.t3` or `~/.hal-c2` (`HalC2.Migration`).

  Old homes are made inside the scenario (`HalC2.Test.Storage`): an MC run flat in
  `<old home>/elixir`, as an install from before left it, or a marker home. Every file
  the migration copies goes through `HalC2.Test.Storage.copy/2`, so "reads nothing
  from" is what was copied, and "unchanged" is a byte-for-byte snapshot of the old home
  from before the first start.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Paths
  alias HalC2.Test.Storage
  alias HalC2.Test.Mc.World

  # --- old homes -----------------------------------------------------------------------

  step ~r/^(?<var>T3CODE_HOME|T3_HOME) is "(?<value>[^"]+)" and "(?<a>[^"]+)" and "(?<b>[^"]+)" both exist$/,
       %{args: [var, value, a, b]} = context do
    context = Storage.user(context)
    World.put_os_env(var, Storage.path(context, value))
    for home <- [value, a, b], do: marker_home(context, home)
    context
  end

  step ~r/^"(?<a>[^"]+)" and "(?<b>[^"]+)" both exist$/, %{args: homes} = context do
    for home <- homes, do: marker_home(context, home)
    context
  end

  step ~r/^(?:only )?"(?<home>[^"]+)" exists$/, %{args: [home]} = context do
    marker_home(context, home)
    context
  end

  step "T3CODE_HOME is {string}, which does not exist", %{args: [home]} = context do
    real = Storage.path(context, home)
    refute File.exists?(real)
    World.put_os_env("T3CODE_HOME", real)
    context
  end

  step "T3CODE_HOME is {string}", %{args: [home]} = context do
    marker_home(context, home)
    World.put_os_env("T3CODE_HOME", Storage.path(context, home))
    context
  end

  step ~r/^there is no "~\/\.hal-c2", no "~\/\.t3" and no T3CODE_HOME or T3_HOME$/, context do
    for home <- ["~/.hal-c2", "~/.t3"], do: refute(File.exists?(Storage.path(context, home)))
    for var <- ["T3CODE_HOME", "T3_HOME"], do: assert(System.get_env(var) == nil)
    context
  end

  step "{string} holds state for the installed app, a development server and the MC",
       %{args: [home]} = context do
    root = Storage.path(context, home)

    for part <- ["userdata", "dev"] do
      File.mkdir_p!(Path.join(root, part))
      File.write!(Path.join([root, part, "environment-id"]), "env-from-#{part}")
    end

    marker_home(context, home)
    context
  end

  step "{string} is the old home", %{args: [home]} = context do
    old_home(context, home)
  end

  step "the old home holds {string}", %{args: [path]} = context do
    real = Storage.path(context, path)

    case Path.basename(real) do
      "t3.sqlite" ->
        dir = Path.dirname(real)

        for suffix <- ["", "-wal", "-shm"],
            File.exists?(Path.join(dir, "hal-c2.sqlite" <> suffix)),
            do: File.rename!(Path.join(dir, "hal-c2.sqlite" <> suffix), real <> suffix)

      _ ->
        unless File.exists?(real), do: make_item(real)
    end

    Map.put(context, :old_item, real)
  end

  step ~r/^the old home holds (?<what>.+) at "(?<path>[^"]+)"$/,
       %{args: [_what, path]} = context do
    real = Storage.path(context, path)

    make_item(real)
    context
  end

  step "the old home holds secrets", context do
    dir = Path.join(context.old_home, "elixir/secrets")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "relay-token.bin"), "old secret")
    # Private or not before, the copy is private.
    File.chmod!(dir, 0o755)
    File.chmod!(Path.join(dir, "relay-token.bin"), 0o644)
    context
  end

  step "T3 Code is running against {string} and writing to its database",
       %{args: [home]} = context do
    path = Path.join(Storage.path(context, home), "elixir/hal-c2.sqlite")
    {:ok, db} = Exqlite.Sqlite3.open(path)
    ExUnit.Callbacks.on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    for sql <- [
          "PRAGMA journal_mode = WAL",
          "PRAGMA wal_autocheckpoint = 0",
          "CREATE TABLE t3_open (n INTEGER)",
          "INSERT INTO t3_open VALUES (1), (2), (3)",
          # Mid-write: not committed while HAL-C2 copies.
          "BEGIN",
          "INSERT INTO t3_open VALUES (4)"
        ],
        do: :ok = Exqlite.Sqlite3.execute(db, sql)

    Map.put(context, :t3_db, db)
  end

  step "HAL-C2 is copying the database from the old home", context do
    watch = fn from, to ->
      data = Paths.data_dir()
      seen = Process.get(:database_while_copying)

      if seen == nil,
        do:
          Process.put(:database_while_copying, %{
            final: File.exists?(Path.join(data, "hal-c2.sqlite")),
            staged: Path.wildcard(data <> ".migrating-*/hal-c2.sqlite") != []
          })

      Storage.copy(from, to)
    end

    put_in(context, [:mc, :migration], copy_file: watch)
  end

  step "a thread in project {string} works in the worktree {string}",
       %{args: [project, path]} = context do
    real = Storage.path(context, path)

    context =
      Storage.seed_mc(context, Path.join(context.old_home, "elixir"), fn ctx ->
        ctx =
          World.create_project(ctx, project, %{"workspaceRoot" => World.git_repo(ctx, project)})

        root = World.project(ctx, project).root
        File.mkdir_p!(Path.dirname(real))
        World.git!(root, ["worktree", "add", "-q", "-b", "feature-login", real])

        World.worktree_thread(ctx, "Login", project, %{
          "worktreePath" => real,
          "branch" => "feature-login"
        })
      end)

    Map.merge(context, %{thread: World.thread_id(context, "Login"), worktree_path: real})
  end

  # --- starting ------------------------------------------------------------------------

  step "HAL-C2 starts for the first time", context do
    Storage.first_start(context)
  end

  step ~r/^HAL-C2 (?:copies the database|looks for its database before the copy finishes|copies them)$/,
       context do
    Storage.first_start(context)
  end

  step "HAL-C2 starts for the first time and the user creates a thread", context do
    context
    |> Storage.first_start()
    |> World.create_project("web")
    |> World.create_thread("New thread", "web")
  end

  step ~r/^HAL-C2 migrate(?:s|d) from the old home$/, context do
    migrated(context)
  end

  step "HAL-C2 migrates from the old home and runs for a while", context do
    context = context |> migrated() |> World.create_thread("Later work", "Old project")
    :ok = World.merge_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
    Storage.restart(context)
  end

  step "the user then renamed a thread in T3 Code", context do
    Storage.seed_mc(context, Path.join(context.old_home, "elixir"), fn ctx ->
      {:ok, _} =
        HalC2.Orchestration.dispatch(%{
          "type" => "thread.metadata.update",
          "threadId" => World.thread_id(ctx, "Old work"),
          "title" => "Renamed in T3 Code"
        })

      ctx
    end)
  end

  step ~r/^HAL-C2 (?:restarts|starts again)$/, context do
    Storage.start(context)
  end

  step "HAL-C2's data directory already holds {string}", %{args: [path]} = context do
    real = Storage.mc_path(context, path)
    File.mkdir_p!(Path.dirname(real))
    File.write!(real, "")
    context
  end

  step "the user deletes {string} and HAL-C2 restarts", %{args: [path]} = context do
    File.rm_rf!(Storage.mc_path(context, path))
    Storage.start(context)
  end

  step "the user deletes {string} and {string}", %{args: paths} = context do
    for path <- paths, do: File.rm_rf!(Storage.mc_path(context, path))
    context
  end

  step "HAL_C2_NO_MIGRATE is {string}", %{args: [value]} = context do
    World.put_os_env("HAL_C2_NO_MIGRATE", value)
    context
  end

  step "HAL-C2 started once with HAL_C2_NO_MIGRATE set to {string}",
       %{args: [value]} = context do
    World.put_os_env("HAL_C2_NO_MIGRATE", value)
    Storage.first_start(context)
  end

  step "HAL-C2 restarts without it", context do
    World.put_os_env("HAL_C2_NO_MIGRATE", nil)
    Storage.restart(context)
  end

  # --- failures ------------------------------------------------------------------------

  step "the disk fills up partway through the copy", context do
    full = fn from, to ->
      if Storage.copies() == [] do
        Storage.copy(from, to)
      else
        raise File.CopyError, reason: :enospc, action: "copy", source: from, destination: to
      end
    end

    put_in(context, [:mc, :migration], copy_file: full)
  end

  step "a file in the old home cannot be read", context do
    file = Path.join(context.old_home, "elixir/settings.json")
    File.chmod!(file, 0o000)
    ExUnit.Callbacks.on_exit(fn -> File.chmod(file, 0o644) end)
    context
  end

  step "the old home's database is corrupt", context do
    db = Path.join(context.old_home, "elixir/hal-c2.sqlite")
    for suffix <- ["-wal", "-shm"], do: File.rm(db <> suffix)
    File.write!(db, :binary.copy("not a database ", 512))
    context
  end

  step "HAL-C2 was stopped partway through copying from the old home", context do
    # What a start that crashed mid-copy leaves: a staging directory with part of it.
    data = Paths.mc_dirs(nil, System.get_env(), Paths.user_home()).data
    staging = data <> ".migrating-99999"
    File.mkdir_p!(staging)
    File.write!(Path.join(staging, "environment-id"), "partial")
    Map.put(context, :unfinished, staging)
  end

  # --- what happened -------------------------------------------------------------------

  step ~r/^it copies from "(?<home>[^"]+)"(?: again| from the beginning)?$/,
       %{args: [home]} = context do
    source = Storage.path(context, home)
    home = if Path.basename(source) == "elixir", do: Path.dirname(source), else: source
    record = record!()
    assert record["source"] == home
    assert record["copied"] != []
    copies = Storage.copies()
    assert copies != []
    for from <- copies, do: assert(String.starts_with?(from, Path.join(home, "elixir") <> "/"))
    assert File.read!(Path.join(Paths.data_dir(), "environment-id")) == env_id(home)
    context
  end

  step "it reads nothing from the other old homes", context do
    source = record!()["source"]

    for home <- Paths.legacy_candidates(System.get_env(), Paths.user_home()), home != source do
      refute Enum.any?(Storage.copies(), &String.starts_with?(&1, home <> "/"))
      Storage.assert_untouched(context, home)
    end

    context
  end

  step ~r/^(?:it|HAL-C2) starts with no threads or projects$/, context do
    assert HalC2.Store.list_shell(HalC2.Store.home_path()) == []
    context
  end

  step "no migration is recorded", context do
    refute File.exists?(HalC2.Migration.record_path())
    context
  end

  step "the thread is stored in {string}", %{args: [path]} = context do
    db = HalC2.Store.home_path()
    assert String.starts_with?(db, Storage.path(context, path) <> "/")
    id = World.thread_id(context, "New thread")
    assert Enum.any?(HalC2.Store.list_shell(db), &(elem(&1, 0) == id))
    context
  end

  step "a copy is at {string}", %{args: [path]} = context do
    real = Storage.mc_path(context, path)
    old = context.old_item

    cond do
      String.ends_with?(real, ".sqlite") ->
        # A whole database with the old MC's threads in it.
        assert World.thread(context, "Old work")["title"] == "Old work"
        assert HalC2.Store.home_path() == real

      File.dir?(old) ->
        # A link back into the old home is left behind (see "points back").
        assert Storage.snapshot(real) |> Map.keys() |> Enum.sort() ==
                 for({rel, entry} <- Storage.snapshot(old), elem(entry, 0) != :symlink, do: rel)
                 |> Enum.sort()

      true ->
        assert File.read!(real) == File.read!(old)
    end

    context
  end

  step "the copy is a consistent snapshot that opens without repair", context do
    {:ok, db} = Exqlite.Sqlite3.open(HalC2.Store.home_path(), mode: :readonly)

    try do
      assert query(db, "PRAGMA integrity_check") == [["ok"]]
      # What T3 Code had committed, and not what it was still writing.
      assert query(db, "SELECT count(*) FROM t3_open") == [[3]]
    after
      Exqlite.Sqlite3.close(db)
    end

    context
  end

  step "T3 Code keeps running undisturbed", context do
    db = context.t3_db
    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO t3_open VALUES (5)")
    assert query(db, "SELECT count(*) FROM t3_open") == [[5]]
    context
  end

  step "there is no database at its final path yet", context do
    assert Process.get(:database_while_copying) == %{final: false, staged: true}
    assert File.regular?(HalC2.Store.home_path())
    context
  end

  step "nothing is copied from {string}", %{args: [path]} = context do
    real = Storage.path(context, path)
    assert record!()["source"] != nil
    refute Enum.any?(Storage.copies(), &String.starts_with?(&1, real <> "/"))
    refute Enum.any?(Storage.copies(), &(&1 == real))
    context
  end

  step "the copied {string} directory is readable only by the user", %{args: [name]} = context do
    dir = Path.join(Paths.data_dir(), name)
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    assert File.read!(Path.join(dir, "relay-token.bin")) == "old secret"
    context
  end

  step "no file or directory it created is a link into {string}", %{args: [home]} = context do
    home = Storage.path(context, home)
    assert record!()["source"] == home

    for dir <- Map.values(Storage.app_dirs()),
        {rel, entry} <- Storage.snapshot(dir),
        elem(entry, 0) == :symlink do
      {:ok, target} = File.read_link(Path.join(dir, rel))
      target = Path.expand(target, Path.dirname(Path.join(dir, rel)))
      refute String.starts_with?(target, home <> "/"), "#{rel} links to #{target}"
    end

    context
  end

  step "the agent works in {string}", %{args: [path]} = context do
    World.await_stream(context.thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] == "completed"))
    end)

    assert [%{"params" => %{"cwd" => cwd}} | _] = World.codex_sessions(context)
    assert cwd == Storage.path(context, path)
    context
  end

  step "the project's repository still lists that worktree", context do
    root = World.project(context, "api").root

    assert World.git!(root, ~w(worktree list --porcelain)) =~
             "worktree #{context.worktree_path}\n"

    context
  end

  step "the user starts a new thread in a new worktree of {string}",
       %{args: [project]} = context do
    World.worktree_thread(context, "New work", project)
  end

  step "the worktree is created under {string}", %{args: [path]} = context do
    under = Storage.mc_path(context, path)
    assert String.starts_with?(context.worktree.path, under <> "/")
    assert File.dir?(context.worktree.path)
    context
  end

  step "{string} names {string}, when it ran and what it copied",
       %{args: [record, home]} = context do
    record = Storage.mc_path(context, record) |> File.read!() |> JSON.decode!()
    assert record["source"] == Storage.path(context, home)
    assert {:ok, _, _} = DateTime.from_iso8601(record["at"])
    assert "elixir/hal-c2.sqlite" in record["copied"]
    assert "elixir/environment-id" in record["copied"]
    context
  end

  step "HAL-C2 logs one line saying it migrated from {string}", %{args: [home]} = context do
    lines = migrated_lines(context)
    assert [line] = lines
    assert line =~ "Migrated from #{Storage.path(context, home)}:"
    context
  end

  step "the thread keeps its old name in HAL-C2", context do
    assert World.thread(context, "Old work")["title"] == "Old work"
    context
  end

  step "every file in {string} is byte-for-byte what it was before", %{args: [home]} = context do
    real = Storage.path(context, home)
    now = Storage.snapshot(real)
    before = without_shm(Storage.baseline(context, real))

    for {rel, entry} <- before,
        match?({:regular, _, _}, entry),
        do: assert(now[rel] == entry, "#{rel} changed")

    context
  end

  step "no file was added to or removed from {string}", %{args: [home]} = context do
    real = Storage.path(context, home)
    assert Map.keys(Storage.snapshot(real)) == Map.keys(Storage.baseline(context, real))
    context
  end

  step "{string} is unchanged", %{args: [home]} = context do
    real = Storage.path(context, home)
    assert without_shm(Storage.snapshot(real)) == without_shm(Storage.baseline(context, real))
    context
  end

  step "nothing is copied from the old home", context do
    assert Storage.copies() == []
    context
  end

  step "the old home is not read", context do
    assert Storage.copies() == []
    assert migrated_lines(context) == []

    case File.read(HalC2.Migration.record_path()) do
      {:ok, text} -> assert JSON.decode!(text)["source"] == nil
      {:error, :enoent} -> :ok
    end

    context
  end

  step "none of the old home's files are in its data directory", context do
    old = Path.join(context.old_home, "elixir")
    refute File.read!(Path.join(Paths.data_dir(), "environment-id")) == env_id(context.old_home)

    for {rel, {:regular, _, hash}} <- Storage.snapshot(old),
        not String.ends_with?(rel, [".sqlite", "-wal", "-shm"]),
        dir <- [Paths.config_dir(), Paths.data_dir(), Paths.state_dir()],
        copy = Path.join(dir, rel),
        File.regular?(copy),
        do: refute(:crypto.hash(:sha256, File.read!(copy)) == hash, "#{copy} was copied")

    context
  end

  step "no unfinished copy is left beside the data directory", context do
    for {_, dir} <- Paths.dirs(), do: assert(Path.wildcard(dir <> ".migrating-*") == [])
    context
  end

  step "HAL-C2 warns that migrating from {string} failed and why", %{args: [home]} = context do
    prefix = "Migrating from #{Storage.path(context, home)} failed, starting fresh: "
    assert [line] = Enum.filter(logged(context), &String.contains?(&1, prefix))
    [_, reason] = String.split(line, prefix, parts: 2)
    assert String.trim(reason) != ""
    context
  end

  step "the unfinished copy is not used", context do
    refute File.exists?(context.unfinished)
    refute File.read!(Path.join(Paths.data_dir(), "environment-id")) == "partial"
    context
  end

  # --- services from before -----------------------------------------------------------

  step ~r/^a (?<manager>systemd|launchd) service installed before, whose definition sets (?<var>[A-Z0-9_]+)$/,
       %{args: [manager, var]} = context do
    home = if var == "T3CODE_HOME", do: "~/.t3", else: "~/.hal-c2"
    context = Storage.user(context)

    # The user is the Background's Linux user; a launchd service is a Mac's.
    if manager == "launchd", do: World.put_app_env(:service_platform, {:unix, :darwin})
    old_unit(context, String.to_atom(manager), var, Storage.path(context, home))
  end

  step ~r/^a service installed before whose definition sets (?<var>[A-Z0-9_]+)(?: to "(?<home>[^"]+)")?$/,
       %{args: args} = context do
    {var, home} =
      case args do
        [var] -> {var, "~/.t3"}
        [var, home] when home in [nil, ""] -> {var, "~/.t3"}
        [var, home] -> {var, home}
      end

    marker_home(context, home)
    old_unit(context, :systemd, var, Storage.path(context, home))
  end

  step "HAL-C2's data directory does not exist yet", context do
    refute File.exists?(Storage.app_dirs().data)
    context
  end

  step "the service starts HAL-C2", context do
    for {name, value} <- Storage.unit_env(File.read!(context.old_unit)),
        do: World.put_os_env(name, value)

    Storage.first_start(context)
  end

  step "it runs from the XDG directories", context do
    xdg = Paths.mc_dirs(nil, System.get_env(), Paths.user_home())
    assert Paths.dirs() == xdg
    assert HalC2.Store.home_path() == Path.join(xdg.data, "hal-c2.sqlite")
    assert String.starts_with?(xdg.data, Storage.path(context, "~/.local/share/hal-c2/"))
    context
  end

  step "the service is reported as installed", context do
    assert context.service_output =~ ~r/^Background service: installed/
    context
  end

  step "the user can remove it with {string}", %{args: ["hal-c2 service " <> cmd]} = context do
    context = Storage.service(context, cmd)
    assert context.service_output == "Background service removed."
    refute File.exists?(context.old_unit)

    assert Storage.service(context, "status").service_output ==
             "Background service: not installed"

    context
  end

  step "the service definition names no HAL-C2 home", context do
    env = unit_env(context)

    for name <- ~w(HAL_C2_HOME HAL_C2_MC_HOME HALC2_HOME T3CODE_HOME T3_HOME),
        do: refute(env[name])

    context
  end

  step "the service keeps its files in the XDG directories", context do
    text = File.read!(Storage.unit_path(context, :systemd, "hal-c2.service"))

    refute Enum.any?(Storage.unit_env(text), fn {name, _} -> String.starts_with?(name, "XDG_") end)

    log = Storage.path(context, "~/.local/state/hal-c2/elixir/logs/boot-service.log")
    assert text =~ "StandardOutput=append:#{log}"
    context
  end

  step "the service definition sets HAL_C2_HOME to {string}", %{args: [home]} = context do
    assert unit_env(context)["HAL_C2_HOME"] == Storage.path(context, home)
    context
  end

  step "the service definition names no HAL-C2 home and no T3CODE_HOME", context do
    env = unit_env(context)
    for name <- ~w(HAL_C2_HOME HAL_C2_MC_HOME HALC2_HOME T3CODE_HOME), do: refute(env[name])
    refute File.exists?(context.old_unit)
    context
  end

  # --- helpers -------------------------------------------------------------------------

  # A home from before holding an MC's marker files, so a copy says where it came from.
  defp marker_home(context, home) do
    root = Storage.path(context, home)
    dir = Path.join(root, "elixir")

    unless File.exists?(Path.join(dir, "environment-id")) do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "environment-id"), "env-#{:erlang.phash2(root)}")
      File.write!(Path.join(dir, "settings.json"), ~s({"from":"#{home}"}))
    end

    root
  end

  defp env_id(root), do: File.read!(Path.join([root, "elixir", "environment-id"]))

  # The old home as an MC from before left it: a database with a project and a
  # thread, settings, a secret, an attachment, logs, and a link back into the home.
  defp old_home(context, home) do
    context = Storage.user(context)
    root = Storage.path(context, home)
    dir = Path.join(root, "elixir")

    context =
      Storage.seed_mc(context, dir, fn ctx ->
        ctx
        |> World.create_project("Old project")
        |> World.create_thread("Old work", "Old project")
      end)

    File.write!(Path.join(dir, "settings.json"), ~s({"from":"#{home}"}))
    File.write!(Path.join(dir, "keybindings.json"), "[]")
    File.mkdir_p!(Path.join(dir, "secrets"))
    File.write!(Path.join(dir, "secrets/relay-token.bin"), "old secret")
    File.mkdir_p!(Path.join(dir, "attachments"))
    File.write!(Path.join(dir, "attachments/photo.png"), "old photo")
    File.ln_s!(Path.join(dir, "environment-id"), Path.join(dir, "attachments/link"))
    File.mkdir_p!(Path.join(dir, "logs"))
    File.write!(Path.join(dir, "logs/server.log"), "old log\n")
    Map.put(context, :old_home, root)
  end

  defp make_item(real) do
    if Path.extname(real) == "" do
      File.mkdir_p!(real)
      File.write!(Path.join(real, "kept"), "old #{Path.basename(real)}")
    else
      File.mkdir_p!(Path.dirname(real))
      File.write!(real, "old #{Path.basename(real)}")
    end
  end

  defp migrated(context) do
    context = Storage.first_start(context)
    assert record!()["source"] == context.old_home

    # A thread carried over works on: the fake Codex runs its turns.
    if context[:worktree_path] do
      World.provider_services()
      World.providers(context)
    else
      context
    end
  end

  # Any reader of a WAL database, the migration's snapshot included, updates
  # SQLite's shared-memory index; it holds no data, so it is not compared.
  defp without_shm(snapshot),
    do: Map.reject(snapshot, fn {rel, _} -> String.ends_with?(rel, "-shm") end)

  defp record! do
    HalC2.Migration.record_path() |> File.read!() |> JSON.decode!()
  end

  defp migrated_lines(context), do: Enum.filter(logged(context), &(&1 =~ "Migrated from "))

  defp logged(context), do: context |> World.logged() |> String.split("\n", trim: true)

  defp query(db, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    rows
  end

  # A unit written before the rename, by T3 Code or HAL-C2's first releases.
  defp old_unit(context, manager, var, home) do
    name =
      case {manager, var} do
        {:systemd, "T3CODE_HOME"} -> "t3code.service"
        {:systemd, _} -> "hal-c2.service"
        {:launchd, "T3CODE_HOME"} -> "com.t3tools.t3code.service"
        {:launchd, "HALC2_HOME"} -> "io.github.halc2.halc2.service"
        {:launchd, _} -> "io.github.halc2.service"
      end

    path = Storage.unit_path(context, manager, name)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      case manager do
        :systemd ->
          """
          [Unit]
          Description=T3 Code server

          [Service]
          Environment=#{var}=#{home}
          ExecStart=/usr/local/bin/t3 serve
          Restart=always

          [Install]
          WantedBy=default.target
          """

        :launchd ->
          """
          <?xml version="1.0" encoding="UTF-8"?>
          <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>#{name}</string>
            <key>EnvironmentVariables</key>
            <dict>
              <key>#{var}</key>
              <string>#{home}</string>
            </dict>
          </dict>
          </plist>
          """
      end
    )

    Map.put(context, :old_unit, path)
  end

  defp unit_env(context) do
    context
    |> Storage.unit_path(:systemd, "hal-c2.service")
    |> File.read!()
    |> Storage.unit_env()
    |> Map.new()
  end
end
