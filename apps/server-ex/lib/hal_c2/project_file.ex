defmodule HalC2.ProjectFile do
  @moduledoc """
  A checkout's `hal-c2.json`, the shared defaults for everyone who opens it. A checkout
  that only has the `t3.json` from before the rename is read the same way.
  """

  @doc "The file's text, or `{:error, reason}` when the checkout has neither."
  def read(root) do
    with {:error, _} <- File.read(Path.join(root, "hal-c2.json")),
         do: File.read(Path.join(root, "t3.json"))
  end
end
