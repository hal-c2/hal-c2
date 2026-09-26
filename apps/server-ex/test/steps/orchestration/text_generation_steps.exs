defmodule HalC2.Steps.Orchestration.TextGeneration do
  @moduledoc """
  Steps for `features/node/orchestration/text-generation.feature`. The engine's
  writers (`HalC2.TextGeneration`) run against fakes: `fake_text_cli.py` as the
  `claude` and `codex` CLIs, `fake_acp.py --instance <id>` as the ACP agents, and
  `fake_gh.py` for linked GitHub items. Each fake logs its calls, which is how a
  step tells who wrote and what they were given.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.TextGeneration
  alias HalC2.TextGeneration.Style
  alias HalC2.Test.Node.World

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
    |> title("Fix the login redirect loop")
  end

  # --- who wrote -----------------------------------------------------------------------

  step "{string} writes it", %{args: [provider]} = context do
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

  defp plugin_text_model(context, driver) do
    context
    |> install()
    |> World.update_settings(%{
      "providerInstances" => %{driver => %{"driver" => driver, "enabled" => true}},
      "textGenerationModelSelection" => %{"instanceId" => driver, "model" => "default"}
    })
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

  defp calls(context), do: World.text_calls(context)

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
    dir = HalC2.Test.Node.tmp_dir(context.node, "gh")
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
