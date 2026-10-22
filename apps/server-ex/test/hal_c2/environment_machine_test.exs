defmodule HalC2.Environment.MachineTest do
  use ExUnit.Case, async: true

  alias HalC2.Environment.Machine

  test "Apple names, DMI chassis types, and VMs map to icon kinds" do
    assert Machine.apple("Mac mini (2024)") == "mac-mini"
    assert Machine.apple("Macmini8,1") == "mac-mini"
    assert Machine.apple("MacBookPro18,3") == "laptop"
    assert Machine.apple("ThinkPad") == nil

    assert Machine.from_dmi("23", "Dell Inc.", "PowerEdge R640") == "server"
    assert Machine.from_dmi("10", "LENOVO", "ThinkPad X1") == "laptop"
    # A VM is "cloud" whatever chassis the hypervisor fakes; Asahi keeps the Apple name.
    assert Machine.from_dmi("3", "QEMU", "Standard PC (Q35)") == "cloud"
    assert Machine.from_dmi(nil, "Apple Inc.", "Mac Studio (M2 Max)") == "mac-studio"
    assert Machine.from_dmi("2", nil, nil) == nil
  end

  test "the machine id is hashed as the desktop hashes QSysInfo::machineUniqueId()" do
    # SHA-256 of these bytes, as `sha256sum` prints it.
    assert Machine.hash("0123456789abcdef0123456789abcdef") ==
             "3eb1bd439947eb762998e566ccc2e099c791118b2f40579cc4f7da2b5061b7f9"

    assert Machine.hash("") == nil
    assert Machine.hash(nil) == nil
  end

  @tag :tmp_dir
  test "D-Bus's machine id is read as Qt reads it", %{tmp_dir: dir} do
    missing = Path.join(dir, "missing")
    id = Path.join(dir, "machine-id")
    File.write!(id, "0123456789abcdef0123456789abcdef\n")

    # The first file that exists, its first 32 bytes; none at all is no id.
    assert Machine.dbus_id([missing, id]) == "0123456789abcdef0123456789abcdef"
    assert Machine.dbus_id([missing]) == nil
    # One that exists but cannot be read ends the search, as it does in Qt.
    assert Machine.dbus_id([dir, id]) == nil
  end

  test "the descriptor names this machine by its id, or leaves it out" do
    platform = HalC2.Environment.descriptor()["platform"]

    case Machine.id() do
      nil -> refute Map.has_key?(platform, "machineId")
      id -> assert platform["machineId"] == id and id =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  test "the descriptor anyone may ask for leaves the machine's id out" do
    refute Map.has_key?(HalC2.Environment.public_descriptor()["platform"], "machineId")
  end
end
