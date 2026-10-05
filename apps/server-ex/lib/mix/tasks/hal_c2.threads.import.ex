defmodule Mix.Tasks.HalC2.Threads.Import do
  @shortdoc "Picks threads from T3 Code or an older HAL-C2 and imports them"
  @moduledoc """
  Lists the threads of a T3 Code or Node HAL-C2 install on this machine and imports
  the ones you pick into the running MC (`HalC2.Import.PreviousInstall`).

      mix hal_c2.threads.import

  Threads still in play come first, settled ones after and marked as such. Type to
  filter (`active` and `settled` match too), Tab marks a thread, Enter imports the
  marked ones (or the one under the cursor), Ctrl-C leaves. The MC must be running; the install is only read.
  """

  use Mix.Task

  alias HalC2.Cluster.Command

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")

    sources =
      case Command.request(:get, "/api/previous-installs") do
        {:ok, %{"sources" => [_ | _] = sources}} ->
          sources

        {:ok, _} ->
          Mix.raise("No T3 Code or older HAL-C2 install was found on this machine.")

        {:error, "The MC answered 404" <> _} ->
          Mix.raise("The running MC does not have this command; run `mise run mc:reload` first.")

        {:error, message} ->
          Mix.raise(message)
      end

    :ok = :shell.start_interactive({:noshell, :raw})
    # Raw mode leaves Ctrl-C to the terminal, which would stop the VM in its break menu.
    stty("-isig")
    IO.write("\e[?1049h\e[?25l")

    outcome =
      try do
        with %{} = source <- pick_source(sources),
             {:ok, %{"threads" => threads}} <-
               Command.request(:post, "/api/previous-installs/threads", %{
                 "source" => source["path"]
               }),
             [_ | _] = picked <-
               pick(threads, "Threads in #{source["label"]} (#{source["path"]})", true) do
          import_threads(source, picked)
        end
      after
        IO.write("\e[?25h\e[?1049l")
        stty("isig")
        :shell.start_interactive({:noshell, :cooked})
      end

    case outcome do
      {:done, lines} -> Enum.each(lines, &Mix.shell().info(&1))
      {:error, message} -> Mix.raise(message)
      _ -> Mix.shell().info("Nothing was imported.")
    end
  end

  # `stty` on the VM's own terminal: a port without stdio keeps the VM's.
  defp stty(mode) do
    with path when is_binary(path) <- System.find_executable("stty") do
      port = Port.open({:spawn_executable, path}, [:nouse_stdio, :exit_status, args: [mode]])

      receive do
        {^port, {:exit_status, _}} -> :ok
      end
    end
  end

  defp pick_source([source]), do: source

  defp pick_source(sources) do
    rows =
      for s <- sources, do: %{"id" => s["path"], "title" => s["label"], "project" => s["path"]}

    with [%{"id" => path}] <- pick(rows, "Import threads from", false),
         do: Enum.find(sources, &(&1["path"] == path))
  end

  # One request a thread, so the progress is real and one slow thread shows.
  defp import_threads(source, picked) do
    total = length(picked)

    failed =
      picked
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {thread, n} ->
        IO.write("\e[H\e[2JImporting #{n} of #{total}: #{thread["title"]}\r\n")
        input = %{"source" => source["path"], "threadIds" => [thread["id"]]}

        case Command.request(:post, "/api/previous-installs/import", input, :timer.minutes(30)) do
          {:ok, %{"failed" => [%{"message" => message}]}} -> ["#{thread["title"]}: #{message}"]
          {:ok, _} -> []
          {:error, message} -> ["#{thread["title"]}: #{message}"]
        end
      end)

    {:done, ["Imported #{total - length(failed)} of #{total} threads." | failed]}
  end

  # --- the list ---------------------------------------------------------------------

  # The rows the user chose: the marked ones, or the one under the cursor.
  defp pick(rows, heading, many?) do
    loop(%{
      rows: rows,
      heading: heading,
      many?: many?,
      filter: "",
      cursor: 0,
      marked: MapSet.new()
    })
  end

  defp loop(state) do
    shown = shown(state)
    state = %{state | cursor: state.cursor |> min(length(shown) - 1) |> max(0)}
    draw(state, shown)
    current = Enum.at(shown, state.cursor)

    case key() do
      :quit ->
        []

      :enter ->
        marked = Enum.filter(state.rows, &MapSet.member?(state.marked, &1["id"]))

        cond do
          marked != [] -> marked
          current && !current["imported"] -> [current]
          true -> loop(state)
        end

      :tab when state.many? and current != nil ->
        marked =
          cond do
            current["imported"] ->
              state.marked

            MapSet.member?(state.marked, current["id"]) ->
              MapSet.delete(state.marked, current["id"])

            true ->
              MapSet.put(state.marked, current["id"])
          end

        loop(%{state | marked: marked, cursor: state.cursor + 1})

      :up ->
        loop(%{state | cursor: state.cursor - 1})

      :down ->
        loop(%{state | cursor: state.cursor + 1})

      :page_up ->
        loop(%{state | cursor: state.cursor - page()})

      :page_down ->
        loop(%{state | cursor: state.cursor + page()})

      :backspace ->
        loop(%{state | filter: String.slice(state.filter, 0..-2//1), cursor: 0})

      {:text, text} ->
        loop(%{state | filter: state.filter <> text, cursor: 0})

      _ ->
        loop(state)
    end
  end

  defp shown(%{filter: ""} = state), do: state.rows

  defp shown(state) do
    words = state.filter |> String.downcase() |> String.split()

    Enum.filter(state.rows, fn row ->
      state = if row["settled"], do: "settled", else: "active"
      text = String.downcase("#{row["title"]} #{row["project"]} #{state}")
      Enum.all?(words, &String.contains?(text, &1))
    end)
  end

  defp page, do: max(rows() - 5, 1)

  defp rows do
    case :io.rows() do
      {:ok, rows} -> rows
      _ -> 24
    end
  end

  defp columns do
    case :io.columns() do
      {:ok, columns} -> columns
      _ -> 80
    end
  end

  defp draw(state, shown) do
    height = page()
    top = max(state.cursor - height + 1, 0)
    keys = if state.many?, do: "Tab marks, Enter imports", else: "Enter chooses"

    lines =
      shown
      |> Enum.slice(top, height)
      |> Enum.with_index(top)
      |> Enum.map(fn {row, index} -> line(state, row, index == state.cursor) end)

    marked = if state.many?, do: "  #{MapSet.size(state.marked)} marked", else: ""

    IO.write([
      "\e[H\e[2J\e[1m",
      clip(state.heading),
      "\e[0m\r\n",
      clip(
        "#{length(shown)} of #{length(state.rows)}#{marked}  ·  type to filter, #{keys}, Ctrl-C leaves"
      ),
      "\r\n> ",
      state.filter,
      "\r\n",
      Enum.intersperse(lines, "\r\n")
    ])
  end

  defp line(state, row, current?) do
    mark =
      cond do
        row["imported"] -> " ✓ "
        not state.many? -> "   "
        MapSet.member?(state.marked, row["id"]) -> "[x]"
        true -> "[ ]"
      end

    subagents =
      if (row["subagents"] || 0) > 0, do: " +#{row["subagents"]} subagent threads", else: ""

    day = String.slice(row["updatedAt"] || "", 0, 10)
    settled = if row["settled"], do: "settled"

    detail =
      Enum.reject([row["project"], day, settled], &(&1 in [nil, ""])) |> Enum.join(" · ")

    text = clip("#{mark} #{row["title"]}  (#{detail}#{subagents})")

    cond do
      current? -> ["\e[7m", text, "\e[0m"]
      row["imported"] -> ["\e[2m", text, "\e[0m"]
      true -> text
    end
  end

  defp clip(text), do: String.slice(String.replace(text, ~r/\s+/, " "), 0, columns() - 1)

  defp key do
    case IO.getn("", 1) do
      <<3>> -> :quit
      <<4>> -> :quit
      :eof -> :quit
      "\r" -> :enter
      "\n" -> :enter
      "\t" -> :tab
      <<127>> -> :backspace
      <<8>> -> :backspace
      "\e" -> escape()
      <<c::utf8>> = text when c >= 32 -> {:text, text}
      _ -> :other
    end
  end

  defp escape do
    with "[" <- IO.getn("", 1) do
      case IO.getn("", 1) do
        "A" -> :up
        "B" -> :down
        "5" -> tilde(:page_up)
        "6" -> tilde(:page_down)
        _ -> :other
      end
    else
      _ -> :other
    end
  end

  defp tilde(key) do
    IO.getn("", 1)
    key
  end
end
