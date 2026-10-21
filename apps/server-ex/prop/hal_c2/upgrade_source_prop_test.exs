defmodule HalC2.UpgradeSourcePropTest do
  @moduledoc """
  The bundle cache of `HalC2.Upgrade.Source`: however a version's archive is replaced,
  by `put/3`, by a download from a peer or the release URL (an archive and its checksum
  written, nothing else), by a put that stopped mid-copy (its torn temp left beside a
  whole previous archive), beside an unpack
  that stopped midway, with its checksum taken away again, or with a wrong stamp left
  beside the unpacked bundle, fetching the version unpacks the archive last written
  whole, and nothing when there is none. No peer or release URL answers here.

  Sequentially, `rm_checksum` and `corrupt_stamp` pin that observable contract, not
  every branch behind it: after `rm_checksum` the source check already refuses (and
  drops) the archive, so `unpack/2`'s own missing-checksum refusal is race-only
  defence — a checksum taken between the source check and the unpack — that no
  sequential command here reaches.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Upgrade
  alias HalC2.Upgrade.Source

  @version "2.0.0"
  @platform "darwin-arm64"
  @markers ~w(a b c)

  property "fetching a version unpacks the archive last written whole",
    numtests: HalC2.Prop.numtests(100) do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        dir = HalC2.Prop.scratch_home("upgrade-source")
        {:ok, _} = Application.ensure_all_started(:inets)
        url = Application.get_env(:hal_c2, :upgrade_url)
        Application.put_env(:hal_c2, :upgrade_url, "http://127.0.0.1:1/{version}/{platform}")
        Process.put(:archives, Map.new(@markers, &{&1, tarball(dir, &1)}))

        {history, state, result} =
          try do
            run_commands(__MODULE__, cmds)
          after
            if url,
              do: Application.put_env(:hal_c2, :upgrade_url, url),
              else: Application.delete_env(:hal_c2, :upgrade_url)

            File.rm_rf(dir)
          end

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  # --- model ------------------------------------------------------------------------

  # The markers of the archive in the cache and of the one its checksum is of, nil for
  # none. The archive is whole when the two are the same.
  def initial_state, do: %{archive: nil, sum: nil}

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :put, [marker()]}},
      {3, {:call, __MODULE__, :downloaded, [marker()]}},
      {1, {:call, __MODULE__, :stopped_put, [marker()]}},
      {1, {:call, __MODULE__, :stopped_unpack, [marker()]}},
      {1, {:call, __MODULE__, :rm_checksum, []}},
      {1, {:call, __MODULE__, :corrupt_stamp, [marker()]}},
      {4, {:call, __MODULE__, :fetch, []}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(_state, _result, {:call, _, name, [marker]}) when name in [:put, :downloaded],
    do: %{archive: marker, sum: marker}

  # A stopped put never reaches the archive (copy-then-rename), so the
  # previous archive and its checksum stand.
  def next_state(state, _result, {:call, _, :stopped_put, [_marker]}), do: state

  def next_state(state, _result, {:call, _, :rm_checksum, []}), do: %{state | sum: nil}

  # The release URL is tried for an archive that is not whole, and its failure removes it.
  def next_state(state, _result, {:call, _, :fetch, []}),
    do: if(whole?(state), do: state, else: %{state | archive: nil})

  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :fetch, []}, result) do
    if whole?(state),
      do:
        match?({:ok, dir} when is_binary(dir), result) and
          marker_of(elem(result, 1)) == state.archive,
      else: match?({:error, %{"_tag" => "ServerSelfUpdateError"}}, result)
  end

  def postcondition(_state, _call, _result), do: true

  defp whole?(%{archive: archive, sum: sum}), do: archive != nil and archive == sum

  defp marker, do: oneof(@markers)

  # --- commands --------------------------------------------------------------------

  def put(marker), do: Source.put(@version, @platform, archive(marker))

  # What a download from a peer or the release URL leaves: the archive, then its checksum.
  def downloaded(marker) do
    target = cached_archive()
    File.mkdir_p!(Path.dirname(target))
    File.cp!(archive(marker), target)
    File.write!(target <> ".sha256", sha256(target))
  end

  # A put that stopped mid-copy: a torn temp beside the archive, never on
  # it, so the previous archive stays whole and fetchable.
  def stopped_put(marker) do
    target = cached_archive()
    File.mkdir_p!(Path.dirname(target))
    File.write!(target <> ".put-stopped", File.read!(archive(marker)) |> binary_part(0, 4))
  end

  # An unpack that stopped after some of an archive's files were out: one with another
  # manifest, beside a stamp it never wrote.
  def stopped_unpack(marker) do
    dir = Path.join(Source.cache_dir(@version), "bundle-#{@platform}")
    File.rm(dir <> ".sha256")
    manifest = Path.join([dir, "releases", @version, "upgrade.json"])
    File.mkdir_p!(Path.dirname(manifest))
    File.write!(manifest, JSON.encode!(%{"version" => @version, "marker" => "stale-" <> marker}))
  end

  # The checksum taken away while a whole archive remains (a cleanup, a writer
  # outside the upgrade server): fetching is an error, and a following whole
  # write recovers.
  def rm_checksum, do: File.rm(cached_archive() <> ".sha256")

  # A stamp beside the unpacked bundle naming a sum no archive here has, its
  # manifest left as it was: a plausible-looking stamp must not be trusted.
  # Not another marker's sum — that could become the right sum beside a stale
  # manifest after a later put of that marker, a state no writer here produces
  # (only an unpack writes the stamp, after extracting that very archive).
  def corrupt_stamp(marker) do
    stamp = Path.join(Source.cache_dir(@version), "bundle-#{@platform}.sha256")
    File.mkdir_p!(Path.dirname(stamp))
    sum = :crypto.hash(:sha256, "corrupt-" <> marker) |> Base.encode16(case: :lower)
    File.write!(stamp, sum)
  end

  def fetch, do: Source.fetch(@version, @platform)

  # --- helpers ---------------------------------------------------------------------

  defp marker_of(dir), do: (Upgrade.manifest(dir) || %{})["marker"]

  defp archive(marker), do: Map.fetch!(Process.get(:archives), marker)

  defp cached_archive,
    do: Path.join(Source.cache_dir(@version), Source.file_name(@version, @platform))

  defp tarball(dir, marker) do
    archive = Path.join(dir, "#{marker}.tar.gz")
    manifest = JSON.encode!(%{"version" => @version, "marker" => marker})
    entry = {~c"releases/#{@version}/upgrade.json", manifest}
    :ok = :erl_tar.create(String.to_charlist(archive), [entry], [:compressed])
    archive
  end

  defp sha256(path), do: Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
end
