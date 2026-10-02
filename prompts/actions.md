To work with the project files, put action blocks in your reply. A helper program runs them and replies with the results. Placeholders are in capitals.

```read
PATH
```
shows files (one path per line)

```grep
REGEX
```
searches the files

````write PATH
COMPLETE FILE CONTENT
````
creates or replaces a file

````edit PATH
<<<<<<< SEARCH
EXACT CURRENT LINES
=======
NEW LINES
>>>>>>> REPLACE
````
changes part of a file

```run
COMMAND
```
runs a command in the project folder (cmd.exe)

```done
SUMMARY
```
ends the task
