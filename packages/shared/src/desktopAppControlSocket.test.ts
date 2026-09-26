import { describe, expect, it } from "vite-plus/test";

import { resolveDesktopAppControlSocket } from "./desktopAppControlSocket.ts";

const resolve = (dirs: { state: string; runtime: string }, platform: NodeJS.Platform = "linux") =>
  resolveDesktopAppControlSocket({
    dirs,
    platform,
    tempDir: "/tmp",
    userId: 1000,
    joinPath: (...segments) => segments.join("/"),
  });

describe("resolveDesktopAppControlSocket", () => {
  it("places the socket in the runtime directory", () => {
    const socket = resolve({
      state: "/home/me/.local/state/hal-c2",
      runtime: "/run/user/1000/hal-c2",
    });
    expect(socket.directory).toBe("/run/user/1000/hal-c2");
    expect(socket.address).toMatch(/^\/run\/user\/1000\/hal-c2\/[0-9a-f]{24}\.sock$/);
  });

  it("uses the state directory when it is the runtime directory", () => {
    const socket = resolve({
      state: "/home/me/.local/state/hal-c2",
      runtime: "/home/me/.local/state/hal-c2",
    });
    expect(socket.directory).toBe("/home/me/.local/state/hal-c2");
  });

  it("names the socket after the state directory", () => {
    const runtime = "/run/user/1000/hal-c2";
    expect(resolve({ state: "/a", runtime }).address).not.toBe(
      resolve({ state: "/b", runtime }).address,
    );
  });

  it("falls back to the temp directory when the path is too long for a socket", () => {
    const deep = `/home/me/${"nested/".repeat(20)}hal-c2/state`;
    const socket = resolve({ state: deep, runtime: deep });
    expect(socket.directory).toBe("/tmp/hal-c2-1000");
  });

  it("keeps the named pipe on Windows", () => {
    const socket = resolve(
      { state: "C:\\Users\\me\\AppData\\Local\\hal-c2\\state", runtime: "ignored" },
      "win32",
    );
    expect(socket.directory).toBeNull();
    expect(socket.address).toMatch(/^\\\\\.\\pipe\\hal-c2-app-[0-9a-f]{24}$/);
  });
});
