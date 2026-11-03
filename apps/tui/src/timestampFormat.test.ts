import { describe, expect, it } from "bun:test";

import {
  formatChatTimestampTooltip,
  formatDayAwareTimestamp,
  formatShortTimestamp,
} from "./timestampFormat.ts";

const at = (year: number, month: number, day: number, hour = 9, minute = 5) =>
  new Date(year, month - 1, day, hour, minute).toISOString();
const NOW = new Date(2026, 8, 23, 10, 0).getTime();

describe("formatShortTimestamp", () => {
  it("writes the time in the chosen format", () => {
    expect(formatShortTimestamp(at(2026, 9, 23), "12-hour")).toBe("9:05 AM");
    expect(formatShortTimestamp(at(2026, 9, 23), "24-hour")).toBe("09:05");
    expect(formatShortTimestamp(at(2026, 9, 23, 21), "24-hour")).toBe("21:05");
    expect(formatShortTimestamp("not a date", "locale")).toBe("");
  });
});

describe("formatDayAwareTimestamp", () => {
  it("adds the day once the message is not from today, and the year once it differs", () => {
    expect(formatDayAwareTimestamp(at(2026, 9, 23), "12-hour", NOW)).toBe("9:05 AM");
    expect(formatDayAwareTimestamp(at(2026, 9, 22, 23, 59), "12-hour", NOW)).toBe(
      "yesterday at 11:59 PM",
    );
    expect(formatDayAwareTimestamp(at(2026, 9, 20), "12-hour", NOW)).toBe("9/20 9:05 AM");
    expect(formatDayAwareTimestamp(at(2025, 12, 30), "12-hour", NOW)).toBe("12/30/2025 9:05 AM");
  });
});

describe("formatChatTimestampTooltip", () => {
  it("writes the ordinal day, month and year after the time", () => {
    expect(formatChatTimestampTooltip(at(2026, 9, 22), "12-hour")).toBe(
      "9:05 AM, 22nd September 2026",
    );
    expect(formatChatTimestampTooltip(at(2026, 9, 11), "12-hour")).toBe(
      "9:05 AM, 11th September 2026",
    );
    expect(formatChatTimestampTooltip(at(2026, 9, 1), "12-hour")).toBe(
      "9:05 AM, 1st September 2026",
    );
  });
});
