/**
 * "Reset quota" without deleting usage rows (they carry the cost history): the console
 * stores how many units were already spent in the current window (`profiles.quota_reset`),
 * and metering subtracts that while the window is still the same day / month.
 */

import type { QuotaReset } from "../db";
import { dayKey, monthKey, type Bucket, type WindowKind } from "../plans";

export function quotaOffset(reset: QuotaReset | null | undefined, bucket: Bucket, kind: WindowKind, now: Date): number {
  if (!reset) return 0;
  if (kind === "day") {
    if (reset.day !== dayKey(now)) return 0;
    return Math.max(0, (bucket === "answers" ? reset.answersDay : reset.tasksDay) ?? 0);
  }
  if (bucket !== "tasks" || reset.month !== monthKey(now)) return 0;
  return Math.max(0, reset.tasksMonth ?? 0);
}

/** `used` as the meter should see it after any admin reset in this window. */
export function usedAfterReset(used: number, reset: QuotaReset | null | undefined, bucket: Bucket, kind: WindowKind, now: Date): number {
  return Math.max(0, used - quotaOffset(reset, bucket, kind, now));
}
