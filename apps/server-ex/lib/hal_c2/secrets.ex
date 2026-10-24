defmodule HalC2.Secrets do
  @moduledoc """
  The MC's named secrets, such as Slack's tokens: one owner-only file per name at
  `<data>/secrets/<name>.bin`, the layout earlier installs wrote.
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

  @doc "Deletes every secret whose name starts with `prefix`."
  def delete_prefixed(prefix) do
    for file <- Path.wildcard(Path.join(dir(), prefix <> "*.bin")), do: File.rm(file)
    :ok
  end

  defp dir, do: Path.join(HalC2.Paths.data_dir(), "secrets")
  defp path(name), do: Path.join(dir(), name <> ".bin")
end
