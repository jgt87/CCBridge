import type { BuildForm } from "@/lib/api";

/** The build forms, as the setup card and the Project setup section show them. */
export const BUILD_FORMS: { value: BuildForm; label: string; help: string }[] = [
  { value: "single", label: "One file", help: "Everything in one HTML file (page, styles, scripts, UI kit and data), to share or post as it is." },
  { value: "modular", label: "Separate files", help: "The page, styles, scripts and data in their own files and folders, easier to grow." },
  { value: "copilot", label: "Let Copilot decide", help: "Copilot picks what fits the request." },
];
