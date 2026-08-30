Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'v992_external_materialization_watchdog.ps1')

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('sbm-v992-watchdog-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($temporary) | Out-Null
$helper = $null
try {
    $nonce = 'v992-watchdog-oracle'
    $manifest = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    $prefix = Join-Path $temporary 'phase_'
    $heartbeat = @(
        'schema=smr.sbm.lazy-phase-heartbeat.v1', 'sequence=1',
        "nonce=$nonce", "command_manifest_sha256=$manifest", 'edge=BEFORE',
        'phase=underground-enrichment-relocation', 'elapsed_ms=42', 'complete=true'
    ) -join "`n"
    Write-SbmUtf8NoBomAtomic -Path ($prefix + '0001.txt') -Text ($heartbeat + "`n")
    $parsed = Read-SbmPhaseHeartbeats -Prefix $prefix -Nonce $nonce -ManifestSha256 $manifest
    if ($parsed.complete_records -ne 1 -or $parsed.invalid_records -ne 0 -or
        $parsed.inflight_phases.Count -ne 1 -or
        $parsed.inflight_phases[0] -cne 'underground-enrichment-relocation') {
        throw 'hung phase classification failed'
    }

    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $helper = Start-Process -FilePath $hostExe -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120'
    ) -WindowStyle Hidden -PassThru
    $identity = Get-SbmTrackedProcessIdentity -Process $helper
    $wrong = [pscustomobject]@{
        pid = $identity.pid
        creation_time_utc_ticks = [long]$identity.creation_time_utc_ticks + 1
        process_name = $identity.process_name
        executable_path = $identity.executable_path
    }
    $wrongKill = Stop-SbmTrackedProcessExact -Identity $wrong -WaitMilliseconds 1000
    if ($wrongKill.attempted -or $helper.HasExited) { throw 'identity mismatch was not fail-closed' }

    $bundle = Join-Path $temporary 'external_bundle.json'
    $terminal = Join-Path $temporary 'external_terminal.json'
    $cleanup = Join-Path $temporary 'external_cleanup.json'
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $unusedPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $receipt = Publish-SbmExternalWatchdogTimeout -HeartbeatPrefix $prefix `
        -BundlePath $bundle -TerminalPath $terminal -CleanupReceiptPath $cleanup `
        -Nonce $nonce -ManifestSha256 $manifest -TrackedProcess $identity `
        -DapPort $unusedPort -DapQuitSucceeded $false
    $helper.Refresh()
    if (-not $helper.HasExited -or -not $receipt.killed) { throw 'exact fallback kill failed' }
    $bundleValue = Get-Content -Raw -LiteralPath $bundle | ConvertFrom-Json
    $terminalValue = Get-Content -Raw -LiteralPath $terminal | ConvertFrom-Json
    $cleanupValue = Get-Content -Raw -LiteralPath $cleanup | ConvertFrom-Json
    if ($bundleValue.ok -ne $false -or $bundleValue.can_promote -ne $false -or
        $bundleValue.inflight_phases[0] -cne 'underground-enrichment-relocation' -or
        $terminalValue.ok -ne $false -or $cleanupValue.ok -ne $true -or
        $cleanupValue.exact_kill_identity_match -ne $true) {
        throw 'watchdog publication contract failed'
    }
    if ((Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant() -cne
        $terminalValue.bundle_sha256) { throw 'terminal did not bind the causal bundle' }
    Write-Output 'ok=true'
    Write-Output 'hang_classification=exact-inflight-phase'
    Write-Output 'bundle_before_terminal=true'
    Write-Output 'wrong_identity_kills=0'
    Write-Output 'dap_unavailable_exact_kills=1'
    Write-Output 'acceptance_promotions=0'
} finally {
    if ($helper -and -not $helper.HasExited) { Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue }
    if ([System.IO.Directory]::Exists($temporary)) {
        [System.IO.Directory]::Delete($temporary, $true)
    }
}
