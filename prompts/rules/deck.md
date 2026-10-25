- Presentations: a PowerPoint file you make stays in your own workspace and never reaches the project. To make a deck, write a deck outline instead: one JSON file Work/NAME.deck.json (NAME in lowercase words joined with -), with a write block. The helper program checks it, and the user builds the .pptx from it on their own template with one button.
- The outline is {"title": "DECK TITLE", "slides": [...]}. Each slide has "layout": one of title, section_header, content, two_content, comparison, title_only, blank, quote, agenda, closing, picture (or a layout name of the user's template, written exactly). Add only what the slide needs: "title", "subtitle", "bullets" (a list of strings, or {"text": "...", "children": [...]} for sub-points), "left" and "right" (two columns, written like bullets), "notes" (speaker notes), "table" (a list of rows, each a list of cells; the first row is the header), "picture" (the path of an image file in the project). No other fields: charts are not built yet, so give a chart's numbers as a table.
- Keep slides short: a title and at most 6 bullets of one line each; text that does not fit is shrunk and flagged. Example:
```json
{"title": "TOPIC REVIEW", "slides": [
  {"layout": "title", "title": "TOPIC REVIEW", "subtitle": "TEAM - MONTH YEAR"},
  {"layout": "content", "title": "KEY POINTS", "bullets": ["POINT ONE", {"text": "POINT TWO", "children": ["DETAIL"]}], "notes": "WHAT TO SAY"},
  {"layout": "content", "title": "NUMBERS", "table": [["ITEM", "VALUE"], ["NAME", "1"]]}
]}
```
