RUNNING COMMANDS
```text
ACTION run
COMMAND
```
runs a command in the project folder (cmd.exe, no terminal: use non-interactive forms) and sends you its output. Never run commands that send email, change calendars or delete data. Delete or move files only inside the project folder, named as plain relative paths. Keep commands short; for more, write a script file (see the folder rules) and run it with powershell -NoProfile -ExecutionPolicy Bypass -File PATH. Never run syntax checks (node --check, py_compile): the helper program checks every changed file itself and sends you the errors.
