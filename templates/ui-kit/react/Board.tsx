/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { type ReactNode, useRef, useState } from "react";

export interface BoardColumn {
  id: string;
  title: ReactNode;
}
export interface BoardCard {
  id: string;
  column: string;
  content: ReactNode;
}

// The place a dropped card takes: before the first card whose middle is below the pointer, counted
// among the other cards (the dragged one leaves its slot).
function dropIndex(listEl: HTMLElement, id: string, clientY: number) {
  const items = (Array.from(listEl.children) as HTMLElement[]).filter((el) => el.getAttribute("data-id") !== id);
  const index = items.findIndex((el) => el.getBoundingClientRect().top + el.offsetHeight / 2 > clientY);
  return index < 0 ? items.length : index;
}

/**
 * A board of columns with cards (kanban): drag a card, or focus it and press Alt with an arrow key
 * (left and right: the next column, up and down: the order). onMove gets the card, its new column and
 * its place there; the cards stay in the order the page gives them.
 */
export function Board({ columns, cards, onMove }: { columns: BoardColumn[]; cards: BoardCard[]; onMove: (id: string, toColumn: string, index: number) => void }) {
  const dragging = useRef<string | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const inColumn = (col: string) => cards.filter((c) => c.column === col);
  // The end of the column `by` columns away, or null at the board's edge.
  const otherColumn = (ci: number, by: number): [string, number] | null => {
    const col = columns[ci + by];
    return col ? [col.id, inColumn(col.id).length] : null;
  };
  // Where Alt+arrow moves a card (column and place), or null when it is already at that edge.
  const keyTarget = (card: BoardCard, key: string): [string, number] | null => {
    const list = inColumn(card.column);
    const i = list.findIndex((c) => c.id === card.id);
    const ci = columns.findIndex((c) => c.id === card.column);
    if (key === "ArrowUp") return i > 0 ? [card.column, i - 1] : null;
    if (key === "ArrowDown") return i < list.length - 1 ? [card.column, i + 1] : null;
    if (key === "ArrowLeft") return ci > 0 ? otherColumn(ci, -1) : null;
    if (key === "ArrowRight") return ci < columns.length - 1 ? otherColumn(ci, 1) : null;
    return null;
  };
  const keyMove = (card: BoardCard, key: string) => {
    const to = keyTarget(card, key);
    if (to) onMove(card.id, to[0], to[1]);
    return !!to;
  };
  return (
    <div className="kit-board">
      {columns.map((col) => {
        const list = inColumn(col.id);
        return (
          <section className="kit-board__column" key={col.id}>
            <h3 className="kit-board__title">
              {col.title} <span className="kit-badge">{list.length}</span>
            </h3>
            <ul
              className={"kit-board__list" + (over === col.id ? " is-over" : "")}
              data-kit-board={col.id}
              onDragLeave={(e) => {
                if (!e.currentTarget.contains(e.relatedTarget as Node)) setOver(null);
              }}
              onDragOver={(e) => {
                if (!dragging.current) return;
                e.preventDefault();
                setOver(col.id);
              }}
              onDrop={(e) => {
                e.preventDefault();
                setOver(null);
                const id = dragging.current;
                dragging.current = null;
                if (!id) return;
                onMove(id, col.id, dropIndex(e.currentTarget, id, e.clientY));
              }}
            >
              {list.map((card) => (
                <li
                  className="kit-board__card"
                  data-id={card.id}
                  draggable
                  key={card.id}
                  onDragEnd={(e) => e.currentTarget.classList.remove("is-dragging")}
                  onDragStart={(e) => {
                    dragging.current = card.id;
                    e.currentTarget.classList.add("is-dragging");
                    e.dataTransfer.setData("text/plain", card.id);
                    e.dataTransfer.effectAllowed = "move";
                  }}
                  onKeyDown={(e) => {
                    if (e.altKey && e.key.startsWith("Arrow") && keyMove(card, e.key)) e.preventDefault();
                  }}
                  tabIndex={0}
                >
                  {card.content}
                </li>
              ))}
            </ul>
          </section>
        );
      })}
    </div>
  );
}
