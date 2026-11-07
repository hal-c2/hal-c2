defmodule HalC2.Web.Entry do
  @moduledoc """
  The plug the listener runs, in front of `HalC2.Web.Router`.

  A request runs in its connection's process, so a response that streams for as long
  as a client watches a device keeps the frames of every plug it passed through. Inside
  the router that would pin the router's code, the module edited most, and its second
  release upgrade would be refused (`HalC2.Upgrade.Release`). The device hub's relay
  (`HalC2.Devices.Proxy`) is therefore reached from here; everything else goes on to the
  router by a tail call, which leaves no frame of this module behind.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: HalC2.Web.Router.init(opts)

  # A preflight goes to the router, which answers every one the same way.
  @impl true
  def call(%Plug.Conn{path_info: ["api", "device-hub" | rest], method: method} = conn, _opts)
      when method != "OPTIONS" do
    conn
    |> Plug.Conn.merge_resp_headers(HalC2.Web.Router.cors_headers())
    |> HalC2.Devices.Proxy.serve(rest)
  end

  def call(conn, opts), do: HalC2.Web.Router.call(conn, opts)
end
