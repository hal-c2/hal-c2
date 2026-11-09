defmodule HalC2.CodexToolImagesTest do
  use ExUnit.Case, async: false

  alias HalC2.Codex.ToolImages

  @moduletag :tmp_dir
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, dir)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:hal_c2, :home),
        else: Application.put_env(:hal_c2, :home, previous)
    end)
  end

  defp image, do: %{"type" => "image", "mimeType" => "image/png", "data" => Base.encode64(@png)}

  # Regression: a tool that returned `structuredContent` beside image blocks shows
  # the structured output, and its images were dropped unsaved.
  test "saves the images of a tool's content beside its structured output" do
    item = %{
      "type" => "mcpToolCall",
      "result" => %{
        "structuredContent" => %{"hits" => 1},
        "content" => [%{"type" => "text", "text" => "1 hit"}, image()]
      }
    }

    fields = %{"toolName" => "shop.chart", "input" => %{}, "output" => %{"hits" => 1}}

    assert %{"output" => %{"hits" => 1}, "images" => [%{"type" => "image", "id" => id}]} =
             ToolImages.store(fields, "th-1", item)

    assert File.read!(HalC2.Attachments.path(%{"id" => id})) == @png
    refute JSON.encode!(ToolImages.store(fields, "th-1", item)) =~ Base.encode64(@png)
  end

  test "an output that is the content list keeps its images inline, once" do
    output = [image()]
    fields = %{"toolName" => "shop.chart", "input" => %{}, "output" => output}
    item = %{"result" => %{"content" => output}}

    stored = ToolImages.store(fields, "th-1", item)
    assert [%{"type" => "image", "id" => _}] = stored["output"]
    refute Map.has_key?(stored, "images")
  end

  # Regression: an attachments directory that cannot be written raised inside the
  # Codex notification handler and took the thread's runtime down.
  test "an image that cannot be written is an error block, not a crash" do
    # A file where the attachments directory belongs: it can be neither made nor written.
    File.mkdir_p!(Path.dirname(HalC2.Attachments.dir()))
    File.write!(HalC2.Attachments.dir(), "in the way")

    fields = %{"toolName" => "shop.chart", "input" => %{}, "output" => [image()]}

    assert %{"output" => [%{"type" => "image", "error" => message} = block]} =
             ToolImages.store(fields, "th-1")

    assert is_binary(message)
    refute Map.has_key?(block, "data")
  end
end
