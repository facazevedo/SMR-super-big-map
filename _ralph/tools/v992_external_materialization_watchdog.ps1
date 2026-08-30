Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-SbmUtf8NoBomAtomic {
    param([Parameter(Mandatory=$true)][string]$Path,
          [Parameter(Mandatory=$true)][string]$Text)
    $full = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($full)
    if (-not [System.IO.Directory]::Exists($directory)) {
        throw "watchdog output directory is absent: $directory"
    }
    $temporary = $full + '.tmp.' + [Guid]::NewGuid().ToString('N')
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $encoding)
        if ([System.IO.File]::Exists($full)) { throw "watchdog output already exists: $full" }
        [System.IO.File]::Move($temporary, $full)
    } finally {
        if ([System.IO.File]::Exists($temporary)) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Get-SbmFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-SbmTrackedProcessIdentity {
    param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process)
    $Process.Refresh()
    [pscustomobject]@{
        pid = [int]$Process.Id
        creation_time_utc_ticks = [long]$Process.StartTime.ToUniversalTime().Ticks
        process_name = [string]$Process.ProcessName
        executable_path = if ($Process.Path) { [System.IO.Path]::GetFullPath($Process.Path) } else { '' }
    }
}

function Test-SbmTrackedProcessIdentity {
    param([Parameter(Mandatory=$true)]$Identity)
    if ($Identity.pid -isnot [int] -and $Identity.pid -isnot [long]) { return $false }
    if ($Identity.creation_time_utc_ticks -isnot [long] -and
        $Identity.creation_time_utc_ticks -isnot [int]) { return $false }
    try { $candidate = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop } catch { return $false }
    try {
        $actualTicks = [long]$candidate.StartTime.ToUniversalTime().Ticks
        $actualName = [string]$candidate.ProcessName
        $actualPath = if ($candidate.Path) { [System.IO.Path]::GetFullPath($candidate.Path) } else { '' }
    } catch { return $false }
    return $actualTicks -eq [long]$Identity.creation_time_utc_ticks -and
        $actualName -ceq [string]$Identity.process_name -and
        $actualPath -ceq [string]$Identity.executable_path
}

function Stop-SbmTrackedProcessExact {
    param([Parameter(Mandatory=$true)]$Identity,
          [int]$WaitMilliseconds = 15000)
    if (-not (Test-SbmTrackedProcessIdentity -Identity $Identity)) {
        return [pscustomobject]@{ attempted=$false; killed=$false; identity_match=$false; exited=$false }
    }
    $candidate = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop
    Stop-Process -Id ([int]$Identity.pid) -Force -ErrorAction Stop
    $exited = $candidate.WaitForExit([Math]::Max(1, $WaitMilliseconds))
    [pscustomobject]@{ attempted=$true; killed=$true; identity_match=$true; exited=[bool]$exited }
}

function ConvertFrom-SbmHeartbeatText {
    param([Parameter(Mandatory=$true)][string]$Text)
    $record = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $split = $line.IndexOf('=')
        if ($split -le 0) { throw "malformed heartbeat row" }
        $key = $line.Substring(0, $split)
        $value = $line.Substring($split + 1)
        if ($record.Contains($key)) { throw "duplicate heartbeat key: $key" }
        $record[$key] = $value
    }
    if ($record.schema -cne 'smr.sbm.lazy-phase-heartbeat.v1' -or
        $record.complete -cne 'true') { throw 'heartbeat schema/completion mismatch' }
    [pscustomobject]$record
}

function Read-SbmPhaseHeartbeats {
    param([Parameter(Mandatory=$true)][string]$Prefix,
          [Parameter(Mandatory=$true)][string]$Nonce,
          [Parameter(Mandatory=$true)][string]$ManifestSha256)
    $fullPrefix = [System.IO.Path]::GetFullPath($Prefix)
    $directory = [System.IO.Path]::GetDirectoryName($fullPrefix)
    $leafPrefix = [System.IO.Path]::GetFileName($fullPrefix)
    $files = @()
    if ([System.IO.Directory]::Exists($directory)) {
        $files = @(Get-ChildItem -LiteralPath $directory -File |
            Where-Object { $_.Name -cmatch ('^' + [regex]::Escape($leafPrefix) + '[0-9]{4}\.txt$') } |
            Sort-Object Name)
    }
    $timeline = @()
    $open = @{}
    $expected = 1
    $invalid = @()
    foreach ($file in $files) {
        try {
            $record = ConvertFrom-SbmHeartbeatText -Text ([System.IO.File]::ReadAllText($file.FullName))
            $sequence = 0
            if (-not [int]::TryParse([string]$record.sequence, [ref]$sequence) -or $sequence -ne $expected) {
                throw "non-contiguous sequence $($record.sequence), expected $expected"
            }
            if ($record.nonce -cne $Nonce -or
                $record.command_manifest_sha256 -cne $ManifestSha256.ToLowerInvariant()) {
                throw 'heartbeat identity mismatch'
            }
            if ($record.edge -cnotin @('BEFORE','AFTER','ERROR')) { throw 'heartbeat edge mismatch' }
            $phase = [string]$record.phase
            if ($record.edge -ceq 'BEFORE') {
                $open[$phase] = $record
            } elseif ($open.ContainsKey($phase)) {
                $open.Remove($phase)
            }
            if ($timeline.Count -lt 64) { $timeline += $record }
            $expected++
        } catch {
            if ($invalid.Count -lt 8) { $invalid += "$($file.Name):$($_.Exception.Message)" }
        }
    }
    $inflight = @($open.Keys | Sort-Object)
    $last = if ($timeline.Count -gt 0) { $timeline[$timeline.Count - 1] } else { $null }
    [pscustomobject]@{
        complete_records = [int]$timeline.Count
        invalid_records = [int]$invalid.Count
        invalid_examples = $invalid
        timeline = $timeline
        last_record = $last
        inflight_phases = $inflight
        last_completed_phase = if ($last -and $last.edge -ceq 'AFTER') { $last.phase } else { '' }
        diagnostics_complete = ($timeline.Count -gt 0 -and $invalid.Count -eq 0)
    }
}

function Test-SbmTcpPortClosed {
    param([Parameter(Mandatory=$true)][int]$Port, [int]$TimeoutMilliseconds = 1000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $connected = $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false) -and $client.Connected
        return -not $connected
    } catch { return $true } finally { $client.Close() }
}

function Publish-SbmExternalWatchdogTimeout {
    param(
        [Parameter(Mandatory=$true)][string]$HeartbeatPrefix,
        [Parameter(Mandatory=$true)][string]$BundlePath,
        [Parameter(Mandatory=$true)][string]$TerminalPath,
        [Parameter(Mandatory=$true)][string]$CleanupReceiptPath,
        [Parameter(Mandatory=$true)][string]$Nonce,
        [Parameter(Mandatory=$true)][string]$ManifestSha256,
        [Parameter(Mandatory=$true)]$TrackedProcess,
        [Parameter(Mandatory=$true)][int]$DapPort,
        [bool]$DapQuitSucceeded = $false
    )
    $heartbeats = Read-SbmPhaseHeartbeats -Prefix $HeartbeatPrefix -Nonce $Nonce `
        -ManifestSha256 $ManifestSha256
    $bundle = [ordered]@{
        schema = 'smr.ralph.external-materialization-causal-bundle.v1'
        ok = $false
        diagnostic_only = $true
        acceptance_timing_eligible = $false
        can_promote = $false
        sentinel_reason = 'post-T1 materialization exceeded hard 300-second budget'
        nonce = $Nonce
        command_manifest_sha256 = $ManifestSha256.ToLowerInvariant()
        heartbeat_complete_records = $heartbeats.complete_records
        heartbeat_invalid_records = $heartbeats.invalid_records
        heartbeat_invalid_examples = $heartbeats.invalid_examples
        last_completed_phase = $heartbeats.last_completed_phase
        inflight_phases = $heartbeats.inflight_phases
        phase_timeline = $heartbeats.timeline
        diagnostics_complete = $heartbeats.diagnostics_complete
        root_cause_candidates = @(
            if ($heartbeats.inflight_phases.Count -gt 0) {
                [ordered]@{ rank=1; candidate='synchronous phase did not return'; evidence=$heartbeats.inflight_phases }
            } else {
                [ordered]@{ rank=1; candidate='phase heartbeat missing or thread unavailable'; evidence=@('no paired in-flight phase') }
            }
        )
        process_identity = $TrackedProcess
        dap_quit_succeeded_before_publication = $DapQuitSucceeded
        bundle_published_before_terminal = $true
        unknown_or_incomplete_is_failure = $true
    }
    $bundleJson = $bundle | ConvertTo-Json -Depth 12 -Compress
    Write-SbmUtf8NoBomAtomic -Path $BundlePath -Text ($bundleJson + "`n")
    $bundleHash = Get-SbmFileSha256 -Path $BundlePath
    $terminal = [ordered]@{
        schema = 'smr.ralph.external-materialization-terminal.v1'
        ok = $false
        diagnostic_only = $true
        acceptance_timing_eligible = $false
        can_promote = $false
        bundle_path = [System.IO.Path]::GetFullPath($BundlePath)
        bundle_sha256 = $bundleHash
        reason = $bundle.sentinel_reason
    } | ConvertTo-Json -Compress
    Write-SbmUtf8NoBomAtomic -Path $TerminalPath -Text ($terminal + "`n")

    $kill = if ($DapQuitSucceeded) {
        [pscustomobject]@{ attempted=$false; killed=$false; identity_match=$true; exited=$true }
    } else { Stop-SbmTrackedProcessExact -Identity $TrackedProcess }
    Start-Sleep -Milliseconds 200
    $identityGone = -not (Test-SbmTrackedProcessIdentity -Identity $TrackedProcess)
    $portClosed = Test-SbmTcpPortClosed -Port $DapPort
    $cleanup = [ordered]@{
        schema = 'smr.ralph.external-materialization-cleanup.v1'
        ok = ($identityGone -and $portClosed)
        tracked_identity_gone = $identityGone
        dap_port_closed = $portClosed
        dap_quit_succeeded = $DapQuitSucceeded
        exact_kill_attempted = $kill.attempted
        exact_kill_identity_match = $kill.identity_match
        exact_kill_exited = $kill.exited
        bundle_precedes_terminal = ((Get-Item -LiteralPath $BundlePath).CreationTimeUtc -le
            (Get-Item -LiteralPath $TerminalPath).CreationTimeUtc)
    } | ConvertTo-Json -Compress
    Write-SbmUtf8NoBomAtomic -Path $CleanupReceiptPath -Text ($cleanup + "`n")
    if (-not $identityGone -or -not $portClosed) {
        throw 'external watchdog could not prove tracked process and DAP port cleanup'
    }
    [pscustomobject]@{ bundle=$BundlePath; terminal=$TerminalPath; cleanup=$CleanupReceiptPath; killed=$kill.killed }
}
