import { useEffect, useMemo, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import type { Abi } from "viem";
import { arcTestnet, EXPLORER, FAUCET_URL, TASKFORGE_ADDRESS, USDC_ADDRESS, addrUrl, txUrl } from "./config";
import { taskForgeAbi } from "./abi";
import { erc20Abi } from "./erc20";
import { useEvents, useSubmissions, useTask, useTasks, useTx, useUsdc, type TxState } from "./data";
import { CATEGORIES, fmtDate, fmtUsdc, parseUsdc, safeUrl, sameAddr, short, statusLabel, type Task } from "./lib";

const tf = (functionName: string, args: unknown[]) => ({ address: TASKFORGE_ADDRESS!, abi: taskForgeAbi as Abi, functionName, args });

function useHashRoute() {
  const [hash, setHash] = useState(window.location.hash || "#/");
  useEffect(() => {
    const on = () => setHash(window.location.hash || "#/");
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  return hash.replace(/^#/, "").split("/").filter(Boolean);
}

/** Wallet + network state. `canWrite` is false on wrong network or when contract isn't configured. */
function useWallet() {
  const { address, isConnected, chainId } = useAccount();
  const wrongNetwork = isConnected && chainId !== arcTestnet.id;
  return { address, isConnected, chainId, wrongNetwork, canWrite: isConnected && !wrongNetwork && !!TASKFORGE_ADDRESS };
}

export default function App() {
  const route = useHashRoute();
  const w = useWallet();
  return (
    <div className="app">
      <Header />
      {!TASKFORGE_ADDRESS && (
        <div className="banner warn">
          TaskForge contract address is not configured (<code>VITE_TASKFORGE_ADDRESS</code>). Deploy the contract and set it —
          see README. No task data is shown until then.
        </div>
      )}
      {w.wrongNetwork && <WrongNetwork />}
      <main>
        {route[0] === "create" ? <CreateTask /> : route[0] === "task" ? <TaskDetail id={Number(route[1])} /> : route[0] === "activity" ? <Activity /> : <Dashboard />}
      </main>
      <footer>
        Arc Testnet · testnet funds only · <a href={FAUCET_URL} target="_blank" rel="noreferrer">Faucet</a> ·{" "}
        <a href={EXPLORER} target="_blank" rel="noreferrer">Explorer</a>
        {TASKFORGE_ADDRESS && <> · <a href={addrUrl(TASKFORGE_ADDRESS)} target="_blank" rel="noreferrer">Contract {short(TASKFORGE_ADDRESS)}</a></>}
      </footer>
    </div>
  );
}

function Header() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const onArc = isConnected && chainId === arcTestnet.id;
  return (
    <header>
      <a className="brand" href="#/">⚒ Task Forge</a>
      <nav>
        <a href="#/">Tasks</a>
        <a href="#/create">Create</a>
        <a href="#/activity">My Activity</a>
      </nav>
      <div className="wallet">
        <span className={`dot ${isConnected ? (onArc ? "ok" : "bad") : ""}`} title="Network status" />
        <span className="muted">{!isConnected ? "Not connected" : onArc ? "Arc Testnet" : `Unsupported network (${chainId})`}</span>
        {isConnected ? (
          <button className="ghost" onClick={() => disconnect()}>{short(address!)}</button>
        ) : (
          <button onClick={() => connect({ connector: connectors[0] })} disabled={isPending || !connectors.length}>
            {isPending ? "Connecting…" : "Connect wallet"}
          </button>
        )}
      </div>
      {error && <div className="banner bad">{error.message.split("\n")[0]}</div>}
    </header>
  );
}

function WrongNetwork() {
  const { switchChain, isPending, error } = useSwitchChain();
  return (
    <div className="banner bad">
      Your wallet is on an unsupported network. Transactions are disabled until you switch to Arc Testnet (chain ID {arcTestnet.id}).{" "}
      <button onClick={() => switchChain({ chainId: arcTestnet.id })} disabled={isPending}>Switch network</button>
      {error && <div>{error.message.split("\n")[0]}</div>}
    </div>
  );
}

function StatusBadge({ task }: { task: Task }) {
  const s = statusLabel(task);
  return <span className={`badge ${s.toLowerCase()}`}>{s}</span>;
}

function TxStatus({ state, onClose }: { state: TxState; onClose: () => void }) {
  if (state.phase === "idle") return null;
  return (
    <div className={`banner ${state.phase === "failed" ? "bad" : state.phase === "confirmed" ? "ok" : "info"}`}>
      <strong>{state.label}:</strong>{" "}
      {state.phase === "wallet" && "confirm in your wallet…"}
      {state.phase === "pending" && "waiting for confirmation…"}
      {state.phase === "confirmed" && "confirmed."}
      {state.phase === "failed" && (state.error ?? "failed.")}{" "}
      {state.hash && <a href={txUrl(state.hash)} target="_blank" rel="noreferrer">{short(state.hash)} ↗</a>}{" "}
      {(state.phase === "confirmed" || state.phase === "failed") && <button className="link" onClick={onClose}>dismiss</button>}
    </div>
  );
}

function Dashboard() {
  const { data: tasks, isLoading, error, refetch } = useTasks();
  const [q, setQ] = useState("");
  const [cat, setCat] = useState("all");
  const [st, setSt] = useState("all");
  const list = useMemo(
    () =>
      (tasks ?? []).filter(
        (t) =>
          (cat === "all" || t.category === Number(cat)) &&
          (st === "all" || statusLabel(t).toLowerCase() === st) &&
          (!q || (t.title + " " + t.description).toLowerCase().includes(q.toLowerCase())),
      ),
    [tasks, q, cat, st],
  );
  return (
    <>
      <div className="row between">
        <h1>Tasks</h1>
        <a className="btn" href="#/create">+ Create Task</a>
      </div>
      <div className="filters">
        <input placeholder="Search tasks…" value={q} onChange={(e) => setQ(e.target.value)} />
        <select value={cat} onChange={(e) => setCat(e.target.value)}>
          <option value="all">All categories</option>
          {CATEGORIES.map((c, i) => <option key={c} value={i}>{c}</option>)}
        </select>
        <select value={st} onChange={(e) => setSt(e.target.value)}>
          {["all", "open", "expired", "accepted", "completed", "cancelled"].map((s) => <option key={s} value={s}>{s === "all" ? "All statuses" : s}</option>)}
        </select>
      </div>
      {isLoading && <p className="muted">Loading tasks from Arc Testnet…</p>}
      {error && <div className="banner bad">Could not load tasks: {(error as Error).message.split("\n")[0]} <button onClick={() => refetch()}>Retry</button></div>}
      {TASKFORGE_ADDRESS && tasks && !list.length && <p className="muted">No tasks match. {tasks.length === 0 && "Be the first to create one."}</p>}
      <div className="grid">
        {list.map((t) => (
          <a key={t.id} className="card" href={`#/task/${t.id}`}>
            <div className="row between"><StatusBadge task={t} /><span className="reward">{fmtUsdc(t.reward)} USDC</span></div>
            <h3>{t.title}</h3>
            <p className="muted clamp">{t.description}</p>
            <div className="row between small muted">
              <span>{CATEGORIES[t.category]}</span>
              <span>{t.submissionCount} submission{t.submissionCount === 1 ? "" : "s"}</span>
              <span>Due {fmtDate(t.deadline)}</span>
            </div>
          </a>
        ))}
      </div>
    </>
  );
}

function CreateTask() {
  const w = useWallet();
  const { data: usdc } = useUsdc();
  const { state, send, reset } = useTx();
  const [f, setF] = useState({ title: "", description: "", category: "0", reward: "", deadline: "" });
  const [formErr, setFormErr] = useState<string | null>(null);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const busy = state.phase === "wallet" || state.phase === "pending";

  async function submit() {
    setFormErr(null);
    let reward: bigint;
    try { reward = parseUsdc(f.reward); } catch { return setFormErr("Enter a valid USDC amount (max 6 decimals)."); }
    const dl = Math.floor(new Date(f.deadline).getTime() / 1000);
    if (!f.title.trim() || !f.description.trim()) return setFormErr("Title and description are required.");
    if (reward <= 0n) return setFormErr("Reward must be greater than zero.");
    if (!dl || dl <= Math.floor(Date.now() / 1000)) return setFormErr("Deadline must be in the future.");
    if (usdc && usdc.balance < reward) return setFormErr(`Insufficient USDC balance (${fmtUsdc(usdc.balance)}). Get testnet USDC from the faucet.`);

    // Step 1: approve exact reward if needed. Step 2: create + fund.
    if (!usdc || usdc.allowance < reward) {
      const ok = await send("Approve USDC", { address: USDC_ADDRESS, abi: erc20Abi as unknown as Abi, functionName: "approve", args: [TASKFORGE_ADDRESS, reward] });
      if (!ok) return;
    }
    const ok = await send("Create & fund task", tf("createTask", [f.title.trim(), f.description.trim(), Number(f.category), reward, BigInt(dl)]));
    if (ok) window.location.hash = "#/";
  }

  return (
    <div className="panel">
      <h1>Create Task</h1>
      <label>Title<input value={f.title} onChange={set("title")} maxLength={120} /></label>
      <label>Description<textarea rows={6} value={f.description} onChange={set("description")} maxLength={2000} placeholder="What needs to be done? Link to the GitHub issue, requirements, acceptance criteria." /></label>
      <div className="two">
        <label>Category<select value={f.category} onChange={set("category")}>{CATEGORIES.map((c, i) => <option key={c} value={i}>{c}</option>)}</select></label>
        <label>Reward (USDC)<input inputMode="decimal" value={f.reward} onChange={set("reward")} placeholder="25" /></label>
      </div>
      <label>Deadline<input type="datetime-local" value={f.deadline} onChange={set("deadline")} /></label>
      {usdc && <p className="muted small">Your ERC-20 USDC balance: {fmtUsdc(usdc.balance)}. Funding needs an approval transaction, then the create transaction.</p>}
      {formErr && <div className="banner bad">{formErr}</div>}
      <TxStatus state={state} onClose={reset} />
      <button onClick={submit} disabled={!w.canWrite || busy}>
        {!w.isConnected ? "Connect wallet first" : w.wrongNetwork ? "Switch to Arc Testnet" : !TASKFORGE_ADDRESS ? "Contract not configured" : busy ? "Working…" : "Approve & fund task"}
      </button>
    </div>
  );
}

function TaskDetail({ id }: { id: number }) {
  const w = useWallet();
  const { task, isLoading } = useTask(id);
  const { data: subs } = useSubmissions(id, task?.submissionCount ?? 0);
  const { data: events } = useEvents();
  const { state, send, reset } = useTx();
  const [desc, setDesc] = useState("");
  const [url, setUrl] = useState("");
  const [formErr, setFormErr] = useState<string | null>(null);
  const busy = state.phase === "wallet" || state.phase === "pending";

  if (isLoading) return <p className="muted">Loading…</p>;
  if (!task) return <p className="muted">Task #{id} not found. <a href="#/">Back</a></p>;

  const label = statusLabel(task);
  const isCreator = sameAddr(w.address, task.creator);
  const isContributor = sameAddr(w.address, task.contributor);
  const now = Math.floor(Date.now() / 1000);
  const hasSubmitted = !!subs?.some((s) => sameAddr(s.contributor, w.address));
  const canCancel = task.status === 0 && (task.submissionCount === 0 || now > Number(task.deadline) + 7 * 86400);

  async function submitWork() {
    setFormErr(null);
    if (!desc.trim()) return setFormErr("Describe your work.");
    const u = safeUrl(url.trim());
    if (!u) return setFormErr("Enter a valid http(s) URL to your deliverable (GitHub PR, issue, etc.).");
    if (await send("Submit work", tf("submitWork", [BigInt(id), desc.trim(), u]))) { setDesc(""); setUrl(""); }
  }

  const evRows = (events ?? []).filter((e) => e.taskId === BigInt(id));

  return (
    <div className="panel">
      <a href="#/" className="small">← All tasks</a>
      <div className="row between"><h1>{task.title}</h1><StatusBadge task={task} /></div>
      <p className="pre">{task.description}</p>
      <dl className="meta">
        <dt>Reward</dt><dd className="reward">{fmtUsdc(task.reward)} USDC</dd>
        <dt>Category</dt><dd>{CATEGORIES[task.category]}</dd>
        <dt>Deadline</dt><dd>{fmtDate(task.deadline)}</dd>
        <dt>Creator</dt><dd><a href={addrUrl(task.creator)} target="_blank" rel="noreferrer">{short(task.creator)}</a>{isCreator && " (you)"}</dd>
        <dt>Submissions</dt><dd>{task.submissionCount}</dd>
        {task.status >= 1 && task.status !== 3 && (<><dt>Accepted submission</dt><dd>#{task.acceptedSubmissionId.toString()} by {short(task.contributor)}</dd></>)}
      </dl>

      <TxStatus state={state} onClose={reset} />
      {!w.canWrite && <p className="muted small">{!w.isConnected ? "Connect your wallet to interact." : w.wrongNetwork ? "Switch to Arc Testnet to interact." : ""}</p>}

      {task.status === 1 && isContributor && (
        <div className="banner ok">
          Your submission was accepted. <button disabled={!w.canWrite || busy} onClick={() => send("Withdraw reward", tf("withdrawReward", [BigInt(id)]))}>Withdraw {fmtUsdc(task.reward)} USDC</button>
        </div>
      )}
      {isCreator && task.status === 0 && (
        <div className="row gap">
          <button className="danger" disabled={!w.canWrite || busy || !canCancel} onClick={() => send("Cancel task", tf("cancelTask", [BigInt(id)]))}>Cancel & refund</button>
          {!canCancel && <span className="muted small">Cancellation is available with no submissions, or 7 days after the deadline if none was accepted.</span>}
        </div>
      )}

      <h2>Submissions</h2>
      {!subs?.length && <p className="muted">No submissions yet.</p>}
      {subs?.map((s) => {
        const link = safeUrl(s.url);
        const accepted = task.status >= 1 && task.status !== 3 && task.acceptedSubmissionId === s.id;
        return (
          <div key={s.id.toString()} className={`sub ${accepted ? "accepted" : ""}`}>
            <div className="row between">
              <span>#{s.id.toString()} · {short(s.contributor)}{sameAddr(s.contributor, w.address) && " (you)"} · {fmtDate(s.createdAt)}</span>
              {accepted && <span className="badge accepted">Accepted</span>}
            </div>
            <p className="pre">{s.description}</p>
            {link ? <a href={link} target="_blank" rel="noreferrer noopener">{link} ↗</a> : <span className="muted">Invalid URL</span>}
            {isCreator && task.status === 0 && (
              <div><button disabled={!w.canWrite || busy} onClick={() => send("Accept submission", tf("acceptSubmission", [BigInt(id), s.id]))}>Accept this submission</button></div>
            )}
          </div>
        );
      })}

      {!isCreator && task.status === 0 && label !== "Expired" && (
        <>
          <h2>Submit work</h2>
          {hasSubmitted ? <p className="muted">You have already submitted to this task.</p> : (
            <>
              <label>Description<textarea rows={4} value={desc} onChange={(e) => setDesc(e.target.value)} maxLength={2000} /></label>
              <label>Deliverable URL (GitHub PR / issue / other)<input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://github.com/org/repo/pull/1" /></label>
              {formErr && <div className="banner bad">{formErr}</div>}
              <button disabled={!w.canWrite || busy} onClick={submitWork}>Submit work</button>
            </>
          )}
        </>
      )}
      {label === "Expired" && <p className="muted">This task is past its deadline; new submissions are closed.</p>}

      <h2>Onchain activity</h2>
      {!evRows.length && <p className="muted small">No events found{events ? "" : " (loading…)"}. Set <code>VITE_DEPLOY_BLOCK</code> to the deployment block so history can be loaded.</p>}
      <ul className="events">
        {evRows.map((e) => (
          <li key={e.txHash + e.name + (e.submissionId ?? "")}>{e.name}{e.account ? ` · ${short(e.account)}` : ""} · <a href={txUrl(e.txHash)} target="_blank" rel="noreferrer">{short(e.txHash)} ↗</a></li>
        ))}
      </ul>
    </div>
  );
}

function Activity() {
  const w = useWallet();
  const { data: tasks } = useTasks();
  const { data: events } = useEvents();
  const { state, send, reset } = useTx();
  if (!w.isConnected) return <p className="muted">Connect your wallet to see your activity.</p>;
  const me = w.address;
  const created = (tasks ?? []).filter((t) => sameAddr(t.creator, me));
  const mySubs = (events ?? []).filter((e) => e.name === "SubmissionCreated" && sameAddr(e.account, me));
  const accepted = (tasks ?? []).filter((t) => t.status >= 1 && t.status !== 3 && sameAddr(t.contributor, me));
  const withdrawable = accepted.filter((t) => t.status === 1);
  const paid = accepted.filter((t) => t.status === 2);
  const refunds = (events ?? []).filter((e) => e.name === "TaskCancelled" && sameAddr(e.account, me));
  const eligibleRefunds = created.filter((t) => t.status === 0 && (t.submissionCount === 0 || Date.now() / 1000 > Number(t.deadline) + 7 * 86400));
  const busy = state.phase === "wallet" || state.phase === "pending";
  const taskLink = (t: Task) => <a href={`#/task/${t.id}`}>#{t.id} {t.title}</a>;
  return (
    <div className="panel">
      <h1>My Activity</h1>
      <TxStatus state={state} onClose={reset} />
      <h2>Withdrawable rewards ({withdrawable.length})</h2>
      {withdrawable.map((t) => (
        <div key={t.id} className="row between sub">{taskLink(t)}<button disabled={!w.canWrite || busy} onClick={() => send("Withdraw reward", tf("withdrawReward", [BigInt(t.id)]))}>Withdraw {fmtUsdc(t.reward)} USDC</button></div>
      ))}
      {!withdrawable.length && <p className="muted">Nothing to withdraw.</p>}
      <h2>Eligible refunds ({eligibleRefunds.length})</h2>
      {eligibleRefunds.map((t) => (
        <div key={t.id} className="row between sub">{taskLink(t)}<button className="danger" disabled={!w.canWrite || busy} onClick={() => send("Cancel task", tf("cancelTask", [BigInt(t.id)]))}>Reclaim {fmtUsdc(t.reward)} USDC</button></div>
      ))}
      {!eligibleRefunds.length && <p className="muted">No tasks eligible for refund.</p>}
      <h2>Created tasks ({created.length})</h2>
      {created.map((t) => <div key={t.id} className="row between sub">{taskLink(t)}<span><StatusBadge task={t} /> {fmtUsdc(t.reward)} USDC</span></div>)}
      <h2>Submitted work ({mySubs.length})</h2>
      {mySubs.map((e) => {
        const t = tasks?.find((x) => BigInt(x.id) === e.taskId);
        return <div key={e.txHash} className="row between sub"><span>{t ? taskLink(t) : `Task #${e.taskId}`}</span><a href={txUrl(e.txHash)} target="_blank" rel="noreferrer">{short(e.txHash)} ↗</a></div>;
      })}
      <h2>Accepted submissions ({accepted.length})</h2>
      {accepted.map((t) => <div key={t.id} className="row between sub">{taskLink(t)}<StatusBadge task={t} /></div>)}
      <h2>Completed payments ({paid.length}) &amp; refunds ({refunds.length})</h2>
      {paid.map((t) => <div key={t.id} className="sub">{taskLink(t)} — paid {fmtUsdc(t.reward)} USDC</div>)}
      {refunds.map((e) => <div key={e.txHash} className="sub">Task #{e.taskId.toString()} refunded {e.amount !== undefined && fmtUsdc(e.amount)} USDC · <a href={txUrl(e.txHash)} target="_blank" rel="noreferrer">{short(e.txHash)} ↗</a></div>)}
    </div>
  );
}
