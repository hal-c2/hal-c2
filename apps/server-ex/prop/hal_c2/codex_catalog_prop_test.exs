defmodule HalC2.CodexCatalogPropTest do
  @moduledoc """
  A state machine over Codex's model check (`HalC2.Codex.Provider.load/0`) for a
  ChatGPT account whose models come from Codex's shared catalog cache
  (`$CODEX_HOME/models_cache.json`, pingdotgg/t3code#18200): the account gains or
  loses the Ultrafast tier, another Codex client on the machine rewrites the cache
  with or without it, and the MC checks Codex or reads what it last found.

  The promise: a check lists Ultrafast exactly when the account is entitled to it at
  that check, whatever another client last wrote to the cache, and between checks
  the MC shows what its last check found.

  The app-server is the fake in `test/support/fake_codex.py` playing the catalog
  (`fake_codex_models.py`): its first model list refreshes the cache for its own
  originator, as Codex's backend fetch does.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @sol "gpt-6.1-sol"

  property "a Codex check lists Ultrafast exactly when the account has it",
    numtests: HalC2.Prop.numtests(15),
    max_size: 10 do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        start()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        HalC2.Prop.restore_env()
        :persistent_term.erase({HalC2.Codex.Provider, :models})

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp start do
    home = HalC2.Prop.scratch_home("codex-catalog")
    codex_home = Path.join(home, "codex-home")
    File.mkdir_p!(codex_home)
    HalC2.Prop.put_env(:codex_command, ["python3", "-u", @fake_codex])
    HalC2.Prop.put_system_env("CODEX_HOME", codex_home)
    HalC2.Prop.put_system_env("FAKE_CODEX_ACCOUNT", "chatgpt")
    HalC2.Prop.put_system_env("FAKE_CODEX_CATALOG", "1")
    HalC2.Prop.put_system_env("FAKE_ULTRAFAST_ENTITLED", "0")
    HalC2.Prop.put_system_env("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", nil)
    :persistent_term.erase({HalC2.Codex.Provider, :models})

    HalC2.Prop.start_services([
      {HalC2.Store, path: Path.join(home, "hal-c2.sqlite")},
      HalC2.Settings
    ])

    # The entry's update advisory must not reach a package registry.
    {doc, version} = HalC2.Settings.get()
    {:ok, _} = HalC2.Settings.put(Map.put(doc, "enableProviderUpdateChecks", false), version)
    write_cache(false)
  end

  # --- model ---------------------------------------------------------------------

  # entitled: whether the account has Ultrafast now; listed: whether the MC's last
  # check listed it, nil before a check.
  def initial_state, do: %{entitled: false, listed: nil}

  def command(_state) do
    frequency([
      {2, {:call, __MODULE__, :entitle, [boolean()]}},
      {2, {:call, __MODULE__, :other_client, [boolean()]}},
      {3, {:call, __MODULE__, :check, []}},
      {1, {:call, __MODULE__, :read, []}}
    ])
  end

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :entitle, [entitled]}),
    do: %{state | entitled: entitled}

  def next_state(state, _result, {:call, _, :check, []}), do: %{state | listed: state.entitled}
  def next_state(state, _result, _call), do: state

  def postcondition(state, {:call, _, :check, []}, seen), do: seen == state.entitled
  def postcondition(state, {:call, _, :read, []}, seen), do: seen == state.listed
  def postcondition(_state, _call, seen), do: seen == :ok

  # --- commands ------------------------------------------------------------------

  def entitle(entitled) do
    HalC2.Prop.put_system_env("FAKE_ULTRAFAST_ENTITLED", if(entitled, do: "1", else: "0"))
    :ok
  end

  # Another Codex client (the plain CLI, or an app entitled to more) wrote the
  # cache a minute ago.
  def other_client(ultrafast), do: write_cache(ultrafast)

  def check do
    HalC2.Codex.Provider.load()
    read()
  end

  # Whether the MC's entry offers Ultrafast for the model, nil while it shows none.
  def read do
    with %{"models" => models} <- HalC2.Codex.Provider.entry("codex"),
         %{"capabilities" => %{"optionDescriptors" => descriptors}} <-
           Enum.find(models, &(&1["slug"] == @sol)),
         %{"options" => options} <- Enum.find(descriptors, &(&1["id"] == "serviceTier")) do
      Enum.any?(options, &(&1["id"] == "ultrafast"))
    else
      _ -> nil
    end
  end

  # --- the real side ---------------------------------------------------------------

  defp write_cache(ultrafast) do
    fetched = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    tiers = if ultrafast, do: ~w(priority ultrafast), else: ~w(priority)

    model = %{
      "id" => @sol,
      "model" => @sol,
      "displayName" => "GPT-6.1 Sol",
      "description" => "",
      "hidden" => false,
      "isDefault" => true,
      "serviceTiers" => for(t <- tiers, do: %{"id" => t, "name" => t, "description" => ""})
    }

    File.write!(
      Path.join(System.fetch_env!("CODEX_HOME"), "models_cache.json"),
      JSON.encode!(%{"fetched_at" => fetched, "models" => [model]})
    )

    :ok
  end
end
