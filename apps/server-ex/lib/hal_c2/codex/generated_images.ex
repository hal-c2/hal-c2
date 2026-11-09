defmodule HalC2.Codex.GeneratedImages do
  @moduledoc """
  Images Codex generates with its image tool (`imageGeneration` items) join the
  turn's final reply as markdown embeds of the files Codex saved, as upstream
  T3 Code does (pingdotgg/t3code#19066).

  The runtime keeps, per native turn, the images still being generated, the
  paths saved so far and the reply they join (`state.images`). When the turn
  ends its saved images are appended to the reply; an image saved after that
  is appended then. A turn that was stopped or failed keeps the images already
  saved and drops the ones still generating, and an app-server that is gone
  takes its unfinished images with it.

  The embeds are portable (`embed/1`): a Windows drive path is written with
  forward slashes and a UNC path as a `file:` URL, so every client reads it as
  the MC's file; `host_path/1` reads one back.
  """

  alias HalC2.Orchestration
  alias HalC2.Orchestration.{Entities, TurnWriter}

  # --- the turn's images ----------------------------------------------------------

  @doc "Codex started generating image `native` in native turn `turn_id`."
  def started(state, turn_id, native) do
    case entry(state, turn_id) do
      nil -> state
      entry -> put(state, turn_id, %{entry | running: MapSet.put(entry.running, native)})
    end
  end

  @doc """
  Codex finished image `item` of native turn `turn_id`: a saved one joins the
  reply, now if its turn has ended. A failed one, or one with no saved file,
  adds nothing.
  """
  def completed(state, turn_id, %{"id" => native} = item) do
    case entry(state, turn_id) do
      nil ->
        state

      entry ->
        saved = entry.saved ++ List.wrap(saved_path(item))
        entry = %{entry | running: MapSet.delete(entry.running, native), saved: saved}
        entry = if entry.ended, do: project(state, turn_id, entry), else: entry
        put(state, turn_id, entry)
    end
  end

  @doc """
  The turn's agent message `item` finished: a final reply (no phase, or
  `final_answer`) the thread shows is the one its images join, the latest one.
  """
  def answered(%{turn: %{native_turn_id: turn_id}} = state, %{"id" => native} = item)
      when is_binary(turn_id) do
    with true <- item["phase"] in [nil, "final_answer"],
         %{id: item_id, message: message} when is_binary(message) <- state.items[native],
         %{} = entry <- entry(state, turn_id) do
      put(state, turn_id, %{entry | answer: %{item: item_id, message: message}})
    else
      _ -> state
    end
  end

  def answered(state, _item), do: state

  @doc """
  The current turn ends as `status`; `stream` is `:ended` when its app-server
  is gone. Its saved images join the reply; images still generating stay
  awaited only after a completed turn whose app-server is still there.
  """
  def turn_ended(%{turn: %{native_turn_id: turn_id}} = state, status, stream)
      when is_binary(turn_id) do
    case Map.get(images(state), turn_id) do
      nil ->
        state

      entry ->
        running =
          if status == "completed" and stream == :open, do: entry.running, else: MapSet.new()

        entry = project(state, turn_id, %{entry | running: running, ended: true})
        put(state, turn_id, entry)
    end
  end

  def turn_ended(state, _status, _stream), do: state

  @doc "The app-server is gone: images it was still generating never arrive."
  def forget(state), do: Map.put(state, :images, %{})

  defp images(state), do: Map.get(state, :images, %{})

  # A turn's entry, made for the current turn the first time it is needed; an
  # unknown turn that is not the current one has none.
  defp entry(state, turn_id) do
    case Map.get(images(state), turn_id) do
      nil ->
        case state.turn do
          %{native_turn_id: ^turn_id, ids: ids} ->
            %{running: MapSet.new(), saved: [], answer: nil, ids: ids, ended: false}

          _ ->
            nil
        end

      entry ->
        entry
    end
  end

  # An ended turn's entry goes once nothing is left to arrive for it, and an
  # open one is kept only while it holds an image or a reply to show them under.
  defp put(state, turn_id, entry) do
    done? =
      if entry.ended,
        do: MapSet.size(entry.running) == 0,
        else: entry.saved == [] and MapSet.size(entry.running) == 0 and entry.answer == nil

    images =
      if done?,
        do: Map.delete(images(state), turn_id),
        else: Map.put(images(state), turn_id, entry)

    Map.put(state, :images, images)
  end

  defp saved_path(%{"status" => "failed"}), do: nil
  defp saved_path(%{"failure" => failure}) when failure not in [nil, ""], do: nil

  defp saved_path(%{"savedPath" => path}) when is_binary(path),
    do: if(String.trim(path) == "", do: nil, else: path)

  defp saved_path(_item), do: nil

  # Appends the saved images to the reply, making a reply of the images alone
  # when the turn had none. Appending is idempotent, so the whole list goes each time.
  defp project(_state, _turn_id, %{saved: []} = entry), do: entry

  defp project(state, turn_id, %{answer: nil} = entry) do
    native = "generated-images-#{turn_id}"
    writer = %{state | turn: %{ids: entry.ids}, items: %{}}
    text = append_embeds("", entry.saved)

    writer =
      writer
      |> TurnWriter.ensure_item(native, :assistant)
      |> TurnWriter.finish_item(native, "completed", fn entity ->
        Map.merge(entity, %{"text" => text, "streaming" => false})
      end)

    %{id: item_id, message: message} = writer.items[native]
    %{entry | answer: %{item: item_id, message: message}}
  end

  defp project(state, _turn_id, %{answer: %{item: item_id, message: message}} = entry) do
    at = Entities.now()

    with_images = fn entity ->
      entity
      |> Map.put("text", append_embeds(entity["text"] || "", entry.saved))
      |> Map.put("updatedAt", at)
    end

    TurnWriter.commit(state, fn stream ->
      [
        Orchestration.upsert(stream, "turn-item", item_id, with_images),
        Orchestration.upsert(stream, "message", message, with_images)
      ]
    end)

    entry
  end

  # --- markdown --------------------------------------------------------------------

  @doc """
  `text` with an embed appended for each of `paths` it does not already show
  as an image, each once, in order. An unclosed fence, comment or raw HTML
  block at its end is closed first, so it cannot swallow them.
  """
  def append_embeds(text, paths) do
    shown = text |> shown_paths() |> MapSet.new(&comparable/1)

    {missing, _} =
      Enum.reduce(paths, {[], shown}, fn path, {missing, seen} ->
        key = comparable(path)
        if key in seen, do: {missing, seen}, else: {[path | missing], MapSet.put(seen, key)}
      end)

    case Enum.reverse(missing) do
      [] ->
        text

      missing ->
        text = close_trailing_block(text)
        embeds = Enum.map_join(missing, "\n\n", &embed/1)
        if text == "", do: embeds, else: text <> "\n\n" <> embeds
    end
  end

  @doc """
  The markdown image for a saved file: Windows drive paths with forward
  slashes, UNC paths as `file:` URLs, and the characters clients would read
  otherwise (`%?#&\\`, line breaks, `<>`) escaped.
  """
  def embed(path) do
    destination =
      cond do
        drive_path?(path) -> String.replace(path, "\\", "/")
        unc_path?(path) -> "file:" <> String.replace(path, "\\", "/")
        true -> path
      end

    escaped =
      destination
      |> String.replace(~r/[%?#&\\\r\n]/, fn char -> URI.encode_www_form(char) end)
      |> String.replace(~r/[<>]/, "\\\\\\0")

    "![](<#{escaped}>)"
  end

  @doc """
  The file a markdown image destination names on the MC that wrote it, or
  `nil` for a web address: `embed/1` read back, and the raw Windows paths
  Codex itself writes.
  """
  def host_path(destination) do
    raw =
      case Regex.run(~r/\A<(.*)>\z/s, destination) do
        [_, inner] -> inner
        _ -> destination
      end

    if (drive_path?(raw) and String.contains?(raw, "\\")) or unc_path?(raw) do
      raw
    else
      raw
      |> String.replace(~r/\\([!-\/:-@\[-`{-~])/, "\\1")
      |> URI.decode()
      |> file_path()
    end
  end

  defp file_path("file:" <> rest) do
    case rest do
      "///" <> path ->
        if Regex.match?(~r/\A[A-Za-z]:/, path),
          do: String.replace(path, "/", "\\"),
          else: "/" <> path

      "//" <> unc ->
        "\\\\" <> String.replace(unc, "/", "\\")

      path ->
        path
    end
  end

  defp file_path(path) do
    cond do
      Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]+:/, path) -> nil
      drive_path?(path) -> String.replace(path, "/", "\\")
      true -> path
    end
  end

  defp drive_path?(path), do: Regex.match?(~r/\A[A-Za-z]:[\\\/]/, path)
  defp unc_path?(path), do: String.starts_with?(path, "\\\\")

  # Paths compare as Windows compares them: either slash, any case.
  defp comparable(path) do
    slashed = String.replace(path, "\\", "/")

    if drive_path?(path) or String.starts_with?(slashed, "//"),
      do: String.downcase(slashed),
      else: slashed
  end

  # The files `text` shows as images: inline images and reference images, not
  # links, code, comments or escaped ones.
  defp shown_paths(text) do
    {blocks, _open} = blocks(text)
    prose = for {:prose, chunk} <- blocks, do: chunk
    prose = Enum.map(prose, &Regex.replace(~r/(`+)(?:(?!\1).)+?\1/s, &1, ""))

    definitions =
      for line <- Enum.flat_map(prose, &String.split(&1, ~r/\r\n|\r|\n/)),
          [_, label, dest] <-
            [Regex.run(~r/\A {0,3}\[([^\]]+)\]:[ \t]*(<[^>\n]*>|\S+)/, line)],
          into: %{},
          do: {label_key(label), dest}

    Enum.flat_map(prose, fn chunk ->
      inline =
        for [_, dest] <-
              Regex.scan(
                ~r/(?<!\\)!\[[^\]]*\]\([ \t]*(<(?:[^<>\\\n]|\\.)*>|[^\s)]+)(?:[ \t]+"[^"]*")?[ \t]*\)/,
                chunk
              ),
            do: dest

      references =
        for [_, alt | label] <- Regex.scan(~r/(?<!\\)!\[([^\]]*)\](?:\[([^\]]*)\])?(?!\()/, chunk),
            dest = definitions[label_key(if label in [[], [""]], do: alt, else: hd(label))],
            dest,
            do: dest

      inline ++ references
    end)
    |> Enum.flat_map(&List.wrap(host_path(&1)))
  end

  defp label_key(label), do: label |> String.downcase() |> String.split() |> Enum.join(" ")

  # The text in blocks: `{:prose, text}` and `{:code, text}` (fenced code,
  # comments and raw HTML blocks), with what an unclosed last block needs to end.
  defp blocks(text) do
    {blocks, open} =
      text
      |> String.split(~r/(?<=\n)/)
      |> Enum.reduce({[], nil}, fn line, {blocks, open} ->
        case open do
          nil ->
            case opens(line) do
              nil ->
                {[{:prose, line} | blocks], nil}

              closer ->
                {[{:code, line} | blocks],
                 if(closes?(closer, line, :first), do: nil, else: closer)}
            end

          closer ->
            {[{:code, line} | blocks], if(closes?(closer, line, :later), do: nil, else: closer)}
        end
      end)

    {Enum.reverse(blocks), open}
  end

  defp opens(line) do
    cond do
      match = Regex.run(~r/\A {0,3}(`{3,}|~{3,})/, line) ->
        {:fence, Enum.at(match, 1)}

      Regex.match?(~r/\A {0,3}<!--/, line) ->
        {:html, "-->", "-->"}

      match = Regex.run(~r/\A {0,3}<(script|pre|style|textarea)(?=[\s>]|\z)/i, line) ->
        tag = Enum.at(match, 1)
        {:html, "</#{tag}>", "</#{String.downcase(tag)}>"}

      true ->
        nil
    end
  end

  defp closes?({:fence, _}, _line, :first), do: false

  defp closes?({:fence, fence}, line, :later) do
    case Regex.run(~r/\A {0,3}(`{3,}|~{3,})[\t ]*\r?\n?\z/, line) do
      [_, closing] ->
        String.first(closing) == String.first(fence) and
          String.length(closing) >= String.length(fence)

      _ ->
        false
    end
  end

  defp closes?({:html, _, end_tag}, line, _),
    do: String.contains?(String.downcase(line), end_tag)

  defp close_trailing_block(text) do
    case elem(blocks(text), 1) do
      nil -> text
      {:fence, fence} -> line_end(text) <> fence
      {:html, closer, _} -> line_end(text) <> closer
    end
  end

  defp line_end(text), do: if(Regex.match?(~r/[\r\n]\z/, text), do: text, else: text <> "\n")
end
