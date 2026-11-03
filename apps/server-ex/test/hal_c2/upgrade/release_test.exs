defmodule HalC2.Upgrade.ReleaseTest do
  use ExUnit.Case, async: true

  alias HalC2.Upgrade.Release

  defmodule Provider do
    @behaviour Config.Provider
    def init(state), do: state
    def load(config, value), do: Config.Reader.merge(config, hal_c2: [from_runtime: value])
  end

  test "the new environment is the running one under the new sys.config" do
    running = [hal_c2: [port: 3780, home: "/h"], logger: [level: :info]]

    config = Release.config(running, hal_c2: [port: 3790])
    assert Enum.sort(config[:hal_c2]) == [home: "/h", port: 3790]
    assert config[:logger] == [level: :info]
  end

  test "the release's config providers run over its sys.config, as at boot" do
    provider =
      struct(Config.Provider, providers: [{Provider, :yes}], extra_config: [hal_c2: [extra: 1]])

    sys = [hal_c2: [port: 3790], elixir: [config_provider_init: provider]]
    config = Release.config([hal_c2: [port: 3780]], sys)

    assert config[:hal_c2][:port] == 3790
    assert config[:hal_c2][:extra] == 1
    assert config[:hal_c2][:from_runtime] == :yes
  end

  test "why an install failed is said in words" do
    assert Release.describe({:code_change_failed, self(), Foo, ~c"1", :badarg}) =~
             "Foo could not migrate"

    assert Release.describe({:old_processes, HalC2.Upgrade.ReleaseTest.Nobody}) ==
             "HalC2.Upgrade.ReleaseTest.Nobody is still run on the code of the update before"
  end
end

defmodule HalC2.Upgrade.ReleaseSaslTest do
  use ExUnit.Case, async: false

  alias HalC2.Upgrade.Release

  # The release handler loads more of SASL as it runs (`misc_supp`), so SASL has to be
  # on the code path even once `release_handler` is loaded and the path was reset.
  test "SASL goes back on the code path while the release handler stays loaded" do
    root = to_string(:code.root_dir())
    :ok = Release.load_sasl(root)
    {:module, :release_handler} = Code.ensure_loaded(:release_handler)
    paths = :code.get_path()
    on_exit(fn -> :code.set_path(paths) end)

    :code.set_path(Enum.reject(paths, &String.contains?(to_string(&1), "/sasl-")))
    assert :code.where_is_file(~c"misc_supp.beam") == :non_existing

    assert :ok = Release.load_sasl(root)
    assert :code.where_is_file(~c"misc_supp.beam") != :non_existing
  end
end
