defmodule HalC2.SpaceFilesPropTest do
  @moduledoc """
  A state machine over Space pages that are project files (`HalC2.Space.Files`): files
  written, deleted and renamed in the project's folder, each with or without the signal
  that the checkout changed; files opened as pages and opened again; pages edited,
  read again from their file and unlinked; unlinked pages edited; and the server that
  follows the files restarting, which reads every file again.

  Every file reads `# Doc`, a blank line and one block, a word, a table or a code block,
  so a page is that block; the page edits it as its kind is edited (a table's text, a
  code block's text and language), so a word stays a word. After each command the test
  reads the folder and the Space back and checks them against the model:

  - the folder holds exactly what the model says: only a linked page with its file in
    place, read as it was last read, writes it, and an unlinked page never does;
  - an edit to a page whose file changed since it was last read loses to the file;
  - a linked page writes as the Markdown it last read or wrote, records that text's
    hash, and says whether its file is gone;
  - a file that vanished is followed to a file no page has that reads the same,
    pages claiming such files in the order of their paths;
  - one file is behind at most one page, and opening a file again goes to its page.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.{Space, StreamState}
  alias HalC2.Space.{Blocks, Files, Markdown}

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @paths ~w(a.md b.md d/c.md)
  @words ~w(alpha beta gamma) ++
           [
             "| a |\n| --- |\n| 1 |",
             "| a |\n| --- |\n| 2 |",
             "```js\nx\n```",
             "```ts\nx\n```",
             "```js\ny\n```"
           ]

  property "pages that are files follow them, and they follow the pages",
    numtests: HalC2.Prop.numtests(100),
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

  # disk: path => text in the folder. links: path => %{id, word, base, missing}, the
  # page of that file, the word it shows, the text it last read or wrote, and whether
  # its file is gone. unlinked: pages made ordinary, %{id, word}.
  def initial_state, do: %{disk: %{}, links: %{}, unlinked: []}

  def command(s) do
    linked = Map.keys(s.links)

    frequency(
      [
        {4, {:call, __MODULE__, :write, [path(), word(), boolean()]}},
        {3, {:call, __MODULE__, :open, [path()]}},
        {1, {:call, __MODULE__, :restart, []}}
      ] ++
        if(s.disk == %{},
          do: [],
          else: [
            {1, {:call, __MODULE__, :delete, [oneof(Map.keys(s.disk)), boolean()]}},
            {2, {:call, __MODULE__, :rename, [oneof(Map.keys(s.disk)), path(), boolean()]}}
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

  def precondition(s, {:call, _, :delete, [path, _]}), do: Map.has_key?(s.disk, path)

  def precondition(s, {:call, _, :rename, [from, to, _]}),
    do: Map.has_key?(s.disk, from) and not Map.has_key?(s.disk, to)

  def precondition(s, {:call, _, :edit, [path, id, word]}),
    do: match?(%{id: ^id}, s.links[path]) and kind(word) == kind(s.links[path].word)

  def precondition(s, {:call, _, name, [path, id | _]}) when name in [:sync, :unlink],
    do: match?(%{id: ^id}, s.links[path])

  def precondition(s, {:call, _, :edit_unlinked, [id, word]}),
    do: Enum.any?(s.unlinked, &(&1.id == id and kind(word) == kind(&1.word)))

  def precondition(_s, _call), do: true

  def next_state(s, _res, {:call, _, :write, [path, word, notify]}),
    do: s |> put_in([:disk, path], doc(word)) |> notified(notify)

  def next_state(s, _res, {:call, _, :delete, [path, notify]}),
    do: %{s | disk: Map.delete(s.disk, path)} |> notified(notify)

  def next_state(s, _res, {:call, _, :rename, [from, to, notify]}) do
    {text, disk} = Map.pop(s.disk, from)
    notified(%{s | disk: Map.put(disk, to, text)}, notify)
  end

  def next_state(s, res, {:call, _, :open, [path]}) do
    cond do
      link = s.links[path] ->
        put_in(s, [:links, path], read(link, s.disk[path]))

      text = s.disk[path] ->
        put_in(s, [:links, path], %{id: res, word: word_of(text), base: text, missing: false})

      true ->
        s
    end
  end

  def next_state(s, _res, {:call, _, :sync, [path, _id]}),
    do: put_in(s, [:links, path], read(s.links[path], s.disk[path]))

  def next_state(s, _res, {:call, _, :edit, [path, _id, word]}) do
    link = s.links[path]
    text = s.disk[path]

    cond do
      word == link.word ->
        s

      # The file changed since it was read, or came back: it wins over the edit.
      text != nil and (link.missing or text != link.base) ->
        put_in(s, [:links, path], read(link, text))

      # The file is gone: the edit stays on the page.
      text == nil ->
        put_in(s, [:links, path], %{link | word: word, missing: true})

      # Written, which tells the server the folder changed.
      true ->
        s
        |> put_in([:disk, path], doc(word))
        |> put_in([:links, path], %{link | word: word, base: doc(word)})
        |> follow()
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

    {links, _} =
      s.links
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.reduce({%{}, taken}, fn {path, link}, {links, taken} ->
        text = s.disk[path]

        cond do
          text != nil ->
            {Map.put(links, path, read(link, text)), taken}

          link.missing ->
            {Map.put(links, path, link), taken}

          to = moved(s.disk, link.base, taken) ->
            {Map.put(links, to, read(link, s.disk[to])), MapSet.put(taken, to)}

          true ->
            {Map.put(links, path, %{link | missing: true}), taken}
        end
      end)

    %{s | links: links}
  end

  defp moved(disk, base, taken) do
    disk
    |> Enum.filter(fn {path, text} -> text == base and not MapSet.member?(taken, path) end)
    |> Enum.map(fn {path, _} -> path end)
    |> Enum.sort()
    |> List.first()
  end

  # A page reading its file again: gone, the same, or taken.
  defp read(link, nil), do: %{link | missing: true}
  defp read(%{missing: false, base: text} = link, text), do: link
  defp read(link, text), do: %{link | word: word_of(text), base: text, missing: false}

  def postcondition(s, {:call, _, :open, [path]} = call, res) do
    expected =
      cond do
        link = s.links[path] -> res == link.id
        s.disk[path] -> is_binary(res)
        true -> res == {:error, :not_found}
      end

    expected and agrees(next_state(s, res, call))
  end

  def postcondition(s, call, res), do: res == :ok and agrees(next_state(s, res, call))

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
          page["file"]["hash"] == hash(link.base) and words(state, page) == [link.word]
      end)

    unlinked =
      Enum.all?(s.unlinked, fn u ->
        page = Enum.find(pages, &(&1["id"] == u.id))
        page["file"] == nil and words(state, page) == [u.word]
      end)

    disk == s.disk and linked and unlinked and length(files) == length(Enum.uniq(files))
  end

  defp words(state, page), do: Enum.map(Blocks.of_page(state, page["id"]), &Markdown.render/1)

  # What a page's block is: an edit keeps it the same kind.
  defp kind("|" <> _), do: :table
  defp kind("```" <> _), do: :code
  defp kind(_), do: :paragraph

  defp doc(word), do: "# Doc\n\n#{word}\n"
  defp word_of("# Doc\n\n" <> rest), do: String.trim_trailing(rest, "\n")
  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # --- commands ---------------------------------------------------------------------

  def write(path, word, notify) do
    file = Path.join(Process.get(:root), path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, doc(word))
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

  # A page writing its file tells the server the folder changed; it has followed once
  # the call behind that is answered.
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

  defp changes(_kind, word), do: %{"text" => word}

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
  defp done(other), do: other
end
