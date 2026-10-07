defmodule HalC2.Steps.Connections.Pairing do
  @moduledoc """
  Steps for `features/connections/pairing.feature`: pairing links printed by
  `mix hal_c2.pair` on the host and minted by an administrator over HTTP or the socket,
  paired through `/oauth/token` as a client does, and the page a link opens in a browser.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc
  alias HalC2.Test.Mc.World

  # --- printed on the host ---------------------------------------------------------

  step "an operator asks the MC for a pairing link with its LAN address", context do
    base = "http://#{Mc.lan_address()}:#{context.mc.port}"
    context |> Map.put(:base, base) |> Map.put(:printed, print_link(base))
  end

  step "an operator asks for a pairing link for {string}", %{args: [base]} = context do
    context |> Map.put(:base, base) |> Map.put(:printed, print_link(base))
  end

  step "it prints the address with a one-time token", context do
    assert [_, token] =
             Regex.run(~r"^#{Regex.escape(context.base)}/\?token=([\w-]+)$", context.printed)

    Map.put(context, :token, token)
  end

  step "the token grants standard scopes for five minutes", context do
    assert [link] = HalC2.Auth.pairing_links()
    assert link["scopes"] == HalC2.Auth.standard_scopes()
    {:ok, created, _} = DateTime.from_iso8601(link["createdAt"])
    {:ok, expires, _} = DateTime.from_iso8601(link["expiresAt"])
    assert DateTime.diff(expires, created) == 5 * 60

    assert {200, %{"scope" => scope}} = Mc.pair_http(context.mc, context.token)
    assert String.split(scope) == HalC2.Auth.standard_scopes()
    # One time only.
    assert {400, %{"error" => "invalid_grant"}} = Mc.pair_http(context.mc, context.token)
    context
  end

  step "the printed link starts with that address", context do
    assert String.starts_with?(context.printed, context.base <> "/?token=")
    token = String.replace_prefix(context.printed, context.base <> "/?token=", "")
    assert {200, %{"access_token" => _}} = Mc.pair_http(context.mc, token)
    context
  end

  # --- minted by an administrator --------------------------------------------------

  step "an administrator's client", context do
    Map.put(context, :admin_access, Mc.pair(Mc.admin_scopes(), "Admin"))
  end

  step "it creates a pairing link labelled {string} with standard scopes",
       %{args: [label]} = context do
    create_link(context, label)
  end

  step "the MC returns the link's credential once", context do
    assert is_binary(context.link["credential"]) and context.link["credential"] != ""
    assert %{"id" => _} = listed = listed_link(context)
    refute Map.has_key?(listed, "credential")
    refute inspect(listed) =~ context.link["credential"]
    context
  end

  step "the link is listed under that label until it is used", context do
    assert listed_link(context)["label"] == context.link_label
    assert listed_link(context)["scopes"] == HalC2.Auth.standard_scopes()
    assert {200, _} = Mc.pair_http(context.mc, context.link["credential"])
    assert listed_link(context) == nil
    context
  end

  step "a listed pairing link", context do
    context =
      context
      |> Map.put(:admin_access, Mc.pair(Mc.admin_scopes(), "Admin"))
      |> create_link("Kitchen tablet")

    assert listed_link(context)
    context
  end

  step "a device pairs with it", context do
    assert {200, %{"access_token" => _}} =
             Mc.pair_http(context.mc, context.link["credential"], "Kitchen tablet")

    context
  end

  step "the link is no longer listed", context do
    assert listed_link(context) == nil
    context
  end

  step "the device is listed as a client", context do
    {200, clients} =
      Mc.http(context.mc, :get, "/api/auth/clients", bearer: context.admin_access)

    assert Enum.any?(clients, &(&1["client"]["label"] == "Kitchen tablet"))
    context
  end

  step "an administrator revokes it", context do
    assert {200, %{"revoked" => true}} =
             Mc.http(context.mc, :post, "/api/auth/pairing-links/revoke",
               bearer: context.admin_access,
               json: %{"id" => context.link["id"]}
             )

    assert listed_link(context) == nil
    context
  end

  step "pairing with it fails", context do
    assert {400, %{"error" => "invalid_grant"}} =
             Mc.pair_http(context.mc, context.link["credential"])

    context
  end

  # --- where a link's MC is reached ------------------------------------------------

  # The host the listener binds, which is what the MC says it is reached at.
  step "the MC listens on its LAN address", context do
    World.put_app_env(:host, Mc.lan_address())
    context
  end

  step("the MC listens on its own machine only", context, do: context)

  step "Tailscale names the MC's machine {string}", %{args: [name]} = context do
    state = Path.join(Mc.tmp_dir(context.mc, "tailscale"), "state.json")
    File.write!(state, JSON.encode!(%{"self" => %{"DNSName" => name <> "."}}))

    World.put_app_env(:tailscale_command, [
      "env",
      "FAKE_TAILSCALE_STATE=#{state}",
      Path.expand("test/support/fake_tailscale.py")
    ])

    Map.put(context, :tailscale_state, state)
  end

  step "Tailscale is not running on the MC's machine", context do
    World.put_app_env(:tailscale_command, ["false"])
    context
  end

  step "it asks the MC for a pairing link at the address it listens on", context do
    ask_for_link(context, %{})
  end

  step "it asks the MC for a pairing link at {string}", %{args: [base]} = context do
    ask_for_link(context, %{"baseUrl" => base})
  end

  step "it asks the MC for a pairing link over Tailscale", context do
    ask_for_link(context, %{"tailscale" => true})
  end

  step "the link comes with the MC's LAN address", context do
    assert {:ok, link} = context.asked
    assert link["address"] == "http://#{Mc.lan_address()}:#{context.mc.port}"
    context
  end

  step "the link comes with the MC's loopback address", context do
    assert {:ok, link} = context.asked
    assert link["address"] == "http://127.0.0.1:#{context.mc.port}"
    context
  end

  step "the link comes with the address {string}", %{args: [address]} = context do
    assert {:ok, link} = context.asked
    assert link["address"] == address
    context
  end

  # Wherever it says it is reached, the link is this MC's: its credential pairs here.
  step "that address is one another device can reach", context do
    assert {:ok, %{"localOnly" => false, "credential" => credential}} = context.asked
    assert {200, %{"access_token" => _}} = Mc.pair_http(context.mc, credential)
    context
  end

  step "that address is reachable only on its own machine", context do
    assert {:ok, %{"localOnly" => true, "credential" => credential}} = context.asked
    assert {200, %{"access_token" => _}} = Mc.pair_http(context.mc, credential)
    context
  end

  step "Tailscale serves the MC over HTTPS at {string}", %{args: [name]} = context do
    served = context.tailscale_state |> File.read!() |> JSON.decode!() |> Map.fetch!("serve")
    assert served == %{"#{name}:443" => "http://127.0.0.1:#{context.mc.port}"}
    context
  end

  step "the client is told Tailscale could not be reached", context do
    assert {:error, message, _detail} = context.asked
    assert message =~ "Could not talk to Tailscale"
    context
  end

  step "no pairing link is listed", context do
    assert {200, []} =
             Mc.http(context.mc, :get, "/api/auth/pairing-links", bearer: context.admin_access)

    context
  end

  # --- opened in a browser -----------------------------------------------------------

  # A browser keeps the fragment, and so the token, to itself: the MC is asked for the path alone.
  step "a phone's browser opens a pairing link", context do
    url = ~c"http://127.0.0.1:#{context.mc.port}/pair"
    assert {:ok, {{_, 200, _}, headers, body}} = :httpc.request(:get, {url, []}, [], [])
    headers = Map.new(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
    assert headers["content-type"] =~ "text/html"
    context |> Map.put(:page, :binary.list_to_bin(body)) |> Map.put(:page_headers, headers)
  end

  step "the page names the MC and offers to open the HAL-C2 app", context do
    label = Plug.HTML.html_escape(HalC2.Environment.descriptor()["label"])
    assert context.page =~ "HAL-C2 MC <b>#{label}</b>"
    assert context.page =~ ~r|<a id="open" hidden>Open in the HAL-C2 app</a>|
    context
  end

  step "it hands the app its own address as {string}", %{args: [link]} = context do
    assert [_, script] = Regex.run(~r|<script>(.*)</script>|s, context.page)

    assert script =~
             ~s|getElementById("open").href = "#{link}" + encodeURIComponent(location.href)|

    # Only for an address that carries a token; without one the page says so instead.
    assert script =~ "location.hash"
    assert context.page =~ ~r|<p id="missing" hidden>This address carries no pairing token|
    context
  end

  step "it says what to do when the app is not installed", context do
    assert context.page =~ "the HAL-C2 app is not installed on this device"
    assert context.page =~ "copy this page's full address and paste it"
    context
  end

  # A policy that names the script and the style by their hashes: the page's own run,
  # and nothing else does or is fetched. The address, token and all, goes to no one.
  step "nothing but the page's own script and style may load", context do
    assert [_, script] = Regex.run(~r|<script>(.*)</script>|s, context.page)
    assert [_, style] = Regex.run(~r|<style>(.*)</style>|s, context.page)
    hash = &Base.encode64(:crypto.hash(:sha256, &1))

    assert context.page_headers["content-security-policy"] ==
             "default-src 'none'; script-src 'sha256-#{hash.(script)}'; " <>
               "style-src 'sha256-#{hash.(style)}'; base-uri 'none'; form-action 'none'; " <>
               "frame-ancestors 'none'"

    assert context.page_headers["referrer-policy"] == "no-referrer"
    assert context.page_headers["cache-control"] == "no-store"
    # The markup itself names no address, inline style or handler.
    refute String.replace(context.page, script, "") =~ ~r/\b(src|href|style|on\w+)\s*=/i
    context
  end

  # --- helpers -----------------------------------------------------------------------

  # `hal-c2.createPairingLink` over the administrator's socket, as Settings → Connections asks.
  defp ask_for_link(context, where) do
    client = Mc.connect_as(context.mc, context.admin_access)
    payload = Map.merge(%{"label" => "Phone", "scopes" => HalC2.Auth.standard_scopes()}, where)

    {reply, _client} =
      Mc.call(client, context.mc.environment, "hal-c2.createPairingLink", payload)

    Map.put(context, :asked, reply)
  end

  defp print_link(base) do
    assert [line] = Mc.run_task(Mix.Tasks.HalC2.Pair, [base])
    line
  end

  defp create_link(context, label) do
    assert {200, link} =
             Mc.http(context.mc, :post, "/api/auth/pairing-token",
               bearer: context.admin_access,
               json: %{"label" => label, "scopes" => HalC2.Auth.standard_scopes()}
             )

    context |> Map.put(:link, link) |> Map.put(:link_label, label)
  end

  defp listed_link(context) do
    {200, links} =
      Mc.http(context.mc, :get, "/api/auth/pairing-links", bearer: context.admin_access)

    Enum.find(links, &(&1["id"] == context.link["id"]))
  end
end
