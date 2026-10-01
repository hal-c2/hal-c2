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
end
