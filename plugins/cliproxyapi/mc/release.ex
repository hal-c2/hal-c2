defmodule HalC2Plugins.CliProxyApi.Release do
  @moduledoc """
  The CLIProxyAPI release the plugin runs when no `cli-proxy-api` is set or on PATH:
  version `@version`, pinned. It is downloaded once into the plugin's data folder,
  `bin/<version>/cli-proxy-api`, and only after its archive's SHA-256 matches the
  release's `checksums.txt`. A newer release is only ever announced, never
  downloaded: moving the pin is an update of the plugin.

  `config :hal_c2, :cliproxyapi, releases: url, path: dirs` points the download and
  the PATH lookup somewhere else, as the tests do.
  """

  @version "8.0.79"
  @releases "https://github.com/router-for-me/CLIProxyAPI/releases/download/v#{@version}"

  def version, do: @version

  @doc "The binary's name on this OS."
  def binary_name,
    do: if(match?({:win32, _}, :os.type()), do: "cli-proxy-api.exe", else: "cli-proxy-api")

  @doc "Where the downloaded binary lives in the data folder `dir`."
  def installed(dir), do: Path.join([dir, "bin", @version, binary_name()])

  @doc """
  The binary to run: `{:ok, path, source}` with `source` `"setting"`, `"path"` or
  `"download"`, `{:download, path}` when it has to be downloaded first, or
  `{:error, message}` when the one set cannot run.
  """
  def locate(setting, dir) do
    cond do
      setting not in [nil, ""] ->
        if executable?(setting),
          do: {:ok, setting, "setting"},
          else:
            {:error,
             "#{setting} (cli-proxy-api binary, in the plugin's settings) is not a file this machine can run."}

      found = on_path() ->
        {:ok, found, "path"}

      executable?(installed(dir)) ->
        {:ok, installed(dir), "download"}

      true ->
        {:download, installed(dir)}
    end
  end

  @doc """
  The release archive for this machine, such as `CLIProxyAPI_8.0.79_linux_amd64.tar.gz`,
  or `{:error, message}` on one the release has no build for.
  """
  def asset, do: asset(:os.type(), :erlang.system_info(:system_architecture))

  def asset(os, architecture) do
    arch = architecture |> to_string() |> String.split("-") |> hd()

    arch =
      cond do
        arch in ["x86_64", "amd64"] -> "amd64"
        arch in ["aarch64", "arm64"] -> "aarch64"
        true -> nil
      end

    case {os, arch} do
      {_, nil} ->
        {:error, "CLIProxyAPI has no release for #{architecture}."}

      {{:unix, :linux}, arch} ->
        {:ok, "CLIProxyAPI_#{@version}_linux_#{arch}.tar.gz"}

      {{:unix, :darwin}, arch} ->
        {:ok, "CLIProxyAPI_#{@version}_darwin_#{arch}.tar.gz"}

      {{:unix, :freebsd}, "amd64"} ->
        {:ok, "CLIProxyAPI_#{@version}_freebsd_amd64.tar.gz"}

      {{:unix, :freebsd}, arch} ->
        {:ok, "CLIProxyAPI_#{@version}_freebsd_#{arch}_no-plugin.tar.gz"}

      {{:win32, _}, arch} ->
        {:ok, "CLIProxyAPI_#{@version}_windows_#{arch}.zip"}

      {os, _} ->
        {:error, "CLIProxyAPI has no release for #{inspect(os)}."}
    end
  end

  @doc """
  Downloads this machine's archive and `checksums.txt` into `dir`, checks one
  against the other and puts the binary at `installed(dir)`: `{:ok, path}` or
  `{:error, message}`. Nothing is left behind when it fails.
  """
  def download(dir) do
    work = Path.join(dir, "download")
    File.rm_rf!(work)
    File.mkdir_p!(work)

    try do
      with {:ok, name} <- asset(),
           {:ok, sums} <- fetch(url("checksums.txt")),
           {:ok, expected} <- expected(sums, name),
           archive = Path.join(work, name),
           :ok <- fetch_to(url(name), archive),
           :ok <- check(archive, expected, name),
           {:ok, binary} <- extract(archive, work) do
        dest = installed(dir)
        File.mkdir_p!(Path.dirname(dest))
        File.rename!(binary, dest)
        File.chmod!(dest, 0o755)
        {:ok, dest}
      end
    after
      File.rm_rf(work)
    end
  end

  defp expected(sums, name) do
    found =
      for line <- String.split(sums, "\n"),
          [hex, file] <- [String.split(String.trim(line), ~r/\s+\*?/, parts: 2)],
          file == name,
          do: String.downcase(hex)

    case found do
      [hex | _] -> {:ok, hex}
      [] -> {:error, "The release's checksums.txt does not list #{name}."}
    end
  end

  defp check(archive, expected, name) do
    actual =
      File.stream!(archive, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else:
        {:error,
         "#{name} does not match the release's checksum (expected #{expected}, got #{actual}); it was not installed."}
  end

  defp extract(archive, work) do
    out = Path.join(work, "out")
    File.mkdir_p!(out)
    file = to_charlist(binary_name())

    result =
      if String.ends_with?(archive, ".zip"),
        do: :zip.extract(to_charlist(archive), [{:file_list, [file]}, {:cwd, to_charlist(out)}]),
        else:
          :erl_tar.extract(to_charlist(archive), [
            :compressed,
            {:files, [file]},
            {:cwd, to_charlist(out)}
          ])

    binary = Path.join(out, binary_name())

    case result do
      ok when ok == :ok or elem(ok, 0) == :ok ->
        if File.regular?(binary),
          do: {:ok, binary},
          else: {:error, "#{Path.basename(archive)} has no #{binary_name()}."}

      {:error, reason} ->
        {:error, "#{Path.basename(archive)} could not be unpacked: #{inspect(reason)}."}
    end
  end

  defp fetch(url) do
    case :httpc.request(:get, {to_charlist(url), []}, http_options(), body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, _}} -> {:error, "#{url} answered #{status}."}
      {:error, reason} -> {:error, "#{url} could not be reached: #{inspect(reason)}."}
    end
  end

  defp fetch_to(url, path) do
    case :httpc.request(:get, {to_charlist(url), []}, http_options(), stream: to_charlist(path)) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, "#{url} answered #{status}."}
      {:error, reason} -> {:error, "#{url} could not be reached: #{inspect(reason)}."}
    end
  end

  defp http_options,
    do: [timeout: 300_000, connect_timeout: 15_000, ssl: :httpc.ssl_verify_host_options(true)]

  defp url(file), do: String.trim_trailing(env(:releases, @releases), "/") <> "/" <> file

  defp on_path do
    env(:path, System.get_env("PATH", ""))
    |> String.split(if(match?({:win32, _}, :os.type()), do: ";", else: ":"), trim: true)
    |> Enum.map(&Path.join(&1, binary_name()))
    |> Enum.find(&executable?/1)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp env(key, default),
    do: Keyword.get(Application.get_env(:hal_c2, :cliproxyapi, []), key, default)
end
