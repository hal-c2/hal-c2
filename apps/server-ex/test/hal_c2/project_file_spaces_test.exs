defmodule HalC2.ProjectFileSpacesTest do
  use ExUnit.Case, async: true

  alias HalC2.ProjectFile

  @moduletag :tmp_dir

  @page [%{"path" => "docs/**/*.md", "kind" => "page"}]

  defp put(dir, text), do: File.write!(Path.join(dir, "hal-c2.json"), text)
  defp text(dir), do: File.read!(Path.join(dir, "hal-c2.json"))

  test "every Markdown file is a page without a spaces section", %{tmp_dir: dir} do
    assert {:ok, :default, entries} = ProjectFile.spaces(dir)
    assert ProjectFile.space_kind(entries, "README.md") == "page"
    assert ProjectFile.space_kind(entries, "docs/deep/guide.md") == "page"
    assert ProjectFile.space_kind(entries, "src/app.ts") == nil
  end

  test "a section that does not match the format counts no files", %{tmp_dir: dir} do
    put(dir, ~s({"spaces": {"files": [{"path": "*.md", "kind": "poster"}]}}))
    assert ProjectFile.spaces(dir) == {:error, :invalid}
  end

  test "globs: ** crosses folders, * and ? do not" do
    kind = &ProjectFile.space_kind([%{"path" => &1, "kind" => "page"}], &2)

    assert kind.("*.md", "README.md")
    refute kind.("*.md", "docs/guide.md")
    assert kind.("docs/**/*.md", "docs/guide.md")
    assert kind.("docs/**/*.md", "docs/a/b/guide.md")
    refute kind.("docs/**/*.md", "notes/guide.md")
    assert kind.("**/*.md", "a/b.md")
    assert kind.("notes/to?o.md", "notes/todo.md")
    refute kind.("notes/to?o.md", "notes/to/o.md")
    refute kind.("a.md", "xa.md")
  end

  test "the scan proposes the top and each top folder, leaving out hidden ones" do
    files = ~w(README.md docs/a.md docs/deep/b.md notes/c.md .github/x.md src/app.ts)

    assert ProjectFile.propose_spaces(files) == [
             %{"path" => "*.md", "kind" => "page"},
             %{"path" => "docs/**/*.md", "kind" => "page"},
             %{"path" => "notes/**/*.md", "kind" => "page"}
           ]

    assert ProjectFile.propose_spaces(~w(src/app.ts)) == []
  end

  test "writing the section makes the file when there is none", %{tmp_dir: dir} do
    :ok = ProjectFile.put_spaces(dir, @page)
    assert {:ok, :project, @page} = ProjectFile.spaces(dir)
  end

  test "writing the section after a string member keeps the rest", %{tmp_dir: dir} do
    put(dir, ~s({"name": "shop"}\n))
    :ok = ProjectFile.put_spaces(dir, @page)

    assert {:ok, :project, @page} = ProjectFile.spaces(dir)
    assert text(dir) =~ ~s("name": "shop",)
  end

  test "writing the section into an empty object", %{tmp_dir: dir} do
    put(dir, "{}")
    :ok = ProjectFile.put_spaces(dir, @page)
    assert {:ok, :project, @page} = ProjectFile.spaces(dir)
  end

  test "writing the section replaces the old one and keeps comments", %{tmp_dir: dir} do
    put(dir, """
    {
      // the scripts
      "scripts": [{"name": "Test", "command": "mix test"}],
      "spaces": {"files": [{"path": "*.md", "kind": "page"}]}, /* kept */
      "trailing": true,
    }
    """)

    :ok = ProjectFile.put_spaces(dir, @page)
    written = text(dir)

    assert {:ok, :project, @page} = ProjectFile.spaces(dir)
    assert written =~ "// the scripts"
    assert written =~ "/* kept */"
    assert written =~ ~s("trailing": true)
    refute written =~ ~s("*.md")
  end
end
