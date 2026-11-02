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
  alias HalC2.Space.{Blocks, Markdown}
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

  step "the user makes {string} a level {int} heading", %{args: [text, level]} = context do
    payload = %{
      "spaceId" => context.space,
      "blockId" => block_id(context, text),
      "level" => level
    }

    {reply, context} = World.call(context, "space.block.update", payload)
    Map.put(context, :reply, reply)
  end

  step "the table of {string} has the rows:", %{args: [title]} = context do
    assert table(context, title)["table"]["rows"] == context.datatable.raw
    context
  end

  step "the columns of the table of {string} are aligned {string}",
       %{args: [title, aligns]} = context do
    assert Enum.join(table(context, title)["table"]["align"], ", ") == aligns
    context
  end

  step "the first row's {string} in the table of {string} reads {string}",
       %{args: [column, title, text]} = context do
    %{"table" => %{"rows" => [head, first | _]}} = table(context, title)
    assert Enum.at(first, Enum.find_index(head, &(&1 == column))) == text
    context
  end

  step "the user changes the {string} of {string} in the table of {string} to {string}",
       %{args: [column, row, title, text]} = context do
    %{"table" => %{"rows" => [head | _] = rows}} = table(context, title)

    edit_table(context, title, %{
      "type" => "setCell",
      "row" => Enum.find_index(rows, &(hd(&1) == row)),
      "column" => Enum.find_index(head, &(&1 == column)),
      "text" => text
    })
  end

  step "the user adds a row to the end of the table of {string}", %{args: [title]} = context do
    at = length(table(context, title)["table"]["rows"])
    edit_table(context, title, %{"type" => "insertRow", "at" => at})
  end

  step "the user adds a column to the end of the table of {string}",
       %{args: [title]} = context do
    at = length(table(context, title)["table"]["align"])
    edit_table(context, title, %{"type" => "insertColumn", "at" => at})
  end

  step "the user removes the last row of the table of {string}", %{args: [title]} = context do
    last = length(table(context, title)["table"]["rows"]) - 1
    edit_table(context, title, %{"type" => "deleteRow", "row" => last})
  end

  step "the user removes the last column of the table of {string}",
       %{args: [title]} = context do
    last = length(table(context, title)["table"]["align"]) - 1
    edit_table(context, title, %{"type" => "deleteColumn", "column" => last})
  end

  step "the user adds a table to {string} of the rows:", %{args: [title]} = context do
    payload = %{
      "spaceId" => context.space,
      "pageId" =>
        hd(blocks(context, title) ++ [%{"pageId" => page_id(context, title)}])["pageId"],
      "kind" => "table",
      "table" => %{"rows" => context.datatable.raw}
    }

    {_, context} = World.call!(context, "space.block.insert", payload)
    context
  end

  step "{string} has a code block in {string} holding:",
       %{args: [title, language]} = context do
    code = Enum.find(blocks(context, title), &(&1["kind"] == "code")) || flunk("no code block")
    assert {code["language"], code["text"]} == {language, context.docstring}
    context
  end

  step "the user makes the code block of {string} {string} code holding:",
       %{args: [title, language]} = context do
    code = Enum.find(blocks(context, title), &(&1["kind"] == "code")) || flunk("no code block")

    payload = %{
      "spaceId" => context.space,
      "blockId" => code["id"],
      "text" => context.docstring,
      "language" => language
    }

    {_, context} = World.call!(context, "space.block.update", payload)
    context
  end

  step "the list items of {string} are:", %{args: [title]} = context do
    [_header | rows] = context.datatable.raw

    items =
      for %{"kind" => kind} = block <- blocks(context, title),
          kind in Markdown.lists(),
          do: [kind, to_string(block["depth"] || 0), block["text"]]

    assert items == rows
    context
  end

  step "the user adds the numbered item {string} after {string}",
       %{args: [text, after_text]} = context do
    after_id = block_id(context, after_text)
    state = Streams.state(Space.stream_id(context.space))

    payload = %{
      "spaceId" => context.space,
      "pageId" => StreamState.get(state, "block")[after_id]["pageId"],
      "kind" => "numbered",
      "text" => text,
      "afterBlockId" => after_id
    }

    {_, context} = World.call!(context, "space.block.insert", payload)
    context
  end

  step "the user starts the list at {string} from {int}", %{args: [text, start]} = context do
    update_block(context, text, %{"start" => start})
  end

  step "the user nests {string} {int} deep", %{args: [text, depth]} = context do
    update_block(context, text, %{"depth" => depth})
  end

  step "{string} has a callout holding:", %{args: [title]} = context do
    assert callout(context, title)["text"] == context.docstring
    context
  end

  step "{string} has a {string} callout {string}", %{args: [title, alert, text]} = context do
    assert Map.take(callout(context, title), ~w(alert text)) == %{
             "alert" => alert,
             "text" => text
           }

    context
  end

  step "the user makes {string} a {string} alert", %{args: [text, alert]} = context do
    update_block(context, text, %{"alert" => alert})
  end

  step "the user makes {string} a plain quote", %{args: [text]} = context do
    update_block(context, text, %{"alert" => nil})
  end

  # An update whose reply a later step may check, as `context.reply`.
  defp update_block(context, text, fields) do
    payload =
      Map.merge(%{"spaceId" => context.space, "blockId" => block_id(context, text)}, fields)

    {reply, context} = World.call(context, "space.block.update", payload)
    Map.put(context, :reply, reply)
  end

  defp callout(context, title),
    do: Enum.find(blocks(context, title), &(&1["kind"] == "callout")) || flunk("no callout")

  defp edit_table(context, title, edit) do
    payload = %{
      "spaceId" => context.space,
      "blockId" => table(context, title)["id"],
      "edit" => edit
    }

    {_, context} = World.call!(context, "space.block.editTable", payload)
    context
  end

  defp table(context, title),
    do: Enum.find(blocks(context, title), &(&1["kind"] == "table")) || flunk("no table")

  defp block_id(context, text) do
    state = Streams.state(Space.stream_id(context.space))
    block = Enum.find(StreamState.list(state, "block"), &(&1["text"] == text))
    (block || flunk("no block #{inspect(text)}"))["id"]
  end

  defp page_id(context, title) do
    state = Streams.state(Space.stream_id(context.space))
    Enum.find(Map.values(StreamState.get(state, "page")), &(&1["title"] == title))["id"]
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
