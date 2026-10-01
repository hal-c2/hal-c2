defmodule HalC2.Steps.Files.Search do
  @moduledoc """
  Steps for `features/files/search.feature`: `projects.searchEntries` and
  `projects.searchContents` over the socket. The paths a search returns go in
  `context.listing` for the shared "is returned" steps.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  step "{string} holds {string}, {string}, {string} and {string}",
       %{args: [project, a, b, c, d]} = context do
    root = World.project(context, project).root
    for file <- [a, b, c, d], do: write(root, file, contents(file))
    context
  end

  step ~r/^a client searches "(?<project>[^"]+)" for (?<kind>files|folders|image files) named "(?<query>[^"]*)"$/,
       %{args: [project, kind, query]} = context do
    search_entries(context, project, query, kind, 50)
  end

  step "a client searches {string} for files named {string} with a limit of {int}",
       %{args: [project, query, limit]} = context do
    search_entries(context, project, query, "files", limit)
  end

  step "a client searches {string} for files with an empty query", %{args: [project]} = context do
    search_entries(context, project, "", "files", 50)
  end

  step "{string} is ranked first", %{args: [path]} = context do
    assert [^path | _] = context.listing
    context
  end

  step "{string} is ranked before {string}", %{args: [first, second]} = context do
    ranks = Enum.with_index(context.listing) |> Map.new()
    assert ranks[first] && ranks[second], "#{inspect(context.listing)}"
    assert ranks[first] < ranks[second]
    context
  end

  step "{string} is listed first", %{args: [path]} = context do
    assert [^path | _] = context.listing
    context
  end

  # Fuzzy matching also finds entries below the one named ("src/lib" for "src"), so
  # "only" means the named entry leads and nothing of another kind is returned.
  step "only {string} is returned", %{args: [path]} = context do
    assert [^path | _] = context.listing
    {:ok, %{"entries" => entries}} = context.reply

    for entry <- entries do
      case context.search_kind do
        "folders" -> assert entry["kind"] == "directory"
        "image files" -> assert Path.extname(entry["path"]) in ~w(.png .jpg .jpeg .gif .svg .webp)
      end
    end

    context
  end

  step "{string} holds {int} files named like {string}",
       %{args: [project, count, name]} = context do
    root = World.project(context, project).root
    for n <- 1..count, do: write(root, "generated/#{name}-#{n}.ts", "export {};\n")
    context
  end

  step "{int} entries are returned", %{args: [count]} = context do
    assert length(context.listing) == count
    context
  end

  step "{string} changed most recently", %{args: [file]} = context do
    root = World.project(context).root
    hour_ago = System.os_time(:second) - 3600

    for path <- Path.wildcard(Path.join(root, "**/*"), match_dot: false),
        File.regular?(path),
        do: File.touch!(path, hour_ago)

    File.touch!(Path.join(root, file))
    context
  end

  step "{string} contains the line {string}", %{args: [file, line]} = context do
    write(World.project(context).root, file, "// Checkout page.\n#{line}\n")
    Map.put(context, :line, line)
  end

  step "a client searches the contents of {string} for {string}",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{})
  end

  step "a client searches the contents of {string} for {string} with matching case",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{"caseSensitive" => true})
  end

  step "a client searches the contents of {string} for {string} with matching whole words",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{"wholeWord" => true})
  end

  step "a client searches the contents of {string} for {string} with a regular expression",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{"useRegex" => true})
  end

  step "a client searches the contents of {string} for {string} as a regular expression",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{"useRegex" => true})
  end

  step "the line {string} in {string} is returned", %{args: [line, file]} = context do
    assert Enum.any?(context.matches, &(&1["path"] == file and &1["lineContent"] == line)),
           inspect(context.matches)

    context
  end

  step "each match carries its line number and the character range of the match", context do
    assert [_ | _] = context.matches

    for match <- context.matches do
      assert match["lineNumber"] == 2
      assert [_ | _] = match["matchRanges"]

      for %{"start" => start, "end" => stop} <- match["matchRanges"],
          do:
            assert(
              String.downcase(String.slice(match["lineContent"], start, stop - start)) == "total"
            )
    end

    context
  end

  step "matches for the text {string} are returned", %{args: [text]} = context do
    assert [_ | _] = context.matches
    for match <- context.matches, do: assert(match["lineContent"] =~ text)
    context
  end

  step "the result explains why the regular expression was not used", context do
    assert {:ok, %{"regexFallbackError" => reason}} = context.reply
    assert is_binary(reason) and reason != ""
    context
  end

  step "ripgrep is not installed on the environment", context do
    Application.put_env(:hal_c2, :ripgrep, "rg-not-installed")
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:hal_c2, :ripgrep) end)
    context
  end

  step "{string} in {string} is {int} MB and contains {string}",
       %{args: [file, project, mb, text]} = context do
    root = World.project(context, project).root
    write(root, file, "#{text}\n" <> String.duplicate("log line\n", div(mb * 1_048_576, 9)))
    context
  end

  # The notes mention a call to `cart(`, so a literal search for it has a match.
  defp contents("docs/" <> _), do: "Call cart(items) to fill the shopping cart.\n"

  defp contents(file),
    do: if(Path.extname(file) == ".png", do: <<137, 80, 78, 71, 0>>, else: "export {};\n")

  defp write(root, file, contents) do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp search_entries(context, project, query, kind, limit) do
    Mc.ensure(HalC2.Workspace)

    input =
      case kind do
        "files" -> %{"kind" => "file"}
        "folders" -> %{"kind" => "directory"}
        "image files" -> %{"imageOnly" => true}
      end

    {reply, context} =
      World.call(
        context,
        "projects.searchEntries",
        Map.merge(input, %{
          "cwd" => World.project(context, project).root,
          "query" => query,
          "limit" => limit
        })
      )

    assert {:ok, %{"entries" => entries}} = reply

    Map.merge(context, %{
      reply: reply,
      search_kind: kind,
      listing: Enum.map(entries, & &1["path"])
    })
  end

  defp search_contents(context, project, query, options) do
    Mc.ensure(HalC2.Workspace)

    {reply, context} =
      World.call(
        context,
        "projects.searchContents",
        Map.merge(options, %{"cwd" => World.project(context, project).root, "query" => query})
      )

    assert {:ok, %{"matches" => matches}} = reply

    Map.merge(context, %{
      reply: reply,
      matches: matches,
      listing: matches |> Enum.map(& &1["path"]) |> Enum.uniq()
    })
  end
end
