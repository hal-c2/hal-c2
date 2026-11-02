defmodule HalC2.Steps.Space.Sites do
  @moduledoc """
  Steps for `features/space/sites.feature`. A published link is remembered by page title
  in `context.site_links`, as it has to outlive the site, and opened as a browser would:
  a plain HTTP request with no credentials. The last answer is `context.browser`.
  The Space and its pages come from `HalC2.Steps.Space.Pages`.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.{Space, StreamState, Streams}
  alias HalC2.Space.Sites
  alias HalC2.Test.{Mc, WsClient}
  alias HalC2.Test.Mc.World

  # --- publishing --------------------------------------------------------------------

  step "the page {string} is published as a site", %{args: [title]} = context do
    {%{"site" => site}, context} = World.call!(context, "space.page.publish", ref(context, title))
    remember(context, title, site)
  end

  step "the user publishes the page {string} as a site", %{args: [title]} = context do
    publish(context, title, %{})
  end

  step "the user publishes the page {string} over Tailscale", %{args: [title]} = context do
    publish(context, title, %{"tailscale" => true})
  end

  step "a client that reached the MC at {string} publishes the page {string}",
       %{args: [base, title]} = context do
    publish(context, title, %{"baseUrl" => base})
  end

  step "the user unpublishes the page {string}", %{args: [title]} = context do
    {_, context} = World.call!(context, "space.page.unpublish", ref(context, title))
    context
  end

  step "a session that may only read", context do
    session(context, ["orchestration:read"])
  end

  step "a session that may change the Space but not access", context do
    session(context, ["orchestration:read", "orchestration:operate"])
  end

  step "that session publishes the page {string} as a site", %{args: [title]} = context do
    session_publish(context, title, %{})
  end

  step "that session publishes the page {string} over Tailscale", %{args: [title]} = context do
    session_publish(context, title, %{"tailscale" => true})
  end

  step "that session is refused for lack of access", context do
    assert {:error, message, _} = context.session_reply
    assert message =~ "is required"
    assert StreamState.list(state(context), "site") == []
    context
  end

  # --- what the page shows -----------------------------------------------------------

  step "the page {string} shows it is published with a link", %{args: [title]} = context do
    site = site(context, title)
    assert %{path: "/sites/" <> _, scheme: "http" <> _} = URI.parse(site["url"])
    assert site["behind"] == false
    assert site["url"] == context.site_links[title]
    context
  end

  step "the page {string} shows it is not published", %{args: [title]} = context do
    assert site(context, title) == nil
    context
  end

  step "the page {string} shows its site is behind", %{args: [title]} = context do
    assert site(context, title)["behind"] == true
    context
  end

  step "the page {string} shows its site is up to date", %{args: [title]} = context do
    assert site(context, title)["behind"] == false
    context
  end

  step "the page {string} has a different site link", %{args: [title]} = context do
    assert context.earlier_link != nil
    assert site(context, title)["url"] != context.earlier_link
    context
  end

  step "the page {string} has the same site link", %{args: [title]} = context do
    assert site(context, title)["url"] == context.earlier_link
    context
  end

  step "the second client sees the page {string} published", %{args: [title]} = context do
    id = page(context, title)["id"]

    published? = fn frame ->
      frame["t"] == "events" and
        Enum.any?(frame["events"], fn [_seq, kind, _id, patch | _] ->
          kind == "site" and is_map(patch["s"]) and patch["s"]["pageId"] == id
        end)
    end

    {_, client} = Mc.await(World.client(context, "second"), published?, 5_000)
    World.put_client(context, "second", client)
  end

  # --- what a browser gets -----------------------------------------------------------

  step "a browser with no pairing opens the site link of the page {string}",
       %{args: [title]} = context do
    open(context, context.site_links[title])
  end

  step "a browser with no pairing opens a made-up site link in the Space", context do
    open(context, "http://mc/sites/#{context.space}/#{String.duplicate("x", 32)}")
  end

  step "a browser with no pairing opens the site token of the page {string} under {string}",
       %{args: [title, name]} = context do
    open(context, "http://mc/sites/#{context.spaces[name]}/#{token(context, title)}")
  end

  step "the site link of the page {string} no longer opens", %{args: [title]} = context do
    assert_gone(context, context.site_links[title])
    context
  end

  step "the earlier site link no longer opens", context do
    assert_gone(context, context.earlier_link)
    context
  end

  step "the browser is answered as for an address the MC does not have", context do
    assert_unknown(context, context.browser)
    context
  end

  step "the browser reads {string} and {string}", %{args: [first, second]} = context do
    assert {200, _, body} = context.browser
    assert body =~ first
    assert body =~ second
    context
  end

  step "the browser reads {string}", %{args: [text]} = context do
    assert {200, _, body} = context.browser
    assert body =~ text
    context
  end

  step "the browser does not read {string}", %{args: [text]} = context do
    assert {200, _, body} = context.browser
    refute body =~ text
    context
  end

  step "the site token of the page {string} is used as a credential",
       %{args: [title]} = context do
    Map.put(context, :site_token, token(context, title))
  end

  step "the MC refuses it on its HTTP routes and its socket", context do
    token = context.site_token

    for {method, path, opts} <- [
          {:get, "/api/auth/session", []},
          {:post, "/api/auth/websocket-ticket", [json: %{}]},
          {:get, "/api/auth/clients", []},
          {:get, "/api/cluster", []}
        ] do
      {status, body} = Mc.http(context.mc, method, path, [bearer: token] ++ opts)
      assert status == 401 or body["authenticated"] == false, "#{path} answered #{status}"
    end

    for query <- ["token=", "wsTicket="] do
      assert {:error, 401} = WsClient.connect(context.mc.port, "/ws?#{query}#{token}")
    end

    context
  end

  step "the document has no tags from the page text", context do
    assert {200, _, body} = context.browser
    refute body =~ "<script"
    refute body =~ "<img"
    context
  end

  step "the browser reads {string} as text", %{args: [text]} = context do
    assert {200, _, body} = context.browser
    assert body =~ IO.iodata_to_binary(Plug.HTML.html_escape(text))
    context
  end

  step "the response has a policy that runs no scripts and loads nothing", context do
    assert {200, headers, _} = context.browser
    policy = headers["content-security-policy"]
    assert policy =~ "default-src 'none'"
    assert policy =~ "sandbox"
    refute policy =~ "script-src"
    refute policy =~ "unsafe"
    context
  end

  step "the response is not cached, sends no referrer and allows no other origin", context do
    assert {200, headers, _} = context.browser
    assert headers["cache-control"] == "no-store"
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["x-content-type-options"] == "nosniff"
    refute Map.has_key?(headers, "access-control-allow-origin")
    context
  end

  step "the page {string} also has a heading {string}, a callout {string} and a ticked item {string}",
       %{args: [title, heading, callout, item]} = context do
    [
      %{"kind" => "heading", "text" => heading},
      %{"kind" => "callout", "text" => callout},
      %{"kind" => "checklist", "text" => item, "checked" => true}
    ]
    |> Enum.reduce(context, fn block, context ->
      {_, context} =
        World.call!(context, "space.block.insert", Map.merge(ref(context, title), block))

      context
    end)
  end

  step "the document has a heading {string}, a note {string} and a ticked item {string}",
       %{args: [heading, note, item]} = context do
    assert {200, _, body} = context.browser
    assert body =~ "<h2>#{heading}</h2>"
    assert body =~ "<aside>#{note}</aside>"
    assert body =~ "<li>☑ #{item}</li>"
    context
  end

  step "the document has the heading {string}", %{args: [heading]} = context do
    assert {200, _, body} = context.browser
    assert body =~ "<h2>#{heading}</h2>"
    context
  end

  step "the document has no links", context do
    assert {200, _, body} = context.browser
    refute body =~ "<a "
    refute body =~ "href"
    context
  end

  # --- the address -------------------------------------------------------------------

  step "the MC listens only on this machine", context do
    assert {:ok, %{"localOnly" => true}} = HalC2.Web.address()
    context
  end

  step "the page {string} says only this machine can open its site link",
       %{args: [title]} = context do
    assert site(context, title)["localOnly"] == true
    context
  end

  step "the site link of the page {string} starts with {string}",
       %{args: [title, start]} = context do
    assert String.starts_with?(site(context, title)["url"], start)
    Map.put(context, :last_site, site(context, title))
  end

  step "the link is not marked as only for this machine", context do
    assert context.last_site["localOnly"] == false
    context
  end

  step "the link names one of the machine's non-loopback addresses", context do
    %{host: host} = URI.parse(context.last_site["url"])
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    {:ok, interfaces} = :inet.getifaddrs()
    assert ip in for({_, opts} <- interfaces, {:addr, addr} <- opts, do: addr)
    refute match?({127, _, _, _}, ip)
    context
  end

  # --- helpers -----------------------------------------------------------------------

  defp publish(context, title, where) do
    {reply, context} =
      World.call(context, "space.page.publish", Map.merge(ref(context, title), where))

    context = Map.put(context, :space_reply, reply)

    case reply do
      {:ok, %{"site" => site}} -> remember(context, title, site)
      _ -> context
    end
  end

  defp remember(context, title, site) do
    links = context[:site_links] || %{}

    context
    |> Map.put(:earlier_link, links[title])
    |> Map.put(:site_links, Map.put(links, title, site["url"]))
    |> Map.put(:last_site, site)
  end

  # A socket whose session has only `scopes`.
  defp session(context, scopes) do
    {:ok, %{"credential" => credential}} =
      HalC2.Auth.create_pairing_link(%{"label" => "Limited", "scopes" => scopes})

    {:ok, access, _, ^scopes} = HalC2.Auth.exchange(credential, %{"label" => "Limited"})
    {:ok, ticket, _} = HalC2.Auth.issue_ticket(access)
    World.put_client(context, "limited", Mc.connect(context.mc, "wsTicket=#{ticket}"))
  end

  defp session_publish(context, title, where) do
    {reply, context} =
      World.call(
        context,
        "space.page.publish",
        Map.merge(ref(context, title), where),
        "limited"
      )

    Map.put(context, :session_reply, reply)
  end

  # Links are opened on the port the MC listens on here, whatever address they name.
  defp open(context, link), do: Map.put(context, :browser, get(context, URI.parse(link).path))

  defp get(context, path) do
    url = ~c"http://127.0.0.1:#{context.mc.port}#{path}"

    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(:get, {url, []}, [timeout: 5_000], body_format: :binary)

    {status, Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}
  end

  defp assert_gone(context, link), do: assert_unknown(context, get(context, URI.parse(link).path))

  # The same status and body as an address that never existed, and no document headers.
  defp assert_unknown(context, {status, headers, body}) do
    {unknown_status, _, unknown_body} = get(context, "/no-such-address")
    assert {status, body} == {unknown_status, unknown_body}
    refute Map.has_key?(headers, "content-security-policy")
  end

  defp token(context, title),
    do: context.site_links[title] |> URI.parse() |> Map.get(:path) |> Path.basename()

  defp state(context), do: Streams.state(Space.stream_id(context.space))

  defp page(context, title) do
    Enum.find(StreamState.list(state(context), "page"), &(&1["title"] == title)) ||
      flunk("no page #{inspect(title)}")
  end

  defp site(context, title), do: Sites.of_page(state(context), page(context, title)["id"])

  defp ref(context, title),
    do: %{"spaceId" => context.space, "pageId" => page(context, title)["id"]}
end
