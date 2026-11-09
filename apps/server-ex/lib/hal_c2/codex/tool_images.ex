defmodule HalC2.Codex.ToolImages do
  @moduledoc """
  Images a Codex tool call returns: a dynamic tool's `inputImage` with a base64
  `data:` URL, or an MCP tool's `image` content block. Each is saved as one of
  the thread's attachments (`HalC2.Attachments.persist/1`) and stands in the
  tool's output as an image block naming it, as a pasted image does on a user
  message, so the image is shown with the tool call (pingdotgg/t3code#23284)
  and its base64 text never reaches the log or the clients.
  """

  @data_url ~r/\Adata:(image\/[a-z0-9.+-]+);base64,([A-Za-z0-9+\/=]+)\z/i

  @doc """
  Tool `fields` (`toolName`, `input`, `output`) with the output's images saved. An
  MCP tool that returns `structuredContent` shows that as its output, so the image
  blocks of its `content` (`item`'s result) are saved apart, as the item's `"images"`.
  """
  def store(fields, thread_id, item \\ %{})

  def store(%{"output" => output} = fields, thread_id, _item) when is_list(output),
    do: %{fields | "output" => Enum.map(output, &image(&1, thread_id))}

  def store(fields, thread_id, %{"result" => %{"content" => content}}) when is_list(content) do
    case for(%{"type" => "image"} = block <- content, do: image(block, thread_id)) do
      [] -> fields
      images -> Map.put(fields, "images", images)
    end
  end

  def store(fields, _thread_id, _item), do: fields

  defp image(%{"type" => "inputImage", "imageUrl" => url} = block, thread_id)
       when is_binary(url) do
    case Regex.run(@data_url, url) do
      [_, mime, _data] -> save(thread_id, String.downcase(mime), url)
      _ -> block
    end
  end

  defp image(%{"type" => "image", "data" => data, "mimeType" => mime} = block, thread_id)
       when is_binary(data) and is_binary(mime) do
    url = "data:#{mime};base64,#{data}"

    if Regex.match?(@data_url, url),
      do: save(thread_id, mime, url),
      else: Map.delete(block, "data")
  end

  defp image(block, _thread_id), do: block

  # An image that cannot be saved (too large, say) is named without its data.
  defp save(thread_id, mime, url) do
    attachment = %{"dataUrl" => url, "mimeType" => mime, "name" => "tool-image"}

    case HalC2.Attachments.persist(%{"threadId" => thread_id, "attachments" => [attachment]}) do
      {:ok, %{"attachments" => [saved]}} ->
        saved

      {:error, %{"message" => message}} ->
        %{"type" => "image", "mimeType" => mime, "error" => message}
    end
  end
end
