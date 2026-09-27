defmodule HalC2.SourceControl.ForgejoTest do
  use ExUnit.Case, async: false

  alias HalC2.SourceControl.Forgejo
  alias HalC2.Test.FakeHttp

  @moduletag :tmp_dir

  defp keys(hosts, aliases \\ %{}) do
    %{
      "hosts" => Map.new(hosts, &{&1, %{"type" => "Application", "token" => "t-" <> &1}}),
      "aliases" => aliases
    }
  end

  describe "logins_from_keys/2" do
    test "a server under a subpath is left to tea" do
      logins = Forgejo.logins_from_keys(keys(["codeberg.org", "git.example.com/forgejo"]))
      assert Enum.map(logins, & &1["url"]) == ["https://codeberg.org"]
    end

    test "each SSH alias fj knows is a login of its own" do
      logins =
        Forgejo.logins_from_keys(
          keys(["codeberg.org"], %{"cb" => "codeberg.org", "berg" => "codeberg.org"})
        )

      assert logins |> Enum.map(& &1["ssh_host"]) |> Enum.sort() == ["berg", "cb"]
      assert Enum.all?(logins, &(&1["name"] == "codeberg.org"))
    end

    test "only an explicit http remote on the same server makes the login http" do
      keys = keys(["git.local:3000", "codeberg.org"])

      urls =
        keys
        |> Forgejo.logins_from_keys("http://git.local:3000/acme/shop.git")
        |> Enum.map(& &1["url"])
        |> Enum.sort()

      assert urls == ["http://git.local:3000", "https://codeberg.org"]
    end
  end

  describe "match_login/4" do
    @logins [
      %{"name" => "a", "url" => "https://codeberg.org", "default" => "false"},
      %{
        "name" => "b",
        "url" => "https://git.example.com",
        "default" => "false",
        "ssh_host" => "forge"
      }
    ]

    test "an HTTP remote matches by host" do
      remote = Forgejo.parse_remote("https://codeberg.org/acme/shop.git")
      assert %{"name" => "a"} = Forgejo.match_login(@logins, remote)
      assert remote.path == "acme/shop"
    end

    test "an SSH remote matches by the login's alias" do
      remote = Forgejo.parse_remote("forge:acme/shop.git")
      assert remote.ssh
      assert %{"name" => "b"} = Forgejo.match_login(@logins, remote)
    end

    test "two accounts on one server resolve to its default, else to none" do
      second = %{"name" => "c", "url" => "https://codeberg.org", "default" => "false"}
      remote = Forgejo.parse_remote("https://codeberg.org/acme/shop")
      assert Forgejo.match_login([second | @logins], remote) == nil

      default = %{second | "default" => "true"}
      assert %{"name" => "c"} = Forgejo.match_login([default | @logins], remote)
    end
  end

  describe "through fj" do
    setup %{tmp_dir: tmp} do
      {base, log} =
        FakeHttp.start(%{
          "/api/v1/user" => {200, %{"login" => "octocat"}},
          "/api/v1/repos/acme/shop" => {200, %{"full_name" => "acme/shop"}}
        })

      host = String.replace_prefix(base, "http://", "")
      keys = Path.join(tmp, "keys.json")
      File.write!(keys, JSON.encode!(keys([host])))

      fj = Path.join(tmp, "fj")
      File.write!(fj, "#!/bin/sh\nexit 0\n")
      File.chmod!(fj, 0o755)

      put_app_env(:fj_keys_paths, [keys])
      put_app_env(:fj_command, fj)
      %{base: base, log: log, host: host}
    end

    test "the account comes from the server with fj's token", %{base: base, log: log, host: host} do
      assert Forgejo.account(nil, base) == {:ok, "octocat"}
      assert [%{"authorization" => "token t-" <> ^host}] = FakeHttp.requests(log)
    end

    test "a repository on the server is read with fj's token", %{base: base, log: log} do
      assert {:ok, body, %{status: 200}} =
               Forgejo.api(nil, [remote_url: base <> "/acme/shop.git"], "repos/acme/shop")

      assert JSON.decode!(body) == %{"full_name" => "acme/shop"}
      assert [%{"path" => "/api/v1/repos/acme/shop"}] = FakeHttp.requests(log)
    end

    test "a missing repository is named not found", %{base: base} do
      assert {:error, {:not_found, "Forgejo repository or pull request was not found."}} =
               Forgejo.api(nil, [remote_url: base <> "/acme/gone.git"], "repos/acme/gone")
    end
  end

  defp put_app_env(key, value) do
    previous = Application.get_env(:hal_c2, key)
    Application.put_env(:hal_c2, key, value)
    on_exit(fn -> Application.put_env(:hal_c2, key, previous) end)
  end
end
