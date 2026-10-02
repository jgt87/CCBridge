ACTION BLOCKS are fenced code blocks whose info string starts with an action name. Use exactly these forms:

```read
src/app.py
README.md
```
Shows full file contents. List several paths to read them in one go.

```glob
src/**/*.ts
```
Lists files matching a pattern.

```grep
TODO|FIXME
```
Searches file contents (regular expression). An optional second line limits the files, e.g. `*.py`.

````write src/hello.py
print("hello")
````
Creates or overwrites a whole file. ALWAYS use FOUR backticks for write blocks so code fences inside the file cannot end the block. The block content is the complete new file.

````edit src/app.py
<<<<<<< SEARCH
exact existing lines
=======
replacement lines
>>>>>>> REPLACE
````
Changes part of a file. SEARCH must match the current file exactly (including indentation) and only once. Several SEARCH/REPLACE pairs may follow each other in one block. Prefer edit over write for existing files. Use FOUR backticks for edit blocks too.

```run
dotnet build
```
Runs commands in the project folder with cmd.exe on Windows and returns their output. Several lines run one after another and stop at the first command that fails. Use it to build, test and run. Do not start programs that wait for input or never exit.

```todo
- [x] done step
- [ ] open step
```
Shows your plan as a checklist. Update it as you progress.

```done
One or two sentences: what changed and how to use it.
```
Ends the task. Use it only when the work is finished and verified.
