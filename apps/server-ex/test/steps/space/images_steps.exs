defmodule HalC2.Steps.Space.Images do
  @moduledoc """
  Steps for `features/space/images.feature`. A file reaches the MC as a client's does:
  a signed upload over HTTP, then `space.image.add`. Generating runs
  `test/support/fake_image_cli.py` as the provider's CLI. Images are found by the name
  they were added under in `context.image_ids`, which outlasts the image itself.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Attachments, Space, StreamState, Streams}
  alias HalC2.Space.{Blocks, Images}
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  @fake Path.expand("../../support/fake_image_cli.py", __DIR__)
  @watch 71
  # What a test image holds past its header, to look for where it must not be.
  @marker "HAL-C2-IMAGE-BYTES"

  # --- adding --------------------------------------------------------------------------

  step "the user adds the image {string} to {string}", %{args: [name, space]} = context do
    add(context, space, name, png())
  end

  step("the image {string} in {string}", %{args: [name, space]} = context,
    do: add(context, space, name, png())
  )

  step "the user adds the file {string} holding plain text to {string}",
       %{args: [name, space]} = context do
    add(context, space, name, "just some notes\n")
  end

  step "the user adds a {word} file called {string} to {string}",
       %{args: [content, name, space]} = context do
    add(context, space, name, sample(content))
  end

  step "the user adds an SVG file to {string}", %{args: [space]} = context do
    add(context, space, "x.svg", ~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>))
  end

  step "the user adds a PNG with a broken header to {string}", %{args: [space]} = context do
    add(context, space, "x.png", <<0x89, "PNG\r\n", 0x1A, "\n", 0::32, "nope">>)
  end

  step "the user adds a PNG claiming to be 20000 by 20000 to {string}",
       %{args: [space]} = context do
    add(context, space, "x.png", png(20_000, 20_000))
  end

  step "the user asks to upload an image of 11 MB", context do
    payload = %{"name" => "big.png", "mimeType" => "image/png", "sizeBytes" => 11 * 1024 * 1024}
    {reply, context} = World.call(context, "attachments.createUploadUrl", payload)
    Map.put(context, :space_reply, reply)
  end

  step "the upload is refused", context do
    assert {:error, _, _} = context.space_reply
    context
  end

  step "the user adds the same upload again", context do
    payload = %{"spaceId" => context.space, "attachmentId" => context.upload, "name" => "again"}
    request(context, "space.image.add", payload)
  end

  step "the image request is refused", context do
    assert {:error, _, %{"_tag" => "SpaceError"}} = context.space_reply
    context
  end

  step "the images of {string} are {string}", %{args: [name, names]} = context do
    live = name |> space_state(context) |> Images.live()
    assert Enum.map_join(live, ", ", & &1["name"]) == names
    context
  end

  step "the image trash of {string} holds {string}", %{args: [name, names]} = context do
    trashed = name |> space_state(context) |> Images.trashed()
    assert Enum.map_join(trashed, ", ", & &1["name"]) == names
    context
  end

  step "the image {string} is a {word}", %{args: [name, type]} = context do
    assert image(context, name)["mimeType"] == type
    context
  end

  step "the second client sees the image {string}", %{args: [name]} = context do
    match? = fn frame ->
      frame["t"] == "events" and frame["id"] == @watch and
        Enum.any?(frame["events"], fn [_seq, kind, _id, patch | _] ->
          kind == "image" and is_map(patch["s"]) and patch["s"]["name"] == name
        end)
    end

    {_, client} = Mc.await(World.client(context, "second"), match?, 5_000)
    World.put_client(context, "second", client)
  end

  # --- generating ----------------------------------------------------------------------

  step("image generation is available", context, do: install(context, [:codex]))

  step "no image generation provider is available", context do
    context
    |> install([])
    |> World.update_settings(%{"providers" => %{"grok" => %{"enabled" => false}}})
  end

  step "image generation fails", context do
    World.put_env("FAKE_IMAGE_MODE", "fail")
    install(context, [:codex])
  end

  step "{word} is installed and can generate images", %{args: [provider]} = context do
    install(context, [String.to_atom(provider)])
  end

  step("no other provider is available", context, do: context)

  step "a codex instance {string} that can generate images", %{args: [id]} = context do
    instance = %{"driver" => "codex", "enabled" => true, "config" => %{"binaryPath" => @fake}}

    context
    |> install([])
    |> World.update_settings(%{"providerInstances" => %{id => instance}})
  end

  step "grok is installed and never finishes", context do
    World.put_env("FAKE_IMAGE_MODE", "hang")
    World.put_app_env(:image_generation_timeout, 500)
    install(context, [:grok])
  end

  step "the user is told image generation timed out", context do
    context = told(context, "failed")
    assert inspect(context.space_reply) =~ "timed out"
    context
  end

  step "no agent's scratch folder is left", context do
    scratch = Path.dirname(HalC2.Scratch.path("probe"))
    assert Path.wildcard(Path.join(scratch, "hal-c2-image-*")) == []
    context
  end

  step "grok is installed and leaves no file", context do
    World.put_env("FAKE_IMAGE_MODE", "none")
    install(context, [:grok])
  end

  step "grok is installed and leaves a file that is not an image", context do
    World.put_env("FAKE_IMAGE_MODE", "text")
    install(context, [:grok])
  end

  step "the user generates an image of {string} in {string}",
       %{args: [prompt, space]} = context do
    generate(context, space, %{"prompt" => prompt})
  end

  step "the user generates an image of {string} in {string} with {word}",
       %{args: [prompt, space, provider]} = context do
    Mc.ensure(HalC2.Settings)
    selection = %{"instanceId" => provider}
    generate(context, space, %{"prompt" => prompt, "modelSelection" => selection})
  end

  step "the user generates an image of {string} in {string} with {word} using {string}",
       %{args: [prompt, space, provider, model]} = context do
    Mc.ensure(HalC2.Settings)
    selection = %{"instanceId" => provider, "model" => model}
    generate(context, space, %{"prompt" => prompt, "modelSelection" => selection})
  end

  step "{string} has a generated image of {string}", %{args: [space, prompt]} = context do
    image = Enum.find(Images.live(space_state(space, context)), &(&1["prompt"] == prompt))
    assert %{"name" => ^prompt, "mimeType" => "image/png", "generatedBy" => %{}} = image
    assert File.regular?(Space.ImageFile.path(image["id"]))
    context
  end

  step "the user is told image generation is unavailable", context do
    told(context, "unavailable")
  end

  step("the user is told image generation failed", context, do: told(context, "failed"))

  step "the user is told {word} does not generate images here", %{args: [provider]} = context do
    context = told(context, "unsupported")
    {:error, message, _} = context.space_reply
    assert message =~ provider
    context
  end

  step "the image remembers it was made by {word}", %{args: [provider]} = context do
    assert {:ok, %{"image" => %{"generatedBy" => %{"instanceId" => ^provider}}}} =
             context.space_reply

    context
  end

  step "the image remembers it was made by {word} using {string}",
       %{args: [provider, model]} = context do
    assert {:ok,
            %{"image" => %{"generatedBy" => %{"instanceId" => ^provider, "model" => ^model}}}} =
             context.space_reply

    context
  end

  step "the user is told {string} is not an image model {word} can use",
       %{args: [model, provider]} = context do
    context = told(context, "unsupported")
    {:error, message, _} = context.space_reply
    assert message =~ model and message =~ provider
    context
  end

  step "the agent ran on {string}, a model the MC picked for writing text",
       %{args: [model]} = context do
    [call] = calls(context)
    pairs = Enum.chunk_every(call["argv"], 2, 1)
    assert ["--model", model] in pairs or ["-m", model] in pairs

    context
  end

  step "grok was told to draw with {string}", %{args: [model]} = context do
    assert [%{"imageModel" => ^model}] = calls(context)
    context
  end

  step "grok was not told which image model to use", context do
    assert [%{"imageModel" => nil}] = calls(context)
    context
  end

  step "only the providers that can generate are offered, with their image models", context do
    {%{"providers" => providers, "selection" => selection}, context} =
      World.call!(context, "space.image.providers")

    assert Enum.map(providers, &{&1["instanceId"], &1["status"]}) == [
             {"codex", "ready"},
             {"grok", "unavailable"}
           ]

    models =
      Map.new(providers, &{&1["instanceId"], Enum.map(&1["models"], fn m -> m["slug"] end)})

    assert models["codex"] == ["auto"]
    assert models["grok"] == ["auto", "grok-imagine-image-2.0", "grok-imagine-image"]
    assert selection == %{"instanceId" => "codex", "model" => "auto"}
    context
  end

  # --- on a page -----------------------------------------------------------------------

  step "the user places the image {string} on {string}", %{args: [name, title]} = context do
    request(context, "space.block.insert", placement(context, name, title))
  end

  step "{string} shows the image {string} already", %{args: [title, name]} = context do
    {_, context} = World.call!(context, "space.block.insert", placement(context, name, title))
    context
  end

  step "{string} shows the image {string}", %{args: [title, name]} = context do
    assert_block(context, title, name)
    assert image(context, name)["trashedAt"] == nil
    context
  end

  step "{string} says the image {string} is in the trash", %{args: [title, name]} = context do
    assert_block(context, title, name)
    assert image(context, name)["trashedAt"] != nil
    context
  end

  step "{string} says the image {string} was deleted", %{args: [title, name]} = context do
    assert_block(context, title, name)
    assert image(context, name) == nil
    context
  end

  step "the user removes the image from {string}", %{args: [title]} = context do
    [block] = Enum.filter(blocks(context, title), &(&1["kind"] == "image"))

    request(context, "space.block.delete", %{"spaceId" => context.space, "blockId" => block["id"]})
  end

  step "the Space keeps one file for {string}", %{args: [name]} = context do
    assert image_files() == [Space.ImageFile.path(id(context, name))]
    context
  end

  step "the Markdown holds the image {string}", %{args: [name]} = context do
    assert {:ok, %{"markdown" => markdown}} = context.space_reply
    assert markdown =~ "![#{name}](space-image:#{id(context, name)})"
    Map.put(context, :markdown, markdown)
  end

  step "the user imports that Markdown into {string} as {string}",
       %{args: [space, title]} = context do
    markdown = String.replace(context.markdown, ~r/^# .*$/m, "# " <> title, global: false)
    payload = %{"spaceId" => context.spaces[space], "markdown" => markdown}
    request(context, "space.page.importMarkdown", payload)
  end

  # --- trash ---------------------------------------------------------------------------

  step "the user moves the image {string} to the trash", %{args: [name]} = context do
    request(context, "space.image.trash", ref(context, name))
  end

  step "the image {string} is in the image trash", %{args: [name]} = context do
    {_, context} = World.call!(context, "space.image.trash", ref(context, name))
    context
  end

  step "the user restores the image {string}", %{args: [name]} = context do
    request(context, "space.image.restore", ref(context, name))
  end

  step "the user deletes the image {string} for good", %{args: [name]} = context do
    request(context, "space.image.delete", ref(context, name))
  end

  # --- the bytes -----------------------------------------------------------------------

  step "the bytes of {string} can be fetched", %{args: [name]} = context do
    {url, context} = sign(context, name)
    assert {200, body} = fetch(context, url)
    assert body == context.image_bytes[name]
    context
  end

  step "a signed address for {string}", %{args: [name]} = context do
    {url, context} = sign(context, name)
    Map.put(context, :signed, url)
  end

  step "the signed address finds nothing", context do
    assert {status, _} = fetch(context, context.signed)
    assert status in [404, 410]
    context
  end

  step "no new address can be signed for {string}", %{args: [name]} = context do
    {reply, context} = World.call(context, "assets.createUrl", asset(context, name))
    assert {:error, _, _} = reply
    context
  end

  step "no image file is left behind", context do
    assert image_files() == []
    assert Path.wildcard(Path.join(Attachments.dir(), "pending-*")) == []
    context
  end

  step "the Space's event log holds none of the bytes of {string}", %{args: [_name]} = context do
    events =
      HalC2.Store.reduce_stream(
        HalC2.Store.path(),
        Space.stream_id(context.space),
        0,
        [],
        &[&1 | &2]
      )

    assert events != []
    logged = inspect(events, limit: :infinity, printable_limit: :infinity)
    refute logged =~ @marker
    refute logged =~ Base.encode64(@marker)
    context
  end

  # --- helpers -------------------------------------------------------------------------

  defp add(context, space, name, bytes) do
    payload = %{"name" => name, "mimeType" => "image/png", "sizeBytes" => byte_size(bytes)}

    {%{"attachmentId" => upload, "relativeUrl" => url}, context} =
      World.call!(context, "attachments.createUploadUrl", payload)

    target = String.to_charlist("http://127.0.0.1:#{context.mc.port}#{url}")

    {:ok, {{_, 204, _}, _, _}} =
      :httpc.request(:post, {target, [], ~c"image/png", bytes}, [timeout: 5_000],
        body_format: :binary
      )

    input = %{"spaceId" => context.spaces[space], "attachmentId" => upload, "name" => name}

    context
    |> Map.put(:upload, upload)
    |> request("space.image.add", input, fn %{"image" => image}, context ->
      context
      |> Map.update(:image_ids, %{name => image["id"]}, &Map.put(&1, name, image["id"]))
      |> Map.update(:image_bytes, %{name => bytes}, &Map.put(&1, name, bytes))
    end)
  end

  defp generate(context, space, input) do
    request(
      context,
      "space.image.generate",
      Map.put(input, "spaceId", context.spaces[space])
    )
  end

  # The fake as the CLI of `providers`; the others are not there.
  defp install(context, providers) do
    World.put_env("FAKE_IMAGE_LOG", Path.join(context.mc.home, "image-calls.jsonl"))

    World.put_app_env(
      :text_codex_command,
      if(:codex in providers, do: @fake, else: "hal-c2-test-no-codex")
    )

    commands =
      if :grok in providers, do: %{"grok" => [@fake]}, else: %{"grok" => ["hal-c2-test-no-grok"]}

    World.put_app_env(:acp_commands, commands)
    Mc.ensure(HalC2.Settings)

    if :grok in providers,
      do: World.update_settings(context, %{"providers" => %{"grok" => %{"enabled" => true}}}),
      else: context
  end

  # Each call the fake CLI logged, oldest first.
  defp calls(context) do
    Path.join(context.mc.home, "image-calls.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp told(context, reason) do
    assert {:error, _, %{"_tag" => "SpaceImageGenerationError", "reason" => ^reason}} =
             context.space_reply

    context
  end

  defp request(context, method, payload, on_ok \\ fn _, context -> context end) do
    {reply, context} = World.call(context, method, payload)
    context = Map.put(context, :space_reply, reply)

    case reply do
      {:ok, result} -> on_ok.(result, context)
      _ -> context
    end
  end

  defp space_state(name, context), do: Streams.state(Space.stream_id(context.spaces[name]))
  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp id(context, name),
    do: (context[:image_ids] || %{})[name] || flunk("no image #{inspect(name)} in this scenario")

  defp image(context, name), do: Images.get(state(context), id(context, name))
  defp ref(context, name), do: %{"spaceId" => context.space, "imageId" => id(context, name)}

  defp page_id(context, title) do
    pages = Map.values(StreamState.get(state(context), "page"))
    Enum.find(pages, &(&1["title"] == title))["id"] || flunk("no page #{inspect(title)}")
  end

  defp blocks(context, title), do: Blocks.of_page(state(context), page_id(context, title))

  defp placement(context, name, title) do
    %{
      "spaceId" => context.space,
      "pageId" => page_id(context, title),
      "kind" => "image",
      "imageId" => id(context, name)
    }
  end

  defp assert_block(context, title, name) do
    image_id = id(context, name)

    assert Enum.any?(
             blocks(context, title),
             &(&1["kind"] == "image" and &1["imageId"] == image_id and &1["text"] == name)
           )
  end

  defp asset(context, name) do
    %{
      "resource" => %{
        "_tag" => "space-image",
        "spaceId" => context.space,
        "imageId" => id(context, name)
      }
    }
  end

  defp sign(context, name) do
    {%{"relativeUrl" => url}, context} =
      World.call!(context, "assets.createUrl", asset(context, name))

    {url, context}
  end

  defp fetch(context, url) do
    target = String.to_charlist("http://127.0.0.1:#{context.mc.port}#{url}")

    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(:get, {target, []}, [timeout: 5_000], body_format: :binary)

    {status, body}
  end

  defp image_files, do: Path.wildcard(Path.join(Attachments.dir(), "space_image_*"))

  # Only the headers are real: the MC never decodes the pixels.
  defp png(width \\ 2, height \\ 2) do
    <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0, 0::32,
      @marker>>
  end

  defp sample("PNG"), do: png()
  defp sample("GIF"), do: <<"GIF89a", 2::little-16, 2::little-16, 0, 0, 0, @marker>>

  defp sample("JPEG") do
    <<0xFF, 0xD8, 0xFF, 0xE0, 16::16, 0::size(14)-unit(8), 0xFF, 0xC0, 17::16, 8, 2::16, 2::16, 3,
      0::size(9)-unit(8), @marker>>
  end

  defp sample("WebP"),
    do:
      <<"RIFF", 0::little-32, "WEBP", "VP8 ", 0::little-32, 0::24, 0x9D, 0x01, 0x2A, 2::little-16,
        2::little-16, @marker>>
end
