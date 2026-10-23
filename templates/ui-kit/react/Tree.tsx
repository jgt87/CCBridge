/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { type KeyboardEvent, type ReactNode, useRef, useState } from "react";

export interface TreeNode {
  value: string;
  label: ReactNode;
  icon?: ReactNode;
  children?: TreeNode[];
}

/** A hierarchy (folders, an organisation): toggles on branches, the arrow keys move and open or close, Enter or Space picks. */
export function Tree({ nodes, label, selected, onSelect, defaultOpen = [] }: { nodes: TreeNode[]; label: string; selected?: string; onSelect: (value: string) => void; defaultOpen?: string[] }) {
  const [open, setOpen] = useState<Set<string>>(() => new Set(defaultOpen));
  const [current, setCurrent] = useState<string | undefined>(selected ?? nodes[0]?.value);
  const root = useRef<HTMLUListElement>(null);
  const toggle = (value: string, to?: boolean) =>
    setOpen((s) => {
      const n = new Set(s);
      const want = to ?? !n.has(value);
      if (want) n.add(value);
      else n.delete(value);
      return n;
    });
  // The rows a person can reach: not inside a closed branch.
  const rows = () => Array.from(root.current?.querySelectorAll<HTMLDivElement>(".kit-tree__row") ?? []).filter((r) => !r.closest("li[aria-expanded='false'] ul"));
  const focusRow = (r?: HTMLDivElement) => {
    if (!r) return;
    setCurrent(r.parentElement?.getAttribute("data-value") ?? undefined);
    r.focus();
  };
  const parentRow = (parent: TreeNode) => root.current?.querySelector<HTMLDivElement>(`li[data-value="${parent.value}"] > .kit-tree__row`) ?? undefined;
  // What each key does on a row; other keys are left to the browser.
  const onKey = (e: KeyboardEvent<HTMLDivElement>, node: TreeNode, parent?: TreeNode) => {
    const list = rows();
    const i = list.indexOf(e.currentTarget);
    const branch = !!node.children?.length;
    const isOpen = open.has(node.value);
    const pick = () => onSelect(node.value);
    const keys: Record<string, () => void> = {
      ArrowDown: () => focusRow(list[i + 1]),
      ArrowUp: () => focusRow(list[i - 1]),
      Home: () => focusRow(list[0]),
      End: () => focusRow(list[list.length - 1]),
      // Right opens a closed branch, then goes into it.
      ArrowRight: () => {
        if (branch && !isOpen) toggle(node.value, true);
        else if (branch) focusRow(list[i + 1]);
      },
      // Left closes an open branch, else goes up to the parent.
      ArrowLeft: () => {
        if (branch && isOpen) toggle(node.value, false);
        else if (parent) focusRow(parentRow(parent));
      },
      Enter: pick,
      " ": pick,
    };
    const act = Object.prototype.hasOwnProperty.call(keys, e.key) ? keys[e.key] : undefined;
    if (!act) return;
    act();
    e.preventDefault();
  };
  const render = (list: TreeNode[], parent?: TreeNode) =>
    list.map((n) => {
      const branch = !!n.children?.length;
      const isOpen = open.has(n.value);
      return (
        <li aria-expanded={branch ? isOpen : undefined} aria-selected={selected === n.value ? true : undefined} data-value={n.value} key={n.value} role="treeitem">
          <div
            className="kit-tree__row"
            onClick={() => {
              setCurrent(n.value);
              onSelect(n.value);
            }}
            onKeyDown={(e) => onKey(e, n, parent)}
            tabIndex={current === n.value ? 0 : -1}
          >
            {branch ? (
              <button
                aria-label="Open or close"
                className="kit-tree__toggle"
                onClick={(e) => {
                  e.stopPropagation();
                  toggle(n.value);
                }}
                tabIndex={-1}
                type="button"
              />
            ) : (
              <span aria-hidden="true" className="kit-tree__spacer" />
            )}
            {n.icon}
            {n.label}
          </div>
          {branch ? <ul role="group">{render(n.children!, n)}</ul> : null}
        </li>
      );
    });
  return (
    <ul aria-label={label} className="kit-tree" ref={root} role="tree">
      {render(nodes)}
    </ul>
  );
}
