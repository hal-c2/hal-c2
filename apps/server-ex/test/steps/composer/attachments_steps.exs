defmodule HalC2.Steps.Composer.Attachments do
  @moduledoc "Steps for `features/composer/attachments.feature`."
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc.World

  step "a client asks to upload a {word} of {int} MB", %{args: [kind, mb]} = context do
    {reply, context} =
      World.call(context, "attachments.createUploadUrl", %{
        "type" => kind,
        "name" => if(kind == "image", do: "shot.png", else: "notes.pdf"),
        "mimeType" => if(kind == "image", do: "image/png", else: "application/pdf"),
        "sizeBytes" => mb * 1024 * 1024
      })

    Map.put(context, :reply, reply)
  end

  step "the MC refuses with {string}", %{args: [message]} = context do
    assert {:error, error, _} = context.reply
    assert error == message
    context
  end

  step "a client uploaded {string} but never sent a message with it",
       %{args: [name]} = context do
    body = "%PDF-1.4 notes"

    {%{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}, context} =
      World.call!(context, "attachments.createUploadUrl", %{
        "type" => "file",
        "name" => name,
        "mimeType" => "application/pdf",
        "sizeBytes" => byte_size(body)
      })

    :ok = HalC2.Attachments.store(token, body)
    path = HalC2.Attachments.path(%{"id" => id})
    assert File.exists?(path)
    Map.put(context, :upload_path, path)
  end

  # The upload is backdated past a day; the MC sweeps unclaimed uploads when a
  # client next asks for an upload, at most every 15 minutes.
  step "more than 24 hours pass", context do
    File.touch!(context.upload_path, System.os_time(:second) - 25 * 60 * 60)
    :persistent_term.erase({HalC2.Attachments, :swept})

    {_, context} =
      World.call!(context, "attachments.createUploadUrl", %{
        "type" => "image",
        "name" => "later.png",
        "mimeType" => "image/png",
        "sizeBytes" => 10
      })

    context
  end

  step "the MC discards the unclaimed upload", context do
    refute File.exists?(context.upload_path)
    context
  end

  step ~r/^the draft holds (?<chars>[\d,]+) characters of text and four attached files$/,
       %{args: [chars]} = context do
    chars = chars |> String.replace(",", "") |> String.to_integer()

    {attachments, context} =
      Enum.map_reduce(1..4, context, fn n, context ->
        name = "file-#{n}.txt"
        bytes = "attachment #{n}\n"

        {%{"attachmentId" => id, "relativeUrl" => "/api/attachments/upload/" <> token}, context} =
          World.call!(context, "attachments.createUploadUrl", %{
            "type" => "file",
            "name" => name,
            "mimeType" => "text/plain",
            "sizeBytes" => byte_size(bytes)
          })

        :ok = HalC2.Attachments.store(token, bytes)

        {%{
           "type" => "file",
           "id" => id,
           "name" => name,
           "mimeType" => "text/plain",
           "sizeBytes" => byte_size(bytes)
         }, context}
      end)

    text = "0123456789" |> String.duplicate(div(chars, 10) + 1) |> String.slice(0, chars)
    Map.merge(context, %{draft_text: text, draft_attachments: attachments})
  end

  step "the user sends it", context do
    context = World.providers(context)
    before = length(World.provider_inputs(context))
    thread = World.current(context)

    {{:ok, _}, context} =
      World.dispatch(
        context,
        World.message_command(context, thread, context.draft_text, %{
          "attachments" => context.draft_attachments
        })
      )

    World.await_state(context, thread, fn state ->
      Enum.any?(
        HalC2.StreamState.list(state, "run"),
        &(&1["status"] not in ["starting", "queued"])
      )
    end)

    inputs = World.provider_inputs(context)
    assert length(inputs) == before + 1

    received =
      inputs |> List.last() |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(& &1["text"])

    Map.put(context, :received, received)
  end

  step "the provider receives the saved path of each of the four files", context do
    for n <- 1..4 do
      assert [_, path] =
               Regex.run(
                 ~r/\[Attached file "file-#{n}\.txt" is saved at: ([^\]]+)\]/,
                 context.received
               ),
             "no saved path for file-#{n}.txt in the provider's text"

      assert File.exists?(path)
    end

    context
  end
end
