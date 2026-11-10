# HAL-C2's own checks only (credo/checks), not Credo's default suite: `mix credo`.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/"], excluded: []},
      requires: ["credo/checks/*.ex"],
      strict: true,
      checks: %{
        enabled: [
          {HalC2.Credo.WaitsInChangingCode, baseline: "credo/waits_baseline.exs"}
        ]
      }
    }
  ]
}
