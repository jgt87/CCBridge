/**
 * UI kit components for React projects: render the kit's markup (styles/kit/kit.css), need only React.
 * Adapted from kokonutui team-selector (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import type { CSSProperties } from "react";

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

/** A person as initials (or a photo) in their own chart colour. */
export function Avatar({ name, src, size }: { name: string; src?: string; size?: "sm" | "lg" }) {
  const style = { "--kit-avatar-color": avatarColor(name) } as CSSProperties;
  return (
    <span aria-label={name} className={"kit-avatar" + (size ? " kit-avatar--" + size : "")} role="img" style={style} title={name}>
      {src ? <img alt="" src={src} /> : initials(name)}
    </span>
  );
}

/** A group of people, the first few as avatars and the rest as "+N". */
export function AvatarGroup({ names, max = 4, label }: { names: string[]; max?: number; label: string }) {
  const shown = names.slice(0, max);
  const rest = names.length - shown.length;
  return (
    <div aria-label={label} className="kit-avatars" role="group">
      {shown.map((n) => (
        <Avatar key={n} name={n} />
      ))}
      {rest > 0 ? (
        <span className="kit-avatars__more" title={names.slice(max).join(", ")}>
          +{rest}
        </span>
      ) : null}
    </div>
  );
}
