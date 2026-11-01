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
  @builtin ~w(codex claudeAgent cursor grok opencode antigravity pi)

  @doc """
  How long an agent may take to make an image: 5 minutes. Tests shorten it with the
  `:image_generation_timeout` app env.
  """
  def timeout, do: Application.get_env(:hal_c2, :image_generation_timeout, 300_000)

  @doc """
  `space.image.providers`: each provider with whether it can make an image here, and the
  selection used when the user does not choose.
  """
  def providers do
    settings = HalC2.Settings.settings()

    %{
      "providers" => Enum.map(instances(settings), &provider(settings, &1)),
      "selection" => default(settings)
    }
  end

  defp instances(settings),
    do: Enum.uniq(@builtin ++ Map.keys(settings["providerInstances"] || %{}))

  defp provider(settings, id) do
    driver = TextGeneration.driver(id)

    {status, message} =
      cond do
        driver not in @supported -> {"unsupported", unsupported(id)}
        TextGeneration.usable?(settings, %{"instanceId" => id}) -> {"ready", nil}
        true -> {"unavailable", unavailable(id)}
      end

    %{"instanceId" => id, "driver" => driver, "status" => status, "message" => message}
  end

  defp unsupported(id), do: "#{id} does not generate images here."
  defp unavailable(id), do: "#{id} is not enabled or not installed."

  # The model chosen for writing text when it can make images, else the first that can.
  defp default(settings) do
    text = settings["textGenerationModelSelection"]

    if is_map(text) and TextGeneration.driver(text) in @supported and
         TextGeneration.usable?(settings, text) do
      selection(text)
    else
      Enum.find_value(@supported, fn driver ->
        selection = %{"instanceId" => driver, "model" => TextGeneration.default_model(driver)}
        if TextGeneration.usable?(settings, selection), do: selection
      end)
    end
  end

  defp selection(selection), do: Map.take(selection, ~w(instanceId model))

  @doc """
  Runs the agent and leaves its image as a pending upload for
  `HalC2.Space.add_image/5`: `{:ok, attachment_id, selection used}`, or `{:error, reason,
  message}` with reason `:unsupported`, `:unavailable` or `:failed`.
  """
  def generate(prompt, selection) do
    with {:ok, selection} <- choose(selection),
         selection = with_model(selection) do
      dir = Path.join(System.tmp_dir!(), "hal-c2-image-#{HalC2.Environment.uuid4()}")
      File.mkdir_p!(dir)

      try do
        with {:ok, _} <- run(selection, dir, instruction(prompt)),
             {:ok, file} <- newest_image(dir),
             {:ok, upload} <- pending(file) do
          {:ok, upload, selection(selection)}
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

    cond do
      TextGeneration.driver(id) not in @supported -> {:error, :unsupported, unsupported(id)}
      TextGeneration.usable?(settings, selection) -> {:ok, selection}
      true -> {:error, :unavailable, unavailable(id)}
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

  defp with_model(%{"model" => model} = selection) when is_binary(model) and model != "",
    do: selection

  defp with_model(selection) do
    model = TextGeneration.default_model(TextGeneration.driver(selection))
    Map.put(selection, "model", model)
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
            ["--model", selection["model"], "--config", ~s(model_reasoning_effort="low"), "-"]

        TextGeneration.run_cli([TextGeneration.codex_command(id) | args], dir, instruction,
          timeout: timeout()
        )

      "grok" ->
        with {:ok, [command | _], env} <- HalC2.Acp.command(id) do
          args = ["-p", instruction, "--cwd", dir, "-m", selection["model"], "--yolo"]
          TextGeneration.run_cli([command | args], dir, "", timeout: timeout(), env: env)
        end
    end
  end

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
