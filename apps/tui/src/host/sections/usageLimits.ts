import type { EnvironmentId, ServerProvider } from "@hal-c2/contracts";
import {
  collectLimitAccounts,
  collectLimitNotices,
  collectLimitPools,
  formatResetsIn,
  type LimitAccount,
  type LimitPresentations,
  remainingPercent,
} from "@hal-c2/shared/usageLimits";

import type { UsageLimitsSnapshot } from "../../settingsClient.ts";
import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText, plural } from "./shared.ts";

/** How an account reads in the list: its name, then the hub that reports it. */
export function accountName(account: LimitAccount): string {
  const name = account.displayName ?? account.email ?? account.key;
  return account.sourceLabel ? `${name} · ${account.sourceLabel}` : name;
}

const PACE = { ahead: "ahead of pace", on: "on pace", under: "under pace" } as const;

const OUTCOME: Record<string, string> = {
  reset: "Limits reset.",
  nothingToReset: "Nothing to reset; the credit was kept.",
  noCredit: "There is no reset credit to use.",
  alreadyRedeemed: "That reset credit was already used.",
};

/**
 * Limits: what is left of each subscription's rolling windows, pooled per
 * provider over this machine's accounts and the accounts its usage hubs
 * report. An account both report counts once. A banked reset credit is spent
 * from here, after a confirmation, through the hub when a hub holds it.
 * Limits are followed only while the page is open.
 */
export function usageLimitsSection(host: SectionHost): SettingsSection {
  const { client } = host;
  let snapshot: UsageLimitsSnapshot | null = null;
  let label = "This machine";
  let environmentId = "local";
  let unsubscribe: (() => void) | null = null;
  let generation = 0;

  const presentations = (current: UsageLimitsSnapshot): LimitPresentations =>
    new Map([
      [
        environmentId as EnvironmentId,
        {
          entry: { target: { label } },
          serverConfig: { providers: current.providers, usageLimitSources: current.sources },
        },
      ],
    ]);

  const spend = (account: LimitAccount) => {
    const redeem = account.redeem;
    if (!redeem) return;
    void host.track(
      client
        .mcCall<{
          readonly outcome: string;
          readonly warning?: string;
        }>("provider.consumeResetCredit", redeem.input)
        .then(
          (result) =>
            host.status(
              [OUTCOME[result.outcome] ?? result.outcome, result.warning].filter(Boolean).join(" "),
              result.outcome === "reset" && !result.warning ? "success" : "info",
            ),
          (cause: unknown) =>
            host.status(`Could not use the reset credit: ${errorText(cause)}`, "error"),
        ),
    );
  };

  const providerLabel = (driver: ServerProvider["driver"]) =>
    snapshot?.providers.find((provider) => provider.driver === driver)?.displayName ??
    `${String(driver).charAt(0).toUpperCase()}${String(driver).slice(1)}`;

  return {
    id: "usageLimits",
    commands: () => [
      {
        id: "section.usageLimits",
        title: "Usage limits",
        keywords: "limits quota subscription accounts reset credit hub usage settings",
        action: "section.open",
        payload: { id: "usageLimits" },
      },
    ],
    open: () => {
      const asked = ++generation;
      unsubscribe?.();
      snapshot = null;
      unsubscribe = client.subscribeUsageLimits((next) => {
        snapshot = next;
        host.refresh();
      });
      void host.track(
        client.getServerConfig().then(
          (config) => {
            if (asked !== generation) return;
            const environment = config.environment as
              | { environmentId?: string; label?: string }
              | undefined;
            label = environment?.label ?? label;
            environmentId = environment?.environmentId ?? environmentId;
            host.refresh();
          },
          () => {},
        ),
      );
    },
    close: () => {
      generation += 1;
      unsubscribe?.();
      unsubscribe = null;
    },
    page: () => {
      const items: SectionItem[] = [];
      const current = snapshot;
      if (current === null) {
        items.push({ kind: "note", text: "Reading limits…" });
        return { title: "limits", items };
      }
      const now = host.now();
      const shown = presentations(current);
      for (const notice of collectLimitNotices(shown)) {
        items.push({ kind: "note", text: notice, tone: "error" });
      }
      const pools = collectLimitPools(collectLimitAccounts(shown), now);
      if (pools.length === 0) {
        items.push({
          kind: "note",
          text: "No limits to show. Sign in to a subscription provider, or add a usage hub.",
        });
      }
      for (const pool of pools) {
        items.push({ kind: "blank" });
        items.push({
          kind: "heading",
          text: `${providerLabel(pool.driver)} · ${plural(pool.accounts.length, "account")}`,
        });
        for (const window of pool.windows) {
          items.push({
            kind: "note",
            tone: "text",
            text: [
              `${window.label}: ${window.remainingPercent}% left`,
              window.pace ? PACE[window.pace] : null,
            ]
              .filter(Boolean)
              .join(" · "),
          });
          for (const member of window.members) {
            items.push({
              kind: "note",
              indent: 2,
              text: [
                accountName(member.account),
                `${remainingPercent(member.window)}% left`,
                formatResetsIn(member.window, now),
              ]
                .filter(Boolean)
                .join(" · "),
            });
          }
        }
        for (const account of pool.accounts) {
          const credits = account.limits.resetCredits?.availableCount ?? 0;
          if (credits === 0 || account.redeem === null) continue;
          items.push({
            kind: "row",
            id: `credit-${account.key}`,
            label: `Use a reset credit for ${account.displayName ?? account.email ?? account.key}`,
            value: `${credits} banked`,
            tone: "accent",
            run: () =>
              host.confirm(
                `Use a reset credit for ${account.displayName ?? account.email ?? account.key}? It clears the current limits and cannot be taken back.`,
                () => spend(account),
              ),
          });
        }
      }
      items.push({ kind: "blank" });
      items.push({
        kind: "row",
        id: "refresh",
        label: "Check limits now",
        run: () =>
          void host.track(
            client.mcCall("server.refreshProviders", {}).then(
              () => host.status("Limits checked.", "success"),
              (cause: unknown) =>
                host.status(`Could not check limits: ${errorText(cause)}`, "error"),
            ),
          ),
      });
      return { title: "limits", items };
    },
  };
}
