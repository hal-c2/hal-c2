import { describe, expect, it } from "bun:test";

import { hashMachineId, hostedHere, loopbackHost, thisMachineId } from "./thisMachine.ts";

const HERE = "5e1f00000000000000000000000000000000000000000000000000000000c0de";
const ELSEWHERE = "a1".repeat(32);

describe("hashMachineId", () => {
  it("hashes the raw id as the MC and the desktop do", () => {
    // apps/server-ex/test/hal_c2/environment_machine_test.exs has the same vector.
    expect(hashMachineId(Buffer.from("0123456789abcdef0123456789abcdef"))).toBe(
      "3eb1bd439947eb762998e566ccc2e099c791118b2f40579cc4f7da2b5061b7f9",
    );
    expect(hashMachineId(null)).toBeNull();
    expect(hashMachineId(Buffer.alloc(0))).toBeNull();
  });

  it("reads this machine's id once", async () => {
    const id = await thisMachineId();
    expect(id === null || /^[0-9a-f]{64}$/.test(id)).toBe(true);
    expect(await thisMachineId()).toBe(id);
  });
});

describe("loopbackHost", () => {
  it("knows this machine's loopback names", () => {
    for (const host of [
      "localhost",
      "LOCALHOST",
      "127.0.0.1",
      "127.8.9.10",
      "::1",
      "[::1]",
      "::ffff:127.0.0.1",
      new URL("ws://[::ffff:127.0.0.1]:3773").hostname,
      "[::ffff:7f08:90a]",
    ]) {
      expect(loopbackHost(host)).toBe(true);
    }
    for (const host of [
      "",
      "192.168.1.20",
      "100.64.0.7",
      "devbox",
      "localhost.example.com",
      "::2",
      new URL("ws://[::ffff:192.168.1.20]:3773").hostname,
    ]) {
      expect(loopbackHost(host)).toBe(false);
    }
  });
});

describe("hostedHere", () => {
  it("goes by the ids when both are known", () => {
    // A cluster member on this machine, reached through another MC.
    expect(
      hostedHere({ ours: HERE, theirs: HERE, own: false, origin: "ws://192.168.1.20:3773" }),
    ).toBe(true);
    // An SSH port forward: loopback, but another machine.
    expect(
      hostedHere({ ours: HERE, theirs: ELSEWHERE, own: true, origin: "ws://127.0.0.1:3773" }),
    ).toBe(false);
  });

  it("else takes only its own MC on loopback to be here", () => {
    expect(
      hostedHere({ ours: HERE, theirs: undefined, own: true, origin: "ws://localhost:3773" }),
    ).toBe(true);
    expect(
      hostedHere({ ours: null, theirs: ELSEWHERE, own: true, origin: "ws://[::1]:3773" }),
    ).toBe(true);
    expect(
      hostedHere({ ours: HERE, theirs: null, own: true, origin: "wss://devbox.tailnet.ts.net" }),
    ).toBe(false);
    expect(
      hostedHere({ ours: HERE, theirs: null, own: false, origin: "ws://127.0.0.1:3773" }),
    ).toBe(false);
    expect(hostedHere({ ours: HERE, theirs: null, own: true, origin: "" })).toBe(false);
  });
});
