defmodule HalC2.Prop.Upgrade do
  @moduledoc """
  The services `prop/hal_c2/upgrade_release_prop_test.exs` upgrades in place, as
  Erlang source of any version, compiled without loading (`beam/1`): a GenServer
  whose state each version may keep in another shape, and a supervisor whose
  children each version may change. Their stubs below make them modules of the MC's
  application, as the release handler and `HalC2.Upgrade.Tree` need.
  """

  @counter HalC2.Prop.Upgrade.Counter
  @sup HalC2.Prop.Upgrade.Sup

  def counter, do: @counter
  def sup, do: @sup

  @doc """
  Version `vsn` of the counter: its state is `{shape, history}`, and `code_change/3`
  moves a state of another shape to `shape`, adding the old shape to the history.
  `linger/1` keeps a process in this version's code until it is sent `:go`. A
  `raising` version's `code_change/3` raises instead.
  """
  def counter(vsn, shape, raising \\ false) do
    m = atom(@counter)

    code_change =
      if raising,
        do: "code_change(_Old, _St, _Extra) -> erlang:error(migration_broke).",
        else: """
        code_change(_Old, {#{shape}, H}, _Extra) -> {ok, {#{shape}, H}};
        code_change(_Old, {Old, H}, _Extra) -> {ok, {#{shape}, H ++ [Old]}}.
        """

    beam("""
    -module(#{m}).
    -behaviour(gen_server).
    -export([start_link/1, state/0, vsn/0, linger/1, init/1, handle_call/3, handle_cast/2, code_change/3]).
    start_link(_) -> gen_server:start_link({local, #{m}}, #{m}, nil, []).
    state() -> gen_server:call(#{m}, state).
    vsn() -> #{vsn}.
    linger(Parent) -> Parent ! {lingering, self()}, receive go -> ok end.
    init(_) -> {ok, {#{shape}, []}}.
    handle_call(state, _From, St) -> {reply, St, St}.
    handle_cast(_Msg, St) -> {noreply, St}.
    #{code_change}
    """)
  end

  @doc "Version `vsn` of the supervisor, its children Agents `%{id => value}`."
  def sup(vsn, children) do
    m = atom(@sup)

    specs =
      Enum.map_join(Enum.sort(children), ", ", fn {id, value} ->
        "\#{id => #{id}, start => {'Elixir.Agent', start_link, [#{m}, value, [#{value}]]}}"
      end)

    beam("""
    -module(#{m}).
    -behaviour(supervisor).
    -export([start_link/1, init/1, vsn/0, value/1]).
    start_link(_) -> supervisor:start_link({local, #{m}}, #{m}, []).
    vsn() -> #{vsn}.
    value(V) -> V.
    init(_) -> {ok, {\#{strategy => one_for_one}, [#{specs}]}}.
    """)
  end

  defp atom(mod), do: "'#{mod}'"

  defp beam(source) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))

    forms =
      tokens
      |> Enum.chunk_while(
        [],
        fn
          {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
          token, acc -> {:cont, [token | acc]}
        end,
        fn [] -> {:cont, []} end
      )
      |> Enum.map(fn form ->
        {:ok, parsed} = :erl_parse.parse_form(form)
        parsed
      end)

    {:ok, _mod, beam} = :compile.forms(forms, [:binary, :return_errors])
    beam
  end
end

defmodule HalC2.Prop.Upgrade.Counter do
  @moduledoc false
  # A stub: each case loads a version of `HalC2.Prop.Upgrade.counter/2` in its place.
  def vsn, do: :stub
end

defmodule HalC2.Prop.Upgrade.Sup do
  @moduledoc false
  # A stub: each case loads a version of `HalC2.Prop.Upgrade.sup/2` in its place.
  def vsn, do: :stub
end
