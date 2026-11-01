defmodule HalC2.RuntimeRecordPropTest do
  @moduledoc """
  `HalC2.RuntimeRecord.locate/2` over generated homes and record layouts: a chosen home
  only ever locates its own record; otherwise the tool's own profile comes first, then
  the installed MC, then the other profile. Only a live record counts. Each home is one
  of five places on disk, with a root `HalC2.Paths` ignores meaning the installed
  profile, and the model knows them by that place alone.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.RuntimeRecord

  @env ~w(HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME APPDATA LOCALAPPDATA)
  @places [:installed, :dev, :root, :mc, :dir]
  # Above any pid an OS hands out, so `kill -0` always finds it gone.
  @dead_pid 2_000_000_000

  setup do
    env = Map.new(@env, &{&1, System.get_env(&1)})
    home = Application.get_env(:hal_c2, :home)
    base = HalC2.Prop.scratch_home("runtime-record")

    # `locate/2` reads the environment itself, so the profiles must resolve under `base`.
    Enum.each(@env -- ["HOME"], &System.delete_env/1)
    System.put_env("HOME", base)

    on_exit(fn ->
      Enum.each(env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Application.put_env(:hal_c2, :home, home)
      File.rm_rf!(base)
    end)

    {:ok, base: base}
  end

  property "a chosen home locates only itself; a profile tries itself, the installed MC, then the other",
           [numtests: HalC2.Prop.numtests(200), max_size: 20],
           %{base: base} do
    forall {own, installed, layout} <- {oneof([nil, :dev, home()]), home(), layout()} do
      {own, installed} = {resolve(own, base), resolve(installed, base)}
      write_layout(layout, base)

      found = RuntimeRecord.locate(own, installed)
      expected = expected(own, installed, layout, base)

      (found == expected)
      |> when_fail(
        IO.puts("""
        locate(#{inspect(own)}, #{inspect(installed)}) over #{inspect(layout)}
        found    #{inspect(found)}
        expected #{inspect(expected)}
        """)
      )
      |> aggregate(outcome: outcome(expected, own, installed))
    end
  end

  defp expected(own, installed, layout, base) do
    tried =
      if own in [nil, :dev],
        do: [own, installed, other_profile(own)],
        else: [own]

    Enum.find_value(tried, fn home ->
      place = place(home, base)
      if layout[place] == :live, do: {home, record(place)}
    end)
  end

  defp other_profile(nil), do: :dev
  defp other_profile(:dev), do: nil

  # Where a home's files are, as `HalC2.Paths` documents it.
  defp place(nil, _base), do: :installed
  defp place(:dev, _base), do: :dev
  defp place(dir, _base) when is_binary(dir), do: :dir

  defp place({kind, dir}, base) do
    cond do
      dir == "relative" or String.starts_with?(dir, Path.join(base, ".t3")) -> :installed
      kind == :root -> :root
      kind == :mc -> :mc
    end
  end

  defp outcome(nil, _own, _installed), do: :none
  defp outcome({home, _}, home, _installed), do: :own
  defp outcome({home, _}, _own, home), do: :installed
  defp outcome(_found, _own, _installed), do: :other_profile

  defp home do
    oneof([
      nil,
      :dev,
      {:root, :root},
      {:mc, :mc},
      :dir,
      {:root, :relative},
      {:mc, :relative},
      {:root, :legacy},
      {:mc, :legacy_inside}
    ])
  end

  defp layout do
    let states <- vector(length(@places), oneof([:live, :live, :absent, :stale, :garbage])) do
      Map.new(Enum.zip(@places, states))
    end
  end

  # Homes are generated without the case's scratch path, so a counterexample stays readable.
  defp resolve(:dir, base), do: Path.join(base, "dir")
  defp resolve({kind, :relative}, _base), do: {kind, "relative"}
  defp resolve({:root, :legacy}, base), do: {:root, Path.join(base, ".t3")}
  defp resolve({:mc, :legacy_inside}, base), do: {:mc, Path.join([base, ".t3", "inside"])}
  defp resolve({kind, place}, base), do: {kind, Path.join(base, Atom.to_string(place))}
  defp resolve(home, _base), do: home

  defp write_layout(layout, base) do
    for {place, state} <- layout do
      path = Path.join(state_dir(place, base), "server-runtime.json")
      File.rm_rf!(path)
      File.mkdir_p!(Path.dirname(path))
      if body = body(state, place), do: File.write!(path, body)
    end
  end

  defp state_dir(:installed, base), do: Path.join(base, ".local/state/hal-c2/elixir")
  defp state_dir(:dev, base), do: Path.join(base, ".local/state/hal-c2-dev/elixir")
  defp state_dir(:root, base), do: Path.join(base, "root/state/elixir")
  defp state_dir(:mc, base), do: Path.join(base, "mc/state")
  defp state_dir(:dir, base), do: Path.join(base, "dir")

  defp body(:absent, _place), do: nil
  defp body(:garbage, _place), do: "{not json"
  defp body(:stale, place), do: JSON.encode!(%{record(place) | "pid" => @dead_pid})
  defp body(:live, place), do: JSON.encode!(record(place))

  # The origin says which place a located record came from.
  defp record(place) do
    %{"pid" => String.to_integer(System.pid()), "origin" => "http://#{place}.test"}
  end
end
