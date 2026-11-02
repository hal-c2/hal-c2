defmodule HalC2.SpaceFilesPropTest do
  @moduledoc """
  A state machine over Space pages that are project files (`HalC2.Space.Files`): files
  written, deleted, renamed and made read-only in the project's folder, and links made
  to them and deleted, each with or without the signal that the checkout changed; files opened as pages and opened again; pages edited,
  read again from their file and unlinked; unlinked pages edited; and the server that
  follows the files restarting, which reads every file again.

  Every file reads `# Doc`, a blank line and a word: a paragraph, a table, a code block,
  a quote or alert, a list or a rule, so a page is that word's blocks. The page edits a
  word as its kind is edited (a table's text, a code block's text and language, a quote's
  text and alert), so a word stays a word of its kind; a list or rule written as a page
  cannot write it (a marker, a depth, a rule other than `---`) only ever changes in the
  file. After each command the test reads the folder and the Space back and checks them
  against the model:

  - the folder holds exactly what the model says: only a linked page with its file in
    place, read as it was last read, writes it, and an unlinked page never does;
  - an edit to a page whose file changed since it was last read loses to the file, and
    the page says so;
  - an edit to a page whose file is read-only is refused, and neither changes;
  - an edit to a page whose file is gone stays on the page, and a file that comes back
    wins over it, and the page says so; an edit that reaches the file clears that;
  - a page writing its file does not set the server following the folder, but another
    page that is the same file through a link takes what it wrote, once the server has
    seen a page go through a link (at an open or a follow) or the write went through one;
    a link stays a link;
  - a linked page writes as the Markdown it last read or wrote, records that text's
    hash, and says whether its file is gone;
  - a file that vanished is followed to the one file no page has that reads the same,
    and to none when there are more, pages claiming such files in the order of their
    paths;
  - one file is behind at most one page, and opening a file again goes to its page.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Space, StreamState}
  alias HalC2.Space.{Blocks, Files, Markdown}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @paths ~w(a.md b.md d/c.md l.md)
  # Links are made at the top of the folder, to a file there, never to another link.
  @tops ~w(a.md b.md l.md)
  @words ~w(alpha beta gamma) ++
           [
             "| a |\n| --- |\n| 1 |",
             "| a |\n| --- |\n| 2 |",
             "```js\nx\n```",
             "```ts\nx\n```",
             "```js\ny\n```",
             "> x",
             "> [!NOTE]\n> x",
             "> [!TIP]\n> x",
             "> a\n>\n> b",
             "* a",
             "- a\n- b",
             "- a\n  - b",
             "***",
             "___"
           ]

  property "pages that are files follow them, and they follow the pages",
    numtests: HalC2.Prop.numtests(600),
    max_size: 30 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        home = HalC2.Prop.scratch_home("space-files")
        work = Path.join(home, "work")
        File.mkdir_p!(work)
        {_, 0} = System.cmd("git", ~w(init -q -b main), cd: work)

        HalC2.Prop.start_services([
          {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
          HalC2.Settings,
          HalC2.Streams,
          HalC2.Shell,
          Files
        ])

        {:ok, _} =
          HalC2.Projects.mutate(%{
            "type" => "project.create",
            "projectId" => "demo",
            "title" => "demo",
            "workspaceRoot" => work
          })

        HalC2.Streams.flush_shell("demo")
        :sys.get_state(HalC2.Shell)

        {:ok, space} = Space.create("Prop")
        Process.put(:space, space["id"])
        Process.put(:root, Path.expand(work))
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ----------------------------------------------------------------------

  # disk: path => text of the files in the folder; sym: path => path, its links;
  # locked: the files that are read-only. seen: whether a page's path went through a
  # link when the server last looked (opening it, or following the folder). links:
  # path => %{id, word, base, missing, unwritten, conflict}, the page of that file, the
  # word it shows, the text it last read or wrote, whether its file is gone, whether it
  # was edited since, and whether it says the file won over an edit. unlinked: pages
  # made ordinary, %{id, word}.
  def initial_state,
    do: %{disk: %{}, sym: %{}, locked: MapSet.new(), seen: false, links: %{}, unlinked: []}

  def command(s) do
    linked = Map.keys(s.links)

    frequency(
      [
        {4, {:call, __MODULE__, :write, [path(), word(), boolean()]}},
        {3, {:call, __MODULE__, :open, [path()]}},
        {2, {:call, __MODULE__, :symlink, [oneof(@tops), oneof(@tops), boolean()]}},
        {1, {:call, __MODULE__, :restart, []}}
      ] ++
        if(s.disk == %{},
          do: [],
          else: [
            {2,
             {:call, __MODULE__, :delete, [oneof(Map.keys(s.disk) ++ Map.keys(s.sym)), boolean()]}},
            {2, {:call, __MODULE__, :rename, [oneof(Map.keys(s.disk)), path(), boolean()]}},
            {1, {:call, __MODULE__, :lock, [oneof(Map.keys(s.disk))]}}
          ]
        ) ++
        if(linked == [],
          do: [],
          else: [
            {4,
             let(p <- oneof(linked), do: {:call, __MODULE__, :edit, [p, s.links[p].id, word()]})},
            {1, let(p <- oneof(linked), do: {:call, __MODULE__, :sync, [p, s.links[p].id]})},
            {1, let(p <- oneof(linked), do: {:call, __MODULE__, :unlink, [p, s.links[p].id]})}
          ]
        ) ++
        if(s.unlinked == [],
          do: [],
          else: [
            {1,
             let(u <- oneof(s.unlinked), do: {:call, __MODULE__, :edit_unlinked, [u.id, word()]})}
          ]
        )
    )
  end

  defp path, do: oneof(@paths)
  defp word, do: oneof(@words)

  def precondition(s, {:call, _, :delete, [path, _]}),
    do: Map.has_key?(s.disk, path) or Map.has_key?(s.sym, path)

  def precondition(s, {:call, _, :lock, [path]}), do: Map.has_key?(s.disk, path)

  def precondition(s, {:call, _, :rename, [from, to, _]}),
    do: Map.has_key?(s.disk, from) and free?(s, to)

  def precondition(s, {:call, _, :symlink, [from, to, _]}),
    do:
      from != to and free?(s, from) and from not in Map.values(s.sym) and
        not Map.has_key?(s.sym, to)

  def precondition(s, {:call, _, :edit, [path, id, word]}),
    do: match?(%{id: ^id}, s.links[path]) and editable?(word, s.links[path].word)

  def precondition(s, {:call, _, name, [path, id | _]}) when name in [:sync, :unlink],
    do: match?(%{id: ^id}, s.links[path])

  def precondition(s, {:call, _, :edit_unlinked, [id, word]}),
    do: Enum.any?(s.unlinked, &(&1.id == id and editable?(word, &1.word)))

  def precondition(_s, _call), do: true

  defp opens?(s, path), do: Map.has_key?(s.links, path) or text(s, path) != nil

  defp free?(s, path), do: not Map.has_key?(s.disk, path) and not Map.has_key?(s.sym, path)

  # The file `path` is: the one it links to, or itself.
  defp resolve(s, path), do: Map.get(s.sym, path, path)
  defp text(s, path), do: s.disk[resolve(s, path)]

  # What reading each path in the folder gives, links followed.
  defp view(s), do: for(path <- @paths, text = text(s, path), into: %{}, do: {path, text})

  def next_state(s, _res, {:call, _, :write, [path, word, notify]}) do
    path = resolve(s, path)

    %{s | locked: MapSet.delete(s.locked, path)}
    |> put_in([:disk, path], doc(word))
    |> notified(notify)
  end

  def next_state(s, _res, {:call, _, :delete, [path, notify]}),
    do:
      %{
        s
        | disk: Map.delete(s.disk, path),
          sym: Map.delete(s.sym, path),
          locked: MapSet.delete(s.locked, path)
      }
      |> notified(notify)

  def next_state(s, _res, {:call, _, :symlink, [from, to, notify]}),
    do: notified(put_in(s, [:sym, from], to), notify)

  def next_state(s, _res, {:call, _, :rename, [from, to, notify]}) do
    {text, disk} = Map.pop(s.disk, from)
    locked = MapSet.delete(MapSet.delete(s.locked, from), to)
    locked = if MapSet.member?(s.locked, from), do: MapSet.put(locked, to), else: locked
    notified(%{s | disk: Map.put(disk, to, text), locked: locked}, notify)
  end

  def next_state(s, _res, {:call, _, :lock, [path]}),
    do: %{s | locked: MapSet.put(s.locked, path)}

  def next_state(s, res, {:call, _, :open, [path]}) do
    s = %{s | seen: s.seen or (opens?(s, path) and Map.has_key?(s.sym, path))}

    cond do
      link = s.links[path] ->
        put_in(s, [:links, path], read(link, text(s, path)))

      text = text(s, path) ->
        link = %{id: res, word: word_of(text), base: text, missing: false}
        put_in(s, [:links, path], Map.merge(link, %{unwritten: false, conflict: false}))

      true ->
        s
    end
  end

  def next_state(s, _res, {:call, _, :sync, [path, _id]}),
    do: put_in(s, [:links, path], read(s.links[path], text(s, path)))

  def next_state(s, _res, {:call, _, :edit, [path, _id, word]}) do
    link = s.links[path]
    text = text(s, path)
    file = resolve(s, path)

    cond do
      word == link.word ->
        s

      # The file changed since it was read, or came back: it wins over the edit.
      text != nil and (link.missing or text != link.base) ->
        put_in(s, [:links, path], read(%{link | conflict: true}, text))

      # The file is gone: the edit stays on the page.
      text == nil ->
        put_in(s, [:links, path], %{link | word: word, missing: true, unwritten: true})

      # Read-only: refused.
      MapSet.member?(s.locked, file) ->
        s

      # Written; nothing else is read but the pages that are the same file by a link.
      true ->
        s = put_in(s.disk[file], doc(word))

        twins? = Map.has_key?(s.sym, path) or s.seen

        links =
          Map.new(s.links, fn
            {^path, link} ->
              {path, %{link | word: word, base: doc(word), conflict: false}}

            {other, link} ->
              {other,
               if(twins? and resolve(s, other) == file, do: read(link, doc(word)), else: link)}
          end)

        %{s | links: links}
    end
  end

  def next_state(s, _res, {:call, _, :unlink, [path, _id]}) do
    {link, links} = Map.pop(s.links, path)
    %{s | links: links, unlinked: [%{id: link.id, word: link.word} | s.unlinked]}
  end

  def next_state(s, _res, {:call, _, :edit_unlinked, [id, word]}),
    do: %{s | unlinked: Enum.map(s.unlinked, &if(&1.id == id, do: %{&1 | word: word}, else: &1))}

  def next_state(s, _res, {:call, _, :restart, []}), do: follow(s)

  defp notified(s, true), do: follow(s)
  defp notified(s, false), do: s

  # The server looking at every file: a page takes its file when it changed, follows a
  # vanished file to an unclaimed one that reads as it last read, or says it is gone.
  defp follow(s) do
    taken = MapSet.new(Map.keys(s.links))

    {links, taken} =
      s.links
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.reduce({%{}, taken}, fn {path, link}, {links, taken} ->
        text = text(s, path)

        cond do
          text != nil ->
            {Map.put(links, path, read(link, text)), taken}

          link.missing ->
            {Map.put(links, path, link), taken}

          to = moved(view(s), link.base, taken) ->
            {Map.put(links, to, read(link, text(s, to))), MapSet.put(taken, to)}

          true ->
            {Map.put(links, path, %{link | missing: true}), taken}
        end
      end)

    %{s | links: links, seen: Enum.any?(taken, &Map.has_key?(s.sym, &1))}
  end

  defp moved(disk, base, taken) do
    case Enum.filter(disk, fn {path, text} -> text == base and not MapSet.member?(taken, path) end) do
      [{path, _}] -> path
      _ -> nil
    end
  end

  # A page reading its file again: gone, the same, or taken, over what was edited while
  # the file was gone.
  defp read(link, nil), do: %{link | missing: true}
  defp read(%{missing: false, base: text} = link, text), do: link

  defp read(link, text) do
    %{
      link
      | word: word_of(text),
        base: text,
        missing: false,
        unwritten: false,
        conflict: link.conflict or link.unwritten
    }
  end

  # An edit the model refuses: to the page of a read-only file that is as it was read.
  defp refused?(s, {:call, _, :edit, [path, _id, word]}) do
    link = s.links[path]
    text = text(s, path)

    word != link.word and text == link.base and not link.missing and
      MapSet.member?(s.locked, resolve(s, path))
  end

  defp refused?(_s, _call), do: false

  def postcondition(s, {:call, _, :open, [path]} = call, res) do
    expected =
      cond do
        link = s.links[path] -> res == link.id
        text(s, path) -> is_binary(res)
        true -> res == {:error, :not_found}
      end

    expected and agrees(next_state(s, res, call))
  end

  def postcondition(s, call, res) do
    expected = if refused?(s, call), do: {:error, :unavailable}, else: :ok
    res == expected and agrees(next_state(s, res, call))
  end

  # The folder and the Space are what the model says.
  defp agrees(s) do
    root = Process.get(:root)
    {:ok, state} = Space.state(Process.get(:space))
    pages = StreamState.list(state, "page")

    disk =
      for path <- @paths,
          {:ok, text} <- [File.read(Path.join(root, path))],
          into: %{},
          do: {path, text}

    files = for %{"file" => %{"path" => path}} <- pages, do: path

    linked =
      Enum.all?(s.links, fn {path, link} ->
        page = Enum.find(pages, &(&1["id"] == link.id))

        page["file"]["path"] == path and page["file"]["missing"] == link.missing and
          page["file"]["unwritten"] == link.unwritten and
          page["file"]["conflictAt"] != nil == link.conflict and
          page["file"]["hash"] == hash(link.base) and words(state, page) == [link.word]
      end)

    unlinked =
      Enum.all?(s.unlinked, fn u ->
        page = Enum.find(pages, &(&1["id"] == u.id))
        page["file"] == nil and words(state, page) == [u.word]
      end)

    syms =
      Enum.all?(s.sym, fn {path, to} -> File.read_link(Path.join(root, path)) == {:ok, to} end)

    disk == view(s) and syms and linked and unlinked and
      length(files) == length(Enum.uniq(files))
  end

  defp words(state, page) do
    blocks = Blocks.of_page(state, page["id"])
    [blocks |> Markdown.document(fn _ -> nil end) |> String.trim_trailing("\n")]
  end

  # What a page's block is: an edit keeps it the same kind.
  defp kind("|" <> _), do: :table
  defp kind("```" <> _), do: :code
  defp kind(">" <> _), do: :callout
  defp kind(word) when word in ["* a", "- a\n- b", "- a\n  - b", "***", "___"], do: {:as, word}
  defp kind(_), do: :paragraph

  defp doc(word), do: "# Doc\n\n#{word}\n"
  defp word_of("# Doc\n\n" <> rest), do: String.trim_trailing(rest, "\n")
  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # --- commands ---------------------------------------------------------------------

  # Written as an editor that is told to would: over a read-only file too, which then
  # is not read-only any more.
  def write(path, word, notify) do
    file = Path.join(Process.get(:root), path)
    File.mkdir_p!(Path.dirname(file))
    if File.exists?(file), do: File.chmod!(file, 0o644)
    File.write!(file, doc(word))
    notify(notify)
  end

  def lock(path), do: File.chmod!(Path.join(Process.get(:root), path), 0o444)

  def symlink(from, to, notify) do
    File.ln_s!(to, Path.join(Process.get(:root), from))
    notify(notify)
  end

  def delete(path, notify) do
    File.rm!(Path.join(Process.get(:root), path))
    notify(notify)
  end

  def rename(from, to, notify) do
    root = Process.get(:root)
    File.mkdir_p!(Path.dirname(Path.join(root, to)))
    :ok = File.rename(Path.join(root, from), Path.join(root, to))
    notify(notify)
  end

  def open(path) do
    case Space.open_file(Process.get(:space), "demo", path) do
      {:ok, %{"page" => page}} -> page["id"]
      {:error, reason, _message} -> {:error, reason}
    end
  end

  def sync(_path, id), do: done(Space.sync_file(Process.get(:space), id))
  def unlink(_path, id), do: done(Space.unlink_file(Process.get(:space), id))

  # Anything the edit set the server following the files doing is done once it answers,
  # so a follow the edit should not have caused shows.
  def edit(_path, id, word) do
    result = edit_unlinked(id, word)
    :sys.get_state(Files)
    result
  end

  def edit_unlinked(id, word) do
    space = Process.get(:space)
    {:ok, state} = Space.state(space)
    [block] = Blocks.of_page(state, id)
    done(Space.edit_block(space, block["id"], changes(kind(word), word)))
  end

  defp changes(:code, word) do
    ["```" <> language, text, "```"] = String.split(word, "\n")
    %{"text" => text, "language" => language}
  end

  defp changes(:callout, word) do
    case String.split(word, "\n", parts: 2) do
      ["> [!" <> alert, text] ->
        %{
          "alert" => alert |> String.trim_trailing("]") |> String.downcase(),
          "text" => unquote_lines(text)
        }

      _ ->
        %{"alert" => nil, "text" => unquote_lines(word)}
    end
  end

  defp changes(_kind, word), do: %{"text" => word}

  defp unquote_lines(text),
    do:
      text
      |> String.split("\n")
      |> Enum.map_join("\n", &(&1 |> String.trim_leading(">") |> String.trim_leading(" ")))

  # A page's edit gives the block a word of its kind, and one written only as a file
  # writes it (a marker, a depth, a rule) is not one a page's edit can give.
  defp editable?(word, from), do: kind(word) == kind(from) and not match?({:as, _}, kind(word))

  def restart do
    HalC2.Prop.restart_service(Files)
    Files.drain()
  end

  defp notify(false), do: :ok

  defp notify(true) do
    root = Process.get(:root)
    seen = Files.generation(root)
    Files.changed(root)
    Files.await(root, seen)
  end

  defp done({:ok, _}), do: :ok
  defp done({:error, reason, _message}), do: {:error, reason}
  defp done(other), do: other
end
