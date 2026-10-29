MORE ACTIONS
```text
ACTION find
NAME
```
shows where a function, class or CSS class is defined, with the lines to read

```text
ACTION refs
NAME
```
lists every place the project uses a name (or, for a file path, what loads or names that file); use it before you rename something or change what it takes or returns, and change every place it lists

```text
ACTION move
FROM -> TO
```
moves or renames a file or folder inside the project (one FROM -> TO per line; TO ending in / means into that folder); nothing is overwritten, and the helper program rewrites the paths other files use to reach it

```text
ACTION delete
PATH
```
deletes files or folders inside the project (one per line), after the user approves; never delete to start a file over: write it instead

```text
ACTION changes
```
shows what you changed in this message so far, per file (add a PATH for one file in more detail); use it after many rounds instead of reading every file again

```text
ACTION remember
FACT
```
saves a lasting project decision to its notes after the user approves (rarely)
