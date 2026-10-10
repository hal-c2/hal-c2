defmodule HalC2.Import.Picker do
  @moduledoc """
  `mix hal_c2.threads.import` and `bin/hal-c2-service threads import`: lists the
  threads of a T3 Code or earlier HAL-C2 install on this machine and imports the ones
  you pick into the running MC (`HalC2.Import.PreviousInstall`), asked of that MC
  over HTTP with its own access token.

  Threads still in play come first, settled ones after and marked as such. Type to
  filter (`active` and `settled` match too), Space marks a thread, Enter imports the
  marked ones (or the one under the cursor), Ctrl-C leaves. The MC must be running; the install is only read.
  """

  alias HalC2.Cluster.Command

  @doc "Runs the picker and prints its outcome; exits 1 on failure."
  def main(args) do
    outcome =
      case args do
        ["import"] -> run()
        _ -> {:error, "Usage: hal-c2-service threads import"}
      end

    case outcome do
      {:ok, lines} ->
        Enum.each(lines, &IO.puts/1)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc "Runs the picker: the lines to tell the user as `{:ok, lines}`, or `{:error, message}`."
  def run do
    case Command.request(:get, "/api/previous-installs") do
      {:ok, %{"sources" => [_ | _] = sources}} ->
        choose(sources)

      {:ok, _} ->
        {:error, "No T3 Code or older HAL-C2 install was found on this machine."}

      {:error, "The MC answered 404" <> _} ->
        {:error, "The running MC does not have this command yet; update or reload it first."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp choose(sources) do
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
      {:done, lines} -> {:ok, lines}
      {:error, message} -> {:error, message}
      _ -> {:ok, ["Nothing was imported."]}
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

  # One request a thread, so one slow thread shows; the MC says how far each is.
  defp import_threads(source, picked) do
    total = length(picked)

    failed =
      picked
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {thread, n} ->
        IO.write([
          "\e[H\e[2J\e[1m",
          clip("Importing #{n} of #{total}: #{thread["title"]}"),
          "\e[0m\r\n",
          bar(n - 1, total),
          "  threads\r\n\r\nReading the thread\r\n"
        ])

        input = %{"source" => source["path"], "threadIds" => [thread["id"]]}
        path = "/api/previous-installs/import"

        case Command.stream(path, input, :timer.minutes(30), &progress/1) do
          {:ok, %{"failed" => [%{"message" => message}]}} -> ["#{thread["title"]}: #{message}"]
          {:ok, _} -> []
          {:error, message} -> ["#{thread["title"]}: #{message}"]
        end
      end)

    {:done, ["Imported #{total - length(failed)} of #{total} threads." | failed]}
  end

  # Where the thread being imported is, on the line under the heading.
  defp progress(%{"stage" => "events", "done" => done, "total" => total}),
    do: IO.write(["\e[4;1H\e[K", bar(done, total), "  #{done} of #{total} events"])

  defp progress(%{"stage" => "files", "done" => done, "total" => total}) do
    IO.write([
      "\e[4;1H\e[K",
      bar(done, total),
      "  attachments and terminal logs, #{done} of #{total} threads"
    ])
  end

  defp progress(_), do: :ok

  defp bar(done, total) do
    width = 30
    filled = if total > 0, do: div(min(done, total) * width, total), else: width
    percent = if total > 0, do: div(min(done, total) * 100, total), else: 100

    [
      "[",
      String.duplicate("█", filled),
      String.duplicate("░", width - filled),
      "] ",
      String.pad_leading("#{percent}%", 4)
    ]
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

      :mark when state.many? and current != nil ->
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
    keys = if state.many?, do: "Space marks, Enter imports", else: "Enter chooses"

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
      " " -> :mark
      "\t" -> :mark
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
