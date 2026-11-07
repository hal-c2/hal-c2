defmodule HalC2.Steps.Orchestration.TextGeneration do
  @moduledoc """
  Steps for `features/mc/orchestration/text-generation.feature`. The engine's
  writers (`HalC2.TextGeneration`) run against fakes: `fake_text_cli.py` as the
  `claude` and `codex` CLIs, `fake_acp.py --instance <id>` as the ACP agents, and
  `fake_gh.py` for linked GitHub items. Each fake logs its calls, which is how a
  step tells who wrote and what they were given.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Acp.Antigravity
  alias HalC2.Test.FakeAcp
  alias HalC2.TextGeneration
  alias HalC2.TextGeneration.Style
  alias HalC2.Test.Mc.World

  @fake_acp Path.expand("../../support/fake_acp.py", __DIR__)
  @fake_gh Path.expand("../../support/fake_gh.py", __DIR__)
  @clis %{"codex" => :codex, "claudeAgent" => :claude}
  @acp ~w(cursor grok opencode)
  @defaults %{
    "codex" => "gpt-6-luna",
    "claudeAgent" => "claude-haiku-4-5",
    "cursor" => "composer-2",
    "grok" => "grok-build",
    "opencode" => "openai/gpt-5"
  }

  # --- model choices -------------------------------------------------------------------

  step "the text generation model is {string} on {string}",
       %{args: [model, provider]} = context do
    context
    |> install()
    |> World.update_settings(%{"textGenerationModelSelection" => selection(provider, model)})
  end

  step "no text generation model is chosen", context do
    context = install(context)
    refute HalC2.Settings.settings()["textGenerationModelSelection"]
    context
  end

  step "the source control writer is {string} and the text model is {string}",
       %{args: [writer, text]} = context do
    context
    |> install()
    |> World.update_settings(%{
      "sourceControlWriterModelSelection" => selection(writer),
      "textGenerationModelSelection" => selection(text)
    })
  end

  step "the source control writer is a disabled provider and the text model is {string}",
       %{args: [text]} = context do
    context
    |> install()
    |> World.update_settings(%{
      "providers" => %{"claudeAgent" => %{"enabled" => false}},
      "sourceControlWriterModelSelection" => selection("claudeAgent"),
      "textGenerationModelSelection" => selection(text)
    })
  end

  step "the environment's source control writer is {string}", %{args: [writer]} = context do
    context
    |> install()
    |> World.update_settings(%{"sourceControlWriterModelSelection" => selection(writer)})
  end

  step "project {string} overrides the source control writer with {string}",
       %{args: [project, writer]} = context do
    World.update_settings(context, %{
      "projectSettingsOverrides" => %{
        World.project(context, project).id => %{
          "sourceControlWriterModelSelection" => selection(writer)
        }
      }
    })
  end

  step "the text model's provider cannot be used and only {string} is installed and enabled",
       %{args: [provider]} = context do
    # The chosen model is on a provider that is not installed here.
    unusable = if provider == "codex", do: "claudeAgent", else: "codex"

    context
    |> install([provider])
    |> World.update_settings(%{"textGenerationModelSelection" => selection(unusable, "chosen")})
  end

  # Pi and Antigravity instances, as plugin providers configure them.
  step "the text model is on a {string} instance", %{args: [driver]} = context do
    plugin_text_model(context, driver)
  end

  step "the text model is on an {string} instance", %{args: [driver]} = context do
    plugin_text_model(context, driver)
  end

  step "no provider that can write text is installed and enabled", context do
    install(context, [])
  end

  # --- generating ----------------------------------------------------------------------

  step "a title is generated for {string}", %{args: [message]} = context do
    title(context, message)
  end

  step "a title is generated", context do
    title(context, "Fix the login redirect loop")
  end

  step "titles are written by {string} on {string} with low reasoning effort",
       %{args: [model, provider]} = context do
    context = title(context, "Fix the login redirect loop")
    assert {:ok, _} = context.reply
    assert [call] = calls(context)
    assert writer(call) == provider
    assert after_flag(call, "--model") == model
    assert ~s(model_reasoning_effort="low") in call["argv"]
    context
  end

  step "a branch name is generated", context do
    context = install(context)
    reply(context, TextGeneration.branch_name(root(context), "Add a login page"))
  end

  step "a commit message is generated for {string}", %{args: [project]} = context do
    commit(context, World.project(context, project).root)
  end

  step "a pull request title and body is generated", context do
    pull_request(context)
  end

  step "pull request text is generated", context do
    pull_request(context)
  end

  step "{string} writes a title", %{args: [provider]} = context do
    context
    |> install([provider])
    |> World.update_settings(%{"textGenerationModelSelection" => selection(provider)})
    |> title("Fix the login redirect loop", attachments: Map.get(context, :attachments, []))
  end

  step "{string} is asked to write a title", %{args: [provider]} = context do
    context =
      if provider == "antigravity",
        do: plugin_text_model(context, "antigravity"),
        else:
          context
          |> install([provider])
          |> World.update_settings(%{"textGenerationModelSelection" => selection(provider)})

    title(context, "Fix the login redirect loop")
  end

  # --- who wrote -----------------------------------------------------------------------

  step "{string} writes it", %{args: [provider]} = context do
    if provider in ["pi", "antigravity"],
      do: fake_wrote(context, provider),
      else: cli_wrote(context, provider)
  end

  defp fake_wrote(context, provider) do
    assert {:ok, %{"title" => title}} = context.reply,
           "text generation failed: #{inspect(context.reply)}"

    assert title == "#{provider} title"
    assert [start] = FakeAcp.starts(context, provider)

    if provider == "pi" do
      # An ephemeral Pi without extensions or tools, given the prompt once.
      assert ~w(--mode rpc --no-session --no-extensions --no-tools) --
               start["argv"] == []

      assert [%{"message" => prompt}] =
               for(
                 %{"recv" => %{"type" => "prompt"} = recv} <- FakeAcp.log(context, "pi"),
                 do: recv
               )

      assert prompt =~ "Fix the login redirect loop"
    else
      # In an empty folder that is gone afterwards, told to use nothing but the input.
      assert [prompt] = fake_prompts(context, "antigravity")
      assert prompt =~ "Use only the input below. Do not use tools"
      refute File.exists?(start["cwd"])
    end

    context
  end

  defp cli_wrote(context, provider) do
    assert {:ok, _} = context.reply, "text generation failed: #{inspect(context.reply)}"
    assert [_ | _] = calls = calls(context)
    assert Enum.map(calls, &writer/1) |> Enum.uniq() == [provider]
    context
  end

  step "{string} writes it with {string}", %{args: [provider, model]} = context do
    assert {:ok, _} = context.reply, "text generation failed: #{inspect(context.reply)}"
    assert [call] = calls(context)
    assert writer(call) == provider

    if Map.has_key?(@clis, provider) do
      assert after_flag(call, "--model") == model
    else
      # ACP agents keep their session's model when it is only an alias; the engine's choice.
      assert %{"instanceId" => ^provider, "model" => ^model} =
               TextGeneration.model_selection(root(context), :text)
    end

    context
  end

  # --- no tools ------------------------------------------------------------------------

  step "it runs as a one-shot prompt with a JSON answer schema and no tools", context do
    assert [%{"argv" => argv} = call] = calls(context)
    assert "-p" in argv
    assert %{"type" => "object"} = JSON.decode!(after_flag(call, "--json-schema"))
    assert after_flag(call, "--tools") == ""
    assert after_flag(call, "--permission-mode") == "dontAsk"
    context
  end

  step "it runs as a one-shot exec in a read-only sandbox", context do
    assert [%{"argv" => ["exec" | _] = argv} = call] = calls(context)
    assert "--ephemeral" in argv
    assert after_flag(call, "-s") == "read-only"
    context
  end

  step "it runs as one prompt in an empty folder with every tool request refused", context do
    assert {:ok, _} = context.reply
    assert [%{"acp" => "opencode", "listing" => [], "refused" => refused}] = calls(context)
    assert refused["tg-perm"] == %{"outcome" => %{"outcome" => "cancelled"}}

    assert %{"error" => %{"message" => "fs/read_text_file is disabled for text generation"}} =
             refused["tg-read"]

    context
  end

  # --- timeouts ------------------------------------------------------------------------

  step "the writing agent does not answer within 3 minutes", context do
    assert TextGeneration.timeout() == 3 * 60_000
    context = install(context)
    # The same limit, shortened so the scenario does not wait three minutes.
    World.put_app_env(:text_generation_timeout, 2_000)
    System.put_env("FAKE_TEXT_HANG", "1")
    context
  end

  step "text generation fails and the agent's process is stopped", context do
    context = title(context, "Fix the login redirect loop")
    assert {:error, error, _} = context.reply
    assert error =~ "timed out"
    assert [%{"pid" => pid}] = calls(context)
    # `tail --pid` returns once the process is gone.
    assert {_, 0} =
             System.cmd("timeout", ["5", "tail", "--pid=#{pid}", "-s", "0.05", "-f", "/dev/null"])

    refute File.exists?("/proc/#{pid}")
    context
  end

  # --- titles --------------------------------------------------------------------------

  step "the writing agent answers the title {string}", %{args: [raw]} = context do
    answered_titles(context, [raw])
  end

  step "the writing agent answers the title a first line and a second line", context do
    answered_titles(context, ["Fix the parser\nand the lexer too"])
  end

  step "the writing agent answers the title wrapped in quotes or backticks", context do
    answered_titles(context, [~s("Fix the parser"), "`Fix the parser`", "'Fix the parser'"])
  end

  step "the writing agent answers the title with runs of spaces and tabs", context do
    answered_titles(context, ["Fix  the\t\tparser \t now"])
  end

  step "the writing agent answers the title 200 characters long", context do
    raw = for n <- 0..199, into: "", do: <<?a + rem(n, 26)>>
    context |> answered_titles([raw]) |> Map.put(:raw, raw)
  end

  step "the writing agent answers the title empty", context do
    answered_titles(context, [""])
  end

  step "the title is {string}", %{args: [title]} = context do
    assert titles(context) == [title]
    context
  end

  step "the title is the first line", context do
    assert titles(context) == ["Fix the parser"]
    context
  end

  step "the title is the text without the quotes", context do
    assert titles(context) == ["Fix the parser", "Fix the parser", "Fix the parser"]
    context
  end

  step "the title is the text with single spaces", context do
    assert titles(context) == ["Fix the parser now"]
    context
  end

  step "the title is the first 117 characters followed by {string}", %{args: [tail]} = context do
    assert titles(context) == [String.slice(context.raw, 0, 117) <> tail]
    context
  end

  step "the writing agent answers a title and says it needs refinement", context do
    answered_titles(context, [%{"title" => "Look at this link", "needsRefinement" => true}])
  end

  step "the title result says it needs refinement", context do
    assert [{:ok, %{"title" => "Look at this link", "needsRefinement" => true}}] = context.results
    context
  end

  # --- linked items --------------------------------------------------------------------

  step "a title is generated for a message linking a github.com pull request and an issue",
       context do
    context =
      github(context, [
        item(7, "Login redirect loops", "The login page redirects forever. "),
        item(9, "Session cookie expires early", "Users are signed out after a minute. ")
      ])

    title(
      context,
      "Take over https://github.com/hal-c2/code/pull/7 and fix https://github.com/hal-c2/code/issues/9."
    )
  end

  step "the writer is given each linked item's title and the start of its body", context do
    assert [%{"prompt" => prompt}] = calls(context)
    assert prompt =~ "Linked source control context"

    for {number, title, body} <- [
          {7, "Login redirect loops", "The login page redirects forever. "},
          {9, "Session cookie expires early", "Users are signed out after a minute. "}
        ] do
      assert prompt =~
               "https://github.com/hal-c2/code/#{if number == 7, do: "pull", else: "issues"}/#{number}\n"

      assert prompt =~ JSON.encode!(title)
      # The body's first 1,200 characters, not its end.
      assert prompt =~ String.slice(body <> String.duplicate("x", 1_200), 0, 1_200)
      refute prompt =~ "END #{number}"
    end

    context
  end

  step "a title is generated for a message linking four github.com issues and one is slow",
       context do
    context =
      github(context, [
        item(1, "First issue", "One. "),
        item(2, "Second issue", "Two. ") |> Map.put("sleep", 10),
        item(3, "Third issue", "Three. "),
        item(4, "Fourth issue", "Four. ")
      ])

    links = Enum.map_join(1..4, " ", &"https://github.com/hal-c2/code/issues/#{&1}")
    started = System.monotonic_time(:millisecond)
    context = title(context, "Triage #{links}")
    Map.put(context, :elapsed, System.monotonic_time(:millisecond) - started)
  end

  step "only the first two are looked up", context do
    assert gh_endpoints(context) == ["repos/hal-c2/code/issues/1", "repos/hal-c2/code/issues/2"]
    context
  end

  step "a lookup that takes longer than 3 seconds is reported as unavailable", context do
    assert [%{"prompt" => prompt}] = calls(context)
    assert prompt =~ "https://github.com/hal-c2/code/issues/2: unavailable"
    assert prompt =~ JSON.encode!("First issue")
    # Cut off at 3 seconds, long before the slow lookup would answer (10 s).
    assert context.elapsed in 3_000..9_000
    context
  end

  step "a title is generated for a message linking a pull request on another host", context do
    context
    |> github([item(7, "Private work", "Secret. ")])
    |> title(
      "Review https://gitlab.com/hal-c2/code/pull/7, https://github.example.com/hal-c2/code/pull/7 " <>
        "and https://someone@github.com/hal-c2/code/pull/7"
    )
  end

  step "no credentials are used to look it up", context do
    assert {:ok, _} = context.reply
    assert gh_endpoints(context) == []
    context
  end

  # --- images --------------------------------------------------------------------------

  step "a title is generated for a message with an image attachment", context do
    png = Base.encode64("\x89PNG fake image")

    {:ok, %{"attachments" => [image]}} =
      HalC2.Attachments.persist(%{
        "threadId" => "t-image",
        "attachments" => [
          %{"dataUrl" => "data:image/png;base64,#{png}", "name" => "shot.png"}
        ]
      })

    context
    |> Map.put(:image, image)
    |> title("What is wrong on this screen?", attachments: [image])
  end

  step "the writer receives the image", context do
    assert {:ok, _} = context.reply
    assert [%{"prompt" => prompt} = call] = calls(context)
    assert after_flag(call, "--image") == HalC2.Attachments.path(context.image)
    assert prompt =~ "Attachment metadata:"
    assert prompt =~ "shot.png"
    context
  end

  # --- branch names --------------------------------------------------------------------

  step "the writing agent answers the branch {string}", %{args: [raw]} = context do
    branch(context, raw)
  end

  step "the writing agent answers the branch 100 letters", context do
    raw = for n <- 0..99, into: "", do: <<?a + rem(n, 26)>>
    context |> branch(raw) |> Map.put(:raw, raw)
  end

  step "the branch fragment is {string}", %{args: [fragment]} = context do
    assert {:ok, %{"branch" => ^fragment}} = context.reply
    context
  end

  step "the branch fragment is the first 64 letters", context do
    assert {:ok, %{"branch" => branch}} = context.reply
    assert branch == String.slice(context.raw, 0, 64)
    context
  end

  # --- pull request templates ----------------------------------------------------------

  step "the project follows pull request templates", context do
    World.update_settings(context, %{
      "sourceControlWritingStyle" => %{"followChangeRequestTemplates" => true}
    })
  end

  step "the project does not follow pull request templates", context do
    context
    |> commit_files(%{".github/pull_request_template.md" => "## Why\n"})
    |> World.update_settings(%{
      "sourceControlWritingStyle" => %{"followChangeRequestTemplates" => false}
    })
  end

  step "the base branch has {string}", %{args: [path]} = context do
    context
    |> commit_files(%{path => "## Why\n\n## How it was tested\n"})
    |> Map.put(:template, "## Why\n\n## How it was tested")
  end

  step "the base branch has two templates in {string}", %{args: [dir]} = context do
    commit_files(context, %{
      Path.join(dir, "bug.md") => "## Bug\n",
      Path.join(dir, "feature.md") => "## Feature\n"
    })
  end

  step "the template exists only in the working copy, not the base branch", context do
    root = root(context)
    File.mkdir_p!(Path.join(root, ".github"))
    File.write!(Path.join(root, ".github/pull_request_template.md"), "## Why\n")
    context
  end

  step "the writer is given that template for the body", context do
    assert [%{"prompt" => prompt}] = calls(context)
    assert prompt =~ "Repository change request template:\n#{context.template}\n"
    context
  end

  step "the writer is given no template", context do
    assert [%{"prompt" => prompt}] = calls(context)
    refute prompt =~ "change request template"
    context
  end

  # --- Claude, Cursor and Antigravity configuration ------------------------------------

  step "the text model is on a Claude instance with its own home folder", context do
    home = HalC2.Test.Mc.tmp_dir(context.mc, "claude-home")
    context = install(context)

    context
    |> World.update_settings(%{
      "providerInstances" => %{
        "claude-work" => %{"driver" => "claudeAgent", "config" => %{"homePath" => home}}
      },
      "textGenerationModelSelection" => selection("claude-work", "claude-haiku-4-5")
    })
    |> Map.put(:claude_home, home)
  end

  step "it runs in a new temporary folder that is removed afterwards", context do
    assert [%{"cwd" => cwd}] = calls(context)
    refute cwd == root(context)
    refute File.exists?(cwd)
    context
  end

  step "the user's hooks, slash commands and MCP servers are not loaded", context do
    assert [%{"argv" => argv} = call] = calls(context)
    assert %{"disableAllHooks" => true} = JSON.decode!(after_flag(call, "--settings"))
    assert "--disable-slash-commands" in argv
    assert "--strict-mcp-config" in argv
    context
  end

  step "Claude is run with that instance's home as its configuration folder", context do
    assert {:ok, _} = context.reply
    assert [%{"claudeConfigDir" => dir}] = calls(context)
    assert dir == Path.expand(context.claude_home)
    context
  end

  step "it runs in plan mode in a new temporary folder", context do
    assert [%{"acp" => "cursor", "cwd" => cwd}] = calls(context)
    refute cwd == root(context)
    refute File.exists?(cwd)
    # The fake replaces the agent's command, so the plan mode is read from the command
    # the MC builds for a text generation run.
    World.put_app_env(:acp_commands, %{})
    assert {:ok, command, _env} = HalC2.Acp.command("cursor", "text-generation")
    assert Enum.take(command, -2) == ["--mode", "text-generation"]
    context
  end

  step "it is stopped if it does not answer in 3 minutes", context do
    assert TextGeneration.timeout() == 3 * 60_000
    context
  end

  step "the user has a custom {string}", %{args: [path]} = context do
    home = HalC2.Test.Mc.tmp_dir(context.mc, "home")
    World.put_os_env("HOME", home)
    file = Path.join(home, String.replace_prefix(path, "~/", ""))
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{}")
    context
  end

  # The MC names the file (`~/.cursor/sandbox.json`) where the feature says "that file".
  step "it fails saying Cursor text generation cannot enforce workspace isolation with that file and to use another provider",
       context do
    assert {:error, message, _} = context.reply
    assert message =~ "Cursor text generation cannot enforce workspace isolation"
    assert message =~ "~/.cursor/sandbox.json"
    assert message =~ "Use another text-generation provider"
    context
  end

  step "the Antigravity profile has global hooks", context do
    antigravity_profile(context, "hooks.json", %{
      "hooks" => %{"beforeTool" => [%{"command" => "true"}]}
    })
  end

  step "the Antigravity profile has MCP servers configured", context do
    antigravity_profile(context, "mcp_config.json", %{
      "mcpServers" => %{"files" => %{"command" => "fs"}}
    })
  end

  step "it fails saying text generation is unavailable for that profile and to select another system model",
       context do
    assert {:error, message, _} = context.reply
    assert message =~ "text generation is unavailable"
    assert message =~ "Select another system model"
    context
  end

  step "{string} writes a title and asks to run a command or read a file", context do
    steps = [
      %{
        "permission" => %{
          "toolCallId" => "tg-run",
          "title" => "run",
          "kind" => "execute",
          "rawInput" => %{"command" => "ls"}
        }
      },
      answer_step("antigravity")
    ]

    context
    |> antigravity_model(steps)
    |> title("Fix the login redirect loop")
  end

  step "the run is stopped and text generation fails", context do
    assert {:error, message, _} = context.reply
    assert message =~ "tool permission"
    context
  end

  step "{string} writes a title and leaves a file in its working folder", context do
    steps = [%{"writeFile" => "notes.md"}, %{"writeSession" => true}, answer_step("antigravity")]

    context
    |> antigravity_model(steps)
    |> title("Fix the login redirect loop")
  end

  step "it fails saying Antigravity wrote files during text generation", context do
    assert {:error, "Antigravity wrote files during text generation.", _} = context.reply
    context
  end

  step "the folder and the session it made are removed", context do
    assert [%{"cwd" => cwd}] = FakeAcp.starts(context, "antigravity")
    refute File.exists?(cwd)

    assert [] ==
             Path.wildcard(
               Path.join([
                 Antigravity.profile("antigravity"),
                 "antigravity-acp",
                 "conversations",
                 "*.meta"
               ])
             )

    context
  end

  step "the text model is {string} on a {string} instance",
       %{args: [model, provider]} = context do
    context =
      if provider == "pi",
        do: plugin_text_model(context, "pi"),
        else: install(context, [provider])

    World.update_settings(context, %{"textGenerationModelSelection" => selection(provider, model)})
  end

  # `/` is alternation in a Cucumber expression, so it is escaped.
  step "it fails saying the model must use the provider\\/model format", context do
    assert {:error, message, _} = context.reply
    assert message =~ "provider/model format"
    context
  end

  # --- Codex images --------------------------------------------------------------------

  step "a message with two images attached and one of them no longer stored", context do
    [first, second] = persist_images(["first.png", "second.png"])
    File.rm!(HalC2.Attachments.path(second))
    Map.merge(context, %{attachments: [first, second], image: first})
  end

  step "Codex receives the stored image as an image input", context do
    assert {:ok, _} = context.reply
    assert [call] = calls(context)
    assert image_args(call) == [HalC2.Attachments.path(context.image)]
    context
  end

  step "the missing one is left out without failing", context do
    assert {:ok, _} = context.reply
    assert [call] = calls(context)
    assert length(image_args(call)) == 1
    context
  end

  # --- thread context ------------------------------------------------------------------

  step "a thread whose assistant replies are each far longer than 2,000 characters", context do
    Map.put(context, :messages, [
      message("user", "Fix the login loop"),
      message("assistant", String.duplicate("x", 3_000)),
      message("assistant", String.duplicate("y", 3_000)),
      message("assistant", String.duplicate("z", 3_000))
    ])
  end

  step "the user changed the scope of the task in a late message", context do
    Map.update!(context, :messages, &(&1 ++ [message("user", "Scope changed: also fix logout")]))
  end

  step "a title is generated for that thread", context do
    regenerate(context, context.messages)
  end

  step "the first user message and the user's later messages are all in the context", context do
    prompt = prompt(context)
    assert prompt =~ "USER:\nFix the login loop"
    assert prompt =~ "USER:\nScope changed: also fix logout"
    context
  end

  step "the assistant replies take only the space the user's messages left", context do
    prompt = prompt(context)
    # Each reply is cut, so no whole reply reaches the writer; the latest one keeps its start.
    refute prompt =~ String.duplicate("x", 3_000)
    assert prompt =~ "ASSISTANT:\n" <> String.duplicate("z", 100)
    context
  end

  step "a user message longer than the space it is given", context do
    Map.put(context, :messages, [
      message("user", "START " <> String.duplicate("m", 20_000) <> " END")
    ])
  end

  step "the writer sees the start and the end of the message with {string} between them",
       %{args: [marker]} = context do
    assert prompt(context) =~ ~r/START .*#{Regex.escape(marker)}.*END/s
    context
  end

  step "when messages were left out the context begins with {string}",
       %{args: [marker]} = context do
    assert prompt(context) =~ "Thread contents:\n" <> marker
    context
  end

  step "a thread with user messages, assistant replies, reasoning traces and system notes",
       context do
    Map.put(context, :messages, [
      message("user", "Fix the parser"),
      message("reasoning", "hidden reasoning trace"),
      message("assistant", "Found it in the lexer"),
      message("system", "system note text")
    ])
  end

  step "only the user and assistant messages are given to the writer", context do
    prompt = prompt(context)
    refute prompt =~ "hidden reasoning trace"
    refute prompt =~ "system note text"
    context
  end

  step "each is labelled {string} or {string}",
       %{args: [user_label, assistant_label]} = context do
    prompt = prompt(context)
    assert prompt =~ "#{user_label}\nFix the parser"
    assert prompt =~ "#{assistant_label}\nFound it in the lexer"
    context
  end

  step "a thread whose first message has an image and whose later messages have five more",
       context do
    names = for n <- 0..5, do: "shot#{n}.png"
    images = persist_images(names)

    messages =
      for {image, n} <- Enum.with_index(images) do
        text = if n == 0, do: "First message", else: "Later message #{n}"
        message("user", text, [image])
      end

    Map.merge(context, %{messages: messages, images: images})
  end

  step "each message lists its attachments by name as {string}", context do
    prompt = prompt(context)

    Enum.each(0..5, fn n ->
      assert prompt =~ "[Attachments: shot#{n}.png]"
    end)

    context
  end

  step "the writer receives the first message's image and the three most recent ones", context do
    assert [call] = calls(context)
    expected = for n <- [0, 3, 4, 5], do: HalC2.Attachments.path(Enum.at(context.images, n))
    assert image_args(call) == expected
    context
  end

  # --- pull request templates ----------------------------------------------------------

  step "the base branch has {string} and {string}", %{args: [first, second]} = context do
    commit_files(context, %{first => template_body(first), second => template_body(second)})
  end

  step "the base branch has only one markdown file in {string}", %{args: [dir]} = context do
    path = Path.join(dir, "bug.md")

    context
    |> commit_files(%{path => template_body(path)})
    |> Map.put(:template_path, path)
  end

  step "the base branch has a file in {string} and {string}", %{args: [dir, path]} = context do
    commit_files(context, %{
      Path.join(dir, "bug.md") => template_body(Path.join(dir, "bug.md")),
      path => template_body(path)
    })
  end

  step "the base branch has a pull request template of 20,000 characters", context do
    commit_files(context, %{".github/pull_request_template.md" => String.duplicate("x", 20_000)})
  end

  step "the base branch has a symbolic link at {string}", %{args: [path]} = context do
    commit_entry(context, path, &File.ln_s!("README.md", &1))
  end

  step "the base branch has an empty file at {string}", %{args: [path]} = context do
    commit_files(context, %{path => ""})
  end

  step "the base branch has a file with only blank lines at {string}",
       %{args: [path]} = context do
    commit_files(context, %{path => "\n\n  \n"})
  end

  step "the writer is given {string} for the body", %{args: [path]} = context do
    expect_template(context, path)
  end

  step "the writer is given that file for the body", context do
    expect_template(context, context.template_path)
  end

  step "the writer is given the first 8,000 bytes of it followed by {string}",
       %{args: [marker]} = context do
    prompt = prompt(context)
    assert prompt =~ String.duplicate("x", 8_000) <> "\n\n" <> marker
    refute prompt =~ String.duplicate("x", 8_001)
    context
  end

  step "the writer is given no template from that path", context do
    refute prompt(context) =~ "change request template"
    context
  end

  # --- helpers -------------------------------------------------------------------------

  # Installs fakes for `providers` (codex and Claude when not named), once per scenario.
  defp install(context, providers \\ nil)

  defp install(%{text_log: _} = context, nil), do: context

  defp install(context, providers) do
    providers = providers || ["codex", "claudeAgent"]
    context = World.text_writers(context, for(p <- providers, cli = @clis[p], do: cli))

    commands =
      for p <- providers,
          p in @acp,
          into: %{},
          do: {p, ["python3", "-u", @fake_acp, "--instance", p]}

    World.put_app_env(:acp_commands, commands)

    World.update_settings(context, %{
      "providers" => Map.new(@acp, &{&1, %{"enabled" => &1 in providers}})
    })
  end

  # Pi is the scripted Pi RPC fake; Antigravity the scripted ACP fake as a custom
  # executable, signed in. Each answers any prompt with a title naming it.
  defp plugin_text_model(context, "pi") do
    context
    |> install()
    |> FakeAcp.install_pi(%{"turns" => [answer_turn("pi")]}, enabled: true)
    |> World.update_settings(%{
      "textGenerationModelSelection" => %{"instanceId" => "pi", "model" => "default"}
    })
  end

  defp plugin_text_model(context, "antigravity"),
    do: antigravity_model(context, [answer_step("antigravity")])

  # Antigravity signed in, answering the next prompt with `steps`.
  defp antigravity_model(context, steps) do
    context =
      context
      |> install()
      |> FakeAcp.install(
        "antigravity",
        %{"googleAuth" => true, "turns" => [%{"match" => "", "steps" => steps}]},
        binary: "agy_acp_server.par",
        enabled: true
      )

    harness =
      Path.join(Path.dirname(FakeAcp.fake(context, "antigravity").bin), "localharness_external")

    File.write!(harness, "#!/bin/sh\n")
    File.chmod!(harness, 0o755)
    token = Antigravity.token_path("antigravity")
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, JSON.encode!(%{"account" => "user@example.com"}))

    World.update_settings(context, %{
      "textGenerationModelSelection" => %{
        "instanceId" => "antigravity",
        "model" => "antigravity-default"
      }
    })
  end

  defp answer_turn(driver), do: %{"match" => "", "steps" => [answer_step(driver)]}

  defp answer_step(driver),
    do: %{"text" => JSON.encode!(%{"title" => "#{driver} title", "needsRefinement" => false})}

  # The prompts a fake Pi or Antigravity received.
  defp fake_prompts(context, driver) do
    for %{
          "recv" => %{
            "method" => "session/prompt",
            "params" => %{"prompt" => [%{"text" => text}]}
          }
        } <-
          FakeAcp.log(context, driver),
        do: text
  end

  defp selection(provider, model \\ nil),
    do: %{"instanceId" => provider, "model" => model || @defaults[provider]}

  defp root(context), do: World.project(context).root

  defp reply(context, result), do: Map.put(context, :reply, World.normalize_reply(result))

  defp title(context, message, opts \\ []) do
    context = install(context)
    reply(context, TextGeneration.thread_title(root(context), message, opts))
  end

  defp answered_titles(context, answers) do
    context = install(context)

    results =
      for answer <- answers do
        answer = if is_map(answer), do: answer, else: %{"title" => answer}
        System.put_env("FAKE_TEXT_ANSWER", JSON.encode!(answer))
        TextGeneration.thread_title(root(context), "Fix the parser")
      end

    Map.put(context, :results, results)
  end

  defp titles(context) do
    for result <- context.results do
      assert {:ok, %{"title" => title}} = result
      title
    end
  end

  defp branch(context, raw) do
    context = install(context)
    System.put_env("FAKE_TEXT_ANSWER", JSON.encode!(%{"branch" => raw}))
    reply(context, TextGeneration.branch_name(root(context), "Add a login page"))
  end

  defp commit(context, cwd) do
    context = install(context)

    reply(
      context,
      TextGeneration.commit_message(cwd, "main", "M README.md", "diff", false,
        policy: Style.policy(cwd)
      )
    )
  end

  # As `HalC2.GitActions` asks for a new pull request's text, with the base's template.
  defp pull_request(context) do
    context = install(context)
    cwd = root(context)

    reply(
      context,
      TextGeneration.pr_content(
        cwd,
        "main",
        "feature/login",
        "abc123 Add login",
        "1 file",
        "diff",
        policy: Style.policy(cwd),
        template: Style.pr_template(cwd, "main")
      )
    )
  end

  defp commit_files(context, files) do
    root = root(context)

    for {path, contents} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), contents)
      World.git!(root, ["add", path])
    end

    World.git!(root, ["commit", "-q", "-m", "templates"])
    context
  end

  # The one prompt a writer was given.
  defp prompt(context) do
    assert [%{"prompt" => prompt}] = calls(context)
    prompt
  end

  defp calls(context), do: World.text_calls(context)

  defp image_args(%{"argv" => argv}),
    do: for({"--image", index} <- Enum.with_index(argv), do: Enum.at(argv, index + 1))

  defp message(role, text, attachments \\ []),
    do: %{"role" => role, "text" => text, "attachments" => attachments}

  # Thread context as `Orchestration.regenerate_title` builds it, for a regenerated title.
  defp regenerate(context, messages) do
    {text, attachments} = HalC2.TextGeneration.Prompts.thread_context(messages)
    title(context, text, previous_title: "Old title", attachments: attachments)
  end

  # Stored images as Codex and the title prompt receive them, in the order given.
  defp persist_images(names) do
    png = Base.encode64("\x89PNG fake image")

    {:ok, %{"attachments" => stored}} =
      HalC2.Attachments.persist(%{
        "threadId" => "t-images",
        "attachments" =>
          for(name <- names, do: %{"dataUrl" => "data:image/png;base64,#{png}", "name" => name})
      })

    Enum.sort_by(stored, & &1["name"])
  end

  # The body each template path carries in these scenarios, so a prompt shows which one was given.
  defp template_body(path), do: "## Template from #{path}\n"

  defp expect_template(context, path) do
    assert prompt(context) =~
             "Repository change request template:\n" <> String.trim_trailing(template_body(path))

    context
  end

  defp commit_entry(context, path, make) do
    root = root(context)
    File.mkdir_p!(Path.dirname(Path.join(root, path)))
    make.(Path.join(root, path))
    World.git!(root, ["add", path])
    World.git!(root, ["commit", "-q", "-m", "templates"])
    context
  end

  # A file in the Antigravity profile's config, as its global hooks or MCP servers.
  defp antigravity_profile(context, file, config) do
    dir = Path.join(Antigravity.profile("antigravity"), "config")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), JSON.encode!(config))
    context
  end

  defp writer(%{"acp" => instance}), do: instance
  defp writer(%{"argv" => ["exec" | _]}), do: "codex"
  defp writer(%{"argv" => _}), do: "claudeAgent"

  defp after_flag(%{"argv" => argv}, flag),
    do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)

  # A GitHub item as the fake `gh api` answers it: a title, and a body longer than 1,200.
  defp item(number, title, body) do
    %{
      "args" => ["--hostname github.com", "repos/hal-c2/code/issues/#{number} "],
      "stdout" => %{
        "title" => title,
        "body" => body <> String.duplicate("x", 1_200) <> "END #{number}"
      }
    }
  end

  defp github(context, rules) do
    context = install(context)
    dir = HalC2.Test.Mc.tmp_dir(context.mc, "gh")
    log = Path.join(dir, "calls.jsonl")
    rules_path = Path.join(dir, "rules.json")
    File.write!(rules_path, JSON.encode!(rules))
    File.write!(log, "")
    System.put_env("FAKE_GH_LOG", log)
    System.put_env("FAKE_GH_RULES", rules_path)
    World.put_app_env(:gh_command, @fake_gh)

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("FAKE_GH_LOG")
      System.delete_env("FAKE_GH_RULES")
    end)

    Map.put(context, :gh_log, log)
  end

  defp gh_endpoints(context) do
    context.gh_log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> JSON.decode!() |> Map.fetch!("args") end)
    |> Enum.map(fn args -> Enum.find(args, &String.starts_with?(&1, "repos/")) end)
    |> Enum.sort()
  end
end
