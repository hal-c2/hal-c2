defmodule HalC2.Space.Rpc do
  @moduledoc """
  The `space.*` RPC methods (`packages/contracts/src/space.ts`) on `HalC2.Space`.
  Refusals are `SpaceError`s, a page a thread could not be summarised into a
  `SpaceTextGenerationError`, an image that could not be generated a
  `SpaceImageGenerationError`, and a chart that could not be drawn a `SpaceChartError`.
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

  defp call("page.publish", %{"spaceId" => s, "pageId" => p} = i) do
    with {:ok, site} <- Space.publish_page(s, p, Map.take(i, ~w(baseUrl tailscale))),
         do: {:ok, %{"site" => site}}
  end

  defp call("page.unpublish", %{"spaceId" => s, "pageId" => p}),
    do: with({:ok, id} <- Space.unpublish_page(s, p), do: {:ok, %{"pageId" => id}})

  defp call("page.exportMarkdown", %{"spaceId" => s, "pageId" => p}),
    do: with({:ok, markdown} <- Space.export_markdown(s, p), do: {:ok, %{"markdown" => markdown}})

  defp call("page.importMarkdown", %{"spaceId" => s, "markdown" => markdown} = i),
    do: page(Space.import_markdown(s, markdown, i["title"], i["parentPageId"]))

  defp call("page.createFromThread", %{"spaceId" => s, "threadId" => t} = i),
    do: page(Space.create_page_from_thread(s, t, i["parentPageId"]))

  defp call("page.history", %{"spaceId" => s, "pageId" => p} = i) do
    with {:ok, %{versions: versions, next_before: next}} <-
           Space.page_versions(s, p, i["before"], i["limit"]) do
      {:ok, %{"versions" => Enum.map(versions, &version/1), "nextBefore" => next}}
    end
  end

  defp call("page.version", %{"spaceId" => s, "pageId" => p, "version" => v}) do
    with {:ok, read} <- Space.page_version(s, p, v) do
      {:ok,
       %{
         "version" => read.version,
         "at" => read.at,
         "title" => read.title,
         "blocks" => read.blocks
       }}
    end
  end

  defp call("page.restoreVersion", %{"spaceId" => s, "pageId" => p, "version" => v}),
    do: page(Space.restore_page_version(s, p, v))

  defp call("page.askAgent", %{"spaceId" => s, "pageId" => p, "request" => request}),
    do: agent(Space.ask_page_agent(s, p, request))

  defp call("page.stopAgent", %{"spaceId" => s, "pageId" => p}),
    do: agent(Space.stop_page_agent(s, p))

  defp call("page.dismissAgent", %{"spaceId" => s, "pageId" => p}),
    do: with({:ok, _} <- Space.dismiss_page_agent(s, p), do: {:ok, %{"pageId" => p}})

  defp call("block.insert", %{"spaceId" => s, "pageId" => p, "kind" => _} = i) do
    spec = Map.take(i, ~w(kind text checked linkedPageId imageId))
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

  defp call("block.visualize", %{"spaceId" => s, "pageId" => p, "request" => request} = i) do
    after_id = Map.get(i, "afterBlockId", :last)
    block(Space.visualize(s, p, request, i["blockId"], after_id))
  end

  defp call("comment.add", %{"spaceId" => s, "pageId" => p, "body" => body} = i),
    do: comment(Space.add_comment(s, p, i["blockId"], body))

  defp call("comment.resolve", %{"spaceId" => s, "commentId" => c}),
    do: comment(Space.resolve_comment(s, c))

  defp call("comment.reopen", %{"spaceId" => s, "commentId" => c}),
    do: comment(Space.reopen_comment(s, c))

  defp call("deck.create", %{"spaceId" => s, "title" => title}),
    do: deck(Space.create_deck(s, title))

  defp call("deck.createFromPage", %{"spaceId" => s, "pageId" => p}),
    do: deck(Space.create_deck_from_page(s, p))

  defp call("deck.rename", %{"spaceId" => s, "deckId" => d, "title" => title}),
    do: deck(Space.rename_deck(s, d, title))

  defp call("deck.trash", %{"spaceId" => s, "deckId" => d}), do: deck(Space.trash_deck(s, d))
  defp call("deck.restore", %{"spaceId" => s, "deckId" => d}), do: deck(Space.restore_deck(s, d))

  defp call("deck.delete", %{"spaceId" => s, "deckId" => d}),
    do: with({:ok, id} <- Space.delete_deck(s, d), do: {:ok, %{"deckId" => id}})

  defp call("slide.insert", %{"spaceId" => s, "deckId" => d} = i) do
    spec = Map.take(i, ~w(title body))
    slide(Space.insert_slide(s, d, spec, Map.get(i, "afterSlideId", :last)))
  end

  defp call("slide.update", %{"spaceId" => s, "slideId" => id} = i),
    do: slide(Space.update_slide(s, id, Map.take(i, ~w(title body))))

  defp call("slide.move", %{"spaceId" => s, "slideId" => id} = i),
    do: slide(Space.move_slide(s, id, Map.get(i, "afterSlideId", :last)))

  defp call("slide.delete", %{"spaceId" => s, "slideId" => id}),
    do: with({:ok, id} <- Space.delete_slide(s, id), do: {:ok, %{"slideId" => id}})

  defp call("image.add", %{"spaceId" => s, "attachmentId" => a, "name" => name}),
    do: image(Space.add_image(s, a, name))

  defp call("image.generate", %{"spaceId" => s, "prompt" => prompt} = i),
    do: image(Space.generate_image(s, prompt, i["modelSelection"]))

  defp call("image.trash", %{"spaceId" => s, "imageId" => id}),
    do: image(Space.trash_image(s, id))

  defp call("image.restore", %{"spaceId" => s, "imageId" => id}),
    do: image(Space.restore_image(s, id))

  defp call("image.delete", %{"spaceId" => s, "imageId" => id}),
    do: with({:ok, id} <- Space.delete_image(s, id), do: {:ok, %{"imageId" => id}})

  defp call("image.providers", _), do: {:ok, HalC2.Space.ImageGeneration.providers()}

  defp call(method, _input) do
    if method in methods(),
      do: {:error, :invalid, "space.#{method} is missing a required field."},
      else: {:unknown, method}
  end

  @methods ~w(list create rename delete page.create page.rename page.move page.trash
    page.restore page.delete page.publish page.unpublish page.exportMarkdown page.importMarkdown
    page.createFromThread page.history page.version page.restoreVersion page.askAgent
    page.stopAgent page.dismissAgent block.insert block.update block.setChecked block.move
    block.delete block.visualize comment.add comment.resolve comment.reopen deck.create
    deck.createFromPage deck.rename deck.trash deck.restore deck.delete slide.insert
    slide.update slide.move slide.delete image.add image.generate image.trash image.restore
    image.delete image.providers)

  defp agent({:ok, agent}), do: {:ok, %{"agent" => agent}}
  defp agent(refused), do: refused

  @doc "The methods after `space.`."
  def methods, do: @methods

  defp version(version) do
    %{
      "version" => version.version,
      "at" => version.at,
      "author" => version.author,
      "threadTitle" => version.thread_title,
      "restoredFromAt" => version.restored_from_at
    }
  end

  defp space(result), do: with({:ok, space} <- result, do: {:ok, %{"space" => space}})
  defp page(result), do: with({:ok, page} <- result, do: {:ok, %{"page" => page}})
  defp block(result), do: with({:ok, block} <- result, do: {:ok, %{"block" => block}})
  defp comment(result), do: with({:ok, comment} <- result, do: {:ok, %{"comment" => comment}})
  defp deck(result), do: with({:ok, deck} <- result, do: {:ok, %{"deck" => deck}})
  defp slide(result), do: with({:ok, slide} <- result, do: {:ok, %{"slide" => slide}})
  defp image(result), do: with({:ok, image} <- result, do: {:ok, %{"image" => image}})

  @reasons %{
    invalid: "invalid",
    not_found: "notFound",
    trashed: "trashed",
    not_empty: "notEmpty",
    cycle: "cycle",
    unavailable: "unavailable"
  }

  defp reply({:ok, _} = ok), do: ok
  defp reply({:unknown, method}), do: {:error, "space.#{method} is not served by this MC yet"}

  defp reply({:error, reason, message})
       when reason in [:generation_unavailable, :generation_failed] do
    tag = if reason == :generation_unavailable, do: "unavailable", else: "failed"
    {:error, %{"_tag" => "SpaceTextGenerationError", "message" => message, "reason" => tag}}
  end

  defp reply({:error, reason, message})
       when reason in [:chart_unavailable, :chart_failed, :chart_unanswerable] do
    tag = reason |> Atom.to_string() |> String.replace_prefix("chart_", "")
    {:error, %{"_tag" => "SpaceChartError", "message" => message, "reason" => tag}}
  end

  defp reply({:error, reason, message})
       when reason in [:image_unsupported, :image_unavailable, :image_failed] do
    tag = reason |> Atom.to_string() |> String.replace_prefix("image_", "")
    {:error, %{"_tag" => "SpaceImageGenerationError", "message" => message, "reason" => tag}}
  end

  defp reply({:error, reason, message}),
    do:
      {:error,
       %{"_tag" => "SpaceError", "message" => message, "reason" => Map.fetch!(@reasons, reason)}}
end
