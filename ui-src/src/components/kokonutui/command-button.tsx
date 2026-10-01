import { Command } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * @author: @dorianbaffier
 * @description: Command Button
 * @version: 1.0.0
 * @date: 2025-06-26
 * @license: MIT
 * @website: https://kokonutui.com
 * @github: https://github.com/kokonut-labs/kokonutui
 */

export default function CommandButton({
  className,
  children,
  icon: Icon = Command,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & {
  children?: React.ReactNode;
  /** CCBridge: icon shown instead of the Command glyph. */
  icon?: React.ComponentType<{ className?: string }>;
}) {
  return (
    <Button
      {...props}
      className={cn(
        // CCBridge: flat design (no gradient, border or shimmer).
        "relative px-3 py-2",
        "rounded-md shadow-none",
        "bg-black/5 hover:bg-black/10 dark:bg-white/10 dark:hover:bg-white/15",
        "transition-colors duration-150",
        "group",
        "inline-flex items-center justify-center",
        "gap-2",
        className
      )}
    >
      <Icon
        className={cn(
          "h-4 w-4",
          "text-foreground/80",
          "transition-colors"
        )}
      />
      <span className="text-foreground/80 text-sm">
        {children || "CMD + K"}
      </span>
    </Button>
  );
}
