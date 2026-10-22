defmodule HalC2.MachineFiles.NinePTest do
  use ExUnit.Case, async: true

  alias HalC2.MachineFiles.NineP

  defp s(value), do: <<byte_size(value)::16-little, value::binary>>

  defp frame(type, tag, body),
    do: <<byte_size(body) + 7::32-little, type, tag::16-little, body::binary>>

  test "splits whole messages off a buffer and keeps the rest" do
    one = frame(120, 1, <<5::32-little>>)
    two = frame(108, 2, <<1::16-little>>)
    partial = binary_part(two, 0, 5)

    assert NineP.frames(one <> two <> partial) ==
             {[{120, 1, <<5::32-little>>}, {108, 2, <<1::16-little>>}], partial}

    assert NineP.frames(<<1, 2>>) == {[], <<1, 2>>}
    refute NineP.valid_size?(<<3::32-little>>, 8192)
    refute NineP.valid_size?(<<9000::32-little>>, 8192)
    assert NineP.valid_size?(<<3, 0>>, 8192)
  end

  test "decodes the T-messages the helper sends" do
    assert NineP.decode(100, <<8192::32-little>> <> s("9P2000.L")) == {:version, 8192, "9P2000.L"}

    assert NineP.decode(
             104,
             <<0::32-little, -1::32-little>> <> s("me") <> s("") <> <<1000::32-little>>
           ) ==
             {:attach, 0}

    assert NineP.decode(110, <<0::32-little, 1::32-little, 2::16-little>> <> s("home") <> s("me")) ==
             {:walk, 0, 1, ["home", "me"]}

    assert NineP.decode(24, <<1::32-little, 0x7FF::64-little>>) == {:getattr, 1}
    assert NineP.decode(12, <<1::32-little, 2::32-little>>) == {:lopen, 1, 2}

    assert NineP.decode(116, <<1::32-little, 10::64-little, 4096::32-little>>) ==
             {:read, 1, 10, 4096}

    assert NineP.decode(118, <<1::32-little, 3::64-little, 2::32-little, "hi">>) ==
             {:write, 1, 3, "hi"}

    assert NineP.decode(40, <<1::32-little, 0::64-little, 8000::32-little>>) ==
             {:readdir, 1, 0, 8000}

    assert NineP.decode(
             14,
             <<1::32-little>> <> s("a.ts") <> <<0o102::32-little, 0o644::32-little, 0::32-little>>
           ) ==
             {:lcreate, 1, "a.ts", 0o102, 0o644}

    assert NineP.decode(72, <<1::32-little>> <> s("lib") <> <<0o755::32-little, 0::32-little>>) ==
             {:mkdir, 1, "lib", 0o755}

    assert NineP.decode(76, <<1::32-little>> <> s("lib") <> <<0x200::32-little>>) ==
             {:unlinkat, 1, "lib", 0x200}

    assert NineP.decode(74, <<1::32-little>> <> s("a") <> <<2::32-little>> <> s("b")) ==
             {:renameat, 1, "a", 2, "b"}

    setattr =
      <<1::32-little, 0x28::32-little, 0::32-little, 0::32-little, 0::32-little, 3::64-little,
        0::64-little, 0::64-little, 99::64-little, 0::64-little>>

    assert {:setattr, 1, %{valid: 0x28, size: 3, mtime: 99}} = NineP.decode(26, setattr)
    assert NineP.decode(8, <<1::32-little>>) == {:statfs, 1}
    assert NineP.decode(50, <<1::32-little, 0::32-little>>) == {:fsync, 1}
    assert NineP.decode(108, <<7::16-little>>) == {:flush, 7}
    assert NineP.decode(120, <<1::32-little>>) == {:clunk, 1}
  end

  test "a message it does not answer or cannot parse is named so" do
    assert NineP.decode(30, <<>>) == {:unknown, 30}
    assert NineP.decode(116, <<1, 2, 3>>) == {:bad, 116}
    assert NineP.decode(118, <<1::32-little, 0::64-little, 5::32-little, "hi">>) == {:bad, 118}

    assert NineP.decode(110, <<0::32-little, 1::32-little, 2::16-little>> <> s("home")) ==
             {:bad, 110}
  end

  test "encodes R-messages with their size, type and tag" do
    encoded = fn tag, reply -> IO.iodata_to_binary(NineP.encode(tag, reply)) end
    qid = {:dir, 3, 42}
    qid_bytes = <<0x80, 3::32-little, 42::64-little>>

    assert encoded.(1, {:lerror, 2}) == frame(7, 1, <<2::32-little>>)

    assert encoded.(65535, {:version, 8192, "9P2000.L"}) ==
             frame(101, 65535, <<8192::32-little>> <> s("9P2000.L"))

    assert encoded.(2, {:attach, qid}) == frame(105, 2, qid_bytes)

    assert encoded.(3, {:walk, [qid, {:file, 0, 7}]}) ==
             frame(111, 3, <<2::16-little>> <> qid_bytes <> <<0, 0::32, 7::64-little>>)

    assert encoded.(4, {:read, "abc"}) == frame(117, 4, <<3::32-little, "abc">>)
    assert encoded.(5, {:write, 3}) == frame(119, 5, <<3::32-little>>)
    assert encoded.(6, {:clunk}) == frame(121, 6, <<>>)
    assert encoded.(7, {:lopen, qid, 0}) == frame(13, 7, qid_bytes <> <<0::32>>)

    dirent = {qid, 1, 4, "src"}
    readdir = encoded.(8, {:readdir, [dirent]})

    assert readdir ==
             frame(41, 8, <<27::32-little>> <> qid_bytes <> <<1::64-little, 4>> <> s("src"))

    assert NineP.dirent_size(dirent) == 27
  end

  test "an Rgetattr carries the basic fields" do
    attr = %{
      mode: 0o100644,
      uid: 1000,
      gid: 1000,
      nlink: 1,
      size: 513,
      atime: 1,
      mtime: 2,
      ctime: 3
    }

    <<size::32-little, 25, 9::16-little, body::binary>> =
      IO.iodata_to_binary(NineP.encode(9, {:getattr, {:file, 2, 5}, attr}))

    assert size == byte_size(body) + 7

    assert <<0x7FF::64-little, 0, 2::32-little, 5::64-little, 0o100644::32-little,
             1000::32-little, 1000::32-little, 1::64-little, 0::64-little, 513::64-little,
             4096::64-little, 2::64-little, 1::64-little, 0::64, 2::64-little, 0::64,
             3::64-little, 0::64, 0::64, 0::64, 0::64, 0::64>> = body
  end

  test "errnos are Linux's, and EIO for any it does not know" do
    assert NineP.errno(:enoent) == 2
    assert NineP.errno(:ehostdown) == 112
    assert NineP.errno(:something_else) == 5
  end
end
