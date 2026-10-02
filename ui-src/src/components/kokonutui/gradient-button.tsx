import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

type ColorVariant = "neutral" | "subtle" | "emerald" | "purple" | "orange";

interface GradientColors {
  dark: {
    border: string;
    overlay: string;
    accent: string;
    text: string;
    glow: string;
    textGlow: string;
    hover: string;
  };
  light: {
    border: string;
    base: string;
    overlay: string;
    accent: string;
    text: string;
    glow: string;
    hover: string;
  };
}

interface GradientButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  icon?: string;
  label?: string;
  className?: string;
  variant?: ColorVariant;
}

const gradientColors: Record<Exclude<ColorVariant, "subtle">, GradientColors> = {
  // CCBridge: monochrome white/grey variant used throughout the app.
  neutral: {
    dark: {
      border: "from-[#71717A] via-[#141414] to-[#52525B]",
      overlay: "from-[#A1A1AA]/20 via-[#141414] to-[#52525B]/20",
      accent: "from-white/10 via-[#141414] to-[#27272A]/50",
      text: "from-white to-zinc-300",
      glow: "rgba(255,255,255,0.08)",
      textGlow: "rgba(255,255,255,0.25)",
      hover: "from-[#27272A]/20 via-white/10 to-[#27272A]/20",
    },
    light: {
      border: "from-zinc-400 via-zinc-300 to-zinc-200",
      base: "from-zinc-50 via-zinc-50/80 to-zinc-50/90",
      overlay: "from-zinc-300/30 via-zinc-200/20 to-zinc-400/20",
      accent: "from-zinc-400/20 via-zinc-300/10 to-zinc-200/30",
      text: "from-zinc-900 to-zinc-700",
      glow: "rgba(113,113,122,0.2)",
      hover: "from-zinc-300/30 via-zinc-200/20 to-zinc-300/30",
    },
  },
  emerald: {
    dark: {
      border: "from-[#336C4F] via-[#0C1F21] to-[#0D6437]",
      overlay: "from-[#347B52]/40 via-[#0C1F21] to-[#0D6437]/30",
      accent: "from-[#87F6B7]/10 via-[#0C1F21] to-[#17362A]/50",
      text: "from-[#8AEECA] to-[#73F8A8]",
      glow: "rgba(135,246,183,0.1)",
      textGlow: "rgba(135,246,183,0.4)",
      hover: "from-[#17362A]/20 via-[#87F6B7]/10 to-[#17362A]/20",
    },
    light: {
      border: "from-emerald-400 via-emerald-300 to-emerald-200",
      base: "from-emerald-50 via-emerald-50/80 to-emerald-50/90",
      overlay: "from-emerald-300/30 via-emerald-200/20 to-emerald-400/20",
      accent: "from-emerald-400/20 via-emerald-300/10 to-emerald-200/30",
      text: "from-emerald-700 to-emerald-600",
      glow: "rgba(52,211,153,0.2)",
      hover: "from-emerald-300/30 via-emerald-200/20 to-emerald-300/30",
    },
  },
  purple: {
    dark: {
      border: "from-[#6B46C1] via-[#0C1F21] to-[#553C9A]",
      overlay: "from-[#7E22CE]/40 via-[#0C1F21] to-[#6B46C1]/30",
      accent: "from-[#E9D8FD]/10 via-[#0C1F21] to-[#44337A]/50",
      text: "from-[#E9D8FD] to-[#D6BCFA]",
      glow: "rgba(159,122,234,0.1)",
      textGlow: "rgba(159,122,234,0.4)",
      hover: "from-[#44337A]/20 via-[#B794F4]/10 to-[#44337A]/20",
    },
    light: {
      border: "from-purple-400 via-purple-300 to-purple-200",
      base: "from-purple-50 via-purple-50/80 to-purple-50/90",
      overlay: "from-purple-300/30 via-purple-200/20 to-purple-400/20",
      accent: "from-purple-400/20 via-purple-300/10 to-purple-200/30",
      text: "from-purple-700 to-purple-600",
      glow: "rgba(159,122,234,0.2)",
      hover: "from-purple-300/30 via-purple-200/20 to-purple-300/30",
    },
  },
  orange: {
    dark: {
      border: "from-[#C05621] via-[#0C1F21] to-[#9C4221]",
      overlay: "from-[#DD6B20]/40 via-[#0C1F21] to-[#C05621]/30",
      accent: "from-[#FED7AA]/10 via-[#0C1F21] to-[#7B341E]/50",
      text: "from-[#FED7AA] to-[#FBD38D]",
      glow: "rgba(237,137,54,0.1)",
      textGlow: "rgba(237,137,54,0.4)",
      hover: "from-[#7B341E]/20 via-[#ED8936]/10 to-[#7B341E]/20",
    },
    light: {
      border: "from-orange-400 via-orange-300 to-orange-200",
      base: "from-orange-50 via-orange-50/80 to-orange-50/90",
      overlay: "from-orange-300/30 via-orange-200/20 to-orange-400/20",
      accent: "from-orange-400/20 via-orange-300/10 to-orange-200/30",
      text: "from-orange-700 to-orange-600",
      glow: "rgba(237,137,54,0.2)",
      hover: "from-orange-300/30 via-orange-200/20 to-orange-300/30",
    },
  },
};

export default function GradientButton({
  label = "Welcome",
  className,
  variant = "neutral",
  ...props
}: GradientButtonProps) {
  // CCBridge: flat design. "neutral" is a solid primary button, "subtle" a flat secondary one;
  // the layered gradient rendering below is kept for the original colour variants.
  if (variant === "neutral" || variant === "subtle") {
    return (
      <Button
        className={cn(
          "h-10 rounded-md px-4 font-medium text-sm shadow-none transition-colors disabled:opacity-40",
          variant === "neutral"
            ? "bg-foreground text-background hover:bg-foreground/85 hover:text-background"
            : "bg-black/5 text-foreground hover:bg-black/10 hover:text-foreground dark:bg-white/10 dark:hover:bg-white/15",
          className
        )}
        variant="ghost"
        {...props}
      >
        {label}
      </Button>
    );
  }

  const colors = gradientColors[variant];

  return (
    <Button
      className={cn(
        "group relative h-12 overflow-hidden rounded-lg px-4 transition-all duration-500",
        className
      )}
      variant="ghost"
      {...props}
    >
      <div
        className={cn(
          "absolute inset-0 rounded-lg bg-linear-to-b p-[2px]",
          "dark:bg-none",
          colors.light.border,
          colors.dark.border
        )}
      >
        <div
          className={cn(
            "absolute inset-0 rounded-lg opacity-90",
            "bg-white/80",
            "dark:bg-[#141414]"
          )}
        />
      </div>

      <div
        className={cn(
          "absolute inset-[2px] rounded-lg opacity-95",
          "bg-white/80",
          "dark:bg-[#141414]"
        )}
      />

      <div
        className={cn(
          "absolute inset-[2px] rounded-lg bg-linear-to-r opacity-90",
          colors.light.base,
          "dark:from-[#141414] dark:via-[#141414] dark:to-[#141414]"
        )}
      />
      <div
        className={cn(
          "absolute inset-[2px] rounded-lg bg-linear-to-b opacity-80",
          colors.light.overlay,
          colors.dark.overlay
        )}
      />
      <div
        className={cn(
          "absolute inset-[2px] rounded-lg bg-linear-to-br",
          colors.light.accent,
          colors.dark.accent
        )}
      />

      <div
        className={cn(
          "absolute inset-[2px] rounded-lg",
          `shadow-[inset_0_0_10px_${colors.light.glow}]`,
          `dark:shadow-[inset_0_0_10px_${colors.dark.glow}]`
        )}
      />

      <div className="relative flex items-center justify-center gap-2">
        <span
          className={cn(
            "bg-linear-to-b bg-clip-text font-medium text-sm text-transparent tracking-tight",
            colors.light.text,
            colors.dark.text,
            `dark:drop-shadow-[0_0_12px_${colors.dark.textGlow}]`
          )}
        >
          {label}
        </span>
      </div>

      <div
        className={cn(
          "absolute inset-[2px] rounded-lg bg-linear-to-r opacity-0 transition-opacity duration-300 group-hover:opacity-100",
          colors.light.hover,
          colors.dark.hover
        )}
      />
    </Button>
  );
}
