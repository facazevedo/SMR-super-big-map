param(
    [int]$CycleTimeoutSeconds = 600,
    # Session provider. `codex` reproduces the historical launch byte-for-byte;
    # `claude` runs the same task contract through the Claude Code CLI. The task
    # contract is agent-neutral, so a campaign may alternate between them.
    [ValidateSet("codex", "claude")]
    [string]$Agent = "codex",
    # Empty selects the agent's default model from the profile table below.
    [string]$Model = "",
    # Pins one constant effort for every cycle and disables the ladder. Empty
    # runs the ladder between -BaseEffort and -EscalatedEffort.
    [string]$Effort = "",
    # Ledger-driven effort ladder. Empty selects the agent defaults: Claude runs
    # Opus 5 at `high` and escalates to `max` (the Claude CLI's extra-high tier;
    # it has no `xhigh`). Codex keeps its historical constant `xhigh` on both
    # rungs, so existing codex campaigns are unchanged until asked otherwise.
    [string]$BaseEffort = "",
    [string]$EscalatedEffort = "",
    [int]$StagnantCyclesBeforeEscalation = 2,
    [switch]$NoAdaptiveEffort,
    # Pin a specific CLI build instead of the first match on PATH. Also the seam
    # used to exercise the launch-failure/backoff path without a real provider.
    [string]$ExecutablePath = "",
    # 0 means run until the operator stops the supervisor.
    [int]$MaxCycles = 0,
    # A cycle that exits nonzero faster than this is a launch failure, not work.
    [int]$MinHealthyCycleSeconds = 60,
    [int]$MaxConsecutiveFastFailures = 5,
    [int]$BackoffSeconds = 60,
    [int]$BackoffCapSeconds = 900,
    # Claude only; 0 leaves the CLI default in place.
    [double]$MaxBudgetUsd = 0,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$promptPath = Join-Path $repoRoot "_ralph\tasks\super-big-map-rule-equivalent-driver.md"
$runtimeRoot = Join-Path $repoRoot "_ralph\runtime\overnight-super-big-map"
$artifactRoot = Join-Path $repoRoot "_ralph\runs\surface-loading-under-60s-rough\artifacts"
$statePath = Join-Path $runtimeRoot "supervisor-state.json"
$ledgerPath = Join-Path $runtimeRoot "cycles.jsonl"
$architectureQueuePath = Join-Path $runtimeRoot "rule-equivalent-campaign-complete.json"

New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null

# --- Agent profiles -------------------------------------------------------
# Every provider reads the same task contract from stdin and writes its final
# message where the supervisor can archive it, so no contract text is
# provider-specific. Adding a provider means adding one branch here.

function Resolve-AgentExecutable {
    param([string]$AgentName)
    if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) {
        if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
            throw "ExecutablePath does not exist: $ExecutablePath"
        }
        return (Resolve-Path -LiteralPath $ExecutablePath).Path
    }
    $candidates = switch ($AgentName) {
        "codex"  { @("codex.exe", "codex") }
        "claude" { @("claude.exe", "claude") }
        default  { throw "unsupported agent: $AgentName" }
    }
    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    # PATH is not a reliable locator for either CLI: Codex ships as a Store app
    # whose execution alias disappears across updates, and both also install into
    # per-user directories that a service or scheduled shell may not inherit. A
    # missing alias must not end a campaign, so probe the known install roots
    # before failing, newest build first.
    foreach ($pattern in (Get-AgentFallbackPaths -AgentName $AgentName)) {
        $found = @(Get-Item -Path $pattern -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending)
        if ($found.Count -gt 0) { return $found[0].FullName }
    }
    throw ("agent '{0}' is not installed, not on PATH, and not in any known install root " +
        "(looked for: {1}); pass -ExecutablePath to pin one" -f `
        $AgentName, ($candidates -join ", "))
}

function Get-AgentFallbackPaths {
    param([string]$AgentName)
    switch ($AgentName) {
        "codex" {
            return @(
                (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\codex.exe"),
                "C:\Program Files\WindowsApps\OpenAI.Codex_*_x64_*\app\resources\codex.exe",
                (Join-Path $env:USERPROFILE ".vscode\extensions\openai.chatgpt-*-win32-x64\bin\windows-x86_64\codex.exe"),
                (Join-Path $env:APPDATA "npm\codex.cmd")
            )
        }
        "claude" {
            return @(
                (Join-Path $env:USERPROFILE ".local\bin\claude.exe"),
                (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\claude.exe"),
                (Join-Path $env:APPDATA "npm\claude.cmd")
            )
        }
        default { return @() }
    }
}

function Get-AgentDefaults {
    param([string]$AgentName)
    switch ($AgentName) {
        # Codex kept its historical single effort on both rungs, so an existing
        # codex campaign behaves exactly as before unless the operator opts in.
        "codex"  { return @{ Model = "gpt-5.6-sol";   Base = "xhigh"; Escalated = "xhigh" } }
        # Opus 5 at `high`, escalating to `max` - the tier the UI labels "Extra
        # high". Claude Code's effort values are low/medium/high/max; there is no
        # `xhigh`, which is the Codex spelling of the same idea.
        "claude" { return @{ Model = "claude-opus-5"; Base = "high";  Escalated = "max" } }
        default  { throw "unsupported agent: $AgentName" }
    }
}

function Resolve-AgentEffort {
    param([string]$AgentName, [string]$Requested)
    if ($AgentName -ne "claude") { return $Requested }
    # The Claude CLI names its escalated tier `max`. Accept the Codex spelling so
    # one campaign contract and one operator habit work for both providers.
    if ($Requested -eq "xhigh") { return "max" }
    $allowed = @("low", "medium", "high", "max")
    if ($allowed -notcontains $Requested) {
        throw ("claude effort '{0}' is not one of: {1}" -f $Requested, ($allowed -join ", "))
    }
    return $Requested
}

function Build-AgentArguments {
    param(
        [string]$AgentName,
        [string]$AgentModel,
        [string]$AgentEffort,
        [string]$LastMessagePath
    )
    if ($AgentName -eq "codex") {
        # Historical launch, unchanged. Codex reads the contract from stdin (`-`)
        # and writes only its final message to -o.
        return @(
            "exec", "--strict-config",
            "-C", $repoRoot,
            "-m", $AgentModel,
            "-c", ('model_reasoning_effort="{0}"' -f $AgentEffort),
            "-c", 'approval_policy="never"',
            "-s", "danger-full-access",
            "--color", "never",
            "-o", $LastMessagePath,
            "-"
        )
    }
    if ($AgentName -eq "claude") {
        # -p reads the contract from stdin and prints only the final message on
        # stdout, so the supervisor copies stdout to the last-message path after
        # the cycle instead of asking the CLI for a second output file.
        $arguments = @(
            "-p",
            "--dangerously-skip-permissions",
            "--model", $AgentModel,
            "--effort", $AgentEffort,
            "--output-format", "text"
        )
        if ($MaxBudgetUsd -gt 0) {
            $arguments += @("--max-budget-usd", ([string]$MaxBudgetUsd))
        }
        return $arguments
    }
    throw "unsupported agent: $AgentName"
}

# --- Effort ladder ---------------------------------------------------------
# The ladder is driven by a restart-safe cycle ledger, not by supervisor uptime,
# so a hot restart resumes at the rung the campaign had actually reached. The
# progress signal is the `Progress: yes|no` line the task contract requires each
# iteration to end with - the same convention loop.py uses - read from the
# cycle's final message. A cycle that never started work (provider outage) is
# recorded as a launch failure and does not count as stagnation.

function Get-CycleProgress {
    param([string]$LastMessagePath)
    if (-not (Test-Path -LiteralPath $LastMessagePath)) { return $null }
    try {
        $text = Get-Content -LiteralPath $LastMessagePath -Raw -ErrorAction Stop
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    # Last occurrence wins: an iteration may quote the convention before using it.
    $matches = [regex]::Matches($text, '(?im)^\s*Progress:\s*(yes|no)\b')
    if ($matches.Count -eq 0) { return $null }
    return ($matches[$matches.Count - 1].Groups[1].Value.ToLowerInvariant() -eq "yes")
}

function Add-CycleLedgerRecord {
    param([hashtable]$Record)
    $line = ([ordered]@{
        schema = "smr.ralph.overnight-cycle.v1"
        cycle = $Record.Cycle
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        agent = $script:agent
        model = $script:agentModel
        effort = $Record.Effort
        exit_code = $Record.ExitCode
        elapsed_seconds = [Math]::Round([double]$Record.ElapsedSeconds, 1)
        timed_out = [bool]$Record.TimedOut
        launch_failure = [bool]$Record.LaunchFailure
        launch_failure_reason = [string]$Record.LaunchFailureReason
        progress = $Record.Progress
        last_message = [string]$Record.LastMessagePath
    } | ConvertTo-Json -Compress -Depth 4)
    Add-Content -LiteralPath $ledgerPath -Value $line -Encoding UTF8
}

function Get-StagnantCycleCount {
    <#
        Consecutive most-recent worked cycles that did not report progress.
        Launch failures are skipped entirely - they are not iterations - and a
        single `Progress: yes` resets the count to zero.
    #>
    if (-not (Test-Path -LiteralPath $ledgerPath)) { return 0 }
    try {
        $lines = @(Get-Content -LiteralPath $ledgerPath -ErrorAction Stop)
    } catch {
        return 0
    }
    $stagnant = 0
    for ($index = $lines.Count - 1; $index -ge 0; $index -= 1) {
        if ([string]::IsNullOrWhiteSpace($lines[$index])) { continue }
        try { $record = $lines[$index] | ConvertFrom-Json } catch { continue }
        if ($record.launch_failure -eq $true) { continue }
        if ($record.progress -eq $true) { break }
        $stagnant += 1
    }
    return $stagnant
}

function Get-EffortForNextCycle {
    if (-not [string]::IsNullOrWhiteSpace($Effort)) { return $script:pinnedEffort }
    if ($NoAdaptiveEffort) { return $script:baseEffort }
    if ((Get-StagnantCycleCount) -ge $StagnantCyclesBeforeEscalation) {
        return $script:escalatedEffort
    }
    return $script:baseEffort
}

# A launch that dies in seconds is a provider outage, not an iteration. Without
# this the supervisor spun ~4 s per cycle for hours against an exhausted Codex
# quota and burned the campaign's wall clock (cycles 0700-0727, 2026-09-01).
function Get-LaunchFailureReason {
    param([string]$StderrPath)
    if (-not (Test-Path -LiteralPath $StderrPath)) { return "" }
    try {
        $text = Get-Content -LiteralPath $StderrPath -Raw -ErrorAction Stop
    } catch {
        return ""
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $patterns = [ordered]@{
        "usage-limit"     = 'usage limit|out of credit|purchase more credits|quota exceeded|insufficient_quota'
        "rate-limit"      = 'rate limit|429|too many requests'
        "authentication"  = 'not authenticated|please (run )?.*login|unauthorized|invalid api key|401'
        "model-rejected"  = 'unknown model|model not found|unsupported model|not available for your'
    }
    foreach ($reason in $patterns.Keys) {
        if ($text -imatch $patterns[$reason]) { return $reason }
    }
    return ""
}

function Find-AcceptedUnderSixtyReceipt {
    if (-not (Test-Path -LiteralPath $artifactRoot)) { return $null }
    $receipts = Get-ChildItem -LiteralPath $artifactRoot -Recurse -File `
        -Filter "surface_only_acceptance_receipt.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($receiptFile in $receipts) {
        try {
            $receipt = Get-Content -LiteralPath $receiptFile.FullName -Raw | ConvertFrom-Json
            if ($receipt.ok -eq $true -and $receipt.diagnostic_only -ne $true `
                -and $receipt.acceptance_timing_eligible -eq $true `
                -and [double]$receipt.t0_to_t1_ms -lt 60000) {
                return $receiptFile
            }
        } catch {
            continue
        }
    }
    return $null
}

function Find-CompletedArchitectureQueue {
    if (-not (Test-Path -LiteralPath $architectureQueuePath)) { return $null }
    try {
        $queue = Get-Content -LiteralPath $architectureQueuePath -Raw | ConvertFrom-Json
        if ($queue.schema -ne "smr.ralph.rule-equivalent-campaign-complete.v1" `
            -or $queue.all_candidates_attempted -ne $true `
            -or $null -eq $queue.items) {
            return $null
        }
        $terminal = @("accepted", "rejected", "infeasible")
        foreach ($id in 1..3) {
            $item = @($queue.items | Where-Object { [int]$_.id -eq $id })
            if ($item.Count -ne 1 -or $terminal -notcontains [string]$item[0].verdict `
                -or [string]::IsNullOrWhiteSpace([string]$item[0].evidence_path)) {
                return $null
            }
            $evidence = [string]$item[0].evidence_path
            if (-not [IO.Path]::IsPathRooted($evidence)) {
                $evidence = Join-Path $repoRoot $evidence
            }
            if (-not (Test-Path -LiteralPath $evidence)) { return $null }
        }
        return Get-Item -LiteralPath $architectureQueuePath
    } catch {
        return $null
    }
}

function Write-SupervisorState {
    param(
        [int]$Cycle,
        [string]$Status,
        [int]$WorkerPid = 0,
        [string]$Detail = ""
    )
    [ordered]@{
        schema = "smr.ralph.overnight-supervisor.v1"
        workspace = $repoRoot
        cycle = $Cycle
        status = $Status
        worker_pid = $WorkerPid
        detail = $Detail
        agent = $script:agent
        model = $script:agentModel
        effort = $script:agentEffort
        base_effort = $script:baseEffort
        escalated_effort = $script:escalatedEffort
        stagnant_cycles = $script:stagnantCycles
        updated_local = (Get-Date).ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

$script:agent = $Agent
$defaults = Get-AgentDefaults -AgentName $Agent
$script:agentModel = if ([string]::IsNullOrWhiteSpace($Model)) { $defaults.Model } else { $Model }

$requestedBase = if ([string]::IsNullOrWhiteSpace($BaseEffort)) { $defaults.Base } else { $BaseEffort }
$requestedEscalated =
    if ([string]::IsNullOrWhiteSpace($EscalatedEffort)) { $defaults.Escalated } else { $EscalatedEffort }
$script:baseEffort = Resolve-AgentEffort -AgentName $Agent -Requested $requestedBase
$script:escalatedEffort = Resolve-AgentEffort -AgentName $Agent -Requested $requestedEscalated
$script:pinnedEffort = ""
if (-not [string]::IsNullOrWhiteSpace($Effort)) {
    $script:pinnedEffort = Resolve-AgentEffort -AgentName $Agent -Requested $Effort
}
# Reported before the first cycle runs; refreshed from the ledger each cycle.
$script:stagnantCycles = 0
$script:agentEffort = $script:baseEffort

if (-not (Test-Path -LiteralPath $promptPath)) {
    throw "task contract not found: $promptPath"
}

if ($DryRun) {
    # Dry run reports the exact launch without requiring the provider to be
    # installed, so a codex command can be reviewed from a claude-only machine.
    $executable = try { Resolve-AgentExecutable -AgentName $Agent } catch { "<not installed>" }
    $script:stagnantCycles = Get-StagnantCycleCount
    $script:agentEffort = Get-EffortForNextCycle
    $preview = Build-AgentArguments -AgentName $Agent -AgentModel $script:agentModel `
        -AgentEffort $script:agentEffort -LastMessagePath (Join-Path $runtimeRoot "cycle-DRYRUN.last.txt")
    [ordered]@{
        agent = $Agent
        executable = $executable
        model = $script:agentModel
        effort_next_cycle = $script:agentEffort
        base_effort = $script:baseEffort
        escalated_effort = $script:escalatedEffort
        effort_pinned = (-not [string]::IsNullOrWhiteSpace($script:pinnedEffort))
        adaptive_effort = (-not $NoAdaptiveEffort)
        stagnant_cycles = $script:stagnantCycles
        escalate_at_stagnant_cycles = $StagnantCyclesBeforeEscalation
        working_directory = $repoRoot
        prompt_stdin = $promptPath
        cycle_ledger = $ledgerPath
        cycle_timeout_seconds = $CycleTimeoutSeconds
        arguments = $preview
    } | ConvertTo-Json -Depth 4
    return
}

$executable = Resolve-AgentExecutable -AgentName $Agent

$cycle = 0
$priorState = $null
if (Test-Path -LiteralPath $statePath) {
    try {
        $priorState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $cycle = [Math]::Max(0, [int]$priorState.cycle)
    } catch {
        $priorState = $null
    }
}

# A supervisor can be hot-restarted while a bounded worker or live game is active. Adopt that
# worker instead of launching a duplicate; its successor will collect any live test normally.
if ($null -ne $priorState -and $priorState.status -eq "worker-running" `
    -and [int]$priorState.worker_pid -gt 0 `
    -and (Get-Process -Id ([int]$priorState.worker_pid) -ErrorAction SilentlyContinue)) {
    $adoptedPid = [int]$priorState.worker_pid
    Write-SupervisorState -Cycle $cycle -Status "worker-adopted" -WorkerPid $adoptedPid `
        -Detail ([string]$priorState.detail)
    try {
        Wait-Process -Id $adoptedPid -Timeout $CycleTimeoutSeconds -ErrorAction Stop
        Write-SupervisorState -Cycle $cycle -Status "adopted-worker-finished" `
            -Detail ([string]$priorState.detail)
    } catch {
        if (Get-Process -Id $adoptedPid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $adoptedPid -Force
        }
        Write-SupervisorState -Cycle $cycle -Status "adopted-worker-timeout-recovering" `
            -Detail ("timeout_seconds={0}; last={1}" -f $CycleTimeoutSeconds, [string]$priorState.detail)
    }
}

$startingCycle = $cycle
$consecutiveFastFailures = 0
$currentBackoffSeconds = $BackoffSeconds
$env:SMR_RALPH_AGENT = $Agent
$env:SMR_RALPH_MODEL = $script:agentModel
$env:SMR_RALPH_REASONING_EFFORT = $script:agentEffort

while ($true) {
    if ($MaxCycles -gt 0 -and ($cycle - $startingCycle) -ge $MaxCycles) {
        Write-SupervisorState -Cycle $cycle -Status "supervisor-cycle-budget-reached" `
            -Detail ("max_cycles={0}" -f $MaxCycles)
        break
    }
    $cycle += 1
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $stdoutPath = Join-Path $runtimeRoot ("cycle-{0:D4}-{1}.stdout.log" -f $cycle, $stamp)
    $stderrPath = Join-Path $runtimeRoot ("cycle-{0:D4}-{1}.stderr.log" -f $cycle, $stamp)
    $lastPath = Join-Path $runtimeRoot ("cycle-{0:D4}-{1}.last.txt" -f $cycle, $stamp)
    # Re-read the ledger every cycle so a hot restart, an out-of-band ledger
    # correction, and a mid-campaign progress report all take effect immediately.
    $script:stagnantCycles = Get-StagnantCycleCount
    $script:agentEffort = Get-EffortForNextCycle
    $env:SMR_RALPH_REASONING_EFFORT = $script:agentEffort
    $arguments = Build-AgentArguments -AgentName $Agent -AgentModel $script:agentModel `
        -AgentEffort $script:agentEffort -LastMessagePath $lastPath

    $cycleStarted = Get-Date
    $worker = Start-Process -FilePath $executable -ArgumentList $arguments `
        -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardInput $promptPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    Write-SupervisorState -Cycle $cycle -Status "worker-running" -WorkerPid $worker.Id `
        -Detail $lastPath

    $timedOut = $false
    try {
        Wait-Process -Id $worker.Id -Timeout $CycleTimeoutSeconds -ErrorAction Stop
        $worker.Refresh()
        Write-SupervisorState -Cycle $cycle -Status "worker-finished" `
            -Detail ("exit_code={0}; last={1}" -f $worker.ExitCode, $lastPath)
    } catch {
        $timedOut = $true
        if (Get-Process -Id $worker.Id -ErrorAction SilentlyContinue) {
            Stop-Process -Id $worker.Id -Force
        }
        Write-SupervisorState -Cycle $cycle -Status "worker-timeout-recovering" `
            -Detail ("timeout_seconds={0}; last={1}" -f $CycleTimeoutSeconds, $lastPath)
    }

    # Providers that print the final message on stdout get the same last-message
    # artifact Codex writes with -o, so downstream tooling stays agent-neutral.
    if ($Agent -ne "codex" -and -not (Test-Path -LiteralPath $lastPath) `
        -and (Test-Path -LiteralPath $stdoutPath)) {
        try { Copy-Item -LiteralPath $stdoutPath -Destination $lastPath -Force } catch { }
    }

    $elapsedSeconds = ((Get-Date) - $cycleStarted).TotalSeconds
    $exitCode = if ($timedOut) { -1 } else { [int]$worker.ExitCode }
    $fastFailure = (-not $timedOut) -and $exitCode -ne 0 `
        -and $elapsedSeconds -lt $MinHealthyCycleSeconds
    $reason = if ($fastFailure) { Get-LaunchFailureReason -StderrPath $stderrPath } else { "" }
    if ($fastFailure -and [string]::IsNullOrWhiteSpace($reason)) { $reason = "fast-exit" }

    Add-CycleLedgerRecord @{
        Cycle = $cycle
        Effort = $script:agentEffort
        ExitCode = $exitCode
        ElapsedSeconds = $elapsedSeconds
        TimedOut = $timedOut
        LaunchFailure = $fastFailure
        LaunchFailureReason = $reason
        Progress = if ($fastFailure) { $null } else { Get-CycleProgress -LastMessagePath $lastPath }
        LastMessagePath = $lastPath
    }

    if (-not $fastFailure) {
        $consecutiveFastFailures = 0
        $currentBackoffSeconds = $BackoffSeconds
        # Intentional zero-delay handoff. The next worker first collects any live test left by the
        # bounded predecessor, so a timeout cannot trigger a duplicate Mars launch.
        continue
    }

    $consecutiveFastFailures += 1

    if ($consecutiveFastFailures -ge $MaxConsecutiveFastFailures) {
        Write-SupervisorState -Cycle $cycle -Status "supervisor-stopped-launch-failures" `
            -Detail ("reason={0}; consecutive={1}; elapsed_seconds={2:N1}; stderr={3}" -f `
                $reason, $consecutiveFastFailures, $elapsedSeconds, $stderrPath)
        throw ("{0} consecutive {1} launch failures for agent '{2}'; see {3}" -f `
            $consecutiveFastFailures, $reason, $Agent, $stderrPath)
    }

    Write-SupervisorState -Cycle $cycle -Status ("worker-launch-failed-" + $reason) `
        -Detail ("consecutive={0}; backoff_seconds={1}; elapsed_seconds={2:N1}; stderr={3}" -f `
            $consecutiveFastFailures, $currentBackoffSeconds, $elapsedSeconds, $stderrPath)
    Start-Sleep -Seconds $currentBackoffSeconds
    $currentBackoffSeconds = [Math]::Min($BackoffCapSeconds, $currentBackoffSeconds * 2)
}
