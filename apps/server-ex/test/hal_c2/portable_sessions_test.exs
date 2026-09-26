defmodule HalC2.PortableSessionsTest do
  # Places carried sessions where each provider looks for them; every home is a temp dir.
  use ExUnit.Case, async: false

  alias HalC2.PortableSessions

  @moduletag :tmp_dir
  @variables ~w(CLAUDE_CONFIG_DIR CODEX_HOME PI_CODING_AGENT_DIR PI_CODING_AGENT_SESSION_DIR)

  setup %{tmp_dir: dir} do
    previous = for name <- @variables, do: {name, System.get_env(name)}
    System.put_env("CLAUDE_CONFIG_DIR", Path.join(dir, "claude"))
    System.put_env("CODEX_HOME", Path.join(dir, "codex"))
    System.put_env("PI_CODING_AGENT_DIR", Path.join(dir, "pi"))
    System.delete_env("PI_CODING_AGENT_SESSION_DIR")

    on_exit(fn ->
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    %{from: "/home/a/code/shop", to: Path.join(dir, "src/shop")}
  end

  defp session(driver, native, files, from) do
    %{
      "driver" => driver,
      "providerThreadId" => "provider-thread:#{driver}:t1",
      "nativeId" => native,
      "cwd" => from,
      "files" => for({name, lines} <- files, do: %{"fileName" => name, "data" => jsonl(lines)})
    }
  end

  defp jsonl(lines), do: Enum.map_join(lines, "\n", &JSON.encode!/1) <> "\n"

  defp read(path),
    do: for(l <- String.split(File.read!(path), "\n", trim: true), do: JSON.decode!(l))

  test "a Codex rollout keeps its date folder and moves the session's and each turn's cwd",
       %{tmp_dir: dir, from: from, to: to} do
    name = "sessions/2026/09/26/rollout-2026-09-26T10-00-00-abc.jsonl"

    lines = [
      %{"type" => "session_meta", "payload" => %{"id" => "abc", "cwd" => from}},
      %{"type" => "turn_context", "payload" => %{"cwd" => from <> "/web"}},
      %{"type" => "response_item", "payload" => %{"text" => from}}
    ]

    assert {%{"carriedSession" => carried}, []} =
             PortableSessions.place(session("codex", "abc", [{name, lines}], from), to, %{})

    path = Path.join([dir, "codex", name])

    assert carried == %{
             "driver" => "codex",
             "instanceId" => "codex",
             "nativeId" => "abc",
             "path" => path
           }

    assert [%{"payload" => %{"cwd" => ^to}}, %{"payload" => %{"cwd" => web}}, untouched] =
             read(path)

    assert web == to <> "/web"
    assert untouched == List.last(lines)
  end

  test "a Claude transcript goes under the destination's project folder with its sub-agents",
       %{tmp_dir: dir, from: from, to: to} do
    files = [
      {"s1.jsonl", [%{"sessionId" => "s1", "cwd" => from}, %{"type" => "summary"}]},
      {"s1/subagents/agent-1.jsonl", [%{"cwd" => from <> "/lib"}]}
    ]

    assert {%{"carriedSession" => %{"path" => path}}, []} =
             PortableSessions.place(session("claudeAgent", "s1", files, from), to, %{})

    folder = Path.join([dir, "claude", "projects", String.replace(to, ~r/[^A-Za-z0-9]/, "-")])
    assert path == Path.join(folder, "s1.jsonl")
    assert [%{"cwd" => ^to}, %{"type" => "summary"}] = read(path)
    assert [%{"cwd" => lib}] = read(Path.join(folder, "s1/subagents/agent-1.jsonl"))
    assert lib == to <> "/lib"
  end

  test "a Pi session's header moves, and Pi finds the copy by its path",
       %{tmp_dir: dir, from: from, to: to} do
    name = "2026-09-26T10-00-00-000Z_p1.jsonl"
    lines = [%{"type" => "session", "id" => "p1", "cwd" => from}, %{"type" => "message"}]

    assert {%{"carriedSession" => %{"nativeId" => path, "path" => path}}, []} =
             PortableSessions.place(session("pi", "p1", [{name, lines}], from), to, %{})

    folder = "--" <> (to |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
    assert path == Path.join([dir, "pi", "sessions", folder, name])
    assert [%{"cwd" => ^to}, %{"type" => "message"}] = read(path)
  end

  test "a copy the machine already has is kept, and names outside the home are skipped",
       %{tmp_dir: dir, from: from, to: to} do
    name = "sessions/2026/09/26/rollout-x-abc.jsonl"
    path = Path.join([dir, "codex", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "kept\n")

    files = [
      {name, [%{"type" => "session_meta", "payload" => %{"cwd" => from}}]},
      {"../out.jsonl", [%{}]}
    ]

    assert {%{"carriedSession" => _}, []} =
             PortableSessions.place(session("codex", "abc", files, from), to, %{})

    assert File.read!(path) == "kept\n"
    refute File.exists?(Path.join(dir, "out.jsonl"))
  end

  test "a provider that cannot carry its session places nothing", %{to: to} do
    assert {nil, []} = PortableSessions.place(%{"driver" => "cursor", "files" => []}, to, %{})
    assert {nil, []} = PortableSessions.place(nil, to, %{})
  end
end
