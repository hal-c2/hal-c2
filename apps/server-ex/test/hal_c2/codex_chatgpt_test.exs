defmodule HalC2.Codex.ChatGptTest do
  # The checks around a ChatGPT sign-in run through HAL-C2: which link is OpenAI's,
  # which pasted address is the sign-in's callback, and which instance is managed.
  use ExUnit.Case, async: false

  alias HalC2.Codex.ChatGpt
  alias HalC2.Settings

  @moduletag :tmp_dir

  @link "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_x" <>
          "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=s1"

  setup %{tmp_dir: dir} do
    Application.put_env(:hal_c2, :home, dir)
    start_supervised!(Settings)
    :ok
  end

  describe "authorization/1" do
    test "reads the loopback callback and state of OpenAI's link" do
      assert {:ok, %{redirect_uri: "http://localhost:1455/auth/callback", state: "s1"}} =
               ChatGpt.authorization(@link)
    end

    test "refuses a link that is not OpenAI's sign-in page or names no loopback callback" do
      for link <- [
            String.replace(@link, "auth.openai.com", "auth.openai.com.example.org"),
            String.replace(@link, "https://", "http://"),
            String.replace(@link, "/oauth/authorize", "/oauth/other"),
            String.replace(@link, "&state=s1", ""),
            String.replace(@link, "localhost", "example.org"),
            nil
          ] do
        assert ChatGpt.authorization(link) == :error, inspect(link)
      end
    end
  end

  describe "validate_callback/2" do
    setup do
      {:ok, pending} = ChatGpt.authorization(@link)
      %{pending: pending}
    end

    test "delivers the callback with the sign-in's state", %{pending: pending} do
      for pasted <- [
            "http://localhost:1455/auth/callback?code=c1&state=s1",
            "  localhost:1455/auth/callback?code=c1&state=s1\n",
            "http://127.0.0.1:1455/auth/callback?code=c1",
            "http://localhost:1455/auth/callback?error=access_denied&state=s1"
          ] do
        assert {:ok, %URI{host: "localhost", port: 1455, path: "/auth/callback", query: query}} =
                 ChatGpt.validate_callback(pending, pasted),
               inspect(pasted)

        assert %{"state" => "s1"} = URI.decode_query(query)
      end
    end

    test "refuses an address that points anywhere but the callback", %{pending: pending} do
      for pasted <- [
            "https://localhost:1455/auth/callback?code=c1",
            "http://example.org:1455/auth/callback?code=c1",
            "http://localhost:1456/auth/callback?code=c1",
            "http://localhost:1455/other?code=c1",
            "http://user@localhost:1455/auth/callback?code=c1",
            "http://localhost:1455/auth/callback?code=c1#x",
            ""
          ] do
        assert {:error, "This address is not the ChatGPT sign-in callback."} =
                 ChatGpt.validate_callback(pending, pasted),
               inspect(pasted)
      end
    end

    test "refuses another sign-in's state, a missing or doubled answer, and a huge address",
         %{pending: pending} do
      callback = "http://localhost:1455/auth/callback?"

      assert {:error, "This callback address belongs to another ChatGPT sign-in."} =
               ChatGpt.validate_callback(pending, callback <> "code=c1&state=s2")

      for query <- ["state=s1", "code=&state=s1", "code=c1&error=x", "code=c1&code=c2"] do
        assert {:error, "The callback address must carry one ChatGPT sign-in answer."} =
                 ChatGpt.validate_callback(pending, callback <> query),
               query
      end

      assert {:error, "The callback address is too long."} =
               ChatGpt.validate_callback(
                 pending,
                 callback <> "code=" <> String.duplicate("c", 17_000)
               )
    end
  end

  describe "managed?/1" do
    test "is each instance's own mode, never the built-in instance's" do
      {:ok, _} =
        Settings.put(
          %{
            "providers" => %{"codex" => %{"setupMode" => "managed"}},
            "providerInstances" => %{
              "codex-work" => %{"driver" => "codex"},
              "codex-home" => %{"driver" => "codex", "config" => %{"setupMode" => "managed"}},
              "claude-work" => %{
                "driver" => "claudeAgent",
                "config" => %{"setupMode" => "managed"}
              }
            }
          },
          0
        )

      assert ChatGpt.managed?("codex")
      refute ChatGpt.managed?("codex-work")
      assert ChatGpt.managed?("codex-home")
      refute ChatGpt.managed?("claude-work")
      refute ChatGpt.managed?(nil)
    end
  end
end
