defmodule HalC2.Web.AssetStreamAborted do
  @moduledoc """
  Raised by `HalC2.Web.Router` when a signed asset fails after its status line went
  out, so Bandit drops the connection rather than ending a short body normally.
  """
  defexception [:message, plug_status: 502]
end
