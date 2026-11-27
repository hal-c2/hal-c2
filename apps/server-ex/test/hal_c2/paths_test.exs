defmodule HalC2.PathsTest do
  use ExUnit.Case, async: true

  alias HalC2.Paths

  @moduletag :tmp_dir

  describe "write_replace/3" do
    test "replaces the file whole, with its mode, and leaves nothing beside it", %{tmp_dir: dir} do
      path = Path.join(dir, "state.json")
      File.write!(path, "old")

      assert :ok = Paths.write_replace(path, "new", 0o600)
      assert File.read!(path) == "new"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert File.ls!(dir) == ["state.json"]
    end

    # Another writer's file at the name this one picked is not this call's to remove.
    test "a temporary name already taken is passed over and left alone", %{tmp_dir: dir} do
      path = Path.join(dir, "state.json")
      taken = path <> ".taken.tmp"
      File.write!(taken, "another writer's")

      assert {:error, :eexist} = Paths.write_replace(path, "new", 0o600, [taken])
      assert File.read!(taken) == "another writer's"
      refute File.exists?(path)

      assert :ok = Paths.write_replace(path, "new", 0o600, [taken, path <> ".mine.tmp"])
      assert File.read!(taken) == "another writer's"
      assert File.read!(path) == "new"
      assert Enum.sort(File.ls!(dir)) == ["state.json", "state.json.taken.tmp"]
    end

    test "a file it wrote but could not rename into place is removed", %{tmp_dir: dir} do
      # A directory with something in it cannot be renamed over.
      path = Path.join(dir, "busy")
      File.mkdir_p!(Path.join(path, "inside"))

      assert {:error, _} = Paths.write_replace(path, "new", 0o600, [path <> ".mine.tmp"])
      assert File.ls!(dir) == ["busy"]
    end
  end

  describe "ensure!/1" do
    test "a directory left readable by everyone is tightened to its owner", %{tmp_dir: dir} do
      File.chmod!(dir, 0o755)
      dirs = Map.new(~w(config data state cache)a, &{&1, Path.join(dir, Atom.to_string(&1))})

      for path <- Map.values(dirs) do
        File.mkdir_p!(path)
        File.chmod!(path, 0o755)
      end

      Paths.ensure!(dirs)

      for path <- Map.values(dirs) ++ [Path.join(dirs.data, "secrets")] do
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700
      end

      # The parent the directories share is not the MC's to tighten.
      assert Bitwise.band(File.stat!(dir).mode, 0o077) != 0
    end
  end
end
