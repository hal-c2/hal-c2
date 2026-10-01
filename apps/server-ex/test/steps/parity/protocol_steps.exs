defmodule HalC2.Steps.Parity.Protocol do
  @moduledoc """
  Steps for `features/parity/protocol.feature`: the protocol 3 wire as a client
  sees it. Shapes are subscribed and driven through `HalC2.Steps.Parity.Shapes`;
  the frame a scenario checks is `context.received`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Steps.Parity.Fixtures
  alias HalC2.Steps.Parity.Shapes
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Test.WsClient

  step "a protocol 3 client connected to it", context do
    World.put_client(context, Mc.connect(context.mc))
  end

  # --- greeting --------------------------------------------------------------------

  step "the client opens its socket", context do
    Map.put(context, :received, Shapes.open_socket(context))
  end

  step "the first frame is a hello carrying protocol 3, the MC's name and its environment",
       context do
    me = Atom.to_string(node())
    environment = HalC2.Environment.id()

    assert %{"t" => "hello", "protocol" => 3, "mc" => ^me, "environment" => ^environment} =
             context.received

    context
  end

  # --- client frames ---------------------------------------------------------------

  step ~r/^the client sends an? (?<frame>sub|unsub|ping|rpc) frame with (?<fields>.+)$/,
       %{args: [frame, _fields]} = context do
    context = Fixtures.setup(context)
    client = World.client(context)

    case frame do
      "sub" ->
        message = %{"t" => "sub", "id" => 1, "shape" => %{"type" => "shell"}, "offset" => nil}
        client = WsClient.send_json(client, message)
        context |> World.put_client(client) |> Map.put(:sent, %{id: 1})

      "unsub" ->
        context = Shapes.subscribe(context, "scheduledTasks")
        id = context.shape.id
        client = Mc.unsub(World.client(context), id)
        # The unsub is behind the pong, so the MC has dropped the shape after it.
        client = Shapes.quiet(client, id)
        context |> World.put_client(client) |> Map.put(:sent, %{id: id})

      "ping" ->
        World.put_client(context, WsClient.send_json(client, %{"t" => "ping"}))

      "rpc" ->
        # The payload is optional: this one has none.
        message = %{"t" => "rpc", "id" => 7, "environment" => context.mc.environment}
        message = Map.put(message, "method", "hal-c2.readSettings")
        client = WsClient.send_json(client, message)
        context |> World.put_client(client) |> Map.put(:sent, %{id: 7})
    end
  end

  step ~r/^the MC answers with (?<answer>the shape's first frames under that id|nothing further under that id|an rpc\.result or an rpc\.error under that id)$/,
       %{args: [answer]} = context do
    id = context.sent.id

    case answer do
      "the shape's first frames under that id" ->
        {frame, client} = Mc.await(World.client(context), &(&1["id"] == id))
        assert %{"t" => "shell", "mcs" => [_ | _], "rows" => rows} = frame
        assert is_list(rows)
        World.put_client(context, client)

      "nothing further under that id" ->
        {:ok, _} = HalC2.ScheduledTasks.upsert(Fixtures.task())
        World.put_client(context, Shapes.quiet(World.client(context), id))

      "an rpc.result or an rpc.error under that id" ->
        {frame, client} = Mc.await(World.client(context), Mc.reply?(id))
        assert %{"t" => "rpc.result", "result" => %{"settings" => %{}}} = frame
        World.put_client(context, client)
    end
  end

  # --- shapes ----------------------------------------------------------------------

  step ~r/^the client subscribes to an? (?<shape>\w+) shape with (?<fields>.+)$/,
       %{args: [type, fields]} = context do
    form =
      cond do
        "environment" in String.split(fields, ", ") -> "environment"
        fields == "links" -> "links"
        true -> "mc"
      end

    context = Shapes.subscribe(context, type, form)
    expected = if fields == "none", do: [], else: String.split(fields, ", ")
    assert Enum.sort(Map.keys(context.shape.map)) == Enum.sort(expected)
    context
  end

  step ~r/^the first frame under that id is (?<text>.+)$/, %{args: [_text]} = context do
    Shapes.check_first(context)
    context
  end

  step ~r/^later changes arrive as (?<text>.+)$/, %{args: [text]} = context do
    %{type: type, form: form} = context.shape
    later = Shapes.later(type, form)

    if form == "environment",
      do: assert(text == "the same frames as the MC form"),
      else: for(t <- later, do: assert(String.contains?(text, t), "#{t} is not in #{text}"))

    Enum.reduce(later, context, fn t, context ->
      {frame, context} = Shapes.trigger(context, t)
      assert frame["t"] == t and frame["id"] == context.shape.id
      context
    end)
  end

  # The methods a shape replaces are not rpc methods on the MC.
  step ~r/^the shape stands in for (?<replaces>.+)$/, %{args: [replaces]} = context do
    replaces
    |> String.split([", ", " and "])
    |> Enum.reduce(context, fn method, context ->
      {reply, context} = World.call(context, method, %{})
      assert {:error, error, _} = reply
      assert error == "#{method} is not served by this MC yet"
      context
    end)
  end

  # --- frames the MC sends -------------------------------------------------------

  step ~r/^the client is subscribed to a shape that uses (?<frame>[\w.]+) frames$/,
       %{args: [frame]} = context do
    context = Fixtures.setup(context)

    case Shapes.shape_for(frame) do
      nil -> World.put_client(context, World.client(context))
      # These frames are the subscription opening; the When subscribes.
      _ when frame in ~w(shell snapshot config) -> context
      type -> Shapes.subscribe(context, type, Shapes.form_for(frame))
    end
  end

  step ~r/^the client is subscribed to an? (?<shape>\w+) shape$/, %{args: [type]} = context do
    Shapes.subscribe(context, type)
  end

  @whens %{
    "the socket opens" => "hello",
    "the client pings" => "pong",
    "a frame or subscription is refused" => "error",
    "a method succeeds" => "rpc.result",
    "a method fails" => "rpc.error",
    "the shell subscription opens" => "shell",
    "projects or threads on one MC change" => "shell.rows",
    "an MC's environment descriptor changes" => "shell.environment",
    "an MC joins or leaves the cluster" => "shell.mc",
    "the environments the MC links to change" => "shell.links",
    "a linked environment's projects or threads change" => "shell.linkRows",
    "a linked environment's MC descriptor changes" => "shell.linkEnvironment",
    "a linked environment's MC comes online or goes offline" => "shell.linkMc",
    "a stream subscription starts or falls too far behind" => "snapshot",
    "stream entities change" => "events",
    "a stream has caught up" => "live",
    "a client falls behind" => "resync",
    "a shape is over" => "end",
    "a config subscription opens" => "config",
    "the MC moves to another version in place" => "config.ready",
    "the MC's settings change" => "config.settings",
    "the MC's published themes change" => "config.themes",
    "the MC's usage limit sources change" => "config.usageLimitSources",
    "the MC's keybinding rules change" => "config.keybindings",
    "the MC's providers change" => "config.providers",
    "an attached terminal emits" => "terminal",
    "terminal summaries change" => "terminals",
    "a checkout's status changes" => "vcs",
    "a provider's sign-in state changes" => "providerAuth",
    "a thread's worktree setup progresses" => "worktreeSetup",
    "a scheduled task changes" => "scheduledTasks",
    "a pairing link or paired client changes" => "authAccess",
    "a project clone progresses" => "projectClones",
    "pull requests are refreshed" => "pullRequestRefreshes",
    "a preview tab changes" => "preview",
    "an agent drives the client's browser" => "previewAutomation",
    "the resource monitor takes a sample" => "resourceTelemetry",
    "a web server starts or stops on the host" => "localServers",
    "a simulator, emulator or device session changes" => "devices",
    "a git action progresses" => "gitAction",
    "a version move progresses" => "serverUpdate",
    "a managed runtime installation progresses" => "providerInstall",
    "the relay client install progresses" => "relayClientInstall"
  }

  step ~r/^(?<when>the socket opens|the client pings|a frame or subscription is refused|a method succeeds|a method fails|the shell subscription opens|projects or threads on one MC change|an MC's environment descriptor changes|an MC joins or leaves the cluster|the environments the MC links to change|a linked environment's projects or threads change|a linked environment's MC descriptor changes|a linked environment's MC comes online or goes offline|a stream subscription starts or falls too far behind|stream entities change|a stream has caught up|a client falls behind|a shape is over|a config subscription opens|the MC moves to another version in place|the MC's settings change|the MC's published themes change|the MC's usage limit sources change|the MC's keybinding rules change|the MC's providers change|an attached terminal emits|terminal summaries change|a checkout's status changes|a provider's sign-in state changes|a thread's worktree setup progresses|a scheduled task changes|a pairing link or paired client changes|a project clone progresses|pull requests are refreshed|a preview tab changes|an agent drives the client's browser|the resource monitor takes a sample|a web server starts or stops on the host|a simulator, emulator or device session changes|a git action progresses|a version move progresses|a managed runtime installation progresses|the relay client install progresses)$/,
       %{args: [text]} = context do
    frame = Map.fetch!(@whens, text)

    {received, context} =
      case frame do
        "hello" ->
          {Shapes.open_socket(context), context}

        "pong" ->
          client = WsClient.send_json(World.client(context), %{"t" => "ping"})
          {frame, client} = WsClient.recv(client, 1_000)
          {frame, World.put_client(context, client)}

        "error" ->
          shape = %{"type" => "config", "environment" => "env-missing"}
          client = Mc.sub(World.client(context), 31, shape)
          {frame, client} = Mc.await(client, &(&1["id"] == 31))
          {frame, World.put_client(context, client)}

        "rpc.result" ->
          reply(context, 32, "hal-c2.readSettings", %{})

        "rpc.error" ->
          reply(context, 33, "hal-c2.writeSettings", %{"settings" => %{}, "version" => -1})

        opening when opening in ~w(shell snapshot config) ->
          context = Shapes.subscribe(context, Shapes.shape_for(opening))
          {hd(context.shape.first), context}

        _ ->
          Shapes.trigger(context, frame)
      end

    Map.put(context, :received, received)
  end

  # The keys each frame carries besides `t`, from `apps/server-ex/lib/hal_c2/web/protocol.ex`.
  @carries %{
    "hello" => ~w(protocol mc environment),
    "pong" => [],
    "error" => ~w(id reason),
    "rpc.result" => ~w(id result),
    "rpc.error" => ~w(id error detail),
    "shell" => ~w(id mcs rows links),
    "shell.rows" => ~w(id mc rows),
    "shell.environment" => ~w(id mc environment),
    "shell.mc" => ~w(id mc online),
    "shell.links" => ~w(id links),
    "shell.linkRows" => ~w(id link mc rows),
    "shell.linkEnvironment" => ~w(id link mc environment),
    "shell.linkMc" => ~w(id link mc online),
    "snapshot" => ~w(id offset at part rows done),
    "events" => ~w(id offset events),
    "live" => ~w(id offset),
    "resync" => ~w(id offset),
    "end" => ~w(id),
    "config" => ~w(id mc config),
    "config.ready" => ~w(id environment updateOutcome),
    "config.settings" => ~w(id settings),
    "config.themes" => ~w(id themes),
    "config.usageLimitSources" => ~w(id sources),
    "config.keybindings" => ~w(id rules),
    "config.providers" => ~w(id providers),
    "providerAuth" => ~w(id state),
    "providerInstall" => ~w(id state),
    "scheduledTasks" => ~w(id tasks),
    "projectClones" => ~w(id clones),
    "pullRequestRefreshes" => ~w(id revision),
    "resourceTelemetry" => ~w(id snapshot),
    "localServers" => ~w(id list),
    "devices" => ~w(id state)
  }

  step ~r/^the client receives an? (?<frame>[\w.]+) frame carrying (?<fields>.+)$/,
       %{args: [t, _fields]} = context do
    frame = context.received
    assert frame["t"] == t, "expected a #{t} frame, got #{inspect(frame)}"
    keys = Map.get(@carries, t, ~w(id event))
    assert Enum.sort(Map.keys(frame) -- ["t"]) == Enum.sort(keys), inspect(frame)
    check_frame(t, frame)
    context
  end

  defp check_frame("shell", frame),
    do: for(n <- frame["mcs"], do: assert(Map.keys(n) -- ["mc"] == ~w(environment online)))

  defp check_frame("events", frame) do
    for [seq, kind, id, _patch, at] <- frame["events"],
        do: assert(is_integer(seq) and is_binary(kind) and is_binary(id) and is_integer(at))

    assert frame["events"] != []
  end

  defp check_frame("rpc.error", frame), do: assert(frame["detail"]["_tag"] == "StaleSettings")
  defp check_frame("config.keybindings", frame), do: assert(is_list(frame["rules"]))
  defp check_frame(_t, _frame), do: :ok

  defp reply(context, id, method, payload) do
    client = Mc.rpc(World.client(context), context.mc.environment, id, method, payload)
    {frame, client} = Mc.await(client, Mc.reply?(id))
    {frame, World.put_client(context, client)}
  end

  # --- shapes that end on their own ------------------------------------------------

  step ~r/^(?<ending>the action finishes or fails|the update completes|the update fails|the MC drops the client as its host|the relay client is found or installed)$/,
       %{args: [ending]} = context do
    id = context.shape.id

    {last, context} =
      case ending do
        "the action finishes or fails" ->
          done = &(&1["id"] == id and &1["event"]["kind"] in ~w(action_finished action_failed))
          {frame, client} = Mc.await(World.client(context), done, 10_000)
          {[frame], World.put_client(context, client)}

        "the update completes" ->
          Shapes.serve_bundle()
          complete? = &(&1["id"] == id and &1["event"]["type"] == "complete")
          {complete, client} = Mc.await(World.client(context), complete?, 5_000)
          {frame, client} = WsClient.recv(client, 2_000)
          {[complete, frame], World.put_client(context, client)}

        "the update fails" ->
          Shapes.refuse_bundle()
          {frame, client} = Mc.await(World.client(context), &(&1["t"] == "error"), 5_000)
          {[frame], World.put_client(context, client)}

        "the MC drops the client as its host" ->
          {frame, context} = Shapes.trigger(context, "end")
          {[frame], context}

        "the relay client is found or installed" ->
          {complete, context} = Shapes.trigger(context, "relayClientInstall")
          {frame, client} = Mc.await(World.client(context), &(&1["id"] == id), 2_000)
          {[complete, frame], World.put_client(context, client)}
      end

    Map.put(context, :last, last)
  end

  step ~r/^the MC sends (?<last>a gitAction frame with action_finished or action_failed|a serverUpdate frame with complete, then an end frame|an error frame with the reason and its detail|an end frame|a relayClientInstall frame with complete, then an end frame)$/,
       %{args: [last]} = context do
    id = context.shape.id

    case {last, context.last} do
      {"a gitAction frame with action_finished or action_failed", [frame]} ->
        assert %{"t" => "gitAction", "id" => ^id, "event" => %{"kind" => kind}} = frame
        assert kind in ~w(action_finished action_failed)

      {"a serverUpdate frame with complete, then an end frame", [complete, ending]} ->
        assert %{"t" => "serverUpdate", "id" => ^id, "event" => %{"type" => "complete"}} =
                 complete

        assert %{"t" => "end", "id" => ^id} = ending

      {"an error frame with the reason and its detail", [frame]} ->
        assert %{"t" => "error", "id" => ^id, "reason" => reason, "detail" => detail} = frame
        assert reason =~ "is not available"
        assert detail["_tag"] == "ServerSelfUpdateError" and detail["reason"] == reason

      {"an end frame", [frame]} ->
        assert frame == %{"t" => "end", "id" => id}

      {"a relayClientInstall frame with complete, then an end frame", [complete, ending]} ->
        assert %{"t" => "relayClientInstall", "event" => %{"type" => "complete"}} = complete
        assert %{"status" => %{"status" => "available"}} = complete["event"]
        assert ending == %{"t" => "end", "id" => id}
    end

    context
  end

  # An event for the ended shape reaches the socket and goes nowhere.
  step "the MC forgets the subscription", context do
    %{type: type, id: id} = context.shape
    {socket, context} = Shapes.socket_pid(context)

    late =
      case type do
        "gitAction" ->
          {:hal_c2_git_action, "parity-action", %{"kind" => "phase_started"}}

        "serverUpdate" ->
          {:hal_c2_server_update, node(), %{"type" => "progress"}}

        "previewAutomation" ->
          {:hal_c2_preview_automation, node(), "parity-host", %{"type" => "x"}}

        "relayClientInstall" ->
          {:hal_c2_relay_client_install, node(), %{"type" => "progress", "stage" => "checking"}}
      end

    send(socket, late)
    World.put_client(context, Shapes.quiet(World.client(context), id))
  end

  # --- refusals --------------------------------------------------------------------

  step ~r/^the MC answers with an? (?<frame>error|rpc\.error) frame whose reason is "(?<reason>[^"]+)"$/,
       %{args: [t, reason]} = context do
    frame = context.refusal

    case t do
      "error" -> assert %{"t" => "error", "reason" => ^reason} = frame
      "rpc.error" -> assert %{"t" => "rpc.error", "error" => ^reason <> _} = frame
    end

    context
  end

  # --- activity --------------------------------------------------------------------

  step "the client calls server.reportClientActivity in an rpc frame", context do
    {client, session} = Shapes.paired_client(context, "Activity")
    policy = Mc.ensure(HalC2.BackgroundPolicy)
    {socket, context} = Shapes.socket_pid(World.put_client(context, client))
    :erlang.trace(policy, true, [:receive])

    activity = %{"clientId" => "parity-client", "visible" => true, "ttlMs" => 60_000}
    {frame, context} = reply(context, 51, "server.reportClientActivity", activity)
    assert_receive {:trace, ^policy, :receive, {:"$gen_cast", {:lease, _, ^socket, _}}}, 2_000
    Map.merge(context, %{received: frame, activity: %{session: session, socket: socket}})
  end

  step "the MC records the activity lease for the client's session and socket", context do
    %{session: session, socket: socket} = context.activity
    leases = Map.values(:sys.get_state(HalC2.BackgroundPolicy).leases)
    lease = Enum.find(leases, &(&1["clientId"] == "parity-client"))
    assert lease, "no lease in #{inspect(leases)}"
    assert lease["sessionId"] == session
    assert lease["rpcClientId"] == inspect(socket)
    context
  end

  step "the rpc.result carries no result", context do
    assert %{"t" => "rpc.result", "id" => 51} = context.received
    assert Map.fetch(context.received, "result") == {:ok, nil}
    context
  end

  # --- the client adapter ----------------------------------------------------------

  @adapter_script Path.expand("../../support/v3_unsupported_call.ts", __DIR__)

  # A method the TypeScript client offers that the adapter does not carry.
  step "a client calls a method the protocol 3 adapter does not carry", context do
    {:ok, ticket, _} = ticket()
    url = "ws://127.0.0.1:#{context.mc.port}/ws?wsTicket=#{ticket}"
    args = [@adapter_script, url, context.mc.environment, "provider.install.start"]
    {out, status} = System.cmd("bun", args, stderr_to_stdout: true)
    assert status == 0, out
    line = out |> String.split("\n", trim: true) |> List.last()
    Map.put(context, :adapter, JSON.decode!(line))
  end

  step "the call fails in the client saying the method is not served by protocol-3 environments yet",
       context do
    assert context.adapter["error"] ==
             "provider.install.start is not served by protocol-3 environments yet"

    context
  end

  step "no frame is sent to the MC", context do
    assert context.adapter["sent"] == []
    context
  end

  defp ticket do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{
        "label" => "Adapter",
        "scopes" => HalC2.Auth.standard_scopes()
      })

    {:ok, access, _expires, _scopes} = HalC2.Auth.exchange(credential, %{"label" => "Adapter"})
    HalC2.Auth.issue_ticket(access)
  end
end

defmodule HalC2.Steps.Parity.Shapes do
  @moduledoc """
  Every protocol 3 shape, subscribed the way a client does and driven through the
  MC's own services: `subscribe/3` opens one on the default socket and records
  `context.shape` (`%{type, id, map, form, first}`), `trigger/2` makes the MC send
  a later frame of a type and returns it.
  """
  import ExUnit.Assertions

  alias HalC2.Steps.Parity.Fixtures
  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World
  alias HalC2.Test.WsClient

  @ids %{
    "shell" => 1,
    "stream" => 2,
    "config" => 3,
    "terminal" => 4,
    "terminals" => 5,
    "vcs" => 6,
    "providerAuth" => 7,
    "worktreeSetup" => 8,
    "scheduledTasks" => 9,
    "authAccess" => 10,
    "projectClones" => 11,
    "preview" => 12,
    "resourceTelemetry" => 13,
    "localServers" => 14,
    "devices" => 15,
    "previewAutomation" => 16,
    "pullRequestRefreshes" => 17,
    "gitAction" => 18,
    "serverUpdate" => 19,
    "providerInstall" => 20,
    "relayClientInstall" => 21
  }

  # The services an MC-wide shape reads, as `HalC2.Application` starts them.
  @services %{
    "scheduledTasks" => HalC2.ScheduledTasks,
    "projectClones" => HalC2.ProjectClones,
    "preview" => HalC2.Preview,
    "resourceTelemetry" => HalC2.Diagnostics,
    "localServers" => HalC2.LocalServers,
    "pullRequestRefreshes" => HalC2.PullRequests.Refreshes,
    "worktreeSetup" => HalC2.WorktreeSetup,
    "previewAutomation" => HalC2.PreviewAutomation
  }

  @gone :"gone@127.0.0.1"
  @fake_cloudflared Path.expand("../../support/fake_cloudflared.sh", __DIR__)
  @target "0.0.0-parity"

  @doc "The frame types a shape's first frames can be."
  def frame_types("stream"), do: ["snapshot"]
  def frame_types(type), do: [type]

  @doc "The shape a frame type belongs to; nil for socket frames."
  def shape_for(t) when t in ~w(hello pong error rpc.result rpc.error), do: nil
  def shape_for("shell" <> _), do: "shell"
  def shape_for(t) when t in ~w(snapshot events live resync), do: "stream"
  def shape_for("end"), do: "previewAutomation"
  def shape_for("config" <> _), do: "config"
  def shape_for(t), do: t

  @doc "The later frame types of a shape, in the order `trigger/2` can produce them."
  def later("shell"), do: ~w(shell.rows shell.environment shell.mc)
  def later("stream"), do: ~w(live events resync)

  def later("config"),
    do: ~w(config.settings config.providers config.keybindings config.themes
           config.usageLimitSources config.ready)

  def later(type), do: [type]

  def later("shell", "links"), do: ~w(shell.linkRows shell.linkEnvironment shell.linkMc)
  def later(type, _form), do: later(type)

  @doc "The form of the shape a frame type needs: a linked environment's frames need links."
  def form_for("shell.link" <> _), do: "links"
  def form_for(_t), do: "mc"

  @doc "Subscribes the default socket to `type` and collects its first frames."
  def subscribe(context, type, form \\ "mc") do
    context = Fixtures.setup(context)
    {map, context} = prepare(context, type, form)
    id = Map.fetch!(@ids, type)
    client = Mc.sub(World.client(context), id, Map.put(map, "type", type))
    {first, client} = first(client, type, id)

    for frame <- first,
        do: assert(frame["t"] != "error", "#{type} was refused: #{inspect(frame)}")

    shape = %{type: type, id: id, map: map, form: form, first: first}
    context |> World.put_client(client) |> Map.put(:shape, shape)
  end

  @doc "The first frame a shape delivers, driving the MC when it sends none at once."
  def first_frame(context, type) do
    context = subscribe(context, type)

    case context.shape.first do
      [] -> trigger(context, type)
      [frame | _] -> {frame, context}
    end
  end

  @doc "Lets a git action the shape started run out before the scenario tears down its repo."
  def settle(context, "gitAction") do
    ended =
      &(&1["id"] == @ids["gitAction"] and &1["event"]["kind"] in ~w(action_finished action_failed))

    {_, client} = Mc.await(World.client(context), ended, 10_000)
    World.put_client(context, client)
  end

  def settle(context, _type), do: context

  defp first(client, "preview", id), do: {[], quiet(client, id)}

  defp first(client, "config", id) do
    Mc.await_all(
      client,
      for(
        t <- ~w(config config.themes config.usageLimitSources),
        do: &(&1["t"] == t and &1["id"] == id)
      )
    )
  end

  defp first(client, "stream", id), do: snapshots(client, id, [])
  defp first(client, _type, id), do: Mc.await(client, &(&1["id"] == id), 5_000) |> one()

  defp one({frame, client}), do: {[frame], client}

  defp snapshots(client, id, acc) do
    {frame, client} = Mc.await(client, &(&1["id"] == id))
    acc = [frame | acc]

    if frame["t"] != "snapshot" or frame["done"],
      do: {Enum.reverse(acc), client},
      else: snapshots(client, id, acc)
  end

  @doc "Asserts the first frames match the shape's contract."
  def check_first(context) do
    %{type: type, id: id, first: first, form: form} = context.shape
    me = Atom.to_string(node())
    for frame <- first, do: assert(frame["id"] == id)

    case {type, first} do
      {"shell", [frame]} ->
        assert %{"t" => "shell", "mcs" => mcs, "rows" => rows} = frame

        assert Enum.map(mcs, & &1["mc"]) ==
                 Enum.map(HalC2.Shell.environments(), &to_string(elem(&1, 0)))

        assert length(rows) == length(HalC2.Shell.rows())

        # With links, each link also carries its environment's MCs and rows. A link
        # paired since scopes were kept also lists them.
        link_keys = if form == "links", do: ~w(environment mcs online origin rows)
        link_keys = link_keys || ~w(environment online origin)

        for link <- frame["links"],
            do: assert(Enum.sort(Map.keys(link) -- ["scopes"]) == link_keys)

      {"stream", [first | _] = frames} ->
        assert first["part"] == 0
        assert Enum.all?(frames, &(&1["t"] == "snapshot"))
        assert List.last(frames)["done"]

      {"config", frames} ->
        assert Enum.map(frames, & &1["t"]) == ~w(config config.themes config.usageLimitSources)
        assert hd(frames)["mc"] == me

        if form == "environment",
          do: assert(context.shape.map["environment"] == context.mc.environment)

      {"terminal", [frame]} ->
        assert %{"event" => %{"type" => "snapshot", "snapshot" => %{}}} = frame

      {"terminals", [frame]} ->
        assert %{"t" => "terminals", "event" => %{"type" => "snapshot"}} = frame

      {"vcs", [frame]} ->
        assert %{"t" => "vcs", "event" => %{}} = frame

      {"providerAuth", [frame]} ->
        assert %{"t" => "providerAuth", "state" => %{}} = frame

      {"worktreeSetup", [frame]} ->
        assert %{"t" => "worktreeSetup"} = frame
        assert frame["event"] == nil or is_map(frame["event"])

      {"scheduledTasks", [frame]} ->
        assert %{"t" => "scheduledTasks", "tasks" => tasks} = frame
        assert is_list(tasks)

      {"authAccess", [frame]} ->
        assert %{"t" => "authAccess", "event" => %{"type" => "snapshot", "payload" => %{}}} =
                 frame

      {"projectClones", [frame]} ->
        assert %{"t" => "projectClones", "clones" => clones} = frame
        assert is_list(clones)

      {"preview", []} ->
        :ok

      {"resourceTelemetry", [frame]} ->
        assert %{"t" => "resourceTelemetry", "snapshot" => %{}} = frame

      {"localServers", [frame]} ->
        assert %{"t" => "localServers", "list" => %{"servers" => _}} = frame

      {"devices", [frame]} ->
        assert %{"t" => "devices", "state" => %{}} = frame

      {"previewAutomation", [frame]} ->
        assert %{"t" => "previewAutomation", "event" => %{"type" => "connected"}} = frame

      {"pullRequestRefreshes", [frame]} ->
        assert %{"t" => "pullRequestRefreshes", "revision" => revision} = frame
        assert is_integer(revision)

      {"gitAction", [frame]} ->
        assert %{"t" => "gitAction", "event" => %{"kind" => "action_started"}} = frame

      {"serverUpdate", [frame]} ->
        assert %{"event" => %{"type" => "progress", "stage" => "downloading"}} = frame

      {"providerInstall", [frame]} ->
        assert %{"t" => "providerInstall", "state" => %{"driver" => "antigravity"}} = frame

      {"relayClientInstall", [frame]} ->
        assert %{"event" => %{"type" => "progress", "stage" => "checking"}} = frame
    end
  end

  # --- preparing a shape -------------------------------------------------------------

  # A shape named by environment is its MC form with the environment in place of the MC.
  defp prepare(context, type, "environment") do
    {map, context} = prepare(context, type, "mc")
    {map |> Map.delete("mc") |> Map.put("environment", context.mc.environment), context}
  end

  defp prepare(context, type, form) do
    f = context.fixtures
    mc = %{"mc" => Atom.to_string(node())}

    case type do
      "shell" ->
        # The socket follows the MC's links for shell.links from the moment it subscribes.
        ensure([
          {Registry, keys: :unique, name: HalC2.Links.Registry},
          {DynamicSupervisor, name: HalC2.Links.Supervisor, strategy: :one_for_one},
          HalC2.Links
        ])

        {if(form == "links", do: %{"links" => true}, else: %{}), context}

      "authAccess" ->
        {%{}, context}

      "stream" ->
        {Map.put(mc, "stream", f.thread), context}

      "config" ->
        Enum.each([HalC2.EnvironmentThemes, HalC2.UsageLimitSources], &Mc.ensure/1)
        {mc, context}

      "terminal" ->
        World.open_terminal(f.thread, f.root)
        {Map.put(mc, "input", Fixtures.terminal(f)), context}

      "terminals" ->
        ensure(Fixtures.terminals())
        World.put_env("SHELL", "/bin/sh")
        {mc, context}

      "vcs" ->
        ensure(Fixtures.vcs())
        {Map.put(mc, "cwd", f.root), context}

      "providerAuth" ->
        ensure(Fixtures.provider_auth())
        {Map.put(mc, "instanceId", "opencode"), context}

      "worktreeSetup" ->
        ensure([@services[type]])
        {Map.put(mc, "threadId", f.thread), context}

      "previewAutomation" ->
        ensure([@services[type]])
        {Map.put(mc, "host", %{"clientId" => "parity-host"}), context}

      "gitAction" ->
        ensure(Fixtures.vcs())
        File.write!(Path.join(f.root, "parity.txt"), "parity\n")

        input = %{
          "actionId" => "parity-action",
          "cwd" => f.root,
          "action" => "commit",
          "commitMessage" => "Parity"
        }

        {Map.put(mc, "input", input), context}

      "devices" ->
        context = World.fake_device_tools(context)
        ensure([HalC2.Devices])
        {mc, context}

      "serverUpdate" ->
        {Map.put(mc, "input", %{"targetVersion" => @target}), update_gate(context)}

      "providerInstall" ->
        ensure(Fixtures.provider_auth() ++ [HalC2.Acp.Antigravity.Installation])
        {Map.put(mc, "instanceId", "antigravity"), Fixtures.managed_install(context)}

      # A relay client already on the PATH: the install checks, finds it and completes.
      "relayClientInstall" ->
        bin = Mc.tmp_dir(context.mc, "relay-bin")
        File.cp!(@fake_cloudflared, Path.join(bin, "cloudflared"))
        File.chmod!(Path.join(bin, "cloudflared"), 0o755)
        World.put_app_env(:relay_client_env, %{"PATH" => bin})
        World.put_app_env(:relay_client_target, {"linux", "x64"})
        {mc, context}

      _ ->
        ensure([Map.fetch!(@services, type)])
        {mc, context}
    end
  end

  defp ensure(children), do: Enum.each(children, &Mc.ensure/1)

  # --- later frames ------------------------------------------------------------------

  @doc """
  Makes the MC send a `t` frame on the current shape; returns `{frame, context}`.
  Methods go through a second socket, so waiting for their reply skips no frame.
  """
  def trigger(context, t) do
    %{id: id} = context.shape
    f = context.fixtures

    case t do
      "shell.rows" ->
        context = World.create_project(context, "Later")
        await(context, t, id)

      "shell.environment" ->
        descriptor = %{"environmentId" => "env-gone"}
        GenServer.cast(HalC2.Shell, {:peer_environment, @gone, descriptor})
        await(context, t, id, &(&1["mc"] == to_string(@gone)))

      "shell.mc" ->
        send(HalC2.Shell, {:nodedown, @gone})
        await(context, t, id, &(&1["online"] == false))

      "shell.links" ->
        # A link to an environment nobody serves; removed once the frame lands.
        environment = %{"environmentId" => "env-linked", "label" => "Linked"}
        link = %{"origin" => "http://127.0.0.1:9", "token" => "t", "environment" => environment}
        :ok = GenServer.call(HalC2.Links, {:put, link})

        result =
          await(context, t, id, &match?([%{"origin" => "http://127.0.0.1:9"} | _], &1["links"]))

        HalC2.Links.remove("env-linked")
        result

      "shell.link" <> _ ->
        linked_frame(context, t, id)

      "live" ->
        await(context, t, id)

      "events" ->
        item = %{"s" => %{"id" => "parity-item", "text" => "hi"}}
        {:ok, _} = HalC2.Streams.commit(f.thread, :thread, [{"turn-item", "parity-item", item}])
        await(context, t, id)

      "resync" ->
        # One change larger than the socket buffers for a subscription.
        big = %{"s" => %{"id" => "parity-big", "text" => String.duplicate("x", 9_000_000)}}
        {:ok, _} = HalC2.Streams.commit(f.thread, :thread, [{"turn-item", "parity-big", big}])
        await(context, t, id, & &1, 10_000)

      "config.settings" ->
        context = World.update_settings(context, %{"timestampFormat" => "24-hour"})
        await(context, t, id)

      "config.providers" ->
        context = World.update_settings(context, %{"timestampFormat" => "12-hour"})
        await(context, t, id)

      "config.keybindings" ->
        {:ok, _} = HalC2.Keybindings.upsert(Fixtures.keybinding())
        await(context, t, id)

      "config.themes" ->
        dir = Path.join(context.mc.home, "themes")
        File.mkdir_p!(dir)

        theme = %{
          "name" => "Parity",
          "appearance" => "dark",
          "colors" => %{"background" => "#101010", "primary" => "#ff8800"}
        }

        File.write!(Path.join(dir, "parity.json"), JSON.encode!(theme))
        send(HalC2.EnvironmentThemes, :check)
        await(context, t, id)

      "config.usageLimitSources" ->
        source = %{"kind" => "cliproxy", "url" => "http://127.0.0.1:1", "enabled" => true}
        context = World.update_settings(context, %{"usageLimitSources" => %{"parity" => source}})
        :ok = HalC2.UsageLimitSources.refresh()
        await(context, t, id)

      "config.ready" ->
        # What `HalC2.Upgrade` announces once a version has loaded in place.
        HalC2.Settings.notify_upgraded(%{"id" => "parity", "status" => "committed"})
        await(context, t, id)

      "terminal" ->
        {_, context} =
          World.call!(
            context,
            "terminal.write",
            Map.put(Fixtures.terminal(f), "data", "echo parity\n"),
            "caller"
          )

        await(context, t, id)

      "terminals" ->
        World.open_terminal(f.thread, f.root, "term-2")
        await(context, t, id)

      "vcs" ->
        File.write!(Path.join(f.root, "changed.txt"), "changed\n")
        {_, context} = World.call(context, "vcs.refreshStatus", %{"cwd" => f.root}, "caller")
        await(context, t, id)

      "providerAuth" ->
        input = %{"instanceId" => "opencode", "methodId" => "browser"}
        {_, context} = World.call(context, "provider.auth.start", input, "caller")
        await(context, t, id)

      "worktreeSetup" ->
        project = %{"workspaceRoot" => f.root}
        strategy = %{"branch" => "parity", "baseRef" => "main"}
        HalC2.WorktreeSetup.start(f.thread, "run-parity", project, strategy, "go")
        await(context, t, id)

      "scheduledTasks" ->
        {:ok, _} = HalC2.ScheduledTasks.upsert(Fixtures.task())
        await(context, t, id)

      "authAccess" ->
        link = %{"label" => "Later", "scopes" => HalC2.Auth.standard_scopes()}
        {:ok, _} = HalC2.Auth.create_pairing_link(link)
        await(context, t, id)

      "projectClones" ->
        {payload, context} = Fixtures.payload(context, "projectClone.start")
        {_, context} = World.call(context, "projectClone.start", payload, "caller")
        await(context, t, id)

      "pullRequestRefreshes" ->
        HalC2.PullRequests.Refreshes.bump()
        await(context, t, id)

      "preview" ->
        payload = %{"threadId" => f.thread, "url" => "http://127.0.0.1:1/"}
        {_, context} = World.call(context, "preview.open", payload, "caller")
        await(context, t, id)

      "previewAutomation" ->
        task = invoke(f, 5_000)
        {frame, context} = await(context, t, id, &(&1["event"]["type"] == "request"))
        %{"requestId" => request} = frame["event"]["request"]

        HalC2.PreviewAutomation.respond(%{
          "requestId" => request,
          "clientId" => "parity-host",
          "connectionId" => frame["event"]["connectionId"],
          "ok" => true,
          "result" => %{}
        })

        assert {:ok, %{}} = Task.await(task)
        {frame, context}

      "end" ->
        # A host that never answers is evicted, which ends its stream.
        task = invoke(f, 50)
        result = await(context, t, id, & &1, 5_000)
        assert {:error, %{"_tag" => "PreviewAutomationTimeoutError"}} = Task.await(task)
        result

      "resourceTelemetry" ->
        send(HalC2.Diagnostics, :sample)
        await(context, t, id)

      "localServers" ->
        server =
          Mc.ensure(
            Supervisor.child_spec({Bandit, plug: __MODULE__.Page, port: 0, ip: :loopback},
              id: :parity_page
            )
          )

        {:ok, {_, port}} = ThousandIsland.listener_info(server)
        send(HalC2.LocalServers, :scan)
        listed = &Enum.any?(&1["list"]["servers"], fn s -> s["port"] == port end)
        await(context, t, id, listed, 8_000)

      "devices" ->
        {_, context} =
          World.call(context, "device.configure", %{"onboardingCompleted" => true}, "caller")

        await(context, t, id)

      "gitAction" ->
        await(context, t, id, &(&1["event"]["kind"] == "phase_started"), 5_000)

      "providerInstall" ->
        input = %{"instanceId" => "antigravity"}
        {_, context} = World.call(context, "provider.install.start", input, "caller")
        await(context, t, id, &(&1["state"]["phase"] == "downloading"))

      "relayClientInstall" ->
        await(context, t, id, &(&1["event"]["type"] == "complete"))

      "serverUpdate" ->
        serve_bundle()
        installing = &(&1["event"]["stage"] == "installing")
        {frame, context} = await(context, t, id, installing, 5_000)
        # The update goes on to restart (a stand-in exit); it has read its settings by then.
        {_, context} = await(context, "end", id, & &1, 5_000)
        {frame, context}
    end
  end

  # A link to an environment nobody serves, whose shell frames the test plays to the
  # MC's links as that environment would send them; removed once the frame lands.
  defp linked_frame(context, t, id) do
    environment = %{"environmentId" => "env-linked", "label" => "Linked"}
    link = %{"origin" => "http://127.0.0.1:9", "token" => "t", "environment" => environment}
    :ok = GenServer.call(HalC2.Links, {:put, link})
    [ref] = for {ref, "env-linked"} <- :sys.get_state(HalC2.Links).following, do: ref

    frame =
      case t do
        "shell.linkRows" ->
          row = %{"id" => "th-linked", "title" => "Linked"}
          %{"t" => "shell.rows", "mc" => "beast@host", "rows" => [["th-linked", "thread", row]]}

        "shell.linkEnvironment" ->
          %{"t" => "shell.environment", "mc" => "beast@host", "environment" => environment}

        "shell.linkMc" ->
          %{"t" => "shell.mc", "mc" => "beast@host", "online" => true}
      end

    send(HalC2.Links, {:hal_c2_link, ref, frame})
    result = await(context, t, id, &(&1["link"] == "env-linked"))
    :ok = HalC2.Links.remove("env-linked")
    result
  end

  defp await(context, t, id, fun \\ fn _ -> true end, timeout \\ 3_000) do
    match = &(&1["t"] == t and &1["id"] == id and fun.(&1))
    {frame, client} = Mc.await(World.client(context), match, timeout)
    {frame, World.put_client(context, client)}
  end

  defp invoke(f, timeout_ms) do
    scope = %{thread_id: f.thread, instance: "codex"}

    Task.async(fn ->
      HalC2.PreviewAutomation.invoke(scope, "status", %{}, timeout_ms: timeout_ms)
    end)
  end

  defmodule Page do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "<!doctype html><title>parity</title>")
    end
  end

  # --- server updates ------------------------------------------------------------------

  defmodule Gate do
    @moduledoc false
    # Hands each download request to the scenario, which says what to answer.
    @behaviour Plug
    def init(test), do: test

    def call(conn, test) do
      send(test, {:hal_c2_parity_download, self(), conn.request_path})

      receive do
        {:serve, status, body} -> Plug.Conn.send_resp(conn, status, body)
      after
        15_000 -> Plug.Conn.send_resp(conn, 504, "")
      end
    end
  end

  # A release root the MC updates from a loopback server, restarting into the new
  # version through a stand-in for `System.stop/1`.
  defp update_gate(context) do
    root = Mc.tmp_dir(context.mc, "release")
    for dir <- ~w(releases lib bin), do: File.mkdir_p!(Path.join(root, dir))
    start = "#{:erlang.system_info(:version)} #{HalC2.Upgrade.version()}\n"
    File.write!(Path.join([root, "releases", "start_erl.data"]), start)

    World.put_app_env(:restart_exit, fn _status -> :ok end)
    World.put_env("RELEASE_ROOT", root)
    World.put_env("HAL_C2_SERVICE", "1")

    gate =
      Mc.ensure(
        Supervisor.child_spec({Bandit, plug: {Gate, self()}, port: 0, ip: :loopback},
          id: :parity_gate
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(gate)
    World.put_env("HAL_C2_UPGRADE_URL", "http://127.0.0.1:#{port}/{version}/{platform}.tar.gz")

    Mc.ensure(HalC2.Upgrade)

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({HalC2.Upgrade, :version})
      :persistent_term.erase({HalC2.Upgrade, :outcome})
    end)

    context
  end

  @doc "Answers the pending bundle download with a bundle for the target and its checksum."
  def serve_bundle do
    assert_receive {:hal_c2_parity_download, gate, path}, 5_000
    assert path =~ @target
    archive = bundle()
    send(gate, {:serve, 200, archive})

    assert_receive {:hal_c2_parity_download, gate, sum_path}, 5_000
    assert String.ends_with?(sum_path, ".sha256")
    send(gate, {:serve, 200, Base.encode16(:crypto.hash(:sha256, archive), case: :lower)})
  end

  @doc "Answers the pending bundle download with a 404."
  def refuse_bundle do
    assert_receive {:hal_c2_parity_download, gate, _path}, 5_000
    send(gate, {:serve, 404, ""})
  end

  defp bundle do
    path =
      Path.join(System.tmp_dir!(), "hal-c2-parity-#{System.unique_integer([:positive])}.tar.gz")

    manifest = JSON.encode!(%{"version" => @target})

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [{~c"releases/#{@target}/upgrade.json", manifest}, {~c"lib/.keep", ""}],
        [:compressed]
      )

    archive = File.read!(path)
    File.rm!(path)
    archive
  end

  # --- sockets -------------------------------------------------------------------------

  @doc "Opens a new socket with the MC's token and returns its first frame."
  def open_socket(context) do
    {:ok, client} = WsClient.connect(context.mc.port, "/ws?token=#{HalC2.Web.token()}")
    {frame, _client} = WsClient.recv(client, 1_000)
    frame
  end

  @doc "Sends a ping and asserts nothing arrives for `id` before its pong."
  def quiet(client, id) do
    client = WsClient.send_json(client, %{"t" => "ping"})
    {_pong, skipped, client} = WsClient.recv_until(client, &(&1["t"] == "pong"))
    assert Enum.filter(skipped, &(&1["id"] == id)) == []
    client
  end

  @doc """
  The MC process behind the default socket, found as the one new shell
  subscriber when it subscribes to the shell. Returns `{pid, context}`.
  """
  def socket_pid(context) do
    before = Map.keys(:sys.get_state(HalC2.Shell).subscribers)
    client = Mc.sub(World.client(context), 99, %{"type" => "shell"})
    {_, client} = Mc.await(client, &(&1["t"] == "shell" and &1["id"] == 99))
    [pid] = Map.keys(:sys.get_state(HalC2.Shell).subscribers) -- before
    {pid, World.put_client(context, client)}
  end

  @doc "A socket paired under `label` with standard scopes; returns `{client, session_id}`."
  def paired_client(context, label) do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{
        "label" => label,
        "scopes" => HalC2.Auth.standard_scopes()
      })

    sessions = fn -> Enum.map(HalC2.Auth.clients(), & &1["sessionId"]) end
    before = sessions.()
    {:ok, access, _expires, _scopes} = HalC2.Auth.exchange(credential, %{"label" => label})
    [session] = sessions.() -- before
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)
    {Mc.connect(context.mc, "wsTicket=#{ticket}"), session}
  end
end
