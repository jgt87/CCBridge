LOOK ASKED FOR
- This message asks to change how something looks. Work in this order, per element the person named:
  1. Find the element in the UI kit: its kit class or part, a variant (such as --primary, --ghost, --sm), an option of the part (a chart's options, a table's attributes) or a token in styles/kit/tokens.css. If the element is not built with the kit yet and the kit has that part, rebuild it with the kit part first.
  2. If the kit offers what is asked (a variant, a size, an option, a layout class, a token value), use that: the kit's own way, so the element keeps working with the rest of the kit.
  3. If the element already uses the kit and the request goes beyond what the kit offers, do exactly what the person asks, even where it differs from the kit's defaults, and only for what they named; everything else keeps the kit's look.
- Say in your summary per element which of the three you did (kit part applied, kit option or token used, or the kit's default overruled as asked).
- Put an overruling look in the project's own stylesheet or the element's own styles, never in the files the helper program writes in styles/kit/ (kit.css, kit-icons.js, tailwind/). A change for the whole project (its main colour, its font, its corners) goes into styles/kit/tokens.css.
- Mark an overruling look with a comment that says it was asked for: /* Look asked for: WHAT */ (in markup <!-- Look asked for: WHAT -->). Such styles stay as they are in later work.
- Keep it working and readable: if the asked look makes text hard to read (WCAG AA contrast), do it anyway and say so in your summary with a readable alternative.
