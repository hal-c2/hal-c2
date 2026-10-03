defmodule HalC2.ModelManifest do
  @moduledoc """
  The model manifest (`priv/model-manifest.json`): provider model catalogs, which
  models are current, and the provider versions each HAL-C2 release works with.

  Every release bundles the manifest, so an MC that never reaches the network lists
  models from it. `refresh/1` fetches the copy on `main` and keeps the last good one
  in the cache directory (`model-manifest.json`), which the next start reads back.
  Preference is the fetched copy, then the one on disk, then the bundle; a copy
  edited before the bundle (`updatedAt`) is not used, since the release then carries
  data that copy never saw. A download that is not a usable manifest changes nothing.

  A refresh runs at boot and when the user refreshes every provider
  (`server.refreshProviders`), never on a provider check, so an offline MC pays no
  timeout there. `enableProviderUpdateChecks` off stops the fetch, not the use of a
  copy already on disk. The URL is `config :hal_c2, :model_manifest_url`; a value that
  is not an http(s) URL is read as a file.
  """

  @bundled_path Path.expand("../../priv/model-manifest.json", __DIR__)
  @external_resource @bundled_path
  @bundled @bundled_path |> File.read!() |> JSON.decode!()

  @url "https://raw.githubusercontent.com/hal-c2/hal-c2/main/apps/server-ex/priv/model-manifest.json"
  @key {__MODULE__, :manifest}

  @doc "The manifest this release carries."
  def bundled, do: Application.get_env(:hal_c2, :model_manifest_bundled, @bundled)

  @doc "The manifest in use: read from memory, never from the network."
  def current do
    case :persistent_term.get(@key, nil) do
      nil -> put(load())
      manifest -> manifest
    end
  end

  @doc "The model catalog of `driver` (`defaults`, `profiles`, `models`), or nil."
  def catalog(driver), do: get_in(current(), ["providers", driver])

  @doc """
  The compatibility policies, the manifest in use first: a fetched policy replaces
  the bundled one for its provider, and a provider it leaves out keeps the bundled one.
  """
  def policies, do: (current()["compatibility"] || []) ++ (bundled()["compatibility"] || [])

  @doc "Where the last fetched manifest is kept."
  def cache_path, do: Path.join(HalC2.Paths.cache_dir(), "model-manifest.json")

  @doc "Forgets the manifest in memory; the next read loads the disk copy again."
  def forget, do: :persistent_term.erase(@key)

  @doc """
  Fetches the manifest and returns the one in use afterwards. Never fails: a fetch
  that does not yield a usable manifest keeps the last one.
  """
  def refresh do
    current = current()

    with true <- HalC2.Settings.settings()["enableProviderUpdateChecks"] != false,
         {:ok, manifest} <- fetch(),
         # `main` can trail a release that is still being cut.
         false <- updated_ms(bundled()) > updated_ms(manifest) do
      write_cache(manifest)

      if manifest != current do
        put(manifest)
        # Model lists and advisories are built from it.
        HalC2.Settings.notify_providers()
      end

      manifest
    else
      _ -> current
    end
  end

  defp put(manifest) do
    :persistent_term.put(@key, manifest)
    manifest
  end

  defp load do
    bundled = bundled()

    with {:ok, text} <- File.read(cache_path()),
         {:ok, %{"manifest" => manifest}} <- JSON.decode(text),
         true <- valid?(manifest),
         false <- updated_ms(bundled) > updated_ms(manifest) do
      manifest
    else
      _ -> bundled
    end
  end

  defp write_cache(manifest) do
    path = cache_path()
    cache = %{"fetchedAtMs" => System.system_time(:millisecond), "manifest" => manifest}
    _ = File.mkdir_p(Path.dirname(path))
    _ = File.write(path, JSON.encode_to_iodata!(cache))
    :ok
  end

  defp fetch do
    with {:ok, text} <- read(Application.get_env(:hal_c2, :model_manifest_url, @url)),
         {:ok, manifest} <- JSON.decode(text),
         true <- valid?(manifest) do
      {:ok, manifest}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp read("http" <> _ = url) do
    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [timeout: 10_000, ssl: :httpc.ssl_verify_host_options(true)],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      _ -> :error
    end
  end

  defp read(path) when is_binary(path), do: File.read(path)
  defp read(_none), do: :error

  # Epoch milliseconds of `updatedAt`; a manifest without one is older than any dated one.
  defp updated_ms(manifest) do
    with at when is_binary(at) <- manifest["updatedAt"],
         {:ok, time, _} <- DateTime.from_iso8601(at) do
      DateTime.to_unix(time, :millisecond)
    else
      _ -> 0
    end
  end

  @doc """
  Whether `manifest` is one this MC can use (`ModelManifestSchema`): version 1,
  `currentModels` naming model ids per provider, catalogs whose models have unique
  ids and name profiles and a default that exist, and policies with their ranges.
  """
  def valid?(%{"version" => 1, "currentModels" => %{} = current} = manifest) do
    Enum.all?(current, fn {_driver, models} -> strings?(models) end) and
      catalogs?(Map.get(manifest, "providers", %{})) and
      policies?(Map.get(manifest, "compatibility", []))
  end

  def valid?(_manifest), do: false

  defp catalogs?(%{} = providers),
    do: Enum.all?(providers, fn {_, catalog} -> catalog?(catalog) end)

  defp catalogs?(_), do: false

  defp catalog?(%{"profiles" => %{} = profiles, "models" => models} = catalog)
       when is_list(models) do
    slugs = for %{"slug" => slug} <- models, do: slug
    default = get_in(catalog, ["defaults", "chat"])

    Enum.all?(models, &model?(&1, profiles)) and slugs == Enum.uniq(slugs) and
      (default == nil or default in slugs)
  end

  defp catalog?(_), do: false

  defp model?(%{"slug" => slug, "name" => name, "status" => status} = model, profiles) do
    text?(slug) and text?(name) and status in ["current", "legacy"] and
      (model["profile"] == nil or is_map(profiles[model["profile"]])) and
      (model["aliases"] == nil or strings?(model["aliases"]))
  end

  defp model?(_, _), do: false

  defp policies?(policies) when is_list(policies) do
    Enum.all?(policies, fn
      %{"driver" => driver, "halC2Range" => range, "ranges" => ranges} when is_list(ranges) ->
        text?(driver) and text?(range) and
          Enum.all?(
            ranges,
            &match?(%{"range" => r, "status" => s} when is_binary(r) and is_binary(s), &1)
          )

      _ ->
        false
    end)
  end

  defp policies?(_), do: false

  defp strings?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
