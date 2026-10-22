export type ThreadHistoryMeta = {
  readonly historyCursor: string | null;
  readonly hasMoreHistory: boolean;
  readonly loading: boolean;
  readonly error: string | null;
  /** True after at least one older page was merged; skip monolithic cache growth. */
  readonly expanded: boolean;
  /**
   * Max local turn ordinal known for partial progressive windows. Null when
   * unknown (legacy cache) or when history meta is cleared for a full snapshot.
   */
  readonly latestLocalTurnOrdinal: number | null;
};

export const EMPTY_THREAD_HISTORY_META: ThreadHistoryMeta = {
  historyCursor: null,
  hasMoreHistory: false,
  loading: false,
  error: null,
  expanded: false,
  latestLocalTurnOrdinal: null,
};

/** Whether a history-page response still matches the cursor that started it. */
export function isActiveHistoryRequestCursor(
  requestCursor: string,
  history: { readonly historyCursor: string | null },
): boolean {
  return history.historyCursor === requestCursor;
}

/** Whether a client timeline should render its load-earlier control. */
export function shouldShowLoadEarlierControl(history: ThreadHistoryMeta): boolean {
  return history.hasMoreHistory || history.error !== null;
}
