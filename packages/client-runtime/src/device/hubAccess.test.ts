import { describe, expect, it } from "vite-plus/test";

import { atDeviceHubBasePath } from "./hubAccess.ts";

const access = {
  httpBase: "https://mc.example.ts.net/api/device-hub",
  wsBase: "wss://mc.example.ts.net/api/device-hub",
  query: { wsTicket: "ticket" },
  credentials: false,
};

describe("atDeviceHubBasePath", () => {
  it("routes through the connected origin to the MC the state names", () => {
    expect(atDeviceHubBasePath(access, "/api/device-hub/mcs/hal-c2%40mini")).toEqual({
      httpBase: "https://mc.example.ts.net/api/device-hub/mcs/hal-c2%40mini",
      wsBase: "wss://mc.example.ts.net/api/device-hub/mcs/hal-c2%40mini",
      query: { wsTicket: "ticket" },
      credentials: false,
    });
  });

  it("keeps access as it is before the state arrives", () => {
    expect(atDeviceHubBasePath(access, undefined)).toBe(access);
  });
});
