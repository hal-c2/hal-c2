defmodule HalC2.TextGeneration do
  @moduledoc """
  Short structured text from a coding agent: commit messages and pull request
  content for `HalC2.GitActions`, branch names for `HalC2.WorktreeSetup`, and thread
  titles for `HalC2.Orchestration`, and pages from threads for `HalC2.Space`. The
  prompts live in `HalC2.TextGeneration.Prompts`.

  Commits, pull requests, and branch names are written by the project's source
  control writer model when its provider is usable, otherwise by its text
  generation model, which also writes titles (`model_selection/2`). A selection
  whose provider is disabled, not installed, signed out, failed its last check,
  or has no runner here falls back to the first usable provider, with that
  provider's default model; a provider still being checked keeps its selection.

  Claude runs `claude -p` with a JSON schema and no tools; Codex runs `codex exec`
  in a read-only sandbox; Grok, OpenCode, Cursor, and Antigravity answer one ACP
  prompt in an empty directory, with every tool and permission request refused
  (Antigravity fails outright on one); Pi answers one prompt in an ephemeral
  `pi --mode rpc --no-session` without extensions or tools.
  """

  require Logger

  alias HalC2.Acp.Antigravity
  alias HalC2.Acp.Antigravity.Session, as: AntigravitySession
  alias HalC2.JsonRpc.Connection
  alias HalC2.TextGeneration.Prompts

  # Text generation defaults: the selection, and each provider's model.
  @default_selection %{
    "instanceId" => "codex",
    "model" => "gpt-6-luna",
    "options" => [%{"id" => "reasoningEffort", "value" => "low"}]
  }
  @default_models %{
    "codex" => "gpt-6-luna",
    # Upstream #18781: Claude's default writer moved from Haiku 4.5 to Haiku 5.5;
    # a model the user saved is kept (it only names the fallback's model).
    "claudeAgent" => "claude-haiku-5-5",
    "cursor" => "composer-2",
    "grok" => "grok-build",
    # Upstream #22442: many OpenCode users have no access to "openai/gpt-5".
    "opencode" => "opencode/big-pickle",
    # Pi's and Antigravity's own default model.
    "pi" => "default",
    "antigravity" => "antigravity-default"
  }
  # The order text generation falls back through when the selected provider cannot be used.
  @fallback_order ~w(codex claudeAgent cursor grok pi opencode antigravity)
  @acp_drivers ~w(grok opencode cursor antigravity)
  # What Antigravity may answer before text generation is refused, in characters.
  @antigravity_max_output 128_000

  @doc """
  How long a writing agent may take before it is stopped: 3 minutes.
  Tests shorten it with the `:text_generation_timeout` app env.
  """
  def timeout, do: Application.get_env(:hal_c2, :text_generation_timeout, 180_000)

  @doc """
  A commit message for the staged changes: `%{"subject", "body"}`, and a
  branch name (under the namespace the writer chose, else `feature/`) when asked for. Options: `:policy` (`HalC2.TextGeneration.Style`).
  """
  def commit_message(
        cwd,
        branch,
        staged_summary,
        staged_patch,
        include_branch \\ false,
        opts \\ []
      ) do
    prompt =
      Prompts.commit(branch, staged_summary, staged_patch, include_branch, opts[:policy] || %{})

    keys = if include_branch, do: ~w(subject body branch), else: ~w(subject body)

    with {:ok, out} <-
           generate(cwd, :writer, prompt, Map.new(keys, &{&1, :string}),
             operation: "a commit message"
           ) do
      result = %{"subject" => commit_subject(out["subject"]), "body" => String.trim(out["body"])}

      {:ok,
       if(include_branch,
         do: Map.put(result, "branch", namespaced_branch(out["branch"])),
         else: result
       )}
    end
  end

  @doc """
  A pull request's `%{"title", "body"}` for a branch's commits and diff. Options:
  `:policy` and `:template`, the repository's pull request template.
  """
  def pr_content(cwd, base, head, commits, diff_stat, diff_patch, opts \\ []) do
    prompt =
      Prompts.pr(
        base,
        head,
        commits,
        diff_stat,
        diff_patch,
        opts[:template],
        opts[:policy] || %{}
      )

    with {:ok, out} <-
           generate(cwd, :writer, prompt, %{"title" => :string, "body" => :string},
             operation: "pull request content"
           ) do
      title =
        case out["title"] |> String.trim() |> String.split(~r/\r?\n/) |> hd() |> String.trim() do
          "" -> "Update project changes"
          title -> title
        end

      {:ok, %{"title" => title, "body" => String.trim(out["body"])}}
    end
  end

  @doc "A short branch name fragment for the work a message asks for: `%{\"branch\"}`."
  def branch_name(cwd, message, attachments \\ []) do
    prompt = Prompts.branch(message, attachments)

    with {:ok, out} <-
           generate(cwd, :writer, prompt, %{"branch" => :string}, images: images(attachments)),
         do: {:ok, %{"branch" => branch_fragment(out["branch"])}}
  end

  @doc """
  A thread title: `%{"title", "needsRefinement"}`. From the first message, or,
  with `:previous_title`, from the thread's contents (`Prompts.thread_context/1`).
  Options: `:previous_title`, `:attachments`. GitHub pull requests and issues
  linked in the message are looked up for the model.
  """
  def thread_title(cwd, message, opts \\ []) do
    attachments = opts[:attachments] || []
    schema = %{"title" => :string, "needsRefinement" => :boolean}

    with {:ok, selection} <- usable_selection(cwd, :text),
         linked = linked_context(cwd, message),
         prompt =
           Prompts.thread_title(
             message,
             opts[:previous_title],
             linked,
             attachments,
             settings(cwd)["threadTitleInstructions"]
           ),
         # Titles need only the prompt, not the checkout's configuration.
         {:ok, out} <-
           run(selection, cwd, prompt, schema,
             isolate: true,
             images: images(attachments),
             attachments: attachments,
             operation: "a thread title"
           ) do
      {:ok,
       %{"title" => title(out["title"]), "needsRefinement" => out["needsRefinement"] == true}}
    end
  end

  @doc """
  A Space page summarising a thread from its context (`Prompts.thread_context/1`),
  written in the thread's checkout: `%{"title", "markdown"}`. `{:error,
  {:unavailable, message}}` when no provider can write it.
  """
  def page_from_thread(cwd, context) do
    case usable_selection(cwd, :text) do
      {:ok, selection} ->
        run(
          selection,
          cwd,
          Prompts.page_from_thread(context),
          %{"title" => :string, "markdown" => :string},
          []
        )

      {:error, message} ->
        {:error, {:unavailable, message}}
    end
  end

  @doc """
  What a run of a page's update writes into the page (`HalC2.Space.Schedule`), from
  the global settings and in no checkout: `%{"markdown"}`. `{:error, {:unavailable,
  message}}` when no provider can write it.
  """
  def page_update(title, instruction, page, threads) do
    case usable_selection(nil, :text) do
      {:ok, selection} ->
        prompt = Prompts.page_update(title, instruction, page, threads)
        schema = %{"markdown" => :string}
        in_dir(nil, &run(selection, &1, prompt, schema, isolate: true))

      {:error, message} ->
        {:error, {:unavailable, message}}
    end
  end

  @doc """
  How to draw a chart for `request`, given the page's text and the counts on offer
  (`HalC2.Space.Visualize`): `%{"source", "type", "title", "chart"}`, as strings. Asked
  in an empty directory, with the global text model, so all it reads is the prompt.
  """
  def chart(request, page_text, datasets) do
    in_dir(nil, fn dir ->
      case usable_selection(dir, :text) do
        {:ok, selection} ->
          run(
            selection,
            dir,
            Prompts.chart(request, page_text, datasets),
            %{"source" => :string, "type" => :string, "title" => :string, "chart" => :string},
            isolate: true
          )

        {:error, message} ->
          {:error, {:unavailable, message}}
      end
    end)
  end

  @doc """
  What a plugin asks the user's text model (`HalC2.Plugins.Host.generate/3`): an object
  with `schema`'s keys, written from the global settings in an empty directory, and
  what writing it used: `{:ok, out, %{"instanceId", "model", "inputTokens",
  "cachedInputTokens", "outputTokens", "costUsd", "estimated"}}`. A provider that
  reports nothing is estimated at four characters a token, with no cost.
  """
  def for_plugin(prompt, schema) do
    in_dir(nil, fn dir ->
      case usable_selection(dir, :text) do
        {:ok, selection} ->
          with {:ok, out, reported} <-
                 measured_run(selection, dir, prompt, schema, isolate: true, operation: "text") do
            {:ok, out, usage(selection, prompt, out, reported)}
          end

        {:error, message} ->
          {:error, {:unavailable, message}}
      end
    end)
  end

  @doc false
  def usage(selection, prompt, out, reported) do
    base = %{"instanceId" => selection["instanceId"], "model" => selection["model"]}

    case reported do
      %{} ->
        Map.merge(base, Map.put(reported, "estimated", false))

      nil ->
        Map.merge(base, %{
          "inputTokens" => div(String.length(prompt) + 3, 4),
          "cachedInputTokens" => 0,
          "outputTokens" => div(String.length(JSON.encode!(out)) + 3, 4),
          "costUsd" => nil,
          "estimated" => true
        })
    end
  end

  # --- model selection ---------------------------------------------------------------

  @doc "The settings that apply to `cwd`: its project's, when it is in one."
  def settings(cwd), do: HalC2.Settings.for_project(HalC2.Projects.at(cwd))

  @doc """
  The model that writes for `cwd`: `:writer` for commits, pull requests, and
  branch names (the source control writer when its provider is usable), `:text`
  for titles. Falls back as the moduledoc says.
  """
  def model_selection(cwd, kind) do
    settings = settings(cwd)
    text = settings["textGenerationModelSelection"] || @default_selection
    writer = settings["sourceControlWriterModelSelection"]

    cond do
      kind == :writer and is_map(writer) and usable?(settings, writer) -> writer
      usable?(settings, text) -> text
      true -> fallback(settings) || text
    end
  end

  defp fallback(settings) do
    Enum.find_value(@fallback_order, fn driver ->
      selection = %{"instanceId" => driver, "model" => @default_models[driver]}
      if usable?(settings, selection), do: selection
    end)
  end

  @doc "The provider driver of a model selection or an instance id."
  def driver(%{"instanceId" => id}), do: driver(id)

  def driver(id),
    do: get_in(HalC2.Settings.settings(), ["providerInstances", id, "driver"]) || id

  @doc "A provider's default model for writing text."
  def default_model(driver), do: @default_models[driver]

  @doc "Whether a selection's provider is enabled and installed under `settings`."
  def usable?(settings, %{"instanceId" => id}) when is_binary(id) do
    case driver(id) do
      "codex" ->
        enabled?(settings, id) and executable?(codex_command(id)) and healthy?(id, "codex")

      "claudeAgent" ->
        enabled?(settings, id) and executable?(claude_command(id)) and
          healthy?(id, "claudeAgent")

      "pi" ->
        acp_on?(settings, id) and executable?(HalC2.Acp.binary_path(id) || "pi")

      driver when driver in @acp_drivers ->
        acp_on?(settings, id) and acp_installed?(id) and healthy?(id, driver)

      # A text-generation backend plugin (`HalC2.Plugins.TextGeneration`) by its id.
      _ ->
        HalC2.Plugins.text_backend?(id)
    end
  end

  def usable?(_settings, _selection), do: false

  # What the provider's last check found, read without starting a new one
  # (upstream #29607): a check that failed, or an account a probe found signed
  # out, cannot write; a provider still being checked keeps its selection, so
  # titles at startup are not handed to another provider on a guess.
  defp healthy?(id, "codex") do
    HalC2.Codex.Provider.check_state(id) != :failed and
      HalC2.ProviderUsageLimits.account_status(id) != "unauthenticated"
  end

  defp healthy?(id, "claudeAgent") do
    HalC2.Claude.Provider.health_state(id) != :failed and
      HalC2.ProviderUsageLimits.account_status(id) != "unauthenticated"
  end

  defp healthy?(id, driver) when driver in @acp_drivers,
    do: not HalC2.Acp.unauthenticated?(id)

  defp healthy?(_id, _driver), do: true

  # Codex and Claude are on unless turned off.
  defp enabled?(settings, id), do: HalC2.Settings.provider_on?(settings, nil, id)

  # An ACP agent is off until turned on (`HalC2.Acp.enabled?/1`); a project's own
  # switch, which `settings` carries where it differs from the environment's, wins.
  defp acp_on?(settings, id) do
    on = HalC2.Settings.switch(settings, id)

    if is_boolean(on) and on != HalC2.Settings.switch(HalC2.Settings.settings(), id),
      do: on,
      else: HalC2.Acp.enabled?(id)
  end

  defp acp_installed?(id) do
    case HalC2.Acp.command(id) do
      {:ok, [executable | _], _env} -> executable?(executable)
      _ -> false
    end
  end

  defp executable?(command), do: System.find_executable(command) != nil

  defp usable_selection(cwd, kind) do
    selection = model_selection(cwd, kind)
    settings = settings(cwd)

    cond do
      usable?(settings, selection) ->
        {:ok, selection}

      message = missing_cli(settings, selection) ->
        {:error, message}

      true ->
        {:error,
         "No text generation provider is available. Install Claude Code or Codex, or enable another provider."}
    end
  end

  # Why the provider the user chose for text cannot write, when nothing else can:
  # its CLI is not on PATH, or Cursor is signed out.
  defp missing_cli(settings, %{"instanceId" => id}) do
    chosen = settings["textGenerationModelSelection"]

    if match?(%{"instanceId" => ^id}, chosen) do
      case driver(id) do
        "codex" ->
          enabled?(settings, id) && missing_cli_message("Codex", codex_command(id))

        "claudeAgent" ->
          enabled?(settings, id) && missing_cli_message("Claude", claude_command(id))

        "cursor" ->
          acp_on?(settings, id) && acp_installed?(id) && signed_out_cursor(id)

        _ ->
          nil
      end
    end
  end

  defp missing_cli(_settings, _selection), do: nil

  # Cursor is not asked to write without a sign-in or key.
  defp signed_out_cursor(id) do
    if HalC2.Acp.unauthenticated?(id),
      do:
        "Cursor is not signed in. Sign in with Cursor or add CURSOR_API_KEY in provider settings."
  end

  defp missing_cli_message(label, command) do
    unless executable?(command),
      do: "#{label} CLI (`#{command}`) is required but not available on PATH."
  end

  # --- running ----------------------------------------------------------------------

  defp generate(cwd, kind, prompt, schema, opts) do
    with {:ok, selection} <- usable_selection(cwd, kind),
         do: run(selection, cwd, prompt, schema, opts)
  end

  defp run(selection, cwd, prompt, schema, opts) do
    with {:ok, out, _reported} <- measured_run(selection, cwd, prompt, schema, opts),
         do: {:ok, out}
  end

  # `run/5`, and what the provider reported it used, or nil when it reports nothing.
  defp measured_run(selection, cwd, prompt, schema, opts) do
    json_schema = %{
      "type" => "object",
      "properties" => Map.new(schema, fn {key, type} -> {key, %{"type" => to_string(type)}} end),
      "required" => Map.keys(schema),
      "additionalProperties" => false
    }

    {label, result} =
      case driver(selection) do
        "claudeAgent" ->
          {"Claude", claude(cwd, prompt, json_schema, selection, opts)}

        "codex" ->
          {"Codex", codex(cwd, prompt, json_schema, selection, opts)}

        "pi" ->
          {"Pi", pi(selection, if(opts[:isolate], do: nil, else: cwd), prompt)}

        driver when driver in @acp_drivers ->
          label = HalC2.Acp.label(selection["instanceId"])

          {label,
           acp(
             selection,
             prompt,
             label,
             if(driver(selection) == "opencode", do: opts[:attachments] || [], else: [])
           )}

        plugin ->
          {plugin, HalC2.Plugins.generate(plugin, prompt, json_schema)}
      end

    {result, reported} =
      case result do
        {:ok, out, reported} -> {{:ok, out}, reported}
        other -> {other, nil}
      end

    with {:ok, out} <- result do
      if valid?(out, schema),
        do: {:ok, out, reported},
        else: {:error, "#{label} returned invalid structured output."}
    end
  end

  defp valid?(%{} = out, schema) do
    Enum.all?(schema, fn
      {key, :string} -> is_binary(out[key])
      {key, :boolean} -> out[key] in [true, false, nil]
    end)
  end

  defp valid?(_out, _schema), do: false

  defp option(selection, id) do
    Enum.find_value(selection["options"] || [], fn
      %{"id" => ^id, "value" => value} -> value
      _ -> nil
    end)
  end

  defp claude(cwd, prompt, schema, selection, opts) do
    isolate = opts[:isolate]
    thinking = option(selection, "thinking")

    settings =
      %{"disableAllHooks" => true}
      |> then(
        &if(is_boolean(thinking), do: Map.put(&1, "alwaysThinkingEnabled", thinking), else: &1)
      )
      |> then(
        &if(option(selection, "fastMode") == true, do: Map.put(&1, "fastMode", true), else: &1)
      )

    effort = option(selection, "effort")

    args =
      ~w(-p --output-format json --json-schema) ++
        [JSON.encode!(schema), "--model", selection["model"] || @default_models["claudeAgent"]] ++
        if(is_binary(effort), do: ["--effort", effort], else: []) ++
        ["--settings", JSON.encode!(settings), "--tools", ""] ++
        ["--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk"]

    # The instance's own env and config folder, as its sessions get them.
    instance = selection["instanceId"] || "claudeAgent"

    env =
      (Enum.to_list(HalC2.Settings.instance_env(instance)) ++
         case HalC2.Claude.Provider.home_path(instance) do
           nil -> []
           home -> [{"CLAUDE_CONFIG_DIR", HalC2.Claude.Provider.expand_home(home)}]
         end)
      |> then(&HalC2.Claude.Provider.spawn_env(instance, &1))

    command =
      HalC2.Claude.Provider.scrubbed_command(
        [claude_command(selection["instanceId"]) | args],
        instance
      )

    in_dir(if(isolate, do: nil, else: cwd), fn dir ->
      cli = [label: "Claude", unexpected: unexpected(opts), env: env]

      case exec_cli(command, dir, prompt, cli) do
        {:ok, out} ->
          with {:ok, decoded} <- JSON.decode(out),
               %{} = result <- structured(decoded) do
            {:ok, result, claude_usage(final_result(decoded))}
          else
            _ -> {:error, claude_reported(out) || "Claude returned invalid structured output."}
          end

        {:failed, out, message} ->
          {:error, claude_reported(out) || message}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # `--output-format json` is one result object, or a list of messages ending in one.
  defp structured(%{"structured_output" => %{} = out}), do: out

  # Only the final result counts: an earlier one that had an answer does not stand in.
  defp structured(list) when is_list(list) do
    case list |> Enum.reverse() |> Enum.find(&match?(%{"type" => "result"}, &1)) do
      nil -> nil
      result -> structured(result)
    end
  end

  defp structured(_), do: nil

  # What Claude itself reported when its final result is an error: the result text,
  # or the strings of its error list (upstream #30331), never the JSON or the
  # diagnostic entries. A wrapper's notice on stderr is not it.
  defp claude_reported(out) do
    with {:ok, decoded} <- JSON.decode(out),
         %{"is_error" => true} = result <- final_result(decoded) do
      case result do
        %{"result" => text} when is_binary(text) and text != "" ->
          String.trim(text)

        %{"errors" => [_ | _] = errors} ->
          case for(error <- errors, is_binary(error) and error != "", do: String.trim(error)) do
            [] -> nil
            lines -> Enum.join(lines, "\n")
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  # What the final result says the call used, as `for_plugin/2` reports it.
  defp claude_usage(%{"usage" => %{} = usage} = result) do
    %{
      "inputTokens" =>
        (usage["input_tokens"] || 0) + (usage["cache_creation_input_tokens"] || 0) +
          (usage["cache_read_input_tokens"] || 0),
      "cachedInputTokens" => usage["cache_read_input_tokens"] || 0,
      "outputTokens" => usage["output_tokens"] || 0,
      "costUsd" => result["total_cost_usd"]
    }
  end

  defp claude_usage(_result), do: nil

  defp final_result(list) when is_list(list),
    do: list |> Enum.reverse() |> Enum.find(&match?(%{"type" => "result"}, &1))

  defp final_result(%{} = result), do: result
  defp final_result(_), do: nil

  # What a failure that is not the CLI's own output says: the operation, no details.
  defp unexpected(opts), do: "Failed to generate #{opts[:operation] || "text"}"

  defp codex(cwd, prompt, schema, selection, opts) do
    images = opts[:images] || []

    {model, fallback?} =
      codex_model(
        selection["instanceId"] || "codex",
        selection["model"] || @default_models["codex"]
      )

    # A model swapped in because the account did not list the default runs with
    # that model's own defaults, not options chosen for another one.
    effort = if(fallback?, do: nil, else: option(selection, "reasoningEffort") || "low")

    tier =
      if(fallback?,
        do: nil,
        else:
          option(selection, "serviceTier") ||
            if(option(selection, "fastMode") == true, do: "fast")
      )

    in_dir(nil, fn dir ->
      schema_path = Path.join(dir, "schema.json")
      output_path = Path.join(dir, "output.json")
      File.write!(schema_path, JSON.encode!(schema))

      # The instance's config overrides apply to the Codex that writes text too.
      launch =
        case HalC2.Codex.Provider.launch_args(selection["instanceId"]) do
          {:ok, args} -> HalC2.Codex.Provider.exec_args(args)
          {:error, _} -> []
        end

      args =
        ["exec"] ++
          launch ++
          ~w(--ephemeral --skip-git-repo-check -s read-only) ++
          ["--model", model] ++
          if(is_binary(effort),
            do: ["--config", ~s(model_reasoning_effort="#{effort}")],
            else: []
          ) ++
          if(is_binary(tier), do: ["--config", ~s(service_tier="#{tier}")], else: []) ++
          ["--output-schema", schema_path, "--output-last-message", output_path] ++
          Enum.flat_map(images, &["--image", &1]) ++ ["-"]

      cli = [label: "Codex", unexpected: unexpected(opts)]

      with {:ok, _} <- run_cli([codex_command(selection["instanceId"]) | args], cwd, prompt, cli),
           {:ok, text} <- File.read(output_path),
           {:ok, %{} = result} <- JSON.decode(text) do
        {:ok, result}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        _ -> {:error, "Codex returned invalid structured output."}
      end
    end)
  end

  # The model Codex is run with, resolved against the list its last check read
  # (nil when none was read: the name stands). A listed name stands; a family
  # name takes the family's first listed model; the built-in default an account
  # does not list takes the account's default, or else its first model, and says
  # so (`true`) so the caller drops options chosen for the default. Any other
  # name is a model the user typed and goes as written.
  defp codex_model(instance, model) do
    model = HalC2.Codex.Provider.current_slug(model)

    case HalC2.Codex.Provider.listed_models(instance) do
      [_ | _] = listed ->
        slugs = Enum.map(listed, & &1["slug"])

        cond do
          model in slugs ->
            {model, false}

          family = Enum.find(slugs, &String.starts_with?(&1, model <> "-")) ->
            {family, false}

          model == @default_models["codex"] ->
            default = Enum.find(listed, & &1["isDefault"]) || hd(listed)
            {default["slug"], true}

          true ->
            {model, false}
        end

      _ ->
        {model, false}
    end
  end

  # Runs `fun` in `dir`, or in a new temporary directory it removes afterwards.
  defp in_dir(dir, fun) when is_binary(dir), do: fun.(dir)

  defp in_dir(nil, fun) do
    dir = HalC2.Scratch.dir("hal-c2-text")

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  # The images a Codex prompt takes by path.
  defp images(attachments) do
    for %{"type" => "image", "id" => id} = attachment <- attachments,
        is_binary(id),
        path = HalC2.Attachments.path(attachment),
        is_binary(path) and File.regular?(path),
        do: path
  end

  # One ACP prompt in its own process, which outlives neither the agent nor the timeout.
  defp acp(selection, prompt, label, attachments) do
    id = selection["instanceId"]
    antigravity = driver(id) == "antigravity"
    cursor = driver(id) == "cursor"

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        # Who asked for the text: only its exit is a cancellation. The task
        # is also linked to the agent connection and to the prompt task, and
        # their exits are failures to report, not the user cancelling.
        caller = List.first(Process.get(:"$callers") || [])

        try do
          in_dir(nil, fn dir ->
            cond do
              driver(id) == "cursor" and
                  File.exists?(Path.join(HalC2.Paths.user_home(), ".cursor/sandbox.json")) ->
                # Cursor's own sandbox settings could widen what the agent may write.
                {:error,
                 "Cursor text generation cannot enforce workspace isolation with a custom ~/.cursor/sandbox.json. Use another text-generation provider."}

              antigravity ->
                antigravity(id, dir, selection["model"], prompt, caller)

              driver(id) == "opencode" and selection["model"] not in [nil, "", "default"] and
                  not provider_model?(selection["model"]) ->
                {:error,
                 "OpenCode model '#{selection["model"]}' must use the provider/model format."}

              true ->
                # Cursor plans read-only there, without the user's Cursor settings or tools.
                mode = if driver(id) == "cursor", do: "text-generation"

                HalC2.Acp.with_agent(
                  id,
                  dir,
                  fn conn, _init ->
                    acp_prompt(conn, dir, selection["model"], prompt, false, attachments, caller)
                  end,
                  mode
                )
            end
          end)
        catch
          _kind, reason -> {:error, reason}
        end
      end)

    case Task.yield(task, timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} ->
        case JSON.decode(json_object(text)) do
          {:ok, %{} = out} -> {:ok, out}
          _ -> {:error, "#{label} returned invalid structured output."}
        end

      # Cursor's run that ended badly gives nothing, whatever it printed first.
      {:ok, {:error, "The request was cancelled."}} when cursor ->
        {:error, "Cursor SDK request was cancelled."}

      # The user text stays generic; what Cursor said is only for the log.
      {:ok, {:error, %{} = reason}} when cursor ->
        Logger.warning("Cursor text generation ended with an error: #{inspect(reason)}")
        {:error, "Cursor SDK request finished with an error."}

      {:ok, {:error, reason}} when is_binary(reason) ->
        {:error, reason}

      {:ok, {:error, %{"message" => _} = error}} ->
        if driver(id) == "opencode",
          do: {:error, opencode_failure(error)},
          else: {:error, "#{label} request failed: #{error["message"]}"}

      {:ok, {:error, %{} = error}} ->
        if driver(id) == "opencode",
          do: {:error, opencode_failure(error)},
          else: {:error, "#{label} request failed: #{inspect(error)}"}

      {:ok, {:error, reason}} ->
        {:error, "#{label} request failed: #{inspect(reason)}"}

      nil when antigravity ->
        {:error, "Antigravity text generation timed out."}

      nil ->
        if driver(id) == "opencode",
          do: {:error, "OpenCode did not finish generating in time."},
          else: {:error, "#{label} request timed out."}
    end
  end

  # An OpenCode generation the model provider failed, in fixed plain words: the
  # provider's own text (sometimes only "<none>") never reaches the user.
  defp opencode_failure(error) do
    message = String.downcase(to_string(error["message"] || ""))
    data = if is_map(error["data"]), do: error["data"], else: %{}
    status = data["statusCode"] || data["status"]
    name = String.downcase(to_string(data["errorName"] || ""))

    cond do
      status in [401, 403] or name =~ "auth" or
          message =~ ~r/unauthor|invalid (api )?key|credential|sign[ -]?in|authentication/ ->
        "The model provider rejected the credentials. Check the provider's sign-in or API key in OpenCode."

      status == 429 or name =~ "rate" or name =~ "quota" or
          message =~ ~r/rate.?limit|too many requests|quota/ ->
        "The model provider's usage or rate limit was reached. Try again later."

      message =~ ~r/context|too long|too large/ ->
        "The prompt is too long for the selected model's context window."

      message =~ "abort" or name =~ "abort" ->
        "OpenCode stopped the generation."

      is_integer(status) ->
        "The model provider failed the request (HTTP #{status})."

      true ->
        "OpenCode could not generate the text."
    end
  end

  defp acp_prompt(conn, dir, model, prompt, antigravity, attachments, caller) do
    with {:ok, %{"sessionId" => session_id} = session} <-
           Connection.call(conn, "session/new", %{"cwd" => dir, "mcpServers" => []}, 60_000),
         :ok <- acp_mode(conn, session_id, antigravity),
         :ok <- acp_model(conn, session_id, session, model, antigravity) do
      blocks = [%{"type" => "text", "text" => prompt} | acp_images(attachments)]
      params = %{"sessionId" => session_id, "prompt" => blocks}
      task = Task.async(fn -> Connection.call(conn, "session/prompt", params, :infinity) end)
      result = acp_collect(conn, task.ref, [], antigravity, caller)
      delete_session(conn, session_id)
      result
    end
  end

  # Only the images that can be opened go with the prompt; any other attachment is
  # described in its text, never sent.
  @acp_image_types ~w(image/gif image/jpeg image/png image/webp)
  defp acp_images(attachments) do
    for %{"type" => "image", "mimeType" => mime} = attachment <- attachments,
        mime in @acp_image_types,
        {:ok, bytes} <- [HalC2.Attachments.read(attachment)],
        do: %{"type" => "image", "mimeType" => mime, "data" => Base.encode64(bytes)}
  end

  # A generation's throwaway session is deleted again, so titles and commit
  # messages leave nothing in the agent's session history. Best effort: an
  # agent without `session/delete` just says so.
  defp delete_session(conn, session_id) do
    Connection.call(conn, "session/delete", %{"sessionId" => session_id}, 2_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Antigravity runs in its default (asking) mode, never a thread's access mode.
  defp acp_mode(_conn, _session_id, false), do: :ok

  defp acp_mode(conn, session_id, true) do
    params = %{"sessionId" => session_id, "modeId" => "default"}

    case Connection.call(conn, "session/set_mode", params) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Picks the model when the agent offers it; an alias such as `grok-build` keeps the
  # session's. Antigravity refuses a model its account does not list.
  defp acp_model(conn, session_id, session, model, antigravity) do
    option = Enum.find(session["configOptions"] || [], &(&1["id"] == "model")) || %{}
    offered = for %{"value" => value} <- option["options"] || [], do: value

    cond do
      model in offered and model != option["currentValue"] ->
        params = %{"sessionId" => session_id, "configId" => "model", "value" => model}

        case Connection.call(conn, "session/set_config_option", params) do
          {:ok, _} -> :ok
          error -> error
        end

      antigravity and is_binary(model) and model not in ["", "default", "antigravity-default"] and
          model not in offered ->
        {:error,
         "Antigravity model '#{model}' is unavailable for this Google account. Select an available model."}

      true ->
        :ok
    end
  end

  # Other agents have their tool and permission requests refused and go on. Antigravity
  # fails at the first one, or at tool work it reports: its global hooks could act first.
  defp acp_collect(conn, ref, text, antigravity, caller) do
    receive do
      {:json_rpc, ^conn,
       {:notification, "session/update",
        %{
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => chunk}
          }
        }}} ->
        if antigravity and
             String.length(IO.iodata_to_binary([text, chunk])) > @antigravity_max_output,
           do: {:error, "Antigravity text generation exceeded the output limit."},
           else: acp_collect(conn, ref, [text, chunk], antigravity, caller)

      {:json_rpc, ^conn,
       {:notification, "session/update", %{"update" => %{"sessionUpdate" => update}}}}
      when antigravity and update in ["tool_call", "tool_call_update"] ->
        {:error, "Antigravity attempted tool work during text generation."}

      {:json_rpc, ^conn, {:request, id, "session/request_permission", _params}} ->
        Connection.respond(conn, id, {:ok, %{"outcome" => %{"outcome" => "cancelled"}}})

        if antigravity,
          do: {:error, "Antigravity text generation requested a tool permission or user input."},
          else: acp_collect(conn, ref, text, antigravity, caller)

      {:json_rpc, ^conn, {:request, id, method, _params}} ->
        Connection.respond(
          conn,
          id,
          {:error, %{"code" => -32601, "message" => "#{method} is disabled for text generation"}}
        )

        cond do
          not antigravity ->
            acp_collect(conn, ref, text, antigravity, caller)

          method == "elicitation/create" ->
            {:error, "Antigravity text generation requested user input."}

          true ->
            {:error, "Antigravity text generation requested a tool or user input."}
        end

      # The caller that asked for the text went away (the user cancelled):
      # the generation stops with it instead of running on unattended. Any
      # other linked exit (the connection, the prompt task) is not this:
      # the prompt's own answer, or its DOWN just below, reports it.
      {:EXIT, ^caller, _reason} ->
        {:error, "The request was cancelled."}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, reason}

      {^ref, reply} ->
        Process.demonitor(ref, [:flush])

        case {reply, text |> IO.iodata_to_binary() |> String.trim()} do
          {{:ok, %{"stopReason" => "cancelled"}}, _} when antigravity ->
            {:error, "Antigravity text generation was cancelled."}

          {{:ok, %{"stopReason" => "cancelled"}}, _} ->
            {:error, "The request was cancelled."}

          {{:ok, _}, ""} when antigravity ->
            {:error, "Antigravity returned empty text generation output."}

          {{:ok, _}, ""} ->
            {:error, "The agent returned empty output."}

          {{:ok, _}, output} ->
            {:ok, output}

          {error, _} ->
            error
        end

      _other ->
        acp_collect(conn, ref, text, antigravity, caller)
    end
  end

  # Antigravity signs in with the instance's own login, answers in an empty directory,
  # and leaves neither files there nor its session in the profile.
  defp antigravity(id, dir, model, prompt, caller) do
    if antigravity_available?(Antigravity.profile(id)) do
      prompt =
        "Use only the input below. Do not use tools, read or write files, run commands, or ask questions.\n" <>
          "Return only the requested JSON object.\n\n" <> prompt

      result =
        HalC2.Acp.with_agent(id, dir, fn conn, _init ->
          with :ok <- AntigravitySession.authenticate(conn, id),
               do: acp_prompt(conn, dir, model, prompt, true, [], caller)
        end)

      remove_antigravity_session(id, dir)

      if antigravity_left_nothing?(dir),
        do: result,
        else: {:error, "Antigravity wrote files during text generation."}
    else
      {:error,
       "Antigravity text generation is unavailable for profiles with global hooks or MCP configuration. Select another system model."}
    end
  end

  # The empty skill folders Antigravity makes when its session starts
  # (upstream #27191) are not files it wrote; anything else left behind is.
  @antigravity_start_dirs ~w(.agents .agents/skills .gemini .gemini/skills)

  defp antigravity_left_nothing?(dir), do: antigravity_clean?(dir, "")

  defp antigravity_clean?(dir, rel) do
    case File.ls(Path.join(dir, rel)) do
      {:ok, names} ->
        Enum.all?(names, fn name ->
          child = if rel == "", do: name, else: rel <> "/" <> name

          child in @antigravity_start_dirs and
            File.dir?(Path.join(dir, child)) and antigravity_clean?(dir, child)
        end)

      _ ->
        false
    end
  end

  @doc """
  Whether an Antigravity profile can write text. Its global hooks and MCP servers
  would run before a tool request could be refused, so a profile with any cannot.
  """
  def antigravity_available?(profile) do
    Enum.all?([{"hooks.json", "hooks"}, {"mcp_config.json", "mcpServers"}], fn {name, key} ->
      path = Path.join([profile, "config", name])

      case File.stat(path) do
        {:error, :enoent} ->
          true

        {:ok, %File.Stat{type: :regular, size: size}} when size <= 64_000 ->
          case JSON.decode(File.read!(path)) do
            {:ok, %{} = config} -> Map.get(config, key, config) == %{}
            _ -> false
          end

        _ ->
          false
      end
    end)
  end

  # The conversation files a text prompt's session left in the profile, known by the
  # unique directory it ran in.
  defp remove_antigravity_session(id, dir) do
    acp = Path.join(Antigravity.profile(id), "antigravity-acp")

    for meta <- Path.wildcard(Path.join([acp, "conversations", "*.meta"])),
        {:ok, body} <- [File.read(meta)],
        {:ok, %{"cwd" => ^dir}} <- [JSON.decode(body)] do
      base = String.replace_suffix(meta, ".meta", "")
      for suffix <- ~w(.db .db-wal .db-shm .db-journal .meta), do: File.rm(base <> suffix)
      File.rm_rf(Path.join([acp, "brain", Path.basename(base)]))
    end

    :ok
  end

  # One prompt to an ephemeral Pi without extensions or tools, in its own process.
  defp pi(selection, cwd, prompt) do
    id = selection["instanceId"]

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        try do
          in_dir(cwd, fn dir -> pi_prompt(id, dir, selection["model"], prompt) end)
        catch
          _kind, reason -> {:error, reason}
        end
      end)

    case Task.yield(task, timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} ->
        case JSON.decode(json_object(text)) do
          {:ok, %{} = out} -> {:ok, out}
          _ -> {:error, "Pi returned invalid structured output."}
        end

      {:ok, {:error, reason}} when is_binary(reason) ->
        {:error, reason}

      {:ok, {:error, _reason}} ->
        {:error, "Pi text generation failed."}

      nil ->
        {:error, "Pi request timed out."}
    end
  end

  defp pi_prompt(id, dir, model, prompt) do
    with {:ok, argv, env} <- HalC2.Pi.launch(id, bare: true, ephemeral: true),
         {:ok, conn} <-
           Connection.start_link(cmd: argv, handler: self(), cd: dir, env: env, dialect: :pi) do
      try do
        with :ok <- pi_model(conn, model),
             {:ok, _} <- Connection.call(conn, "prompt", %{"message" => prompt}, :infinity),
             :ok <- pi_settled(conn),
             {:ok, data} <- Connection.call(conn, "get_last_assistant_text", %{}, 60_000) do
          case String.trim((is_map(data) && is_binary(data["text"]) && data["text"]) || "") do
            "" -> {:error, "Pi returned empty output."}
            text -> {:ok, text}
          end
        end
      after
        Connection.stop(conn)
      end
    end
  end

  # Pi's own default model is kept; any other must be a `provider/model` slug, since
  # running the default instead would report success for a model nobody asked for.
  defp provider_model?(model) do
    match?([provider, id] when provider != "" and id != "", String.split(model, "/", parts: 2))
  end

  defp pi_model(_conn, model) when model in [nil, "", "default"], do: :ok

  defp pi_model(conn, model) do
    case String.split(model, "/", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        case Connection.call(conn, "set_model", %{"provider" => provider, "modelId" => model_id}) do
          {:ok, _} -> :ok
          error -> error
        end

      _ ->
        {:error, "Pi model '#{model}' must use provider/model format."}
    end
  end

  defp pi_settled(conn) do
    receive do
      {:json_rpc, ^conn, {:notification, "agent_settled", _event}} -> :ok
      {:EXIT, ^conn, reason} -> {:error, reason}
    end
  end

  # The first balanced `{…}` in an agent's reply, which may wrap it in prose or a fence.
  defp json_object(text) do
    case :binary.match(text, "{") do
      :nomatch -> text
      {start, _} -> scan(text, start, start, 0, false, false)
    end
  end

  defp scan(text, start, index, depth, in_string, escaping) when index < byte_size(text) do
    char = :binary.at(text, index)
    next = index + 1

    cond do
      in_string and escaping -> scan(text, start, next, depth, true, false)
      in_string and char == ?\\ -> scan(text, start, next, depth, true, true)
      in_string -> scan(text, start, next, depth, char != ?", false)
      char == ?" -> scan(text, start, next, depth, true, false)
      char == ?{ -> scan(text, start, next, depth + 1, false, false)
      char == ?} and depth == 1 -> binary_part(text, start, next - start)
      char == ?} -> scan(text, start, next, depth - 1, false, false)
      true -> scan(text, start, next, depth, false, false)
    end
  end

  defp scan(text, start, _index, _depth, _in_string, _escaping),
    do: binary_part(text, start, byte_size(text) - start)

  @doc """
  Runs a provider CLI in `cwd` with `input` on stdin: `{:ok, stdout}` or `{:error,
  message}`. Options: `:timeout` (default `timeout/0`), `:env`, `:label` (the CLI's
  name in a failure: "Claude CLI command failed: …") and `:unexpected` (what a
  failure that is not the CLI's own output says, instead of its details).
  """
  def run_cli(argv, cwd, input, opts \\ []) do
    case exec_cli(argv, cwd, input, opts) do
      {:failed, _out, message} -> {:error, message}
      other -> other
    end
  end

  # As `run_cli/4`, but a CLI that exited with a failure gives its stdout too:
  # `{:failed, stdout, message}`.
  defp exec_cli([command | args], cwd, input, opts) do
    task =
      Task.async(fn ->
        try do
          [command | args]
          |> Exile.stream(
            cd: cwd,
            input: if(input == "", do: [], else: [input]),
            stderr: :consume,
            ignore_epipe: true,
            env: opts[:env] || []
          )
          |> Enum.reduce({[], [], nil}, fn
            {:stdout, data}, {out, err, status} -> {[out, data], err, status}
            {:stderr, data}, {out, err, status} -> {out, [err, data], status}
            {:exit, status}, {out, err, _} -> {out, err, status}
          end)
        rescue
          error -> {:raised, error}
        end
      end)

    case Task.yield(task, opts[:timeout] || timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, _err, {:status, 0}}} ->
        {:ok, IO.iodata_to_binary(out)}

      {:ok, {out, err, status}} ->
        out = IO.iodata_to_binary(out)
        {:failed, out, failure_message(command, opts[:label], failure(err), status)}

      {:ok, {:raised, error}} ->
        # The user sees only the general failure; a bad binary path or a vanished
        # working folder is for the log.
        if opts[:unexpected],
          do: Logger.warning("#{command} could not run: #{Exception.message(error)}")

        {:error, opts[:unexpected] || Exception.message(error)}

      nil ->
        {:error, "#{opts[:label] || Path.basename(command)} timed out"}
    end
  end

  defp failure_message(command, nil, detail, status),
    do: "#{Path.basename(command)} failed (#{inspect(status)}): #{detail}"

  defp failure_message(_command, label, "", {:status, code}),
    do: "#{label} CLI command failed with code #{code}."

  defp failure_message(_command, label, detail, _status),
    do: "#{label} CLI command failed: #{detail}"

  # CLIs print a banner first and the reason last; keep the error lines when there are any.
  defp failure(err) do
    lines = err |> IO.iodata_to_binary() |> String.split("\n", trim: true)
    errors = Enum.filter(lines, &String.starts_with?(&1, "ERROR"))

    if(errors == [], do: lines, else: Enum.uniq(errors))
    |> Enum.join("\n")
    |> String.slice(-500, 500)
  end

  # The CLI an instance writes text with: its binary path in settings, else the one on PATH.
  defp claude_command(instance), do: cli(instance, :text_claude_command, "claude")
  @doc false
  def codex_command(instance), do: cli(instance, :text_codex_command, "codex")

  defp cli(instance, key, default),
    do:
      hd(HalC2.Settings.instance_command(instance, [Application.get_env(:hal_c2, key, default)]))

  # --- linked pull requests and issues -----------------------------------------------

  # What the first two GitHub pull request or issue links in a message are about:
  # each link with its title and body, or marked unavailable.
  defp linked_context(cwd, message) do
    links =
      Regex.scan(~r{https://[^\s<>"')\]`]+}, message)
      # Sentence punctuation and markdown emphasis after a link are not part of
      # it (upstream #29656): "…/pull/12: the tests fail", "**…/pull/12**".
      |> Enum.map(fn [url] -> URI.parse(String.replace(url, ~r/[.,;!?:*]+$/, "")) end)
      |> Enum.flat_map(fn uri ->
        with %URI{host: host, userinfo: nil, path: path} when is_binary(path) <- uri,
             {:ok, endpoint} <- link_endpoint(host, path) do
          [{URI.to_string(%{uri | query: nil, fragment: nil}), endpoint}]
        else
          _ -> []
        end
      end)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.take(2)

    subjects =
      links
      |> Task.async_stream(fn {url, endpoint} -> subject(cwd, url, endpoint) end,
        timeout: 3_000,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, subject} -> subject
        {:exit, {{url, _}, _}} -> "#{url}: unavailable"
      end)

    if subjects != [], do: Enum.join(subjects, "\n\n")
  end

  # What a link looks up: a GitHub pull request or issue, or a GitLab merge request or
  # issue (in a group of any depth). Only these two hosts: ambient credentials never go
  # to a host named in message text.
  defp link_endpoint("github.com", path) do
    case Regex.run(~r{^/([\w.-]+)/([\w.-]+)/(?:pull|issues)/([1-9]\d*)(?:/.*)?$}, path) do
      [_, owner, repo, number] -> {:ok, {:github, "repos/#{owner}/#{repo}/issues/#{number}"}}
      _ -> :error
    end
  end

  defp link_endpoint("gitlab.com", path) do
    case Regex.run(
           ~r{^/([\w.-]+(?:/[\w.-]+)+)/-/(merge_requests|issues)/([1-9]\d*)(?:/.*)?$},
           path
         ) do
      [_, project, kind, number] ->
        {:ok, {:gitlab, "projects/#{URI.encode_www_form(project)}/#{kind}/#{number}"}}

      _ ->
        :error
    end
  end

  defp link_endpoint(_host, _path), do: :error

  defp subject(cwd, url, {:gitlab, endpoint}) do
    with {:ok, out, _} <-
           HalC2.SourceControl.Cli.run("glab", ["api", "--hostname", "gitlab.com", endpoint],
             cd: cwd,
             timeout: 3_000
           ),
         {:ok, %{"title" => title} = subject} when is_binary(title) <- JSON.decode(out) do
      body = if is_binary(subject["description"]), do: subject["description"], else: ""
      subject_text(url, title, body)
    else
      _ -> "#{url}: unavailable"
    end
  end

  defp subject(cwd, url, {:github, endpoint}) do
    with {:ok, out} <-
           HalC2.GitHub.gh(
             cwd,
             ["api", "--hostname", "github.com", endpoint, "--jq", "{title, body}"]
           ),
         {:ok, %{"title" => title} = subject} when is_binary(title) <- JSON.decode(out) do
      body = if is_binary(subject["body"]), do: subject["body"], else: ""
      subject_text(url, title, body)
    else
      _ -> "#{url}: unavailable"
    end
  rescue
    _ -> "#{url}: unavailable"
  end

  defp subject_text(url, title, body),
    do:
      "#{url}\n" <>
        ~s({"title":#{JSON.encode!(String.slice(title, 0, 300))},"body":#{JSON.encode!(String.slice(body, 0, 1_200))}})

  # --- output ----------------------------------------------------------------------

  defp commit_subject(raw) do
    subject =
      raw
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> hd()
      |> String.trim()
      |> String.replace(~r/\.+$/, "")
      |> String.trim()

    if subject == "",
      do: "Update project files",
      else: subject |> String.slice(0, 72) |> String.trim_trailing()
  end

  @doc "A git branch name fragment from free text (`update` when nothing is left)."
  def branch_fragment(raw) do
    raw
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['"`]/, "")
    |> String.replace(~r{^[./\s_-]+|[./\s_-]+$}, "")
    |> String.replace(~r{[^a-z0-9/_-]+}, "-")
    |> String.replace(~r{/+}, "/")
    |> String.replace(~r/-+/, "-")
    |> String.replace(~r{^[./_-]+|[./_-]+$}, "")
    |> String.slice(0, 64)
    |> String.replace(~r{[./_-]+$}, "")
    |> then(&if(&1 == "", do: "update", else: &1))
  end

  # Namespaces a writer may choose; any other leading word is part of the name.
  @branch_namespaces ~w(feat feature fix bugfix hotfix chore docs refactor test perf ci build style release)

  @doc """
  A branch name under the namespace the writer chose (`fix/…`) when it is one of
  `@branch_namespaces`; any other name goes under `feature/`, its slashes flattened
  (`add login/logout page` is `feature/add-login-logout-page`).
  """
  def namespaced_branch(raw) do
    {namespace, rest} =
      case String.split(branch_fragment(raw), "/", parts: 2) do
        [namespace, rest] when namespace in @branch_namespaces -> {namespace, rest}
        [fragment] -> {"feature", fragment}
        [first, rest] -> {"feature", first <> "/" <> rest}
      end

    namespace <> "/" <> (rest |> String.replace("/", "-") |> String.replace(~r/-+/, "-"))
  end

  # Prompts ask for under 40 characters; 120 only stops a runaway model.
  defp title(raw) do
    title =
      case JSON.decode(raw) do
        {:ok, %{"title" => title}} when is_binary(title) -> title
        _ -> raw
      end

    normalized =
      title
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> hd()
      |> String.trim()
      |> String.replace(~r/^['"`]+|['"`]+$/, "")
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    cond do
      normalized == "" -> "New thread"
      String.length(normalized) <= 120 -> normalized
      true -> (normalized |> String.slice(0, 117) |> String.trim_trailing()) <> "..."
    end
  end
end
