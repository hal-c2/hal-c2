defmodule HalC2.LongTextPropTest do
  @moduledoc """
  The laws `HalC2.Attachments.fold_long_text/3` promises over any text and any
  attachments a message already has: text of 120,000 characters or fewer is untouched;
  longer text keeps its first 8,000 and last 2,000 characters around a note giving the
  exact count cut and the name of the file holding the whole of it; that file is
  added after the message's own attachments under a name none of them has, holds the
  text byte for byte, and is a `pasted-text` file the MC marks as its fold; and what is
  sent is itself short enough to pass through again untouched. `folded_into/2` finds
  that file from the folded text, and no file in text that was not folded, even when
  the text quotes a cut mark naming a pasted text the message has (#1363 review). An edit of the folded text
  that keeps its cut mark leaves that file with the message, and one that drops the
  mark, or keeps it but not the file, leaves it behind (`left_behind/4`). Counted in
  characters, so the text mixes in multi-byte ones.
  """

  use ExUnit.Case, async: false
  use PropCheck

  alias HalC2.Attachments

  @limit 120_000

  setup_all do
    home = Path.join(System.tmp_dir!(), "long-text-prop-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:hal_c2, :home)
    Application.put_env(:hal_c2, :home, home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hal_c2, :home, previous),
        else: Application.delete_env(:hal_c2, :home)

      File.rm_rf!(home)
    end)

    :ok
  end

  property "a long message keeps its ends and the whole of it is a file",
    numtests: HalC2.Prop.numtests(100),
    max_size: 20 do
    forall {text, kept} <- {text(), list(attachment())} do
      chars = String.length(text)
      {:ok, folded, attachments} = Attachments.fold_long_text("t-prop", text, kept)

      checks =
        if chars <= @limit do
          [
            untouched: folded == text and attachments == kept,
            unfound: Attachments.folded_into(folded, attachments) == [],
            nothing_behind:
              Attachments.left_behind(folded, "edited", attachments, attachments) == []
          ]
        else
          [file] = attachments -- kept
          name = file["name"]

          note =
            "\n\n[... #{chars - 10_000} characters cut here; the whole message is in the attached #{name} ...]\n\n"

          [
            ends:
              folded ==
                String.slice(text, 0, 8_000) <> note <> String.slice(text, chars - 2_000, 2_000),
            appended: Enum.drop(attachments, -1) == kept and List.last(attachments) == file,
            fresh_name: name not in Enum.map(kept, & &1["name"]),
            whole: File.read!(Attachments.path(file)) == text,
            described:
              file["sizeBytes"] == byte_size(text) and
                file["source"] == %{"_tag" => "pasted-text", "folded" => true} and
                file["mimeType"] == "text/plain",
            found: Attachments.folded_into(folded, attachments) == [file],
            edited:
              Attachments.left_behind(folded, "edited " <> folded, attachments, attachments) == [],
            replaced:
              Attachments.left_behind(folded, String.slice(text, 0, 10), attachments, attachments) ==
                [file],
            unlisted: Attachments.left_behind(folded, folded, attachments, kept) == [file],
            settles:
              Attachments.fold_long_text("t-prop", folded, attachments) ==
                {:ok, folded, attachments}
          ]
        end

      failed = for {name, false} <- checks, do: name

      (failed == [])
      |> when_fail(
        IO.puts("failed #{inspect(failed)} at #{chars} characters, kept #{inspect(kept)}")
      )
      |> aggregate(side: if(chars <= @limit, do: :short, else: :long))
    end
  end

  # Mostly near the limit, where an off-by-one would show, and sometimes far past it.
  # Sometimes it starts by quoting a cut mark naming a file the message may have.
  defp text do
    let {length, unit, quoted} <-
          {oneof([integer(0, 200), integer(@limit - 3, @limit + 3), integer(@limit, 3 * @limit)]),
           non_empty(list(oneof([range(?a, ?z), ?\n, ?é, ?€, 0x1F600]))),
           oneof([nil, "message.txt", "message-2.txt"])} do
      unit = List.to_string(unit)

      quote =
        if quoted,
          do: "[... 5 characters cut here; the whole message is in the attached #{quoted} ...]",
          else: ""

      (quote <> String.duplicate(unit, div(length, String.length(unit)) + 1))
      |> String.slice(0, max(length, String.length(quote)))
    end
  end

  # Names a message's own files may have, including the ones a fold would pick, and
  # sometimes a pasted text of its own.
  defp attachment do
    let {name, pasted} <-
          {oneof(["message.txt", "message-2.txt", "message-3.txt", "notes.md", "shot.png"]),
           boolean()} do
      file = %{"type" => "file", "id" => "kept-#{name}", "name" => name}
      if pasted, do: Map.put(file, "source", %{"_tag" => "pasted-text"}), else: file
    end
  end
end
