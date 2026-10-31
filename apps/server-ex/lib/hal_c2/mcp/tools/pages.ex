defmodule HalC2.Mcp.Tools.Pages do
  @moduledoc """
  MCP tools that read and write the pages of a Space (`HalC2.Space`), for
  `HalC2.Mcp.Tools`. Spaces belong to the environment, so any thread's agent may
  use them; what it writes names the thread as its author.
  """

  alias HalC2.Space
  alias HalC2.Space.Pages

  @tools ~w(hal_c2_page_list hal_c2_page_read hal_c2_page_block_insert hal_c2_page_block_update
            hal_c2_page_block_delete)

  def tools, do: @tools

  def run("hal_c2_page_list", args, _caller) do
    with {:ok, spaces} <- Space.list(),
         {:ok, spaces} <- only(spaces, args["spaceId"]) do
      {:ok, %{"spaces" => Enum.map(spaces, &with_pages/1)}}
    end
    |> reply()
  end

  def run("hal_c2_page_read", %{"spaceId" => space, "pageId" => page}, _caller) do
    with {:ok, read} <- Space.page(space, page),
         {:ok, markdown} <- Space.export_markdown(space, page) do
      {:ok,
       %{
         "page" => read.page,
         "blocks" => read.blocks,
         "comments" => read.comments,
         "markdown" => markdown
       }}
    end
    |> reply()
  end

  def run(
        "hal_c2_page_block_insert",
        %{"spaceId" => s, "pageId" => p, "kind" => _} = args,
        caller
      ) do
    spec = Map.take(args, ~w(kind text checked linkedPageId))

    s
    |> Space.insert_block(p, spec, Map.get(args, "afterBlockId", :last), author(caller))
    |> block()
  end

  # Text and the tick change together when given; a block given neither is returned as is.
  def run("hal_c2_page_block_update", %{"spaceId" => s, "blockId" => b} = args, caller) do
    s |> Space.edit_block(b, args["text"], args["checked"], author(caller)) |> block()
  end

  def run("hal_c2_page_block_delete", %{"spaceId" => s, "blockId" => b}, _caller) do
    reply(with({:ok, id} <- Space.delete_block(s, b), do: {:ok, %{"blockId" => id}}))
  end

  def run(name, _args, _caller),
    do: {:error, "invalid_request", "#{name} is missing a required argument."}

  defp author(caller), do: Space.agent(caller.thread_id)

  defp only(spaces, nil), do: {:ok, spaces}

  defp only(spaces, id) do
    case Enum.filter(spaces, &(&1["id"] == id)) do
      [] -> {:error, :not_found, "There is no Space #{id}."}
      found -> {:ok, found}
    end
  end

  defp with_pages(space) do
    {:ok, state} = Space.state(space["id"])
    pages = for page <- Pages.live(state), do: Map.take(page, ~w(id title parentPageId))
    space |> Map.take(~w(id name)) |> Map.put("pages", pages)
  end

  defp block(result), do: with({:ok, block} <- result, do: {:ok, %{"block" => block}}) |> reply()

  defp reply({:ok, _} = ok), do: ok
  defp reply({:error, _reason, message}), do: {:error, "invalid_request", message}
end
