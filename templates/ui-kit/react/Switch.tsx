/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui switch-button (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */

/** An on/off switch with its label. */
export function Switch({ checked, onChange, label, disabled }: { checked: boolean; onChange: (checked: boolean) => void; label: string; disabled?: boolean }) {
  return (
    <label className="kit-switch">
      <input checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} role="switch" type="checkbox" />
      <span aria-hidden="true" className="kit-switch__track" />
      {label}
    </label>
  );
}
