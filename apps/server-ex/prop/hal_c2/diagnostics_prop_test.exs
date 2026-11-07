defmodule HalC2.DiagnosticsPropTest do
  @moduledoc """
  The laws of `HalC2.Diagnostics`' pure parts: a history request is always held to a window
  of one second to an hour with a bucket of one second up to that window, a counter only ever
  adds a non-negative amount that is at most its own movement, nothing across a long gap or a
  backwards step, and host CPU use is blank or within 0..1, and blank when the core count
  changed. The sampler process is covered by `features/mc/platform/diagnostics.feature`.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias HalC2.Diagnostics

  property "a history request is held to what the MC keeps" do
    forall {window, bucket} <-
             {oneof([non_neg_integer(), float()]), oneof([non_neg_integer(), float()])} do
      {window_used, bucket_used} = Diagnostics.history_bounds(window, bucket)

      window_used in 1_000..3_600_000 and bucket_used in 1_000..window_used and
        Diagnostics.history_bounds(window_used, bucket_used) == {window_used, bucket_used}
    end
  end

  property "a counter adds its movement, or nothing" do
    forall {earlier, later, gap} <- {non_neg_integer(), non_neg_integer(), non_neg_integer()} do
      added = Diagnostics.counter_delta(earlier, later, gap)

      added >= 0 and (added == 0 or (added == later - earlier and gap <= 60_000))
    end
  end

  property "CPU use is blank or a share, and blank across a change of cores" do
    forall {idle, total, cores} <- {non_neg_integer(), non_neg_integer(), pos_integer()} do
      first = {idle, total, cores}
      second = {idle + 40, total + 100, cores}
      share = Diagnostics.cpu_share(first, second)

      is_float(share) and share >= 0.0 and share <= 1.0 and
        Diagnostics.cpu_share(first, {idle + 40, total + 100, cores + 1}) == nil and
        Diagnostics.cpu_share(first, first) == nil
    end
  end

  property "a provider log keeps no credential, and redacting twice changes nothing" do
    forall {key, secret} <-
             {oneof(~w(authorization apiKey api_key accessToken password clientSecret)),
              non_empty(list(range(?a, ?z)))} do
      secret = "sk-" <> to_string(secret)

      event = %{
        "params" => %{
          key => %{"value" => secret},
          "list" => [%{"note" => "Bearer " <> secret}],
          "line" => "curl -H 'Authorization: Bearer " <> secret <> "' x"
        }
      }

      redacted = HalC2.ProviderLog.redact(event)

      not String.contains?(JSON.encode!(redacted), secret) and
        HalC2.ProviderLog.redact(redacted) == redacted
    end
  end
end
