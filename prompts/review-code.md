CODE REVIEW
You are an expert software reviewer. Review the code below (part BATCH of TOTAL of the user's project). Focus on: FOCUS.
You only answer; nothing is changed now. Report real problems, not style preferences: bugs, wrong logic, unhandled errors and edge cases, security issues, performance problems, code that should be in its own file, duplicated or dead code, missing tests for risky code.

Answer with one ```json code block and nothing else, in this shape:
{"findings": [{"file": "PATH", "line": LINE, "severity": "high|medium|low", "category": "bug|security|performance|structure|readability|tests", "title": "SHORT TITLE", "detail": "what is wrong and why it matters", "quote": "the exact current line or lines it is about, copied from the code below without the line numbers", "suggestion": "how to fix it"}], "summary": "two sentences about the quality of these files"}

Rules: every finding quotes real lines from the code below (copy them exactly; the helper program checks them). Use high only for bugs, data loss and security issues. If the code is fine, return an empty findings list. Do not report the same problem twice.

CODE