defmodule HalC2.ProjectEnvironmentTest do
  use ExUnit.Case, async: false

  alias HalC2.ProjectEnvironment

  # Checkouts are made under TMPDIR, so a fixture's mise or direnv config sits under
  # no repository's own.
  setup do
    dir = Path.join(System.tmp_dir!(), "project-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:hal_c2, :home, Path.join(dir, "home"))

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:hal_c2, :project_environment_commands)
      Application.delete_env(:hal_c2, :project_environment_timeout_ms)
    end)

    %{dir: dir}
  end

  defp checkout(dir, files) do
    root = Path.join(dir, "checkout")

    for {name, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, name)))
      File.write!(Path.join(root, name), text)
    end

    File.mkdir_p!(root)
    root
  end

  # A stand-in for a manager: a script that prints `out` to stdout, `err` to stderr
  # and exits `status`.
  defp fake(dir, name, out, err \\ "", status \\ 0) do
    path = Path.join(dir, "fake-#{name}")

    File.write!(path, """
    #!/bin/sh
    printf '%s' '#{out}'
    printf '%s' '#{err}' >&2
    exit #{status}
    """)

    File.chmod!(path, 0o755)
    commands = Application.get_env(:hal_c2, :project_environment_commands, %{})
    Application.put_env(:hal_c2, :project_environment_commands, Map.put(commands, name, path))
  end

  describe "off" do
    test "loads nothing unless the project chose a source", %{dir: dir} do
      root = checkout(dir, %{".env" => "SOME_URL=https://example.test\n", "mise.toml" => ""})

      for settings <- [%{}, %{"projectEnvironment" => "off"}, %{"projectEnvironment" => "later"}] do
        assert ProjectEnvironment.load(settings, root) == {[], []}
      end
    end
  end

  describe "dotenv" do
    test "reads the chosen file relative to the working directory", %{dir: dir} do
      root = checkout(dir, %{".env.dev" => "SOME_URL=https://example.test/mcp\n"})

      assert ProjectEnvironment.load(
               %{"projectEnvironment" => "dotenv", "projectEnvironmentFile" => ".env.dev"},
               root
             ) == {[{"SOME_URL", "https://example.test/mcp"}], []}
    end

    test "defaults to .env", %{dir: dir} do
      root = checkout(dir, %{".env" => "A=1\n"})

      assert ProjectEnvironment.load(%{"projectEnvironment" => "dotenv"}, root) ==
               {[{"A", "1"}], []}
    end

    test "a missing file is a warning, not an error", %{dir: dir} do
      root = checkout(dir, %{})
      assert {[], [warning]} = ProjectEnvironment.load(%{"projectEnvironment" => "dotenv"}, root)
      assert warning =~ ".env was not found"
    end

    test "parses the forms a dotenv file takes" do
      text = """
      # a comment
      export EXPORTED=yes
      PLAIN = spaced value  # trailing comment
      HASH=a#b
      SINGLE='literal $HOME \\n'
      DOUBLE="tab\\there \\"quoted\\""
      MULTI="first
      second"
      EMPTY=
      DUP=old
      DUP=new
      not a variable
      CRLF=yes\r
      """

      assert ProjectEnvironment.parse_dotenv(text) ==
               {[
                  {"EXPORTED", "yes"},
                  {"PLAIN", "spaced value"},
                  {"HASH", "a#b"},
                  {"SINGLE", "literal $HOME \\n"},
                  {"DOUBLE", "tab\there \"quoted\""},
                  {"MULTI", "first\nsecond"},
                  {"EMPTY", ""},
                  {"DUP", "new"},
                  {"CRLF", "yes"}
                ], [12]}
    end

    test "loads the variables around a bad line and names only its number", %{dir: dir} do
      root = checkout(dir, %{".env" => "A=1\nsecret-looking garbage\nB=2\n"})

      assert {[{"A", "1"}, {"B", "2"}], [warning]} =
               ProjectEnvironment.load(%{"projectEnvironment" => "dotenv"}, root)

      assert warning =~ "line 2"
      refute warning =~ "garbage"
    end
  end

  describe "auto with stand-in managers" do
    test "mise runs only where a mise config applies, in the working directory", %{dir: dir} do
      fake(dir, "mise", ~s({"FROM_MISE":"1"}))
      root = checkout(dir, %{"mise.toml" => "", "sub/x" => ""})
      bare = checkout(Path.join(dir, "bare"), %{})

      assert ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, Path.join(root, "sub")) ==
               {[{"FROM_MISE", "1"}], []}

      assert ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, bare) == {[], []}
    end

    test "direnv's variables sit over mise's, and its unsets are left", %{dir: dir} do
      fake(dir, "mise", ~s({"A":"mise","B":"mise"}))
      fake(dir, "direnv", ~s({"B":"direnv","C":null}))
      root = checkout(dir, %{"mise.toml" => "", ".envrc" => ""})

      assert ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root) ==
               {[{"A", "mise"}, {"B", "direnv"}], []}
    end

    test "direnv builds on mise's variables, so a PATH it changes keeps mise's tools",
         %{dir: dir} do
      for {name, bin} <- [{"mise", "/mise/bin"}, {"direnv", "/envrc/bin"}] do
        path = Path.join(dir, "path-#{name}")
        File.write!(path, ~s(#!/bin/sh\nprintf '{"PATH":"#{bin}:%s"}' "$PATH"\n))
        File.chmod!(path, 0o755)
        commands = Application.get_env(:hal_c2, :project_environment_commands, %{})
        Application.put_env(:hal_c2, :project_environment_commands, Map.put(commands, name, path))
      end

      root = checkout(dir, %{"mise.toml" => "", ".envrc" => ""})

      assert ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root) ==
               {[{"PATH", "/envrc/bin:/mise/bin:" <> System.get_env("PATH")}], []}
    end

    test "mise and direnv share one time limit", %{dir: dir} do
      path = Path.join(dir, "slow-mise")
      File.write!(path, "#!/bin/sh\nexec sleep 30\n")
      File.chmod!(path, 0o755)
      Application.put_env(:hal_c2, :project_environment_commands, %{"mise" => path})
      fake(dir, "direnv", ~s({"A":"1"}))
      Application.put_env(:hal_c2, :project_environment_timeout_ms, 200)
      root = checkout(dir, %{"mise.toml" => "", ".envrc" => ""})

      assert {[], [mise, direnv]} =
               ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)

      assert mise =~ "mise took longer"
      assert direnv =~ "direnv took longer"
    end

    test "an .envrc direnv has not allowed is reported, not bypassed", %{dir: dir} do
      fake(dir, "direnv", "", "direnv: error .envrc is blocked. Run `direnv allow`", 1)
      root = checkout(dir, %{".envrc" => "export A=1"})

      assert {[], [warning]} = ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)
      assert warning =~ "direnv allow"
    end

    test "an untrusted mise config is reported", %{dir: dir} do
      fake(dir, "mise", "", "Config files in mise.toml are not trusted.", 1)
      root = checkout(dir, %{"mise.toml" => ""})

      assert {[], [warning]} = ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)
      assert warning =~ "mise trust"
    end

    test "a failing manager's stderr never reaches the warning", %{dir: dir} do
      fake(dir, "mise", "", "TOKEN=hunter2 went wrong", 3)
      root = checkout(dir, %{"mise.toml" => ""})

      assert {[], [warning]} = ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)
      refute warning =~ "hunter2"
    end

    test "one manager failing keeps the other's variables", %{dir: dir} do
      fake(dir, "mise", "not json")
      fake(dir, "direnv", ~s({"A":"1"}))
      root = checkout(dir, %{"mise.toml" => "", ".envrc" => ""})

      assert {[{"A", "1"}], [warning]} =
               ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)

      assert warning =~ "mise"
    end

    test "a manager that runs too long is given up on", %{dir: dir} do
      path = Path.join(dir, "slow-mise")
      File.write!(path, "#!/bin/sh\nexec sleep 30\n")
      File.chmod!(path, 0o755)
      Application.put_env(:hal_c2, :project_environment_commands, %{"mise" => path})
      Application.put_env(:hal_c2, :project_environment_timeout_ms, 200)
      root = checkout(dir, %{"mise.toml" => ""})

      assert {[], [warning]} = ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)
      assert warning =~ "took longer"
    end

    test "a manager that cannot be started is a warning", %{dir: dir} do
      Application.put_env(:hal_c2, :project_environment_commands, %{
        "mise" => Path.join(dir, "gone")
      })

      root = checkout(dir, %{"mise.toml" => ""})

      assert {[], [_warning]} = ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)
    end
  end

  describe "the real managers" do
    test "mise env reads a trusted checkout's [env]", %{dir: dir} do
      if System.find_executable("mise") do
        root = checkout(dir, %{"mise.toml" => ~s([env]\nSOME_URL = "https://example.test/mcp"\n)})
        System.put_env("MISE_TRUSTED_CONFIG_PATHS", root)
        on_exit(fn -> System.delete_env("MISE_TRUSTED_CONFIG_PATHS") end)

        assert {env, []} = ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)
        assert {"SOME_URL", "https://example.test/mcp"} in env
      end
    end

    test "direnv export reads an allowed .envrc", %{dir: dir} do
      # direnv's trust lives in its data directory, so it gets one of its own here.
      if System.find_executable("direnv") do
        root = checkout(dir, %{".envrc" => "export SOME_URL=https://example.test/mcp\n"})
        System.put_env("XDG_DATA_HOME", Path.join(dir, "data"))
        on_exit(fn -> System.delete_env("XDG_DATA_HOME") end)
        {_, 0} = System.cmd("direnv", ["allow", root], stderr_to_stdout: true)

        assert {env, []} = ProjectEnvironment.load(%{"projectEnvironment" => "auto"}, root)
        assert {"SOME_URL", "https://example.test/mcp"} in env
      end
    end
  end

  describe "merge" do
    test "the launch environment wins and HAL-C2's own variables are kept" do
      launch = [{"CODEX_HOME", "/instance"}, {"HAL_C2_MCP_URL", "http://mc"}]

      project = [
        {"CODEX_HOME", "/project"},
        {"HAL_C2_MCP_BEARER_TOKEN", "stolen"},
        {"HAL_C2_ANYTHING", "x"},
        {"SOME_URL", "https://example.test"},
        {"META_API_KEY", "k"}
      ]

      assert ProjectEnvironment.merge(launch, project, ["META_API_KEY"]) ==
               [{"SOME_URL", "https://example.test"} | launch]
    end

    test "names the launch command unsets stay unset" do
      assert ProjectEnvironment.unset_by(~w(env -u A -u B muse serve)) == ["A", "B"]
      assert ProjectEnvironment.unset_by(~w(/usr/bin/env --unset=A codex)) == ["A"]
      assert ProjectEnvironment.unset_by(~w(codex app-server -u X)) == []
    end
  end

  describe "for a turn" do
    setup %{dir: dir} do
      home = Path.join(dir, "home")
      File.mkdir_p!(home)
      start_supervised!({HalC2.Store, path: Path.join(home, "hal-c2.sqlite")})
      start_supervised!(HalC2.Streams)
      start_supervised!(HalC2.Settings)
      :ok
    end

    defp choose(project, settings) do
      {doc, version} = HalC2.Settings.get()
      overrides = Map.put(doc["projectSettingsOverrides"] || %{}, project, settings)
      {:ok, _} = HalC2.Settings.put(Map.put(doc, "projectSettingsOverrides", overrides), version)
    end

    defp ids,
      do: %{thread: "thread:pe", run: "run:pe", root_node: "node:pe", provider_thread: "pt:pe"}

    defp notice,
      do: HalC2.Streams.get("thread:pe", "turn-item", "turn-item:project-environment:run:pe")

    test "turning it on loads the project's variables, and off stops it", %{dir: dir} do
      root = checkout(dir, %{".env" => "SOME_URL=https://example.test/mcp\n"})
      turn = %{cwd: root, project_id: "p1", ids: ids()}
      launch = [{"CLAUDE_CONFIG_DIR", "/c"}]

      assert ProjectEnvironment.for_turn(turn, launch) == launch

      choose("p1", %{"projectEnvironment" => "dotenv"})

      assert ProjectEnvironment.for_turn(turn, launch) ==
               [{"SOME_URL", "https://example.test/mcp"} | launch]

      choose("p1", %{"projectEnvironment" => "off"})
      assert ProjectEnvironment.for_turn(turn, launch) == launch
      assert notice() == nil
    end

    test "a failure starts the session with its usual environment and a notice on the run",
         %{dir: dir} do
      root = checkout(dir, %{})

      choose("p1", %{"projectEnvironment" => "dotenv", "projectEnvironmentFile" => ".env.missing"})

      turn = %{cwd: root, project_id: "p1", ids: ids()}

      assert ProjectEnvironment.for_turn(turn, [{"A", "1"}]) == [{"A", "1"}]

      assert %{"type" => "system_notice", "status" => "completed", "message" => message} =
               notice()

      assert message =~ ".env.missing was not found"

      # A second launch in the same run does not repeat it.
      assert ProjectEnvironment.for_turn(turn, []) == []

      assert HalC2.Streams.state("thread:pe") |> HalC2.StreamState.get("turn-item") |> map_size() ==
               1
    end

    test "a launch outside a run, such as a rewind's, only logs", %{dir: dir} do
      root = checkout(dir, %{})
      choose("p1", %{"projectEnvironment" => "dotenv"})

      assert ProjectEnvironment.for_turn(%{cwd: root, project_id: "p1"}, []) == []
      assert notice() == nil
    end
  end
end
