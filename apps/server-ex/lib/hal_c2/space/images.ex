defmodule HalC2.Space.Images do
  @moduledoc """
  The images of one Space, decided on its stream state like `HalC2.Space.Pages`. The
  stream holds what is known about an image and never its bytes (`HalC2.Space.ImageFile`).

  An image in the trash can come back and can still be fetched, but cannot be placed on
  another page. Only an image in the trash is deleted. Blocks showing an image outlive
  it: a page tells from the entity's `trashedAt`, or from its absence, what to say.
  """

  alias HalC2.Orchestration.Entities
  alias HalC2.Patch
  alias HalC2.Space.Pages
  alias HalC2.StreamState

  @max_name 255
  @max_prompt 4000
  @max_name_from_prompt 60

  @doc "The image `id`, or nil."
  def get(state, id), do: StreamState.get(state, "image")[id]

  @doc "The images not in the trash, in the order they were made."
  def live(state), do: state |> StreamState.list("image") |> Enum.reject(& &1["trashedAt"])

  @doc "The images in the trash, in the order they were made."
  def trashed(state), do: state |> StreamState.list("image") |> Enum.filter(& &1["trashedAt"])

  @doc "The image `id` if it can be placed, or why it cannot."
  def fetch_live(state, id) do
    case get(state, id) do
      nil -> not_found(id)
      %{"trashedAt" => at} = image when at != nil -> in_trash(image)
      image -> {:ok, image}
    end
  end

  @doc "A new image whose file `HalC2.Space.ImageFile.take/1` has kept under `id`."
  def add(_state, space_id, id, name, file, extra, author) do
    at = Entities.now()

    image =
      Map.merge(
        %{
          "id" => id,
          "spaceId" => space_id,
          "name" => name,
          "mimeType" => file.mime_type,
          "sizeBytes" => file.size_bytes,
          "width" => file.width,
          "height" => file.height,
          "prompt" => nil,
          "generatedBy" => nil,
          "trashedAt" => nil,
          "createdBy" => author,
          "createdAt" => at,
          "updatedAt" => at
        },
        extra
      )

    {[{"image", id, Patch.diff(nil, image)}], {:ok, image}}
  end

  def trash(state, id) do
    with {:ok, image} <- fetch_live(state, id) do
      update(image, %{"trashedAt" => Entities.now()})
    end
    |> Pages.refused()
  end

  def restore(state, id) do
    case get(state, id) do
      %{"trashedAt" => at} = image when at != nil ->
        update(image, %{"trashedAt" => nil})

      nil ->
        Pages.refused(not_found(id))

      image ->
        Pages.refused({:error, :invalid, "The image \"#{image["name"]}\" is not in the trash."})
    end
  end

  @doc "Deletes an image in the trash for good. Replies with its id."
  def delete(state, id) do
    case get(state, id) do
      %{"trashedAt" => at} when at != nil ->
        {[{"image", id, Patch.delete()}], {:ok, id}}

      nil ->
        Pages.refused(not_found(id))

      image ->
        Pages.refused(
          {:error, :invalid,
           "Only an image in the trash can be deleted; move \"#{image["name"]}\" there first."}
        )
    end
  end

  @doc "An image's name: one trimmed line, without any folders."
  def name(name) when is_binary(name) do
    case name |> String.trim() |> Path.basename() |> String.replace(~r/[\r\n]+/, " ") do
      "" -> {:error, :invalid, "An image needs a name."}
      name -> {:ok, String.slice(name, 0, @max_name)}
    end
  end

  def name(_), do: {:error, :invalid, "An image needs a name."}

  @doc "A prompt to generate from: trimmed, not empty, not too long."
  def prompt(prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)

    cond do
      prompt == "" -> {:error, :invalid, "Say what the image should show."}
      String.length(prompt) > @max_prompt -> {:error, :invalid, "That prompt is too long."}
      true -> {:ok, prompt}
    end
  end

  def prompt(_), do: {:error, :invalid, "Say what the image should show."}

  @doc "The name of an image generated from `prompt`: its first words, on one line."
  def name_from(prompt) do
    prompt
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @max_name_from_prompt)
    |> String.replace("/", " ")
    |> String.trim()
    |> case do
      "" -> "Image"
      name -> name
    end
  end

  defp update(image, fields) do
    next = image |> Map.merge(fields) |> Map.put("updatedAt", Entities.now())
    {[{"image", image["id"], Patch.diff(image, next)}], {:ok, next}}
  end

  defp not_found(id), do: {:error, :not_found, "There is no image #{id} in this Space."}
  defp in_trash(image), do: {:error, :trashed, "The image \"#{image["name"]}\" is in the trash."}
end
