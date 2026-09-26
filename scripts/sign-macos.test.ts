import { sign as signApplication, type SignOptions } from "@electron/osx-sign";
import { expect, it, vi } from "vite-plus/test";

import sign from "./sign-macos.ts";

vi.mock("@electron/osx-sign", () => ({ sign: vi.fn() }));

it("batches codesign calls without changing existing signing options", async () => {
  const options = {
    app: "/tmp/HAL-C2.app",
    identity: "Developer ID Application: HAL-C2, Inc.",
    keychain: "/tmp/hal-c2.keychain",
    provisioningProfile: "/tmp/hal-c2.provisionprofile",
    optionsForFile: () => ({
      entitlements: "/tmp/hal-c2.entitlements.plist",
      hardenedRuntime: true,
    }),
  } satisfies SignOptions;

  await sign(options);

  expect(signApplication).toHaveBeenCalledExactlyOnceWith({
    ...options,
    batchCodesignCalls: true,
  });
});
