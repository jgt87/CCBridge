/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */

/** Two values on one slider (a number range for a filter); the values show under it. */
export function SliderRange({ min, max, step = 1, value, onChange, label }: { min: number; max: number; step?: number; value: [number, number]; onChange: (value: [number, number]) => void; label: string }) {
  const lo = Math.min(value[0], value[1]);
  const hi = Math.max(value[0], value[1]);
  const span = max - min || 1;
  const set = (a: number, b: number) => onChange([Math.min(a, b), Math.max(a, b)]);
  return (
    <>
      <div aria-label={label} className="kit-slider-range" role="group">
        <span className="kit-slider-range__fill" style={{ left: ((lo - min) / span) * 100 + "%", width: ((hi - lo) / span) * 100 + "%" }} />
        <input aria-label={"Lowest " + label} className="kit-slider" max={max} min={min} onChange={(e) => set(Number(e.target.value), hi)} step={step} type="range" value={lo} />
        <input aria-label={"Highest " + label} className="kit-slider" max={max} min={min} onChange={(e) => set(lo, Number(e.target.value))} step={step} type="range" value={hi} />
      </div>
      <div aria-live="polite" className="kit-slider__value">
        {lo.toLocaleString()} - {hi.toLocaleString()}
      </div>
    </>
  );
}
