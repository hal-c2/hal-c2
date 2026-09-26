defmodule T3.Attachments.AppIcon do
  @moduledoc """
  The icon of an application on the host, for a work log entry that names one
  (`native-app-icon` assets). The Node server asks macOS (Spotlight and the app
  bundle); this node reads the freedesktop entries a Linux host installs: the
  `applications/*.desktop` files under `$XDG_DATA_HOME` and `$XDG_DATA_DIRS`, and the
  icon their `Icon=` key names from the hicolor theme or `pixmaps`.
  """

  @sizes ~w(64x64 48x48 128x128 96x96 256x256 32x32 scalable)
  @extensions ~w(.png .svg)

  @doc "The icon file for an app reference (`app-id` or `display-name`), or `nil`."
  def resolve(%{"_tag" => "app-id", "appId" => id}) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, id) do
      Enum.find_value(data_dirs(), fn dir ->
        entry = Path.join([dir, "applications", id <> ".desktop"])
        if File.regular?(entry), do: icon(entry)
      end)
    end
  end

  def resolve(%{"_tag" => "display-name", "displayName" => name}) do
    wanted = String.downcase(name)

    unless String.match?(name, ~r/[\x00-\x1f\x7f]/) do
      data_dirs()
      |> Enum.flat_map(&Path.wildcard(Path.join([&1, "applications", "*.desktop"])))
      |> Enum.find_value(fn entry ->
        if String.downcase(key(entry, "Name") || "") == wanted, do: icon(entry)
      end)
    end
  end

  def resolve(_app), do: nil

  defp icon(entry) do
    case key(entry, "Icon") do
      nil ->
        nil

      "/" <> _ = path ->
        if File.regular?(path) and Path.extname(path) in @extensions, do: path

      name ->
        if Path.basename(name) == name, do: themed(name)
    end
  end

  defp themed(name) do
    Enum.find_value(data_dirs(), fn dir ->
      Enum.find_value(@sizes, fn size ->
        Enum.find_value(@extensions, fn ext ->
          path = Path.join([dir, "icons", "hicolor", size, "apps", name <> ext])
          if File.regular?(path), do: path
        end)
      end) ||
        Enum.find_value(@extensions, fn ext ->
          path = Path.join([dir, "pixmaps", name <> ext])
          if File.regular?(path), do: path
        end)
    end)
  end

  # A key of the `[Desktop Entry]` group.
  defp key(entry, name) do
    with {:ok, text} <- File.read(entry) do
      text
      |> String.split("\n")
      |> Enum.drop_while(&(String.trim(&1) != "[Desktop Entry]"))
      |> Enum.drop(1)
      |> Enum.take_while(&(not String.starts_with?(&1, "[")))
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          [^name, value] -> String.trim(value)
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  defp data_dirs do
    home = System.get_env("XDG_DATA_HOME") || Path.join(System.user_home() || "/", ".local/share")
    dirs = System.get_env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share"
    [home | String.split(dirs, ":", trim: true)]
  end
end
