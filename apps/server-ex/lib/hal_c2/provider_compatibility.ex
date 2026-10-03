defmodule HalC2.ProviderCompatibility do
  @moduledoc """
  Whether an installed provider version works with this HAL-C2 release: the
  `compatibilityAdvisory` on its `ServerConfig.providers` entry, which clients show
  as limited support, an unsupported version or a known broken one.

  The policies are the model manifest's `compatibility` list (`HalC2.ModelManifest.policies/0`:
  a fetched policy over the bundled one for its provider). A policy covers
  one driver on the HAL-C2 releases in its `halC2Range`, and its `ranges` give
  provider versions a status. A range is comparators (`^`, `>=`, `>`, `<=`, `<`, `=`;
  none means `=`) separated by spaces, in groups joined by `||`; a missing minor or
  patch is 0. Only a stable `x.y.z` provider version is judged, anything else is
  `unknown`, as is a version no range names.

  The advisory also carries the status of the provider's latest release
  (`latestVersionStatus`), so clients do not offer an update to a release that is
  itself broken or unsupported here.
  """

  @messages %{
    "broken" => "This provider version is known to be incompatible with this HAL-C2 release.",
    "unsupported" =>
      "This provider version is outside the supported range for this HAL-C2 release.",
    "graceful" => "This provider version has limited compatibility with this HAL-C2 release."
  }

  @doc "Adds the advisory to an enabled, installed provider entry a policy covers."
  def put(%{"driver" => driver} = entry) do
    policies =
      Application.get_env(:hal_c2, :provider_compatibility) || HalC2.ModelManifest.policies()

    release = to_string(Application.spec(:hal_c2, :vsn))

    with true <- entry["enabled"] != false and entry["installed"] != false,
         %{} = advisory <- advisory(policies, driver, entry["version"], release) do
      latest = get_in(entry, ["versionAdvisory", "latestVersion"])

      advisory =
        case is_binary(latest) && advisory(policies, driver, latest, release) do
          %{"status" => status} -> Map.put(advisory, "latestVersionStatus", status)
          _ -> advisory
        end

      Map.put(entry, "compatibilityAdvisory", advisory)
    else
      _ -> entry
    end
  end

  def put(entry), do: entry

  @doc """
  The advisory for `version` of `driver` on HAL-C2 `release`, or nil when no policy
  covers that driver on that release.
  """
  def advisory(policies, driver, version, release) do
    policy =
      Enum.find(policies, &(&1["driver"] == driver and satisfies?(release, &1["halC2Range"])))

    if policy do
      status =
        with true <- is_binary(version),
             [_, stable] <-
               Regex.run(~r/^v?(\d+\.\d+\.\d+)(?:\+[0-9A-Za-z.-]+)?$/, String.trim(version)),
             %{"status" => status} <-
               Enum.find(policy["ranges"], &satisfies?(stable, &1["range"])) do
          status
        else
          _ -> "unknown"
        end

      message = @messages[status]
      recommendation = policy["recommendedVersion"] || policy["recommendedRange"]

      %{
        "status" => status,
        "message" =>
          if(message && recommendation,
            do: "#{message} Use #{recommendation}.",
            else: message
          ),
        "recommendedVersion" => policy["recommendedVersion"],
        "recommendedRange" => policy["recommendedRange"]
      }
    end
  end

  @doc "Whether `version` (with or without a leading `v`) is in `range`."
  def satisfies?(version, range) do
    case triple(version) do
      nil ->
        false

      version ->
        range
        |> String.split("||")
        |> Enum.any?(fn group ->
          # ">= 1.2" is one comparator, as ">=1.2" is.
          comparators = String.split(Regex.replace(~r/(\^|>=|>|<=|<|=)\s+/, group, "\\1"))
          comparators != [] and Enum.all?(comparators, &matches?(version, &1))
        end)
    end
  end

  defp matches?(version, comparator) do
    case Regex.run(~r/^(\^|>=|>|<=|<|=)?v?(\d+(?:\.\d+){0,2})$/, comparator) do
      [_, operator, target] ->
        target = triple(target)

        case operator do
          "^" -> version >= target and caret?(version, target)
          ">=" -> version >= target
          ">" -> version > target
          "<=" -> version <= target
          "<" -> version < target
          _ -> version == target
        end

      nil ->
        false
    end
  end

  # `^` keeps the leftmost non-zero part: ^1.2.3 is 1.x from 1.2.3, ^0.2.3 is 0.2.x.
  defp caret?([major | _], [target | _]) when target > 0, do: major == target
  defp caret?([0, minor | _], [0, target | _]) when target > 0, do: minor == target
  defp caret?(version, target), do: version == target

  # `[major, minor, patch]`, which compare in order; a prerelease suffix and build
  # metadata are ignored.
  defp triple(text) do
    case Regex.run(
           ~r/^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/,
           String.trim(text)
         ) do
      [_ | parts] ->
        Enum.map(parts, &String.to_integer/1) ++ List.duplicate(0, 3 - length(parts))

      nil ->
        nil
    end
  end
end
