# Devices

The MC owns simulators and emulators the way it owns terminals: discovery, streaming, and agent
access all run there, and every client reaches them through the environment connection. This is
what makes the Device panel work over Tailscale and HAL-C2 Connect, and across a cluster: each
machine is its own host, and the MC a client is connected to relays to the MC that owns the device.

## Two external tools, one seam

[expo-device-hub](../../apps/server-ex/lib/hal_c2/devices.ex) streams and
[agent-device](../../apps/server-ex/lib/hal_c2/devices.ex) drives. Each is npm-installed at a
pinned version into HAL-C2's data directory after its matching Device panel consent step. Nothing
is installed or started until device support is enabled; agent-device stays absent and stopped
until agent access is granted. Both run with the system Node; `npx` would make the first
`device_open` after a reboot depend on the registry. The hub is a supervised child rather than
code in the MC because serve-sim loads private CoreSimulator frameworks through a native addon,
and a crash there must not take the MC down.

[`HalC2.Devices`](../../apps/server-ex/lib/hal_c2/devices.ex) is the only module that knows the
hub's origin and the agent-device endpoint; the proxy and the MCP tools go through it.

## The hub is never exposed

serve-sim has a shell-exec route whose token is readable from its own
unauthenticated `/api`, and serve-emu's action routes have no auth at all. The
hub binds loopback and the only way in is the
[proxy](../../apps/server-ex/lib/hal_c2/devices/proxy.ex), which allowlists the
stream, config, and screenshot routes and authenticates every request as an
environment session. `<img>` and `WebSocket` cannot carry headers, so the proxy
authenticates like the `/ws` upgrade: a short-lived `wsTicket` that clients mint over an
authenticated connection, or a bearer header. The ticket is stripped before the request reaches
the hub.

## Device settings never go through the hub

serve-sim's preview drives its Tools panel by sending shell commands over that
same exec channel. Proxying it, even allowlisted, would hand any environment
session arbitrary command execution on the host, so HAL-C2 does not. The
`device.action` RPC ([`Devices.Actions`](../../apps/server-ex/lib/hal_c2/devices/actions.ex))
runs the underlying `simctl`, `adb`, and serve-sim helper binaries itself, one typed action per
control, and returns the settings it reads back. The proxy allowlist grows only with read routes
(accessibility tree, foreground app, event log) and refuses non-GET methods everywhere except
screenshot capture and stream tuning.

## Agents drive through the CLI

The `device_*` toolkit is deliberately four tools: list, open, screenshot, and
close ([`HalC2.Mcp.Devices`](../../apps/server-ex/lib/hal_c2/mcp/devices.ex)). Driving happens
through the `agent-device` CLI, which has the semantic snapshot model agents need and stays
current with its own releases. `device_open` returns the command that runs the pinned CLI with
`--config` and `--session` flags pinned to the thread's device; a launcher refuses commands
without them, so an agent never drives the user's other devices by accident.

The tools are offered only where the user allowed agent access (`enableAgentDeviceAccess`, or the
project's override of it), and the MC readies agent-device only when device support and agent
access are both enabled and the machine can run at least one platform.

How to drive a device is returned from `device_open`, not kept in an always-loaded prompt or
skill: it costs nothing in threads that never open a device and cannot drift from the pinned CLI
version.

## The viewer decodes both vendored protocols

The hub vendors two streaming servers with different wire formats. iOS video is
an HTTP body of AVCC envelopes, with input on a separate binary WebSocket;
Android multiplexes SEMU-framed H.264 and JSON gestures over one WebSocket.
The viewer speaks both so one panel covers both platforms.

The Qt desktop's [`DeviceStream`](../../apps/desktop-qt/src/native/DeviceStream.cpp)
decodes in software with libavcodec on its own thread
([`DeviceDecoder`](../../apps/desktop-qt/src/native/DeviceDecoder.cpp)), so
every profile decodes and MJPEG only seeds the first picture. QtMultimedia was
not used: its player paces by timestamp and buffers, and cannot drop frames or
ask for keyframes. A decoder that falls behind drops its backlog and waits for
the next keyframe instead of showing old pictures late. FFmpeg is not linked or
shipped (licensing and size): [`FFmpeg.cpp`](../../apps/desktop-qt/src/native/FFmpeg.cpp)
loads the user's libraries at run time, and only at the major versions of the
headers the app was built with, since the decoder reads FFmpeg's structs
directly. Without them the app runs and the Device tab says to install FFmpeg.
