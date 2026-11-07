# Sobelow as a ratchet: fails on a finding sobelow_baseline.txt doesn't hold.
#
#     mix sobelow.check [--update]
#
# A finding is its rule and description, file and variable, without the line, so code
# moving inside a file changes nothing. The baseline counts each one, so a second unsafe
# `File.read` of the same variable in the same file is new too. A reviewed false positive
# gets a function-scoped `# sobelow_skip ["<Rule>"]` with a comment saying why (as in
# HalC2.Cluster), not a baseline line. `--update` rewrites the baseline after a fix, or
# after a finding has been reviewed and accepted; the diff is what the review reads.

baseline = Path.expand("../sobelow_baseline.txt", __DIR__)
out = Path.join(System.tmp_dir!(), "sobelow-#{System.unique_integer([:positive])}.json")

Mix.Task.run("sobelow", ~w(--root . --skip --private --no-router --format json --out #{out}))

findings =
  out
  |> File.read!()
  |> JSON.decode!()
  |> Map.fetch!("findings")
  |> Map.values()
  |> List.flatten()
  |> Enum.map(fn finding ->
    Enum.join([finding["type"], finding["file"], finding["variable"] || "-"], " | ")
  end)
  |> Enum.sort()

File.rm(out)

if "--update" in System.argv() do
  File.write!(baseline, Enum.map(findings, &[&1, ?\n]))
  IO.puts("Wrote #{length(findings)} findings to #{Path.relative_to_cwd(baseline)}.")
else
  known = baseline |> File.read!() |> String.split("\n", trim: true)
  # List subtraction removes one occurrence per element: a multiset difference.
  new = findings -- known
  gone = known -- findings

  for finding <- new, do: IO.puts("new: #{finding}")
  for finding <- gone, do: IO.puts("fixed: #{finding}")

  cond do
    new != [] ->
      Mix.raise("""
      Sobelow found #{length(new)} new finding(s). Fix them, mark a reviewed false positive \
      with a function-scoped `# sobelow_skip` and the reason, or accept them with \
      `mix sobelow.check --update`.
      """)

    gone != [] ->
      Mix.raise("""
      #{length(gone)} baseline finding(s) are gone. Tighten the ratchet with \
      `mix sobelow.check --update`.
      """)

    true ->
      IO.puts("Sobelow: no new findings (#{length(findings)} in the baseline).")
  end
end
