import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useAccount, usePublicClient, useWriteContract } from "wagmi";
import { useCallback, useState } from "react";
import type { Abi, Hash } from "viem";
import { arcTestnet, DEPLOY_BLOCK, TASKFORGE_ADDRESS, USDC_ADDRESS } from "./config";
import { taskForgeAbiWithRejection as taskForgeAbi } from "./abi";
import { erc20Abi } from "./erc20";
import { errMsg, type Submission, type Task } from "./lib";

type RawTask = Omit<Task, "id" | "submissionCount" | "category" | "status"> & { submissionCount: number; category: number; status: number };

const toTask = (id: number, t: RawTask): Task => ({ ...t, id, category: Number(t.category), status: Number(t.status), submissionCount: Number(t.submissionCount) });

export function useTasks() {
  const client = usePublicClient({ chainId: arcTestnet.id });
  return useQuery({
    queryKey: ["tasks", TASKFORGE_ADDRESS],
    enabled: !!client && !!TASKFORGE_ADDRESS,
    queryFn: async (): Promise<Task[]> => {
      const addr = TASKFORGE_ADDRESS!;
      const total = Number(await client!.readContract({ address: addr, abi: taskForgeAbi, functionName: "taskCount" }));
      const out: Task[] = [];
      const PAGE = 50;
      for (let off = 0; off < total; off += PAGE) {
        const page = (await client!.readContract({ address: addr, abi: taskForgeAbi, functionName: "getTasks", args: [BigInt(off), BigInt(PAGE)] })) as unknown as RawTask[];
        page.forEach((t, i) => out.push(toTask(off + i, t)));
      }
      return out.reverse(); // newest first
    },
  });
}

export function useTask(id: number) {
  const { data: tasks, ...rest } = useTasks();
  return { task: tasks?.find((t) => t.id === id), tasks, ...rest };
}

export function useSubmissions(taskId: number, count: number) {
  const client = usePublicClient({ chainId: arcTestnet.id });
  return useQuery({
    queryKey: ["subs", TASKFORGE_ADDRESS, taskId, count],
    enabled: !!client && !!TASKFORGE_ADDRESS,
    queryFn: async (): Promise<Submission[]> => {
      const addr = TASKFORGE_ADDRESS!;
      const [ids, subs] = (await client!.readContract({ address: addr, abi: taskForgeAbi, functionName: "getTaskSubmissions", args: [BigInt(taskId), 0n, 200n] })) as unknown as [bigint[], Omit<Submission, "id">[]];

      // Deployments predating submission rejection don't expose these getters, so calling them
      // reverts. Probe once, then degrade gracefully: rejection metadata missing must never
      // hide the submissions themselves (the UI would otherwise claim "No submissions yet").
      let supportsRejection = false;
      if (ids.length > 0) {
        try {
          await client!.readContract({ address: addr, abi: taskForgeAbi, functionName: "submissionRejected", args: [ids[0]] });
          supportsRejection = true;
        } catch {
          supportsRejection = false;
        }
      }

      return Promise.all(subs.map(async (s, i) => {
        let rejected = false;
        let rejectionReason = "";
        if (supportsRejection) {
          try {
            [rejected, rejectionReason] = await Promise.all([
              client!.readContract({ address: addr, abi: taskForgeAbi, functionName: "submissionRejected", args: [ids[i]] }),
              client!.readContract({ address: addr, abi: taskForgeAbi, functionName: "submissionRejectionReason", args: [ids[i]] }),
            ]);
          } catch {
            // Keep the submission visible; only its rejection metadata is unavailable.
          }
        }

        return {
          ...s,
          id: ids[i],
          rejected: Boolean(rejected),
          rejectionReason: String(rejectionReason),
        };
      }));
    },
  });
}

/**
 * Probes whether the configured deployment supports submission rejection (added after the first
 * deployment). Older contracts revert when the getter is called, so the UI hides the reject
 * controls instead of sending transactions that are guaranteed to fail.
 */
export function useRejectionSupport() {
  const client = usePublicClient({ chainId: arcTestnet.id });
  return useQuery({
    queryKey: ["rejectionSupport", TASKFORGE_ADDRESS],
    enabled: !!client && !!TASKFORGE_ADDRESS,
    queryFn: async (): Promise<boolean> => {
      try {
        await client!.readContract({ address: TASKFORGE_ADDRESS!, abi: taskForgeAbi, functionName: "submissionRejected", args: [0n] });
        return true;
      } catch {
        return false;
      }
    },
  });
}

export type EventRow = { name: string; taskId: bigint; submissionId?: bigint; account?: `0x${string}`; amount?: bigint; txHash: Hash; block: bigint };

/** All TaskForge events since the configured deploy block — source of tx hashes and activity history. */
export function useEvents() {
  const client = usePublicClient({ chainId: arcTestnet.id });
  return useQuery({
    queryKey: ["events", TASKFORGE_ADDRESS],
    enabled: !!client && !!TASKFORGE_ADDRESS,
    queryFn: async (): Promise<EventRow[]> => {
      const logs = await client!.getContractEvents({ address: TASKFORGE_ADDRESS!, abi: taskForgeAbi as Abi, fromBlock: DEPLOY_BLOCK, toBlock: "latest" });
      return logs.map((l) => {
        const a = (l as unknown as { args: Record<string, unknown> }).args;
        return {
          name: (l as unknown as { eventName: string }).eventName,
          taskId: a.taskId as bigint,
          submissionId: a.submissionId as bigint | undefined,
          account: (a.contributor ?? a.creator) as `0x${string}` | undefined,
          amount: (a.amount ?? a.refund ?? a.reward) as bigint | undefined,
          txHash: l.transactionHash as Hash,
          block: l.blockNumber as bigint,
        };
      });
    },
  });
}

export function useUsdc() {
  const { address } = useAccount();
  const client = usePublicClient({ chainId: arcTestnet.id });
  return useQuery({
    queryKey: ["usdc", address, TASKFORGE_ADDRESS],
    enabled: !!client && !!address && !!TASKFORGE_ADDRESS,
    queryFn: async () => {
      const [balance, allowance] = await Promise.all([
        client!.readContract({ address: USDC_ADDRESS, abi: erc20Abi, functionName: "balanceOf", args: [address!] }),
        client!.readContract({ address: USDC_ADDRESS, abi: erc20Abi, functionName: "allowance", args: [address!, TASKFORGE_ADDRESS!] }),
      ]);
      return { balance, allowance };
    },
  });
}

export type TxState = { phase: "idle" | "wallet" | "pending" | "confirmed" | "failed"; label?: string; hash?: Hash; error?: string };

/** Sends txs one at a time; only reports "confirmed" after a successful receipt. */
export function useTx() {
  const client = usePublicClient({ chainId: arcTestnet.id });
  const { writeContractAsync } = useWriteContract();
  const qc = useQueryClient();
  const [state, setState] = useState<TxState>({ phase: "idle" });

  const send = useCallback(
    async (label: string, req: { address: `0x${string}`; abi: Abi; functionName: string; args: unknown[] }): Promise<boolean> => {
      try {
        setState({ phase: "wallet", label });
        const hash = await writeContractAsync({ ...req, chainId: arcTestnet.id } as never);
        setState({ phase: "pending", label, hash });
        const receipt = await client!.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") {
          setState({ phase: "failed", label, hash, error: "Transaction reverted onchain." });
          return false;
        }
        setState({ phase: "confirmed", label, hash });
        await qc.invalidateQueries();
        return true;
      } catch (e) {
        setState((s) => ({ phase: "failed", label, hash: s.hash, error: errMsg(e) }));
        return false;
      }
    },
    [client, writeContractAsync, qc],
  );

  return { state, send, reset: () => setState({ phase: "idle" }) };
}
