import { ClipboardCheck, FileText, MessageCircleQuestion } from "lucide-react";
import { useState } from "react";
import type { ChatOptions } from "@/lib/api";
import { cn } from "@/lib/utils";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";
const field =
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";

export interface ClarifyQuestion {
  question: string;
  options: string[];
}

/** Clarify first: Copilot's questions as a short form; the answers start a plan. */
/** "Open PLAN.md": every decision of this request is collected there. */
function PlanLink({ onOpenFile }: { onOpenFile?: (path: string) => void }) {
  if (!onOpenFile) return null;
  return (
    <button className={flatButton} onClick={() => onOpenFile(".streamhub/PLAN.md")} title="Every question, answer, plan version and approval of this request" type="button">
      <FileText className="h-3 w-3" /> PLAN.md
    </button>
  );
}

export function ClarifyCard({
  request,
  questions,
  summary,
  planId,
  onSend,
  onOpenFile,
}: {
  request: string;
  questions: ClarifyQuestion[];
  summary?: string;
  planId?: string;
  onSend: (text: string, opts: ChatOptions) => void;
  onOpenFile?: (path: string) => void;
}) {
  const [answers, setAnswers] = useState<string[]>(questions.map(() => ""));
  const [sent, setSent] = useState(false);
  const set = (i: number, v: string) => setAnswers((a) => a.map((x, k) => (k === i ? v : x)));

  const submit = (withAnswers: boolean) => {
    setSent(true);
    const lines = questions.map((q, i) => `${i + 1}. ${q.question}\n   Answer: ${answers[i].trim() || "(no preference)"}`).join("\n");
    onSend(withAnswers ? `${request}\n\nMy answers to your questions:\n${lines}` : request, {
      planFirst: true,
      request,
      planId,
      ...(withAnswers ? { answers: questions.map((q, i) => ({ question: q.question, answer: answers[i].trim() })) } : { skipped: true }),
    });
  };

  return (
    <div className="rounded-xl border border-black/10 p-3 dark:border-white/10">
      <div className="mb-1 flex items-center gap-1.5 font-medium text-sm">
        <MessageCircleQuestion className="h-4 w-4" /> Copilot has questions first
      </div>
      {summary && <p className="mb-2 text-muted-foreground text-xs">Understood: {summary}</p>}
      <div className="space-y-3">
        {questions.map((q, i) => (
          <div className="space-y-1" key={i}>
            <div className="text-sm">{q.question}</div>
            {q.options.length > 0 && (
              <div className="flex flex-wrap gap-1">
                {q.options.map((o) => (
                  <button
                    className={cn(
                      "rounded-md border px-1.5 py-0.5 text-xs",
                      answers[i] === o ? "border-black/30 bg-black/10 dark:border-white/30 dark:bg-white/15" : "border-black/10 text-muted-foreground dark:border-white/10"
                    )}
                    disabled={sent}
                    key={o}
                    onClick={() => set(i, o)}
                    type="button"
                  >
                    {o}
                  </button>
                ))}
              </div>
            )}
            <input aria-label={`Answer to question ${i + 1}`} className={field} disabled={sent} onChange={(e) => set(i, e.target.value)} placeholder="Your answer" value={answers[i]} />
          </div>
        ))}
      </div>
      <div className="mt-3 flex flex-wrap justify-end gap-1">
        {planId && <span className="mr-auto"><PlanLink onOpenFile={onOpenFile} /></span>}
        <button className={flatButton} disabled={sent} onClick={() => submit(false)} title="Plan with Copilot's own assumptions" type="button">
          Skip questions
        </button>
        <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={sent} onClick={() => submit(true)} type="button">
          {sent ? "Sent" : "Send answers and plan"}
        </button>
      </div>
    </div>
  );
}

/** Plan first: Copilot's plan to approve (then it builds) or to change. */
export function PlanCard({
  request,
  plan,
  planId,
  onSend,
  onOpenFile,
}: {
  request: string;
  plan: string;
  planId?: string;
  onSend: (text: string, opts: ChatOptions) => void;
  onOpenFile?: (path: string) => void;
}) {
  const [changing, setChanging] = useState(false);
  const [feedback, setFeedback] = useState("");
  const [sent, setSent] = useState<"" | "build" | "change">("");

  const build = () => {
    setSent("build");
    onSend(`Build this now, following the approved plan below. Change files with action blocks.\n\nRequest: ${request}\n\nApproved plan:\n${plan}`, { asCoding: true, planId, approve: true });
  };
  const change = () => {
    setSent("change");
    onSend(`Change the plan: ${feedback.trim()}\n\nRequest: ${request}\n\nCurrent plan:\n${plan}`, { planFirst: true, request, planId, feedback: feedback.trim() });
  };

  return (
    <div className="rounded-xl border border-black/20 p-3 dark:border-white/20">
      <div className="mb-2 flex items-center gap-1.5 font-medium text-sm">
        <ClipboardCheck className="h-4 w-4" /> Plan to approve
      </div>
      <div className="whitespace-pre-wrap text-sm">{plan}</div>
      {changing && !sent && (
        <textarea aria-label="What should be different" className={cn(field, "mt-2 min-h-16 resize-y")} onChange={(e) => setFeedback(e.target.value)} placeholder="What should be different?" value={feedback} />
      )}
      <div className="mt-3 flex flex-wrap justify-end gap-1">
        {planId && <span className="mr-auto"><PlanLink onOpenFile={onOpenFile} /></span>}
        {changing ? (
          <button className={flatButton} disabled={Boolean(sent) || !feedback.trim()} onClick={change} type="button">
            {sent === "change" ? "Sent" : "Send the change"}
          </button>
        ) : (
          <button className={flatButton} disabled={Boolean(sent)} onClick={() => setChanging(true)} type="button">
            Change the plan
          </button>
        )}
        <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={Boolean(sent)} onClick={build} type="button">
          {sent === "build" ? "Building..." : "Approve and build"}
        </button>
      </div>
    </div>
  );
}
