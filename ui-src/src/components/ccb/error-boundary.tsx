import { Component, type ErrorInfo, type ReactNode } from "react";
import { reportClientError } from "@/lib/api";

/**
 * Catches render errors so the page never goes blank: shows what went wrong, reports it to the
 * CCBridge log (so diagnostics include it) and offers to continue or reload.
 */
export class ErrorBoundary extends Component<{ children: ReactNode; area: string; context?: () => Record<string, unknown> }, { error: Error | null }> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    reportClientError(`Render error in ${this.props.area}: ${error.message}`, {
      stack: (error.stack ?? "").split("\n").slice(0, 6).join(" | "),
      component: (info.componentStack ?? "").split("\n").filter(Boolean).slice(0, 6).join(" | "),
      context: this.props.context?.(),
    });
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="kit-notice kit-notice--error mx-auto my-6 max-w-2xl flex-col p-4 text-sm">
        <p className="font-medium text-(--kit-error)">Something in the {this.props.area} could not be shown.</p>
        <p className="mt-1 break-words font-mono text-muted-foreground text-xs">{this.state.error.message}</p>
        <p className="mt-2 text-muted-foreground text-xs">
          The details were written to the StreamHub log; Menu, Export diagnostics includes them.
        </p>
        <div className="mt-3 flex gap-2">
          <button className="kit-btn kit-btn--sm" onClick={() => this.setState({ error: null })} type="button">
            Continue
          </button>
          <button className="kit-btn kit-btn--sm" onClick={() => location.reload()} type="button">
            Reload page
          </button>
        </div>
      </div>
    );
  }
}
