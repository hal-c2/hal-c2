defmodule HalC2Plugins.Maintenance.Report do
  @moduledoc """
  What a maintenance agent reports with `maintenance_report`, checked against its run,
  and the pull request body made of it.

  A report is a summary, one entry per category of the run (what was applied as
  commits, what was deferred with the command a human would run, and findings to
  discuss), and the gate the agent ran with its result. Every text in it is redacted
  of tokens, keys and private key blocks, and cut to a length, before it is kept:
  the report is shown on the page and becomes a pull request body.
  """

  @categories ~w(deps security-alerts docs-drift coverage-gaps)
  @results ~w(passed failed not-run)
  @titles %{
    "deps" => "Dependencies",
    "security-alerts" => "Security alerts",
    "docs-drift" => "Docs drift",
    "coverage-gaps" => "Coverage gaps"
  }
  # A field longer than this is summary enough; the body stays under GitHub's limit.
  @field_limit 4_000
  @body_limit 60_000
  @redacted "[redacted]"

  # Each pattern and what its match becomes. A private key block goes whole; a
  # `name = value` assignment keeps its name.
  @secrets [
    {~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s,
     "[redacted private key]"},
    {~r/\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/, @redacted},
    {~r/\bxox[abposr]-[A-Za-z0-9-]{10,}/, @redacted},
    {~r/\bxapp-[A-Za-z0-9-]{10,}/, @redacted},
    {~r/\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}/, @redacted},
    {~r/\bAKIA[0-9A-Z]{16}\b/, @redacted},
    {~r/\bglpat-[A-Za-z0-9_-]{20,}/, @redacted},
    {~r/\bnpm_[A-Za-z0-9]{36}\b/, @redacted},
    {~r/\b(Bearer|token)\s+[A-Za-z0-9._~+\/-]{20,}=*/i, "\\1 " <> @redacted},
    {~r/(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY))(\s*[:=]\s*)(?!\[redacted)["']?[^\s"']{6,}["']?/,
     "\\1\\2" <> @redacted}
  ]

  def categories, do: @categories
  def results, do: @results
  def title(category), do: @titles[category] || category

  @doc "`text` with every token, key and private key block in it replaced."
  def redact(text) when is_binary(text) do
    Enum.reduce(@secrets, text, fn {pattern, replacement}, text ->
      Regex.replace(pattern, text, replacement)
    end)
  end

  @doc """
  The report `arguments` give, checked against `run`: `{:ok, report}` with every text
  redacted and cut, or `{:error, message}` telling the agent what to fix. A run in
  report mode applies nothing; a report covers each category of its run, and only those.
  """
  def check(arguments, run) when is_map(arguments) do
    wanted = run["categories"]

    with {:ok, summary} <- text(arguments["summary"], "summary"),
         {:ok, entries} <- entries(arguments["categories"]),
         reported = Enum.map(entries, & &1["category"]),
         :ok <- only(reported, wanted),
         :ok <- all(reported, wanted),
         :ok <- applies(entries, run["mode"]),
         {:ok, gate} <- gate(arguments["gate"]) do
      ordered = Enum.sort_by(entries, &Enum.find_index(wanted, fn c -> c == &1["category"] end))
      {:ok, %{"summary" => summary, "categories" => ordered, "gate" => gate}}
    end
  end

  def check(_arguments, _run), do: {:error, "Report with an object."}

  @doc "How many commits a report says it applied."
  def applied(%{"categories" => entries}),
    do: Enum.reduce(entries, 0, &(&2 + length(&1["applied"])))

  def applied(_report), do: 0

  defp entries(list) when is_list(list) and list != [] do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case entry(entry) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        dupes =
          entries |> Enum.frequencies_by(& &1["category"]) |> Enum.filter(&(elem(&1, 1) > 1))

        if dupes == [],
          do: {:ok, entries},
          else: {:error, "Report each category once; #{elem(hd(dupes), 0)} is there twice."}

      error ->
        error
    end
  end

  defp entries(_list), do: {:error, "categories: report each category of this run."}

  defp entry(%{"category" => category} = entry) when category in @categories do
    with {:ok, applied} <- items(entry["applied"], "applied", "title", ["commit"]),
         {:ok, deferred} <- items(entry["deferred"], "deferred", "item", ["reason", "command"]),
         {:ok, findings} <- texts(entry["findings"], "findings"),
         :ok <- reasons(deferred, category) do
      {:ok,
       %{
         "category" => category,
         "applied" => applied,
         "deferred" => deferred,
         "findings" => findings
       }}
    end
  end

  defp entry(%{"category" => category}),
    do:
      {:error,
       "#{inspect(category)} is not a category; use one of #{Enum.join(@categories, ", ")}."}

  defp entry(_entry), do: {:error, "categories: each entry names its category."}

  # A deferred item says why, so the human reading the report can decide.
  defp reasons(deferred, category) do
    case Enum.find(deferred, &(&1["reason"] in [nil, ""])) do
      nil -> :ok
      item -> {:error, "#{category}: say why \"#{item["item"]}\" was deferred."}
    end
  end

  defp items(nil, _field, _key, _optional), do: {:ok, []}

  defp items(list, field, key, optional) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{^key => value} = item, {:ok, acc} when is_binary(value) and value != "" ->
        kept =
          for name <- optional, is_binary(item[name]) and item[name] != "", into: %{} do
            {name, clean(item[name])}
          end

        {:cont, {:ok, acc ++ [Map.put(kept, key, clean(value))]}}

      _item, _acc ->
        {:halt, {:error, "#{field}: give each item its #{key}."}}
    end)
  end

  defp items(_list, field, _key, _optional), do: {:error, "#{field}: give a list."}

  defp texts(nil, _field), do: {:ok, []}

  defp texts(list, field) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list |> Enum.reject(&(String.trim(&1) == "")) |> Enum.map(&clean/1)},
      else: {:error, "#{field}: give a list of texts."}
  end

  defp texts(_list, field), do: {:error, "#{field}: give a list of texts."}

  defp only(reported, wanted) do
    case reported -- wanted do
      [] ->
        :ok

      [extra | _] ->
        {:error, "#{extra} is not a category of this run; report on #{Enum.join(wanted, ", ")}."}
    end
  end

  defp all(reported, wanted) do
    case wanted -- reported do
      [] ->
        :ok

      missing ->
        {:error,
         "Report on every category of this run, #{Enum.join(missing, ", ")} too, even when it found nothing."}
    end
  end

  defp applies(entries, "report") do
    if Enum.all?(entries, &(&1["applied"] == [])),
      do: :ok,
      else:
        {:error,
         "This run is in report mode: it applies nothing. Move what you would apply to deferred, and leave the repository as it was."}
  end

  defp applies(_entries, _mode), do: :ok

  defp gate(%{"result" => result} = gate) when result in @results do
    command = if is_binary(gate["command"]), do: clean(gate["command"]), else: ""

    if command == "" and result != "not-run" do
      {:error, "gate: name the command you ran."}
    else
      details = if is_binary(gate["details"]), do: clean(gate["details"]), else: ""
      {:ok, %{"command" => command, "result" => result, "details" => details}}
    end
  end

  defp gate(_gate),
    do: {:error, "gate: give the gate command and its result (#{Enum.join(@results, ", ")})."}

  defp text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "#{field}: cannot be empty."}
      _ -> {:ok, clean(value)}
    end
  end

  defp text(_value, field), do: {:error, "#{field}: give it as text."}

  defp clean(text), do: text |> redact() |> cut(@field_limit)

  defp cut(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n… (cut)",
      else: text
  end

  @doc """
  The pull request body of a run's report: its summary, then per category what was
  applied, deferred with the command to run, and found, then the gate.
  """
  def markdown(report, run) do
    header = [
      "Maintenance of #{run["repository"]}, #{run["date"]}.",
      "",
      "Mode: #{run["mode"]}#{if run["securityOnly"], do: " (security advisories only)", else: ""} · Categories: #{Enum.join(run["categories"], ", ")}" <>
        if(run["branch"], do: " · Branch: `#{run["branch"]}`", else: ""),
      "",
      report["summary"]
    ]

    sections = Enum.flat_map(report["categories"], &section/1)
    gate = report["gate"]

    gate_lines =
      [
        "",
        "## Gate",
        "",
        if(gate["command"] == "",
          do: "Not run.",
          else: "`#{gate["command"]}`: #{gate["result"]}"
        )
      ] ++ if(gate["details"] == "", do: [], else: ["", gate["details"]])

    (header ++ sections ++ gate_lines)
    |> Enum.join("\n")
    |> cut(@body_limit)
  end

  defp section(entry) do
    applied =
      for item <- entry["applied"],
          do: "- #{item["title"]}" <> if(item["commit"], do: " (#{item["commit"]})", else: "")

    deferred =
      Enum.flat_map(entry["deferred"], fn item ->
        ["- #{item["item"]}: #{item["reason"]}"] ++
          if(item["command"], do: ["  `#{item["command"]}`"], else: [])
      end)

    findings = Enum.map(entry["findings"], &("- " <> &1))

    body =
      part("Applied", applied) ++ part("Deferred", deferred) ++ part("To discuss", findings)

    ["", "## #{title(entry["category"])}", ""] ++
      if(body == [], do: ["Nothing to do."], else: body)
  end

  defp part(_title, []), do: []
  defp part(title, lines), do: ["**#{title}**", "" | lines] ++ [""]
end
