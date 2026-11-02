defmodule HalC2.Test.PushPhone do
  @moduledoc """
  A phone's UnifiedPush endpoint on loopback, standing in for a distributor such as
  ntfy: `start/1` gives the phone a P-256 key and auth secret and serves its endpoint;
  `messages/1` decrypts what `HalC2.Push` POSTed there, as the phone would.

  The endpoint answers 201, or the statuses queued with `answer/2` first. `clock/0` is
  the time `HalC2.Push` reads in tests, moved with `set_clock/1`; `post/3` is its
  `WebPush.post/3` that also notes every URL it was given (`posted_urls/0`).
  """
  @behaviour Plug

  import Plug.Conn

  alias HalC2.Push.WebPush

  @doc "Serves a phone's endpoint at `path` under the test supervisor."
  def start(path \\ "/up") do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)
    {:ok, log} = Agent.start_link(fn -> %{requests: [], answers: []} end)

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, log}, port: 0, ip: :loopback},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{
      endpoint: "http://127.0.0.1:#{port}#{path}?up=1",
      path: path,
      public: public,
      private: private,
      auth: auth,
      log: log
    }
  end

  @doc "The `hal-c2.registerPush` input for `phone`, with `fields` over the defaults."
  def registration(phone, fields \\ %{}) do
    Map.merge(
      %{
        "endpoint" => phone.endpoint,
        "keys" => %{
          "p256dh" => Base.url_encode64(phone.public, padding: false),
          "auth" => Base.url_encode64(phone.auth, padding: false)
        },
        "distributor" => "io.heckel.ntfy",
        "liveActivity" => false,
        "mutedThreads" => [],
        "quietHours" => nil
      },
      fields
    )
  end

  @doc "Makes the next requests get `statuses`, in order, before 201 again."
  def answer(phone, statuses),
    do: Agent.update(phone.log, &%{&1 | answers: &1.answers ++ statuses})

  @doc "Every request served: `%{path, headers, body, status}`, oldest first."
  def requests(phone), do: Agent.get(phone.log, &Enum.reverse(&1.requests))

  @doc "The decrypted messages of the requests the endpoint accepted, oldest first."
  def messages(phone) do
    for %{status: status, body: body} <- requests(phone), status in 200..299 do
      {:ok, json} = WebPush.decrypt(body, phone.private, phone.auth)
      JSON.decode!(json)
    end
  end

  @doc "The alerts among `messages/1`."
  def alerts(phone), do: for(%{"alert" => alert} <- messages(phone), do: alert)

  @impl true
  def init(log), do: log

  @impl true
  def call(conn, log) do
    {:ok, body, conn} = read_body(conn)

    status =
      Agent.get_and_update(log, fn state ->
        {status, answers} =
          case state.answers do
            [status | rest] -> {status, rest}
            [] -> {201, []}
          end

        request = %{
          path: conn.request_path,
          headers: conn.req_headers,
          body: body,
          status: status
        }

        {status, %{state | answers: answers, requests: [request | state.requests]}}
      end)

    send_resp(conn, status, "")
  end

  # --- the service's clock and its outgoing requests --------------------------------

  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{clock: nil, urls: []} end, name: __MODULE__)

  @doc "The test clock: the time set with `set_clock/1`, else the system's."
  def clock do
    case Agent.get(__MODULE__, & &1.clock) do
      nil -> System.os_time(:millisecond)
      ms -> ms
    end
  end

  def set_clock(ms), do: Agent.update(__MODULE__, &%{&1 | clock: ms})

  def post(url, body, urgency) do
    Agent.update(__MODULE__, &%{&1 | urls: [url | &1.urls]})
    WebPush.post(url, body, urgency)
  end

  def posted_urls, do: Agent.get(__MODULE__, &Enum.reverse(&1.urls))

  @doc "`HalC2.Push` as tests run it: this clock and `post/3`, retries without waiting."
  def service,
    do: {HalC2.Push, clock: &__MODULE__.clock/0, post: &__MODULE__.post/3, sleep: fn _ -> :ok end}
end
