defmodule HalC2.SourceControlNamesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # A stand-in `az` that answers with the repository it was asked for.
  setup %{tmp_dir: dir} do
    az = Path.join(dir, "az")

    File.write!(az, """
    #!/bin/sh
    while [ "$1" != "--repository" ]; do shift; done
    printf '{"name":"%s","remoteUrl":"https://dev.azure.com/o/p/_git/x","sshUrl":"git@ssh.dev.azure.com:v3/o/p/x"}' "$2"
    """)

    File.chmod!(az, 0o755)
    Application.put_env(:hal_c2, :az_command, az)
    on_exit(fn -> Application.delete_env(:hal_c2, :az_command) end)
  end

  test "a repository name with spaces reaches the host CLI as one argument; an option never does" do
    assert {:ok, %{"nameWithOwner" => "My Repository"}} =
             HalC2.SourceControl.lookup(%{
               "provider" => "azure-devops",
               "repository" => "My Repository"
             })

    assert {:error, %{"detail" => "invalid repository name"}} =
             HalC2.SourceControl.lookup(%{
               "provider" => "azure-devops",
               "repository" => "--org=x"
             })
  end
end
