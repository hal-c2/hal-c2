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

  # Follow-up to #1837 (#1851): the host of a pasted GitHub address is
  # kept for every host, github.com included, or `gh` would read the
  # repository on its default host (GH_HOST, or a sole Enterprise login).
  # The stand-in `gh` answers with the repository it was asked for.
  test "a pasted github.com address keeps its host for the lookup", %{tmp_dir: dir} do
    gh = Path.join(dir, "gh")

    File.write!(gh, """
    #!/bin/sh
    printf '{"nameWithOwner":"%s","url":"https://example.test/x","sshUrl":"git@example.test:x"}' "$3"
    """)

    File.chmod!(gh, 0o755)
    Application.put_env(:hal_c2, :gh_command, gh)
    on_exit(fn -> Application.delete_env(:hal_c2, :gh_command) end)

    File.write!(Path.join(dir, "hosts.yml"), "")
    previous = System.get_env("GH_CONFIG_DIR")
    System.put_env("GH_CONFIG_DIR", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("GH_CONFIG_DIR", previous),
        else: System.delete_env("GH_CONFIG_DIR")
    end)

    assert {:ok, %{"nameWithOwner" => "github.com/acme/web"}} =
             HalC2.SourceControl.lookup(%{
               "provider" => "github",
               "repository" => "https://github.com/acme/web.git?tab=readme"
             })
  end
end
