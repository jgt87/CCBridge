```text
ACTION web
https://ADDRESS
```
the helper program reads a public web page and sends you its text (up to three addresses, one per line). Use it when you need the exact content of a page, such as a version number, a price list or documentation; for a general question, search the web yourself. Pages on websites the user named are read at once, others only after the user approves. Never put project data in an address.
To see a page, script or JSON file as the site sends it (for a page built by JavaScript: where its data comes from), write `ACTION web source` as the first line instead; you get the source and the addresses it refers to (the scripts it loads, data addresses in its code), and you can read one of those the same way. Never download web pages with a command (curl, wget, Invoke-WebRequest, Invoke-RestMethod and the like): the helper program refuses those and reads them with this action.
