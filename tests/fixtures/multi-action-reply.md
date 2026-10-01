```todo
- [ ] Create hello.ps1
- [ ] Run script and verify output
```

````write hello.ps1
Write-Output "Hello from CCBridge"

$date = Get-Date
Write-Output ("Date: " + $date)

[int[]]]$numbers = 1, 2, 3, 4, 5
$sum = ($numbers | Measure-Object -Sum).Sum

Write-Output ("Sum: " + $sum)
````

```run
powershell -NoProfile -ExecutionPolicy Bypass -File hello.ps1
```