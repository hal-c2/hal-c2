defmodule HalC2.AcpSessionOptionsTest do
  use ExUnit.Case, async: true

  # Found by HalC2.AcpSessionOptionsPropTest: the second naming of an option was
  # offered although the first, a mode option, decides it.
  test "an option named twice is the one named first" do
    config = [
      %{"id" => "o1", "category" => "mode", "type" => "select", "options" => []},
      %{"id" => "o1", "type" => "select", "options" => [%{"value" => "plan", "name" => "plan"}]}
    ]

    assert HalC2.Acp.session_options(config) == []
  end
end
