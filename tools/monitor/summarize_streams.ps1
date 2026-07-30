param(
    [string]$ModelPattern = "*TIE_Fighter_Mini*",
    [string]$StreamDirectory = (Join-Path $PSScriptRoot "streams")
)

$ErrorActionPreference = "Stop"
$expectedOod = @{
    none = 0; battery = 1; fault = 1; zone = 1
    fault_battery = 2; fault_zone = 2; battery_zone = 2
}

$rows = foreach ($file in Get-ChildItem -LiteralPath $StreamDirectory -Filter "$ModelPattern.jsonl") {
    $lastLine = Get-Content -LiteralPath $file.FullName -Tail 1
    if (-not $lastLine) {
        continue
    }

    $frame = $lastLine | ConvertFrom-Json
    $assemblies = @($frame.assemblies)
    $robots = @($frame.robots)
    $ood = @($frame.ood)
    $history = @($frame.respec_history)

    $done = @($assemblies | Where-Object status -eq "done").Count
    $depleted = @($robots | Where-Object {
        $_.depleted -or $_.mode -eq "DEPLETED" -or $_.soc -le 0.101
    }).Count
    $faulted = @($robots | Where-Object mode -eq "FAULT").Count

    $scenario = $file.BaseName -replace "^.*__", ""
    $expected = if ($expectedOod.ContainsKey($scenario)) {
        $expectedOod[$scenario]
    } else {
        $ood.Count
    }

    [pscustomobject]@{
        Scenario = $scenario
        Complete = "$done/$($assemblies.Count)"
        OOD = $ood.Count
        Respec = $history.Count
        Depleted = $depleted
        Faulted = $faulted
        FinalStep = $frame.t
        Pass = (
            $assemblies.Count -gt 0 -and
            $done -eq $assemblies.Count -and
            $ood.Count -eq $expected -and
            $history.Count -eq $expected
        )
    }
}

$rows | Sort-Object Scenario | Format-Table -AutoSize

if (@($rows).Count -eq 0) {
    throw "No streams matched '$ModelPattern.jsonl' in $StreamDirectory"
}
if (@($rows | Where-Object { -not $_.Pass }).Count -gt 0) {
    exit 1
}
