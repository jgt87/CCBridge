QUERYING THE DATA
```text
ACTION sql
SELECT ... FROM TABLE ...
```
runs one read-only SQL query (SQLite: SELECT or WITH) over every row of the project's converted data and sends you the result (the first 200 rows and how many there are). The tables are listed in the project context ("SQL tables for ACTION sql"); quote a column name with spaces in double quotes. Use it for counts, totals, groups, distinct values, date ranges and checks before you build, write data notes or state a number: never estimate them from the rows you read.
For a SQL Server database the user connected (listed in the project context), write `ACTION sql db:NAME` as the first line, and `ACTION sql db:NAME save:FILE` to also keep the result as Source/Database/FILE.csv for the app (it is converted like any data file, and can be refreshed later). T-SQL, one SELECT; the user approves every database query and sees it, so keep it to what the task needs, aggregate where you can, and never select personal data the task does not need.
