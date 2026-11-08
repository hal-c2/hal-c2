defmodule HalC2.CodexChatGptPropTest do
  @moduledoc """
  `HalC2.Codex.ChatGpt`'s account against a model of two Codex instances on one
  shared home, each on the CLI's login or on a ChatGPT account HAL-C2 connects.

  Sign-ins arrive the ways they do in production: a login moved here
  (`adopt/3`), and Codex itself writing or losing the login in the instance's
  own home (a sign-in, a revoked token). The remembered account follows what a
  usage probe last saw of a managed instance: signed in as the login's account,
  or signed out with its email kept. A disconnect (`logout/1`) removes the login
  and keeps the email. An instance on the CLI's login is never touched, and one
  instance's mode, login or account never reaches the other's.
  """

  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias HalC2.Codex.ChatGpt
  alias HalC2.ProviderUsageLimits, as: Limits
  alias HalC2.Settings

  @moduletag timeout: :infinity
  @moduletag capture_log: true

  @fake_codex Path.expand("../../test/support/fake_codex.py", __DIR__)
  @instances ~w(codex codex-work)

  property "a connected ChatGPT account follows its login and stays its instance's own",
    numtests: HalC2.Prop.numtests(15) do
    forall cmds <- commands(__MODULE__) do
      trap_exit do
        setup()
        {history, state, result} = run_commands(__MODULE__, cmds)
        HalC2.Prop.stop_services()
        System.delete_env("FAKE_CODEX_CHATGPT")

        (result == :ok)
        |> when_fail(IO.puts(HalC2.Prop.report(cmds, history, state, result)))
        |> aggregate(command_names(cmds))
      end
    end
  end

  defp setup do
    home = HalC2.Prop.scratch_home("codex-chatgpt")
    shared = Path.join(home, "codex")
    File.mkdir_p!(shared)
    System.put_env("FAKE_CODEX_CHATGPT", "1")
    Application.put_env(:hal_c2, :codex_command, ["python3", @fake_codex])
    HalC2.Prop.start_services([Settings, Limits])

    {:ok, _} =
      Settings.put(
        %{
          "providers" => %{"codex" => %{"homePath" => shared}},
          "providerInstances" => %{
            "codex-work" => %{"driver" => "codex", "enabled" => true, "displayName" => "Work"}
          }
        },
        0
      )

    drain()
  end

  # --- the model -----------------------------------------------------------------
  #
  # Per instance: its mode, the account its home's login is (`{email, plan}`, or
  # nil), and the remembered account (`{email, plan, signed_in?}`, or nil).

  def initial_state,
    do: Map.new(@instances, &{&1, %{mode: "existing", login: nil, record: nil}})

  def command(_state) do
    instance = oneof(@instances)
    account = {oneof(~w(a@example.com b@example.com)), oneof(~w(plus pro))}

    frequency([
      {3, {:call, __MODULE__, :probe, [instance]}},
      {2, {:call, __MODULE__, :set_mode, [instance, oneof(~w(managed existing))]}},
      {2, {:call, __MODULE__, :adopt, [instance, account]}},
      {2, {:call, __MODULE__, :codex_signs_in, [instance, account]}},
      {1, {:call, __MODULE__, :codex_loses_login, [instance]}},
      {2, {:call, __MODULE__, :logout, [instance]}},
      {1, {:call, __MODULE__, :restart_limits, []}}
    ])
  end

  # A mode set to what it is changes no setting, so it probes nothing.
  def precondition(state, {:call, _, :set_mode, [instance, mode]}),
    do: state[instance].mode != mode

  # A disconnect is offered for a managed instance only (`HalC2.ProviderAuth`).
  def precondition(state, {:call, _, :logout, [instance]}),
    do: state[instance].mode == "managed"

  def precondition(_state, _call), do: true

  def next_state(state, _result, {:call, _, :probe, [instance]}), do: probed(state, instance)

  # A changed instance is read again at once.
  def next_state(state, _result, {:call, _, :set_mode, [instance, mode]}),
    do: state |> put_in([instance, :mode], mode) |> probed(instance)

  def next_state(state, _result, {:call, _, :adopt, [instance, {email, plan}]}),
    do:
      Map.put(state, instance, %{
        mode: "managed",
        login: {email, plan},
        record: {email, plan, true}
      })

  def next_state(state, _result, {:call, _, :codex_signs_in, [instance, account]}),
    do: put_in(state, [instance, :login], account)

  def next_state(state, _result, {:call, _, :codex_loses_login, [instance]}),
    do: put_in(state, [instance, :login], nil)

  def next_state(state, _result, {:call, _, :logout, [instance]}),
    do: state |> put_in([instance, :login], nil) |> signed_out(instance)

  # A restarted service reads every instance again.
  def next_state(state, _result, {:call, _, :restart_limits, []}),
    do: Enum.reduce(@instances, state, &probed(&2, &1))

  defp probed(state, instance) do
    case state[instance] do
      %{mode: "managed", login: {email, plan}} ->
        put_in(state, [instance, :record], {email, plan, true})

      %{mode: "managed", login: nil} ->
        signed_out(state, instance)

      _existing ->
        state
    end
  end

  defp signed_out(state, instance) do
    case state[instance].record do
      {email, plan, _} -> put_in(state, [instance, :record], {email, plan, false})
      nil -> state
    end
  end

  def postcondition(state, call, _result) do
    after_call = next_state(state, nil, call)
    Enum.all?(@instances, &matches?(&1, after_call[&1]))
  end

  defp matches?(instance, model) do
    record =
      case ChatGpt.record(instance) do
        %{"email" => email, "planType" => plan, "signedIn" => signed_in?} ->
          {email, plan, signed_in?}

        nil ->
          nil
      end

    {:ok, [method]} = ChatGpt.methods(instance)
    email = with {email, _plan, _} <- model.record, do: email

    record == model.record and method["accountEmail"] == email and
      ChatGpt.managed?(instance) == (model.mode == "managed") and
      login(instance) == model.login
  end

  # --- the commands ------------------------------------------------------------------

  def probe(instance), do: Limits.refresh([instance])

  def set_mode(instance, mode) do
    {:ok, _} =
      Settings.update(fn settings ->
        path =
          if instance == "codex",
            do: [Access.key("providers", %{}), Access.key("codex", %{})],
            else: [Access.key("providerInstances", %{}), instance, Access.key("config", %{})]

        put_in(settings, path ++ ["setupMode"], mode)
      end)

    drain()
  end

  def adopt(instance, {email, plan}) do
    result =
      ChatGpt.adopt(instance, login_file(email, plan), %{"email" => email, "planType" => plan})

    drain()
    result
  end

  # As Codex writes its own login in the instance's home.
  def codex_signs_in(instance, {email, plan}),
    do: File.write!(login_path(instance), login_file(email, plan))

  def codex_loses_login(instance) do
    File.rm(login_path(instance))
    :ok
  end

  def logout(instance) do
    result = ChatGpt.logout(instance)
    drain()
    result
  end

  def restart_limits do
    HalC2.Prop.restart_service(Limits)
    drain()
  end

  # The usage service probes in its own process, a settings change's probe
  # included: an empty refresh returns once everything queued before it is done.
  defp drain, do: Limits.refresh([])

  defp login_path(instance), do: Path.join(ChatGpt.home(instance), "auth.json")

  # A login as the fake Codex (test/support/fake_codex_chatgpt.py) writes it.
  defp login_file(email, plan),
    do:
      JSON.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{"refresh_token" => "fake"},
        "fake_account" => %{"email" => email, "planType" => plan}
      })

  defp login(instance) do
    with {:ok, bytes} <- File.read(login_path(instance)),
         {:ok, %{"fake_account" => %{"email" => email, "planType" => plan}}} <-
           JSON.decode(bytes) do
      {email, plan}
    else
      _ -> nil
    end
  end
end
