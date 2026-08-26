param(
    [Parameter(Mandatory = $true)][string]$ReferenceManifest,
    [Parameter(Mandatory = $true)][string]$CandidateBase,
    [Parameter(Mandatory = $true)][string]$Verdict,
    [string]$AbortSentinel = "",
    [string]$ReadySentinel = "",
    [ValidateSet("HashOnly", "Full")][string]$Mode = "HashOnly",
    [ValidateSet("HashOnly", "Full")][string]$ExpectedReferenceMode = "HashOnly",
    [ValidateSet("True", "False")][string]$ReferenceModeInferred = "False",
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Schema = "smr.ralph.event_checkpoint_verdict.v1"

function Write-JsonAtomic([string]$Path, [object]$Payload) {
    $resolvedParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [IO.Directory]::CreateDirectory($resolvedParent) | Out-Null
    $temporary = Join-Path $resolvedParent ("." + [IO.Path]::GetFileName($Path) + "." + $PID + ".tmp")
    $Payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Get-ReadyHash([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    } catch [IO.IOException] {
        return $null
    }
    try {
        $length = $stream.Length
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = [Convert]::ToHexString($algorithm.ComputeHash($stream))
        } finally {
            $algorithm.Dispose()
        }
        return [ordered]@{ bytes = $length; sha256 = $digest }
    } finally {
        $stream.Dispose()
    }
}

function Publish-Failure([string]$Reason, [object]$Rows, [object]$FirstMismatch, [datetime]$Started) {
    $payload = [ordered]@{
        schema = $Schema
        ok = $false
        mode = $Mode
        candidate_observer_mode = $Mode
        reference_observer_mode = $ExpectedReferenceMode
        reference_observer_mode_inferred = $ReferenceModeInferred -eq "True"
        mode_matched_reference = $true
        event_driven = $true
        reason = $Reason
        first_mismatch = $FirstMismatch
        checked = @($Rows).Count
        checkpoints = @($Rows)
        elapsed_ms = [math]::Round(((Get-Date) - $Started).TotalMilliseconds, 3)
    }
    Write-JsonAtomic $Verdict $payload
    if ($AbortSentinel) {
        Write-JsonAtomic $AbortSentinel ([ordered]@{
            schema = "smr.ralph.fail_fast_abort.v1"
            reason = $Reason
            verdict = [IO.Path]::GetFullPath($Verdict)
        })
    }
    if ($Mode -eq "HashOnly" -and $null -ne $script:directory -and $null -ne $script:prefix) {
        Get-ChildItem -LiteralPath $script:directory -File |
            Where-Object { $_.Name.StartsWith($script:prefix) } |
            Remove-Item -Force
    }
    $payload | ConvertTo-Json -Depth 30
    exit 1
}

$referencePath = [IO.Path]::GetFullPath($ReferenceManifest)
$reference = Get-Content -LiteralPath $referencePath -Raw | ConvertFrom-Json
if ($reference.schema -ne "smr.ralph.checkpoint_reference.v1" -or -not $reference.ok) {
    throw "invalid checkpoint reference manifest"
}
$modeProperty = $reference.identity.PSObject.Properties["observer_mode"]
$manifestMode = if ($null -eq $modeProperty) { $null } else { [string]$modeProperty.Value }
$manifestModeInferred = $false
if ([string]::IsNullOrWhiteSpace([string]$manifestMode)) {
    $manifestMode = "HashOnly"
    $manifestModeInferred = $true
}
if ($manifestMode -notin @("HashOnly", "Full")) {
    throw "checkpoint reference has invalid observer_mode: $manifestMode"
}
if ($manifestMode -ne $ExpectedReferenceMode) {
    throw "reference observer mode changed after validation"
}
if ($manifestModeInferred -ne ($ReferenceModeInferred -eq "True")) {
    throw "reference observer-mode inference changed after validation"
}
if ($Mode -ne $manifestMode) {
    throw "observer-mode mismatch: reference is $manifestMode, candidate is $Mode"
}
$basePath = [IO.Path]::GetFullPath($CandidateBase)
$directory = [IO.Path]::GetDirectoryName($basePath)
$prefix = [IO.Path]::GetFileName($basePath)
[IO.Directory]::CreateDirectory($directory) | Out-Null
$existing = @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name.StartsWith($prefix) })
if ($existing.Count -ne 0) {
    throw "candidate base is not fresh; found $($existing.Count) existing files"
}

$watcher = [IO.FileSystemWatcher]::new($directory, $prefix + "*")
$watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::Size -bor [IO.NotifyFilters]::LastWrite
$watcher.InternalBufferSize = 65536
$watcher.EnableRaisingEvents = $true
$started = Get-Date
if ($ReadySentinel) {
    Write-JsonAtomic $ReadySentinel ([ordered]@{
        schema = "smr.ralph.checkpoint_watcher_ready.v1"
        candidate_base = $basePath
        watcher_pid = $PID
        started_utc = $started.ToUniversalTime().ToString("o")
    })
}
$deadline = $started.AddSeconds($TimeoutSeconds)
$rows = [Collections.Generic.List[object]]::new()

try {
    foreach ($checkpoint in @($reference.checkpoints)) {
        $candidate = $basePath + [string]$checkpoint.suffix
        $actual = $null
        while ($null -eq $actual) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $actual = Get-ReadyHash $candidate
                if ($null -ne $actual) { break }
            }
            $remaining = [math]::Ceiling(($deadline - (Get-Date)).TotalMilliseconds)
            if ($remaining -le 0) {
                Publish-Failure "timeout waiting for checkpoint" $rows ([ordered]@{
                    id = $checkpoint.id; path = $candidate; expected_sha256 = $checkpoint.sha256
                }) $started
            }
            $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, [int][math]::Min($remaining, [int]::MaxValue))
            if ($change.TimedOut) {
                Publish-Failure "timeout waiting for checkpoint" $rows ([ordered]@{
                    id = $checkpoint.id; path = $candidate; expected_sha256 = $checkpoint.sha256
                }) $started
            }
        }
        $matched = ($actual.bytes -eq [int64]$checkpoint.bytes -and
            $actual.sha256 -eq [string]$checkpoint.sha256)
        $row = [ordered]@{
            id = [string]$checkpoint.id
            suffix = [string]$checkpoint.suffix
            bytes = [int64]$actual.bytes
            sha256 = [string]$actual.sha256
            expected_bytes = [int64]$checkpoint.bytes
            expected_sha256 = [string]$checkpoint.sha256
            matched = $matched
        }
        $rows.Add($row)
        if ($Mode -eq "HashOnly") {
            Remove-Item -LiteralPath $candidate -Force
            $row.discarded_after_hash = $true
        } else {
            $row.discarded_after_hash = $false
        }
        if (-not $matched) {
            Publish-Failure "first checkpoint mismatch" $rows $row $started
        }
    }
    $aggregateRows = @($rows | ForEach-Object {
        [ordered]@{ id = $_.id; suffix = $_.suffix; bytes = $_.bytes; sha256 = $_.sha256 }
    }) | ConvertTo-Json -Depth 10 -Compress
    $aggregateBytes = [Text.Encoding]::UTF8.GetBytes($aggregateRows)
    $aggregateAlgorithm = [Security.Cryptography.SHA256]::Create()
    try { $aggregate = [Convert]::ToHexString($aggregateAlgorithm.ComputeHash($aggregateBytes)) }
    finally { $aggregateAlgorithm.Dispose() }
    $payload = [ordered]@{
        schema = $Schema
        ok = $true
        mode = $Mode
        candidate_observer_mode = $Mode
        reference_observer_mode = $ExpectedReferenceMode
        reference_observer_mode_inferred = $ReferenceModeInferred -eq "True"
        mode_matched_reference = $true
        event_driven = $true
        reason = "all ordered checkpoint hashes match"
        checked = $rows.Count
        checkpoints = @($rows)
        aggregate_sha256 = $aggregate
        elapsed_ms = [math]::Round(((Get-Date) - $started).TotalMilliseconds, 3)
        full_capture_retained = $Mode -eq "Full"
    }
    Write-JsonAtomic $Verdict $payload
    $payload | ConvertTo-Json -Depth 30
    exit 0
} finally {
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
}
