defmodule HalC2.Acp.Antigravity.ClientFiles do
  @moduledoc """
  Workspace file access Antigravity asks for through the ACP client `fs`
  capability, ported from upstream T3 Code's `AntigravityClientFiles.ts`
  (pingdotgg/t3code#2829). The agent gates each write behind
  `session/request_permission`, so only path containment is checked here:
  a path must stay, once its links resolve, in the session's workspace or
  among HAL-C2's attachments (where a message's files are saved).
  """

  @max_bytes 8 * 1024 * 1024

  @doc """
  `fs/read_text_file` for `cwd`: the file's text, or one range of its lines
  (`line` is 1-based, `limit` a line count). Reads may also reach HAL-C2's
  attachments, where a message's files are saved; writes may not.
  """
  def read(cwd, %{"path" => requested} = params) when is_binary(requested) do
    with {:ok, path} <- resolve(cwd, requested, [cwd, HalC2.Attachments.dir()]),
         {:ok, text} <- read_file(path, requested) do
      {:ok, %{"content" => lines(text, params["line"], params["limit"])}}
    end
  end

  def read(_cwd, _params),
    do: {:error, %{"code" => -32602, "message" => "fs/read_text_file needs a path"}}

  @doc "`fs/write_text_file` for `cwd`: parent folders are made as needed."
  def write(cwd, %{"path" => requested, "content" => content})
      when is_binary(requested) and is_binary(content) do
    with {:ok, path} <- resolve(cwd, requested, [cwd]) do
      case File.mkdir_p(Path.dirname(path)) do
        :ok ->
          case File.write(path, content) do
            :ok -> {:ok, %{}}
            _ -> refuse("Could not write '#{requested}'.")
          end

        _ ->
          refuse("Could not write '#{requested}'.")
      end
    end
  end

  def write(_cwd, _params),
    do: {:error, %{"code" => -32602, "message" => "fs/write_text_file needs a path and content"}}

  # A relative path is read against the workspace. The path resolves through
  # its links at its nearest existing ancestor, with any folders not yet
  # written rejoined below that, so creating them can only happen under a
  # checked real path: a link out of the workspace cannot escape it, however
  # deep under it the file sits.
  defp resolve(cwd, requested, roots) do
    absolute =
      if Path.type(requested) == :absolute,
        do: Path.expand(requested),
        else: Path.expand(requested, cwd)

    real = real_path(absolute)

    if Enum.any?(roots, &inside?(real, &1)),
      do: {:ok, real},
      else: refuse("Path '#{requested}' is outside the session workspace.")
  end

  defp real_path(path) do
    case HalC2.Paths.real(path) do
      {:ok, real} -> real
      _ -> join_rest(Path.dirname(path), [Path.basename(path)])
    end
  end

  defp join_rest("/", rest), do: Path.join(["/" | rest])

  defp join_rest(dir, rest) do
    case HalC2.Paths.real(dir) do
      {:ok, real} -> Path.join([real | rest])
      _ -> join_rest(Path.dirname(dir), [Path.basename(dir) | rest])
    end
  end

  defp inside?(real, root) do
    case HalC2.Paths.real(root) do
      {:ok, root} -> real == root or String.starts_with?(real, root <> "/")
      _ -> false
    end
  end

  defp read_file(path, requested) do
    case File.stat(path) do
      {:error, :enoent} ->
        refuse("File '#{requested}' not found.")

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes ->
        case File.read(path) do
          {:ok, text} ->
            if String.valid?(text),
              do: {:ok, text},
              else:
                refuse(
                  "File '#{requested}' is not a readable text file under #{@max_bytes} bytes."
                )

          _ ->
            refuse("Could not read '#{requested}'.")
        end

      {:ok, %File.Stat{}} ->
        refuse("File '#{requested}' is not a readable text file under #{@max_bytes} bytes.")

      _ ->
        refuse("Could not read '#{requested}'.")
    end
  end

  defp lines(text, line, limit) when is_integer(line) or is_integer(limit) do
    text
    |> String.split("\n")
    |> Enum.drop(max((line || 1) - 1, 0))
    |> then(&if(is_integer(limit) and limit >= 0, do: Enum.take(&1, limit), else: &1))
    |> Enum.join("\n")
  end

  defp lines(text, _line, _limit), do: text

  defp refuse(message), do: {:error, %{"code" => -32002, "message" => message}}
end
