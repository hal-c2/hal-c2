defmodule T3.Attachments.Favicon do
  @moduledoc """
  A project's favicon, as the Node server finds one (`ProjectFaviconResolver.ts`): the
  path the project saved, else `t3.json`'s `iconPath`, else a well-known location,
  else the icon an `index.html` or root route links.
  """

  @candidates ~w(favicon.svg favicon.ico favicon.png public/favicon.svg public/favicon.ico
    public/favicon.png app/favicon.ico app/favicon.png app/icon.svg app/icon.png app/icon.ico
    src/favicon.ico src/favicon.svg src/app/favicon.ico src/app/icon.svg src/app/icon.png
    assets/icon.svg assets/icon.png assets/logo.svg assets/logo.png .idea/icon.svg)
  @sources ~w(index.html public/index.html app/routes/__root.tsx src/routes/__root.tsx
    app/root.tsx src/root.tsx src/index.html)
  @link_icon ~r/<link\b(?=[^>]*\brel=["'](?:icon|shortcut icon)["'])(?=[^>]*\bhref=["']([^"'?]+))[^>]*>/i
  @icon_rel ~r/\brel\s*:\s*["'](?:icon|shortcut icon)["']/i
  @icon_href ~r/\bhref\s*:\s*["']([^"'?]+)/i

  @doc "The favicon file of the project at `root`, or `nil`."
  def resolve(root, saved \\ nil) do
    (saved && saved_file(root, saved)) ||
      icon_path(root) ||
      Enum.find_value(@candidates, &file(root, &1)) ||
      Enum.find_value(@sources, &linked(root, &1))
  end

  # A grouped project's saved path may be absent from one checkout; discovery still runs.
  defp saved_file(root, saved) do
    if Path.type(saved) == :absolute,
      do: if(File.regular?(saved), do: saved),
      else: file(root, saved)
  end

  defp icon_path(root) do
    with {:ok, text} <- File.read(Path.join(root, "t3.json")),
         {:ok, %{"iconPath" => path}} when is_binary(path) <- JSON.decode(text),
         do: file(root, path),
         else: (_ -> nil)
  end

  defp linked(root, source) do
    with full when is_binary(full) <- file(root, source),
         {:ok, text} <- File.read(full),
         href when is_binary(href) <- href(text) do
      clean = String.trim_leading(href, "/")
      file(root, Path.join("public", clean)) || file(root, clean)
    else
      _ -> nil
    end
  end

  defp href(text) do
    case Regex.run(@link_icon, text) do
      [_, href] ->
        href

      _ ->
        text
        |> String.split("}")
        |> Enum.find_value(fn run ->
          if Regex.match?(@icon_rel, run),
            do: with([_, href] <- Regex.run(@icon_href, run), do: href)
        end)
    end
  end

  defp file(root, relative) do
    case T3.Workspace.resolve(root, relative) do
      {:ok, full} -> if File.regular?(full), do: full
      _ -> nil
    end
  end
end
