import { useMemo } from "react";
import { browserHasFont, cssColour, fontFamily, parseDrawing, textLayout } from "./pptx-drawing-view";

/** One option's preview: the description from lib/PptxChoices.psm1 drawn as SVG (scaled to fit its box). */
export function PptxDrawing({ json, label, className }: { json: string; label: string; className?: string }) {
  const d = useMemo(() => parseDrawing(json), [json]);
  if (!d) return <div className="flex h-12 items-center justify-center text-muted-foreground text-xs">No preview</div>;
  const family = (f: string) => fontFamily(f, browserHasFont);
  return (
    <svg aria-label={label} className={className} preserveAspectRatio="xMidYMid meet" role="img" viewBox={`-2 -2 ${d.w + 4} ${d.h + 4}`}>
      <rect fill={cssColour(d.bg, "#ffffff")} height={d.h + 4} width={d.w + 4} x={-2} y={-2} />
      {d.items.map((it, i) => {
        const stroke = cssColour(it.line);
        const common = { fill: cssColour(it.fill), stroke, strokeWidth: stroke === "none" ? 0 : Math.max(0.5, it.lineW) };
        const t = textLayout(it, family);
        return (
          <g key={i}>
            {it.type === "ellipse" ? (
              <ellipse cx={it.x + it.w / 2} cy={it.y + it.h / 2} rx={it.w / 2} ry={it.h / 2} {...common} />
            ) : it.type !== "text" ? (
              <rect height={it.h} rx={it.type === "roundRect" ? Math.min(it.radius, it.w / 2, it.h / 2) : 0} width={it.w} x={it.x} y={it.y} {...common} />
            ) : null}
            {t && (
              <text fill={t.fill} fontFamily={t.font} fontSize={t.size} fontWeight={t.bold ? 700 : 400} textAnchor={t.anchor}>
                {t.lines.map((l, j) => (
                  <tspan dy={j === 0 ? 0 : t.size * 1.2} key={j} x={t.x} y={j === 0 ? t.y : undefined}>
                    {l}
                  </tspan>
                ))}
              </text>
            )}
          </g>
        );
      })}
    </svg>
  );
}
