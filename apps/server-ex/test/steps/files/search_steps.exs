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

  step "the MC answers that regular expression search needs ripgrep", context do
    assert {:error, message, %{"_tag" => "ProjectSearchContentsError"}} = context.reply
    assert message =~ "Regex search needs ripgrep"
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

  step "{string} holds {string} and the folder {string}",
       %{args: [project, file, folder]} = context do
    root = World.project(context, project).root
    # The file this step adds is the newest in the project (an empty search
    # ranks by when files last changed, at second precision).
    hour_ago = System.os_time(:second) - 3600

    for path <- Path.wildcard(Path.join(root, "**/*")),
        File.regular?(path),
        do: File.touch!(path, hour_ago)

    write(root, file, contents(file))
    File.mkdir_p!(Path.join(root, folder))
    context
  end

  step "a client searches {string} for image files and folders with an empty query",
       %{args: [project]} = context do
    Mc.ensure(HalC2.Workspace)

    {reply, context} =
      World.call(context, "projects.searchEntries", %{
        "cwd" => World.project(context, project).root,
        "query" => "",
        "limit" => 50,
        "kind" => "directory",
        "imageOnly" => true
      })

    assert {:ok, %{"entries" => entries}} = reply

    Map.merge(context, %{
      reply: reply,
      search_kind: "image files",
      listing: Enum.map(entries, & &1["path"])
    })
  end

  step "{string} holds {int} files named like {string} and only {int} of them are images",
       %{args: [project, count, name, images]} = context do
    root = World.project(context, project).root
    made = for n <- 1..images, do: "generated/#{name}-#{n}.png"
    for file <- made, do: write(root, file, contents("x.png"))

    for n <- 1..(count - images),
        do: write(root, "generated/#{name}-doc-#{n}.ts", "export {};\n")

    Map.put(context, :generated_images, made)
  end

  step "a client searches {string} for image files named {string} with a limit of {int}",
       %{args: [project, query, limit]} = context do
    search_entries(context, project, query, "image files", limit)
  end

  step "the {int} images are returned", %{args: [count]} = context do
    # Those images, and nothing but images: had the limit been applied before
    # the kind filter, the far more numerous other files would crowd them out.
    assert length(context.generated_images) == count

    for file <- context.generated_images,
        do: assert(file in context.listing, "#{file} not in #{inspect(context.listing)}")

    for path <- context.listing,
        do: assert(Path.extname(path) in ~w(.png .jpg .jpeg .gif .svg .webp))

    context
  end

  step "{string} in {string} is one line with {string} after its first {int} characters",
       %{args: [file, project, word, count]} = context do
    root = World.project(context, project).root
    write(root, file, String.duplicate("x", count) <> " " <> word <> "\n")
    context
  end

  step "a client searches the contents of {string} for {string} as plain text",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{})
  end

  step "a client searches the contents of {string} for {string} matching whole words",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{"wholeWord" => true})
  end

  step "a client searches the contents of {string} for {string} as a regular expression matching case",
       %{args: [project, query]} = context do
    search_contents(context, project, query, %{"useRegex" => true, "caseSensitive" => true})
  end

  step "a client searches the contents of {string} for {string} with a limit of {int}",
       %{args: [project, query, limit]} = context do
    search_contents(context, project, query, %{"limit" => limit})
  end

  step "the line is returned", context do
    assert Enum.any?(context.matches, &(&1["lineContent"] == context.line)),
           inspect(context.matches)

    context
  end

  step "the line is not returned", context do
    assert {:ok, %{"matches" => _}} = context.reply

    refute Enum.any?(context.matches, &(&1["lineContent"] == context.line)),
           inspect(context.matches)

    context
  end

  step "the match range starts at character {int} of the line", %{args: [start]} = context do
    assert [%{"matchRanges" => [%{"start" => ^start} | _]} | _] = context.matches
    context
  end

  step ~r/^"(?<file>[^"]+)" in "(?<project>[^"]+)" contains "(?<text>[^"]+)" on (?<count>[\d,]+) lines$/,
       %{args: [file, project, text, count]} = context do
    count = count |> String.replace(",", "") |> String.to_integer()
    root = World.project(context, project).root
    write(root, file, String.duplicate("the #{text} so far\n", count))
    # The file is part of the project's content, whatever the machine's own
    # global ignore file says about its kind.
    File.write!(Path.join(root, ".gitignore"), "!#{file}\n", [:append])
    context
  end

  step "{string} contains {string} once", %{args: [file, text]} = context do
    contents = File.read!(Path.join(World.project(context).root, file))
    lines = String.split(contents, "\n")
    assert Enum.count(lines, &(String.downcase(&1) =~ String.downcase(text))) == 1
    context
  end

  step "no more than {int} matches come from {string}", %{args: [count, file]} = context do
    from = Enum.count(context.matches, &(&1["path"] == file))
    assert from <= count, "#{from} matches from #{file}"
    assert from > 0
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

    matches =
      case reply do
        {:ok, %{"matches" => matches}} -> matches
        {:error, _message, _details} -> []
      end

    Map.merge(context, %{
      reply: reply,
      matches: matches,
      listing: matches |> Enum.map(& &1["path"]) |> Enum.uniq()
    })
  end
end
