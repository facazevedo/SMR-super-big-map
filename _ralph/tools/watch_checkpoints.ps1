param(
    [Parameter(Mandatory = $true)][string]$ReferenceManifest,
    [Parameter(Mandatory = $true)][string]$CandidateBase,
    [Parameter(Mandatory = $true)][string]$Verdict,
    [string]$AbortSentinel = "",
    [string]$ReadySentinel = "",
    [ValidateSet("HashOnly", "Full")][string]$Mode = "HashOnly",
    [string]$ShadowRetentionDirectory = "",
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
        event_driven = $true
        reason = $Reason
        first_mismatch = $FirstMismatch
        checked = @($Rows).Count
        checkpoints = @($Rows)
        elapsed_ms = [math]::Round(((Get-Date) - $Started).TotalMilliseconds, 3)
    }
    if ($null -ne $script:shadowDirectory) {
        $payload.shadow_retention = $true
        $payload.shadow_retention_directory = $script:shadowDirectory
        $payload.retained_file_count = @($Rows | Where-Object { $_.moved_to_shadow }).Count
        $payload.full_capture_retained = $true
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
$basePath = [IO.Path]::GetFullPath($CandidateBase)
$directory = [IO.Path]::GetDirectoryName($basePath)
$prefix = [IO.Path]::GetFileName($basePath)
[IO.Directory]::CreateDirectory($directory) | Out-Null
$shadowDirectory = $null
if ($ShadowRetentionDirectory) {
    if ($Mode -ne "Full") {
        throw "shadow retention is valid only in Full mode"
    }
    $shadowDirectory = [IO.Path]::GetFullPath($ShadowRetentionDirectory)
    if ([string]::Equals($shadowDirectory, $directory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "shadow retention directory must differ from the candidate directory"
    }
    $candidateRoot = [IO.Path]::GetPathRoot($basePath)
    $shadowRoot = [IO.Path]::GetPathRoot($shadowDirectory)
    if (-not [string]::Equals($candidateRoot, $shadowRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "shadow retention directory must be on the candidate volume"
    }
    if (Test-Path -LiteralPath $shadowDirectory) {
        throw "shadow retention directory is not fresh: $shadowDirectory"
    }
    [IO.Directory]::CreateDirectory($shadowDirectory) | Out-Null
}
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
        } elseif ($null -ne $shadowDirectory) {
            $retained = Join-Path $shadowDirectory ([IO.Path]::GetFileName($candidate))
            [IO.File]::Move($candidate, $retained, $false)
            $row.discarded_after_hash = $false
            $row.moved_to_shadow = $true
            $row.retained_path = $retained
            $row.candidate_removed_after_hash = -not (Test-Path -LiteralPath $candidate)
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
        event_driven = $true
        reason = "all ordered checkpoint hashes match"
        checked = $rows.Count
        checkpoints = @($rows)
        aggregate_sha256 = $aggregate
        elapsed_ms = [math]::Round(((Get-Date) - $started).TotalMilliseconds, 3)
        full_capture_retained = $Mode -eq "Full"
    }
    if ($null -ne $shadowDirectory) {
        $payload.shadow_retention = $true
        $payload.shadow_retention_directory = $shadowDirectory
        $payload.retained_file_count = @($rows | Where-Object { $_.moved_to_shadow }).Count
    }
    Write-JsonAtomic $Verdict $payload
    $payload | ConvertTo-Json -Depth 30
    exit 0
} finally {
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
}
