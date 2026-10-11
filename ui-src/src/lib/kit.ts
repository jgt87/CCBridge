/**
 * The UI kit's classes as StreamHub uses them (templates/ui-kit/kit.css, with the app's colours from
 * styles/kit-tokens.css). One place for the common shapes, so every panel draws its buttons, fields,
 * boxes and notes the same way; Tailwind utilities on the same element still win (the kit sits in the
 * components layer), so a width or margin can be added next to these.
 */
export const kit = {
  /** A small bordered button (the app's size: 30 px tall, 12 px text). */
  btn: "kit-btn kit-btn--sm",
  /** A button without a border until hovered: row actions, "Run", "View". */
  ghost: "kit-btn kit-btn--ghost kit-btn--sm",
  /** An icon-only button (give it aria-label or title). */
  icon: "kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm",
  /** A bordered icon-only button. */
  iconBordered: "kit-btn kit-btn--icon kit-btn--sm",
  /** The one action that deletes or stops. */
  danger: "kit-btn kit-btn--danger kit-btn--sm",
  /** A full-size button (36 px): the main actions of a card or dialog. */
  btnLg: "kit-btn",
  input: "kit-input",
  select: "kit-select",
  textarea: "kit-textarea",
  check: "kit-check",
  label: "kit-label",
  help: "kit-help",
  error: "kit-error-text",
  /** A box with a border and the surface colour (cards in the side panel, in the chat). */
  panel: "kit-panel",
  /** A pill with a count or a short status word. */
  badge: "kit-badge",
  badgeOk: "kit-badge kit-badge--ok",
  badgeError: "kit-badge kit-badge--error",
  /** A note the reader should see: grey by default, rose for an error. */
  notice: "kit-notice",
  noticeError: "kit-notice kit-notice--error",
  noticeOk: "kit-notice kit-notice--ok",
  /** Nothing to show yet. */
  empty: "kit-empty",
  emptyTitle: "kit-empty__title",
  /** A dialog's box (over the app's backdrop) and its button row. */
  dialog: "kit-dialog",
  dialogActions: "kit-dialog__actions",
  /** A small panel of content from a button, or the box under an info button. */
  popover: "kit-popover",
  /** Lists of rows with a title, a second line and actions. */
  list: "kit-list",
  listItem: "kit-list__item",
  listBody: "kit-list__body",
  listTitle: "kit-list__title",
  listMeta: "kit-list__meta",
  listActions: "kit-list__actions",
  /** A kit-table in its wrapper. */
  tableWrap: "kit-table-wrap",
  table: "kit-table",
  /** A thin bar that fills to a share. */
  progress: "kit-progress",
  progressBar: "kit-progress__bar",
  kbd: "kit-kbd",
  spinner: "kit-spinner",
  code: "kit-code",
  truncate: "kit-truncate",
  dot: "kit-dot",
  tree: "kit-tree",
  treeRow: "kit-tree__row",
} as const;
