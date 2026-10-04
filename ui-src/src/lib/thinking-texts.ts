/**
 * The texts the chat shows while a message waits for its reply. Generic on purpose: they never
 * name the assistant's product. The plain lines say what is happening; a light line is mixed in
 * between them, in an order that changes per message (the seed).
 */

/** Sent, no reply yet. */
export const WAITING = ["Sending your message...", "Waiting for the reply...", "Thinking it over..."];

/** The reply is coming in. */
export const WRITING = ["Writing the reply...", "Receiving the reply..."];

export const FUNNY_WAITING = [
  "Warming up the neurons...",
  "Consulting the rubber duck...",
  "Counting the brackets twice...",
  "Asking very nicely...",
  "Brewing a fresh pot of ideas...",
  "Reticulating splines...",
  "Herding semicolons...",
  "Untangling the spaghetti...",
  "Reading the manual, for once...",
  "Bribing the compiler with cookies...",
  "Looking for the missing semicolon...",
  "Turning it off and on again...",
  "Feeding the hamsters...",
  "Rearranging the bits...",
  "Pretending this is a hard one...",
  "Checking under the sofa for bugs...",
];

export const FUNNY_WRITING = [
  "Typing furiously...",
  "Choosing the finest characters...",
  "Indenting with care...",
  "Words incoming...",
  "Closing every bracket it opens...",
  "Dotting the i's, crossing the t's...",
  "Making it look easy...",
];

/** A fixed shuffle for one seed (the same message keeps the same order while it waits). */
export function shuffled<T>(list: readonly T[], seed: number): T[] {
  const out = [...list];
  let s = (Math.abs(Math.floor(seed)) % 2147483646) + 1;
  for (let i = out.length - 1; i > 0; i--) {
    s = (s * 16807) % 2147483647;
    const j = s % (i + 1);
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/** Plain lines first, then plain and light lines taking turns. */
export function thinkingTexts(phase: "waiting" | "writing", seed: number): string[] {
  const plain = phase === "writing" ? WRITING : WAITING;
  const funny = shuffled(phase === "writing" ? FUNNY_WRITING : FUNNY_WAITING, seed);
  const out = [...plain];
  funny.forEach((f, i) => out.push(f, plain[i % plain.length]));
  return out;
}
