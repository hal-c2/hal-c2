# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: The TokenEconomizer authors (microsoft/TokenEconomizer); HAL-C2 contributors
# Ported from tokeneconomizer/loopguard/judge.py and tokeneconomizer/plugin/judge.py
# (microsoft/TokenEconomizer@cb42207e3e09), into Elixir for HAL-C2's MC. Changed: both
# calls go to the user's text generation model (`HalC2.Plugins.Host.generate/3`), which
# answers an object, so the reply is not parsed out of free text; a job is a process of
# the plugin's, not a detached CLI, and its spend is the provider's token counts.

defmodule HalC2Plugins.TokenEconomizer.LoopGuard.Judge do
  @moduledoc """
  The loop guard's two paid calls: a stuck judge and a redirect writer.

  Both read the same leakage-safe digest of the agent's recent actions
  (`State.recent_digest/3`: commands, searches, edited file basenames, error signatures,
  never file contents or the task). A job (`run/3`) asks the judge, and the writer only
  when the verdict is stuck and sure enough to act on, so the redirect is ready when the
  verdict is read. Either call failing falls back to the free path: no verdict, or the
  count template.
  """

  @stuck_judge_system "You monitor an AI coding agent that is partway through ONE task in a software repo. " <>
                        "A cheap heuristic flagged its recent process as a possible UNPRODUCTIVE LOOP. Read " <>
                        "the leakage-safe digest of its RECENT actions and judge whether it is genuinely " <>
                        "STUCK — repeating the same kind of edit/test/failure with no progress toward green " <>
                        "tests, unlikely to recover if it keeps going the same way — versus still making " <>
                        "real progress (changing failures, narrowing the problem, exploring new hypotheses).\n\n" <>
                        "Judge ONLY the workflow from the digest; do NOT infer the task's solution or which " <>
                        "lines to change. Favor SPARING (stuck=false) when there is any sign of progress; " <>
                        "only return stuck=true with high confidence for a clear, repetitive dead-end.\n" <>
                        "Answer with stuck (true or false), confidence (a number from 0.0 to 1.0) and " <>
                        "reason (a short leakage-safe justification)."

  @nudge_writer_system "An AI coding agent is stuck in a REPETITIVE, UNPRODUCTIVE loop partway through one " <>
                         "task in a software repo. You are given a leakage-safe digest of its RECENT ACTIONS " <>
                         "only (tool names, shell commands, searched patterns, edited file BASENAMES, and " <>
                         "error SIGNATURES — never file contents or the task description). Write a SHORT " <>
                         "redirect (2-4 sentences) addressed to the agent that: (1) names the specific " <>
                         "repetitive pattern you actually see in the digest (e.g. re-editing the same file, " <>
                         "re-running the same test to the same failure); (2) proposes a MATERIALLY DIFFERENT " <>
                         "next step (a different file/root-cause to consider, re-reading the failing test's " <>
                         "expectation, verifying a new hypothesis before editing again).\n" <>
                         "HARD CONSTRAINTS: Do NOT tell it to stop, give up, or reduce effort — only redirect. " <>
                         "Do NOT infer the task's solution, name specific line numbers to change, or reference " <>
                         "any code/identifier you cannot see in the digest. Answer with text: only the " <>
                         "redirect, as plain text, with no preamble and no headings."

  @verdict_schema %{"stuck" => "boolean", "confidence" => "string", "reason" => "string"}
  @writer_schema %{"text" => "string"}

  @doc """
  The stuck judge: `%{"stuck" => true | false | nil, "confidence", "reason",
  "_tokens"}`, `stuck` nil when the call failed. `generate` is
  `HalC2.Plugins.Host.generate/3` bound to the plugin.
  """
  def stuck_judge(digest, generate) when is_binary(digest) and digest != "" do
    prompt =
      @stuck_judge_system <> "\n\nRecent process digest:\n" <> digest <> "\n\nReturn the verdict."

    case generate.(prompt, @verdict_schema) do
      {:ok, out, usage} ->
        %{
          "stuck" => if(is_boolean(out["stuck"]), do: out["stuck"]),
          "confidence" =>
            out["confidence"]
            |> HalC2Plugins.TokenEconomizer.LoopGuard.Rules.confidence()
            |> max(0.0)
            |> min(1.0),
          "reason" => String.slice(to_string(out["reason"] || ""), 0, 160),
          "_tokens" => tokens(usage)
        }

      {:error, message} ->
        %{
          "stuck" => nil,
          "confidence" => 0.0,
          "reason" => String.slice("error:#{message}", 0, 60),
          "_failed" => true,
          "_tokens" => 0
        }
    end
  end

  def stuck_judge(_, _),
    do: %{"stuck" => nil, "confidence" => 0.0, "reason" => "no-digest", "_tokens" => 0}

  @doc "The redirect writer: `%{\"text\", \"_tokens\"}`, text empty when the call failed."
  def nudge_writer(digest, generate) when is_binary(digest) and digest != "" do
    prompt =
      @nudge_writer_system <>
        "\n\nRecent process digest:\n" <> digest <> "\n\nWrite the redirect."

    # A reply with no words is still paid for; the redirect falls back to the template.
    case generate.(prompt, @writer_schema) do
      {:ok, out, usage} ->
        text = if is_map(out) and is_binary(out["text"]), do: String.trim(out["text"]), else: ""
        %{"text" => String.slice(text, 0, 1200), "_tokens" => tokens(usage)}

      _ ->
        %{"text" => "", "_tokens" => 0}
    end
  end

  def nudge_writer(_, _), do: %{"text" => "", "_tokens" => 0}

  @doc """
  One job: the judge, and the writer only when the verdict is stuck at `threshold` or
  more and a redirect can still be sent (`redirect`). The verdict, with the redirect in
  `"_nudge"` when one was written and both calls' spend in `"_tokens"`.
  """
  def run(digest, threshold, generate, redirect \\ true) do
    verdict = stuck_judge(digest, generate)

    if redirect and verdict["stuck"] == true and verdict["confidence"] >= threshold do
      written = nudge_writer(digest, generate)
      verdict = Map.update!(verdict, "_tokens", &(&1 + written["_tokens"]))
      if written["text"] != "", do: Map.put(verdict, "_nudge", written["text"]), else: verdict
    else
      verdict
    end
  end

  # `cachedInputTokens` is a part of `inputTokens` (`Host.generate/3`), not more of them.
  defp tokens(usage) when is_map(usage),
    do: Enum.sum(for key <- ~w(inputTokens outputTokens), is_number(usage[key]), do: usage[key])

  defp tokens(_), do: 0
end
