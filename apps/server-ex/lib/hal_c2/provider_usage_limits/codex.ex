defmodule HalC2.ProviderUsageLimits.Codex do
  @moduledoc """
  Codex subscription usage.

  `account/rateLimits/read` and the `account/rateLimits/updated` notification carry
  the same snapshot, so `windows/1` serves the probe (`probe/1`) and a turn's update
  alike, and both land on the rows `primary` and `secondary`. `consume/2` redeems a
  reset credit (`account/rateLimitResetCredit/consume`). Each opens its own
  short-lived `codex app-server`.
  """

  alias HalC2.JsonRpc.Connection
  alias HalC2.ProviderUsageLimits, as: Limits

  @session 5 * 60
  @week 7 * 24 * 60
  @month 30 * 24 * 60

  def command(instance \\ "codex"), do: HalC2.Codex.Installation.command(instance)

  def installed?(instance \\ "codex") do
    case command(instance) do
      [executable | _] -> System.find_executable(executable) != nil
      _ -> false
    end
  end

  @doc """
  The main allowance's windows in a rate-limit snapshot. `primary` and `secondary`
  are positions, not durations: without `windowDurationMins`, paid plans have the
  five-hour and weekly pair and Free/Go one monthly allowance. Model-specific
  snapshots (such as Spark) describe another allowance and yield nothing.
  """
  def windows(%{} = snapshot) do
    if snapshot["limitId"] not in [nil, "", "codex"] do
      []
    else
      monthly = snapshot["planType"] in ["free", "go"]

      for {id, fallback} <- [
            {"primary", if(monthly, do: @month, else: @session)},
            {"secondary", @week}
          ],
          %{"usedPercent" => used} = window <- [snapshot[id]],
          is_number(used) do
        mins =
          if is_number(window["windowDurationMins"]),
            do: window["windowDurationMins"],
            else: fallback

        kind = kind(mins)

        %{
          "id" => id,
          "kind" => kind,
          "label" => label(kind),
          "usedPercent" => Limits.clamp(used),
          "windowDurationMins" => mins
        }
        |> Limits.put_present("resetsAt", Limits.iso_from_seconds(window["resetsAt"]))
      end
    end
  end

  def windows(_), do: []

  @doc "The `account/rateLimits/read` response as `ServerProviderUsageLimits`."
  def limits(response, checked_at) do
    snapshot = get_in(response, ["rateLimitsByLimitId", "codex"]) || response["rateLimits"]

    checked_at
    |> Limits.limits(windows(snapshot))
    |> Limits.put_present("resetCredits", reset_credits(response["rateLimitResetCredits"]))
  end

  defp reset_credits(%{"availableCount" => count} = summary) when is_integer(count) do
    expiries =
      for %{"status" => "available", "expiresAt" => at} <- summary["credits"] || [],
          is_number(at),
          do: at

    %{"availableCount" => max(0, count)}
    |> Limits.put_present(
      "nextExpiresAt",
      Limits.iso_from_seconds(Enum.min(expiries, fn -> nil end))
    )
  end

  defp reset_credits(_), do: nil

  @doc """
  The plan as the Codex provider labels it (`ChatGPT Pro 200 Subscription`), by
  the name OpenAI currently gives it. A plan a newer Codex names and this
  release does not know keeps its own name, so its account still reads as
  signed in on that plan; no plan at all labels nothing.
  """
  def plan_label(plan) do
    known_plan_label(plan) ||
      if(is_binary(plan) and String.trim(plan) != "", do: plan)
  end

  @doc "The label of a plan this release knows, or nil (no plan, or an unknown one)."
  def known_plan_label(plan) do
    case plan do
      "free" ->
        "ChatGPT Free Subscription"

      "go" ->
        "ChatGPT Go Subscription"

      "plus" ->
        "ChatGPT Plus Subscription"

      "pro" ->
        "ChatGPT Pro 200 Subscription"

      "prolite" ->
        "ChatGPT Pro 100 Subscription"

      "promax" ->
        "ChatGPT Pro 500 Subscription"

      "team" ->
        "ChatGPT Business Subscription"

      "self_serve_business_prolite" ->
        "ChatGPT Business Premium Subscription"

      p when p in ~w(self_serve_business_usage_based business) ->
        "ChatGPT Business Subscription"

      p when p in ~w(ent26 enterprise_cbp_automation enterprise_cbp_usage_based enterprise) ->
        "ChatGPT Enterprise Subscription"

      p when p in ~w(edu edu_plus edu_pro) ->
        "ChatGPT Edu Subscription"

      "unknown" ->
        "ChatGPT Subscription"

      _ ->
        nil
    end
  end

  defp kind(mins) when mins >= @month, do: "monthly"
  defp kind(mins) when mins >= @week, do: "weekly"
  defp kind(_), do: "session"

  defp label("session"), do: "Session"
  defp label("weekly"), do: "Weekly"
  defp label("monthly"), do: "Monthly"

  @doc """
  Reads the signed-in account's limits. An API key account has none (`unsupported`);
  a failed read is `probeFailed` with a short reason clients may show.
  """
  def probe(checked_at, instance \\ "codex") do
    with_app_server(instance, fn conn ->
      read = call(conn, "account/read", %{}, 10_000)

      with {:ok, %{"account" => %{} = account}} <- read,
           do: Limits.remember_account(instance, account(account))

      case read do
        {:ok, %{"account" => %{"type" => "apiKey"}}} ->
          Limits.unavailable(checked_at, "unsupported")

        {:ok, %{"account" => nil, "requiresOpenaiAuth" => true}} ->
          Limits.remember_account(instance, %{
            "status" => "unauthenticated",
            "message" => "Codex CLI is not authenticated. Run `codex login` and try again."
          })

          Limits.unavailable(checked_at, "probeFailed")

        {:ok, %{} = read_ok} ->
          # Usage is an enrichment with its own short deadline.
          case call(conn, "account/rateLimits/read", nil, 3_000) do
            {:ok, %{} = response} ->
              remember_usage_plan(instance, read_ok["account"] || %{}, response)
              limits(response, checked_at)

            failure ->
              Limits.unavailable(checked_at, "probeFailed", failure(failure))
          end

        failure ->
          Limits.unavailable(checked_at, "probeFailed", failure(failure))
      end
    end) ||
      Limits.unavailable(checked_at, "probeFailed", "Codex could not be started to read usage.")
  end

  # The plan in Codex's cached login can lag a downgrade: a plan its usage read
  # names (and this release knows) is the account's plan. A usage read naming
  # none, or one unknown here, leaves the login's label as it was.
  defp remember_usage_plan(instance, %{"type" => "chatgpt"} = acct, response) do
    snapshot = get_in(response, ["rateLimitsByLimitId", "codex"]) || response["rateLimits"]

    case snapshot && known_plan_label(snapshot["planType"]) do
      label when is_binary(label) ->
        Limits.remember_account(instance, Map.put(account(acct), "label", label))

      _ ->
        :ok
    end
  end

  defp remember_usage_plan(_instance, _account, _response), do: :ok

  @doc false
  # `auth` fields for the signed-in account.
  def account(%{"type" => "apiKey"}), do: %{"type" => "apiKey", "label" => "OpenAI API Key"}

  def account(%{"type" => "amazonBedrock"}),
    do: %{"type" => "amazonBedrock", "label" => "Amazon Bedrock"}

  def account(%{"type" => "chatgpt"} = account) do
    %{"type" => "chatgpt"}
    |> Limits.put_present("label", plan_label(account["planType"]))
    |> Limits.put_present("email", account["email"])
  end

  def account(_), do: %{}

  @doc "Redeems one of `instance`'s reset credits; `key` names the attempt, so a retry reuses it."
  def consume(key, instance \\ "codex") do
    with_app_server(instance, fn conn ->
      case call(conn, "account/rateLimitResetCredit/consume", %{"idempotencyKey" => key}, 20_000) do
        {:ok, %{"outcome" => outcome}}
        when outcome in ["reset", "nothingToReset", "noCredit", "alreadyRedeemed"] ->
          {:ok, outcome}

        other ->
          {:error, other}
      end
    end) || {:error, :spawn}
  end

  # Runs `fun` against a fresh, initialized app-server of `instance` (its executable
  # and its variables, such as CODEX_HOME); nil when it cannot start.
  defp with_app_server(instance, fun) do
    Process.flag(:trap_exit, true)
    env = Enum.to_list(HalC2.Settings.instance_env(instance))

    case Connection.start_link(cmd: command(instance), handler: self(), env: env) do
      {:ok, conn} ->
        try do
          with {:ok, _} <-
                 call(
                   conn,
                   "initialize",
                   %{
                     "clientInfo" => %{
                       "name" => "hal_c2_desktop",
                       "title" => "HAL-C2 Desktop",
                       "version" => "0.1.0"
                     },
                     "capabilities" => %{"experimentalApi" => true}
                   },
                   15_000
                 ) do
            Connection.notify(conn, "initialized", nil)
            fun.(conn)
          else
            _ -> nil
          end
        after
          stop(conn)
        end

      _ ->
        nil
    end
  end

  defp stop(conn) do
    Connection.stop(conn)
  catch
    :exit, _ -> :ok
  end

  defp call(conn, method, params, timeout) do
    Connection.call(conn, method, params, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :closed}
  end

  defp failure({:error, %{"code" => code}}), do: "Codex could not read usage (JSON-RPC #{code})."
  defp failure({:error, :closed}), do: "Codex exited before it could report usage."
  defp failure(_), do: "Codex did not answer the usage request."
end
