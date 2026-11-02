// Message times as the web writes them (apps/web/src/timestampFormat.ts at 8212e08f9),
// in the runtime's locale and the device's time format.
import type { TimestampFormat } from "@hal-c2/contracts";

export type { TimestampFormat };

/** The formats a device can choose, with what the settings call them. */
export const TIMESTAMP_FORMATS: ReadonlyArray<TimestampFormat> = ["locale", "12-hour", "24-hour"];
export const TIMESTAMP_FORMAT_LABELS: Record<TimestampFormat, string> = {
  locale: "System default",
  "12-hour": "12-hour",
  "24-hour": "24-hour",
};

const formatters = new Map<TimestampFormat, Intl.DateTimeFormat>();

/** `9:05 AM`, or `09:05` in the 24-hour format. */
export function formatShortTimestamp(isoDate: string, format: TimestampFormat): string {
  const date = new Date(isoDate);
  if (Number.isNaN(date.getTime())) return "";
  let formatter = formatters.get(format);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
      ...(format === "locale" ? {} : { hour12: format === "12-hour" }),
    });
    formatters.set(format, formatter);
  }
  return formatter.format(date);
}

const numericDate = new Intl.DateTimeFormat(undefined, { month: "numeric", day: "numeric" });
const numericDateWithYear = new Intl.DateTimeFormat(undefined, {
  month: "numeric",
  day: "numeric",
  year: "numeric",
});

/**
 * The time a message was sent, with its day once it is not today: `9:05 AM`,
 * `yesterday at 9:05 AM`, `9/20 9:05 AM`, and the year once it differs. Days are
 * local calendar days, not 24-hour windows.
 */
export function formatDayAwareTimestamp(
  isoDate: string,
  format: TimestampFormat,
  nowMs: number,
): string {
  const date = new Date(isoDate);
  if (Number.isNaN(date.getTime())) return "";
  const time = formatShortTimestamp(isoDate, format);
  const now = new Date(nowMs);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  // Rounded so the 23- and 25-hour days around a clock change still count as one.
  const daysAgo = Math.round((today - day) / 86_400_000);
  if (daysAgo <= 0) return time;
  if (daysAgo === 1) return `yesterday at ${time}`;
  const dateFormatter =
    date.getFullYear() === now.getFullYear() ? numericDate : numericDateWithYear;
  return `${dateFormatter.format(date)} ${time}`;
}

// English like the ordinal and day-before-month order around it.
const monthName = new Intl.DateTimeFormat("en-US", { month: "long" });

function ordinalSuffix(day: number): string {
  const lastTwo = day % 100;
  if (lastTwo >= 11 && lastTwo <= 13) return "th";
  return ({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[day % 10] ?? "th";
}

/** The full time a message was sent: `9:05 AM, 22nd September 2026`. */
export function formatChatTimestampTooltip(isoDate: string, format: TimestampFormat): string {
  const date = new Date(isoDate);
  if (Number.isNaN(date.getTime())) return "";
  const day = date.getDate();
  return `${formatShortTimestamp(isoDate, format)}, ${day}${ordinalSuffix(day)} ${monthName.format(date)} ${date.getFullYear()}`;
}
