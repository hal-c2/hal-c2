defmodule HalC2.Space.Rpc do
  @moduledoc """
  The `space.*` RPC methods (`packages/contracts/src/space.ts`) on `HalC2.Space`.
  Refusals are `SpaceError`s, and a page a thread could not be summarised into a
  `SpaceTextGenerationError`.
  """

  alias HalC2.Space

  @doc "Answers `space.<method>` with `input`."
  def handle(method, input) when is_map(input), do: method |> call(input) |> reply()
  def handle(_method, _input), do: reply({:error, :invalid, "The request is an object."})

  defp call("list", _), do: with({:ok, spaces} <- Space.list(), do: {:ok, %{"spaces" => spaces}})
  defp call("create", %{"name" => name}), do: space(Space.create(name))
  defp call("rename", %{"spaceId" => id, "name" => name}), do: space(Space.rename(id, name))

  defp call("delete", %{"spaceId" => id}),
    do: with({:ok, id} <- Space.delete(id), do: {:ok, %{"spaceId" => id}})

  defp call("page.create", %{"spaceId" => s, "title" => title} = i),
    do: page(Space.create_page(s, title, i["parentPageId"]))

  defp call("page.rename", %{"spaceId" => s, "pageId" => p, "title" => title}),
    do: page(Space.rename_page(s, p, title))

  defp call("page.move", %{"spaceId" => s, "pageId" => p} = i) when is_map_key(i, "parentPageId"),
    do: page(Space.move_page(s, p, i["parentPageId"]))

  defp call("page.trash", %{"spaceId" => s, "pageId" => p}), do: page(Space.trash_page(s, p))
  defp call("page.restore", %{"spaceId" => s, "pageId" => p}), do: page(Space.restore_page(s, p))

  defp call("page.delete", %{"spaceId" => s, "pageId" => p}),
    do: with({:ok, ids} <- Space.delete_page(s, p), do: {:ok, %{"deletedPageIds" => ids}})

  defp call("page.exportMarkdown", %{"spaceId" => s, "pageId" => p}),
    do: with({:ok, markdown} <- Space.export_markdown(s, p), do: {:ok, %{"markdown" => markdown}})

  defp call("page.importMarkdown", %{"spaceId" => s, "markdown" => markdown} = i),
    do: page(Space.import_markdown(s, markdown, i["title"], i["parentPageId"]))

  defp call("page.createFromThread", %{"spaceId" => s, "threadId" => t} = i),
    do: page(Space.create_page_from_thread(s, t, i["parentPageId"]))

  defp call("block.insert", %{"spaceId" => s, "pageId" => p, "kind" => _} = i) do
    spec = Map.take(i, ~w(kind text checked linkedPageId))
    block(Space.insert_block(s, p, spec, Map.get(i, "afterBlockId", :last)))
  end

  defp call("block.update", %{"spaceId" => s, "blockId" => b, "text" => text}),
    do: block(Space.update_block(s, b, text))

  defp call("block.setChecked", %{"spaceId" => s, "blockId" => b, "checked" => checked}),
    do: block(Space.set_checked(s, b, checked))

  defp call("block.move", %{"spaceId" => s, "blockId" => b} = i),
    do: block(Space.move_block(s, b, Map.get(i, "afterBlockId", :last)))

  defp call("block.delete", %{"spaceId" => s, "blockId" => b}),
    do: with({:ok, id} <- Space.delete_block(s, b), do: {:ok, %{"blockId" => id}})

  defp call("comment.add", %{"spaceId" => s, "pageId" => p, "body" => body} = i),
    do: comment(Space.add_comment(s, p, i["blockId"], body))

  defp call("comment.resolve", %{"spaceId" => s, "commentId" => c}),
    do: comment(Space.resolve_comment(s, c))

  defp call("comment.reopen", %{"spaceId" => s, "commentId" => c}),
    do: comment(Space.reopen_comment(s, c))

  defp call(method, _input) do
    if method in methods(),
      do: {:error, :invalid, "space.#{method} is missing a required field."},
      else: {:unknown, method}
  end

  @methods ~w(list create rename delete page.create page.rename page.move page.trash
    page.restore page.delete page.exportMarkdown page.importMarkdown page.createFromThread
    block.insert block.update block.setChecked block.move block.delete comment.add
    comment.resolve comment.reopen)

  @doc "The methods after `space.`."
  def methods, do: @methods

  defp space(result), do: with({:ok, space} <- result, do: {:ok, %{"space" => space}})
  defp page(result), do: with({:ok, page} <- result, do: {:ok, %{"page" => page}})
  defp block(result), do: with({:ok, block} <- result, do: {:ok, %{"block" => block}})
  defp comment(result), do: with({:ok, comment} <- result, do: {:ok, %{"comment" => comment}})

  @reasons %{
    invalid: "invalid",
    not_found: "notFound",
    trashed: "trashed",
    not_empty: "notEmpty",
    cycle: "cycle"
  }

  defp reply({:ok, _} = ok), do: ok
  defp reply({:unknown, method}), do: {:error, "space.#{method} is not served by this MC yet"}

  defp reply({:error, reason, message})
       when reason in [:generation_unavailable, :generation_failed] do
    tag = if reason == :generation_unavailable, do: "unavailable", else: "failed"
    {:error, %{"_tag" => "SpaceTextGenerationError", "message" => message, "reason" => tag}}
  end

  defp reply({:error, reason, message}),
    do:
      {:error,
       %{"_tag" => "SpaceError", "message" => message, "reason" => Map.fetch!(@reasons, reason)}}
end
