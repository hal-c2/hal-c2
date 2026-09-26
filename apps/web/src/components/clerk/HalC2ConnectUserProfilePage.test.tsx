import type { EnvironmentId } from "@hal-c2/contracts";
import type { RelayClientEnvironmentRecord } from "@hal-c2/contracts/relay";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vite-plus/test";

import { HalC2ConnectEnvironmentRow } from "./HalC2ConnectUserProfilePage";

const environment: RelayClientEnvironmentRecord = {
  environmentId: "environment-1" as EnvironmentId,
  label: "Studio Mac",
  endpoint: {
    httpBaseUrl: "https://studio.example.com",
    wsBaseUrl: "wss://studio.example.com",
    providerKind: "cloudflare_tunnel",
  },
  linkedAt: "2026-08-12T12:00:00.000Z",
};

function renderRow({
  confirmationOpen = false,
  mutationPending = false,
}: {
  readonly confirmationOpen?: boolean;
  readonly mutationPending?: boolean;
} = {}) {
  return renderToStaticMarkup(
    <HalC2ConnectEnvironmentRow
      environment={environment}
      confirmationOpen={confirmationOpen}
      mutationPending={mutationPending}
      onConfirmationChange={vi.fn()}
      onDeregister={vi.fn()}
    />,
  );
}

describe("HAL-C2 Connect environment row", () => {
  it("keeps deregistration confirmation inline and collapsed by default", () => {
    const markup = renderRow();

    expect(markup).toContain("Studio Mac");
    expect(markup).toContain("Deregister");
    expect(markup).not.toContain("Deregister server");
    expect(markup).not.toContain("Confirm deregistration of Studio Mac");
  });

  it("expands Clerk-style confirmation content beneath the environment row", () => {
    const markup = renderRow({ confirmationOpen: true });

    expect(markup).toContain("Deregister server");
    expect(markup).toContain("“Studio Mac” will be removed from this account.");
    expect(markup).toContain("Confirm deregistration of Studio Mac");
    expect(markup).toContain("Local connections on your devices are not changed.");
    expect(markup).toContain("Cancel");
  });

  it("locks the confirmation actions while deregistration is pending", () => {
    const markup = renderRow({ confirmationOpen: true, mutationPending: true });

    expect(markup).toContain("Deregistering…");
    expect(markup.match(/ disabled=""/g)).toHaveLength(3);
  });
});
