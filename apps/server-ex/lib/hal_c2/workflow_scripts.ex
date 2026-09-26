defmodule HalC2.WorkflowScripts do
  @moduledoc """
  `orchestration.getWorkflowScript`: the script a Claude workflow ran, for the
  Agents view's script button, as the Node server serves it. The path comes from
  the client and is only a hint: the real path must be a `.js` regular file under
  `~/.claude/projects`, where Claude keeps workflow scripts, and reads stop at
  256 KB. Tests can act just before the file is opened with
  `Application.put_env(:hal_c2, :workflow_scripts_opening, fn path -> ... end)`.
  """

  @cap 256 * 1024

  def read(%{"scriptPath" => requested}) do
    with :ok <-
           check(
             Path.type(requested) == :absolute and Path.extname(requested) == ".js",
             "invalid-path",
             requested
           ),
         {:ok, root} <- HalC2.Paths.real(root()) |> or_fail("root-unavailable", requested),
         {:ok, path} <- HalC2.Paths.real(requested) |> or_fail("not-found", requested),
         :ok <- check(String.starts_with?(path, root <> "/"), "outside-root", path),
         :ok <- check(Path.extname(path) == ".js", "not-js", path),
         {:ok, found} <- File.stat(path) |> regular(path) do
      read_found(path, found)
    end
  end

  # Reads the file that was checked, not whatever the path names by the time it is
  # opened: a file swapped in meanwhile has another inode and is refused.
  defp read_found(path, found) do
    if opening = Application.get_env(:hal_c2, :workflow_scripts_opening), do: opening.(path)

    case File.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          with {:ok, info} <- :file.read_file_info(file),
               opened = File.Stat.from_record(info),
               :ok <- check(same_file?(opened, found), "changed-during-read", path),
               {:ok, contents} <- head(file) |> or_fail("read-failed", path) do
            {:ok,
             %{"scriptPath" => path, "contents" => contents, "truncated" => opened.size > @cap}}
          else
            {:error, %{} = error} -> {:error, error}
            {:error, _} -> fail("read-failed", path)
          end
        after
          File.close(file)
        end

      {:error, _} ->
        fail("read-failed", path)
    end
  end

  defp same_file?(a, b),
    do: {a.inode, a.major_device, a.minor_device} == {b.inode, b.major_device, b.minor_device}

  defp root,
    do:
      Application.get_env(:hal_c2, :workflow_scripts_root) ||
        Path.join([System.user_home!(), ".claude", "projects"])

  defp head(file) do
    case :file.read(file, @cap) do
      :eof -> {:ok, ""}
      other -> other
    end
  end

  defp regular({:ok, %File.Stat{type: :regular}} = ok, _path), do: ok
  defp regular({:ok, _}, path), do: fail("not-regular-file", path)
  defp regular({:error, _}, path), do: fail("read-failed", path)

  defp check(true, _reason, _path), do: :ok
  defp check(false, reason, path), do: fail(reason, path)

  defp or_fail({:ok, _} = ok, _reason, _path), do: ok
  defp or_fail(_error, reason, path), do: fail(reason, path)

  defp fail(reason, path) do
    {:error,
     %{"_tag" => "OrchestrationGetWorkflowScriptError", "reason" => reason, "scriptPath" => path}}
  end
end
