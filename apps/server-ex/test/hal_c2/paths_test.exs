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
end
