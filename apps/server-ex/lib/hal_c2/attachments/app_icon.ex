defmodule HalC2.Attachments.AppIcon do
  @moduledoc """
  The icon of an application on the host, for a work log entry that names one
  (`native-app-icon` assets). This MC reads the freedesktop entries a Linux host
  installs: the
  `applications/*.desktop` files under `$XDG_DATA_HOME` and `$XDG_DATA_DIRS`, and the
  icon their `Icon=` key names from the hicolor theme or `pixmaps`.

  On macOS it asks Spotlight (`mdfind`, `mdls`) for the application, reads its bundle's
  `Info.plist` (`plutil`) and converts the icon to a 64 by 64 PNG (`sips`) in the cache
  directory. `Application.get_env(:hal_c2, :host_os)` (`:darwin`) and `:mac_tools_dir`
  (where those four commands are, `/usr/bin` otherwise) let tests stand in for a Mac.
  """

  @icon_size 64
  @command_timeout 5_000

  @sizes ~w(64x64 48x48 128x128 96x96 256x256 32x32 scalable)
  @extensions ~w(.png .svg)

  @doc "The icon file for an app reference (`app-id` or `display-name`), or `nil`."
  def resolve(app) do
    cond do
      control_name?(app) -> nil
      darwin?() -> mac_icon(app)
      true -> desktop_icon(app)
    end
  end

  defp control_name?(%{"_tag" => "display-name", "displayName" => name}),
    do: String.match?(name, ~r/[\x00-\x1f\x7f]/)

  defp control_name?(_app), do: false

  defp desktop_icon(%{"_tag" => "app-id", "appId" => id}) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, id) do
      Enum.find_value(data_dirs(), fn dir ->
        entry = Path.join([dir, "applications", id <> ".desktop"])
        if File.regular?(entry), do: icon(entry)
      end)
    end
  end

  defp desktop_icon(%{"_tag" => "display-name", "displayName" => name}) do
    wanted = String.downcase(name)

    data_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, "applications", "*.desktop"])))
    |> Enum.find_value(fn entry ->
      if String.downcase(key(entry, "Name") || "") == wanted, do: icon(entry)
    end)
  end

  defp desktop_icon(_app), do: nil

  # --- macOS -----------------------------------------------------------------------

  defp darwin?, do: Application.get_env(:hal_c2, :host_os, host_os()) == :darwin

  defp host_os, do: if(match?({:unix, :darwin}, :os.type()), do: :darwin, else: :other)

  defp mac_icon(app) do
    with app_path when is_binary(app_path) <- application_path(app),
         {:ok, bundle} <- File.read_link(app_path) |> real_path(app_path),
         icon when is_binary(icon) <- bundle_icon(bundle) do
      to_png(bundle, icon)
    else
      _ -> nil
    end
  end

  defp real_path({:ok, target}, app_path), do: {:ok, Path.expand(target, Path.dirname(app_path))}
  defp real_path(_not_a_link, app_path), do: {:ok, app_path}

  # Spotlight's query language takes quotes, backslashes and the two wildcards
  # literally only when escaped; a bundle id is matched as typed between quotes.
  defp application_path(app) do
    query =
      case app do
        %{"_tag" => "app-id", "appId" => id} ->
          "kMDItemCFBundleIdentifier == '#{escape_spotlight(id)}'"

        %{"_tag" => "display-name", "displayName" => name} ->
          "kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '#{escape_spotlight(name)}'"

        _ ->
          nil
      end

    with query when is_binary(query) <- query,
         {:ok, found} <- tool("mdfind", [query]) do
      candidates =
        found
        |> String.split(~r/\r?\n/)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.ends_with?(&1, ".app"))

      matching =
        case app do
          %{"displayName" => name} ->
            Enum.filter(
              candidates,
              &(String.downcase(Path.basename(&1, ".app")) == String.downcase(name))
            )

          _ ->
            candidates
        end

      most_recently_used(if matching == [], do: candidates, else: matching)
    else
      _ -> nil
    end
  end

  defp escape_spotlight(value), do: String.replace(value, ~r/([\\'*?])/, "\\\\\\1")

  defp most_recently_used(candidates) do
    candidates
    |> Enum.reduce(nil, fn candidate, best ->
      used =
        case tool("mdls", ["-raw", "-name", "kMDItemLastUsedDate", candidate]) do
          {:ok, out} -> String.trim(out)
          _ -> ""
        end

      if best == nil or used > elem(best, 1), do: {candidate, used}, else: best
    end)
    |> case do
      {path, _used} -> path
      nil -> nil
    end
  end

  # The bundle's icon file: the one Info.plist names, else AppIcon.icns, else any
  # .icns, always a regular file that really sits inside Resources.
  defp bundle_icon(bundle) do
    plist = Path.join([bundle, "Contents", "Info.plist"])
    resources = Path.join([bundle, "Contents", "Resources"])
    name = plist_value(plist, "CFBundleIconFile") || plist_value(plist, "CFBundleIconName")

    if name == nil or Path.basename(name) == name do
      file = if name, do: if(Path.extname(name) == "", do: name <> ".icns", else: name)

      entries =
        case File.ls(resources) do
          {:ok, entries} -> entries
          _ -> []
        end

      [file, "AppIcon.icns", Enum.find(entries, &String.ends_with?(String.downcase(&1), ".icns"))]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.join(resources, &1))
      |> Enum.find(&File.regular?/1)
      |> inside(resources)
    end
  end

  defp inside(nil, _resources), do: nil

  defp inside(file, resources) do
    real = realpath(file)
    root = realpath(resources)
    if real && root && String.starts_with?(real, root <> "/"), do: real
  end

  defp realpath(path) do
    path
    |> Path.split()
    |> Enum.reduce_while("/", fn part, acc ->
      next = Path.join(acc, part)

      case File.read_link(next) do
        {:ok, target} -> {:cont, Path.expand(target, acc)}
        _ -> {:cont, next}
      end
    end)
  end

  defp plist_value(plist, key) do
    case tool("plutil", ["-extract", key, "raw", "-o", "-", plist]) do
      {:ok, out} -> if String.trim(out) != "", do: String.trim(out)
      _ -> nil
    end
  end

  defp to_png(bundle, icon) do
    version =
      plist_value(Path.join([bundle, "Contents", "Info.plist"]), "CFBundleVersion") ||
        plist_value(Path.join([bundle, "Contents", "Info.plist"]), "CFBundleShortVersionString") ||
        ""

    key = :crypto.hash(:sha256, "#{bundle}\0#{version}\0#{icon}") |> Base.encode16(case: :lower)
    dir = Path.join(HalC2.Paths.cache_dir(), "native-app-icons")
    png = Path.join(dir, key <> ".png")

    if File.regular?(png) do
      png
    else
      File.mkdir_p!(dir)
      part = Path.join(dir, ".#{key}-#{System.unique_integer([:positive])}.png")
      size = Integer.to_string(@icon_size)

      result =
        with {:ok, _} <-
               tool("sips", ["-z", size, size, "-s", "format", "png", icon, "--out", part]),
             :ok <- File.rename(part, png),
             do: png

      File.rm(part)
      if is_binary(result), do: result
    end
  end

  defp tool(name, args) do
    command = Path.join(Application.get_env(:hal_c2, :mac_tools_dir, "/usr/bin"), name)

    task =
      Task.async(fn ->
        try do
          System.cmd(command, args, stderr_to_stdout: false)
        rescue
          _ -> :error
        end
      end)

    case Task.yield(task, @command_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      _ -> :error
    end
  end

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
