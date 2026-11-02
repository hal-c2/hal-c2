defmodule HalC2.Steps.Space.Markdown do
  @moduledoc """
  Steps for `features/space/markdown.feature`. Markdown goes in and out over the socket
  as `space.page.importMarkdown` and `space.page.exportMarkdown`; the files are the
  synthetic ones in `test/fixtures/markdown`. The page last imported is
  `context.imported`, and the last export's reply `context.space_reply`. In a quoted
  string `\\n` and `\\r` stand for a line feed and a carriage return.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Space.Blocks
  alias HalC2.Test.Mc.World

  @fixtures Path.expand("../../fixtures/markdown", __DIR__)

  step "the user imports the Markdown file {string} into {string}",
       %{args: [file, name]} = context do
    import_markdown(context, name, File.read!(Path.join(@fixtures, file)))
  end

  step "the user imports the Markdown {string} into {string}",
       %{args: [markdown, name]} = context do
    import_markdown(context, name, unescape(markdown))
  end

  step "the user imports this Markdown into {string} as {string}:",
       %{args: [name, title]} = context do
    import_markdown(context, name, context.docstring, title)
  end

  step "the page {string} imported from:", %{args: [_title]} = context do
    import_markdown(context, nil, context.docstring)
  end

  step "the user exports the imported page as Markdown", context do
    payload = %{"spaceId" => context.space, "pageId" => context.imported["id"]}
    {reply, context} = World.call(context, "space.page.exportMarkdown", payload)
    Map.put(context, :space_reply, reply)
  end

  step "the Markdown is the file {string} exactly", %{args: [file]} = context do
    assert {:ok, %{"markdown" => markdown}} = context.space_reply
    assert markdown == File.read!(Path.join(@fixtures, file))
    context
  end

  step "the exported Markdown is {string}", %{args: [expected]} = context do
    assert {:ok, %{"markdown" => markdown}} = context.space_reply
    assert markdown == unescape(expected)
    context
  end

  step "the blocks of {string} are of the kinds {string}", %{args: [title, kinds]} = context do
    assert Enum.map_join(blocks(context, title), ", ", & &1["kind"]) == kinds
    context
  end

  step "the raw block of {string} holds:", %{args: [title]} = context do
    assert raw_block(context, title)["text"] == context.docstring
    context
  end

  step "the user changes the raw block of {string} to:", %{args: [title]} = context do
    payload = %{
      "spaceId" => context.space,
      "blockId" => raw_block(context, title)["id"],
      "text" => context.docstring
    }

    {_, context} = World.call!(context, "space.block.update", payload)
    context
  end

  step "{string} has a heading {string} of level {int}",
       %{args: [title, text, level]} = context do
    heading = Enum.find(blocks(context, title), &(&1["kind"] == "heading"))
    assert {heading["text"], heading["level"]} == {text, level}
    context
  end

  defp import_markdown(context, name, markdown, title \\ nil) do
    space = if name, do: context.spaces[name], else: context.space

    payload =
      %{"spaceId" => space, "markdown" => markdown}
      |> then(&if(title, do: Map.put(&1, "title", title), else: &1))

    {%{"page" => page}, context} = World.call!(context, "space.page.importMarkdown", payload)
    Map.put(context, :imported, page)
  end

  defp blocks(context, title) do
    state = Streams.state(Space.stream_id(context.space))
    page = Enum.find(Map.values(StreamState.get(state, "page")), &(&1["title"] == title))
    Blocks.of_page(state, (page || flunk("no page #{inspect(title)}"))["id"])
  end

  defp raw_block(context, title),
    do: Enum.find(blocks(context, title), &(&1["kind"] == "raw")) || flunk("no raw block")

  defp unescape(text), do: text |> String.replace("\\n", "\n") |> String.replace("\\r", "\r")
end
