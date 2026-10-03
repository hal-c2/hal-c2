import type { UsageSummary } from "@hal-c2/contracts";
import { formatTokens, formatUsd } from "@hal-c2/shared/usageFormat";

import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText, plural } from "./shared.ts";

/** The window the page reads: the last seven days, today included. */
const DAYS = 7;

const PROVIDERS: Record<string, string> = { claude: "Claude", codex: "Codex", grok: "Grok" };

const day = (ms: number, timeZone: string): string =>
  new Intl.DateTimeFormat("en-CA", { timeZone, dateStyle: "short" }).format(new Date(ms));

interface ProviderTotal {
  readonly provider: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  unpricedRecords: number;
}

/** A summary's buckets added up per provider, the costliest first. */
export function usageByProvider(summary: UsageSummary): ProviderTotal[] {
  const totals = new Map<string, ProviderTotal>();
  for (const bucket of summary.buckets) {
    const total = totals.get(bucket.provider) ?? {
      provider: bucket.provider,
      inputTokens: 0,
      outputTokens: 0,
      costUsd: 0,
      unpricedRecords: 0,
    };
    total.inputTokens +=
      bucket.totals.uncachedInputTokens +
      bucket.totals.cachedInputTokens +
      bucket.totals.cacheCreationTokens;
    // Reasoning is part of output already.
    total.outputTokens += bucket.totals.outputTokens;
    total.costUsd += bucket.costUsd;
    total.unpricedRecords += bucket.unpricedRecords;
    totals.set(bucket.provider, total);
  }
  return [...totals.values()].toSorted((a, b) => b.costUsd - a.costUsd);
}

/**
 * Usage: the tokens the provider CLIs used on this machine over the last week
 * and what they would have cost at API prices, per provider, as the MC adds
 * them up from the CLIs' own transcripts (`server.getUsageSummary`). The cost
 * is an estimate, not what a subscription bills.
 */
export function usageSection(host: SectionHost): SettingsSection {
  let summary: UsageSummary | null = null;
  let failure: string | null = null;
  let generation = 0;

  const read = () => {
    const asked = ++generation;
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const now = host.now();
    void host.track(
      host.client
        .mcCall<UsageSummary>("server.getUsageSummary", {
          sinceDay: day(now - (DAYS - 1) * 86_400_000, timeZone),
          untilDay: day(now, timeZone),
          timeZone,
        })
        .then(
          (next) => {
            if (asked !== generation) return;
            summary = next;
            failure = null;
            host.refresh();
          },
          (cause: unknown) => {
            if (asked !== generation) return;
            failure = errorText(cause);
            host.refresh();
          },
        ),
    );
  };

  return {
    id: "usage",
    commands: () => [
      {
        id: "section.usage",
        title: "Usage",
        keywords: "tokens cost spend totals providers settings",
        action: "section.open",
        payload: { id: "usage" },
      },
    ],
    open: () => {
      summary = null;
      failure = null;
      read();
    },
    close: () => {
      generation += 1;
    },
    page: () => {
      const items: SectionItem[] = [];
      if (failure !== null) {
        items.push({ kind: "note", tone: "error", text: `Could not read usage: ${failure}` });
      } else if (summary === null) {
        items.push({ kind: "note", text: "Reading usage…" });
      } else {
        const totals = usageByProvider(summary);
        items.push({
          kind: "note",
          text: `${summary.sinceDay} to ${summary.untilDay} · estimated at API prices`,
        });
        if (totals.length === 0) items.push({ kind: "note", text: "No usage in this window." });
        for (const total of totals) {
          items.push({ kind: "blank" });
          items.push({ kind: "heading", text: PROVIDERS[total.provider] ?? total.provider });
          items.push({
            kind: "note",
            tone: "text",
            text: `${formatTokens(total.inputTokens + total.outputTokens)} tokens · ${formatTokens(total.inputTokens)} in · ${formatTokens(total.outputTokens)} out`,
          });
          items.push({
            kind: "note",
            tone: "text",
            text: [
              `${formatUsd(total.costUsd)} estimated`,
              total.unpricedRecords > 0
                ? `${plural(total.unpricedRecords, "response")} without a known price`
                : null,
            ]
              .filter(Boolean)
              .join(" · "),
          });
        }
        if (totals.length > 1) {
          items.push({ kind: "blank" });
          items.push({
            kind: "note",
            tone: "text",
            text: `Total ${formatUsd(totals.reduce((sum, total) => sum + total.costUsd, 0))} estimated`,
          });
        }
      }
      items.push({ kind: "blank" });
      items.push({ kind: "row", id: "refresh", label: "Read usage again", run: read });
      return { title: "usage", items };
    },
  };
}
