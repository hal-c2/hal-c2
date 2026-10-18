defmodule HalC2.Web.WireTest do
  use ExUnit.Case, async: true

  alias HalC2.Patch
  alias HalC2.Web.Wire

  @limit 32_768

  defp item(progress), do: %{"id" => "i", "type" => "subagent", "progress" => progress}

  # What a client holds after folding the wire patches of `suffixes` onto `start`.
  defp folded(start, suffixes) do
    {client, _server} =
      Enum.reduce(suffixes, {Wire.entity("turn-item", start), start}, fn suffix,
                                                                         {client, server} ->
        patch = %{"a" => %{"progress" => suffix}}
        sent = Wire.patch("turn-item", patch, "subagent", server)
        {if(sent, do: Patch.apply(client, sent), else: client), Patch.apply(server, patch)}
      end)

    client
  end

  test "progress that grows past the limit by appends is the cut a snapshot shows" do
    chunk = String.duplicate("é", 5_000)
    suffixes = List.duplicate(chunk, 6)
    server = Enum.reduce(suffixes, item(""), &Patch.apply(&2, %{"a" => %{"progress" => &1}}))

    assert byte_size(server["progress"]) > @limit
    assert folded(item(""), suffixes) == Wire.entity("turn-item", server)
  end

  test "an append to text already past the limit sends nothing" do
    start = item(String.duplicate("x", @limit + 1))
    assert Wire.patch("turn-item", %{"a" => %{"progress" => "more"}}, "subagent", start) == nil
  end

  # Text exactly at the limit is not cut, so the client holds all of it: the first
  # append past it is sent as the cut text, and only later ones send nothing.
  test "an append to text exactly at the limit is sent as the cut text, once" do
    at = String.duplicate("x", @limit)
    assert folded(item(at), ["y", "z"]) == Wire.entity("turn-item", item(at <> "yz"))

    assert %{"s" => %{"progress" => _}} =
             Wire.patch("turn-item", %{"a" => %{"progress" => "y"}}, "subagent", item(at))

    assert Wire.patch("turn-item", %{"a" => %{"progress" => "z"}}, "subagent", item(at <> "y")) ==
             nil

    refute Wire.appends_past_limit?("turn-item", %{"a" => %{"progress" => "y"}}, item(at))
  end

  test "an append that stays under the limit goes through as it is" do
    patch = %{"a" => %{"progress" => "bc"}}
    assert Wire.patch("turn-item", patch, "subagent", item("a")) == patch
  end

  # A patch that resets the text and then appends to it, applied raw and sent over
  # the wire to a client holding the snapshot of `start`, leaves the client with the
  # snapshot of the result.
  defp sent_matches_snapshot(start, patch) do
    server = Patch.apply(start, patch)
    sent = Wire.patch("turn-item", patch, "subagent", start)
    client = Wire.entity("turn-item", start)

    assert if(sent, do: Patch.apply(client, sent), else: client) ==
             Wire.entity("turn-item", server)
  end

  test "an append after an unset grows the emptied text, not the old one" do
    long = item(String.duplicate("x", @limit + 1))
    sent_matches_snapshot(long, %{"u" => ["progress"], "a" => %{"progress" => "new"}})
  end

  test "an append after a delete grows the replacement, not the old text" do
    long = item(String.duplicate("x", @limit + 1))
    sent_matches_snapshot(long, %{"d" => true, "s" => item("a"), "a" => %{"progress" => "new"}})

    sent_matches_snapshot(long, %{
      "d" => true,
      "s" => %{"id" => "i", "type" => "subagent"},
      "a" => %{"progress" => "new"}
    })
  end

  test "an unset followed by an append past the limit is sent as the cut text" do
    start = item("short")
    over = String.duplicate("é", @limit)
    sent_matches_snapshot(start, %{"u" => ["progress", "result"], "a" => %{"progress" => over}})
    sent_matches_snapshot(start, %{"u" => ["progress"], "a" => %{"progress" => over}})
  end

  test "a set and an append to one text are cut as the text they make" do
    long = item(String.duplicate("x", @limit + 1))

    for start <- [item("short"), long] do
      sent_matches_snapshot(start, %{
        "s" => %{"progress" => String.duplicate("x", @limit - 8)},
        "a" => %{"progress" => String.duplicate("y", 20)}
      })

      sent_matches_snapshot(start, %{
        "s" => %{"progress" => String.duplicate("é", @limit)},
        "a" => %{"progress" => "y"}
      })
    end
  end

  test "a patch's cut basis grows an item's basis as the patch grows the item" do
    for start <- [item("short"), item(String.duplicate("é", @limit))],
        patch <- [
          %{"a" => %{"progress" => String.duplicate("y", 3 * @limit)}},
          %{"s" => %{"result" => String.duplicate("r", 2 * @limit)}, "a" => %{"result" => "r"}},
          %{"u" => ["progress"], "a" => %{"progress" => String.duplicate("é", @limit)}}
        ] do
      assert Wire.cut_basis(Patch.apply(Wire.cut_basis(start), Wire.cut_basis_patch(patch))) ==
               Wire.cut_basis(Patch.apply(start, patch))
    end
  end

  test "a patch appending to two texts cuts each from what it holds" do
    start = Map.put(item("short"), "result", String.duplicate("r", @limit - 1))
    over = String.duplicate("é", @limit)
    sent_matches_snapshot(start, %{"a" => %{"progress" => " more", "result" => over}})
    sent_matches_snapshot(start, %{"a" => %{"progress" => over, "result" => "r"}})
  end

  test "a subagent's cut basis is cut as the item is, however long its text" do
    long = item(String.duplicate("é", @limit))
    basis = Wire.cut_basis(long)
    assert byte_size(basis["progress"]) == @limit + 1

    for suffix <- ["", "x", String.duplicate("é", 10)] do
      patch = %{"a" => %{"progress" => suffix}}

      assert Wire.patch("turn-item", patch, "subagent", basis) ==
               Wire.patch("turn-item", patch, "subagent", long)
    end

    reset = %{"s" => %{"progress" => "a"}, "a" => %{"progress" => "b"}}
    assert Wire.patch("turn-item", reset, "subagent", basis) == reset
  end

  test "appends in a replay are sent whole when the text is past the limit" do
    patch = %{"a" => %{"progress" => "x"}}
    assert Wire.appends_past_limit?("turn-item", patch, item(String.duplicate("x", @limit + 1)))
    refute Wire.appends_past_limit?("turn-item", patch, item("x"))
  end
end
