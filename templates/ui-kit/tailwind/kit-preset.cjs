/* UI kit for Tailwind CSS 3, written by the helper program: do not edit (change the values in
   styles/kit/tokens.css). In tailwind.config: presets: [require("./styles/kit/tailwind/kit-preset.cjs")],
   and load styles/kit/tokens.css and styles/kit/kit.css in the page. The kit's tokens become Tailwind
   names: bg-kit-accent, text-kit-muted, border-kit-border, bg-kit-chart-1, rounded-kit, shadow-kit,
   font-kit, p-kit-4, gap-kit-3, text-kit-sm ... They follow the project's colour preset and its light
   and dark values; Tailwind's own colours (bg-blue-500) and made-up values (bg-[#123456]) do not. */
const v = (name) => "var(--kit-" + name + ")";
const space = {};
for (let i = 1; i <= 7; i++) space["kit-" + i] = v("space-" + i);

module.exports = {
  theme: {
    extend: {
      colors: {
        kit: {
          bg: v("bg"), surface: v("surface"), "surface-2": v("surface-2"), text: v("text"), muted: v("text-muted"),
          border: v("border"), "border-strong": v("border-strong"),
          accent: v("accent"), "accent-hover": v("accent-hover"), "accent-soft": v("accent-soft"), "accent-2": v("accent-2"), "on-accent": v("on-accent"),
          ok: v("ok"), "ok-soft": v("ok-soft"), warn: v("warn"), "warn-soft": v("warn-soft"), error: v("error"), "error-soft": v("error-soft"),
          "chart-1": v("chart-1"), "chart-2": v("chart-2"), "chart-3": v("chart-3"), "chart-4": v("chart-4"), "chart-5": v("chart-5"), "chart-6": v("chart-6"),
        },
      },
      borderRadius: { kit: v("radius"), "kit-lg": v("radius-lg") },
      boxShadow: { kit: v("shadow") },
      fontFamily: { kit: [v("font")], "kit-mono": [v("font-mono")] },
      spacing: space,
      fontSize: { "kit-xs": v("text-xs"), "kit-sm": v("text-sm"), "kit-md": v("text-md"), "kit-lg": v("text-lg"), "kit-xl": v("text-xl") },
    },
  },
};
