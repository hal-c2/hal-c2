defmodule HalC2.Space do
  @moduledoc """
  Spaces: Pages that people and agents write together, and slide decks
  (`features/space/`).

  The `spaces` stream indexes the Spaces, one `space` entity each, and each Space's
  own `space:<id>` stream holds its `page`, `block`, `comment`, `image`, `site`, `deck`, `slide`
  and `pageAgent` entities. Every change is a `HalC2.Streams.transact/3` on one of them, so the
  event log is the only record and clients follow both streams through the stream shape.
  The decisions live in `HalC2.Space.Pages`, `HalC2.Space.Blocks`, `HalC2.Space.Images`,
  `HalC2.Space.Sites` and `HalC2.Space.Decks`.

  An image's bytes are the one thing not in the log: they are a file
  (`HalC2.Space.ImageFile`), written before the entity that names it and removed after
  the entity is gone, so no entity names a missing file. A crash between the two can
  only leave an unnamed file behind.

  Replies are `{:ok, value}` or `{:error, reason, message}`; an author is
  `%{"type" => "user"}` or `%{"type" => "agent", "threadId" => id}`.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.{Patch, StreamState, Streams}

  alias HalC2.Space.{
    Blocks,
    Decks,
    History,
    ImageFile,
    ImageGeneration,
    Images,
    Markdown,
    PageAgent,
    Pages,
    Sites
  }

  @index "spaces"

  @doc "The stream that lists the Spaces."
  def index, do: @index

  @doc "The stream of the Space `id`."
  def stream_id(id), do: "space:" <> id

  @user %{"type" => "user"}

  @doc "The author of an edit the user makes."
  def user, do: @user

  @doc "The author of an edit the agent of `thread_id` makes."
  def agent(thread_id), do: %{"type" => "agent", "threadId" => thread_id}

  # --- Spaces -------------------------------------------------------------------------

  @doc """
  The Spaces in the order they were made; Personal first, made when there are none.
  That one write is accepted from read-only callers (`space.list`, `hal_c2_page_list`):
  it makes the Space any first look would find.
  """
  def list do
    Streams.transact(@index, :space, fn state ->
      {changes, spaces} = seeded(state)
      {changes, {:ok, spaces}}
    end)
  end

  def create(name) do
    with {:ok, name} <- name(name) do
      space = new_space(name)

      Streams.transact(@index, :space, fn state ->
        {changes, _} = seeded(state)
        {changes ++ [{"space", space["id"], Patch.diff(nil, space)}], {:ok, space}}
      end)
    end
  end

  # The Spaces of the index, with the change that makes Personal when there are none:
  # whoever looks first, by listing or by making a Space, finds Personal there.
  defp seeded(state) do
    case StreamState.list(state, "space") do
      [] ->
        space = new_space("Personal")
        {[{"space", space["id"], Patch.diff(nil, space)}], [space]}

      spaces ->
        {[], spaces}
    end
  end

  def rename(id, name) do
    with {:ok, name} <- name(name) do
      Streams.transact(@index, :space, fn state ->
        case StreamState.get(state, "space")[id] do
          nil ->
            {[], no_space(id)}

          %{"name" => ^name} = space ->
            {[], {:ok, space}}

          space ->
            next = %{space | "name" => name, "updatedAt" => Entities.now()}
            {[{"space", id, Patch.diff(space, next)}], {:ok, next}}
        end
      end)
    end
  end

  @doc "Deletes a Space with no pages, decks or images, in the trash or out of it."
  def delete(id) do
    # Decided in the Space's stream, so nothing can be made in it meanwhile.
    Streams.transact(stream_id(id), :space, fn state ->
      if Enum.all?(~w(page deck image), &(StreamState.get(state, &1) == %{})) do
        reply =
          Streams.transact(@index, :space, fn index ->
            if StreamState.get(index, "space")[id],
              do: {[{"space", id, Patch.delete()}], {:ok, id}},
              else: {[], no_space(id)}
          end)

        {[], reply}
      else
        {[], {:error, :not_empty, "Empty the Space, trash included, before deleting it."}}
      end
    end)
  end

  defp new_space(name) do
    at = Entities.now()
    %{"id" => HalC2.Environment.uuid4(), "name" => name, "createdAt" => at, "updatedAt" => at}
  end

  defp name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :invalid, "A Space needs a name."}
      name -> {:ok, name}
    end
  end

  defp name(_), do: {:error, :invalid, "A Space needs a name."}

  defp no_space(id), do: {:error, :not_found, "There is no Space #{id}."}

  # --- pages, blocks and comments -----------------------------------------------------

  @doc """
  Decides `fun.(state)` in the Space's stream, refusing a Space that does not exist.
  `fun` returns `{changes, reply}`, as `HalC2.Space.Pages` commands do.
  """
  def transact(space_id, fun) when is_binary(space_id) do
    Streams.transact(stream_id(space_id), :space, fn state ->
      # The index is asked from inside the Space's stream: a delete decides there too.
      if Streams.get(@index, "space", space_id),
        do: fun.(state) |> and_sites(state),
        else: {[], no_space(space_id)}
    end)
  end

  def transact(_space_id, _fun), do: {:error, :invalid, "spaceId is required."}

  # Whatever a command does to pages, their sites follow in the same step.
  defp and_sites({changes, reply}, state) do
    if Sites.affected?(state, changes),
      do: {changes ++ Sites.follow(state, with_changes(state, changes), changes), reply},
      else: {changes, reply}
  end

  @doc "The Space's stream state, for reads."
  def state(space_id) do
    if Streams.get(@index, "space", space_id),
      do: {:ok, Streams.state(stream_id(space_id))},
      else: no_space(space_id)
  end

  def create_page(space_id, title, parent_id \\ nil),
    do: transact(space_id, &Pages.create(&1, space_id, title, parent_id))

  def rename_page(space_id, id, title), do: transact(space_id, &Pages.rename(&1, id, title))
  def move_page(space_id, id, parent_id), do: transact(space_id, &Pages.move(&1, id, parent_id))
  def trash_page(space_id, id), do: transact(space_id, &Pages.trash(&1, id))
  def restore_page(space_id, id), do: transact(space_id, &Pages.restore(&1, id))

  def delete_page(space_id, id, author \\ @user),
    do: transact(space_id, &Pages.delete(&1, id, author))

  def insert_block(space_id, page_id, spec, after_id \\ :last, author \\ @user),
    do: transact(space_id, &Blocks.insert(&1, page_id, spec, after_id, author))

  def update_block(space_id, id, text, author \\ @user),
    do: transact(space_id, &Blocks.update_text(&1, id, text, author))

  def set_checked(space_id, id, checked, author \\ @user),
    do: transact(space_id, &Blocks.set_checked(&1, id, checked, author))

  def edit_block(space_id, id, text, checked, author \\ @user),
    do: transact(space_id, &Blocks.edit(&1, id, text, checked, author))

  def move_block(space_id, id, after_id, author \\ @user),
    do: transact(space_id, &Blocks.move(&1, id, after_id, author))

  def delete_block(space_id, id, author \\ @user),
    do: transact(space_id, &Blocks.delete(&1, id, author))

  def add_comment(space_id, page_id, block_id, body, author \\ @user),
    do: transact(space_id, &Blocks.comment(&1, page_id, block_id, body, author))

  def resolve_comment(space_id, id), do: transact(space_id, &Blocks.resolve(&1, id))
  def reopen_comment(space_id, id), do: transact(space_id, &Blocks.reopen(&1, id))

  def create_deck(space_id, title), do: transact(space_id, &Decks.create(&1, space_id, title))

  def create_deck_from_page(space_id, page_id),
    do: transact(space_id, &Decks.create_from_page(&1, space_id, page_id))

  def rename_deck(space_id, id, title), do: transact(space_id, &Decks.rename(&1, id, title))
  def trash_deck(space_id, id), do: transact(space_id, &Decks.trash(&1, id))
  def restore_deck(space_id, id), do: transact(space_id, &Decks.restore(&1, id))
  def delete_deck(space_id, id), do: transact(space_id, &Decks.delete(&1, id))

  def insert_slide(space_id, deck_id, spec, after_id \\ :last),
    do: transact(space_id, &Decks.insert_slide(&1, deck_id, spec, after_id))

  def update_slide(space_id, id, fields),
    do: transact(space_id, &Decks.update_slide(&1, id, fields))

  def move_slide(space_id, id, after_id),
    do: transact(space_id, &Decks.move_slide(&1, id, after_id))

  def delete_slide(space_id, id), do: transact(space_id, &Decks.delete_slide(&1, id))

  @doc "A page with its blocks and comments, trashed or not."
  def page(space_id, page_id) do
    with {:ok, state} <- state(space_id) do
      case Pages.get(state, page_id) do
        nil ->
          {:error, :not_found, "There is no page #{page_id} in this Space."}

        page ->
          {:ok,
           %{
             page: page,
             blocks: Blocks.of_page(state, page_id),
             comments: Blocks.comments(state, page_id)
           }}
      end
    end
  end

  # --- history -------------------------------------------------------------------------

  @doc "See `HalC2.Space.History.versions/4`."
  defdelegate page_versions(space_id, page_id, before \\ nil, limit \\ nil),
    to: History,
    as: :versions

  @doc "See `HalC2.Space.History.read/3`."
  defdelegate page_version(space_id, page_id, version), to: History, as: :read

  @doc """
  Makes the page look like `version` again, as a new edit (`HalC2.Space.History`). The
  version is read before the stream decides: what it held never changes.
  """
  def restore_page_version(space_id, page_id, version, author \\ @user) do
    with {:ok, read} <- History.read(space_id, page_id, version) do
      transact(space_id, &History.restore(&1, page_id, read, author))
    end
  end

  # --- the agent of a page ----------------------------------------------------------------

  @doc "See `HalC2.Space.PageAgent.ask/3`."
  defdelegate ask_page_agent(space_id, page_id, request), to: PageAgent, as: :ask

  @doc "See `HalC2.Space.PageAgent.stop/2`."
  defdelegate stop_page_agent(space_id, page_id), to: PageAgent, as: :stop

  @doc "See `HalC2.Space.PageAgent.dismiss/2`."
  defdelegate dismiss_page_agent(space_id, page_id), to: PageAgent, as: :dismiss

  # --- images --------------------------------------------------------------------------

  @doc """
  Keeps an upload (`attachments.createUploadUrl`) as an image of the Space, if its
  content is a real image; `extra` sets fields such as `prompt`. The upload is used up
  either way.
  """
  def add_image(space_id, attachment_id, name, extra \\ %{}, author \\ @user) do
    with {:ok, _} <- state(space_id),
         {:ok, name} <- Images.name(name),
         {:ok, id, file} <- ImageFile.take(attachment_id) do
      case transact(space_id, &Images.add(&1, space_id, id, name, file, extra, author)) do
        {:ok, _} = kept ->
          kept

        refused ->
          ImageFile.remove(id)
          refused
      end
    end
  end

  @doc """
  An image from a prompt, made by the provider of `selection` or else the first that can
  (`HalC2.Space.ImageGeneration`). With none to make it, or one that fails, there is no
  image.
  """
  def generate_image(space_id, prompt, selection \\ nil) do
    with {:ok, _} <- state(space_id),
         {:ok, prompt} <- Images.prompt(prompt) do
      case ImageGeneration.generate(prompt, selection) do
        {:ok, upload, used} ->
          extra = %{"prompt" => prompt, "generatedBy" => used}

          with {:error, :invalid, message} <-
                 add_image(space_id, upload, Images.name_from(prompt), extra),
               do: {:error, :image_failed, message}

        {:error, :unsupported, message} ->
          {:error, :image_unsupported, message}

        {:error, :unavailable, message} ->
          {:error, :image_unavailable, message}

        {:error, :failed, message} ->
          {:error, :image_failed, message}
      end
    end
  end

  def trash_image(space_id, id), do: transact(space_id, &Images.trash(&1, id))
  def restore_image(space_id, id), do: transact(space_id, &Images.restore(&1, id))

  @doc """
  Deletes an image in the trash for good and removes its file. The blocks showing it
  stay, on every page, and say it was deleted.
  """
  def delete_image(space_id, id) do
    with {:ok, id} = deleted <- transact(space_id, &Images.delete(&1, id)) do
      ImageFile.remove(id)
      deleted
    end
  end

  @doc "`{:ok, file, mime, name}` for an image of the Space, trashed or not, else `:error`."
  def image_file(space_id, id) do
    with {:ok, state} <- state(space_id),
         %{} = image <- Images.get(state, id),
         file when is_binary(file) <- ImageFile.existing(id) do
      {:ok, file, image["mimeType"], image["name"]}
    else
      _ -> :error
    end
  end

  # --- Markdown and threads -----------------------------------------------------------

  def publish_page(space_id, page_id, where \\ %{}) do
    # Refused first: reaching for the address can publish the MC over Tailscale.
    with {:ok, _} <- transact(space_id, &{[], Pages.fetch_live(&1, page_id)}),
         {:ok, reached} <- reached(where) do
      transact(space_id, &Sites.publish(&1, page_id, reached, move: where["tailscale"] == true))
    end
  end

  def unpublish_page(space_id, page_id), do: transact(space_id, &Sites.unpublish(&1, page_id))

  @doc """
  The site at this link: the Space's stream is only touched for a Space that exists, as
  anyone can ask, and only this one entity is read from it.
  """
  def site(space_id, token) do
    if Streams.get(@index, "space", space_id), do: Streams.get(stream_id(space_id), "site", token)
  end

  defp reached(where) do
    with {:error, {:tailscale, message}} <- HalC2.Web.address(where),
         do: {:error, :unavailable, message}
  end

  def export_markdown(space_id, page_id) do
    with {:ok, state} <- state(space_id),
         %{} = page <-
           Pages.get(state, page_id) ||
             {:error, :not_found, "There is no page #{page_id} in this Space."} do
      title_of = &(Pages.get(state, &1) || %{})["title"]
      {:ok, Markdown.export(page, Blocks.of_page(state, page_id), title_of)}
    end
  end

  @doc "A new page from Markdown: its `# ` title unless `title` is given, else \"Untitled\"."
  def import_markdown(
        space_id,
        markdown,
        title \\ nil,
        parent_id \\ nil,
        extra \\ %{},
        author \\ @user
      )

  def import_markdown(space_id, markdown, title, parent_id, extra, author)
      when is_binary(markdown) do
    {heading, specs} = Markdown.parse(markdown)
    title = title || (heading && nonblank(heading)) || "Untitled"

    transact(space_id, fn state ->
      with {page_changes, {:ok, page}} <- Pages.create(state, space_id, title, parent_id, extra),
           # The new page is not in `state` yet: its blocks are decided on a state that has it.
           state = with_changes(state, page_changes),
           {block_changes, {:ok, _}} <-
             Blocks.insert_all(
               state,
               page["id"],
               Enum.map(specs, &links(state, &1)),
               :last,
               author
             ) do
        {page_changes ++ block_changes, {:ok, page}}
      end
    end)
  end

  def import_markdown(_, _, _, _, _, _), do: {:error, :invalid, "markdown is a string."}

  # `state` as if `changes` were committed, to decide what follows them in one step.
  defp with_changes(state, changes) do
    Enum.reduce(changes, state, fn {kind, id, patch}, state ->
      StreamState.apply_event(state, %{seq: state.seq, kind: kind, entity: id, patch: patch})
    end)
  end

  # A link to a page this Space does not have is kept as a paragraph, and so is an image
  # it does not have or that is in the trash.
  @doc "A link to a page that is gone keeps its words as a paragraph; an image likewise."
  def links(state, %{"kind" => "image"} = spec) do
    case Images.fetch_live(state, spec["imageId"]) do
      {:ok, _} ->
        spec

      _ ->
        spec
        |> Map.delete("imageId")
        |> Map.merge(%{
          "kind" => "paragraph",
          "text" => "![#{spec["text"]}](space-image:#{spec["imageId"]})"
        })
    end
  end

  def links(state, %{"kind" => "subpage_link"} = spec) do
    if Pages.get(state, spec["linkedPageId"]),
      do: spec,
      else: %{
        spec
        | "kind" => "paragraph",
          "text" => "[#{spec["text"]}](##{spec["linkedPageId"]})",
          "linkedPageId" => nil
      }
  end

  def links(_state, spec), do: spec

  @doc """
  A new page summarising a thread of this MC, written by text generation in the
  thread's checkout. With no provider to write it, or one that fails, there is no page.
  """
  def create_page_from_thread(space_id, thread_id, parent_id \\ nil) do
    with {:ok, _} <- state(space_id),
         {:ok, cwd, context} <- thread_context(thread_id) do
      case HalC2.TextGeneration.page_from_thread(cwd, context) do
        {:ok, %{"title" => title, "markdown" => markdown}} ->
          extra = %{"sourceThreadId" => thread_id}
          import_markdown(space_id, markdown, nonblank(title), parent_id, extra, agent(thread_id))

        {:error, {:unavailable, message}} ->
          {:error, :generation_unavailable, message}

        {:error, message} ->
          {:error, :generation_failed, message}
      end
    end
  end

  defp nonblank(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp thread_context(thread_id) when is_binary(thread_id) do
    with {"thread", row} <- HalC2.Shell.row(node(), thread_id),
         root when is_binary(root) <- row["worktreePath"] || project_root(row["projectId"]) do
      messages =
        thread_id
        |> Streams.state()
        |> StreamState.list("message")
        |> Enum.filter(&(&1["role"] in ["user", "assistant"] and &1["streaming"] != true))

      case HalC2.TextGeneration.Prompts.thread_context(messages) do
        {"", _} -> {:error, :invalid, "The thread has nothing to summarise yet."}
        {text, _attachments} -> {:ok, root, text}
      end
    else
      _ ->
        {:error, :not_found, "There is no thread #{thread_id} with a project folder on this MC."}
    end
  end

  defp thread_context(_), do: {:error, :invalid, "threadId is required."}

  defp project_root(nil), do: nil

  defp project_root(project_id) do
    case HalC2.Shell.row(node(), project_id) do
      {"project", row} -> row["workspaceRoot"]
      _ -> nil
    end
  end
end
