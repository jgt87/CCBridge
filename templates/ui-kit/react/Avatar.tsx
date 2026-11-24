/**
 * UI kit components for React projects: render the kit's markup (styles/kit/kit.css), need only React.
 * Adapted from kokonutui team-selector (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { type CSSProperties, useState } from "react";

/** The same colour for the same name as kit.js gives it: one of the six chart colours. */
function avatarColor(name: string) {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) | 0;
  return "var(--kit-chart-" + ((Math.abs(h) % 6) + 1) + ")";
}

function initials(name: string) {
  const words = name.trim().split(/\s+/).filter(Boolean);
  return ((words[0] ?? "").charAt(0) + (words.length > 1 ? words[words.length - 1].charAt(0) : "")).toUpperCase();
}

/** A person outline (Lucide "user", ISC licence) for an avatar with no name to take initials from. */
function PersonIcon() {
  return (
    <svg aria-hidden="true" fill="none" focusable="false" height="60%" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} viewBox="0 0 24 24" width="60%">
      <path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2" />
      <circle cx="12" cy="7" r="4" />
    </svg>
  );
}

/**
 * A person as initials (or a photo) in their own chart colour. A photo that fails to load falls back
 * to the initials; no name shows a person outline. decorative: the name is already written beside
 * it, so screen readers skip the avatar instead of reading the name twice.
 */
export function Avatar({ name, src, size, decorative = false }: { name: string; src?: string; size?: "sm" | "lg"; decorative?: boolean }) {
  const [failed, setFailed] = useState<string | null>(null);
  const style = { "--kit-avatar-color": avatarColor(name) } as CSSProperties;
  const text = initials(name);
  const photo = src && failed !== src;
  const label = name.trim() || "Person";
  return (
    <span
      aria-hidden={decorative ? true : undefined}
      aria-label={decorative ? undefined : label}
      className={"kit-avatar" + (size ? " kit-avatar--" + size : "")}
      role={decorative ? undefined : "img"}
      style={style}
      title={name || undefined}
    >
      {photo ? <img alt="" onError={() => setFailed(src)} src={src} /> : text || <PersonIcon />}
    </span>
  );
}

/** A group of people, the first few as avatars and the rest as "+N". */
export function AvatarGroup({ names, max = 4, label }: { names: string[]; max?: number; label: string }) {
  const shown = names.slice(0, max);
  const rest = names.length - shown.length;
  return (
    <div aria-label={label} className="kit-avatars" role="group">
      {/* Two people can share a name: the key is the place in the list plus the name. */}
      {shown.map((n, i) => (
        <Avatar key={i + ":" + n} name={n} />
      ))}
      {rest > 0 ? (
        <span className="kit-avatars__more" title={names.slice(max).join(", ")}>
          +{rest}
        </span>
      ) : null}
    </div>
  );
}
