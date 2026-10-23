// The rules of the file viewer (components/ccb/file-viewer.tsx): what its body shows and where an
// image comes from.
import { isImagePath } from "./app-view";

export const isMarkdownPath = (path: string) => /\.(md|markdown)$/i.test(path);

/** What the viewer's body shows: the change set's diff, the image, rendered Markdown, or the text as code. */
export type ViewerBody = "diff" | "image" | "markdown" | "code";

export function viewerBody(path: string, hasChange: boolean, previewBase: string | undefined, source: boolean): ViewerBody {
  if (hasChange) return "diff";
  if (isImagePath(path) && previewBase) return "image";
  if (isMarkdownPath(path) && !source) return "markdown";
  return "code";
}

/** An image's address on the preview prefix, each path segment encoded. */
export const previewImageSrc = (previewBase: string, path: string) =>
  previewBase + path.split("/").map(encodeURIComponent).join("/");
