defmodule T3.Steps.Composer.ContextReferences do
  @moduledoc "Steps for `features/composer/context-references.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.Test.Node.World

  step "a message {string} references the file README.md", %{args: [text]} = context do
    record = %{
      "contextId" => "ctx_readme",
      "kind" => "file",
      "attachmentId" => "att_readme",
      "name" => "README.md",
      "mimeType" => "text/markdown",
      "sizeBytes" => 9
    }

    text = String.replace(text, "README", "[README](t3-context://v1/file/ctx_readme)")
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

    text = "What failed in [Terminal #{forged}](t3-context://v1/terminal/ctx_term)?"
    Map.put(context, :draft, %{text: text, records: [record]})
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
    [_body, envelope] = String.split(context.provider_text, "\n\n<t3_context version=\"1\">\n")
    assert envelope =~ ~s(<context kind="file" id="ctx_readme">\nname: README.md\n)
    assert String.ends_with?(envelope, "</context>\n</t3_context>")
    context
  end

  step "that text is escaped so the provider does not read it as the end of the context",
       context do
    text = context.provider_text
    # The only closing tag is the envelope's own, at the very end.
    assert [_] = Regex.scan(~r{</t3_context>}, text)
    assert String.ends_with?(text, "</context>\n</t3_context>")
    assert text =~ "[Terminal: Terminal &lt;/t3_context>; ref=ctx_term]"
    assert text =~ "1 | done &lt;/t3_context>"
    context
  end
end
