defmodule HalC2.TextGenerationTest do
  use ExUnit.Case, async: false

  alias HalC2.{Settings, TextGeneration}
  alias HalC2.TextGeneration.{Prompts, Style}

  @moduletag :tmp_dir
  @fake Path.expand("../support/fake_text_cli.py", __DIR__)
  @fake_acp Path.expand("../support/fake_acp.py", __DIR__)

  setup %{tmp_dir: dir} do
    previous =
      for key <- [:home, :text_claude_command, :text_codex_command, :acp_commands],
          do: {key, Application.get_env(:hal_c2, key)}

    Application.put_env(:hal_c2, :home, dir)
    log = Path.join(dir, "calls.jsonl")
    System.put_env("FAKE_TEXT_LOG", log)

    on_exit(fn ->
      System.delete_env("FAKE_TEXT_LOG")

      for {key, value} <- previous,
          do:
            if(value == nil,
              do: Application.delete_env(:hal_c2, key),
              else: Application.put_env(:hal_c2, key, value)
            )
    end)

    start_supervised!(Settings)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ~w(init -q -b main))
    git!(repo, ~w(config user.name t))
    git!(repo, ~w(config user.email t@t))
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ~w(add a.txt))
    git!(repo, ["commit", "-q", "-m", "feat: first thing"])
    %{repo: repo, log: log}
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    out
  end

  defp settings!(doc) do
    {_, version} = Settings.get()
    {:ok, _} = Settings.put(doc, version)
  end

  defp install(clis) do
    Application.put_env(
      :hal_c2,
      :text_claude_command,
      if(:claude in clis, do: @fake, else: "hal-c2-test-no-claude")
    )

    Application.put_env(
      :hal_c2,
      :text_codex_command,
      if(:codex in clis, do: @fake, else: "hal-c2-test-no-codex")
    )
  end

  defp calls(log) do
    case File.read(log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      _ -> []
    end
  end

  defp after_flag(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)

  describe "model routing" do
    test "commits use the source control writer and titles the text generation model", %{
      repo: repo,
      log: log
    } do
      install([:claude, :codex])

      settings!(%{
        "textGenerationModelSelection" => %{
          "instanceId" => "codex",
          "model" => "gpt-text",
          "options" => [%{"id" => "reasoningEffort", "value" => "medium"}]
        },
        "sourceControlWriterModelSelection" => %{
          "instanceId" => "claudeAgent",
          "model" => "claude-writer",
          "options" => [%{"id" => "effort", "value" => "high"}]
        }
      })

      assert {:ok,
              %{
                "subject" => "claude subject",
                "body" => "claude body",
                "branch" => "feature/claude-branch"
              }} = TextGeneration.commit_message(repo, "main", "M a.txt", "diff", true)

      assert {:ok, %{"title" => "codex title", "needsRefinement" => false}} =
               TextGeneration.thread_title(repo, "Fix the login page")

      assert [claude, codex] = calls(log)
      assert after_flag(claude["argv"], "--model") == "claude-writer"
      assert after_flag(claude["argv"], "--effort") == "high"
      assert Path.basename(claude["cwd"]) == "repo"
      assert claude["prompt"] =~ "Return a JSON object with keys: subject, body, branch."

      assert ["exec" | _] = codex["argv"]
      assert after_flag(codex["argv"], "--model") == "gpt-text"
      assert ~s(model_reasoning_effort="medium") in codex["argv"]
      assert codex["prompt"] =~ "User message:\nFix the login page"
    end

    test "options that are not a list of id/value maps are ignored, not a crash", %{
      repo: repo,
      log: log
    } do
      install([:claude])

      for options <- [%{"effort" => "high"}, ["high", %{"id" => "effort", "value" => "low"}]] do
        settings!(%{
          "textGenerationModelSelection" => %{
            "instanceId" => "claudeAgent",
            "model" => "claude-text",
            "options" => options
          }
        })

        assert {:ok, %{"branch" => _}} = TextGeneration.branch_name(repo, "Add login")
      end

      assert [_, second] = calls(log)
      assert after_flag(second["argv"], "--effort") == "low"
    end

    test "a writer on a disabled provider falls back to the text generation model", %{
      repo: repo,
      log: log
    } do
      install([:claude, :codex])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"},
        "sourceControlWriterModelSelection" => %{"instanceId" => "claudeAgent", "model" => "x"},
        "providerInstances" => %{
          "claudeAgent" => %{"driver" => "claudeAgent", "enabled" => false}
        }
      })

      assert {:ok, %{"branch" => "codex-branch"}} = TextGeneration.branch_name(repo, "Add login")
      assert [%{"argv" => ["exec" | _] = argv}] = calls(log)
      assert after_flag(argv, "--model") == "gpt-text"
    end

    test "a model whose CLI is missing falls back to the first usable provider's default", %{
      repo: repo,
      log: log
    } do
      install([:claude])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"}
      })

      assert {:ok, %{"title" => "claude title"}} = TextGeneration.thread_title(repo, "Fix it")
      assert [%{"argv" => argv, "cwd" => cwd}] = calls(log)
      assert after_flag(argv, "--model") == "claude-haiku-5-5"
      # Titles run outside the checkout.
      assert Path.basename(cwd) =~ ~r/^hal-c2-text-/

      install([])

      # A CLI the user chose, missing, with nothing to fall back to, is named.
      assert {:error, "Codex CLI " <> _ = message} =
               TextGeneration.commit_message(repo, "main", "M a.txt", "diff")

      assert message =~ "is required but not available on PATH"

      # With no model chosen there is only the general message.
      settings!(%{"textGenerationModelSelection" => nil})

      assert {:error, "No text generation provider is available" <> _} =
               TextGeneration.commit_message(repo, "main", "M a.txt", "diff")
    end

    test "a writer whose check failed falls back, and one still being checked keeps its selection",
         %{repo: repo, log: log} do
      install([:claude, :codex])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"}
      })

      on_exit(fn -> HalC2.Codex.Provider.record_check("codex", nil) end)

      # Still being checked: the selection stands.
      :ok = HalC2.Codex.Provider.record_check("codex", nil)
      assert {:ok, %{"title" => "codex title"}} = TextGeneration.thread_title(repo, "Fix it")

      # Check failed: the next usable provider writes, with its default model.
      :ok =
        HalC2.Codex.Provider.record_check("codex", %{
          "installed" => true,
          "message" => "Codex app-server provider probe failed: signed out."
        })

      assert {:ok, %{"title" => "claude title"}} = TextGeneration.thread_title(repo, "Fix it")
      assert [_, %{"argv" => argv}] = calls(log)
      assert after_flag(argv, "--model") == "claude-haiku-5-5"
    end

    test "a Codex that cannot list its MCP servers runs in a home with only the login", %{
      repo: repo,
      log: log,
      tmp_dir: dir
    } do
      install([:codex])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"}
      })

      home = Path.join(dir, "user-codex")
      File.mkdir_p!(home)
      File.write!(Path.join(home, "auth.json"), ~s({"token":"t"}))
      File.write!(Path.join(home, "config.toml"), "[mcp_servers.augmenter]\ncommand = \"x\"\n")

      System.put_env("CODEX_HOME", home)
      System.put_env("FAKE_CODEX_MCP_FAIL", "1")

      on_exit(fn ->
        System.delete_env("CODEX_HOME")
        System.delete_env("FAKE_CODEX_MCP_FAIL")
      end)

      assert {:ok, %{"title" => "codex title"}} = TextGeneration.thread_title(repo, "Fix it")

      assert [%{"codexHome" => scratch, "codexFiles" => files}] = calls(log)
      assert scratch != home
      assert files == %{"auth.json" => ~s({"token":"t"}), "config.toml" => ""}
      refute File.exists?(scratch)
    end

    test "a Codex that cannot list its MCP servers drops the servers its launch arguments define",
         %{repo: repo, log: log, tmp_dir: dir} do
      install([:codex])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"},
        "providers" => %{
          "codex" => %{
            "launchArgs" =>
              ~s(-c mcp_servers.launched.command="x" --config=mcp_servers.other.command="y" -c model_verbosity="low")
          }
        }
      })

      System.put_env("CODEX_HOME", dir)
      System.put_env("FAKE_CODEX_MCP_FAIL", "1")

      on_exit(fn ->
        System.delete_env("CODEX_HOME")
        System.delete_env("FAKE_CODEX_MCP_FAIL")
      end)

      assert {:ok, %{"title" => "codex title"}} = TextGeneration.thread_title(repo, "Fix it")

      assert [%{"argv" => argv}] = calls(log)
      refute Enum.any?(argv, &(&1 =~ "mcp_servers"))
      assert "model_verbosity=low" in argv
    end

    test "a Codex that cannot list its MCP servers keeps the login of its shadow home", %{
      repo: repo,
      log: log,
      tmp_dir: dir
    } do
      install([:codex])
      shared = Path.join(dir, "shared-codex")
      shadow = Path.join(dir, "shadow-codex")
      File.mkdir_p!(shared)
      File.write!(Path.join(shared, "auth.json"), ~s({"token":"shared"}))
      File.mkdir_p!(shadow)
      File.write!(Path.join(shadow, "auth.json"), ~s({"token":"shadow"}))

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex-work", "model" => "gpt-text"},
        "providerInstances" => %{
          "codex-work" => %{
            "driver" => "codex",
            "config" => %{"homePath" => shared, "shadowHomePath" => shadow}
          }
        }
      })

      System.put_env("FAKE_CODEX_MCP_FAIL", "1")
      on_exit(fn -> System.delete_env("FAKE_CODEX_MCP_FAIL") end)

      assert {:ok, %{"title" => "codex title"}} = TextGeneration.thread_title(repo, "Fix it")

      assert [%{"codexFiles" => %{"auth.json" => ~s({"token":"shadow"}), "config.toml" => ""}}] =
               calls(log)
    end

    test "a writer whose check only warned keeps generating", %{repo: repo} do
      install([:claude, :codex])

      settings!(%{
        "textGenerationModelSelection" => %{"instanceId" => "codex", "model" => "gpt-text"}
      })

      on_exit(fn -> HalC2.Codex.Provider.record_check("codex", nil) end)

      # A signed-in Codex with no model list: probe/1 records a warning, not a failure.
      :ok =
        HalC2.Codex.Provider.record_check("codex", %{"warning" => "Codex returned no models."})

      assert HalC2.Codex.Provider.check_state("codex") == :ok
      assert {:ok, %{"title" => "codex title"}} = TextGeneration.thread_title(repo, "Fix it")
    end

    test "an ACP agent writes through one prompt in an empty directory", %{repo: repo} do
      install([])
      Application.put_env(:hal_c2, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})

      settings!(%{
        "providers" => %{"opencode" => %{"enabled" => true}},
        "sourceControlWriterModelSelection" => %{
          "instanceId" => "opencode",
          "model" => "fake/two"
        }
      })

      assert {:ok, %{"branch" => branch}} = TextGeneration.branch_name(repo, "Add login")
      assert branch =~ ~r{^acp-branch-fake/two-in-hal-c2-text-\d+-\d+$}
    end

    test "an ACP agent dying mid-generation fails it, not as a cancellation", %{repo: repo} do
      install([])
      dying = Path.expand("../support/fake_acp_dying.py", __DIR__)
      Application.put_env(:hal_c2, :acp_commands, %{"opencode" => ["python3", "-u", dying]})

      settings!(%{
        "providers" => %{"opencode" => %{"enabled" => true}},
        "sourceControlWriterModelSelection" => %{
          "instanceId" => "opencode",
          "model" => "fake/one"
        }
      })

      # The connection's exit and the prompt's error answer race to the
      # collector; whichever lands first, the answer is the failure.
      for _ <- 1..5 do
        assert {:error, message} = TextGeneration.branch_name(repo, "Add login")
        assert message =~ "request failed"
      end
    end
  end

  describe "a project's switch on an ACP agent configured only under providers" do
    setup do
      Application.put_env(:hal_c2, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})
      :ok
    end

    test "turns it off where the environment has it on" do
      settings!(%{
        "providers" => %{"opencode" => %{"enabled" => true}},
        "projectSettingsOverrides" => %{
          "p1" => %{"providerInstances" => %{"opencode" => %{"enabled" => false}}}
        }
      })

      selection = %{"instanceId" => "opencode", "model" => "fake/two"}
      assert TextGeneration.usable?(Settings.settings(), selection)
      refute TextGeneration.usable?(Settings.resolve(Settings.settings(), "p1"), selection)
    end

    test "turns it on where the environment has it off" do
      settings!(%{
        "projectSettingsOverrides" => %{
          "p1" => %{"providerInstances" => %{"opencode" => %{"enabled" => true}}}
        }
      })

      selection = %{"instanceId" => "opencode", "model" => "fake/two"}
      refute TextGeneration.usable?(Settings.settings(), selection)
      assert TextGeneration.usable?(Settings.resolve(Settings.settings(), "p1"), selection)
    end
  end

  describe "writing style" do
    test "Conventional Commits and custom instructions", %{repo: repo} do
      settings!(%{"sourceControlWritingStyle" => %{"mode" => "conventional_commits"}})
      policy = Style.policy(repo)

      assert Prompts.commit("main", "M a.txt", "diff", false, policy) ==
               """
               You write concise git commit messages.
               Return a JSON object with keys: subject, body.
               Rules:
               - subject must be imperative, <= 72 chars, and no trailing period
               - body can be empty string or short bullet points
               - capture the primary user-visible or developer-visible change

               Additional instructions:
               Use Conventional Commits when generating commit subjects. Prefer the narrowest accurate type and include a scope only when it is obvious from the diff.

               Branch: main

               Staged files:
               M a.txt

               Staged patch:
               diff\
               """

      settings!(%{
        "sourceControlWritingStyle" => %{
          "mode" => "custom",
          "customInstructions" => " Be terse. "
        }
      })

      assert %{commit: "Be terse.", change_request: "Be terse."} = Style.policy(repo)

      settings!(%{"sourceControlWritingStyle" => %{"mode" => "custom"}})
      refute Prompts.commit("main", "M", "d", false, Style.policy(repo)) =~ "Additional"
    end

    test "repository conventions read commit subjects, AGENTS.md, and CLAUDE.md for Claude", %{
      repo: repo
    } do
      install([:claude, :codex])
      File.write!(Path.join(repo, "AGENTS.md"), "Use plain language.\n")
      File.write!(Path.join(repo, "CLAUDE.md"), "Claude only.\n")

      examples =
        "Recent commit subjects from this repository:\nfeat: first thing\n\nLocal AGENTS.md:\nUse plain language."

      assert Style.policy(repo) == %{
               kind: "repo_conventions",
               commit:
                 "Follow the repository's established commit message style when examples are available.\n\n" <>
                   examples,
               change_request:
                 "Follow the repository's established change request title and body style when examples are available.\n\n" <>
                   examples
             }

      settings!(%{
        "sourceControlWriterModelSelection" => %{"instanceId" => "claudeAgent", "model" => "x"}
      })

      assert Style.policy(repo).commit =~ examples <> "\n\nLocal CLAUDE.md:\nClaude only."
    end

    test "the pull request prompt follows the repository's template", %{repo: repo} do
      File.mkdir_p!(Path.join(repo, ".github/PULL_REQUEST_TEMPLATE"))
      File.write!(Path.join(repo, ".github/PULL_REQUEST_TEMPLATE/one.md"), "## One\n")
      git!(repo, ~w(add .))
      git!(repo, ~w(commit -q -m templates))
      assert Style.pr_template(repo, "HEAD") == "## One"

      # Two templates in the folder leave the choice to the user.
      File.write!(Path.join(repo, ".github/PULL_REQUEST_TEMPLATE/two.md"), "## Two\n")
      git!(repo, ~w(add .))
      git!(repo, ~w(commit -q -m more))
      assert Style.pr_template(repo, "HEAD") == nil

      # A template path wins; only the committed tree counts.
      File.write!(Path.join(repo, "pull_request_template.md"), "\n<!-- hint -->\n## Why\n")
      assert Style.pr_template(repo, "HEAD") == nil
      git!(repo, ~w(add .))
      git!(repo, ~w(commit -q -m root))
      template = Style.pr_template(repo, "HEAD")
      assert template == "<!-- hint -->\n## Why"

      prompt =
        Prompts.pr("main", "feature/x", "abc feat", "1 file", "diff", template, %{
          change_request: "Sentence case."
        })

      assert prompt ==
               """
               You write source control change request content.
               Return a JSON object with keys: title, body.
               Rules:
               - title should be concise and specific
               - body must be markdown and follow the repository change request template structure
               - fill in the template sections appropriately for this change
               - drop HTML comments from the template in the generated body
               - keep the template's markdown structure

               Additional instructions:
               Sentence case.

               Repository change request template:
               <!-- hint -->
               ## Why

               Base branch: main
               Head branch: feature/x

               Commits:
               abc feat

               Diff stat:
               1 file

               Diff patch:
               diff\
               """

      settings!(%{"sourceControlWritingStyle" => %{"followChangeRequestTemplates" => false}})
      assert Style.pr_template(repo, "HEAD") == nil
    end
  end

  test "a regenerated title reads the first and latest requests before the answers" do
    messages = [
      %{"role" => "user", "text" => "Fix the flaky login test"},
      %{"role" => "assistant", "text" => String.duplicate("a", 9_000)},
      %{"role" => "reasoning", "text" => "hidden"},
      %{
        "role" => "user",
        "text" => "Also cover logout",
        "attachments" => [%{"id" => "i1", "name" => "shot.png"}]
      }
    ]

    {text, attachments} = Prompts.thread_context(messages)

    assert "[Earlier content truncated]\n\nUSER:\nFix the flaky login test\n\nASSISTANT:\n" <>
             rest =
             text

    assert rest =~ "\n[Content truncated]\n"
    assert String.ends_with?(rest, "USER:\nAlso cover logout\n[Attachments: shot.png]")
    refute text =~ "hidden"
    assert [%{"id" => "i1"}] = attachments
  end

  test "an Antigravity profile with global hooks or MCP servers cannot write text", %{
    tmp_dir: dir
  } do
    profile = Path.join(dir, "profile")
    config = Path.join(profile, "config")
    File.mkdir_p!(config)
    write = fn name, body -> File.write!(Path.join(config, name), body) end

    # Nothing configured, or configured empty, either as the key or the whole file.
    assert TextGeneration.antigravity_available?(Path.join(dir, "missing"))
    write.("hooks.json", ~s({"hooks": {}}))
    write.("mcp_config.json", "{}")
    assert TextGeneration.antigravity_available?(profile)

    write.("mcp_config.json", ~s({"mcpServers": {"docs": {"command": "docs-mcp"}}}))
    refute TextGeneration.antigravity_available?(profile)

    write.("mcp_config.json", ~s({"mcpServers": {}}))
    write.("hooks.json", ~s({"hooks": {"PreToolUse": []}}))
    refute TextGeneration.antigravity_available?(profile)

    # A file it cannot read as settings, or one too large to trust, counts as configured.
    write.("hooks.json", "not json")
    refute TextGeneration.antigravity_available?(profile)
    write.("hooks.json", ~s({"hooks": {}, "pad": "#{String.duplicate("x", 64_000)}"}))
    refute TextGeneration.antigravity_available?(profile)
  end

  test "Codex resolves a model against the list of the instance that writes", %{
    repo: repo,
    log: log
  } do
    install([:codex])
    list = fn slugs -> for slug <- slugs, do: %{"slug" => slug, "isDefault" => false} end
    :ok = HalC2.Codex.Provider.record_models("codex", list.(["gpt-6-luna"]))
    :ok = HalC2.Codex.Provider.record_models("codex-work", list.(["gpt-7-work-mini"]))

    on_exit(fn ->
      HalC2.Codex.Provider.record_models("codex", nil)
      HalC2.Codex.Provider.record_models("codex-work", nil)
    end)

    settings!(%{
      "textGenerationModelSelection" => %{"instanceId" => "codex-work", "model" => "gpt-7"},
      "providerInstances" => %{"codex-work" => %{"driver" => "codex"}}
    })

    assert {:ok, _} = TextGeneration.thread_title(repo, "Fix the login redirect loop")
    # The family resolves against the work account's list, not the default account's.
    assert [%{"argv" => argv}] = calls(log)
    assert after_flag(argv, "--model") == "gpt-7-work-mini"
  end

  test "Claude writes with the config folder of the instance chosen for text generation", %{
    repo: repo,
    log: log,
    tmp_dir: dir
  } do
    install([:claude])
    home = Path.join(dir, "claude-work")

    settings!(%{
      "textGenerationModelSelection" => %{
        "instanceId" => "claudeAgent",
        "model" => "claude-haiku-4-5"
      },
      "providerInstances" => %{
        "claudeAgent" => %{"driver" => "claudeAgent", "config" => %{"homePath" => home}}
      }
    })

    assert {:ok, _} = TextGeneration.thread_title(repo, "Fix the login redirect loop")
    assert [%{"claudeConfigDir" => ^home}] = calls(log)
  end

  test "Claude writes with the environment variables of the instance chosen for text generation",
       %{repo: repo, log: log, tmp_dir: dir} do
    install([:claude])
    home = Path.join(dir, "claude-env")

    settings!(%{
      "textGenerationModelSelection" => %{
        "instanceId" => "claudeAgent",
        "model" => "claude-haiku-4-5"
      },
      "providerInstances" => %{
        "claudeAgent" => %{
          "driver" => "claudeAgent",
          "environment" => [%{"name" => "CLAUDE_CONFIG_DIR", "value" => home}]
        }
      }
    })

    assert {:ok, _} = TextGeneration.thread_title(repo, "Fix the login redirect loop")
    assert [%{"claudeConfigDir" => ^home}] = calls(log)
  end

  test "OpenCode's text model must be written as provider/model", %{repo: repo} do
    install([])
    Application.put_env(:hal_c2, :acp_commands, %{"opencode" => ["python3", "-u", @fake_acp]})

    settings!(%{
      "providers" => %{"opencode" => %{"enabled" => true}},
      "textGenerationModelSelection" => %{"instanceId" => "opencode", "model" => "gpt-5"}
    })

    assert {:error, "OpenCode model 'gpt-5' must use the provider/model format."} =
             TextGeneration.thread_title(repo, "Fix the login redirect loop")
  end
end
