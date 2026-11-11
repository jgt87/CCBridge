/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */

/** Two values on one slider (a number range for a filter); the values show under it. The thumbs stop at
 *  each other, and the unit ("min", "km") is shown and read out after the value. */
export function SliderRange({
  min,
  max,
  step = 1,
  value,
  onChange,
  label,
  unit,
}: {
  min: number;
  max: number;
  step?: number;
  value: [number, number];
  onChange: (value: [number, number]) => void;
  label: string;
  unit?: string;
}) {
  const lo = Math.min(value[0], value[1]);
  const hi = Math.max(value[0], value[1]);
  const span = max - min || 1;
  const said = (v: number) => v.toLocaleString() + (unit ? " " + unit : "");
  return (
    <>
      <div aria-label={label} className="kit-slider-range" role="group">
        <span className="kit-slider-range__fill" style={{ left: ((lo - min) / span) * 100 + "%", width: ((hi - lo) / span) * 100 + "%" }} />
        <input
          aria-label={"Lowest " + label}
          aria-valuetext={said(lo)}
          className="kit-slider"
          max={max}
          min={min}
          onChange={(e) => onChange([Math.min(Number(e.target.value), hi), hi])}
          step={step}
          type="range"
          value={lo}
        />
        <input
          aria-label={"Highest " + label}
          aria-valuetext={said(hi)}
          className="kit-slider"
          max={max}
          min={min}
          onChange={(e) => onChange([lo, Math.max(Number(e.target.value), lo)])}
          step={step}
          type="range"
          value={hi}
        />
      </div>
      <div aria-live="polite" className="kit-slider__value">
        {lo.toLocaleString()} - {said(hi)}
      </div>
    </>
  );
}
