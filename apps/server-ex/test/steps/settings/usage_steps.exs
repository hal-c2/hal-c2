defmodule T3.Steps.Settings.Usage do
  @moduledoc """
  Settings → Usage against a node: the usage summary read from the provider CLIs'
  transcripts (`server.getUsageSummary`), model prices (`server.refreshUsageRates`,
  `usagePriceOverrides`), and the Codex and Claude limits published on the provider
  entries (`T3.ProviderUsageLimits`, driven by `test/support/fake_codex.py` and
  `fake_claude.py`).

  Every provider home lives under the scenario's home, so nothing reads the
  machine's own `~/.codex`, `~/.claude` or `~/.grok`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias T3.ProviderUsageLimits, as: Limits
  alias T3.Test.Node
  alias T3.Test.Node.World

  @fake_codex Path.expand("../../support/fake_codex.py", __DIR__)
  @fake_claude Path.expand("../../support/fake_claude.py", __DIR__)

  # The model rates a price fetch serves (LiteLLM's shape), USD per token.
  @rates %{
    "anthropic/claude-fable-5" => %{
      "input_cost_per_token" => 0.000003,
      "output_cost_per_token" => 0.000015,
      "cache_read_input_token_cost" => 0.0000003
    },
    "openai/gpt-5.6-sol" => %{
      "input_cost_per_token" => 0.000002,
      "output_cost_per_token" => 0.00001,
      "cache_read_input_token_cost" => 0.0000002
    }
  }

  # --- history -------------------------------------------------------------------

  step "Codex, Claude Code and Grok have session history on the machine", context do
    context = usage(context)
    day = yesterday()

    write(claude_dir(context), "a.jsonl", claude_line(1, 100, at: at(day, "12:00"), cached: 500))

    write(
      codex_dir(context, day),
      "rollout-a.jsonl",
      codex_lines("codex-1", [40, 60], at(day, "12:00"))
    )

    write(
      Path.join([context.usage.grok, "sessions", "g-1"]),
      "updates.jsonl",
      grok_line("g-1", "p-1", at(day, "12:00"))
    )

    context
  end

  step "Claude Code keeps its history under a custom config directory", context do
    custom = Path.join(context.node.home, "custom-claude")

    context =
      usage(context, %{
        "providers" => %{"claudeAgent" => %{"homePath" => ""}},
        "providerInstances" => %{
          "claudeAgent" => %{
            "driver" => "claudeAgent",
            "environment" => [%{"name" => "CLAUDE_CONFIG_DIR", "value" => custom}]
          }
        }
      })

    write(Path.join([custom, "projects", "proj"]), "a.jsonl", claude_line(1, 21))
    Map.put(context, :history, %{provider: "claude", output: 21, dir: "custom-claude/projects"})
  end

  step "two Codex accounts point at the same history directory", context do
    shared = Path.join(context.node.home, "shared-codex")
    instance = &%{"driver" => "codex", "config" => %{"homePath" => shared}, "label" => &1}

    context =
      usage(context, %{
        "providerInstances" => %{
          "codex" => instance.("Personal"),
          "codex-work" => instance.("Work")
        }
      })

    write(
      Path.join([shared, "sessions", "2026", "01", "01"]),
      "rollout-a.jsonl",
      codex_lines("codex-1", [13, 17], at(yesterday(), "12:00"))
    )

    Map.put(context, :history, %{provider: "codex", output: 30})
  end

  step "a Claude session was resumed into a new transcript", context do
    context = usage(context)
    dir = claude_dir(context)
    # The resumed transcript starts with a copy of the first session's turns.
    write(dir, "a.jsonl", claude_line(1, 5) <> claude_line(2, 7))

    write(
      dir,
      "b.jsonl",
      claude_line(1, 5, session: "session-2") <>
        claude_line(2, 7, session: "session-2") <> claude_line(3, 11, session: "session-2")
    )

    Map.put(context, :history, %{provider: "claude", output: 5 + 7 + 11})
  end

  # The first line sits more than the resume guard (64 bytes) before the end, so a
  # changed first line is only seen by a scan that reads the whole file again.
  step "the node has scanned the history once", context do
    context = usage(context)
    path = Path.join(claude_dir(context), "a.jsonl")
    filler = JSON.encode!(%{"type" => "user", "text" => String.duplicate("x", 200)}) <> "\n"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, claude_line(1, 5) <> filler)
    context = summary(context)
    assert World.usage_output(context.summary, "claude") == 5
    Map.put(context, :transcript, path)
  end

  step "one transcript has grown since", context do
    path = context.transcript
    # Same length, different count: visible only if the old line is parsed again.
    old = File.read!(path)
    File.write!(path, String.replace(old, ~s("output_tokens":5), ~s("output_tokens":9)))
    File.write!(path, claude_line(2, 7), [:append])
    Map.put(context, :history, %{provider: "claude", output: 5 + 7})
  end

  step "a transcript that was scanned and then removed by its CLI", context do
    context = usage(context)
    path = Path.join(claude_dir(context), "a.jsonl")
    write(Path.dirname(path), "a.jsonl", claude_line(1, 8))
    context = summary(context)
    assert World.usage_output(context.summary, "claude") == 8
    File.rm!(path)
    Map.put(context, :history, %{provider: "claude", output: 8})
  end

  # --- reading -------------------------------------------------------------------

  step ~r/^a client asks for the usage summary(?: again| within 90 days)?$/, context do
    summary(context)
  end

  step "a client asks for daily usage in {string}", %{args: [zone]} = context do
    context = usage(context)
    day = yesterday()
    # Either side of UTC midnight.
    write(
      claude_dir(context),
      "a.jsonl",
      claude_line(1, 3, at: at(day, "23:30")) <>
        claude_line(2, 4, at: at(Date.add(day, 1), "00:30"))
    )

    summary(context, %{"timeZone" => zone})
  end

  step "a client asks for hourly usage in {string}", %{args: [zone]} = context do
    context = usage(context)
    # As the clients ask for the past 24 hours: minute-aligned bounds.
    until = DateTime.utc_now() |> DateTime.truncate(:second) |> Map.put(:second, 0)
    since = DateTime.add(until, -24, :hour)

    write(
      claude_dir(context),
      "a.jsonl",
      claude_line(1, 3, at: iso(DateTime.add(since, 10, :minute))) <>
        claude_line(2, 4, at: iso(DateTime.add(since, 70, :minute)))
    )

    context
    |> Map.put(:since_time, since)
    |> summary(%{
      "timeZone" => zone,
      "resolution" => "hour",
      "sinceTime" => iso(since),
      "untilTime" => iso(until)
    })
  end

  step "the summary has tokens, cache savings and estimated cost per model", context do
    buckets = context.summary["buckets"]

    for {provider, model} <- [
          {"claude", "claude-fable-5"},
          {"codex", "gpt-5.6-sol"},
          {"grok", "grok-4"}
        ] do
      assert %{"totals" => totals, "costUsd" => cost} =
               Enum.find(buckets, &(&1["provider"] == provider and &1["model"] == model)),
             "no #{provider} #{model} bucket in #{inspect(buckets)}"

      assert totals["outputTokens"] > 0
      assert cost > 0
    end

    # Claude read 500 tokens from cache at a tenth of the input price.
    claude = Enum.find(buckets, &(&1["model"] == "claude-fable-5"))
    assert_in_delta claude["cacheSavingsUsd"], 500 * (0.000003 - 0.0000003), 1.0e-12
    assert context.summary["pricing"]["status"] == "fresh"
    context
  end

  step "that history is counted", context do
    %{provider: provider, output: output} = context.history
    assert World.usage_output(context.summary, provider) == output

    assert Enum.any?(
             context.summary["sources"],
             &(&1["fingerprint"]["provider"] == provider and
                 String.ends_with?(&1["fingerprint"]["resolvedHomePath"], context.history.dir))
           ),
           "no #{provider} source at #{context.history.dir} in #{inspect(context.summary["sources"])}"

    context
  end

  step "the repeated turns count once", context do
    assert World.usage_output(context.summary, "claude") == context.history.output
    [claude] = for b <- context.summary["buckets"], b["provider"] == "claude", do: b
    assert claude["records"] == 3
    context
  end

  step "its usage is still counted", context do
    assert World.usage_output(context.summary, "claude") == context.history.output
    context
  end

  step ~r/^the buckets start at (?<boundary>midnight|each hour from the window start) in "(?<zone>[^"]+)"$/,
       %{args: [boundary, zone]} = context do
    buckets = context.summary["buckets"]
    assert context.summary["timeZone"] == zone

    case boundary do
      "midnight" ->
        day = yesterday()

        assert for(b <- buckets, do: {b["day"], b["totals"]["outputTokens"]}) == [
                 {Date.to_iso8601(day), 3},
                 {Date.to_iso8601(Date.add(day, 1)), 4}
               ]

      _ ->
        since = context.since_time

        assert for(b <- buckets, do: b["hourStart"]) == [
                 iso(since),
                 iso(DateTime.add(since, 1, :hour))
               ]

        # Each hour sits on the zone's calendar day it starts in.
        for bucket <- buckets do
          {:ok, start, _} = DateTime.from_iso8601(bucket["hourStart"])
          {:ok, local} = DateTime.shift_zone(start, zone, Tz.TimeZoneDatabase)
          assert bucket["day"] == Date.to_iso8601(DateTime.to_date(local))
        end
    end

    context
  end

  step "the buckets are in UTC", context do
    day = yesterday()

    assert for(b <- context.summary["buckets"], do: b["day"]) == [
             Date.to_iso8601(day),
             Date.to_iso8601(Date.add(day, 1))
           ]

    context
  end

  # --- prices --------------------------------------------------------------------

  step "the node fetched model prices yesterday", context do
    context = usage(context)
    fetched = System.system_time(:millisecond) - 25 * 60 * 60 * 1000

    File.write!(
      Path.join(context.node.home, "usage-model-rates.json"),
      JSON.encode!(%{"fetchedAtMs" => fetched, "document" => @rates})
    )

    write(claude_dir(context), "a.jsonl", claude_line(1, 1000))
    Map.put(context, :fetched_at, fetched)
  end

  step "the machine is offline", context do
    World.put_app_env(:usage_rates_url, Path.join(context.node.home, "unreachable.json"))
    context
  end

  step "costs use the saved prices", context do
    assert %{"status" => "cached", "knownModels" => known, "fetchedAt" => fetched} =
             context.summary["pricing"]

    assert known >= 2
    {:ok, at, _} = DateTime.from_iso8601(fetched)
    assert DateTime.to_unix(at, :millisecond) == context.fetched_at

    bucket = Enum.find(context.summary["buckets"], &(&1["model"] == "claude-fable-5"))
    assert bucket["costSource"] == "modelPriced"
    assert_in_delta bucket["costUsd"], 10 * 0.000003 + 1000 * 0.000015, 1.0e-12
    context
  end

  # The node read a smaller table two minutes ago; the source now has more models.
  step "the user refreshes usage prices", context do
    context = usage(context)
    stale = System.system_time(:millisecond) - 2 * 60 * 1000
    [first | _] = Map.keys(@rates)

    File.write!(
      Path.join(context.node.home, "usage-model-rates.json"),
      JSON.encode!(%{"fetchedAtMs" => stale, "document" => Map.take(@rates, [first])})
    )

    {reply, context} = World.call(context, "server.refreshUsageRates")
    Map.merge(context, %{reply: reply, stale_at: stale})
  end

  step "the node fetches the latest model prices", context do
    assert {:ok, %{"status" => "fresh", "knownModels" => known, "fetchedAt" => fetched}} =
             context.reply

    assert known == map_size(@rates) + 2
    {:ok, at, _} = DateTime.from_iso8601(fetched)
    assert DateTime.to_unix(at, :millisecond) > context.stale_at
    context
  end

  step "the user saved a price for {string} of {int} USD input and {int} USD output per million tokens",
       %{args: [model, input, output]} = context do
    context =
      usage(context, %{
        "usagePriceOverrides" => %{
          model => %{
            "inputCostPerMillionTokens" => input,
            "outputCostPerMillionTokens" => output
          }
        }
      })

    # The CLI reported its own cost; the saved price replaces it.
    write(claude_dir(context), "a.jsonl", claude_line(1, 1000, model: model, cost: 5.0))
    Map.put(context, :price, {model, input, output})
  end

  step "{string} costs are estimated at those rates", %{args: [model]} = context do
    {^model, input, output} = context.price
    bucket = Enum.find(context.summary["buckets"], &(&1["model"] == model))
    assert bucket["costSource"] == "modelPriced"
    # 10 input and 1000 output tokens per line.
    assert_in_delta bucket["costUsd"], (10 * input + 1000 * output) / 1_000_000, 1.0e-12
    context
  end

  # --- limits --------------------------------------------------------------------

  step "a client refreshes providers", context do
    context = limits(context)
    before = Map.new(~w(codex claudeAgent), &{&1, Limits.get(&1)["checkedAt"]})
    {reply, context} = World.call(context, "server.refreshProviders")
    Map.merge(context, %{reply: reply, checked_before: before})
  end

  step "the node checks Codex and Claude rate limits", context do
    {:ok, %{"providers" => providers}} = context.reply

    for instance <- ~w(codex claudeAgent) do
      assert %{"usageLimits" => %{"checkedAt" => checked, "windows" => [_ | _]}} =
               Enum.find(providers, &(&1["instanceId"] == instance)),
             "#{instance} has no limits in #{inspect(providers)}"

      assert checked > context.checked_before[instance]
    end

    context
  end

  step "Codex limits were read an hour ago", context do
    context = limits(context)
    hour_ago = World.iso_from_now(-60 * 60 * 1000)
    known = %{Limits.get("codex") | "checkedAt" => hour_ago}
    # The published limits live in the service's own table.
    :sys.replace_state(Limits, fn state ->
      :ets.insert(Limits, {"codex", known})
      state
    end)

    Map.put(context, :known, known)
  end

  step "the next limit check fails", context do
    World.put_app_env(:codex_command, ["python3", Path.join(context.node.home, "missing.py")])
    {reply, context} = World.call(context, "server.refreshProviders", %{"instanceId" => "codex"})
    Map.put(context, :reply, reply)
  end

  step "the last known Codex limits remain", context do
    assert {:ok, %{"providers" => providers}} = context.reply
    assert Limits.get("codex") == context.known
    # What a client reads next still carries the hour-old windows.
    for %{"instanceId" => "codex"} = entry <- providers,
        do: assert(entry["usageLimits"] == context.known)

    context
  end

  step "Claude is signed in with an API key", context do
    World.put_env("FAKE_CLAUDE_USAGE", "unsupported")
    limits(context)
  end

  step "Claude limits are reported as unsupported", context do
    {{:ok, %{"providers" => providers}}, context} = World.call(context, "server.refreshProviders")

    assert %{"usageLimits" => %{"windows" => [], "unavailable" => %{"reason" => "unsupported"}}} =
             Enum.find(providers, &(&1["instanceId"] == "claudeAgent"))

    context
  end

  step ~r/^a Codex account (?<credits>with one banked reset credit|with no reset credits left|whose credit another device redeemed)$/,
       %{args: [credits]} = context do
    {count, outcome} =
      case credits do
        "with one banked reset credit" -> {"1", "reset"}
        "with no reset credits left" -> {"0", "noCredit"}
        "whose credit another device redeemed" -> {"1", "alreadyRedeemed"}
      end

    World.put_env("FAKE_CODEX_RESET_CREDITS", count)
    World.put_env("FAKE_CODEX_CONSUME_OUTCOME", outcome)
    context = limits(context)
    assert %{"availableCount" => available} = Limits.get("codex")["resetCredits"]
    assert available == String.to_integer(count)
    context
  end

  # What the clients show for each outcome (`OUTCOME_TEXT` in the web and mobile
  # usage limits); the node answers with the outcome.
  @outcome_text %{
    "reset" => "Reset applied. Your windows have cleared.",
    "nothingToReset" => "Nothing to reset right now.",
    "noCredit" => "No reset credit left.",
    "alreadyRedeemed" => "That credit was already redeemed."
  }

  step "the user uses a reset credit", context do
    {reply, context} =
      World.call(context, "provider.consumeResetCredit", %{"instanceId" => "codex"})

    reply =
      case reply do
        {:ok, %{"outcome" => outcome} = result} ->
          {:ok, Map.put(result, "shown", Map.fetch!(@outcome_text, outcome))}

        other ->
          other
      end

    assert [_key] =
             context.node.home |> Path.join("consumed") |> File.read!() |> String.split()

    Map.put(context, :reply, reply)
  end

  # --- helpers -------------------------------------------------------------------

  # Settings and the usage service, with every provider home under the scenario's
  # home and the price table served from a file there.
  defp usage(context, patch \\ %{}) do
    if context[:usage] do
      context
    else
      home = context.node.home
      homes = %{codex: Path.join(home, "codex"), claude: Path.join(home, "claude")}
      grok = Path.join(home, "grok")
      rates = Path.join(home, "rates.json")
      File.write!(rates, JSON.encode!(@rates))
      World.put_app_env(:usage_rates_url, rates)

      base = %{
        "providers" => %{
          "codex" => %{"homePath" => homes.codex},
          "claudeAgent" => %{"homePath" => homes.claude}
        },
        "providerInstances" => %{
          "grok" => %{
            "driver" => "grok",
            "environment" => [%{"name" => "GROK_HOME", "value" => grok}]
          }
        }
      }

      context = World.update_settings(context, World.deep_merge(base, patch))
      Node.ensure(T3.Usage)
      Map.put(context, :usage, Map.put(homes, :grok, grok))
    end
  end

  # The provider limits service on the fake Codex and Claude, after its boot probe.
  defp limits(context) do
    World.put_app_env(:codex_command, ["python3", @fake_codex])
    World.put_app_env(:claude_command, ["python3", @fake_claude])
    World.put_env("FAKE_CODEX_CONSUME_LOG", Path.join(context.node.home, "consumed"))
    Node.ensure(T3.Settings)
    Node.ensure(Limits)
    :ok = Limits.refresh([])
    assert Limits.get("codex") && Limits.get("claudeAgent")
    context
  end

  defp summary(context, input \\ %{}) do
    today = Date.utc_today()

    input =
      Map.merge(
        %{
          "sinceDay" => Date.to_iso8601(Date.add(today, -3)),
          "untilDay" => Date.to_iso8601(Date.add(today, 1)),
          "timeZone" => "UTC"
        },
        input
      )

    {{:ok, summary}, context} = World.call(context, "server.getUsageSummary", input)
    Map.put(context, :summary, summary)
  end

  defp claude_dir(context), do: Path.join([context.usage.claude, "projects", "proj"])

  defp codex_dir(context, day),
    do:
      Path.join([
        context.usage.codex,
        "sessions",
        pad(day.year, 4),
        pad(day.month, 2),
        pad(day.day, 2)
      ])

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  defp write(dir, name, text) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), text)
  end

  defp yesterday, do: Date.add(Date.utc_today(), -1)
  defp at(day, time), do: "#{Date.to_iso8601(day)}T#{time}:00Z"
  # As the node writes times: UTC with milliseconds.
  defp iso(at),
    do:
      at
      |> DateTime.to_unix(:millisecond)
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.to_iso8601()

  defp claude_line(id, output, opts \\ []) do
    JSON.encode!(%{
      "type" => "assistant",
      "timestamp" => opts[:at] || at(yesterday(), "12:00"),
      "requestId" => "req_#{id}",
      "sessionId" => opts[:session] || "session-1",
      "costUSD" => opts[:cost],
      "message" => %{
        "id" => "msg_#{id}",
        "model" => opts[:model] || "claude-fable-5",
        "content" => [%{"type" => "text"}],
        "usage" => %{
          "input_tokens" => 10,
          "cache_read_input_tokens" => opts[:cached] || 0,
          "output_tokens" => output
        }
      }
    }) <> "\n"
  end

  defp codex_lines(session, outputs, at) do
    meta = %{"type" => "session_meta", "payload" => %{"id" => session}}
    turn = %{"type" => "turn_context", "payload" => %{"model" => "gpt-5.6-sol"}}

    counts =
      for output <- outputs do
        %{
          "type" => "event_msg",
          "timestamp" => at,
          "payload" => %{
            "type" => "token_count",
            "info" => %{
              "last_token_usage" => %{
                "input_tokens" => 100,
                "cached_input_tokens" => 40,
                "output_tokens" => output
              }
            }
          }
        }
      end

    Enum.map_join([meta, turn | counts], &(JSON.encode!(&1) <> "\n"))
  end

  # A Grok Build turn: its cost in ticks (10^10 per dollar).
  defp grok_line(session, prompt, at) do
    {:ok, time, _} = DateTime.from_iso8601(at)

    JSON.encode!(%{
      "params" => %{
        "sessionId" => session,
        "_meta" => %{"agentTimestampMs" => DateTime.to_unix(time, :millisecond)},
        "update" => %{
          "sessionUpdate" => "turn_completed",
          "prompt_id" => prompt,
          "usage" => %{
            "modelUsage" => %{
              "grok-4" => %{
                "inputTokens" => 200,
                "cachedReadTokens" => 50,
                "outputTokens" => 30,
                "costUsdTicks" => 100_000_000
              }
            }
          }
        }
      }
    }) <> "\n"
  end
end
