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
    "threads:read" => "Read threads",
    "threads:create" => "Start threads that run agents",
    "agentTools" => "Offer tools to agents"
  }

  @setting_types ~w(text longText secret boolean number choice list object)

  # The shape of what the MC and its clients read from a manifest, after
  # `PluginManifest`: `:text` is a non-empty string, `{:map, required, optional}` an
  # object with those keys. An optional key that is absent or null is left out.
  @contributes {:map, %{},
                %{
                  "pages" =>
                    {:list,
                     {:map, %{"id" => :text, "title" => :text, "qml" => :text},
                      %{"icon" => :text}}},
                  "threadKinds" =>
                    {:list,
                     {:map, %{"kind" => :text, "label" => :text},
                      %{"rowMark" => :text, "header" => :text}}},
                  "slots" =>
                    {:list, {:map, %{"slot" => :text, "qml" => :text}, %{"order" => :int}}},
                  "settingsPage" => :text
                }}
  @shape {:map, %{},
          %{
            "author" => {:map, %{"name" => :text}, %{"url" => :text}},
            "homepage" => :text,
            "license" => :text,
            "icon" => :text,
            "screenshots" => {:list, {:map, %{"path" => :text}, %{"caption" => :string}}},
            "permissions" => {:list, {:map, %{"id" => :text, "reason" => :text}, %{}}},
            "settings" =>
              {:list, {:map, %{"key" => :text}, %{"label" => :text, "description" => :string}}},
            "contributes" => @contributes
          }}
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

  # Hidden files count, as the package can serve them; a `.git` checkout of the
  # package does not.
  defp hash(dir) do
    files =
      dir
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, dir))))
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    files
    |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
      acc
      |> :crypto.hash_update(Path.relative_to(file, dir))
      |> :crypto.hash_update(File.read!(file))
    end)
    |> :crypto.hash_final()
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

      missing = Enum.find(~w(name version description), &(not text?(json[&1]))) ->
        {:error, "plugin.json has no #{missing}."}

      not is_integer(json["apiVersion"]) ->
        {:error, "plugin.json has no apiVersion."}

      problem = misshapen(json, @shape, nil) ->
        {:error, "plugin.json does not fit its schema: #{problem}."}

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
  defp misshapen(value, :string, _at) when is_binary(value), do: nil
  defp misshapen(value, :int, _at) when is_integer(value), do: nil
  defp misshapen(_value, {:map, _, _}, at), do: "#{at} must be an object"
  defp misshapen(_value, {:list, _}, at), do: "#{at} must be a list"
  defp misshapen(_value, :int, at), do: "#{at} must be a whole number"
  defp misshapen(_value, _text, at), do: "#{at} must be text"

  defp under(nil, key), do: key
  defp under(at, key), do: "#{at}.#{key}"

  defp text?(value), do: is_binary(value) and value != ""
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
