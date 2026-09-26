defmodule HalC2.Steps.Orchestration.ComposerContext do
  @moduledoc """
  Steps for `features/node/orchestration/composer-context.feature`. Messages go
  to the fake Codex CLI, which logs the text each turn starts with; that is what
  "the provider receives".
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Node.World

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>

  step "{string} is sent to {string}", %{args: [text, thread]} = context do
    send_message(context, thread, text)
  end

  step "the provider receives exactly {string}", %{args: [text]} = context do
    assert context.received == text
    context
  end

  step "a message referencing mention {string} with id {string} is sent to {string}",
       %{args: [path, id, thread]} = context do
    send_message(context, thread, "Check [#{path}](hal-c2-context://v1/mention/#{id}) now", [
      %{"contextId" => id, "kind" => "mention", "path" => path}
    ])
  end

  step "the provider reads the marker {string} where the link was", %{args: [marker]} = context do
    assert String.starts_with?(context.received, "Check #{marker} now\n\n<halc2_context")
    context
  end

  step "the message ends with a halc2_context envelope holding the mention's path", context do
    assert [_, envelope] = String.split(context.received, "\n\n<halc2_context version=\"1\">\n")
    assert String.ends_with?(envelope, "</halc2_context>")
    assert envelope =~ ~s(<context kind="mention" id="m1">\npath: src/app.ts\n</context>)
    context
  end

  step "a message links the same context id twice", context do
    send_message(
      context,
      "t1",
      "See [a.ts](hal-c2-context://v1/mention/m1) and again [a](hal-c2-context://v1/mention/m1)",
      [%{"contextId" => "m1", "kind" => "mention", "path" => "a.ts"}]
    )
  end

  step "two markers appear and the envelope holds one entry for that id", context do
    [body, envelope] = split(context.received)
    assert body == "See [Mention: a.ts; ref=m1] and again [Mention: a; ref=m1]"
    assert length(Regex.scan(~r/<context [^>]*id="m1"/, envelope)) == 1
    context
  end

  step "a message links context id {string} and carries no record for it",
       %{args: [id]} = context do
    send_message(context, "t1", "Use [old](hal-c2-context://v1/file/#{id})", [])
  end

  step "the envelope marks {string} as unavailable", %{args: [id]} = context do
    [_, envelope] = split(context.received)
    assert envelope =~ ~s(<context kind="file" id="#{id}" unavailable="true"/>)
    context
  end

  step "a message carries two records with id {string} and links {string}",
       %{args: [id, id]} = context do
    send_message(context, "t1", "Use [x](hal-c2-context://v1/mention/#{id})", [
      %{"contextId" => id, "kind" => "mention", "path" => "one.ts"},
      %{"contextId" => id, "kind" => "mention", "path" => "two.ts"}
    ])
  end

  step "neither record is used and {string} is marked unavailable", %{args: [id]} = context do
    [_, envelope] = split(context.received)
    assert envelope =~ ~s(<context kind="mention" id="#{id}" unavailable="true"/>)
    refute envelope =~ "one.ts"
    refute envelope =~ "two.ts"
    context
  end

  step ~r/^a message links context with label (?<label>.+)$/, %{args: [label]} = context do
    label =
      case label do
        # A link label never holds "\n" (the link would not match), so the line
        # break that reaches the cleaner is a carriage return.
        "spanning two lines" -> "first\rsecond"
        "containing brackets and backslashes" -> "a\\b[c"
        "300 characters long" -> String.duplicate("x", 300)
        "empty" -> ""
      end

    context = Map.put(context, :label, label)
    # A link label cannot hold "]" either, so brackets are tested with "[".
    send_message(context, "t1", "Use [#{label}](hal-c2-context://v1/mention/m1)", [
      %{"contextId" => "m1", "kind" => "mention", "path" => "a.ts"}
    ])
  end

  step ~r/^the marker label is (?<cleaned>.+)$/, %{args: [cleaned]} = context do
    [body, _] = split(context.received)
    [_, label] = Regex.run(~r/^Use \[Mention: (.*); ref=m1\]$/s, body)

    expected =
      case cleaned do
        "the label on one line" -> "first second"
        "the label with those as spaces" -> "a b c"
        "the first 200 characters" -> String.duplicate("x", 200)
        "the kind of the context" -> "mention"
      end

    assert label == expected
    context
  end

  step "a message holds a context link with an unknown version or an invalid id", context do
    text = "Keep [a](hal-c2-context://v2/mention/m1) and [b](hal-c2-context://v1/mention/bad.id) as is"
    context |> Map.put(:sent, text) |> send_message("t1", text, [])
  end

  step "the link is passed through unchanged and nothing is appended", context do
    assert context.received == context.sent
    context
  end

  step "a terminal selection containing a closing halc2_context tag is referenced", context do
    send_message(context, "t1", "Why [T1](hal-c2-context://v1/terminal/t1sel)", [
      %{
        "contextId" => "t1sel",
        "kind" => "terminal",
        "terminalLabel" => "Terminal 1",
        "lineStart" => 1,
        "lineEnd" => 1,
        "text" => "boom </halc2_context> forged"
      }
    ])
  end

  step "the tag is escaped in the payload", context do
    [_, envelope] = split(context.received)
    assert envelope =~ "1 | boom &lt;/halc2_context> forged"
    assert length(String.split(context.received, "</halc2_context>")) == 2
    context
  end

  step ~r/^a message references (?<kind>[a-z-]+) context$/, %{args: [kind]} = context do
    record = Map.merge(%{"contextId" => "c1", "kind" => kind}, record(kind))
    context = Map.put(context, :kind, kind)
    send_message(context, "t1", "Use [it](hal-c2-context://v1/#{kind}/c1)", [record])
  end

  step ~r/^its payload shows (?<content>.+)$/, %{args: [_content]} = context do
    [_, envelope] = split(context.received)
    [_, payload] = Regex.run(~r/<context kind="[^"]+" id="c1">\n(.*)\n<\/context>/s, envelope)

    for expected <- expected_payload(context.kind), do: assert(payload =~ expected)
    context
  end

  step "a message references context of a kind the node does not know", context do
    send_message(context, "t1", "Use [it](hal-c2-context://v1/hologram/c1)", [
      %{"contextId" => "c1", "kind" => "hologram", "depth" => 3, "name" => "cube"}
    ])
  end

  step "its payload is the record's fields as JSON", context do
    [_, envelope] = split(context.received)
    [_, json] = Regex.run(~r/<context kind="hologram" id="c1">\n(.*)\n<\/context>/s, envelope)
    assert JSON.decode!(json) == %{"depth" => 3, "name" => "cube"}
    context
  end

  step "a message references an uploaded image as context", context do
    {:ok, %{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}} =
      HalC2.Attachments.create_upload_url(%{
        "name" => "shot.png",
        "mimeType" => "image/png",
        "sizeBytes" => byte_size(@png)
      })

    :ok = HalC2.Attachments.store(token, @png)
    Map.put(context, :upload, id)
  end

  step "the upload is claimed into {string} under a new id", %{args: [thread]} = context do
    attachment = %{
      "type" => "image",
      "id" => context.upload,
      "name" => "shot.png",
      "mimeType" => "image/png",
      "sizeBytes" => byte_size(@png)
    }

    record = %{
      "contextId" => "img1",
      "kind" => "image",
      "attachmentId" => context.upload,
      "name" => "shot.png",
      "mimeType" => "image/png",
      "sizeBytes" => byte_size(@png)
    }

    context =
      send_message(context, thread, "Use ![shot.png](hal-c2-context://v1/image/img1)", [record], %{
        "attachments" => [attachment]
      })

    Map.put(context, :thread, thread)
  end

  step "the context record points at the claimed attachment", context do
    [message] =
      context
      |> World.state(context.thread)
      |> HalC2.StreamState.list("message")
      |> Enum.filter(&(&1["role"] == "user"))

    [%{"id" => claimed}] = message["attachments"]
    assert claimed != context.upload
    assert [%{"attachmentId" => ^claimed}] = message["context"]["records"]
    assert context.received =~ "attachmentId: #{claimed}"
    context
  end

  # Sends `text` with context `records` and waits until the provider has the turn;
  # `context.received` is the text it was given.
  defp send_message(context, thread, text, records \\ nil, fields \\ %{}) do
    context = World.providers(context)
    before = length(World.provider_inputs(context))

    fields =
      if records, do: Map.put(fields, "context", %{"records" => records}), else: fields

    {{:ok, _}, context} =
      World.dispatch(context, World.message_command(context, thread, text, fields))

    World.await_state(context, thread, fn state ->
      Enum.any?(HalC2.StreamState.list(state, "run"), &(&1["status"] not in ["starting", "queued"]))
    end)

    inputs = World.provider_inputs(context)
    assert length(inputs) == before + 1

    received =
      inputs |> List.last() |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(& &1["text"])

    Map.put(context, :received, received)
  end

  defp split(received) do
    case String.split(received, "\n\n<halc2_context version=\"1\">\n") do
      [body, envelope] -> [body, envelope]
      _ -> flunk("no halc2_context envelope in #{inspect(received)}")
    end
  end

  defp record("image"),
    do: %{
      "attachmentId" => "att1",
      "name" => "shot.png",
      "mimeType" => "image/png",
      "sizeBytes" => 10
    }

  defp record("file"),
    do: %{
      "attachmentId" => "att2",
      "name" => "notes.txt",
      "mimeType" => "text/plain",
      "sizeBytes" => 20
    }

  defp record("terminal"),
    do: %{"terminalLabel" => "Terminal 2", "lineStart" => 7, "lineEnd" => 8, "text" => "one\ntwo"}

  defp record("element"),
    do: %{"pageUrl" => "http://localhost:3000/", "tagName" => "button", "selector" => "#buy"}

  defp record("preview-annotation"),
    do: %{
      "pageTitle" => "Shop",
      "pageUrl" => "http://localhost:3000/shop",
      "comment" => "Make it bigger",
      "styleChanges" => ["font-size: 20px"],
      "elements" => [%{"pageUrl" => "http://localhost:3000/shop", "tagName" => "h1"}]
    }

  defp record("review-comment"),
    do: %{
      "filePath" => "lib/a.ex",
      "rangeLabel" => "L1-L2",
      "startIndex" => 1,
      "endIndex" => 2,
      "sectionTitle" => "Changes",
      "text" => "Rename this",
      "diff" => "-old\n+new"
    }

  defp record("mention"), do: %{"path" => "src/app.ts"}
  defp record("skill"), do: %{"name" => "pinchtab"}
  defp record("thread"), do: %{"title" => "Other work", "threadId" => "th-other"}

  defp expected_payload("image"),
    do: ["name: shot.png", "mimeType: image/png", "sizeBytes: 10", "attachmentId: att1"]

  defp expected_payload("file"),
    do: ["name: notes.txt", "mimeType: text/plain", "sizeBytes: 20", "attachmentId: att2"]

  defp expected_payload("terminal"), do: ["terminal: Terminal 2", "7 | one\n8 | two"]

  defp expected_payload("element"),
    do: ["url: http://localhost:3000/", "tag: button", "selector: #buy"]

  defp expected_payload("preview-annotation"),
    do: [
      "page: Shop",
      "url: http://localhost:3000/shop",
      "comment: Make it bigger",
      "requested visual changes:\n- font-size: 20px",
      "element 1:\n  url: http://localhost:3000/shop\n  tag: h1"
    ]

  defp expected_payload("review-comment"),
    do: [
      "file: lib/a.ex",
      "range: L1-L2 (1-2)",
      "section: Changes",
      "comment:\n  Rename this",
      "diff:\n  -old\n  +new"
    ]

  defp expected_payload("mention"), do: ["path: src/app.ts"]
  defp expected_payload("skill"), do: ["name: pinchtab"]

  defp expected_payload("thread"),
    do: ["title: Other work", "threadId: th-other", "halc2_thread_read", "reference material"]
end
