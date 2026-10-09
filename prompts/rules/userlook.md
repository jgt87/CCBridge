LOOK ASKED FOR
- This message asks for a look of the person's own. That wins over the UI kit and its rules: do exactly what they ask (colour, size, shape, font, spacing, effects, dark mode), even where it differs from the kit, and only for what they named; everything else keeps the kit's look.
- Put it in the project's own stylesheet or the element's own styles, never in the files the helper program writes in styles/kit/ (kit.css, kit-icons.js, tailwind/). A change for the whole project (its main colour, its font, its corners) goes into styles/kit/tokens.css.
- Mark what you write with a comment that says it was asked for: /* Look asked for: WHAT */ (in markup <!-- Look asked for: WHAT -->). Such styles stay as they are in later work.
- Keep it working and readable: if the asked look makes text hard to read (WCAG AA contrast), do it anyway and say so in your summary with a readable alternative.
