// A stand-in for expo-device-hub's CLI (`--port N --host H ...`): the device list,
// boot and shutdown, and a screenshot, with Android emulators kept in memory.
// Booting "Broken" fails for lack of disk space. Every answer echoes the request
// URL in `x-fake-hub-url`, so tests can see what reached the hub, and the stream
// socket echoes what it gets.
//
// FAKE_HUB_SIMULATORS and FAKE_HUB_EMULATORS (JSON arrays) seed the device lists.
// A simulator's MJPEG stream sends frames until the client goes away, and
// `/fake/streams-closed` answers once no stream is open. `?fake=drop` drops the
// connection and `?fake=hang` never answers.
//
// What tests use to look inside:
//   GET  /fake/requests        every request and socket upgrade the hub received
//   POST /fake/config          shapes later answers: `rejectShutdown` ("off", "booted"
//                              or "missing": what the list says after serve-sim
//                              refuses a shutdown) and `listFailsAfterShutdown`
//   GET  /fake/captures        serve-sim's capture per simulator: a number that grows
//                              with each new capture; a shutdown releases it and ends
//                              its streams
//   GET  /fake/env             the PATH the hub runs with
//   GET  /fake/sockets-closed  answers once no socket is open
// A socket closes from the hub's side when it gets the text frame {"fake":"close"}.
import * as Crypto from "node:crypto";
import * as Http from "node:http";

const args = process.argv.slice(2);
const port = Number(args[args.indexOf("--port") + 1]);
const host = args[args.indexOf("--host") + 1];
const origin = `http://${host}:${port}`;
const emulators = JSON.parse(process.env.FAKE_HUB_EMULATORS || "[]");
const simulators = JSON.parse(process.env.FAKE_HUB_SIMULATORS || "[]");
const streams = new Set();
const streamsClosed = [];
const sockets = new Set();
const socketsClosed = [];
const requests = [];
const captures = {};
let captureCount = 0;
let fake = {};
let listFails = false;
// serve-emu's live stream: its mode and settings.
let streamMode = { mode: "mjpeg" };
let streamSettings = { fps: 30, quality: 80 };

// A PNG header is all a screenshot reader looks at: 390x844.
const png = Buffer.alloc(33);
Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]).copy(png, 0);
png.write("IHDR", 12, "latin1");
png.writeUInt32BE(390, 16);
png.writeUInt32BE(844, 20);

const readBody = (request) =>
  new Promise((resolve) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolve(chunks.length ? JSON.parse(Buffer.concat(chunks)) : {}));
  });

const record = (request) => {
  if (!request.url.startsWith("/fake/") && request.url !== "/readyz")
    requests.push({ method: request.method, url: request.url, headers: request.headers });
};

const server = Http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${host}`);
  record(request);
  response.setHeader("x-fake-hub-url", request.url);
  const json = (value, status = 200) => {
    response.statusCode = status;
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify(value));
  };

  if (url.searchParams.get("fake") === "drop") return request.socket.destroy();
  if (url.searchParams.get("fake") === "hang") return;
  if (url.pathname === "/readyz") return response.end("ok");
  if (url.pathname === "/fake/requests") return json(requests);
  if (url.pathname === "/fake/captures") return json(captures);
  if (url.pathname === "/fake/env") return json({ PATH: process.env.PATH });
  if (url.pathname === "/fake/config") {
    fake = { ...fake, ...(await readBody(request)) };
    return json(fake);
  }
  if (url.pathname === "/api/devices") {
    if (listFails) return json({ error: "adb is not responding" }, 500);
    const listed = simulators.filter((device) => !device.hidden);
    return json({ simulators: listed, emulators, errors: [] });
  }

  if (url.pathname === "/fake/streams-closed") {
    const answer = () => response.end("closed");
    return streams.size ? streamsClosed.push(answer) : answer();
  }

  if (url.pathname === "/fake/sockets-closed") {
    const answer = () => response.end("closed");
    return sockets.size ? socketsClosed.push(answer) : answer();
  }

  const stream = url.pathname.match(/^\/vendor\/serve-sim\/helper\/([^/]+)\/stream\.mjpeg$/);
  if (stream) {
    response.writeHead(200, { "content-type": "multipart/x-mixed-replace; boundary=frame" });
    const timer = setInterval(
      () =>
        response.write("--frame\r\ncontent-type: image/jpeg\r\ncontent-length: 4\r\n\r\njpeg\r\n"),
      20,
    );
    const entry = { udid: stream[1], response, timer };
    streams.add(entry);
    response.on("close", () => {
      clearInterval(timer);
      streams.delete(entry);
      if (streams.size === 0) streamsClosed.splice(0).forEach((answer) => answer());
    });
    return;
  }

  // serve-sim's grid attaches its stream helper (a capture) to a simulator, or shuts
  // the simulator down, which releases the capture and ends its streams.
  if (request.method === "POST" && url.pathname.startsWith("/vendor/serve-sim/grid/api/")) {
    const body = await readBody(request);
    const simulator = simulators.find((device) => device.id === body.udid);
    if (!simulator) return json({ ok: false, error: "Unknown simulator" });
    if (url.pathname.endsWith("/shutdown")) {
      if (fake.rejectShutdown) {
        if (fake.rejectShutdown === "off") simulator.booted = false;
        if (fake.rejectShutdown === "missing") simulator.hidden = true;
        return json({ ok: false, error: "Unable to shutdown device in current state" });
      }
      simulator.booted = false;
      delete captures[body.udid];
      for (const entry of streams) {
        if (entry.udid !== body.udid) continue;
        clearInterval(entry.timer);
        entry.response.end();
      }
    } else if (captures[body.udid] === undefined) {
      captures[body.udid] = ++captureCount;
    }
    return json({ ok: true });
  }

  if (request.method === "POST" && url.pathname === "/api/devices/boot") {
    const body = await readBody(request);
    const simulator = body.platform === "ios" && simulators.find((device) => device.id === body.id);
    if (simulator) {
      simulator.booted = true;
      return json({ ok: true, id: simulator.id });
    }
    if (body.name === "Broken") return json({ ok: false, error: "Not enough disk space" });
    const serial = `emulator-${5554 + emulators.length * 2}`;
    emulators.push({
      id: serial,
      name: body.name,
      version: "Android 15.0",
      platform: "android",
      booted: true,
      physical: false,
    });
    return json({ ok: true, serial });
  }

  if (request.method === "POST" && url.pathname === "/api/devices/shutdown") {
    const body = await readBody(request);
    const index = emulators.findIndex((device) => device.id === body.id);
    if (index >= 0) emulators.splice(index, 1);
    if (fake.listFailsAfterShutdown) listFails = true;
    return json({ ok: true });
  }

  // serve-emu refuses a change whose Origin is not its own.
  const setting = url.pathname.match(/^\/vendor\/serve-emu\/api\/stream-(mode|settings)$/);
  if (setting) {
    if (request.method === "GET") return json(setting[1] === "mode" ? streamMode : streamSettings);
    if (request.headers.origin !== undefined && request.headers.origin !== origin)
      return json({ error: "Cross-origin request refused" }, 403);
    const body = await readBody(request);
    if (setting[1] === "mode") streamMode = { ...streamMode, ...body };
    else streamSettings = { ...streamSettings, ...body };
    return json({ ok: true });
  }

  if (url.pathname === "/vendor/serve-emu/api/screenshot") {
    response.setHeader("content-type", "image/png");
    return response.end(png);
  }

  response.statusCode = 404;
  response.end("not found");
});

// The emulator stream socket: greets with the URL it was opened at, then echoes
// JSON text frames. Frames stay under 126 bytes, so lengths fit in one byte.
server.on("upgrade", (request, socket) => {
  record(request);
  if (new URL(request.url, `http://${host}`).searchParams.get("fake") === "hang") return;
  const accept = Crypto.createHash("sha1")
    .update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  sockets.add(socket);
  socket.on("close", () => {
    sockets.delete(socket);
    if (sockets.size === 0) socketsClosed.splice(0).forEach((answer) => answer());
  });
  const frame = (value) => {
    const payload = Buffer.from(JSON.stringify(value));
    return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
  };
  socket.write(frame({ hello: request.url }));
  let buffer = Buffer.alloc(0);
  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
    while (buffer.length >= 6 && buffer.length >= 6 + (buffer[1] & 0x7f)) {
      const opcode = buffer[0] & 0x0f;
      const length = buffer[1] & 0x7f;
      const mask = buffer.subarray(2, 6);
      const payload = Buffer.from(buffer.subarray(6, 6 + length).map((b, i) => b ^ mask[i % 4]));
      buffer = buffer.subarray(6 + length);
      if (opcode === 0x8) return socket.end();
      if (opcode !== 0x1) continue;
      const message = JSON.parse(payload.toString());
      if (message.fake === "close") return socket.end(Buffer.from([0x88, 0x00]));
      socket.write(frame({ echo: message }));
    }
  });
});

server.listen(port, host);
