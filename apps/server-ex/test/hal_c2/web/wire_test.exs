defmodule HalC2.Web.WireTest do
  use ExUnit.Case, async: true

  alias HalC2.Patch
  alias HalC2.Web.Wire

  @limit 32_768

  defp item(progress), do: %{"id" => "i", "type" => "subagent", "progress" => progress}

  # What a client holds after folding the wire patches of `suffixes` onto `start`. The
  # socket coalesces the events of one flush (`HalC2.Web.Protocol.coalesce/1`), so the
  # wire patches composed into one must leave the client holding the same.
  defp folded(start, suffixes) do
    {sent, _server} =
      Enum.map_reduce(suffixes, start, fn suffix, server ->
        patch = %{"a" => %{"progress" => suffix}}
        {Wire.patch("turn-item", patch, "subagent", server), Patch.apply(server, patch)}
      end)

    sent = Enum.reject(sent, &is_nil/1)
    client = Enum.reduce(sent, Wire.entity("turn-item", start), &Patch.apply(&2, &1))

    if sent != [] do
      composed = Enum.reduce(sent, &Patch.compose(&2, &1))
      assert Patch.apply(Wire.entity("turn-item", start), composed) == client
    end

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

    # At the limit is not past it: a replay still sends the append as a patch.
    assert Wire.replay_patch("turn-item", %{"a" => %{"progress" => "y"}}, item(at)) ==
             {:patch, %{"a" => %{"progress" => "y"}}}
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

  # The replay decision pairing the past-limit check with the empty base lives in
  # the wire: past the limit it is a replacement, never a patch trimmed blind.
  test "a replay decides replacement, trimmed patch or nothing in the wire" do
    append = %{"a" => %{"progress" => "x"}}

    assert Wire.replay_patch("turn-item", append, item(String.duplicate("x", @limit + 1))) ==
             :replacement

    assert Wire.replay_patch("turn-item", append, item("x")) == {:patch, append}

    # A patch that resets the text it appends to is trimmed from the patch itself,
    # whatever the text was at the offset.
    reset = %{"s" => %{"progress" => "a"}, "a" => %{"progress" => "b"}}
    assert Wire.replay_patch("turn-item", reset, item("ab")) == {:patch, reset}

    command = %{"id" => "i", "type" => "command_execution"}
    assert Wire.replay_patch("turn-item", %{"s" => %{"output" => "x"}}, command) == nil
  end

  test "a command whose output reports a failure is sent as failed, without the output" do
    item = %{
      "id" => "i",
      "type" => "command_execution",
      "exitCode" => 0,
      "output" => "bash: frobnicate: command not found"
    }

    sent = Wire.entity("turn-item", item)
    refute Map.has_key?(sent, "output")
    assert sent["outputIndicatesFailure"] == true
    assert sent["exitCode"] == 0

    patch = %{"s" => %{"output" => "ENOENT: no such file or directory", "exitCode" => 0}}

    assert Wire.patch("turn-item", patch, "command_execution", nil) ==
             %{"s" => %{"exitCode" => 0, "outputIndicatesFailure" => true}}

    ok = %{item | "output" => "all done"}
    refute Map.has_key?(Wire.entity("turn-item", ok), "outputIndicatesFailure")
  end

  test "a handoff item is sent without its summary" do
    item = %{
      "id" => "i",
      "type" => "handoff",
      "summary" => "the story so far",
      "fromProviderInstanceIds" => ["codex"],
      "toProviderInstanceId" => "claudeAgent",
      "toModel" => "opus"
    }

    sent = Wire.entity("turn-item", item)
    refute Map.has_key?(sent, "summary")
    assert sent["fromProviderInstanceIds"] == ["codex"]
    assert sent["toModel"] == "opus"

    assert Wire.patch("turn-item", %{"s" => %{"summary" => "x"}}, "handoff", nil) == nil
  end

  test "a dynamic tool result keeps the ids it named and its failure, not the raw output" do
    item = %{
      "id" => "i",
      "type" => "dynamic_tool",
      "input" => %{"title" => "t"},
      "output" => %{
        "threadId" => "th-1",
        "isError" => true,
        "transcript" => String.duplicate("long ", 100)
      }
    }

    sent = Wire.entity("turn-item", item)
    assert sent["output"] == %{"isError" => true, "threadId" => "th-1"}
    assert sent["input"] == %{"title" => "t"}

    wrapped = %{
      item
      | "output" => %{
          "content" => [%{"type" => "text", "text" => ~s({"taskId":"task-9","detail":"raw"})}]
        }
    }

    assert Wire.entity("turn-item", wrapped)["output"] == %{"taskId" => "task-9"}

    nameless = %{item | "output" => %{"detail" => "nothing a summary names"}}
    refute Map.has_key?(Wire.entity("turn-item", nameless), "output")

    patch = %{"s" => %{"output" => %{"threadId" => "th-2", "raw" => "x"}}}

    assert Wire.patch("turn-item", patch, "dynamic_tool", nil) ==
             %{"s" => %{"output" => %{"threadId" => "th-2"}}}

    patch = %{"s" => %{"output" => %{"raw" => "x"}}}
    assert Wire.patch("turn-item", patch, "dynamic_tool", nil) == %{"u" => ["output"]}
  end

  test "a large dynamic tool input is sent as its first non-blank line, marked truncated" do
    big = "\n\n  do   the\tthing " <> String.duplicate("x", 20_000)
    item = %{"id" => "i", "type" => "dynamic_tool", "input" => big}

    assert Wire.entity("turn-item", item)["input"] ==
             %{
               "summary" => "do the thing " <> String.duplicate("x", 146) <> "…",
               "truncated" => true
             }

    small = %{"id" => "i", "type" => "dynamic_tool", "input" => "short"}
    assert Wire.entity("turn-item", small)["input"] == "short"
  end
end
