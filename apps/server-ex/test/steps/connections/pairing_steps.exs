defmodule HalC2.Steps.Connections.Pairing do
  @moduledoc """
  Steps for `features/connections/pairing.feature`: pairing links printed by
  `mix hal_c2.pair` on the host and minted by an administrator over HTTP, paired
  through `/oauth/token` as a client does.
  """
  use Cucumber.StepDefinition
  import ExUnit.Assertions

  alias HalC2.Test.Mc

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

  # --- helpers -----------------------------------------------------------------------

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
