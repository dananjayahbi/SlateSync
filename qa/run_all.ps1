# qa/run_all.ps1 — Doc 28 §4/§6 run_all (Round-6 extended): no required parameters.
# Step order: (1) validate_specs — 20-action freeze (ws_rpc_schema.json enum) ->
# (2) pytest pc_agent/tests -q -rA -> (3) ruff check . -> (4) flutter analyze ->
# (5) flutter test -> (6) gate citations — contract/CLEAR/relay/trail-pan/thumbnail
# test NAMES cited from the runs in (2)/(5), never re-run individually ->
# (7) qa\latency_probe.py (p95 <= 8 ms, transport mean <= 4 ms) ->
# (8) qa\export_verify.py (Doc 28 ladder + Round-6 extent matrix + thumbnail
# smoke) -> (9) dist exe --smoke -> (10) installer exists+size -> (11) APK
# exists+size -> (12) firewall setup.iss script lines (the live rule registers at
# install time, so the script lines are the gate) -> (13) memory benchmark iff
# `flutter devices` reports an attached Android device, else SKIP (never FAIL).
# Output: UTF-8 table STEP | RESULT (PASS/FAIL/SKIP) | SECONDS | DETAIL, then the
# GATE CITATIONS block, then "TOTAL: n FAILED". Exit code = number of FAILed
# steps (Doc 28 §5; SKIP never counts as failure).

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

$rows = New-Object System.Collections.ArrayList

# Runs the child with OUTPUT CAPTURED (citations read the -q / flutter test
# streams); cwd honoured via Push-Location so cmd /c flutter keeps working.
function Invoke-Step {
    param([string]$Exe, [string[]]$ArgList, [string]$Cwd)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = @()
    try {
        Push-Location -LiteralPath $Cwd
        try {
            $out = @(& $Exe @ArgList 2>&1 | ForEach-Object { $_.ToString() })
        } finally {
            Pop-Location
        }
        $sw.Stop()
        $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { -1 }
        return @{ Code = $code; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Err = ''; Out = $out }
    } catch {
        $sw.Stop()
        return @{ Code = -1; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Err = $_.Exception.Message; Out = $out }
    }
}

function Add-Row {
    param([string]$Step, [string]$Result, [double]$Sec, [string]$Detail)
    [void]$rows.Add([pscustomobject]@{ Step = $Step; Result = $Result; Seconds = $Sec; Detail = $Detail })
}

function Show-Tail {
    param([string]$Name, [string[]]$Out, [int]$Last = 40)
    if ($Out -and $Out.Count -gt 0) {
        $n = [math]::Min($Last, $Out.Count)
        Write-Host ("---- {0}: last {1} output lines ----" -f $Name, $n)
        $Out | Select-Object -Last $n | ForEach-Object { Write-Host $_ }
        Write-Host ("---- end {0} ----" -f $Name)
    }
}

function Format-Bytes([long]$n) {
    if ($n -ge 1MB) { return ("{0} ({1:N1} MiB)" -f $n, ($n / 1MB)) }
    return ("{0} B" -f $n)
}

# ---- Step 1: validate_specs + Round-6 20-action freeze -------------------
Write-Host 'running: validate_specs (20 actions) ...'
$specPath = Join-Path $repoRoot 'shared_specs\ws_rpc_schema.json'
$actionCount = -1
$hasClear = $false
$specErr = ''
try {
    $specJson = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json
    $enum = @($specJson.envelope.action.enum)
    $actionCount = $enum.Count
    $hasClear = ($enum -contains 'CLEAR_CANVAS')
} catch {
    $specErr = "action enum unreadable: $($_.Exception.Message)"
}
$rSpec = Invoke-Step -Exe $venvPython -ArgList @('shared_specs\validate_specs.py') -Cwd $repoRoot
$specsOk = ($rSpec.Code -eq 0 -and $actionCount -eq 20 -and $hasClear -and -not $specErr)
if ($specErr) {
    $specsDetail = $specErr
} elseif ($rSpec.Code -ne 0) {
    $specsDetail = if ($rSpec.Err) { "start failed: $($rSpec.Err)" } else { "exit code $($rSpec.Code)" }
} elseif ($actionCount -ne 20 -or -not $hasClear) {
    $specsDetail = "$actionCount actions (expected 20 incl. CLEAR_CANVAS)"
} else {
    $specsDetail = "3 specs valid; $actionCount actions (CLEAR_CANVAS present)"
}
Add-Row -Step 'validate_specs (20 actions)' -Result $(if ($specsOk) { 'PASS' } else { 'FAIL' }) `
    -Sec $rSpec.Sec -Detail $specsDetail
if (-not $specsOk -and $rSpec.Out) { Show-Tail -Name 'validate_specs' -Out $rSpec.Out }

# ---- Step 2: pytest pc_agent/tests (-q -rA: PASSED names feed citations) --
Write-Host 'running: pytest pc_agent/tests ...'
$rPytest = Invoke-Step -Exe $venvPython -ArgList @('-m', 'pytest', 'pc_agent/tests', '-q', '-rA') -Cwd $repoRoot
$pytestOut = @($rPytest.Out)
$pytestDetail = if ($rPytest.Err) { "start failed: $($rPytest.Err)" } else { "exit code $($rPytest.Code)" }
if ($pytestOut.Count -gt 0) {
    $summary = $pytestOut | Where-Object { $_ -match '\d+ (passed|failed|error)' } | Select-Object -Last 1
    if ($summary) { $pytestDetail = "$($summary.Trim()); exit code $($rPytest.Code)" }
}
Add-Row -Step 'pytest pc_agent/tests' -Result $(if ($rPytest.Code -eq 0) { 'PASS' } else { 'FAIL' }) `
    -Sec $rPytest.Sec -Detail $pytestDetail
if ($rPytest.Code -ne 0) { Show-Tail -Name 'pytest' -Out $pytestOut }

# ---- Step 3: ruff ---------------------------------------------------------
Write-Host 'running: ruff check . ...'
$rRuff = Invoke-Step -Exe $venvPython -ArgList @('-m', 'ruff', 'check', '.') -Cwd $repoRoot
$ruffOut = @($rRuff.Out)
$ruffDetail = if ($rRuff.Err) { "start failed: $($rRuff.Err)" } else { "exit code $($rRuff.Code)" }
if ($ruffOut.Count -gt 0) {
    $last = $ruffOut | Where-Object { $_.Trim() } | Select-Object -Last 1
    if ($last) { $ruffDetail = $last.Trim() }
}
Add-Row -Step 'ruff check .' -Result $(if ($rRuff.Code -eq 0) { 'PASS' } else { 'FAIL' }) `
    -Sec $rRuff.Sec -Detail $ruffDetail
if ($rRuff.Code -ne 0) { Show-Tail -Name 'ruff' -Out $ruffOut }

# ---- Step 4: flutter analyze (flutter is a .bat shim: cmd /c) -------------
Write-Host 'running: flutter analyze ...'
$rAn = Invoke-Step -Exe 'cmd' -ArgList @('/c', 'flutter', 'analyze') -Cwd $mobileApp
$anOut = @($rAn.Out)
$anDetail = if ($rAn.Err) { "start failed: $($rAn.Err)" } else { "exit code $($rAn.Code)" }
if ($anOut.Count -gt 0) {
    $last = $anOut | Where-Object { $_.Trim() } | Select-Object -Last 1
    if ($last) { $anDetail = $last.Trim() }
}
Add-Row -Step 'flutter analyze' -Result $(if ($rAn.Code -eq 0) { 'PASS' } else { 'FAIL' }) `
    -Sec $rAn.Sec -Detail $anDetail
if ($rAn.Code -ne 0) { Show-Tail -Name 'flutter analyze' -Out $anOut -Last 30 }

# ---- Step 5: flutter test (JSON reporter: suite-id -> file attribution,
# needed because the human-readable compact reporter omits file paths on many
# lines, and test.url points at package:flutter_test for testWidgets cases) ----
Write-Host 'running: flutter test (json reporter) ...'
$rFl = Invoke-Step -Exe 'cmd' -ArgList @('/c', 'flutter', 'test', '--reporter', 'json') -Cwd $mobileApp
$flOut = @($rFl.Out)
$flSuites = @{}   # suite id -> file path
$flTests = @{}    # test id -> @{ Name; SuiteId }
$flResults = @{}  # test id -> @{ Result; Hidden }
$flErrors = @()
$flDoneOk = $null
foreach ($line in $flOut) {
    $ev = $null
    try { $ev = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $ev.type) { continue }
    if ($ev.type -eq 'suite') {
        $flSuites[[int]$ev.suite.id] = [string]$ev.suite.path
    } elseif ($ev.type -eq 'testStart') {
        $flTests[[int]$ev.test.id] = @{ Name = [string]$ev.test.name; SuiteId = [int]$ev.test.suiteID }
    } elseif ($ev.type -eq 'testDone') {
        $flResults[[int]$ev.testId] = @{ Result = [string]$ev.result; Hidden = [bool]$ev.hidden }
    } elseif ($ev.type -eq 'error') {
        $msg = (([string]$ev.error.message) -split "`r?`n")[0]
        if ($msg) { $flErrors += $msg }
    } elseif ($ev.type -eq 'done') {
        $flDoneOk = [bool]$ev.success
    }
}
$flPassed = 0
$flFailedNames = @()
foreach ($tid in $flTests.Keys) {
    $t = $flTests[$tid]
    if ($t.Name -like 'loading *') { continue }   # suite-loading pseudo-tests
    if (-not $flResults.ContainsKey($tid)) { continue }
    $res = $flResults[$tid]
    if ($res.Hidden) { continue }
    if ($res.Result -eq 'success') {
        $flPassed++
    } elseif ($res.Result -eq 'failure') {
        $p = ''
        if ($flSuites.ContainsKey($t.SuiteId)) { $p = $flSuites[$t.SuiteId] }
        $flFailedNames += ('{0} :: {1}' -f (Split-Path -Leaf $p), $t.Name)
    }
}
$flDetail = if ($rFl.Err) { "start failed: $($rFl.Err)" } else { "exit code $($rFl.Code)" }
if ($null -ne $flDoneOk) {
    $flDetail = "$flPassed passed, $($flFailedNames.Count) failed; exit code $($rFl.Code)"
    if ($flErrors.Count -gt 0) { $flDetail += "; $($flErrors.Count) suite error event(s)" }
}
$flOk = ($rFl.Code -eq 0 -and $flDoneOk -eq $true)
Add-Row -Step 'flutter test' -Result $(if ($flOk) { 'PASS' } else { 'FAIL' }) `
    -Sec $rFl.Sec -Detail $flDetail
if (-not $flOk) {
    if ($flFailedNames.Count -gt 0) {
        Write-Host ('---- flutter test: first {0} failed tests ----' -f ([math]::Min(15, $flFailedNames.Count)))
        $flFailedNames | Select-Object -First 15 | ForEach-Object { Write-Host $_ }
        Write-Host '---- end flutter test failures ----'
    } elseif ($flErrors.Count -gt 0) {
        Write-Host '---- flutter test: suite error events ----'
        $flErrors | Select-Object -First 5 | ForEach-Object { Write-Host $_ }
        Write-Host '---- end flutter test errors ----'
    } else {
        Show-Tail -Name 'flutter test' -Out $flOut
    }
}

# ---- Step 6: gate citations — names taken from steps 2/5 (never re-run) ---
Write-Host 'computing: gate citations ...'
$cSw = [System.Diagnostics.Stopwatch]::StartNew()
$pytestNamed = @($pytestOut | Where-Object { $_ -match '^(PASSED|FAILED|ERROR)\s' })
function Get-PcNames([string]$Pattern) {
    @($pytestNamed | Where-Object { $_ -match $Pattern } | ForEach-Object {
        $idx = $_.IndexOf('::'); if ($idx -ge 0) { $_.Substring($idx + 2) } else { $_.Trim() }
    })
}
# Dart: successful, non-loading tests with their suite file (JSON run in step 5).
$dartPassed = @()
foreach ($tid in $flTests.Keys) {
    $t = $flTests[$tid]
    if ($t.Name -like 'loading *') { continue }
    if (-not $flResults.ContainsKey($tid)) { continue }
    if ($flResults[$tid].Hidden -or $flResults[$tid].Result -ne 'success') { continue }
    $p = ''
    if ($flSuites.ContainsKey($t.SuiteId)) { $p = $flSuites[$t.SuiteId] }
    $dartPassed += @{ Path = $p; Name = $t.Name }
}
function Get-DartNames([hashtable[]]$Tests, [scriptblock]$Match) {
    @($Tests | Where-Object { & $Match $_ } | ForEach-Object {
        '{0} :: {1}' -f (Split-Path -Leaf $_.Path), $_.Name
    })
}
$pcContract = @(Get-PcNames 'test_contract_cross_specs\.py::')
$dartContract = @(Get-DartNames $dartPassed { param($t) $t.Path -match 'contract_\w+_test\.dart' })
$pcClear = @(Get-PcNames '(?i)clear')
$dartClear = @(Get-DartNames $dartPassed {
    param($t) $t.Path -match 'clear_flow_test|engine_clear_all|tool_panels_hold_clear' -or $t.Name -match '(?i)clear'
})
$pcRelay = @(Get-PcNames '(?i)relay')
$dartRelay = @(Get-DartNames $dartPassed {
    param($t) $t.Path -match 'remote_mutation_test' -or $t.Name -match '(?i)relay'
})
$pcTrailPan = @(Get-PcNames 'test_mirror_trail_pan\.py::')
$dartThumb = @(Get-DartNames $dartPassed { param($t) $t.Path -match 'thumbnail_pipeline_test\.dart' })
$cSw.Stop()

$citeProblems = @()
if ($pcContract.Count -ne 7) { $citeProblems += "PC contract $($pcContract.Count)/7" }
if ($dartContract.Count -ne 14) { $citeProblems += "Dart contract $($dartContract.Count)/14" }
if ($pcClear.Count -lt 1) { $citeProblems += 'PC CLEAR' }
if ($dartClear.Count -lt 1) { $citeProblems += 'Dart CLEAR' }
if ($pcRelay.Count -lt 1) { $citeProblems += 'PC relay' }
if ($dartRelay.Count -lt 1) { $citeProblems += 'Dart relay' }
if ($pcTrailPan.Count -lt 1) { $citeProblems += 'PC trail-pan' }
if ($dartThumb.Count -lt 1) { $citeProblems += 'Dart thumbnail' }
$citeDetail = ("PC contract {0}/7; Dart contract {1}/14; CLEAR PC {2} Dart {3}; relay PC {4} Dart {5}; trail-pan {6}; thumb {7}" -f `
    $pcContract.Count, $dartContract.Count, $pcClear.Count, $dartClear.Count, `
    $pcRelay.Count, $dartRelay.Count, $pcTrailPan.Count, $dartThumb.Count)
if ($citeProblems.Count -gt 0) { $citeDetail += '; MISSING: ' + ($citeProblems -join ', ') }
Add-Row -Step 'gate citations' -Result $(if ($citeProblems.Count -eq 0) { 'PASS' } else { 'FAIL' }) `
    -Sec ([math]::Round($cSw.Elapsed.TotalSeconds, 1)) -Detail $citeDetail

# ---- Step 7: latency probe ------------------------------------------------
Write-Host 'running: latency_probe.py ...'
$rLat = Invoke-Step -Exe $venvPython -ArgList @('qa\latency_probe.py', '--token', $probeToken) -Cwd $repoRoot
$latOut = @($rLat.Out)
$latDetail = if ($rLat.Err) { "start failed: $($rLat.Err)" } else { "exit code $($rLat.Code)" }
$mIdx = -1
for ($i = 0; $i -lt $latOut.Count; $i++) { if ($latOut[$i] -match 'p50 ms \| p95 ms') { $mIdx = $i } }
if ($mIdx -ge 0 -and ($mIdx + 1) -lt $latOut.Count) {
    $cells = $latOut[$mIdx + 1].Split('|') | ForEach-Object { $_.Trim() }
    if ($cells.Count -ge 4) {
        $latDetail = "p50 $($cells[0]) ms; p95 $($cells[1]) ms; transport $($cells[3]) ms; exit code $($rLat.Code)"
    }
}
Add-Row -Step 'latency_probe.py' -Result $(if ($rLat.Code -eq 0) { 'PASS' } else { 'FAIL' }) `
    -Sec $rLat.Sec -Detail $latDetail
if ($rLat.Code -ne 0) { Show-Tail -Name 'latency_probe' -Out $latOut }

# ---- Step 8: export verify (ladder + extent matrix + thumbnail smoke) -----
Write-Host 'running: export_verify.py (this can take ~15 min) ...'
$rExp = Invoke-Step -Exe $venvPython -ArgList @('qa\export_verify.py') -Cwd $repoRoot
$expOut = @($rExp.Out)
$expDetail = if ($rExp.Err) { "start failed: $($rExp.Err)" } else { "exit code $($rExp.Code)" }
$resultLine = $expOut | Where-Object { $_ -match '^RESULT: (PASS|FAIL)' } | Select-Object -Last 1
if ($resultLine) {
    $m = [regex]::Match($resultLine, '^RESULT: (PASS|FAIL) \(([^;]+);([^;]+);([^)]+)\)')
    if ($m.Success) { $expDetail = "$($m.Groups[2].Value.Trim()); $($m.Groups[4].Value.Trim())" }
    else { $expDetail = $resultLine.Trim() }
}
Add-Row -Step 'export_verify.py' -Result $(if ($rExp.Code -eq 0) { 'PASS' } else { 'FAIL' }) `
    -Sec $rExp.Sec -Detail $expDetail
if ($rExp.Code -ne 0) { Show-Tail -Name 'export_verify' -Out $expOut -Last 60 }

# ---- Step 9: packaged exe --smoke ----------------------------------------
Write-Host 'running: SlateSyncAgent.exe --smoke ...'
$exePath = Join-Path $repoRoot 'dist\SlateSyncAgent\SlateSyncAgent.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
    Add-Row -Step 'exe --smoke' -Result 'FAIL' -Sec 0 -Detail 'dist\SlateSyncAgent\SlateSyncAgent.exe missing'
} else {
    $exeSize = (Get-Item -LiteralPath $exePath).Length
    $rExe = Invoke-Step -Exe $exePath -ArgList @('--smoke') -Cwd (Split-Path -Parent $exePath)
    $exeDetail = if ($rExe.Err) { "start failed: $($rExe.Err)" } else { "exit code $($rExe.Code); $(Format-Bytes $exeSize)" }
    Add-Row -Step 'exe --smoke' -Result $(if ($rExe.Code -eq 0) { 'PASS' } else { 'FAIL' }) `
        -Sec $rExe.Sec -Detail $exeDetail
    if ($rExe.Code -ne 0) { Show-Tail -Name 'exe --smoke' -Out @($rExe.Out) }
}

# ---- Step 10: installer artifact (exists + size) -------------------------
Write-Host 'checking: SlateSync_Setup.exe ...'
$setupPath = Join-Path $repoRoot 'dist\SlateSync_Setup.exe'
if (Test-Path -LiteralPath $setupPath) {
    $setupSize = (Get-Item -LiteralPath $setupPath).Length
    $setupOk = $setupSize -ge 1MB
    Add-Row -Step 'installer artifact' -Result $(if ($setupOk) { 'PASS' } else { 'FAIL' }) -Sec 0 `
        -Detail "dist\SlateSync_Setup.exe $(Format-Bytes $setupSize)"
} else {
    Add-Row -Step 'installer artifact' -Result 'FAIL' -Sec 0 -Detail 'dist\SlateSync_Setup.exe missing'
}

# ---- Step 11: release APK artifact (exists + size) -----------------------
Write-Host 'checking: app-release.apk ...'
$apkPath = Join-Path $repoRoot 'mobile_app\build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path -LiteralPath $apkPath) {
    $apkSize = (Get-Item -LiteralPath $apkPath).Length
    $apkOk = $apkSize -ge 1MB
    Add-Row -Step 'release APK artifact' -Result $(if ($apkOk) { 'PASS' } else { 'FAIL' }) -Sec 0 `
        -Detail "app-release.apk $(Format-Bytes $apkSize)"
} else {
    Add-Row -Step 'release APK artifact' -Result 'FAIL' -Sec 0 -Detail 'app-release.apk missing'
}

# ---- Step 12: firewall script lines in setup.iss -------------------------
# The live rule registers at INSTALL time (Doc 19 run entry), so the gate is
# the script lines themselves — the Doc 28 matrix `netsh show rule` probe can
# only succeed on an already-installed machine.
Write-Host 'checking: setup.iss firewall lines ...'
$issPath = Join-Path $repoRoot 'pc_agent\installer\setup.iss'
$fwShow = $false; $fwAdd = $false; $fwDelete = $false
$issExists = Test-Path -LiteralPath $issPath
if ($issExists) {
    $fwLines = @(Get-Content -LiteralPath $issPath | Where-Object { $_ -match 'netsh advfirewall firewall' })
    $fwShow = [bool]($fwLines | Where-Object { $_ -match 'show rule' -and $_ -match 'SlateSync WS' })
    $fwAdd = [bool]($fwLines | Where-Object { $_ -match 'add rule' -and $_ -match 'SlateSync WS' -and $_ -match 'localport=50606' })
    $fwDelete = [bool]($fwLines | Where-Object { $_ -match 'delete rule' -and $_ -match 'SlateSync WS' })
}
$fwOk = $fwShow -and $fwAdd -and $fwDelete
$fwDetail = 'show/add/delete lines present (rule registers at install)'
if (-not $fwOk) {
    $missing = @()
    if (-not $fwShow) { $missing += 'show' }
    if (-not $fwAdd) { $missing += 'add' }
    if (-not $fwDelete) { $missing += 'delete' }
    $fwDetail = if ($issExists) { 'missing: ' + ($missing -join ', ') } else { 'setup.iss missing' }
}
Add-Row -Step 'firewall setup.iss lines' -Result $(if ($fwOk) { 'PASS' } else { 'FAIL' }) -Sec 0 -Detail $fwDetail

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
$fmt = '{0,-30} | {1,-21} | {2,7} | {3}'
Write-Host ($fmt -f 'STEP', 'RESULT (PASS/FAIL/SKIP)', 'SECONDS', 'DETAIL')
foreach ($r in $rows) {
    Write-Host ($fmt -f $r.Step, $r.Result, $r.Seconds, $r.Detail)
}

# ---- Gate citations block (names cited from the runs above) ---------------
function Show-CiteNames([string]$Label, [string[]]$Names, [int]$Max = 8) {
    if ($Names.Count -eq 0) { Write-Host ("  {0}: NONE FOUND" -f $Label); return }
    $shown = @($Names | Select-Object -First $Max)
    $line = '  {0}: {1}' -f $Label, ($shown -join '; ')
    if ($Names.Count -gt $Max) { $line += (' (+{0} more)' -f ($Names.Count - $Max)) }
    Write-Host $line
}
Write-Host ''
Write-Host 'GATE CITATIONS (test names cited from the -q / flutter test runs above; never re-run individually)'
Write-Host ("  validate_specs: ws_rpc_schema.json envelope.action.enum = {0} actions (CLEAR_CANVAS {1})" -f `
    $actionCount, $(if ($hasClear) { 'present' } else { 'ABSENT' }))
Show-CiteNames -Label "PC contract tests ($($pcContract.Count)/7)" -Names $pcContract -Max 10
Show-CiteNames -Label "Dart contract tests ($($dartContract.Count)/14)" -Names $dartContract -Max 16
Show-CiteNames -Label "CLEAR tests (PC $($pcClear.Count) / Dart $($dartClear.Count))" -Names @($pcClear + $dartClear)
Show-CiteNames -Label "relay tests (PC $($pcRelay.Count) / Dart $($dartRelay.Count))" -Names @($pcRelay + $dartRelay)
Show-CiteNames -Label "trail-pan regression (PC $($pcTrailPan.Count))" -Names $pcTrailPan
Show-CiteNames -Label "thumbnail pipeline (Dart $($dartThumb.Count); PC smoke inside export_verify)" -Names $dartThumb

Write-Host ''
Write-Host ("TOTAL: {0} FAILED" -f $failCount)
exit $failCount
