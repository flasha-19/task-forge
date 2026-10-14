import { formatUnits, parseUnits } from "viem";
import { USDC_DECIMALS } from "./config";

export const STATUS = ["Open", "Accepted", "Completed", "Cancelled"] as const;
export const CATEGORIES = ["Development", "Frontend", "Smart Contract", "Documentation", "Research", "Design", "Other"] as const;

export type Task = {
  id: number;
  creator: `0x${string}`;
  contributor: `0x${string}`;
  reward: bigint;
  deadline: bigint;
  category: number;
  status: number;
  submissionCount: number;
  acceptedSubmissionId: bigint;
  title: string;
  description: string;
};
export type Submission = { id: bigint; taskId: bigint; contributor: `0x${string}`; createdAt: bigint; description: string; url: string; rejected: boolean; rejectionReason: string };

export const fmtUsdc = (v: bigint) => Number(formatUnits(v, USDC_DECIMALS)).toLocaleString(undefined, { maximumFractionDigits: 6 });
export const parseUsdc = (s: string) => parseUnits(s.trim(), USDC_DECIMALS);
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
export const sameAddr = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
export const fmtDate = (ts: bigint) => new Date(Number(ts) * 1000).toLocaleString();

/** Effective label: an Open task past its deadline is shown as Expired (derived, not stored). */
export function statusLabel(t: Pick<Task, "status" | "deadline">, nowSec = Math.floor(Date.now() / 1000)) {
  if (t.status === 0 && BigInt(nowSec) > t.deadline) return "Expired";
  return STATUS[t.status] ?? "Unknown";
}

export function safeUrl(u: string): string | null {
  try {
    const p = new URL(u);
    return p.protocol === "https:" || p.protocol === "http:" ? p.toString() : null;
  } catch {
    return null;
  }
}

export function errMsg(e: unknown): string {
  const err = e as { shortMessage?: string; message?: string; name?: string; cause?: { name?: string; reason?: string; shortMessage?: string } };
  const text = `${err?.name ?? ""} ${err?.cause?.name ?? ""} ${err?.shortMessage ?? ""} ${err?.message ?? ""}`;
  if (/UserRejected|User rejected|denied/i.test(text)) return "Wallet request was rejected.";
  if (/insufficient funds|exceeds balance/i.test(text)) return "Insufficient balance (USDC is also used for gas on Arc).";
  if (/HttpRequestError|fetch failed|Failed to fetch|timeout/i.test(text)) return "RPC request failed. Check your connection and try again.";
  const custom = /(NotCreator|NotContributor|InvalidStatus|TaskExpired|CreatorCannotSubmit|AlreadySubmitted|SubmissionTaskMismatch|CancelNotAllowed|InvalidDeadline|InvalidReward|InvalidTitle|InvalidDescription|InvalidUrl|InvalidTransferAmount)/.exec(text);
  if (custom) return `Contract rejected the transaction: ${custom[1]}.`;
  return err?.shortMessage ?? err?.message?.split("\n")[0] ?? "Unknown error.";
}
