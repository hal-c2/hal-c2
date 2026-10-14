defmodule HalC2.Steps.Support.PluginHost do
  @moduledoc """
  A plugin that calls the host API (`HalC2.Plugins.Host`) for scenarios, shared by the
  step files that test one part of it (`features/plugins/host-*.feature`). The package
  `host-probe` asks for the permissions a scenario names, is enabled with all of them
  accepted, and answers the call `"host"` with `%{"api", "method", "input"}` by calling
  `Host.<api>(id, method, input)`, so a step drives the host API exactly as a plugin's
  own code does. The plugin is `context.plugin`; `call/4` keeps its answer in
  `context.reply` (`{:ok, result}` or `{:error, message, detail}`).
  """

  import ExUnit.Assertions

  alias HalC2.Steps.Plugins.Fixtures
  alias HalC2.Test.Mc.World

  @id "host-probe"

  @doc "Installs and enables `host-probe` granted `permissions`."
  def granted(context, permissions) do
    dir = Path.join([context.mc.home, "plugins", @id])
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "mc"))

    manifest = %{
      "id" => @id,
      "name" => "Host probe",
      "version" => "1.0.0",
      "apiVersion" => 1,
      "description" => "Calls the host API.",
      "permissions" => for(id <- permissions, do: %{"id" => id, "reason" => "The scenario."})
    }

    File.write!(Path.join(dir, "plugin.json"), JSON.encode!(manifest))
    File.write!(Path.join(dir, "mc/host_probe.ex"), source())
    context = context |> Fixtures.ensure() |> Fixtures.rescan()

    {_, context} =
      World.call!(context, "plugins.enable", %{"id" => @id, "acceptPermissions" => permissions})

    assert %{"status" => "running"} = Fixtures.entry(@id)
    Map.put(context, :plugin, @id)
  end

  @doc "Calls `Host.<api>(id, method, input)` from the plugin; the answer is `context.reply`."
  def call(context, api, method, input) do
    {reply, context} =
      World.call(context, "plugins.call", %{
        "id" => context.plugin,
        "method" => "host",
        "input" => %{"api" => api, "method" => method, "input" => input}
      })

    Map.put(context, :reply, reply)
  end

  @doc "Like `call/4`, asserting success; returns `{result, context}`."
  def call!(context, api, method, input) do
    context = call(context, api, method, input)

    case context.reply do
      {:ok, result} -> {result, context}
      {:error, error, _} -> flunk("#{api}.#{method} failed: #{error}")
    end
  end

  @doc "The message of the refused last call."
  def refusal(context) do
    assert {:error, message, _} = context.reply
    message
  end

  defp source do
    """
    defmodule HalC2PluginFixture.HostProbe do
      @behaviour HalC2.Plugins.Extension
      alias HalC2.Plugins.Host

      @impl true
      def call("host", %{"api" => api, "method" => method, "input" => input}, _context),
        do: apply(Host, String.to_existing_atom(api), [#{inspect(@id)}, method, input])

      def call(method, _input, _context), do: {:error, "no method " <> method}
    end
    """
  end
end
