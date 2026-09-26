defmodule HalC2.Connect.Secrets do
  @moduledoc """
  The node's HAL-C2 Connect secrets: one file per name at `<home>/secrets/<name>.bin`
  (owner-only), the layout the Node server's `ServerSecretStore` uses, so a home
  linked by either server stays linked.
  """

  @doc "The secret's bytes, or nil."
  def get(name) do
    case File.read(path(name)) do
      {:ok, bytes} -> bytes
      {:error, _} -> nil
    end
  end

  @doc "Writes a secret atomically."
  def put(name, value) when is_binary(value) do
    dir = dir()
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    tmp = Path.join(dir, ".#{name}.#{System.unique_integer([:positive])}.tmp")
    File.write!(tmp, value)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path(name))
    :ok
  end

  @doc "Creates a secret only if it does not exist: `:ok` or `:exists` (a replay guard)."
  def create(name, value) do
    File.mkdir_p!(dir())

    case File.open(path(name), [:write, :exclusive, :binary]) do
      {:ok, file} ->
        IO.binwrite(file, value)
        File.close(file)
        File.chmod(path(name), 0o600)
        :ok

      {:error, :eexist} ->
        :exists
    end
  end

  def delete(name) do
    File.rm(path(name))
    :ok
  end

  defp dir, do: Path.join(HalC2.Paths.data_dir(), "secrets")
  defp path(name), do: Path.join(dir(), name <> ".bin")
end
