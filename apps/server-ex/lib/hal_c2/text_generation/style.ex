defmodule HalC2.TextGeneration.Style do
  @moduledoc """
  How generated commits and pull requests are written, from the project's
  `sourceControlWritingStyle` setting. `HalC2.GitActions` passes `policy/1` and
  `pr_template/3` to `HalC2.TextGeneration`.

  A policy is `%{kind:, commit:, change_request:}`, the instructions added to the
  commit and change request prompts: Conventional Commits, the user's own
  instructions, or the repository's conventions, read from its recent commit
  subjects, AGENTS.md, and, when Claude writes, CLAUDE.md.
  """

  alias HalC2.{Git, TextGeneration}

  @defaults %{
    "mode" => "repo_conventions",
    "customInstructions" => "",
    "followChangeRequestTemplates" => true
  }

  @doc "The writing style that applies to `cwd`'s project, with its defaults."
  def settings(cwd),
    do: Map.merge(@defaults, TextGeneration.settings(cwd)["sourceControlWritingStyle"] || %{})

  @doc "The policy for the writing style that applies to `cwd`."
  def policy(cwd) do
    style = settings(cwd)

    case style["mode"] do
      "conventional_commits" ->
        %{
          kind: "conventional_commits",
          commit:
            "Use Conventional Commits when generating commit subjects. Prefer the narrowest accurate type and include a scope only when it is obvious from the diff.",
          change_request:
            "Keep the change request title concise. Do not force Conventional Commit syntax into the title unless the repository already uses it."
        }

      "custom" ->
        case String.trim(style["customInstructions"] || "") do
          "" -> %{kind: "custom", commit: nil, change_request: nil}
          text -> %{kind: "custom", commit: text, change_request: text}
        end

      _ ->
        repo_conventions(cwd)
    end
  end

  defp repo_conventions(cwd) do
    commit =
      "Follow the repository's established commit message style when examples are available."

    change_request =
      "Follow the repository's established change request title and body style when examples are available."

    subjects =
      case Git.ok(cwd, ~w(log -n 20 --no-merges --pretty=format:%s)) do
        {:ok, out} ->
          out |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        _ ->
          []
      end

    claude? = TextGeneration.driver(TextGeneration.model_selection(cwd, :writer)) == "claudeAgent"

    examples =
      [
        if(subjects != [],
          do: Enum.join(["Recent commit subjects from this repository:" | subjects], "\n")
        ),
        instructions(cwd, "AGENTS.md"),
        if(claude?, do: instructions(cwd, "CLAUDE.md"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if examples == "" do
      %{kind: "repo_conventions", commit: commit, change_request: change_request}
    else
      %{
        kind: "repo_conventions",
        commit: commit <> "\n\n" <> examples,
        change_request: change_request <> "\n\n" <> examples
      }
    end
  end

  # A regular file of at most 20 kB in the checkout itself; links are not followed.
  defp instructions(cwd, name) do
    path = Path.join(cwd, name)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 20_000 <- File.lstat(path),
         {:ok, text} <- File.read(path),
         text when text != "" <- String.trim(text) do
      "Local #{name}:\n#{text}"
    else
      _ -> nil
    end
  end

  # GitHub looks in these folders, in this order, for a template of this name in any
  # capitalisation, as `.md` or `.txt`; the folder form holds one such template.
  @template_places [".github", "", "docs"]
  @template_name "pull_request_template"
  @template_exts [".md", ".txt"]
  @gitlab_template ".gitlab/merge_request_templates/default.md"

  @doc """
  The repository's change request template in the base tree `ref` when the project
  follows templates. On GitHub (`kind`): the first of its template files, or the only
  template in a template folder; exact spellings come before other capitalisations.
  On GitLab: the default merge request template. Other hosts have none. `nil` when
  there is none, or several to choose from.
  """
  def pr_template(cwd, ref, kind \\ "github") do
    if settings(cwd)["followChangeRequestTemplates"] != false, do: detect_template(cwd, ref, kind)
  end

  # Read from the committed tree, so links and files changed in the checkout never count.
  defp detect_template(cwd, ref, "gitlab") do
    with %{} = entry <-
           Enum.find(tree(cwd, ref, [@gitlab_template]), &(&1.path == @gitlab_template)),
         true <- entry.type == "blob" and entry.mode in ["100644", "100755"] do
      blob(cwd, entry)
    else
      _ -> nil
    end
  end

  defp detect_template(cwd, ref, "github") do
    entries =
      Enum.flat_map(@template_places, fn place ->
        tree(cwd, ref, if(place == "", do: [], else: [place <> "/"]))
      end)

    in_place = fn place -> Enum.filter(entries, &(Path.dirname(&1.path) == dir_of(place))) end
    named = fn entry -> entry.path |> Path.basename() |> String.downcase() end

    files =
      Enum.flat_map(@template_places, fn place ->
        in_place.(place)
        |> Enum.filter(&(&1.type == "blob" and plain?(&1) and named.(&1) in template_files()))
        |> Enum.sort_by(&{spelling_rank(&1.path), &1.path})
      end)

    Enum.find_value(files, &blob(cwd, &1)) ||
      folders(in_place, named, cwd, ref)
  end

  defp detect_template(_cwd, _ref, _kind), do: nil

  # The first folder with a template; a folder of several ends the search.
  defp folders(in_place, named, cwd, ref) do
    @template_places
    |> Enum.flat_map(fn place ->
      in_place.(place)
      |> Enum.filter(&(&1.type == "tree" and named.(&1) == @template_name))
      |> Enum.sort_by(&{Path.basename(&1.path) != String.upcase(@template_name), &1.path})
    end)
    |> Enum.reduce_while(nil, fn dir, nil ->
      case dir_templates(cwd, ref, dir.path) do
        [] -> {:cont, nil}
        [template] -> {:halt, template}
        _ambiguous -> {:halt, nil}
      end
    end)
  end

  defp dir_of(""), do: "."
  defp dir_of(place), do: place

  defp template_files, do: Enum.map(@template_exts, &(@template_name <> &1))

  defp plain?(%{mode: mode}), do: mode in ["100644", "100755"]

  # `pull_request_template.md` and `PULL_REQUEST_TEMPLATE.md` are the names GitHub
  # documents; they come before any other spelling.
  defp spelling_rank(path) do
    case Path.basename(path) do
      "pull_request_template.md" -> 0
      "PULL_REQUEST_TEMPLATE.md" -> 1
      "pull_request_template.txt" -> 2
      "PULL_REQUEST_TEMPLATE.txt" -> 3
      _ -> 4
    end
  end

  # The entries directly under `paths` (a folder gives its children), or the root's.
  defp tree(cwd, ref, paths) do
    args = ["ls-tree", "-z", "--full-tree", ref] ++ if(paths == [], do: [], else: ["--" | paths])

    case Git.run(cwd, args, max_bytes: 100_000) do
      {:ok, %{status: 0, out: out, truncated: false}} -> tree_entries(out)
      _ -> []
    end
  end

  defp tree_entries(out) do
    for record <- String.split(out, "\0", trim: true),
        [meta, path] <- [String.split(record, "\t", parts: 2)],
        [mode, type, oid] <- [String.split(meta, " ")],
        type in ["blob", "tree"] and Regex.match?(~r/^[0-9a-f]{40,64}$/, oid),
        do: %{mode: mode, type: type, oid: oid, path: path}
  end

  # The one text or markdown template in a folder; a folder of several leaves the
  # choice to the user. Stops at the second template.
  defp dir_templates(cwd, ref, dir) do
    tree(cwd, ref, [dir <> "/"])
    |> Enum.filter(fn entry ->
      entry.type == "blob" and plain?(entry) and
        String.downcase(Path.extname(entry.path)) in @template_exts
    end)
    |> Enum.reduce_while([], fn entry, found ->
      case blob(cwd, entry) do
        nil -> {:cont, found}
        template when found == [] -> {:cont, [template]}
        template -> {:halt, [template | found]}
      end
    end)
  end

  defp blob(cwd, %{oid: oid}) do
    case Git.run(cwd, ["cat-file", "blob", oid], max_bytes: 8_000) do
      {:ok, %{status: 0, out: out, truncated: truncated}} ->
        case String.trim(out) do
          "" -> nil
          text -> if truncated, do: text <> "\n\n[truncated]", else: text
        end

      _ ->
        nil
    end
  end
end
