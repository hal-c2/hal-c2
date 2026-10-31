defmodule HalC2.Steps.Space.PageTools do
  @moduledoc """
  Steps for the agent's side of `features/space/pages.feature`: the `hal_c2_page_*`
  MCP tools, called as the agent of a thread (`World.mcp_tool/4`). The last tool
  outcome is `context.page_tool`. The Space and its pages come from
  `HalC2.Steps.Space.Pages`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Test.Mc.World

  step "the agent in {string} lists the pages of {string}", %{args: [thread, name]} = context do
    tool(context, thread, "hal_c2_page_list", %{"spaceId" => context.spaces[name]})
  end

  step "the agent sees the page {string}", %{args: [title]} = context do
    assert {:ok, %{"spaces" => [%{"pages" => pages}]}} = context.page_tool
    assert Enum.any?(pages, &(&1["title"] == title))
    context
  end

  step "the agent in {string} reads the page {string}", %{args: [thread, title]} = context do
    tool(context, thread, "hal_c2_page_read", page_ref(context, title))
  end

  step "the agent reads {string}", %{args: [text]} = context do
    assert {:ok, %{"blocks" => blocks, "markdown" => markdown}} = context.page_tool
    assert Enum.map(blocks, & &1["text"]) == [text]
    assert markdown =~ text
    context
  end

  step "the agent in {string} adds the block {string} to {string}",
       %{args: [thread, text, title]} = context do
    arguments = Map.merge(page_ref(context, title), %{"kind" => "paragraph", "text" => text})
    tool(context, thread, "hal_c2_page_block_insert", arguments)
  end

  step "the block {string} was written by the thread {string}",
       %{args: [text, thread]} = context do
    author = Space.agent(World.thread_id(context, thread))
    assert %{"createdBy" => ^author, "updatedBy" => ^author} = block(context, text)
    context
  end

  step "the agent in {string} changes the block {string} to {string}",
       %{args: [thread, text, next]} = context do
    arguments = Map.put(block_ref(context, text), "text", next)
    context = tool(context, thread, "hal_c2_page_block_update", arguments)
    assert {:ok, %{"block" => %{"text" => ^next}}} = context.page_tool
    context
  end

  step "the agent in {string} changes the block {string} to {string} and ticks it",
       %{args: [thread, text, next]} = context do
    arguments = Map.merge(block_ref(context, text), %{"text" => next, "checked" => true})
    tool(context, thread, "hal_c2_page_block_update", arguments)
  end

  step "the agent in {string} deletes the block {string}", %{args: [thread, text]} = context do
    context = tool(context, thread, "hal_c2_page_block_delete", block_ref(context, text))
    assert {:ok, _} = context.page_tool
    context
  end

  step "the agent is refused", context do
    assert {:error, "invalid_request", _} = context.page_tool
    context
  end

  defp tool(context, thread, name, arguments),
    do: Map.put(context, :page_tool, World.mcp_tool(context, thread, name, arguments))

  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp page_ref(context, title) do
    page =
      Enum.find(Map.values(StreamState.get(state(context), "page")), &(&1["title"] == title))

    %{"spaceId" => context.space, "pageId" => page["id"]}
  end

  defp block(context, text),
    do: Enum.find(Map.values(StreamState.get(state(context), "block")), &(&1["text"] == text))

  defp block_ref(context, text),
    do: %{"spaceId" => context.space, "blockId" => block(context, text)["id"]}
end
