defmodule HalC2.Steps.Support.Slack do
  @moduledoc """
  The MC's Slack connection for scenarios, against `HalC2.Test.FakeSlack` so nothing
  reaches slack.com. `connect/1` starts the fake workspace and `HalC2.Slack` and
  connects as a client does (`slack.connect`); `watch/1` subscribes the `"slack"` client
  to the `slack` shape and `await/2` waits for a status pushed there. `listener/3`
  installs and enables a plugin granted the given permissions whose `handle_event`
  tells the test process (`:hal_c2_plugin_probe`) `{:slack_event, id, event}`; with
  `hold: true` it tells it `{:slack_held, id, event, pid}` instead and returns only once
  `pid` is sent `:go`.
  """

  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Test.{FakeSlack, Mc}
  alias HalC2.Test.Mc.World

  @doc "The fake workspace and the MC's Slack service, without connecting."
  def ready(context, overrides \\ %{}) do
    unless Process.whereis(FakeSlack), do: :ok = FakeSlack.start(overrides)
    World.put_app_env(:slack_backoff_ms, 5)
    Mc.ensure(HalC2.Slack)
    context
  end

  @doc "Connects with the fake workspace's tokens, asserting it connects."
  def connect(context, overrides \\ %{}) do
    context = ready(context, overrides)
    {reply, context} = World.call(context, "slack.connect", tokens())
    assert {:ok, %{"state" => "connected"}} = reply
    context
  end

  def tokens, do: %{"botToken" => FakeSlack.bot_token(), "appToken" => FakeSlack.app_token()}

  @doc "Subscribes the `\"slack\"` client to the MC's Slack status."
  def watch(%{clients: %{"slack" => _}} = context), do: context

  def watch(context) do
    client = Mc.sub(World.client(context, "slack"), 1, shape())
    World.put_client(context, "slack", client)
  end

  def shape, do: %{"type" => "slack", "mc" => Atom.to_string(node())}

  @doc "Waits for the watched status to be in `state`; answers it and the context."
  def await(context, state) do
    context = watch(context)

    {frame, client} =
      Mc.await(World.client(context, "slack"), fn frame ->
        frame["t"] == "slack" and frame["status"]["state"] == state
      end)

    {frame["status"], World.put_client(context, "slack", client)}
  end

  @doc "Installs and enables `id` granted `permissions`, telling the test process its events."
  def listener(context, id, permissions, opts \\ []) do
    dir = Path.join([context.mc.home, "plugins", id])
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "mc"))

    manifest = %{
      "id" => id,
      "name" => "Listener #{id}",
      "version" => "1.0.0",
      "apiVersion" => 1,
      "description" => "Hears Slack.",
      "permissions" => for(p <- permissions, do: %{"id" => p, "reason" => "The scenario."})
    }

    module = "HalC2PluginFixture.SlackListener#{Macro.camelize(String.replace(id, "-", "_"))}"

    File.write!(Path.join(dir, "plugin.json"), JSON.encode!(manifest))

    File.write!(Path.join(dir, "mc/listener.ex"), """
    defmodule #{module} do
      @behaviour HalC2.Plugins.Extension

      @impl true
      def call(method, _input, _context), do: {:error, "no method " <> method}

      @impl true
      #{if opts[:hold], do: held(), else: heard()}
    end
    """)

    :ok = Fixtures.probe()
    context = context |> Fixtures.ensure() |> Fixtures.rescan()

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => id, "acceptPermissions" => permissions})

    assert %{"status" => "running"} = Fixtures.entry(id)
    context
  end

  defp heard do
    """
    def handle_event(event, context),
        do: send(:hal_c2_plugin_probe, {:slack_event, context.id, event})
    """
  end

  defp held do
    """
    def handle_event(event, context) do
        send(:hal_c2_plugin_probe, {:slack_held, context.id, event, self()})

        receive do
          :go -> :ok
        end
      end
    """
  end
end
