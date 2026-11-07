defmodule HalC2.Steps.Providers.Usage do
  @moduledoc """
  Steps for `features/providers/usage.feature`: `server.getUsageSummary` and
  `server.refreshUsageRates` over transcripts written into the scenario's home.

  The Background gives each provider one turn five minutes ago (`@history`), with
  Claude and Codex homes from `providers.*.homePath` and Grok's from the `grok`
  instance's `GROK_HOME`; the price table is a file (`:usage_rates_url`), never
  the network.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # Per-token USD, as LiteLLM's table lists them.
  @rates %{
    "anthropic/claude-fable-5" => %{
      "input_cost_per_token" => 3.0e-6,
      "output_cost_per_token" => 1.5e-5,
      "cache_read_input_token_cost" => 3.0e-7
    },
    "anthropic/claude-sonnet" => %{
      "input_cost_per_token" => 1.0e-6,
      "output_cost_per_token" => 2.0e-6
    },
    "openai/gpt-5.6-sol" => %{"input_cost_per_token" => 1.0e-6, "output_cost_per_token" => 8.0e-6},
    "xai/grok-4" => %{"input_cost_per_token" => 2.0e-6, "output_cost_per_token" => 1.0e-5}
  }

  # --- background -------------------------------------------------------------------------------

  step "a connected environment with Codex, Claude and Grok history", context do
    home = context.mc.home

    dirs = %{
      claude: Path.join(home, "claude"),
      codex: Path.join(home, "codex"),
      grok: Path.join(home, "grok")
    }

    World.merge_settings(%{
      "providers" => %{
        "claudeAgent" => %{"homePath" => dirs.claude},
        "codex" => %{"homePath" => dirs.codex}
      },
      "providerInstances" => %{
        "grok" => %{
          "driver" => "grok",
          "environment" => [%{"name" => "GROK_HOME", "value" => dirs.grok}]
        }
      }
    })

    rates = Path.join(home, "rates.json")
    File.write!(rates, JSON.encode!(@rates))
    rates_url(rates)

    at = now() - 5 * 60_000

    claude(dirs.claude, "main", [
      claude_line("fable-1", at, input: 1000, cached: 4000, output: 500)
    ])

    codex(dirs.codex, "main", "gpt-5.6-sol", [
      codex_count(at, input: 2000, cached: 1000, output: 300)
    ])

    grok(dirs.grok, "main", [grok_completed("p1", at, "grok-4", input: 800, output: 200)])
    Mc.ensure(HalC2.Usage)
    Map.put(context, :usage_dirs, dirs)
  end

  # --- windows ----------------------------------------------------------------------------------

  step "the user opens Usage for the last seven days", context do
    summary(context)
  end

  step "tokens, cache savings and estimated cost are shown per day, provider and model",
       context do
    today = day(now() - 5 * 60_000)
    usage = context.usage

    assert %{"day" => ^today, "totals" => %{"outputTokens" => 500, "cachedInputTokens" => 4000}} =
             claude = bucket(usage, "claude", "claude-fable-5")

    assert_in_delta claude["costUsd"], 1000 * 3.0e-6 + 4000 * 3.0e-7 + 500 * 1.5e-5, 1.0e-9
    assert_in_delta claude["cacheSavingsUsd"], 4000 * (3.0e-6 - 3.0e-7), 1.0e-9

    assert %{"day" => ^today, "totals" => %{"uncachedInputTokens" => 1000, "outputTokens" => 300}} =
             codex = bucket(usage, "codex", "gpt-5.6-sol")

    assert_in_delta codex["costUsd"], 1000 * 1.0e-6 + 1000 * 1.0e-6 + 300 * 8.0e-6, 1.0e-9

    assert %{"day" => ^today, "totals" => %{"outputTokens" => 200}} =
             bucket(usage, "grok", "grok-4")

    context
  end

  step "the user asks for hourly usage over the last twelve hours", context do
    until = now()
    since = until - 12 * 3_600_000

    input = %{
      "sinceDay" => day(since),
      "untilDay" => day(until),
      "timeZone" => "UTC",
      "resolution" => "hour",
      "sinceTime" => iso(since),
      "untilTime" => iso(until)
    }

    context |> summary(input) |> Map.put(:hourly_since, since)
  end

  step "usage is shown per hour", context do
    buckets = context.usage["buckets"]
    assert length(buckets) == 3

    for bucket <- buckets do
      {:ok, start, _} = DateTime.from_iso8601(bucket["hourStart"])
      offset = DateTime.to_unix(start, :millisecond) - context.hourly_since
      assert rem(offset, 3_600_000) == 0 and offset in 0..(11 * 3_600_000)
    end

    context
  end

  step ~r/^the user asks for usage (?<window>.+)$/, %{args: [window]} = context do
    today = day(now())

    input =
      case window do
        "from 2026-09-10 until 2026-09-01" ->
          %{"sinceDay" => "2026-09-10", "untilDay" => "2026-09-01", "timeZone" => "UTC"}

        ~s(from "yesterday") ->
          %{"sinceDay" => "yesterday", "untilDay" => today, "timeZone" => "UTC"}

        "per hour over two days" ->
          %{
            "sinceDay" => day(now() - 2 * 86_400_000),
            "untilDay" => today,
            "timeZone" => "UTC",
            "resolution" => "hour",
            "sinceTime" => iso(now() - 2 * 86_400_000),
            "untilTime" => iso(now())
          }

        "per hour without start and end instants" ->
          %{"sinceDay" => today, "untilDay" => today, "timeZone" => "UTC", "resolution" => "hour"}

        "without a time zone" ->
          %{"sinceDay" => today, "untilDay" => today}
      end

    {reply, context} = World.call(context, "server.getUsageSummary", input)
    Map.put(context, :reply, reply)
  end

  # --- what is counted --------------------------------------------------------------------------

  step "the user opens Usage", context do
    summary(context)
  end

  step "the user opens Usage again", context do
    summary(context)
  end

  step "the user ran Claude Code directly in a terminal yesterday", context do
    at = noon(1)

    claude(context.usage_dirs.claude, "terminal", [
      claude_line("terminal-1", at, output: 777, session: "terminal")
    ])

    Map.put(context, :terminal_day, day(at))
  end

  step "yesterday's Claude usage includes that session", context do
    buckets =
      for b <- context.usage["buckets"],
          b["provider"] == "claude",
          b["day"] == context.terminal_day,
          do: b

    assert Enum.sum(for b <- buckets, do: b["totals"]["outputTokens"]) >= 777
    assert Enum.sum(for b <- buckets, do: b["sessions"]) >= 1
    context
  end

  step "a Grok session whose last turn never completed", context do
    at = now() - 60_000

    grok(context.usage_dirs.grok, "unfinished", [
      grok_completed("p1", at, "grok-4", input: 10, output: 20),
      # The next turn's usage so far, without its turn_completed update.
      %{
        "params" => %{
          "sessionId" => "unfinished",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "prompt_id" => "p2",
            "usage" => %{"inputTokens" => 9000, "outputTokens" => 9000}
          },
          "_meta" => %{"agentTimestampMs" => at}
        }
      }
    ])

    context
  end

  step "that turn is missing from the totals", context do
    # The Background's turn and the unfinished session's completed one, which
    # land in different days' buckets when the run crosses midnight.
    output =
      context.usage |> buckets("grok", "grok-4", nil) |> Enum.map(& &1["totals"]["outputTokens"])

    assert Enum.sum(output) == 200 + 20
    context
  end

  step "a Grok turn that reported its own cost", context do
    at = now() - 60_000
    turn = grok_completed("p1", at, "grok-code", input: 100, output: 100)

    turn =
      put_in(
        turn,
        ["params", "update", "usage", "modelUsage", "grok-code", "costUsdTicks"],
        12_345_000_000
      )

    grok(context.usage_dirs.grok, "reported", [turn])
    context
  end

  step "that turn's cost is the provider's reported cost", context do
    assert %{"costSource" => "providerReported", "costUsd" => cost} =
             bucket(context.usage, "grok", "grok-code")

    assert_in_delta cost, 1.2345, 1.0e-9
    context
  end

  step "a turn on a model missing from the price table", context do
    claude(context.usage_dirs.claude, "mystery", [
      claude_line("mystery-1", now() - 60_000, model: "claude-mystery-9", output: 10)
    ])

    context
  end

  step "that model's cost is marked unpriced", context do
    assert %{"costSource" => "unpriced", "costUsd" => 0, "unpricedRecords" => 1} =
             bucket(context.usage, "claude", "claude-mystery-9")

    assert bucket(context.usage, "claude", "claude-fable-5")["costSource"] == "modelPriced"
    context
  end

  # --- the price table --------------------------------------------------------------------------

  step "the MC fetched the price table before", context do
    snapshot(context, @rates, 2 * 86_400_000)
  end

  step "the price table cannot be fetched now", context do
    rates_url(Path.join(context.mc.home, "unreachable-rates.json"))
    context
  end

  step "costs use the saved price table", context do
    assert %{"status" => "cached", "knownModels" => known} = context.usage["pricing"]
    assert known > 0
    assert bucket(context.usage, "claude", "claude-fable-5")["costSource"] == "modelPriced"
    assert bucket(context.usage, "codex", "gpt-5.6-sol")["costSource"] == "modelPriced"
    context
  end

  step "the MC has never fetched the price table and cannot fetch it now", context do
    rates_url(Path.join(context.mc.home, "unreachable-rates.json"))
    refute File.exists?(Path.join(context.mc.home, "usage-model-rates.json"))
    context
  end

  step "every model is marked unpriced", context do
    assert %{"status" => "unavailable", "knownModels" => 0} = context.usage["pricing"]
    buckets = context.usage["buckets"]
    assert length(buckets) == 3
    assert Enum.all?(buckets, &(&1["costSource"] == "unpriced" and &1["costUsd"] == 0))
    context
  end

  step "a new model appeared with no cost", context do
    claude(context.usage_dirs.claude, "new", [
      claude_line("new-1", now() - 60_000, model: "claude-new-1", output: 10)
    ])

    # The MC's copy is from before the model existed; upstream knows it now.
    context = snapshot(context, @rates, 2 * 60_000)

    File.write!(
      Path.join(context.mc.home, "rates.json"),
      JSON.encode!(
        Map.put(@rates, "anthropic/claude-new-1", %{
          "input_cost_per_token" => 1.0e-6,
          "output_cost_per_token" => 1.0e-6
        })
      )
    )

    context = summary(context)
    assert bucket(context.usage, "claude", "claude-new-1")["costSource"] == "unpriced"
    context
  end

  step "the user refreshes Usage", context do
    {reply, context} = World.call(context, "server.refreshUsageRates")
    Map.put(context, :reply, reply)
  end

  step "the price table is fetched again", context do
    assert {:ok, %{"status" => "fresh", "fetchedAt" => at}} = context.reply
    {:ok, at, _} = DateTime.from_iso8601(at)
    assert DateTime.diff(DateTime.utc_now(), at) < 60
    context
  end

  step "the new model is priced when the table knows it", context do
    context = summary(context)

    assert %{"costSource" => "modelPriced", "costUsd" => cost} =
             bucket(context.usage, "claude", "claude-new-1")

    assert_in_delta cost, (10 + 10) * 1.0e-6, 1.0e-12
    context
  end

  # --- custom prices ----------------------------------------------------------------------------

  step "the user saved a custom price for {string} of {int} USD input and {int} USD output per million tokens",
       %{args: [model, input, output]} = context do
    # One turn today, and one yesterday that carried the provider's own cost.
    # Both at noon of their day, and their days remembered: a run in the first
    # minute after midnight would otherwise put both turns in yesterday's bucket.
    claude(context.usage_dirs.claude, "custom", [
      claude_line("custom-1", noon(0), model: model, input: 1000, output: 2000),
      claude_line("custom-2", noon(1), model: model, input: 1000, output: 2000, cost: 0.5)
    ])

    context
    |> save_prices(%{
      model => %{"inputCostPerMillionTokens" => input, "outputCostPerMillionTokens" => output}
    })
    |> Map.merge(%{
      custom_cost: 1000 * input / 1.0e6 + 2000 * output / 1.0e6,
      custom_today: day(noon(0)),
      custom_yesterday: day(noon(1))
    })
  end

  step "{string} is priced with the custom rates", %{args: [model]} = context do
    assert [%{"costSource" => "modelPriced", "costUsd" => cost}] =
             buckets(context.usage, "claude", model, context.custom_today)

    assert_in_delta cost, context.custom_cost, 1.0e-12
    context
  end

  step "a provider-reported cost for {string} is replaced by the custom price",
       %{args: [model]} = context do
    assert [%{"costSource" => "modelPriced", "costUsd" => cost}] =
             buckets(context.usage, "claude", model, context.custom_yesterday)

    assert_in_delta cost, context.custom_cost, 1.0e-12
    context
  end

  step "the user saved a custom price for {string} without cache rates",
       %{args: [model]} = context do
    claude(context.usage_dirs.claude, "cache", [
      claude_line("cache-1", now() - 60_000,
        model: model,
        input: 0,
        cached: 1000,
        created: 1000,
        output: 0
      )
    ])

    save_prices(context, %{
      model => %{"inputCostPerMillionTokens" => 3, "outputCostPerMillionTokens" => 9}
    })
  end

  step "cache reads and writes of {string} are priced at its input rate",
       %{args: [model]} = context do
    assert %{"costSource" => "modelPriced", "costUsd" => cost} =
             bucket(context.usage, "claude", model)

    assert_in_delta cost, 2000 * 3 / 1.0e6, 1.0e-12
    context
  end

  step "the user saved a custom price for {string}", %{args: [model]} = context do
    claude(context.usage_dirs.claude, "sonnet", [
      claude_line("sonnet-1", now() - 60_000, model: model, input: 1000, output: 1000)
    ])

    context =
      context
      |> save_prices(%{
        model => %{"inputCostPerMillionTokens" => 100, "outputCostPerMillionTokens" => 100}
      })
      |> summary()

    assert_in_delta bucket(context.usage, "claude", model)["costUsd"], 0.2, 1.0e-12
    context
  end

  step "the user resets {string} to automatic", %{args: [model]} = context do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    settings = update_in(settings, ["usagePriceOverrides"], &Map.delete(&1, model))

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{"settings" => settings, "version" => version})

    context
  end

  step "{string} is priced from the price table again", %{args: [model]} = context do
    context = summary(context)

    assert %{"costSource" => "modelPriced", "costUsd" => cost} =
             bucket(context.usage, "claude", model)

    assert_in_delta cost, 1000 * 1.0e-6 + 1000 * 2.0e-6, 1.0e-12
    context
  end

  # --- homes ------------------------------------------------------------------------------------

  step "two Claude accounts with their own homes, one of them disabled", context do
    work = Path.join(context.mc.home, "claude-work")
    personal = Path.join(context.mc.home, "claude-personal")
    claude(work, "work", [claude_line("work-1", now() - 60_000, output: 111, session: "work")])

    claude(personal, "personal", [
      claude_line("personal-1", now() - 60_000, output: 222, session: "personal")
    ])

    World.merge_settings(%{
      "providerInstances" => %{
        "claude-work" => %{
          "driver" => "claudeAgent",
          "enabled" => false,
          "config" => %{"homePath" => work}
        },
        "claude-personal" => %{"driver" => "claudeAgent", "config" => %{"homePath" => personal}}
      }
    })

    Map.put(context, :account_homes, [work, personal])
  end

  step "both accounts' history is counted", context do
    for home <- context.account_homes do
      assert %{"status" => "ok", "scannedFiles" => 1} =
               source(context.usage, "claude", Path.join(home, "projects"))
    end

    assert output(context.usage, "claude") == 500 + 111 + 222
    context
  end

  step "a Codex account whose CODEX_HOME points at {string}", %{args: [dir]} = context do
    home = home_path(context, dir)
    codex(home, "work", "gpt-5.6-sol", [codex_count(now() - 60_000, input: 10, output: 444)])

    World.merge_settings(%{
      "providerInstances" => %{
        "codex-work" => %{
          "driver" => "codex",
          "environment" => [%{"name" => "CODEX_HOME", "value" => home}]
        }
      }
    })

    context
  end

  step "history under {string} is counted", %{args: [dir]} = context do
    sessions = Path.join(home_path(context, dir), "sessions")
    assert %{"status" => "ok", "scannedFiles" => 1} = source(context.usage, "codex", sessions)
    assert output(context.usage, "codex") == 300 + 444
    context
  end

  step "two accounts that read the same history directory", context do
    {shared, context} = shared_history(context)

    World.merge_settings(%{
      "providerInstances" => %{
        "codex-a" => %{"driver" => "codex", "config" => %{"homePath" => shared}},
        "codex-b" => %{"driver" => "codex", "config" => %{"homePath" => shared}}
      }
    })

    context
  end

  step "two environments on the same machine that read the same history directory", context do
    {shared, context} = shared_history(context)
    # The second environment reaches the directory through a link, as another
    # checkout's server configured differently would.
    link = Path.join(context.mc.home, "codex-link")
    File.ln_s!(shared, link)

    World.merge_settings(%{
      "providerInstances" => %{
        "codex-a" => %{"driver" => "codex", "config" => %{"homePath" => shared}}
      }
    })

    Map.put(context, :second_home, link)
  end

  step "the user opens Usage with both environments selected", context do
    first = summary(context).usage

    World.merge_settings(%{
      "providerInstances" => %{"codex-a" => %{"config" => %{"homePath" => context.second_home}}}
    })

    second = summary(context).usage
    key = &source(&1, "codex", Path.join(context.shared_history.dir, "sessions"))["fingerprint"]
    assert key.(first) == key.(second)
    Map.put(context, :usage_summaries, [first, second])
  end

  # --- the scan cache ---------------------------------------------------------------------------

  step "the user opened Usage a minute ago", context do
    summary(context)
  end

  step "one transcript grew since", context do
    [path] = Path.wildcard(Path.join(context.usage_dirs.claude, "projects/*/main.jsonl"))
    context = World.trace_usage_reads(context)

    File.write!(path, JSON.encode!(claude_line("fable-2", now() - 60_000, output: 50)) <> "\n", [
      :append
    ])

    Map.put(context, :grown_transcript, %{path: path, provider: "claude"})
  end

  step "a transcript that was counted last week and has since been deleted by the CLI", context do
    at = noon(6)

    path =
      claude(context.usage_dirs.claude, "old", [
        claude_line("old-1", at, output: 666, session: "old")
      ])

    File.touch!(path, div(at, 1000))
    context = summary(context)
    assert day_output(context.usage, "claude", day(at)) == 666
    File.rm!(path)
    Map.put(context, :deleted_day, day(at))
  end

  step "last week's totals still include it", context do
    refute File.exists?(Path.join(context.usage_dirs.claude, "projects/old/old.jsonl"))
    assert day_output(context.usage, "claude", context.deleted_day) == 666
    context
  end

  step "the transcripts cannot be scanned", context do
    # A history folder the MC may not list.
    dir = Path.join(context.usage_dirs.claude, "projects")
    File.chmod!(dir, 0o000)
    ExUnit.Callbacks.on_exit(fn -> File.chmod(dir, 0o755) end)
    context
  end

  step "a turn recorded only the model family name {string}", %{args: [family]} = context do
    claude(context.usage_dirs.claude, "family", [
      claude_line("family-1", now() - 60_000, model: family, input: 1000, output: 1000)
    ])

    Map.put(context, :family, family)
  end

  step "that model is marked unpriced rather than priced at one generation's rate", context do
    assert %{"costSource" => "unpriced", "costUsd" => 0} =
             bucket(context.usage, "claude", context.family)

    context
  end

  step "a turn on a model recorded with a bracketed context-size suffix such as {string}",
       %{args: [suffix]} = context do
    model = "claude-sonnet" <> suffix

    claude(context.usage_dirs.claude, "wide", [
      claude_line("wide-1", now() - 60_000, model: model, input: 1000, output: 1000)
    ])

    Map.put(context, :wide_model, model)
  end

  step "that model is priced at the rate of its base model", context do
    assert %{"costSource" => "modelPriced", "costUsd" => cost} =
             bucket(context.usage, "claude", context.wide_model)

    assert_in_delta cost, 1000 * 1.0e-6 + 1000 * 2.0e-6, 1.0e-12
    context
  end

  # --- transcripts still being written, rewritten, or outside the window --------------------------

  step "a transcript whose last line has no line ending yet", context do
    path = claude(context.usage_dirs.claude, "partial", [])
    line = JSON.encode!(claude_line("partial-1", now() - 60_000, output: 321, session: "partial"))
    File.write!(path, line)
    Map.merge(context, %{partial: %{path: path, line: line}, expected_output: 500 + 321})
  end

  step "that unfinished line is counted in the totals", context do
    assert output(context.usage, "claude") == context.expected_output
    context
  end

  step "the CLI finishes the line and the user opens Usage again", context do
    File.write!(context.partial.path, "\n", [:append])
    summary(context)
  end

  step "the line is counted once", context do
    assert output(context.usage, "claude") == context.expected_output
    context
  end

  step "the user opened Usage and a transcript was read", context do
    path =
      claude(context.usage_dirs.claude, "rewrite", [
        claude_line("rw-1", now() - 90_000, output: 400, session: "rewrite"),
        claude_line("rw-2", now() - 80_000, output: 100, session: "rewrite")
      ])

    context = summary(context)
    assert output(context.usage, "claude") == 500 + 400 + 100
    Map.put(context, :rewritten, path)
  end

  step ~r/^the transcript was then (?<change>.+)$/, %{args: [change]} = context do
    lines =
      case change do
        # The same first line, the last bytes before the old end of file changed.
        "rewritten with different text but the same start" ->
          [
            claude_line("rw-1", now() - 90_000, output: 400, session: "rewrite"),
            claude_line("rw-3", now() - 70_000, output: 150, session: "rewrite"),
            claude_line("rw-4", now() - 60_000, output: 7, session: "rewrite")
          ]

        "replaced by a shorter file" ->
          [claude_line("rw-5", now() - 50_000, output: 300, session: "rewrite")]
      end

    File.write!(context.rewritten, Enum.map_join(lines, &(JSON.encode!(&1) <> "\n")))
    context = World.trace_usage_reads(context)

    Map.put(
      context,
      :expected_output,
      500 + Enum.sum(for l <- lines, do: l["message"]["usage"]["output_tokens"])
    )
  end

  step "the whole transcript is read again", context do
    path = context[:rewritten]
    # A rewrite that grew is offered to `Transcripts.read/3` with its old position, which
    # refuses it when the bytes before it changed; the totals below prove it read it whole.
    assert {^path, "claude", _resume} = List.keyfind(World.usage_reads(), path, 0)
    context
  end

  step "its earlier lines are not counted twice", context do
    assert output(context.usage, "claude") == context.expected_output
    context
  end

  step "the MC saved its scan of the history before it restarted", context do
    context = summary(context)
    assert File.exists?(Path.join(context.mc.home, "usage-scan-cache.bin"))
    ExUnit.Callbacks.stop_supervised!(HalC2.Usage)
    Mc.ensure(HalC2.Usage)
    World.trace_usage_reads(context)
  end

  step ~r/^the saved scan (?<damage>.+)$/, %{args: [damage]} = context do
    cache = Path.join(context.mc.home, "usage-scan-cache.bin")
    [main] = Path.wildcard(Path.join(context.usage_dirs.claude, "projects/main/*.jsonl"))

    case damage do
      "was written by an older version of the MC" ->
        saved = cache |> File.read!() |> :erlang.binary_to_term()
        File.write!(cache, :erlang.term_to_binary(%{saved | version: 0}))

      "is not readable" ->
        File.write!(cache, "not a saved scan")

      "has one entry that is damaged" ->
        saved = cache |> File.read!() |> :erlang.binary_to_term()
        files = Map.put(saved.files, main, %{})
        File.write!(cache, :erlang.term_to_binary(%{saved | files: files}))

      "has one entry whose records are damaged" ->
        saved = cache |> File.read!() |> :erlang.binary_to_term()
        files = Map.update!(saved.files, main, &%{&1 | records: [:not_a_record]})
        File.write!(cache, :erlang.term_to_binary(%{saved | files: files}))
    end

    Map.merge(context, %{damaged: damage, claude_main: main})
  end

  step "the affected transcripts are read from the start", context do
    reads = World.usage_reads()

    affected =
      if context.damaged =~ "has one entry",
        do: [context.claude_main],
        else: Path.wildcard(Path.join(context.mc.home, "{claude,codex,grok}/**/*.jsonl"))

    for path <- affected do
      assert {^path, _provider, nil} = List.keyfind(reads, path, 0)
    end

    if context.damaged =~ "has one entry",
      do: assert(length(reads) == 1, "undamaged entries stay cached: #{inspect(reads)}")

    context
  end

  step "the usage page is still shown", context do
    assert {:ok, %{"buckets" => [_ | _]}} = context.reply
    assert output(context.usage, "claude") == 500
    context
  end

  step "the user refreshed Usage and prices were fetched ten seconds ago", context do
    context = snapshot(context, @rates, 10_000)
    {{:ok, pricing}, context} = World.call(context, "server.refreshUsageRates")
    assert pricing["status"] == "cached"

    # The source now knows another model; it would show if the table were fetched.
    File.write!(
      Path.join(context.mc.home, "rates.json"),
      JSON.encode!(
        Map.put(@rates, "anthropic/claude-new-1", %{
          "input_cost_per_token" => 1.0e-6,
          "output_cost_per_token" => 1.0e-6
        })
      )
    )

    Map.put(context, :pricing_before, pricing)
  end

  step "the user refreshes Usage again", context do
    {reply, context} = World.call(context, "server.refreshUsageRates")
    Map.put(context, :reply, reply)
  end

  step "the price table is not fetched again", context do
    assert {:ok, pricing} = context.reply
    assert pricing == context.pricing_before
    context
  end

  step "an ordinary open of Usage never fetches inside the daily refresh", context do
    context = summary(context)
    assert context.usage["pricing"] == context.pricing_before
    context
  end

  step "a Claude transcript last changed 30 hours before the window began, holding records from before and inside the window",
       context do
    started = window_start()

    path =
      claude(context.usage_dirs.claude, "near", [
        claude_line("near-1", started - 3_600_000, output: 111, session: "near"),
        claude_line("near-2", started + 3_600_000, output: 222, session: "near")
      ])

    File.touch!(path, div(started - 30 * 3_600_000, 1000))
    context = World.trace_usage_reads(context)
    Map.merge(context, %{near: path, expected_output: 500 + 222})
  end

  step "another transcript last changed 40 hours before the window began", context do
    started = window_start()

    path =
      claude(context.usage_dirs.claude, "far", [
        claude_line("far-1", started + 7_200_000, output: 333, session: "far")
      ])

    File.touch!(path, div(started - 40 * 3_600_000, 1000))
    Map.put(context, :far, path)
  end

  step "the user opens Usage for that window", context do
    summary(context)
  end

  step "the first transcript is read and only its records inside the window are counted",
       context do
    assert List.keyfind(World.usage_reads(), context.near, 0)
    assert output(context.usage, "claude") == context.expected_output
    context
  end

  step "the second transcript is not opened", context do
    refute List.keyfind(World.usage_reads(), context.far, 0)
    context
  end

  step "a Codex rollout was copied into another folder", context do
    at = now() - 60_000

    original =
      codex(context.usage_dirs.codex, "moved", "gpt-5.6-sol", [codex_count(at, output: 321)])

    copy = Path.join(context.usage_dirs.codex, "sessions/archive/rollout-moved.jsonl")
    File.mkdir_p!(Path.dirname(copy))
    File.cp!(original, copy)
    context
  end

  step "one rollout has two token counts with identical time, model and totals", context do
    at = now() - 50_000

    codex(context.usage_dirs.codex, "twin", "gpt-5.6-sol", [
      codex_count(at, output: 40),
      codex_count(at + 1000, output: 5),
      codex_count(at, output: 40)
    ])

    context
  end

  step "each event of the copied rollout is counted once", context do
    assert output(context.usage, "codex") == 300 + 321 + 40 + 5 + 40
    context
  end

  step "the two identical events inside a single rollout are both counted", context do
    # The Background's 300 and the copied rollout's 321 are the other contributors.
    codex = output(context.usage, "codex")
    assert codex - 300 - 321 == 40 + 5 + 40
    context
  end

  step "a Grok session folder with {string} and other JSONL files", %{args: [name]} = context do
    folder =
      Path.dirname(
        grok(context.usage_dirs.grok, "folder", [
          grok_completed("p1", now() - 60_000, "grok-4", input: 10, output: 20)
        ])
      )

    assert Path.basename(Path.join(folder, name)) == name

    for other <- ["events.jsonl", "prompts.jsonl"] do
      File.write!(
        Path.join(folder, other),
        JSON.encode!(grok_completed("px", now() - 60_000, "grok-4", input: 10, output: 9999)) <>
          "\n"
      )
    end

    context
  end

  step "only {string} contributes to the totals", context do
    assert output(context.usage, "grok") == 200 + 20
    context
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp summary(context, input \\ nil) do
    today = day(now())

    input =
      input ||
        %{"sinceDay" => day(now() - 6 * 86_400_000), "untilDay" => today, "timeZone" => "UTC"}

    {reply, context} = World.call(context, "server.getUsageSummary", input)

    case reply do
      {:ok, usage} -> Map.merge(context, %{reply: reply, usage: usage})
      _ -> Map.put(context, :reply, reply)
    end
  end

  defp save_prices(context, prices) do
    {%{"settings" => settings, "version" => version}, context} =
      World.call!(context, "hal-c2.readSettings")

    settings = Map.update(settings, "usagePriceOverrides", prices, &Map.merge(&1, prices))

    {_, context} =
      World.call!(context, "hal-c2.writeSettings", %{"settings" => settings, "version" => version})

    context
  end

  # A Codex history of one turn on "gpt-shared", which the scenario's accounts share
  # (`:shared_history`, read by "that history is counted once").
  defp shared_history(context) do
    dir = Path.join(context.mc.home, "codex-shared")
    codex(dir, "shared", "gpt-shared", [codex_count(now() - 60_000, input: 10, output: 555)])

    {dir,
     Map.put(context, :shared_history, %{
       dir: dir,
       provider: "codex",
       model: "gpt-shared",
       output_tokens: 555
     })}
  end

  defp snapshot(context, rates, age_ms) do
    File.write!(
      Path.join(context.mc.home, "usage-model-rates.json"),
      JSON.encode!(%{"fetchedAtMs" => now() - age_ms, "document" => rates})
    )

    context
  end

  defp rates_url(url), do: World.put_app_env(:usage_rates_url, url)

  defp home_path(context, "~/" <> rest), do: Path.join(context.mc.home, rest)

  defp bucket(usage, provider, model) do
    case buckets(usage, provider, model, nil) do
      [bucket] -> bucket
      other -> flunk("expected one #{provider} #{model} bucket, got #{inspect(other)}")
    end
  end

  defp buckets(usage, provider, model, day) do
    for b <- usage["buckets"],
        b["provider"] == provider,
        b["model"] == model,
        day in [nil, b["day"]],
        do: b
  end

  defp output(usage, provider),
    do:
      Enum.sum(
        for b <- usage["buckets"], b["provider"] == provider, do: b["totals"]["outputTokens"]
      )

  defp day_output(usage, provider, day),
    do:
      Enum.sum(
        for b <- usage["buckets"],
            b["provider"] == provider,
            b["day"] == day,
            do: b["totals"]["outputTokens"]
      )

  defp source(usage, provider, dir) do
    {real, 0} = System.cmd("realpath", ["-m", dir])
    real = String.trim(real)

    Enum.find(
      usage["sources"],
      &(&1["fingerprint"]["provider"] == provider and
          &1["fingerprint"]["resolvedHomePath"] == real)
    ) ||
      flunk("no #{provider} source for #{real}: #{inspect(usage["sources"])}")
  end

  defp claude(home, name, lines) do
    path = Path.join([home, "projects", name, "#{name}.jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, &(JSON.encode!(&1) <> "\n")))
    path
  end

  defp claude_line(id, at, opts) do
    %{
      "type" => "assistant",
      "timestamp" => iso(at),
      "requestId" => "req_#{id}",
      "sessionId" => opts[:session] || "main",
      "costUSD" => opts[:cost],
      "message" => %{
        "id" => "msg_#{id}",
        "model" => opts[:model] || "claude-fable-5",
        "content" => [%{"type" => "text"}],
        "usage" => %{
          "input_tokens" => Keyword.get(opts, :input, 10),
          "cache_read_input_tokens" => opts[:cached] || 0,
          "cache_creation_input_tokens" => opts[:created] || 0,
          "output_tokens" => opts[:output]
        }
      }
    }
  end

  defp codex(home, name, model, counts) do
    path = Path.join([home, "sessions", "2026", "09", "26", "rollout-#{name}.jsonl"])
    File.mkdir_p!(Path.dirname(path))
    meta = %{"type" => "session_meta", "payload" => %{"id" => "codex-#{name}"}}
    turn = %{"type" => "turn_context", "payload" => %{"model" => model}}
    File.write!(path, Enum.map_join([meta, turn | counts], &(JSON.encode!(&1) <> "\n")))
    path
  end

  defp codex_count(at, opts) do
    %{
      "type" => "event_msg",
      "timestamp" => iso(at),
      "payload" => %{
        "type" => "token_count",
        "info" => %{
          "last_token_usage" => %{
            "input_tokens" => opts[:input],
            "cached_input_tokens" => opts[:cached] || 0,
            "output_tokens" => opts[:output]
          }
        }
      }
    }
  end

  defp grok(home, session, lines) do
    path = Path.join([home, "sessions", session, "updates.jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, &(JSON.encode!(&1) <> "\n")))
    path
  end

  defp grok_completed(prompt, at, model, opts) do
    usage = %{"inputTokens" => opts[:input], "outputTokens" => opts[:output]}

    %{
      "params" => %{
        "sessionId" => "grok-#{prompt}-#{at}",
        "update" => %{
          "sessionUpdate" => "turn_completed",
          "prompt_id" => prompt,
          "usage" => Map.put(usage, "modelUsage", %{model => usage})
        },
        "_meta" => %{"agentTimestampMs" => at}
      }
    }
  end

  # Midnight UTC of the first day of the last-seven-days window.
  defp window_start do
    Date.add(Date.utc_today(), -6)
    |> DateTime.new!(~T[00:00:00])
    |> DateTime.to_unix(:millisecond)
  end

  defp now, do: System.system_time(:millisecond)

  defp noon(days_ago),
    do:
      DateTime.new!(Date.add(Date.utc_today(), -days_ago), ~T[12:00:00])
      |> DateTime.to_unix(:millisecond)

  defp day(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
