defmodule HalC2.GitTest do
  # `:git_command` is application-wide.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "stderr past max_bytes keeps its tail, where a push's refusal is", %{tmp_dir: dir} do
    # A chatty git: 300 KB of progress on stderr, then the line callers act on.
    git = Path.join(dir, "git")

    File.write!(git, """
    #!/bin/sh
    head -c 307200 /dev/zero | tr '\\0' 'x' >&2
    echo >&2
    echo 'refusing to allow an OAuth App to create or update workflow without `workflow` scope' >&2
    exit 1
    """)

    File.chmod!(git, 0o755)
    previous = Application.fetch_env(:hal_c2, :git_command)
    Application.put_env(:hal_c2, :git_command, git)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:hal_c2, :git_command, value)
        :error -> Application.delete_env(:hal_c2, :git_command)
      end
    end)

    max = 64 * 1024

    assert {:ok, %{status: 1, err: err, truncated: true}} =
             HalC2.Git.run(dir, ["push"], max_bytes: max)

    assert byte_size(err) <= max
    assert String.ends_with?(err, "without `workflow` scope\n")
  end
end
