param(
    [string]$ModelBase = "8028_1_TIE_Fighter_Mini",
    [string[]]$Scenarios = @(
        "battery", "fault", "zone",
        "fault_battery", "fault_zone", "battery_zone"
    ),
    [string]$MonitorDirectory = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
$expectedOod = @{
    battery = 1; fault = 1; zone = 1
    fault_battery = 2; fault_zone = 2; battery_zone = 2
}

function Short-Id([object]$value) {
    if ($null -eq $value) { return "" }
    $match = [regex]::Match([string]$value, "\((\d+)\)$")
    if ($match.Success) { return "R$($match.Groups[1].Value)" }
    return [string]$value
}

$results = foreach ($scenario in $Scenarios) {
    $errors = [System.Collections.Generic.List[string]]::new()
    $stream = Join-Path $MonitorDirectory "streams\${ModelBase}__${scenario}.jsonl"
    $animation = Join-Path $MonitorDirectory "anim\${ModelBase}__${scenario}.html"

    if (-not (Test-Path -LiteralPath $stream)) {
        $errors.Add("missing stream")
        $frame = $null
    } else {
        try {
            $frame = Get-Content -LiteralPath $stream -Tail 1 | ConvertFrom-Json
        } catch {
            $errors.Add("invalid final JSON frame")
            $frame = $null
        }
    }

    if (-not (Test-Path -LiteralPath $animation)) {
        $errors.Add("missing animation")
    } elseif ((Get-Item -LiteralPath $animation).Length -lt 100000) {
        $errors.Add("animation is unexpectedly small")
    }

    if ($null -ne $frame) {
        $assemblies = @($frame.assemblies)
        $done = @($assemblies | Where-Object status -eq "done").Count
        if ($assemblies.Count -eq 0 -or $done -ne $assemblies.Count) {
            $errors.Add("assembly incomplete: $done/$($assemblies.Count)")
        }

        $ood = @($frame.ood)
        $history = @($frame.respec_history)
        $expected = $expectedOod[$scenario]
        if ($ood.Count -ne $expected) {
            $errors.Add("OOD count $($ood.Count), expected $expected")
        }
        if ($history.Count -ne $expected) {
            $errors.Add("respec count $($history.Count), expected $expected")
        }

        $robots = @($frame.robots)
        foreach ($robot in $robots) {
            if ($null -ne $robot.soc -and
                (([double]::IsNaN([double]$robot.soc) -or
                  [double]::IsInfinity([double]$robot.soc)) -or
                 [double]$robot.soc -lt 0.0 -or [double]$robot.soc -gt 1.000001)) {
                $errors.Add("invalid SoC for $(Short-Id $robot.id): $($robot.soc)")
            }
        }

        foreach ($handoff in @($frame.handoffs)) {
            $failed = [string]$handoff.failed
            $spare = [string]$handoff.spare
            $at = [double]$handoff.at
            $lateFailed = @($frame.schedule | Where-Object {
                [string]$_.robot -eq $failed -and [double]$_.t1 -gt $at + 1.0e-9
            })
            $crossingSpare = @($frame.schedule | Where-Object {
                [string]$_.robot -eq $spare -and
                [double]$_.t0 -lt $at - 1.0e-9 -and
                [double]$_.t1 -gt $at + 1.0e-9
            })
            if ($lateFailed.Count) {
                $errors.Add("failed $(Short-Id $failed) works after handoff")
            }
            if ($crossingSpare.Count) {
                $errors.Add("spare $(Short-Id $spare) has an obsolete lane crossing handoff")
            }
            if (-not @($robots | Where-Object {
                $_.retired -and [string]$_.id -eq $failed
            }).Count) {
                $errors.Add("missing retired row for $(Short-Id $failed)")
            }
            if (-not @($robots | Where-Object {
                (-not $_.retired) -and
                [string]$_.id -eq $spare -and
                [string]$_.replacement_for -eq $failed
            }).Count) {
                $errors.Add("missing replacement row $(Short-Id $spare)")
            }
        }

        foreach ($event in @($ood | Where-Object kind -eq "battery")) {
            $target = [string]$event.target
            if ([double]$event.soc_after -gt 0.101) {
                $errors.Add("battery event SoC is not critical: $($event.soc_after)")
            }
            $retired = @($robots | Where-Object {
                $_.retired -and [string]$_.id -eq $target
            })
            if ($retired.Count -ne 1 -or
                [string]$retired[0].mode -ne "DEPLETED" -or
                [double]$retired[0].soc -gt 0.101) {
                $errors.Add("depleted fleet row does not preserve event SoC")
            }
        }
    }

    [pscustomobject]@{
        Scenario = $scenario
        Assembly = if ($null -eq $frame) { "-" } else {
            "$(@($frame.assemblies | Where-Object status -eq 'done').Count)/$(@($frame.assemblies).Count)"
        }
        OOD = if ($null -eq $frame) { "-" } else { @($frame.ood).Count }
        Handoffs = if ($null -eq $frame) { "-" } else { @($frame.handoffs).Count }
        AnimationMB = if (Test-Path -LiteralPath $animation) {
            [math]::Round((Get-Item -LiteralPath $animation).Length / 1MB, 2)
        } else { 0 }
        Pass = $errors.Count -eq 0
        Detail = $errors -join "; "
    }
}

$results | Format-Table -AutoSize -Wrap
if (@($results | Where-Object { -not $_.Pass }).Count) {
    exit 1
}
