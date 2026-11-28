/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from an open-source component library (MIT licence; see ../LICENSE-kokonutui.txt).
 */

/**
 * An on/off switch with its label. disabled keeps it focusable (aria-disabled): it looks unavailable and
 * a click, Space or a press on its label leaves it as it is; busy (aria-busy) does the same while it saves.
 */
export function Switch({ checked, onChange, label, disabled, busy }: { checked: boolean; onChange: (checked: boolean) => void; label: string; disabled?: boolean; busy?: boolean }) {
  const off = !!disabled || !!busy;
  return (
    <label className="kit-switch">
      <input
        aria-busy={busy || undefined}
        aria-disabled={disabled || undefined}
        checked={checked}
        // Controlled: while off the change is not passed on, so React puts the box back as it was (no
        // preventDefault on the click: on a controlled checkbox that flips it out of step with React).
        onChange={(e) => {
          if (!off) onChange(e.target.checked);
        }}
        role="switch"
        type="checkbox"
      />
      <span aria-hidden="true" className="kit-switch__track" />
      {label}
    </label>
  );
}
