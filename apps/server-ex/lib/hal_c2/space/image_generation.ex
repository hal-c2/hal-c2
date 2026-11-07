defmodule HalC2.Space.ImageGeneration do
  @moduledoc """
  An image from a prompt, made by the coding agent of a provider the user already has:
  no image settings, no keys and no service of its own. The agent runs once in an empty
  scratch directory with its own image tool, and whatever image it leaves there goes
  through the same checks as an upload (`HalC2.Space.ImageFile`).

  Codex and Grok ship an image tool in the CLI the MC already runs. The others are not
  supported here: Claude, OpenCode and Pi have no image tool, and Cursor and Antigravity
  run through an SDK and a managed ACP agent whose image tools the MC cannot reach, only
  separate CLIs with logins of their own.

  The agent needs to write a file, so unlike text generation it runs with its tools on,
  in that directory, on the user's own prompt.
  """

  alias HalC2.Space.ImageFile
  alias HalC2.TextGeneration

  @supported ~w(codex grok)

  # The image models each provider's own image tool can be told to use; "auto" leaves the
  # choice to the provider. Codex's tool always asks for `gpt-image-2` and OpenAI picks
  # the model that runs it, with no setting to choose one (openai/codex,
  # codex-rs/ext/image-generation/src/tool.rs, and its issue #43965). Grok's takes
  # `features.image_gen_model_override`, which `GROK_IMAGE_GEN_MODEL_OVERRIDE` sets; the
  # ids are xAI's (https://docs.x.ai/docs/models).
  @models %{
    "codex" => [
      %{
        "slug" => "auto",
        "name" => "GPT Image",
        "description" => "OpenAI picks the model. Codex cannot choose it."
      }
    ],
    "grok" => [
      %{"slug" => "auto", "name" => "Grok Imagine", "description" => "Grok picks the model."},
      %{
        "slug" => "grok-imagine-image-2.0",
        "name" => "Grok Imagine Image 2.0",
        "description" => nil
      },
      %{"slug" => "grok-imagine-image", "name" => "Grok Imagine Image", "description" => nil}
    ]
  }

  @doc """
  How long an agent may take to make an image: 5 minutes. Tests shorten it with the
  `:image_generation_timeout` app env.
  """
  def timeout, do: Application.get_env(:hal_c2, :image_generation_timeout, 300_000)

  @doc """
  `space.image.providers`: each provider that can make an image, whether it is ready to,
  and the image models it can be told to use; and the selection used when the user does
  not choose. Providers that cannot make images are left out.
  """
  def providers do
    settings = HalC2.Settings.settings()

    %{
      "providers" => for(id <- instances(settings), do: provider(settings, id)),
      "selection" => default(settings)
    }
  end

  # The built-in instances first, then those the settings add, of a driver that can.
  defp instances(settings) do
    (@supported ++ Map.keys(settings["providerInstances"] || %{}))
    |> Enum.uniq()
    |> Enum.filter(&(TextGeneration.driver(&1) in @supported))
  end

  defp provider(settings, id) do
    driver = TextGeneration.driver(id)
    ready = TextGeneration.usable?(settings, %{"instanceId" => id})

    %{
      "instanceId" => id,
      "driver" => driver,
      "status" => if(ready, do: "ready", else: "unavailable"),
      "message" => if(ready, do: nil, else: unavailable(id)),
      "models" => @models[driver]
    }
  end

  defp unsupported(id), do: "#{id} does not generate images here."
  defp unavailable(id), do: "#{id} is not enabled or not installed."

  # The provider chosen for writing text when it can make images, else the first instance
  # that can, the built-in ones before those settings add; its provider picks the model.
  defp default(settings) do
    text = settings["textGenerationModelSelection"]

    preferred =
      if is_map(text) and is_binary(text["instanceId"]), do: [text["instanceId"]], else: []

    Enum.find_value(preferred ++ instances(settings), fn id ->
      if TextGeneration.driver(id) in @supported and
           TextGeneration.usable?(settings, %{"instanceId" => id}),
         do: %{"instanceId" => id, "model" => "auto"}
    end)
  end

  @doc """
  Runs the agent and leaves its image as a pending upload for
  `HalC2.Space.add_image/5`: `{:ok, attachment_id, selection used}`, or `{:error, reason,
  message}` with reason `:unsupported`, `:unavailable` or `:failed`. The selection's
  model is an image model of `providers/0`; any other, such as an older client's chat
  model, leaves the choice to the provider. The agent itself runs on the provider's
  model for writing text, which the MC picks.
  """
  def generate(prompt, selection) do
    with {:ok, selection} <- choose(selection) do
      dir = HalC2.Scratch.dir("hal-c2-image")

      try do
        with {:ok, _} <- run(selection, dir, instruction(prompt)),
             {:ok, file} <- newest_image(dir),
             {:ok, upload} <- pending(file) do
          {:ok, upload, selection}
        else
          {:error, message} -> {:error, :failed, message}
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp choose(%{"instanceId" => id} = selection) when is_binary(id) do
    settings = HalC2.Settings.settings()
    driver = TextGeneration.driver(id)

    cond do
      driver not in @supported ->
        {:error, :unsupported, unsupported(id)}

      TextGeneration.usable?(settings, selection) ->
        {:ok, %{"instanceId" => id, "model" => image_model(driver, selection["model"])}}

      true ->
        {:error, :unavailable, unavailable(id)}
    end
  end

  defp choose(_none) do
    case default(HalC2.Settings.settings()) do
      nil ->
        {:error, :unavailable,
         "No provider that can generate images is available. Install Codex or Grok, or enable one."}

      selection ->
        {:ok, selection}
    end
  end

  # A model the provider's tool cannot be told, such as the chat model an older client's
  # Generate dialog sent, leaves the choice to the provider.
  defp image_model(driver, model) do
    if Enum.any?(@models[driver], &(&1["slug"] == model)), do: model, else: "auto"
  end

  defp instruction(prompt) do
    """
    Generate one image with your image generation tool, then save the finished image \
    file in the current directory and stop. Do not ask questions and do nothing else.

    The image should show:
    #{prompt}
    """
  end

  defp run(selection, dir, instruction) do
    id = selection["instanceId"]

    case TextGeneration.driver(id) do
      "codex" ->
        launch =
          case HalC2.Codex.Provider.launch_args(id) do
            {:ok, args} -> HalC2.Codex.Provider.exec_args(args)
            {:error, _} -> []
          end

        args =
          ["exec"] ++
            launch ++
            ~w(--skip-git-repo-check -s workspace-write) ++
            ["--model", TextGeneration.default_model("codex")] ++
            ["--config", ~s(model_reasoning_effort="low"), "-"]

        TextGeneration.run_cli([TextGeneration.codex_command(id) | args], dir, instruction,
          timeout: timeout()
        )

      "grok" ->
        with {:ok, [command | _], env} <- HalC2.Acp.command(id) do
          model = TextGeneration.default_model("grok")
          args = ["-p", instruction, "--cwd", dir, "-m", model, "--yolo"]
          env = env ++ grok_image_model(selection["model"])
          TextGeneration.run_cli([command | args], dir, "", timeout: timeout(), env: env)
        end
    end
  end

  defp grok_image_model("auto"), do: []
  defp grok_image_model(model), do: [{"GROK_IMAGE_GEN_MODEL_OVERRIDE", model}]

  # What the agent left in its directory: regular files only, never a link it made, and
  # the newest that passes the checks.
  defp newest_image(dir) do
    candidates =
      for name <- File.ls!(dir),
          file = Path.join(dir, name),
          {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.lstat(file, time: :posix)],
          match?({:ok, _}, ImageFile.check(file)),
          do: {mtime, file}

    case Enum.sort(candidates, :desc) do
      [{_, file} | _] -> {:ok, file}
      [] -> {:error, "The agent finished without leaving an image."}
    end
  end

  # Copied in beside the uploads, as the scratch directory may be on another disk.
  defp pending(file) do
    id = "pending-#{HalC2.Environment.uuid4()}"
    target = Path.join(HalC2.Attachments.dir(), id <> ".image")
    File.mkdir_p!(HalC2.Attachments.dir())

    case File.cp(file, target) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, "The image could not be kept: #{inspect(reason)}."}
    end
  end
end
