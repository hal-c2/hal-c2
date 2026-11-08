defmodule HalC2.AcpCatalogPropTest do
  @moduledoc """
  The registry index cache of `HalC2.Acp.Catalog`, against a model of when a
  read fetches. Reads come as searches (a copy fetched in the last five
  minutes stands), plain reads (a copy fetched today stands) and forced
  reads (always fetch); the registry goes up and down between them, the
  cached copy ages past five minutes, and a recorded failure ages past its
  backoff. Whatever the order:

  - a read fetches exactly when the model says the copy it holds does not
    stand for that kind of read;
  - after a failed fetch, searches serve the cached copy without fetching
    again until the backoff passes, instead of each fetching in turn;
  - a read answers with the agents when it holds a copy or the registry
    answers, and with an error only when it has neither.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity

  defmodule Registry do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, {agent, body}) do
      mode = Agent.get_and_update(agent, fn {mode, n} -> {mode, {mode, n + 1}} end)

      if mode == :up,
        do: Plug.Conn.send_resp(conn, 200, body),
        else: Plug.Conn.send_resp(conn, 500, "")
    end
  end

  property "reads fetch exactly when the cached copy does not stand for them",
    numtests: HalC2.Prop.numtests(60),
    max_size: 20 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start_case()
        {history, state, result} = run_commands(__MODULE__, cmds)
        end_case()

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start_case do
    HalC2.Prop.scratch_home("acp-catalog")
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    :persistent_term.erase({HalC2.Acp.Catalog, :fetch_failed_at})

    {:ok, agent} = Agent.start_link(fn -> {:up, 0} end)
    Process.put(:registry, agent)

    body =
      JSON.encode!(%{
        "version" => "1.0.0",
        "agents" => [
          %{
            "id" => "prop-agent",
            "name" => "Prop Agent",
            "version" => "1.0.0",
            "description" => "A test agent",
            "distribution" => %{
              "binary" => %{
                HalC2.Acp.Catalog.platform() => %{
                  "archive" => "https://example.com/prop.tar.gz",
                  "cmd" => "./bin/prop"
                }
              }
            }
          }
        ]
      })

    HalC2.Prop.start_services([
      {Bandit, plug: {Registry, {agent, body}}, port: 0, ip: :loopback}
    ])

    sup = Process.get({HalC2.Prop, :services})
    [{_, server, _, _}] = Supervisor.which_children(sup)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:hal_c2, :acp_registry_url, "http://127.0.0.1:#{port}/registry.json")
  end

  defp end_case do
    HalC2.Prop.stop_services()
    Agent.stop(Process.get(:registry))
    Application.delete_env(:hal_c2, :acp_registry_url)
    :persistent_term.erase({HalC2.Acp.Catalog, :index})
    :persistent_term.erase({HalC2.Acp.Catalog, :fetch_failed_at})
  end

  # --- model ----------------------------------------------------------------------

  # cached: a copy is held; fresh: no fetch has failed since it was fetched;
  # young: fetched under five minutes ago (ageing makes it ten minutes old,
  # still under a day); failed: when the last failed fetch was recorded.
  def initial_state, do: %{cached: false, fresh: false, young: true, failed: :none, up: true}

  def command(_state) do
    frequency([
      {3, {:call, __MODULE__, :read, [:search]}},
      {2, {:call, __MODULE__, :read, [:plain]}},
      {2, {:call, __MODULE__, :read, [:forced]}},
      {1, {:call, __MODULE__, :set_registry, [:up]}},
      {1, {:call, __MODULE__, :set_registry, [:down]}},
      {1, {:call, __MODULE__, :age_cache, []}},
      {1, {:call, __MODULE__, :age_failure, []}}
    ])
  end

  def precondition(state, {:call, _, :age_cache, []}), do: state.cached and state.young
  def precondition(state, {:call, _, :age_failure, []}), do: state.failed == :recent
  def precondition(_state, _call), do: true

  defp fetches?(_state, :forced), do: true
  defp fetches?(%{cached: false}, _mode), do: true
  defp fetches?(_state, :plain), do: false

  defp fetches?(state, :search),
    do: not ((state.fresh and state.young) or state.failed == :recent)

  def next_state(state, _result, {:call, _, :read, [mode]}) do
    if fetches?(state, mode) do
      cond do
        state.up -> %{state | cached: true, fresh: true, young: true, failed: :none}
        state.cached -> %{state | fresh: false, failed: :recent}
        true -> state
      end
    else
      state
    end
  end

  def next_state(state, _result, {:call, _, :set_registry, [mode]}),
    do: %{state | up: mode == :up}

  def next_state(state, _result, {:call, _, :age_cache, []}), do: %{state | young: false}
  def next_state(state, _result, {:call, _, :age_failure, []}), do: %{state | failed: :old}
  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :read, [mode]}, {ok, fetched}) do
    ok == (state.cached or state.up) and fetched == if(fetches?(state, mode), do: 1, else: 0)
  end

  def postcondition(_state, _call, _result), do: true

  # --- commands -------------------------------------------------------------------

  def read(mode) do
    before = count()

    result =
      case mode do
        :search -> HalC2.Acp.Catalog.index(:search)
        :plain -> HalC2.Acp.Catalog.index(false)
        :forced -> HalC2.Acp.Catalog.index(true)
      end

    {match?({:ok, _}, result), count() - before}
  end

  def set_registry(mode) do
    Agent.update(Process.get(:registry), fn {_, n} -> {mode, n} end)
  end

  def age_cache do
    {_, agents, fresh} = :persistent_term.get({HalC2.Acp.Catalog, :index})
    at = System.system_time(:millisecond) - 10 * 60_000
    :persistent_term.put({HalC2.Acp.Catalog, :index}, {at, agents, fresh})
  end

  def age_failure do
    at = System.system_time(:millisecond) - 60_000
    :persistent_term.put({HalC2.Acp.Catalog, :fetch_failed_at}, at)
  end

  defp count, do: Agent.get(Process.get(:registry), &elem(&1, 1))
end
