defmodule HalC2.Plugins.Package do
  @moduledoc """
  A plugin package: a directory `<plugins>/<id>/` holding `plugin.json` (the
  manifest, `PluginManifest` in `packages/contracts/src/plugin.ts`), an optional
  `mc/` of Elixir sources the MC compiles in name order, and the UI parts and
  assets the MC serves to its clients (`file/3`).

  `read/1` checks the manifest and turns it into the atom-keyed map
  `HalC2.Plugins` keeps for every plugin, with the manifest itself under
  `:package`. The checks are the ones the MC relies on; the contract's schema is the
  complete description for authors.
  """

  @permissions %{
    "projects:read" => "Read this MC's projects and their repositories",
    "pullRequests:read" => "Read pull requests",
    "pullRequests:write" => "Comment on, review and change pull requests",
    "issues:read" => "Read issues, milestones and boards",
    "issues:write" => "Create and change issues, milestones and boards",
    "slack:read" => "Read Slack channels and hear messages to the bot",
    "slack:write" => "Post in Slack as the bot",
    "threads:read" => "Read threads",
    "threads:create" => "Start threads that run agents",
    "threads:organize" =>
      "Settle and stop threads it started, and show or hide them in the thread list",
    "agentTools" => "Offer tools to agents"
  }

  @setting_types ~w(text longText secret boolean number choice list object)

  # The shape of what the MC and its clients read from a manifest, after
  # `PluginManifest`: `:text` is a non-empty string, `:slug` one that is fit for an
  # id, `:path` a relative path inside the package, `{:map, required, optional}` an
  # object with those keys. An optional key that is absent or null is left out.
  @contributes {:map, %{},
                %{
                  "pages" =>
                    {:list,
                     {:map, %{"id" => :slug, "title" => :text, "qml" => :path},
                      %{"icon" => :text}}},
                  "threadKinds" =>
                    {:list,
                     {:map, %{"kind" => :text, "label" => :text},
                      %{"rowMark" => :path, "header" => :path}}},
                  "slots" =>
                    {:list, {:map, %{"slot" => :text, "qml" => :path}, %{"order" => :int}}},
                  "settingsPage" => :path
                }}
  @shape {:map, %{},
          %{
            "author" => {:map, %{"name" => :text}, %{"url" => :text}},
            "homepage" => :text,
            "license" => :text,
            "icon" => :path,
            "screenshots" => {:list, {:map, %{"path" => :path}, %{"caption" => :string}}},
            "permissions" => {:list, {:map, %{"id" => :text, "reason" => :text}, %{}}},
            "settings" =>
              {:list, {:map, %{"key" => :text}, %{"label" => :text, "description" => :string}}},
            "contributes" => @contributes,
            "threadsStay" => :bool
          }}
  # `PackagePath`'s pattern: never absolute, never `..`.
  @path ~r/^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[\w.\/-]+$/
  @text ~w(.qml .js .mjs .json .md .txt .svg .css)

  @doc "A permission's label as the consent shows it."
  def permission_label(id), do: @permissions[id] || id

  @doc "The package directories under `dir`."
  def dirs(dir) do
    dir
    |> Path.join("*/plugin.json")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
  end

  @doc """
  `{:ok, manifest, sources, hash}` for the package at `dir`, where `sources` are its
  `mc/*.ex` files and `hash` covers every file in it; `{:error, message, hash}` when
  its manifest cannot be used.
  """
  def read(dir) do
    hash = hash(dir)
    file = Path.join(dir, "plugin.json")

    with {:ok, text} <- File.read(file),
         {:ok, json} <- decode(text),
         :ok <- check(json, Path.basename(dir)) do
      sources = dir |> Path.join("mc/*.ex") |> Path.wildcard() |> Enum.sort()
      {:ok, manifest(json), sources, hash}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "plugin.json could not be read: #{:file.format_error(reason)}", hash}

      {:error, message} ->
        {:error, message, hash}
    end
  end

  @doc """
  Whether the package `id` installed here declares that its threads never leave the
  machine (`"threadsStay"` in its `plugin.json`). It is read from the package on disk,
  so it holds with the plugin off and with no plugin host running (an export from the
  command line); a plugin that is not installed declares nothing. `HalC2.Plugins.threads_stay?/1`
  also asks the version loaded.

  It fails closed: a package that is there (its directory, or the copy set aside) but
  whose `plugin.json` is missing, unreadable, not valid JSON or not a JSON object is
  taken to declare it, since the declaration cannot be read and a thread from before
  the mark would otherwise leave when the plugin host starts with the manifest broken.
  Its threads stay until the manifest is fixed or the package is uninstalled.

  While `replace/3` replaces the package, which takes two renames (`aside_dir/2`), the
  manifest moved aside speaks for it. The installed package is
  read, then the one aside, then the installed one again: absent at the first read,
  the package was aside then, and absent aside too, the replacement is in place by
  the next read. A few rounds cover installs one after another.
  """
  def threads_stay?(id) when is_binary(id) do
    if Regex.match?(~r/\A[\w.-]+\z/, id) and id not in [".", ".."] do
      plugins = Path.join(HalC2.Paths.data_dir(), "plugins")
      declared(Path.join(plugins, id), aside_dir(plugins, id), 3)
    else
      false
    end
  end

  def threads_stay?(_id), do: false

  defp declared(installed, aside, rounds) do
    case manifest_at(installed) do
      :absent -> declared_aside(installed, aside, rounds)
      found -> stays?(found)
    end
  end

  defp declared_aside(installed, aside, rounds) do
    case manifest_at(aside) do
      :absent when rounds > 1 -> declared(installed, aside, rounds - 1)
      :absent -> false
      found -> stays?(found)
    end
  end

  # A `threadsStay` that is no boolean fails the manifest's validation, so it says nothing.
  defp stays?({:ok, json}), do: Map.get(json, "threadsStay", false) != false
  defp stays?(:unreadable), do: true

  # The manifest of the package at `dir`: `:absent` when there is no such package, and
  # `:unreadable` when there is one whose manifest says nothing, or when the disk cannot
  # say whether there is one (the plugins directory cannot be read, say).
  defp manifest_at(dir) do
    with :present <- presence(dir) do
      with {:ok, text} <- File.read(Path.join(dir, "plugin.json")),
           {:ok, %{} = json} <- JSON.decode(text),
           do: {:ok, json},
           else: (_ -> with(:present <- presence(dir), do: :unreadable))
    end
  end

  defp presence(dir) do
    case File.lstat(dir) do
      {:ok, _} -> :present
      {:error, reason} when reason in [:enoent, :enotdir] -> :absent
      {:error, _} -> :unreadable
    end
  end

  @doc """
  Where `replace/3` copies a new version of package `id` before it goes into `plugins`, beside that directory, where a scan does not see it.
  """
  def staged_dir(plugins, id), do: Path.join(Path.dirname(plugins), ".plugin-#{id}.partial")

  @doc """
  Where `replace/3` moves the installed package `id` aside, between
  renaming it away and renaming its replacement (`staged_dir/2`) into its place, and
  then removes it. `threads_stay?/1` reads it.
  """
  def aside_dir(plugins, id), do: Path.join(Path.dirname(plugins), ".plugin-#{id}.old")

  @doc """
  Replaces package `id` in `plugins` with the one `fill` writes into the directory it is
  given (`staged_dir/2`), or installs it there, as `mix hal_c2.plugins.install` does: the
  installed package goes aside (`aside_dir/2`), the new one into its place, and the one
  aside is removed.

  Cut off at any point (a crash, a kill, a full disk), it leaves the package installed
  or aside, so `threads_stay?/1` always has a manifest to read and a plugin's threads
  never read as those of a plugin that was uninstalled. An install cut off between its
  two renames left the package aside with nothing in its place: the next one puts it
  back before it stages, and removes what is aside only with a package in place.
  """
  def replace(plugins, id, fill) do
    staged = staged_dir(plugins, id)
    aside = aside_dir(plugins, id)
    target = Path.join(plugins, id)

    if presence(target) == :absent, do: File.rename(aside, target)
    File.rm_rf!(staged)
    if presence(target) == :present, do: File.rm_rf!(aside)

    fill.(staged)

    if presence(target) == :present, do: File.rename!(target, aside)
    File.rename!(staged, target)
    File.rm_rf!(aside)
    :ok
  end

  @doc """
  A file of the package at `dir` as `PluginFileResult` fields, or an error when the
  path leaves the package or names no file.
  """
  def file(dir, path, revision) do
    with path when is_binary(path) <- safe(dir, path),
         {:ok, content} <- File.read(Path.join(dir, path)) do
      if Path.extname(path) in @text and String.valid?(content),
        do: {:ok, result(path, "utf8", content, revision)},
        else: {:ok, result(path, "base64", Base.encode64(content), revision)}
    else
      _ -> {:error, "#{path} is not a file of this plugin."}
    end
  end

  defp result(path, encoding, content, revision),
    do: %{"path" => path, "encoding" => encoding, "content" => content, "revision" => revision}

  # A path inside the package, symlinks included, or nil.
  defp safe(dir, path) when is_binary(path) do
    case Path.safe_relative(path, dir) do
      {:ok, relative} -> relative
      :error -> nil
    end
  end

  defp safe(_dir, _path), do: nil

  @doc """
  Copies the package at `dir` to `to`: the files it can serve, without its `.git`
  checkout or what a link in it leads to outside it. A file it cannot copy (one an
  install removed meanwhile, or one it cannot read) is `{:error, message}`.
  """
  def copy(dir, to) do
    Enum.reduce_while(files(dir), :ok, fn file, :ok ->
      path = Path.relative_to(file, dir)
      target = Path.join(to, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.cp(file, target) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, "#{path} could not be copied: #{:file.format_error(reason)}"}}
      end
    end)
  end

  # The files the package can serve. Hidden files count; a `.git` checkout of the
  # package does not, nor does a link that leads out of it.
  defp files(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, dir))))
    |> Enum.filter(&(File.regular?(&1) and safe(dir, Path.relative_to(&1, dir)) != nil))
    |> Enum.sort()
  end

  defp hash(dir) do
    dir
    |> files()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
      acc
      |> :crypto.hash_update(Path.relative_to(file, dir))
      |> :crypto.hash_update(contents(file))
    end)
    |> :crypto.hash_final()
  end

  # A file that cannot be read (gone since the listing, as when an install replaces the
  # package under a scan) hashes as its error, so the next scan reads it again. A file
  # that can hashes as it always did: an upgrade leaves the packages' hashes as they were.
  defp contents(file) do
    case File.read(file) do
      {:ok, bytes} -> bytes
      {:error, reason} -> "\0could not be read: #{reason}"
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _} -> {:error, "plugin.json must hold an object."}
      {:error, _} -> {:error, "plugin.json is not valid JSON."}
    end
  end

  defp check(json, dirname) do
    cond do
      not is_binary(json["id"]) ->
        {:error, "plugin.json has no id."}

      json["id"] != dirname ->
        {:error,
         "plugin.json names the id #{inspect(json["id"])}, but its directory is #{inspect(dirname)}; they must be the same."}

      # The id goes into tab, topic and cache keys, so it is held to `PluginManifest`'s pattern.
      not slug?(json["id"]) ->
        {:error,
         "plugin.json names the id #{inspect(json["id"])}; an id is lowercase letters, digits and dashes, starting with a letter."}

      missing = Enum.find(~w(name version description), &(not text?(json[&1]))) ->
        {:error, "plugin.json has no #{missing}."}

      not is_integer(json["apiVersion"]) ->
        {:error, "plugin.json has no apiVersion."}

      problem = misshapen(json, @shape, nil) ->
        {:error, "plugin.json does not fit its schema: #{problem}."}

      # A page's id is its tab's, so two pages cannot share one.
      at = repeated_page(json) ->
        {:error,
         "plugin.json does not fit its schema: #{at} must differ from the other pages' ids."}

      unknown = Enum.find(list(json["permissions"]), &(not Map.has_key?(@permissions, &1["id"]))) ->
        {:error, "plugin.json asks for the unknown permission #{inspect(unknown["id"])}."}

      field = Enum.find(list(json["settings"]), &(not setting?(&1))) ->
        {:error, "plugin.json has a setting HAL-C2 cannot show: #{inspect(field)}."}

      field =
          Enum.find(
            list(json["settings"]),
            &(&1["default"] != nil and not typed?(&1, &1["default"]))
          ) ->
        {:error,
         "plugin.json gives the setting #{inspect(field["key"])} a default it cannot take: #{inspect(field["default"])}."}

      true ->
        :ok
    end
  end

  # Where `value` does not have `shape`, as "<where> must be <what>", or nil.
  defp misshapen(value, {:map, required, optional}, at) when is_map(value) do
    Enum.find_value(required, fn {key, shape} ->
      if value[key] == nil,
        do: "#{under(at, key)} is missing",
        else: misshapen(value[key], shape, under(at, key))
    end) ||
      Enum.find_value(optional, fn {key, shape} ->
        if value[key] != nil, do: misshapen(value[key], shape, under(at, key))
      end)
  end

  defp misshapen(value, {:list, shape}, at) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {item, i} -> misshapen(item, shape, "#{at}[#{i}]") end)
  end

  defp misshapen(value, :text, _at) when is_binary(value) and value != "", do: nil

  defp misshapen(value, :slug, at) when is_binary(value) do
    if not slug?(value),
      do: "#{at} must be lowercase letters, digits and dashes, starting with a letter"
  end

  defp misshapen(value, :path, at) when is_binary(value) do
    if not Regex.match?(@path, value), do: "#{at} must be a relative path inside the package"
  end

  defp misshapen(value, :string, _at) when is_binary(value), do: nil
  defp misshapen(value, :int, _at) when is_integer(value), do: nil
  defp misshapen(value, :bool, _at) when is_boolean(value), do: nil
  defp misshapen(_value, :bool, at), do: "#{at} must be true or false"
  defp misshapen(_value, {:map, _, _}, at), do: "#{at} must be an object"
  defp misshapen(_value, {:list, _}, at), do: "#{at} must be a list"
  defp misshapen(_value, :int, at), do: "#{at} must be a whole number"
  defp misshapen(_value, _text, at), do: "#{at} must be text"

  defp under(nil, key), do: key
  defp under(at, key), do: "#{at}.#{key}"

  defp text?(value), do: is_binary(value) and value != ""
  defp slug?(value), do: Regex.match?(~r/^[a-z][a-z0-9-]*$/, value)

  # Where a page names an id an earlier page has, or nil.
  defp repeated_page(json) do
    ids = Enum.map(list((json["contributes"] || %{})["pages"]), & &1["id"])

    Enum.find_value(Enum.with_index(ids), fn {id, i} ->
      if id in Enum.take(ids, i), do: "contributes.pages[#{i}].id"
    end)
  end

  defp list(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list(_), do: []

  defp setting?(%{"key" => key, "type" => type} = field) when is_binary(key) do
    type in @setting_types and (type != "choice" or options?(field["options"]))
  end

  defp setting?(_), do: false

  defp options?(options) when is_list(options),
    do:
      Enum.all?(
        options,
        &match?(
          %{"value" => value, "label" => label} when is_binary(value) and is_binary(label),
          &1
        )
      )

  defp options?(_), do: false

  @doc """
  Whether `value` fits the setting `field` (string keys) declares: its type, and for a
  choice one of its options that is not turned off. A field without a type takes anything.
  """
  def typed?(%{"type" => type}, value) when type in ~w(text longText secret),
    do: is_binary(value)

  def typed?(%{"type" => "boolean"}, value), do: is_boolean(value)
  def typed?(%{"type" => "number"}, value), do: is_number(value)
  def typed?(%{"type" => "list"}, value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  def typed?(%{"type" => "choice"} = field, value),
    do: Enum.any?(field["options"] || [], &(&1["value"] == value and &1["disabled"] != true))

  def typed?(_field, _value), do: true

  # The shape `HalC2.Plugins` reads for every plugin.
  defp manifest(json) do
    %{
      id: json["id"],
      name: json["name"],
      version: json["version"],
      api_version: json["apiVersion"],
      description: json["description"],
      settings:
        for field <- list(json["settings"]) do
          %{
            key: field["key"],
            label: field["label"] || field["key"],
            type: field["type"],
            secret: field["type"] == "secret",
            description: field["description"],
            default: field["default"],
            options: field["options"]
          }
        end,
      permissions:
        for permission <- list(json["permissions"]) do
          %{
            id: permission["id"],
            label: permission_label(permission["id"]),
            reason: permission["reason"]
          }
        end,
      package: json
    }
  end
end
