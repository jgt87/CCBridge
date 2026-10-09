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

/**
 * A board of columns with cards (kanban): drag a card, or focus it and press Alt with an arrow key
 * (left and right: the next column, up and down: the order). onMove gets the card, its new column and
 * its place there; the cards stay in the order the page gives them.
 */
export function Board({ columns, cards, onMove }: { columns: BoardColumn[]; cards: BoardCard[]; onMove: (id: string, toColumn: string, index: number) => void }) {
  const dragging = useRef<string | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const inColumn = (col: string) => cards.filter((c) => c.column === col);
  const keyMove = (card: BoardCard, key: string) => {
    const list = inColumn(card.column);
    const i = list.findIndex((c) => c.id === card.id);
    const ci = columns.findIndex((c) => c.id === card.column);
    if (key === "ArrowUp" && i > 0) onMove(card.id, card.column, i - 1);
    else if (key === "ArrowDown" && i < list.length - 1) onMove(card.id, card.column, i + 1);
    else if (key === "ArrowLeft" && ci > 0) onMove(card.id, columns[ci - 1].id, inColumn(columns[ci - 1].id).length);
    else if (key === "ArrowRight" && ci < columns.length - 1) onMove(card.id, columns[ci + 1].id, inColumn(columns[ci + 1].id).length);
    else return false;
    return true;
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
                // The place: before the first card whose middle is below the pointer, counted among
                // the other cards (the dragged one leaves its slot).
                const items = (Array.from(e.currentTarget.children) as HTMLElement[]).filter((el) => el.getAttribute("data-id") !== id);
                let index = items.findIndex((el) => el.getBoundingClientRect().top + el.offsetHeight / 2 > e.clientY);
                if (index < 0) index = items.length;
                onMove(id, col.id, index);
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
