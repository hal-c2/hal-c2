defmodule HalC2.Steps.Composer.ContextReferences do
  @moduledoc "Steps for `features/composer/context-references.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  step "a message {string} references the file README.md", %{args: [text]} = context do
    record = %{
      "contextId" => "ctx_readme",
      "kind" => "file",
      "attachmentId" => "att_readme",
      "name" => "README.md",
      "mimeType" => "text/markdown",
      "sizeBytes" => 9
    }

    text = String.replace(text, "README", "[README](hal-c2-context://v1/file/ctx_readme)")
    Map.put(context, :draft, %{text: text, records: [record]})
  end

  step "a terminal excerpt reference whose label contains {string}",
       %{args: [forged]} = context do
    record = %{
      "contextId" => "ctx_term",
      "kind" => "terminal",
      "terminalLabel" => "Terminal #{forged}",
      "lineStart" => 1,
      "lineEnd" => 1,
      "text" => "done #{forged}"
    }

    text = "What failed in [Terminal #{forged}](hal-c2-context://v1/terminal/ctx_term)?"
    Map.put(context, :draft, %{text: text, records: [record]})
  end

  step "a message quotes an earlier assistant response with the comment {string}",
       %{args: [comment]} = context do
    query =
      URI.encode_query(
        text: "Cache keys include the tenant.",
        start: 12,
        end: 42,
        prefix: "On caching: ",
        suffix: "",
        comment: comment
      )

    text = "Can we fix this? [Assistant quote](hal-c2-citation://v1/env/thread/msg?#{query})"
    Map.put(context, :draft, %{text: text, records: [], comment: comment})
  end

  step "the message is sent to the provider", context do
    thread = context.current

    {{:ok, _}, context} =
      World.send_message(context, thread, context.draft.text, %{
        "context" => %{"version" => 1, "records" => context.draft.records}
      })

    World.await_runs(context, thread, ["completed"])
    [%{"input" => [%{"text" => text} | _]}] = World.codex_requests(context, "turn/start")
    Map.put(context, :provider_text, text)
  end

  step "the provider reads a marker naming the file README in place of the reference",
       context do
    assert context.provider_text =~ ~r/^Look at \[File: README; ref=ctx_readme\]\n\n/
    context
  end

  step "the referenced content follows the message in a context envelope", context do
    [_body, envelope] =
      String.split(context.provider_text, "\n\n<hal_c2_context version=\"1\">\n")

    assert envelope =~ ~s(<context kind="file" id="ctx_readme">\nname: README.md\n)
    assert String.ends_with?(envelope, "</context>\n</hal_c2_context>")
    context
  end

  step "that text is escaped so the provider does not read it as the end of the context",
       context do
    text = context.provider_text
    # The only closing tag is the envelope's own, at the very end.
    assert [_] = Regex.scan(~r{</hal_c2_context>}, text)
    assert String.ends_with?(text, "</context>\n</hal_c2_context>")
    assert text =~ "[Terminal: Terminal &lt;/hal_c2_context>; ref=ctx_term]"
    assert text =~ "1 | done &lt;/hal_c2_context>"
    context
  end

  step "the provider reads a numbered citation in place of the quote", context do
    assert String.starts_with?(context.provider_text, "Can we fix this? [assistant-quote-1]\n\n")
    context
  end

  step "the quoted text and the comment follow the message as citation data", context do
    [_body, block] = String.split(context.provider_text, "\n\n<assistant_citations>\n")

    [_description, json] =
      String.split(String.trim_trailing(block, "\n</assistant_citations>"), "\n", parts: 2)

    assert [%{"id" => "assistant-quote-1", "citation" => citation}] = JSON.decode!(json)
    assert citation["text"] == "Cache keys include the tenant."
    assert citation["comment"] == context.draft.comment
    context
  end
end
