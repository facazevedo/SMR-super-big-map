param(
    [string]$ContractPath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ContractSha256,
    [switch]$Launch,
    [switch]$SelfTest
)

# Reusable cold Surface acceptance executor.  The contract is deliberately content
# addressed: this file knows no iteration, version, candidate, or stage identity.
# A caller must pin every executable/staged input and the expected deployed hashes in
# its contract, then pass the contract's SHA-256 on the command line.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required file missing: $Path" }
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-Json([string]$Path, $Value) {
    Write-Utf8NoBom $Path (($Value | ConvertTo-Json -Depth 12) + "`n")
}

function Assert-ExactTokens([string]$Path, [string[]]$Tokens) {
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match '(?m)^probe_error=') { throw "evidence contains probe_error: $Path" }
    foreach ($token in @($Tokens)) {
        if ([string]::IsNullOrWhiteSpace($token)) { throw "empty required token in contract for $Path" }
        if ($text -notmatch ('(?m)^' + [regex]::Escape($token) + '$')) {
            throw "evidence missing exact token '$token': $Path"
        }
    }
    $text
}

function Get-UniqueInteger([string]$Text, [string]$Name) {
    $m = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($Name) + '=(?<v>-?\d+)$')
    if ($m.Count -ne 1) { throw "integer evidence missing/duplicate: $Name" }
    [Int64]$m[0].Groups['v'].Value
}

function Get-ScalarReceipt([string]$Text) {
    $values = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Length -eq 0) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { throw "malformed scalar receipt line: $line" }
        $name = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        if ($values.ContainsKey($name)) { throw "scalar receipt duplicate field: $name" }
        $values[$name] = $value
    }
    $values
}

function Get-ScalarText($Values, [string]$Name) {
    if (-not $Values.ContainsKey($Name)) { throw "scalar receipt missing/unknown field: $Name" }
    [string]$Values[$Name]
}

function Get-ScalarInteger($Values, [string]$Name) {
    $value = Get-ScalarText $Values $Name
    if ($value -notmatch '^-?\d+$') { throw "scalar receipt non-integer field: $Name" }
    [Int64]$value
}

function Get-ScalarBoolean($Values, [string]$Name) {
    $value = Get-ScalarText $Values $Name
    if ($value -ceq 'true') { return $true }
    if ($value -ceq 'false') { return $false }
    throw "scalar receipt non-boolean field: $Name"
}

function Assert-SurfaceSingleFlushScalar([string]$Text) {
    $values = Get-ScalarReceipt $Text
    $main = @(
        'surface_single_flush_requested', 'surface_single_flush_used', 'surface_single_flush_fallback', 'surface_single_flush_fallback_reason',
        'surface_single_flush_local_passability_calls', 'surface_single_flush_buildable_calls', 'surface_single_flush_height_snapshots',
        'surface_single_flush_height_mismatches', 'surface_single_flush_object_family_count', 'surface_single_flush_object_association_failures',
        'surface_single_flush_provenance_exact', 'surface_single_flush_dirty_digest', 'surface_single_flush_dirty_regions',
        'surface_single_flush_coverage_permille', 'surface_single_flush_closing_complete', 'surface_single_flush_cleanup_complete',
        'outer_passage_pad_finalization_dirty_digest', 'canonical_rebuilds_during_capsule_prepare',
        'canonical_rebuild_fallbacks_during_capsule_prepare', 'fresh_grid_first_rebuild_ms', 'fresh_grid_main_plan_ms', 'fresh_grid_replay_ms',
        'fresh_grid_publication_ms', 'fresh_grid_plan_replay_publication_ms', 'fresh_grid_closing_rebuild_ms',
        'fresh_grid_orchestration_total_ms', 'fresh_grid_phase_order', 'fresh_grid_expected_rebuilds',
        'fresh_grid_rebuild_shape_exact', 'fresh_grid_first_rebuild_complete', 'fresh_grid_closing_rebuild_complete'
    )
    $helper = @(
        'helper_schema', 'helper_requested', 'helper_used', 'helper_phase', 'helper_error', 'helper_fallback',
        'helper_provenance_exact', 'helper_dirty_digest', 'helper_regions', 'helper_terrain_cells', 'helper_coverage_permille',
        'helper_dependency_margin', 'helper_height_snapshots', 'helper_height_mismatches', 'helper_object_family_count',
        'helper_object_association_failures', 'helper_object_containment_failures', 'helper_passability_calls',
        'helper_buildable_calls', 'helper_preplan_complete', 'helper_closing_complete', 'helper_cleanup_complete'
    )
    $header = @(
        'schema', 'surface_stable_published', 'post_t1_only', 'pre_t1_capture_bytes', 'capture_status',
        'async_rand_draw_count', 'async_rand_dispatcher_restored', 'tuple', 'caller_fallback_reason', 'comparison_ms', 'proof_ms'
    )
    $allowed = @($header + $main + $helper | Select-Object -Unique)
    foreach ($name in $allowed) { [void](Get-ScalarText $values $name) }
    foreach ($name in $values.Keys) {
        if ($allowed -notcontains $name) { throw "scalar receipt unknown field: $name" }
    }
    if ((Get-ScalarText $values 'schema') -cne 'smr.ralph.surface_only_single_flush_scalar.v1' -or
        -not (Get-ScalarBoolean $values 'surface_stable_published') -or
        -not (Get-ScalarBoolean $values 'post_t1_only') -or
        (Get-ScalarInteger $values 'pre_t1_capture_bytes') -ne 0 -or
        (Get-ScalarText $values 'capture_status') -cne 'surface-only-none' -or
        -not (Get-ScalarBoolean $values 'async_rand_dispatcher_restored') -or
        (Get-ScalarInteger $values 'async_rand_draw_count') -le 0) {
        throw 'scalar receipt fixed post-T1 header is invalid'
    }
    if ((Get-ScalarInteger $values 'helper_schema') -ne 1 -or
        @('preplan', 'closing') -notcontains (Get-ScalarText $values 'helper_phase')) {
        throw 'scalar receipt helper schema/phase is unknown'
    }
    foreach ($name in @('surface_single_flush_requested', 'surface_single_flush_used', 'surface_single_flush_fallback',
            'surface_single_flush_provenance_exact', 'surface_single_flush_closing_complete', 'surface_single_flush_cleanup_complete',
            'fresh_grid_rebuild_shape_exact', 'fresh_grid_first_rebuild_complete', 'fresh_grid_closing_rebuild_complete',
            'helper_requested', 'helper_used', 'helper_fallback', 'helper_provenance_exact', 'helper_preplan_complete',
            'helper_closing_complete', 'helper_cleanup_complete')) { [void](Get-ScalarBoolean $values $name) }
    foreach ($name in @('surface_single_flush_local_passability_calls', 'surface_single_flush_buildable_calls',
            'surface_single_flush_height_snapshots', 'surface_single_flush_height_mismatches', 'surface_single_flush_object_family_count',
            'surface_single_flush_object_association_failures', 'surface_single_flush_dirty_digest', 'surface_single_flush_dirty_regions',
            'surface_single_flush_coverage_permille', 'outer_passage_pad_finalization_dirty_digest',
            'canonical_rebuilds_during_capsule_prepare', 'canonical_rebuild_fallbacks_during_capsule_prepare',
            'fresh_grid_first_rebuild_ms', 'fresh_grid_main_plan_ms', 'fresh_grid_replay_ms', 'fresh_grid_publication_ms',
            'fresh_grid_plan_replay_publication_ms', 'fresh_grid_closing_rebuild_ms', 'fresh_grid_orchestration_total_ms',
            'fresh_grid_expected_rebuilds', 'helper_schema', 'helper_dirty_digest', 'helper_regions', 'helper_terrain_cells',
            'helper_coverage_permille', 'helper_dependency_margin', 'helper_height_snapshots', 'helper_height_mismatches',
            'helper_object_family_count', 'helper_object_association_failures', 'helper_object_containment_failures',
            'helper_passability_calls', 'helper_buildable_calls', 'comparison_ms', 'proof_ms')) {
        if ((Get-ScalarInteger $values $name) -lt 0) { throw "scalar receipt negative field: $name" }
    }
    # Mandatory f+h safety facts precede branch selection.  A fallback may choose
    # canonical grids, but it must never turn an incomplete local certificate into
    # an acceptable receipt or conceal contradictory helper telemetry.
    $commonSafety = (Get-ScalarBoolean $values 'surface_single_flush_requested') -and
        (Get-ScalarBoolean $values 'surface_single_flush_provenance_exact') -and
        (Get-ScalarInteger $values 'surface_single_flush_height_snapshots') -eq 2 -and
        (Get-ScalarInteger $values 'surface_single_flush_height_mismatches') -eq 0 -and
        (Get-ScalarInteger $values 'surface_single_flush_object_family_count') -eq 6 -and
        (Get-ScalarInteger $values 'surface_single_flush_object_association_failures') -eq 0 -and
        (Get-ScalarInteger $values 'surface_single_flush_dirty_digest') -eq (Get-ScalarInteger $values 'outer_passage_pad_finalization_dirty_digest') -and
        (Get-ScalarInteger $values 'surface_single_flush_dirty_regions') -eq 2 -and
        (Get-ScalarInteger $values 'surface_single_flush_coverage_permille') -ge 1 -and
        (Get-ScalarInteger $values 'surface_single_flush_coverage_permille') -le 150 -and
        (Get-ScalarBoolean $values 'surface_single_flush_closing_complete') -and
        (Get-ScalarBoolean $values 'surface_single_flush_cleanup_complete') -and
        (Get-ScalarBoolean $values 'helper_requested') -and
        (Get-ScalarBoolean $values 'helper_provenance_exact') -and
        (Get-ScalarInteger $values 'helper_regions') -eq 2 -and
        (Get-ScalarInteger $values 'helper_dirty_digest') -eq (Get-ScalarInteger $values 'surface_single_flush_dirty_digest') -and
        (Get-ScalarInteger $values 'helper_coverage_permille') -ge 1 -and
        (Get-ScalarInteger $values 'helper_coverage_permille') -le 150 -and
        (Get-ScalarInteger $values 'helper_height_snapshots') -eq 2 -and
        (Get-ScalarInteger $values 'helper_height_mismatches') -eq 0 -and
        (Get-ScalarInteger $values 'helper_object_family_count') -eq 6 -and
        (Get-ScalarInteger $values 'helper_object_association_failures') -eq 0 -and
        (Get-ScalarInteger $values 'helper_object_containment_failures') -eq 0 -and
        (Get-ScalarInteger $values 'helper_passability_calls') -eq 2 -and
        (Get-ScalarInteger $values 'helper_buildable_calls') -eq 1 -and
        (Get-ScalarBoolean $values 'helper_cleanup_complete')
    if (-not $commonSafety) { throw 'scalar receipt common f+h safety invariant failed' }
    $optimized = (Get-ScalarBoolean $values 'surface_single_flush_requested') -and
        (Get-ScalarBoolean $values 'surface_single_flush_used') -and -not (Get-ScalarBoolean $values 'surface_single_flush_fallback') -and
        (Get-ScalarBoolean $values 'surface_single_flush_provenance_exact') -and
        (Get-ScalarInteger $values 'surface_single_flush_local_passability_calls') -eq 4 -and
        (Get-ScalarInteger $values 'surface_single_flush_buildable_calls') -eq 2 -and
        (Get-ScalarInteger $values 'surface_single_flush_height_snapshots') -eq 2 -and
        (Get-ScalarInteger $values 'surface_single_flush_height_mismatches') -eq 0 -and
        (Get-ScalarInteger $values 'surface_single_flush_object_family_count') -eq 6 -and
        (Get-ScalarInteger $values 'surface_single_flush_object_association_failures') -eq 0 -and
        (Get-ScalarInteger $values 'helper_object_containment_failures') -eq 0 -and
        (Get-ScalarInteger $values 'surface_single_flush_dirty_digest') -eq (Get-ScalarInteger $values 'outer_passage_pad_finalization_dirty_digest') -and
        (Get-ScalarInteger $values 'surface_single_flush_dirty_regions') -eq 2 -and
        (Get-ScalarInteger $values 'surface_single_flush_coverage_permille') -ge 1 -and
        (Get-ScalarInteger $values 'surface_single_flush_coverage_permille') -le 150 -and
        (Get-ScalarBoolean $values 'surface_single_flush_closing_complete') -and (Get-ScalarBoolean $values 'surface_single_flush_cleanup_complete') -and
        (Get-ScalarInteger $values 'canonical_rebuilds_during_capsule_prepare') -eq 0 -and
        (Get-ScalarInteger $values 'canonical_rebuild_fallbacks_during_capsule_prepare') -eq 0 -and
        (Get-ScalarInteger $values 'fresh_grid_expected_rebuilds') -eq 0 -and
        (Get-ScalarBoolean $values 'fresh_grid_rebuild_shape_exact') -and (Get-ScalarBoolean $values 'fresh_grid_first_rebuild_complete') -and
        (Get-ScalarBoolean $values 'fresh_grid_closing_rebuild_complete') -and
        (Get-ScalarBoolean $values 'helper_used') -and -not (Get-ScalarBoolean $values 'helper_fallback') -and
        (Get-ScalarText $values 'helper_error') -ceq '' -and (Get-ScalarText $values 'helper_phase') -ceq 'closing' -and
        (Get-ScalarBoolean $values 'helper_preplan_complete') -and (Get-ScalarBoolean $values 'helper_closing_complete') -and
        (Get-ScalarText $values 'surface_single_flush_fallback_reason') -ceq '' -and
        (Get-ScalarText $values 'fresh_grid_phase_order') -ceq 'local-dirty-grid-publication>fresh-plan-replay>capsule-publication>local-dirty-closing'
    $canonical = (Get-ScalarBoolean $values 'surface_single_flush_requested') -and
        -not (Get-ScalarBoolean $values 'surface_single_flush_used') -and (Get-ScalarBoolean $values 'surface_single_flush_fallback') -and
        -not [string]::IsNullOrEmpty((Get-ScalarText $values 'surface_single_flush_fallback_reason')) -and
        (Get-ScalarInteger $values 'canonical_rebuilds_during_capsule_prepare') -ge 1 -and
        (Get-ScalarInteger $values 'canonical_rebuilds_during_capsule_prepare') -le 2 -and
        (Get-ScalarInteger $values 'canonical_rebuild_fallbacks_during_capsule_prepare') -eq 0 -and
        (Get-ScalarInteger $values 'fresh_grid_expected_rebuilds') -eq (Get-ScalarInteger $values 'canonical_rebuilds_during_capsule_prepare') -and
        (Get-ScalarBoolean $values 'fresh_grid_rebuild_shape_exact') -and (Get-ScalarBoolean $values 'fresh_grid_first_rebuild_complete') -and
        (Get-ScalarBoolean $values 'fresh_grid_closing_rebuild_complete') -and
        -not (Get-ScalarBoolean $values 'helper_used') -and -not (Get-ScalarBoolean $values 'helper_fallback') -and
        -not [string]::IsNullOrEmpty((Get-ScalarText $values 'helper_error')) -and
        (Get-ScalarText $values 'helper_error').Length -le 512 -and
        (Get-ScalarText $values 'helper_error') -ceq (Get-ScalarText $values 'surface_single_flush_fallback_reason') -and
        -not (Get-ScalarBoolean $values 'helper_closing_complete') -and
        (((Get-ScalarText $values 'helper_phase') -ceq 'preplan' -and -not (Get-ScalarBoolean $values 'helper_preplan_complete')) -or
         ((Get-ScalarText $values 'helper_phase') -ceq 'closing' -and (Get-ScalarBoolean $values 'helper_preplan_complete'))) -and
        (Get-ScalarText $values 'fresh_grid_phase_order') -ceq 'canonical-grid-publication>fresh-plan-replay>capsule-publication>closing-rebuild'
    if ($optimized -eq $canonical) { throw 'scalar receipt tuple is missing, ambiguous, or invalid' }
    $tuple = if ($optimized) { 'optimized' } else { 'canonical-fallback' }
    if ((Get-ScalarText $values 'tuple') -cne $tuple) { throw 'scalar receipt declared tuple does not match exact validator' }
    if ((Get-ScalarText $values 'caller_fallback_reason') -ne (Get-ScalarText $values 'surface_single_flush_fallback_reason') -or
        (Get-ScalarInteger $values 'comparison_ms') -ne (Get-ScalarInteger $values 'fresh_grid_plan_replay_publication_ms') -or
        (Get-ScalarInteger $values 'proof_ms') -ne (Get-ScalarInteger $values 'fresh_grid_orchestration_total_ms')) {
        throw 'scalar receipt helper/caller/comparison proof aliases are inconsistent'
    }
    [ordered]@{ tuple = $tuple; comparison_ms = Get-ScalarInteger $values 'comparison_ms'; proof_ms = Get-ScalarInteger $values 'proof_ms' }
}

function Wait-NonEmptyFile([string]$Path, [DateTime]$DeadlineUtc, [Diagnostics.Process]$TrackedProcess) {
    $directory = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "watch directory missing: $directory" }
    $watcher = New-Object IO.FileSystemWatcher $directory, $leaf
    $watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    $watcher.EnableRaisingEvents = $true
    $TrackedProcess.EnableRaisingEvents = $true
    $nonce = [Guid]::NewGuid().ToString('N')
    $changedId = "smr.surface.wait.$nonce.changed"
    $createdId = "smr.surface.wait.$nonce.created"
    $renamedId = "smr.surface.wait.$nonce.renamed"
    $exitId = "smr.surface.wait.$nonce.exited"
    $sourceIds = @($changedId, $createdId, $renamedId, $exitId)
    $fileSubscription = Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier $changedId
    $createdSubscription = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier $createdId
    $renamedSubscription = Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier $renamedId
    $exitSubscription = Register-ObjectEvent -InputObject $TrackedProcess -EventName Exited -SourceIdentifier $exitId
    try {
        while ([DateTime]::UtcNow -lt $DeadlineUtc) {
            # The only wait races filesystem sentinel events with the exact tracked
            # process Exited event.  There is no fixed polling interval.
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                try {
                    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'None')
                    try { if ($stream.Length -gt 0) { return } } finally { $stream.Dispose() }
                } catch [IO.IOException] {}
            }
            if ($TrackedProcess.HasExited) { throw "tracked MarsDebug exited before sentinel: $Path" }
            $remaining = [Math]::Max(1, [Math]::Ceiling(($DeadlineUtc - [DateTime]::UtcNow).TotalSeconds))
            # Windows PowerShell 5.1 accepts one SourceIdentifier only.  Wait on
            # the event queue, then accept only this call's globally unique IDs.
            $event = Wait-Event -Timeout ([int]$remaining)
            if ($event) {
                if ($event.SourceIdentifier -eq $exitId) {
                    Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
                    throw "tracked MarsDebug exited before sentinel: $Path"
                }
                if ($sourceIds -contains $event.SourceIdentifier) {
                    Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
                }
            }
        }
    } finally {
        # Registration can return null under PS5 event races.  Source IDs are unique,
        # so query the subscriber table directly and clean every matching entry.
        foreach ($sourceId in $sourceIds) {
            foreach ($subscription in @(Get-EventSubscriber -SourceIdentifier $sourceId -ErrorAction SilentlyContinue)) {
                Unregister-Event -SubscriptionId $subscription.SubscriptionId -ErrorAction SilentlyContinue
            }
            foreach ($queued in @(Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue)) {
                Remove-Event -EventIdentifier $queued.EventIdentifier -ErrorAction SilentlyContinue
            }
        }
        $watcher.Dispose()
    }
    throw "timeout waiting for $Path"
}

function New-MarsDebugStartWatcher() {
    try {
        $watcher = New-Object Management.ManagementEventWatcher(
            "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'MarsDebug.exe'")
        $watcher.Start()
        $watcher
    } catch {
        throw "MarsDebug start watcher unavailable: $($_.Exception.Message)"
    }
}

function Wait-NewMarsDebugProcess($Watcher, [DateTime]$StartedUtc, [DateTime]$DeadlineUtc) {
    # A single post-start snapshot closes the watcher-registration race; all later
    # waiting is WMI process-start event driven, never interval polling.
    $existing = @(Get-Process -Name MarsDebug -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime.ToUniversalTime() -ge $StartedUtc })
    if ($existing.Count -eq 1) { return $existing[0] }
    if ($existing.Count -gt 1) { throw 'more than one newly-created MarsDebug process observed' }
    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        $remaining = [Math]::Max(1, [Math]::Ceiling(($DeadlineUtc - [DateTime]::UtcNow).TotalSeconds))
        try { $event = $Watcher.WaitForNextEvent([TimeSpan]::FromSeconds([int]$remaining)) }
        catch [Management.ManagementException] { break }
        if ($null -eq $event) { break }
        $pid = [int]$event.NewEvent.ProcessID
        try {
            $candidate = Get-Process -Id $pid -ErrorAction Stop
            if ($candidate.ProcessName -ceq 'MarsDebug' -and $candidate.StartTime.ToUniversalTime() -ge $StartedUtc) {
                return $candidate
            }
        } catch [System.ArgumentException] {}
    }
    throw 'new MarsDebug process identity was not captured by bounded process-start wait'
}

function Test-TcpPortClosed([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(250)) { return $true }
        $client.EndConnect($async)
        $false
    } catch { $true } finally { $client.Dispose() }
}

function Get-ProcessIdentity([Diagnostics.Process]$Process) {
    [ordered]@{
        pid = $Process.Id
        process_name = $Process.ProcessName
        creation_time_utc_ticks = $Process.StartTime.ToUniversalTime().Ticks
        executable_path = $Process.Path
    }
}

function Test-ExactProcessIdentity($Identity) {
    try {
        $p = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop
        $actual = Get-ProcessIdentity $p
        $actual.process_name -ceq $Identity.process_name -and
            $actual.creation_time_utc_ticks -eq $Identity.creation_time_utc_ticks -and
            [string]::Equals($actual.executable_path, $Identity.executable_path, [StringComparison]::OrdinalIgnoreCase)
    } catch { $false }
}

function Stop-ExactProcess($Identity) {
    if (-not (Test-ExactProcessIdentity $Identity)) { return $true }
    $p = Get-Process -Id ([int]$Identity.pid) -ErrorAction Stop
    Stop-Process -Id $p.Id -Force
    Start-Sleep -Milliseconds 250
    -not (Test-ExactProcessIdentity $Identity)
}

function Invoke-Harness([string[]]$Arguments) {
    & python $script:Harness @Arguments
    if ($LASTEXITCODE -ne 0) { throw "harness command failed ($LASTEXITCODE): $($Arguments -join ' ')" }
}

function Assert-DeployAudit([bool]$Enabled) {
    $raw = (& python "$script:Repo\_ralph\tools\deploy.py" audit 2>&1) -join "`n"
    $exit = $LASTEXITCODE
    $audit = $raw | ConvertFrom-Json
    $countOk = $audit.source_files -eq $script:Contract.expected_deploy_file_count -and
        $audit.destination_files -eq $script:Contract.expected_deploy_file_count
    if ($Enabled) {
        $mismatches = @($audit.content_mismatch)
        if ($exit -ne 1 -or -not $countOk -or $mismatches.Count -ne 1 -or
            $mismatches[0] -cne $script:Contract.deployed_config_repo_relative) {
            throw 'enabled deployment audit is not exactly the pinned one-config delta'
        }
    } elseif ($exit -ne 0 -or -not $audit.ok -or -not $countOk) {
        throw 'restored deployment audit is not exact'
    }
}

function Stop-TrackedGame([string]$Reason) {
    $script:trackedQuitAttempted = $true
    if ($script:TrackedIdentity -and -not (Test-ExactProcessIdentity $script:TrackedIdentity) -and (Test-TcpPortClosed 8165)) {
        $script:trackedQuitSucceeded = $true
        return
    }
    & python $script:Harness quit --json --timeout 10 | Out-Host
    if ($LASTEXITCODE -eq 0 -and $script:TrackedIdentity -and -not (Test-ExactProcessIdentity $script:TrackedIdentity) -and (Test-TcpPortClosed 8165)) {
        $script:trackedQuitSucceeded = $true
        return
    }
    if ($script:TrackedIdentity -and (Stop-ExactProcess $script:TrackedIdentity) -and (Test-TcpPortClosed 8165)) {
        $script:trackedQuitSucceeded = $true
        return
    }
    throw "tracked quit/identity fallback failed: $Reason"
}

function Invoke-WaitLifecycleSelfTest {
    # PS5-only runtime proof for the exact subscription implementation above.  It
    # uses this PowerShell process as the non-exiting tracked process; no daemon,
    # game, deploy, or harness call is involved.
    $before = @((Get-EventSubscriber -ErrorAction SilentlyContinue)).Count
    $root = Join-Path ([IO.Path]::GetTempPath()) ("smr_surface_wait_" + [Guid]::NewGuid().ToString('N'))
    $deferred = Join-Path $root 'deferred.txt'
    $census = Join-Path $root 'census.txt'
    $writer = $null
    $firstReturnedBeforeCensus = $false
    $timedOut = $false
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $writer = Start-Job -ScriptBlock {
            param($DeferredPath, $CensusPath)
            Start-Sleep -Milliseconds 300
            [IO.File]::WriteAllText($DeferredPath, 'deferred' + [Environment]::NewLine)
            Start-Sleep -Milliseconds 800
            [IO.File]::WriteAllText($CensusPath, 'census' + [Environment]::NewLine)
        } -ArgumentList $deferred, $census
        $self = Get-Process -Id $PID -ErrorAction Stop
        Wait-NonEmptyFile $deferred ([DateTime]::UtcNow.AddSeconds(10)) $self
        $firstReturnedBeforeCensus = -not (Test-Path -LiteralPath $census -PathType Leaf)
        Wait-NonEmptyFile $census ([DateTime]::UtcNow.AddSeconds(10)) $self
        try {
            Wait-NonEmptyFile (Join-Path $root 'never-arrives.txt') ([DateTime]::UtcNow.AddMilliseconds(100)) $self
        } catch { $timedOut = $_.Exception.Message -like 'timeout waiting for*' }
        Wait-Job -Job $writer -Timeout 5 | Out-Null
        Receive-Job -Job $writer -ErrorAction Stop | Out-Null
        if (-not $firstReturnedBeforeCensus -or -not $timedOut) {
            throw 'delayed sentinel ordering or timeout race self-test failed'
        }
    } finally {
        if ($writer) { Remove-Job -Job $writer -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    $after = @((Get-EventSubscriber -ErrorAction SilentlyContinue)).Count
    if ($after -ne $before) { throw "event subscriber leak: before=$before after=$after" }
    [ordered]@{
        schema = 'smr.ralph.surface-only-wait-lifecycle-selftest.v1'
        ok = $true
        subscriber_count_before = $before
        subscriber_count_after = $after
        deferred_returned_before_census = $firstReturnedBeforeCensus
        timeout_race_rejected = $timedOut
    } | ConvertTo-Json -Compress
}

if ($SelfTest) {
    Invoke-WaitLifecycleSelfTest
    return
}
if ([string]::IsNullOrWhiteSpace($ContractPath) -or [string]::IsNullOrWhiteSpace($ContractSha256)) {
    throw 'ContractPath and ContractSha256 are required unless -SelfTest is used'
}

if ((Get-Sha256 $ContractPath) -cne $ContractSha256.ToUpperInvariant()) { throw 'contract SHA-256 mismatch' }
$script:Contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
if ($script:Contract.schema -cne 'smr.ralph.surface-only-acceptance-contract.v1') { throw 'unsupported surface-only contract schema' }
if ([double]$script:Contract.maximum_t0_to_t1_ms -ne 100000.0) {
    throw 'surface-only contract must pin the strict <100000ms timing boundary'
}
foreach ($name in @('repo', 'stage', 'run', 'harness', 'source_config', 'deployed_config', 'deployed_config_repo_relative', 'enabled_config',
        'generator_script', 'surface_t1_file', 'deferred_t1_file', 'scheduler_census_file', 'post_t1_scalar_file',
        'expected_disabled_config_sha256', 'expected_enabled_config_sha256', 'expected_deploy_file_count',
        't1_timeout_seconds', 'maximum_t0_to_t1_ms', 'stage_files', 'required_surface_t1_tokens',
        'required_deferred_t1_tokens', 'required_scheduler_census_tokens', 'allowed_initial_run_files',
        'executor_sha256')) {
    if ($null -eq $script:Contract.$name) { throw "contract missing required field: $name" }
}

$script:Repo = [IO.Path]::GetFullPath([string]$script:Contract.repo)
$script:Stage = [IO.Path]::GetFullPath([string]$script:Contract.stage)
$script:Run = [IO.Path]::GetFullPath([string]$script:Contract.run)
$script:Harness = [IO.Path]::GetFullPath([string]$script:Contract.harness)
$SourceConfig = [IO.Path]::GetFullPath([string]$script:Contract.source_config)
$DeployedConfig = [IO.Path]::GetFullPath([string]$script:Contract.deployed_config)
$EnabledConfig = Join-Path $script:Stage ([string]$script:Contract.enabled_config)
$Generator = Join-Path $script:Stage ([string]$script:Contract.generator_script)
$SurfaceT1 = Join-Path $script:Run ([string]$script:Contract.surface_t1_file)
$DeferredT1 = Join-Path $script:Run ([string]$script:Contract.deferred_t1_file)
$Census = Join-Path $script:Run ([string]$script:Contract.scheduler_census_file)
$PostT1Scalar = Join-Path $script:Run ([string]$script:Contract.post_t1_scalar_file)
$Receipt = Join-Path $script:Run 'surface_only_acceptance_receipt.json'
$Timing = Join-Path $script:Run 'external_timing.json'
$TrackedReceipt = Join-Path $script:Run 'tracked_mars_process_identity.json'

if (-not (Test-Path -LiteralPath $script:Repo -PathType Container) -or
    -not (Test-Path -LiteralPath $script:Stage -PathType Container) -or
    -not (Test-Path -LiteralPath $script:Run -PathType Container)) { throw 'repo/stage/run path missing' }
if (-not (Test-Path -LiteralPath $script:Harness -PathType Leaf)) { throw 'harness path missing' }
if ((Get-Sha256 $PSCommandPath) -cne ([string]$script:Contract.executor_sha256).ToUpperInvariant()) { throw 'surface-only executor hash mismatch' }
if ((Get-Sha256 $SourceConfig) -cne ([string]$script:Contract.expected_disabled_config_sha256).ToUpperInvariant()) { throw 'source disabled config hash mismatch' }
if ((Get-Sha256 $EnabledConfig) -cne ([string]$script:Contract.expected_enabled_config_sha256).ToUpperInvariant()) { throw 'staged enabled config hash mismatch' }
foreach ($entry in $script:Contract.stage_files.psobject.Properties) {
    $path = Join-Path $script:Stage $entry.Name
    if ((Get-Sha256 $path) -cne ([string]$entry.Value).ToUpperInvariant()) { throw "stage input hash mismatch: $($entry.Name)" }
}
$actualInitial = @(Get-ChildItem -LiteralPath $script:Run -File | ForEach-Object Name | Sort-Object)
$allowedInitial = @($script:Contract.allowed_initial_run_files | ForEach-Object { [string]$_ } | Sort-Object)
$topologyDifference = @(Compare-Object $actualInitial $allowedInitial -CaseSensitive)
if ($topologyDifference.Count -ne 0) { throw 'run directory is not the exact fresh content-addressed topology' }
foreach ($path in @($SurfaceT1, $DeferredT1, $Census, $PostT1Scalar, $Timing, $Receipt, $TrackedReceipt)) {
    if (Test-Path -LiteralPath $path) { throw "stale surface-only output exists: $path" }
}

# Structural safety rule: this executor has one sole run-file (the surface generator).
# The only harness call permitted after that point is the tracked quit in Stop-TrackedGame.

if (-not $Launch) {
    Write-Output 'SURFACE_ONLY_ACCEPTANCE_PREFLIGHT_OK'
    return
}

$status = & python $script:Harness daemon status --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'game already running; cold-run precondition failed' }
if (@(Get-Process -Name MarsDebug -ErrorAction SilentlyContinue).Count -ne 0) { throw 'MarsDebug already exists; exact cold ownership unavailable' }

$script:TrackedIdentity = $null
$script:TrackedProcess = $null
$script:trackedQuitAttempted = $false
$script:trackedQuitSucceeded = $false
$daemonStartAttempted = $false
$failures = New-Object 'System.Collections.Generic.List[string]'
try {
    Copy-Item -LiteralPath $EnabledConfig -Destination $DeployedConfig -Force
    Assert-DeployAudit $true
    if ((Get-Sha256 $DeployedConfig) -cne ([string]$script:Contract.expected_enabled_config_sha256).ToUpperInvariant()) { throw 'enabled deployed config hash mismatch' }

    $processStartWatcher = New-MarsDebugStartWatcher
    try {
        $daemonStartAttempted = $true
        $startedUtc = [DateTime]::UtcNow
        Invoke-Harness @('daemon', 'start', '--json', '--hidden', '--timeout', '300')
        $script:TrackedProcess = Wait-NewMarsDebugProcess $processStartWatcher $startedUtc ([DateTime]::UtcNow.AddSeconds(30))
        $script:TrackedIdentity = Get-ProcessIdentity $script:TrackedProcess
    } finally {
        $processStartWatcher.Stop()
        $processStartWatcher.Dispose()
    }
    Write-Json $TrackedReceipt ([ordered]@{ schema = 'smr.ralph.surface-only-tracked-process.v1'; identity = $script:TrackedIdentity })

    # T0 is immediately before the only harness run-file. No operation after this line
    # may invoke the harness except tracked quit.
    # Stopwatch ticks are the sole authoritative external timing clock.  UTC is
    # retained only as correlatable metadata and never participates in acceptance.
    $timingFrequency = [Diagnostics.Stopwatch]::Frequency
    if ($timingFrequency -le 0) { throw 'Stopwatch frequency is unavailable' }
    $t0Utc = [DateTime]::UtcNow
    [Int64]$t0Timestamp = [Diagnostics.Stopwatch]::GetTimestamp()
    Invoke-Harness @('run-file', '--json', '--timeout', '30', $Generator)
    $t1Deadline = $t0Utc.AddSeconds([int]$script:Contract.t1_timeout_seconds)
    Wait-NonEmptyFile $SurfaceT1 $t1Deadline $script:TrackedProcess
    [Int64]$t1Timestamp = [Diagnostics.Stopwatch]::GetTimestamp()
    $t1Utc = [DateTime]::UtcNow
    $elapsedMs = [Math]::Round((([double]($t1Timestamp - $t0Timestamp) * 1000.0) / [double]$timingFrequency), 4)
    if ($elapsedMs -ge 100000.0) { throw "Surface T0-to-T1 strict <100000ms budget exceeded: $elapsedMs ms" }
    # Deferred proof and the observer census are separate atomic post-T1 files.
    # Wait for each with the same process-exit race before any content validation.
    $postT1EvidenceDeadline = [DateTime]::UtcNow.AddSeconds(120)
    Wait-NonEmptyFile $DeferredT1 $postT1EvidenceDeadline $script:TrackedProcess
    Wait-NonEmptyFile $Census $postT1EvidenceDeadline $script:TrackedProcess

    # These are the invariant portion of the iter241 Surface T1/Close-ready
    # verifier.  Contracts may add candidate-specific values, but cannot relax this
    # baseline.  In particular, all map-2 creation/materialization is still absent.
    $baselineSurfaceTokens = @(
        'rough_terrain_at_generation_start=true', 'rough_terrain_at_t1=true',
        'selected_random_map_preset=RoughTerrain', 'surface_stretch_done=true',
        'surface_expansion_pending=false', 'stretch_pipeline_pending=false',
        'post_pipeline_revalidation_complete=true', 'expansion_loading_visible=false',
        'passage_mode=deferred-unallocated', 'lazy_underground_deferred_certificate=true',
        'maps2_absent=true', 'underground_map_absent=true', 'surface_capsules=2',
        'no_background_generation=true'
    )
    $baselineDeferredTokens = @(
        'ok=true', 'mode=deferred-unallocated', 'maps2_absent=true', 'underground_map_absent=true',
        'capsules=2', 'capsules_published=2', 'unlinked=2', 'exact_positions=2',
        'engine_valid_passages=2', 'markers=2', 'signs=2', 'companion_associations_exact=true',
        'published_capsule_certificate=true', 'descriptor_primitive=true',
        'descriptor_state=ready-for-first-access', 'generation_count=0', 'materialization_attempts=0',
        'implementation=true', 'suppression_committed=true', 'suppression_used=true',
        'literal_eager=false', 'report_ready=true', 'final_grid=true', 'deterministic_repeat=true',
        'digest_exact=true', 'recipe_capture_complete=true', 'native_retention_released=true',
        'route_gates=true', 'no_transient_binding=true', 'no_pending_restore_tokens=true',
        'captured_before_surface_t1_sentinel=true', 'persisted_state_live_reentry_allowed=true',
        'persisted_state_live_reentry_phase=closing-canonical-rebuild',
        'persisted_state_live_reentry_count=2',
        'persisted_state_live_reentry_phase_sequence=pre-surface-pipeline>closing-canonical-rebuild',
        'persisted_state_live_reentry_contract=true', 'persisted_state_materialization_reentry_allowed=false',
        'persisted_state_materialization_reentry_count=0', 'persisted_state_materialization_reentry_phase=',
        'persisted_state_materialization_reentry_phase_sequence=',
        'materialization_reentry_certificate_phase=t1-pre-access', 'materialization_reentry_not_applicable=true',
        'failure_sticky=false', 'planner_contract=true', 'planner_requested=true', 'planner_used=true',
        'planner_bounded_requested=true', 'planner_bounded_used=true', 'planner_stock_requested=false',
        'planner_stock_used=false', 'planner_stock_after_canonical_grid=true',
        'planner_main_attempt_contract=true', 'planner_repeat_attempt_contract=true',
        'planner_finite_capsule_tuples=2', 'planner_publication_validation_calls=2',
        'planner_publication_validation_exact_centers=2', 'planner_publication_validation_depth=0',
        'planner_replay_validation_identity_pinned=true', 'planner_replay_publication_validation_calls=0',
        'planner_full_search_cap=0', 'planner_repeat_full_search_cap=0',
        'planner_full_search_calls=0', 'planner_repeat_full_search_calls=0',
        'planner_unbounded_search_calls=0', 'planner_total_unbounded_calls=0',
        'planner_bounded_search_calls=0', 'planner_repeat_bounded_search_calls=0',
        'planner_full_search_mismatches=0', 'planner_zero_search_path=true',
        'planner_stock_trace_invalid=0', 'planner_stock_trace_selected=0',
        'planner_stock_trace_no_result=0', 'planner_stock_trace_rejected=0', 'planner_stock_trace_rows=0',
        'planner_trace_contract=true', 'planner_ild_balance=true', 'planner_stock_pause_requested=false',
        'planner_stock_pause_used=false', 'planner_stock_resume_ok=false',
        'planner_publication_rollback_residuals=0', 'planner_publication_object_shape_exact=true',
        'planner_stale_attempts=0', 'planner_stale_bounded_search_calls=0',
        'planner_stale_bounded_search_ms=0', 'planner_stale_plan_skipped=true',
        'planner_retry_requested=false', 'planner_retry_pending=false', 'planner_retry_used=false',
        'planner_retry_rebuild_consistent=true', 'planner_fresh_grid_requested=true',
        'planner_fresh_grid_used=true', 'planner_fresh_grid_plan_used=true',
        'planner_fresh_grid_main_plan_invocations=1',
        'planner_fresh_grid_replay_invocations=1',
        'planner_marker_contract=true',
        'planner_marker_index_requested=false', 'planner_marker_index_used=false',
        'planner_marker_index_fallback=false', 'planner_marker_exclusion_exact=true',
        'planner_repeat_marker_index_used=false', 'planner_repeat_marker_index_fallback=false',
        'planner_repeat_marker_exclusion_exact=true', 'planner_private_draws_per_attempt=3',
        'planner_private_draws_exact=true', 'planner_private_state_exact=true',
        'planner_outer_passage_contract=true', 'planner_outer_passage_direct_sampling=true',
        'planner_outer_passage_attempt_cap=32', 'planner_outer_passage_viable_target=4',
        'planner_outer_passage_viable=8', 'planner_outer_passage_replay_viable=8',
        'planner_outer_passage_replay_exact=true', 'outer_passage_report_present=true',
        'outer_passage_requested=true', 'outer_passage_used=true', 'outer_passage_pads=2',
        'outer_passage_attempt_cap=32', 'outer_passage_viable_target=4',
        'outer_passage_direct_sampling=true', 'outer_passage_viable=8', 'outer_passage_replay_viable=8',
        'outer_passage_replay_exact=true', 'outer_passage_patches=2', 'outer_passage_native_used=true',
        'outer_passage_native_fallback=false', 'outer_passage_native_error=',
        'outer_passage_inner_no_write=true', 'outer_passage_all_changed_outer=true',
        'outer_passage_install_rollback_attempted=false', 'outer_passage_install_rollback_completed=false',
        'outer_passage_install_rollback_verified=false', 'outer_passage_install_rollback_mismatches=-1',
        'outer_passage_report_error=', 'validation_z_count=2', 'validation_z_range_exact=true',
        'validation_z_report_certificates=2', 'validation_z_certificate_exact=true'
    )
    $surfaceText = Assert-ExactTokens $SurfaceT1 @($baselineSurfaceTokens + @($script:Contract.required_surface_t1_tokens))
    $deferredText = Assert-ExactTokens $DeferredT1 @($baselineDeferredTokens + @($script:Contract.required_deferred_t1_tokens))
    $censusText = Assert-ExactTokens $Census @($script:Contract.required_scheduler_census_tokens)
    Wait-NonEmptyFile $PostT1Scalar ([DateTime]::UtcNow.AddSeconds(120)) $script:TrackedProcess
    $postT1ScalarText = Get-Content -LiteralPath $PostT1Scalar -Raw
    $singleFlush = Assert-SurfaceSingleFlushScalar $postT1ScalarText
    foreach ($mustBeZero in @('generation_count', 'materialization_attempts')) {
        if ((Get-UniqueInteger $deferredText $mustBeZero) -ne 0) { throw "$mustBeZero is nonzero before surface-only quit" }
    }
    foreach ($mustBePositive in @('planner_attempts', 'planner_outer_passage_attempts', 'planner_outer_passage_plan_digest')) {
        if ((Get-UniqueInteger $deferredText $mustBePositive) -le 0) { throw "$mustBePositive is not positive" }
    }
    foreach ($timingName in @('planner_outer_passage_plan_ms', 'planner_total_ms', 'planner_fresh_grid_orchestration_total_ms')) {
        if ((Get-UniqueInteger $deferredText $timingName) -lt 0) { throw "$timingName is negative" }
    }
    $attempts = Get-UniqueInteger $deferredText 'planner_attempts'
    $outerAttempts = Get-UniqueInteger $deferredText 'planner_outer_passage_attempts'
    $outerReplayAttempts = Get-UniqueInteger $deferredText 'planner_outer_passage_replay_attempts'
    $outerShapeChecks = Get-UniqueInteger $deferredText 'planner_outer_passage_shape_checks'
    $outerPrivateDraws = Get-UniqueInteger $deferredText 'planner_outer_passage_private_draws'
    $outerDigest = Get-UniqueInteger $deferredText 'planner_outer_passage_plan_digest'
    $validationDigest = Get-UniqueInteger $deferredText 'validation_z_digest'
    if ($attempts -lt 8 -or $attempts -gt 64 -or
        (Get-UniqueInteger $deferredText 'planner_repeat_attempts') -ne $attempts -or
        (Get-UniqueInteger $deferredText 'planner_private_draws') -ne (3 * $attempts) -or
        $outerAttempts -ne $attempts -or $outerReplayAttempts -ne $attempts -or
        $outerShapeChecks -lt 8 -or $outerShapeChecks -gt $attempts -or
        $outerPrivateDraws -ne (3 * $attempts) -or $outerDigest -le 0 -or
        (Get-UniqueInteger $deferredText 'outer_passage_attempts') -ne $outerAttempts -or
        (Get-UniqueInteger $deferredText 'outer_passage_replay_attempts') -ne $outerReplayAttempts -or
        (Get-UniqueInteger $deferredText 'outer_passage_shape_checks') -ne $outerShapeChecks -or
        (Get-UniqueInteger $deferredText 'outer_passage_private_draws') -ne $outerPrivateDraws -or
        (Get-UniqueInteger $deferredText 'outer_passage_plan_digest') -ne $outerDigest -or
        (Get-UniqueInteger $deferredText 'validation_z_report_digest') -ne $validationDigest -or $validationDigest -le 0) {
        throw 'exact T1 planner/validation digest relation is inconsistent'
    }

    $receipt = [ordered]@{
        schema = 'smr.ralph.surface-only-acceptance-receipt.v1'
        ok = $true
        diagnostic_only = $false
        acceptance_timing_eligible = $true
        t0_utc = $t0Utc.ToString('o')
        t1_utc = $t1Utc.ToString('o')
        t0_to_t1_ms = $elapsedMs
        stopwatch = [ordered]@{ frequency = $timingFrequency; t0_timestamp = $t0Timestamp; t1_timestamp = $t1Timestamp }
        underground_access_included = $false
        underground_release_invoked = $false
        generator_run_file_count = 1
        contract_sha256 = $ContractSha256.ToUpperInvariant()
        hashes = [ordered]@{
            contract = Get-Sha256 $ContractPath
            executor = Get-Sha256 $PSCommandPath
            generator = Get-Sha256 $Generator
            surface_t1 = Get-Sha256 $SurfaceT1
            deferred_t1 = Get-Sha256 $DeferredT1
            scheduler_census = Get-Sha256 $Census
            post_t1_single_flush_scalar = Get-Sha256 $PostT1Scalar
        }
        planner = [ordered]@{
            attempts = Get-UniqueInteger $deferredText 'planner_attempts'
            outer_passage_attempts = Get-UniqueInteger $deferredText 'planner_outer_passage_attempts'
            outer_passage_plan_ms = Get-UniqueInteger $deferredText 'planner_outer_passage_plan_ms'
            total_ms = Get-UniqueInteger $deferredText 'planner_total_ms'
            fresh_grid_orchestration_total_ms = Get-UniqueInteger $deferredText 'planner_fresh_grid_orchestration_total_ms'
            single_flush_tuple = $singleFlush.tuple
            single_flush_comparison_ms = $singleFlush.comparison_ms
            single_flush_proof_ms = $singleFlush.proof_ms
        }
    }
    Write-Json $Receipt $receipt
    Write-Json $Timing ([ordered]@{
        schema = 'smr.ralph.external_timing.v2'; diagnostic_only = $false; acceptance_timing_eligible = $true
        t0_utc = $t0Utc.ToString('o'); t1_utc = $t1Utc.ToString('o'); t0_to_t1_ms = $elapsedMs
        stopwatch_frequency = $timingFrequency; t0_timestamp = $t0Timestamp; t1_timestamp = $t1Timestamp
        trace_active = $false; underground_access_included = $false; surface_only = $true
    })
    Stop-TrackedGame 'successful surface-only acceptance'
} catch {
    $failures.Add($_.Exception.Message)
} finally {
    if ($daemonStartAttempted -and -not $script:trackedQuitSucceeded) {
        try { Stop-TrackedGame 'surface-only finally cleanup' } catch { $failures.Add($_.Exception.Message) }
    }
    try {
        Copy-Item -LiteralPath $SourceConfig -Destination $DeployedConfig -Force
        if ((Get-Sha256 $DeployedConfig) -cne ([string]$script:Contract.expected_disabled_config_sha256).ToUpperInvariant()) { throw 'disabled config restore hash mismatch' }
        Assert-DeployAudit $false
    } catch { $failures.Add($_.Exception.Message) }
}
if ($failures.Count -ne 0) { throw ($failures -join ' | ') }
Write-Output 'SURFACE_ONLY_ACCEPTANCE_COMPLETE_AND_DEPLOYMENT_RESTORED'
