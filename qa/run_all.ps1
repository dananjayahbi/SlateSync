# qa/run_all.ps1 — Doc 28 §4 run_all: no required parameters.
# Frozen step order: (1) pytest pc_agent/tests -> (2) flutter analyze ->
# (3) flutter test (cwd mobile_app) -> (4) qa\latency_probe.py ->
# (5) qa\export_verify.py -> (6) memory benchmark iff `flutter devices`
# reports an attached Android device, else SKIP (never FAIL).
# Output: UTF-8 table STEP | RESULT (PASS/FAIL/SKIP) | SECONDS | DETAIL,
# then "TOTAL: n FAILED". Exit code = number of FAILed steps (Doc 28 §5).

$ErrorActionPreference = 'Continue'
$env:PYTHONUTF8 = '1'

$repoRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $repoRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    Write-Host "warning: .venv python not found at $venvPython; falling back to PATH python"
    $venvPython = 'python'
}
$mobileApp = Join-Path $repoRoot 'mobile_app'
$flutterCmd = (Get-Command flutter -ErrorAction SilentlyContinue).Source
# Probe boots its OWN in-process server whose token_provider echoes this token;
# session_token.txt (Doc 12 file fallback) is only read when --token is absent.
$probeToken = 'qa-runall-' + [guid]::NewGuid().ToString('N').Substring(0, 12)

$steps = @(
    [pscustomobject]@{ Name = 'pytest pc_agent/tests'; Exe = $venvPython; Args = @('-m', 'pytest', 'pc_agent/tests', '-q'); Cwd = $repoRoot },
    # flutter is a .bat shim: route through cmd /c so Start-Process is reliable
    [pscustomobject]@{ Name = 'flutter analyze';       Exe = 'cmd';       Args = @('/c', 'flutter', 'analyze');                   Cwd = $mobileApp },
    [pscustomobject]@{ Name = 'flutter test';          Exe = 'cmd';       Args = @('/c', 'flutter', 'test');                      Cwd = $mobileApp },
    [pscustomobject]@{ Name = 'latency_probe.py';      Exe = $venvPython; Args = @('qa\latency_probe.py', '--token', $probeToken); Cwd = $repoRoot },
    [pscustomobject]@{ Name = 'export_verify.py';      Exe = $venvPython; Args = @('qa\export_verify.py');                       Cwd = $repoRoot }
)

function Invoke-Step {
    param([string]$Exe, [string[]]$ArgList, [string]$Cwd)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList $ArgList `
            -WorkingDirectory $Cwd -Wait -PassThru -NoNewWindow
        $sw.Stop()
        return @{ Code = $proc.ExitCode; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Err = '' }
    } catch {
        $sw.Stop()
        return @{ Code = -1; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Err = $_.Exception.Message }
    }
}

$rows = New-Object System.Collections.ArrayList

foreach ($step in $steps) {
    $r = Invoke-Step -Exe $step.Exe -ArgList $step.Args -Cwd $step.Cwd
    $result = if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }
    $detail = if ($r.Err) { "start failed: $($r.Err)" } else { "exit code $($r.Code)" }
    [void]$rows.Add([pscustomobject]@{ Step = $step.Name; Result = $result; Seconds = $r.Sec; Detail = $detail })
}

# Step 6 device gate (Doc 28 §5 step 3): memory benchmark iff an Android
# device is attached, else SKIP — never FAIL.
$deviceDetail = 'no Android device attached (flutter devices)'
$androidNames = @()
$sw6 = [System.Diagnostics.Stopwatch]::StartNew()
if ($flutterCmd) {
    try {
        $jsonText = (& $flutterCmd devices --machine 2>$null | Out-String)
        $start = $jsonText.IndexOf('[')
        $end = $jsonText.LastIndexOf(']')
        if ($start -ge 0 -and $end -gt $start) {
            $devices = $jsonText.Substring($start, $end - $start + 1) | ConvertFrom-Json
            foreach ($d in $devices) {
                $tp = [string]$d.targetPlatform
                $id = [string]$d.id
                $plat = [string]$d.platform
                if ($tp -like 'android*' -or $plat -eq 'android' -or $id -like '*android*') {
                    $androidNames += ([string]$d.name)
                }
            }
        }
    } catch {
        $deviceDetail = "flutter devices parse failed: $($_.Exception.Message)"
    }
} else {
    $deviceDetail = 'flutter not found on PATH'
}
if ($androidNames.Count -gt 0) {
    # Android device attached: the Doc 28 §5 memory benchmark (fixture load +
    # 60 s DevTools pan/zoom sweep + heap/frame snapshots) is an interactive
    # DevTools procedure; this script cannot take snapshots headlessly.
    $r6 = @{ Sec = [math]::Round($sw6.Elapsed.TotalSeconds, 1) }
    [void]$rows.Add([pscustomobject]@{
        Step    = 'memory benchmark'
        Result  = 'SKIP'
        Seconds = $r6.Sec
        Detail  = "device(s): $($androidNames -join ', ') - run Doc 28 §5 DevTools procedure manually"
    })
} else {
    $r6 = @{ Sec = [math]::Round($sw6.Elapsed.TotalSeconds, 1) }
    [void]$rows.Add([pscustomobject]@{
        Step    = 'memory benchmark'
        Result  = 'SKIP'
        Seconds = $r6.Sec
        Detail  = $deviceDetail
    })
}

$failCount = @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count

Write-Host ''
$fmt = '{0,-22} | {1,-21} | {2,7} | {3}'
Write-Host ($fmt -f 'STEP', 'RESULT (PASS/FAIL/SKIP)', 'SECONDS', 'DETAIL')
foreach ($r in $rows) {
    Write-Host ($fmt -f $r.Step, $r.Result, $r.Seconds, $r.Detail)
}
Write-Host ''
Write-Host ("TOTAL: {0} FAILED" -f $failCount)
exit $failCount
