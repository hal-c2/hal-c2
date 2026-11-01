defmodule HalC2.Space.ImageFile do
  @moduledoc """
  The file behind a Space's image, among the attachments on disk
  (`HalC2.Attachments`) as `space_image_<id>.image`: one file however many pages show
  the image, removed when the image is deleted for good.

  A file is judged by its content, never its name or the type it claimed: PNG, JPEG,
  GIF or WebP, up to the upload limit and `@max_pixels`. SVG is refused, as it is a
  program as much as a picture. The MC reads only the headers; it never decodes pixels.
  Clients decode the bytes as untrusted data, and a file whose headers are fine but
  whose pixels are not shows as an image that could not be shown.
  """

  alias HalC2.Attachments

  # What a client can decode: Qt refuses images over 256 MB at 4 bytes a pixel.
  @max_pixels 64_000_000

  @not_an_image "That file is not a PNG, JPEG, GIF or WebP image."

  @doc "Where the image `id` is kept."
  def path(id), do: Path.join(Attachments.dir(), "space_image_#{id}.image")

  @doc "The file of the image `id`, if it is there."
  def existing(id) do
    file = path(id)
    if File.regular?(file), do: file
  end

  @doc "Removes the file of the image `id`."
  def remove(id) do
    File.rm(path(id))
    :ok
  end

  @doc """
  Takes the pending upload `attachment_id` as a new image's file: `{:ok, id, file}`, or
  a refusal. Renaming first means an upload is taken once, and what was checked is what
  stays; a file that is refused is removed.
  """
  def take(attachment_id) do
    with {:ok, source} <- pending(attachment_id),
         id = HalC2.Environment.uuid4(),
         :ok <- rename(source, path(id)) do
      case check(path(id)) do
        {:ok, file} ->
          {:ok, id, file}

        refused ->
          remove(id)
          refused
      end
    end
  end

  # A `.part` is an upload still being written: `HalC2.Attachments.store/2` renames it.
  defp pending("pending-" <> _ = id) do
    with true <- Attachments.valid_id?(id),
         file when is_binary(file) <- Attachments.path(%{"id" => id}),
         false <- Path.extname(file) == ".part" do
      {:ok, file}
    else
      _ -> not_uploaded()
    end
  end

  defp pending(_), do: not_uploaded()

  defp rename(source, target) do
    case File.rename(source, target) do
      :ok -> :ok
      _ -> not_uploaded()
    end
  end

  defp not_uploaded, do: {:error, :invalid, "That image was not uploaded."}

  @doc """
  Checks a file on disk: `{:ok, %{mime_type, size_bytes, width, height}}` or a refusal.
  Only a regular file within the upload limit is opened.
  """
  def check(file) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(file),
         true <- size <= Attachments.max_image_bytes() || :too_big,
         {:ok, bytes} <- File.read(file),
         {:ok, mime_type, width, height} <- sniff(bytes),
         true <- width * height <= @max_pixels || :too_many_pixels do
      {:ok, %{mime_type: mime_type, size_bytes: size, width: width, height: height}}
    else
      :too_big ->
        {:error, :invalid,
         "Images may be at most #{div(Attachments.max_image_bytes(), 1024 * 1024)} MB."}

      :too_many_pixels ->
        {:error, :invalid, "That image is too large to show."}

      _ ->
        {:error, :invalid, @not_an_image}
    end
  end

  @doc "The type and size bytes declare for themselves: `{:ok, mime, width, height}` or `:error`."
  def sniff(<<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", w::32, h::32, _::binary>>),
    do: sized("image/png", w, h)

  def sniff(<<"GIF8", v, "a", w::little-16, h::little-16, _::binary>>) when v in [?7, ?9],
    do: sized("image/gif", w, h)

  def sniff(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest)

  def sniff(<<"RIFF", _::little-32, "WEBP", chunk::binary>>), do: webp(chunk)

  def sniff(_), do: :error

  # Segments up to the frame header that holds the size; the scan data comes after it.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD7 or marker == 0x01,
    do: jpeg(rest)

  defp jpeg(<<0xFF, marker, _::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: sized("image/jpeg", w, h)

  defp jpeg(<<0xFF, marker, _::binary>>) when marker in [0xD9, 0xDA], do: :error

  defp jpeg(<<0xFF, _marker, length::16, rest::binary>>)
       when length >= 2 and byte_size(rest) >= length - 2 do
    skip = length - 2
    <<_::binary-size(^skip), next::binary>> = rest
    jpeg(next)
  end

  defp jpeg(_), do: :error

  defp webp(
         <<"VP8 ", _::little-32, _::24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>
       ),
       do: sized("image/webp", Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF))

  defp webp(<<"VP8L", _::little-32, 0x2F, bits::little-32, _::binary>>) do
    w = Bitwise.band(bits, 0x3FFF) + 1
    h = bits |> Bitwise.bsr(14) |> Bitwise.band(0x3FFF) |> Kernel.+(1)
    sized("image/webp", w, h)
  end

  defp webp(<<"VP8X", _::little-32, _flags::32, w::little-24, h::little-24, _::binary>>),
    do: sized("image/webp", w + 1, h + 1)

  defp webp(_), do: :error

  defp sized(_mime, w, h) when w == 0 or h == 0, do: :error
  defp sized(mime, w, h), do: {:ok, mime, w, h}
end
