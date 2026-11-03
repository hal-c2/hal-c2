defmodule HalC2.Test.Services do
  @moduledoc """
  A supervisor of the MC's for upgrade scenarios, started under `HalC2.Supervisor`
  where a release upgrade finds it: a boot task that has run, a service a new
  version drops and one whose spec it changes. `next/0` is the source of that new
  version.
  """
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: Supervisor.init(children(), strategy: :one_for_one)

  def children do
    [
      Supervisor.child_spec({Task, &HalC2.Test.Services.backfill/0}, id: :search_backfill),
      {Registry, keys: :unique, name: HalC2.Test.OldService},
      Supervisor.child_spec({Agent, &HalC2.Test.Services.state/0}, id: :changed_service)
    ]
  end

  def backfill, do: :ok
  def state, do: 1

  @doc "The source of a version that adds two services, one failing, and changes two."
  def next do
    """
    defmodule HalC2.Test.Services do
      use Supervisor

      def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

      @impl true
      def init(_), do: Supervisor.init(children(), strategy: :one_for_one)

      def children do
        [
          Supervisor.child_spec({Task, &HalC2.Test.Services.backfill_again/0}, id: :search_backfill),
          {Registry, keys: :unique, name: HalC2.Test.NewService},
          %{id: :broken_service, start: {HalC2.Test.Services, :broken, []}},
          Supervisor.child_spec({Agent, &HalC2.Test.Services.state_again/0}, id: :changed_service)
        ]
      end

      def backfill, do: :ok
      def backfill_again, do: :ok
      def state, do: 1
      def state_again, do: 2
      def broken, do: {:error, :boom}
      def next, do: nil
    end
    """
  end
end

defmodule HalC2.Test.Shaped do
  @moduledoc """
  A service of the MC's whose state a new version (`next/0`) keeps in another shape,
  migrated by its `code_change/3` in a release upgrade.
  """
  use GenServer

  def start_link(n), do: GenServer.start_link(__MODULE__, n, name: __MODULE__)
  def state, do: GenServer.call(__MODULE__, :state)

  @impl true
  def init(n), do: {:ok, {:v1, n}}

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @doc "The source of the version that keeps `{:v2, n, history}`."
  def next do
    """
    defmodule HalC2.Test.Shaped do
      use GenServer

      def start_link(n), do: GenServer.start_link(__MODULE__, n, name: __MODULE__)
      def state, do: GenServer.call(__MODULE__, :state)

      @impl true
      def init(n), do: {:ok, {:v2, n, []}}

      @impl true
      def handle_call(:state, _from, state), do: {:reply, state, state}

      @impl true
      def code_change(_old, {:v1, n}, _extra), do: {:ok, {:v2, n, [:migrated]}}

      def next, do: nil
    end
    """
  end
end

defmodule HalC2.Test.Compile do
  @moduledoc "Compiles another version of a loaded module without leaving it loaded."
  def beam(mod, source) do
    {^mod, original, file} = :code.get_object_code(mod)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      [{^mod, beam}] = Code.compile_string(source)
      beam
    after
      Code.put_compiler_option(:ignore_module_conflict, false)
      :code.purge(mod)
      {:module, ^mod} = :code.load_binary(mod, file, original)
      :code.purge(mod)
    end
  end
end
