param(
    # Short tag for the run/artifact names. One safe path component.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,40}$')]
    [string]$Label,
    # Sequential cold samples. Each one is a fresh process; never concurrent.
    [ValidateRange(1, 40)]
    [int]$Repeat = 1,
    # Alternate generator stage, e.g. the timestamp-only warm phase profile built by
    # build_warm_phase_profile_generator.py. The payload under test is unchanged;
    # only the harness-side generator differs.
    [string]$TemplateStage = "",
    # The generator embeds this many absolute artifact paths, all retargeted at the
    # run directory. The accepted generator has 5; the phase profile adds one.
    [ValidateRange(1, 16)]
    [int]$ExpectedPathFragments = 5,
    # Stamp T0 when the generator publishes this sentinel instead of at run-file
    # submission, i.e. measure the player's Start button rather than New Game.
    # Requires a generator that writes it (see build_warm_phase_profile_generator.py
    # and the Start-boundary stage).
    [string]$GenerationStartFile = "",
    # A/B mode. When set, samples alternate between -TemplateStage (control) and
    # this stage (candidate), with the order inside each pair drawn at random.
    # Phase 0 at the Start boundary showed the noise is white, so randomised
    # interleaved two-sample is the design, not ABBA blocking.
    [string]$CandidateTemplateStage = "",
    [int]$Seed = 0
)

# Re-measure the accepted 75.8132980 s iteration-266b payload without touching the
# historical five-run calibration state. Same premise checks and same executor as
# `run_accepted_baseline_calibration_sample.ps1`, but the timing threshold is
# deliberately loose (300 s) so every repeat completes the full correctness gate
# even when it is slower than the accepted best. This measures reproducibility; it
# never replaces the accepted baseline.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$artifactRoot = Join-Path $repo '_ralph\runs\surface-loading-under-60s-rough\artifacts'
$templateStage = if ([string]::IsNullOrWhiteSpace($TemplateStage)) {
    Join-Path $repo '_ralph\tmp\.tmp_surface_release_v1011_apron_math_iter266b'
} else {
    [IO.Path]::GetFullPath($TemplateStage)
}
$templateContractPath = Join-Path $repo '_ralph\tmp\iter266b_surface_only_acceptance_contract.json'
$executor = Join-Path $repo '_ralph\tools\execute_surface_only_acceptance.ps1'
$harness = 'D:\PROJS\SMR\smr-harness\cli.py'
$payloadManifestPath = Join-Path $repo '_ralph\runtime\overnight-super-big-map\exact-iter266b-dirty-payload-manifest-334d52b2670017a3.json'
$deployedConfig = 'C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\super-big-map\Code\sbm_config.lua'
$runtimeRoot = Join-Path $repo '_ralph\runtime\overnight-super-big-map'
$ledgerPath = Join-Path $runtimeRoot 'accepted-baseline-replication.jsonl'
$acceptedBestMs = 75813.2980
$utf8 = New-Object Text.UTF8Encoding($false)

function Get-Sha([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-MachineTelemetry {
    <#
        Ambient machine state at the moment a sample starts. The between-session
        shift this tool exists to characterise is environmental, so a timing
        number without its environment is not evidence.
    #>
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    [ordered]@{
        captured_utc = [DateTime]::UtcNow.ToString('o')
        cpu_load_percent = [int](($cpu | Measure-Object -Property LoadPercentage -Average).Average)
        cpu_clock_mhz = [int](($cpu | Measure-Object -Property CurrentClockSpeed -Average).Average)
        cpu_max_clock_mhz = [int](($cpu | Measure-Object -Property MaxClockSpeed -Average).Average)
        memory_used_percent = [Math]::Round(
            100 * (1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)), 1)
        free_physical_mb = [int]($os.FreePhysicalMemory / 1024)
        process_count = @(Get-Process).Count
        mars_processes_before_launch = @(Get-Process -Name MarsDebug -ErrorAction SilentlyContinue).Count
    }
}

function Get-PayloadManifest([string]$Root) {
    $paths = @(
        Get-ChildItem -LiteralPath (Join-Path $Root 'Code') -File -Recurse
        Get-ChildItem -LiteralPath (Join-Path $Root 'Images') -File -Recurse
        Get-Item -LiteralPath (Join-Path $Root 'metadata.lua')
        Get-Item -LiteralPath (Join-Path $Root 'items.lua')
    ) | Sort-Object FullName
    @($paths | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
            bytes = $_.Length
            sha256 = Get-Sha $_.FullName
        }
    })
}

function Assert-ExactAcceptedPayload {
    <#
        Fail closed unless the working tree IS the accepted iteration-266b payload.
        A replication measured against a drifted tree is not a replication.
    #>
    $auditText = (& python (Join-Path $repo '_ralph\tools\deploy.py') audit 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "accepted deployment audit failed: $auditText" }
    $audit = $auditText | ConvertFrom-Json
    if (-not $audit.ok -or [int]$audit.source_files -ne 35 -or [int]$audit.destination_files -ne 35) {
        throw "accepted deployment is not exact 35/35: $auditText"
    }
    $expectedManifest = Get-Content -LiteralPath $payloadManifestPath -Raw | ConvertFrom-Json
    $currentManifest = @(Get-PayloadManifest $repo)
    if (-not $expectedManifest.ok -or [int]$expectedManifest.file_count -ne 35 -or $currentManifest.Count -ne 35) {
        throw 'exact iter266b payload manifest is not a valid 35-file premise'
    }
    foreach ($expected in @($expectedManifest.files)) {
        $found = @($currentManifest | Where-Object { [string]$_.path -ceq [string]$expected.path })
        if ($found.Count -ne 1) { throw "payload path missing or duplicated: $($expected.path)" }
        if ([int64]$expected.bytes -ne [int64]$found[0].bytes -or
            [string]$expected.sha256 -cne [string]$found[0].sha256) {
            throw ("payload identity differs for {0}: expected {1}, actual {2}" -f
                [string]$expected.path, [string]$expected.sha256, [string]$found[0].sha256)
        }
    }
    $sourceConfig = Join-Path $repo 'Code\sbm_config.lua'
    $configText = Get-Content -LiteralPath $sourceConfig -Raw
    $lazy = [regex]::Matches($configText,
        '(?m)^\s*config\.LazyUndergroundSourceGeneration\s*=\s*(?<value>true|false)\s*$')
    if ($lazy.Count -ne 1 -or $lazy[0].Groups['value'].Value -cne 'true') {
        throw 'accepted config does not preserve LazyUndergroundSourceGeneration=true'
    }
    if ((Get-Sha $sourceConfig) -cne 'E3E59B1A45B5A2B5A7B07BFE99E3952F2B331DD924C236E7B57487CC25ED5E6B') {
        throw 'exact preserved iter266b enabled-config identity changed'
    }
    if ((Get-Sha (Join-Path $repo 'Code\sbm_map_generation.lua')) -cne
        'E059A1B854DA08E0822C20ABE0D3F4F72E413D143449131CF20CB96F7CA85C4B') {
        throw 'exact iter266b capsule state-machine identity changed'
    }
    return $currentManifest
}

function Invoke-OneSample {
    param([int]$Index, [array]$PayloadManifest,
          [string]$StageRoot = "", [string]$Arm = "control")
    $sampleStage = if ([string]::IsNullOrWhiteSpace($StageRoot)) { $templateStage } else { $StageRoot }

    $telemetry = Get-MachineTelemetry
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $runName = 'run_v1011_surface_replication_{0}_{1}_sample{2:d2}_{3}' -f $Label, $Arm, $Index, $stamp
    $run = Join-Path $artifactRoot $runName
    if (Test-Path -LiteralPath $run) { throw "fresh run path already exists: $run" }
    New-Item -ItemType Directory -Path $run | Out-Null

    # The historical generator writes five absolute artifact paths; retarget all of
    # them at this run and refuse if that premise ever changes.
    $templateGenerator = Join-Path $sampleStage 'generate_14N134W_rough_reference.lua'
    $oldFragment = 'D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/artifacts/run_v1011_surface_release_apron_math_iter266b'
    $generatorText = [IO.File]::ReadAllText($templateGenerator)
    $fragmentCount = [regex]::Matches($generatorText, [regex]::Escape($oldFragment)).Count
    if ($fragmentCount -ne $ExpectedPathFragments) {
        throw ("generator output-path premise changed: {0} fragments, expected {1}" -f
            $fragmentCount, $ExpectedPathFragments)
    }
    $generatorText = $generatorText.Replace($oldFragment, $run.Replace('\', '/'))
    $shaObject = [Security.Cryptography.SHA256]::Create()
    try {
        $generatorSha = ([BitConverter]::ToString(
            $shaObject.ComputeHash($utf8.GetBytes($generatorText)))).Replace('-', '')
    } finally { $shaObject.Dispose() }

    $stage = Join-Path $repo ('_ralph\tmp\.tmp_replication_{0}_{1}_sample{2:d2}_{3}' -f
        $Label, $Arm, $Index, $generatorSha.Substring(0, 16).ToLowerInvariant())
    if (Test-Path -LiteralPath $stage) { throw "content-addressed stage already exists: $stage" }
    New-Item -ItemType Directory -Path $stage | Out-Null
    $generatorPath = Join-Path $stage 'generate_14N134W_rough_reference.lua'
    Write-Utf8 $generatorPath $generatorText
    Copy-Item -LiteralPath (Join-Path $sampleStage 'sbm_config_flag_on.lua') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $sampleStage 'surface_reference_manifest.json') -Destination $stage

    $sourceConfig = Join-Path $repo 'Code\sbm_config.lua'
    $contract = Get-Content -LiteralPath $templateContractPath -Raw | ConvertFrom-Json
    $contract.executor_sha256 = Get-Sha $executor
    $contract.task_identity = 'accepted-baseline-replication-v1011-exact-iter266b-{0}-{1:d2}' -f $Label, $Index
    $contract.scenario_identity = '14N134W-RoughTerrain-exact-iter266b-cold-replication-{0}-{1:d2}' -f $Label, $Index
    $contract.production_head = 'c24cd637a38b110a8c218b9db115d253b8b76940'
    $contract.production_tree = 'exact-dirty-payload-manifest-334D52B2670017A355DDB5EE84159EDD0CBE7E7EF9DB25ED578A5B914FEC0E45'
    $contract.repo = $repo
    $contract.stage = $stage
    $contract.run = $run
    $contract.source_config = $sourceConfig
    $contract.deployed_config = $deployedConfig
    $contract.expected_disabled_config_sha256 = Get-Sha $sourceConfig
    $contract.expected_enabled_config_sha256 = Get-Sha (Join-Path $stage 'sbm_config_flag_on.lua')
    if (-not [string]::IsNullOrWhiteSpace($GenerationStartFile)) {
        $contract | Add-Member -NotePropertyName generation_start_file `
            -NotePropertyValue $GenerationStartFile -Force
    }
    $contract.t1_timeout_seconds = 300
    # Loose on purpose: a replication must finish its correctness gate even when
    # slower than the accepted best. This is not an acceptance threshold.
    $contract.maximum_t0_to_t1_ms = 300000.0
    $contract.stage_files = [ordered]@{
        'generate_14N134W_rough_reference.lua' = Get-Sha $generatorPath
        'sbm_config_flag_on.lua' = Get-Sha (Join-Path $stage 'sbm_config_flag_on.lua')
        'surface_reference_manifest.json' = Get-Sha (Join-Path $stage 'surface_reference_manifest.json')
    }
    $contract.allowed_initial_run_files = @()
    $draft = Join-Path $repo ('_ralph\tmp\replication_{0}_sample{1:d2}_draft.json' -f $Label, $Index)
    Write-Utf8 $draft (($contract | ConvertTo-Json -Depth 12) + "`n")
    $contractSha = Get-Sha $draft
    $contractPath = Join-Path $repo ('_ralph\tmp\replication_{0}_sample{1:d2}_{2}.json' -f
        $Label, $Index, $contractSha.Substring(0, 16).ToLowerInvariant())
    Move-Item -LiteralPath $draft -Destination $contractPath

    Write-Utf8 ([IO.Path]::ChangeExtension($contractPath, $null) + '_preflight.json') ((
        [ordered]@{
            schema = 'smr.ralph.accepted-baseline-replication-preflight.v1'
            ok = $true
            label = $Label
            sample = $Index
            created_utc = [DateTime]::UtcNow.ToString('o')
            accepted_best_ms = $acceptedBestMs
            exact_historical_identity = [ordered]@{
                accepted_iteration = 'iter266b'
                payload_manifest_sha256 = '334D52B2670017A355DDB5EE84159EDD0CBE7E7EF9DB25ED578A5B914FEC0E45'
                map_generation_sha256 = Get-Sha (Join-Path $repo 'Code\sbm_map_generation.lua')
                config_sha256 = Get-Sha $sourceConfig
                deployed_file_count = 35
                lazy_underground_source_generation = $true
                diagnostics_off = $true
            }
            content_addresses = [ordered]@{
                generator_sha256 = $generatorSha
                contract_sha256 = $contractSha
                stage = $stage
                contract = $contractPath
                run = $run
            }
            executables = [ordered]@{
                executor_sha256 = Get-Sha $executor
                harness_cli_sha256 = Get-Sha $harness
                game_sha256 = Get-Sha 'C:\Games\Surviving Mars Relaunched\MarsDebug.exe'
                deploy_tool_sha256 = Get-Sha (Join-Path $repo '_ralph\tools\deploy.py')
            }
            payload_manifest = $PayloadManifest
        } | ConvertTo-Json -Depth 12) + "`n")

    # Run the executor as a child process with its streams redirected to files.
    # Neither `&` nor `2>&1` is usable here: the executor writes informational
    # notices to stderr (for example "preserved previous tracked-game incident"),
    # and under ErrorActionPreference=Stop a merged native stderr line becomes a
    # terminating NativeCommandError that kills this script mid-run - which
    # orphans the game process the executor has already launched.
    # These must live OUTSIDE $run: the executor asserts the run directory holds
    # exactly its allowed initial topology, and Start-Process creates redirect
    # targets before the child starts.
    $streamPrefix = Join-Path $runtimeRoot ('replication-{0}-sample{1:d2}' -f $Label, $Index)
    $stdoutFile = "$streamPrefix.stdout.log"
    $stderrFile = "$streamPrefix.stderr.log"
    $child = Start-Process -FilePath 'powershell.exe' -PassThru -Wait -NoNewWindow `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $executor,
            '-ContractPath', $contractPath, '-ContractSha256', $contractSha, '-Launch'
        ) `
        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    $executorExit = $child.ExitCode
    $executorOutput = @()
    foreach ($streamFile in @($stdoutFile, $stderrFile)) {
        if (Test-Path -LiteralPath $streamFile) {
            $executorOutput += @(Get-Content -LiteralPath $streamFile -ErrorAction SilentlyContinue)
        }
    }
    Write-Host ("--- executor (exit {0}) ---`n{1}" -f $executorExit, ($executorOutput | Out-String))

    $receiptPath = Join-Path $run 'surface_only_acceptance_receipt.json'
    if ($executorExit -ne 0 -or -not (Test-Path -LiteralPath $receiptPath)) {
        $daemonRecord = Get-Content -LiteralPath 'D:\PROJS\SMR\smr-harness\.daemon.json' -Raw |
            ConvertFrom-Json
        $crashed = $false
        try {
            $crashed = (Get-Content -LiteralPath ([string]$daemonRecord.log) -Raw) -match
                '=================\[ CRASH \]'
        } catch { }
        $tail = @($executorOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 1) -join ' '
        return [ordered]@{
            label = $Label; arm = $Arm; sample = $Index; ok = $false
            executor_exit = $executorExit
            t0_to_t1_ms = $null
            delta_vs_accepted_ms = $null
            run = $runName
            game_crashed = $crashed
            game_log = [string]$daemonRecord.log
            telemetry = $telemetry
            reason = if ($crashed) { 'game crashed before T1' } else { 'executor failed or produced no receipt' }
            executor_tail = $tail
        }
    }

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $correctnessFailures = New-Object 'System.Collections.Generic.List[string]'
    if ($receipt.schema -cne 'smr.ralph.surface-only-acceptance-receipt.v1') { $correctnessFailures.Add('schema') }
    if (-not $receipt.ok) { $correctnessFailures.Add('receipt.ok') }
    if ($receipt.diagnostic_only -ne $false) { $correctnessFailures.Add('diagnostic_only') }
    if ([int]$receipt.generator_run_file_count -ne 1) { $correctnessFailures.Add('generator_run_file_count') }
    if ($receipt.underground_access_included -ne $false) { $correctnessFailures.Add('underground_access_included') }
    if ($receipt.underground_release_invoked -ne $false) { $correctnessFailures.Add('underground_release_invoked') }
    if ([string]$receipt.contract_sha256 -cne $contractSha) { $correctnessFailures.Add('contract_sha256') }
    if ([int64]$receipt.planner.plan_digest -ne 1232699597) { $correctnessFailures.Add('plan_digest') }
    if ([int64]$receipt.planner.outer_passage_plan_digest -ne 1232699597) { $correctnessFailures.Add('outer_passage_plan_digest') }
    if ([int64]$receipt.planner.validation_z_digest -ne 1418606361) { $correctnessFailures.Add('validation_z_digest') }
    if ([string]$receipt.planner.single_flush_tuple -cne 'optimized') { $correctnessFailures.Add('single_flush_tuple') }

    $daemon = Get-Content -LiteralPath 'D:\PROJS\SMR\smr-harness\.daemon.json' -Raw | ConvertFrom-Json
    $logText = Get-Content -LiteralPath ([string]$daemon.log) -Raw
    $forbidden = @([regex]::Matches($logText, '(?im)BlankUnderground|Underground map holder|slot[- ]?2 generation')).Count
    if ($forbidden -ne 0) { $correctnessFailures.Add('forbidden_underground_markers') }

    $teardownDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $remaining = @(Get-Process -Name MarsDebug -ErrorAction SilentlyContinue).Count
        if ($remaining -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $teardownDeadline)
    if ($remaining -ne 0) { $correctnessFailures.Add('tracked_teardown') }

    return [ordered]@{
        label = $Label
        arm = $Arm
        sample = $Index
        ok = ($correctnessFailures.Count -eq 0)
        executor_exit = $executorExit
        t0_to_t1_ms = [double]$receipt.t0_to_t1_ms
        delta_vs_accepted_ms = [Math]::Round([double]$receipt.t0_to_t1_ms - $acceptedBestMs, 4)
        run = $runName
        receipt = $receiptPath.Substring($repo.Length + 1).Replace('\', '/')
        contract_sha256 = $contractSha
        forbidden_log_markers = $forbidden
        correctness_failures = @($correctnessFailures)
        t0_boundary = $(if ($receipt.PSObject.Properties['t0_boundary']) {
            [string]$receipt.t0_boundary } else { 'run-file-submission' })
        submit_to_t0_ms = $(if ($receipt.PSObject.Properties['submit_to_t0_ms']) {
            $receipt.submit_to_t0_ms } else { $null })
        telemetry = $telemetry
    }
}

if (@(Get-Process -Name MarsDebug -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'MarsDebug already exists; sequential cold ownership is unavailable'
}
foreach ($required in @($templateStage, $templateContractPath, $executor, $payloadManifestPath, $harness)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "required replication input is missing: $required" }
}
$payloadManifest = Assert-ExactAcceptedPayload
Write-Output 'REPLICATION_PREMISE_OK exact iter266b payload, deployment 35/35'

$results = New-Object 'System.Collections.Generic.List[object]'
# Randomised pair order: each consecutive pair gets control/candidate in a coin-flip
# order, so any residual position effect cannot align with an arm.
$armPlan = @()
if (-not [string]::IsNullOrWhiteSpace($CandidateTemplateStage)) {
    $rng = if ($Seed -ne 0) { New-Object Random($Seed) } else { New-Object Random }
    for ($pair = 0; $pair -lt [Math]::Ceiling($Repeat / 2.0); $pair += 1) {
        if ($rng.Next(2) -eq 0) { $armPlan += @('control', 'candidate') }
        else { $armPlan += @('candidate', 'control') }
    }
    Write-Output ('ARM_PLAN ' + (($armPlan | Select-Object -First $Repeat) -join ','))
}

for ($index = 1; $index -le $Repeat; $index += 1) {
    $arm = if ($armPlan.Count -gt 0) { $armPlan[$index - 1] } else { 'control' }
    $stageRoot = if ($arm -eq 'candidate') { [IO.Path]::GetFullPath($CandidateTemplateStage) } else { $templateStage }
    $record = Invoke-OneSample -Index $index -PayloadManifest $payloadManifest -StageRoot $stageRoot -Arm $arm
    $results.Add($record)
    # OrderedDictionary has no `+`; build one and copy the record's keys in order.
    $ledgerRecord = [ordered]@{
        schema = 'smr.ralph.accepted-baseline-replication.v1'
        completed_utc = [DateTime]::UtcNow.ToString('o')
    }
    foreach ($key in $record.Keys) { $ledgerRecord[$key] = $record[$key] }
    Add-Content -LiteralPath $ledgerPath -Encoding UTF8 `
        -Value ($ledgerRecord | ConvertTo-Json -Compress -Depth 6)
    Write-Output ('REPLICATION_{0}_{1}_SAMPLE_{2:d2} ok={3} ms={4:R}' -f
        $Label, $arm, $index, $record.ok, $record.t0_to_t1_ms)
}

$valid = @($results | Where-Object { $_.ok -and $null -ne $_.t0_to_t1_ms } |
    ForEach-Object { [double]$_.t0_to_t1_ms })
if ($valid.Count -eq 0) {
    Write-Output 'REPLICATION_SUMMARY no valid sample'
    exit 1
}
$sorted = @($valid | Sort-Object)
$median = if ($sorted.Count % 2 -eq 1) { $sorted[[int](($sorted.Count - 1) / 2)] }
    else { ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
[ordered]@{
    schema = 'smr.ralph.accepted-baseline-replication-summary.v1'
    label = $Label
    accepted_best_ms = $acceptedBestMs
    valid_samples = $valid.Count
    samples_ms = $sorted
    minimum_ms = $sorted[0]
    median_ms = $median
    maximum_ms = $sorted[$sorted.Count - 1]
    median_delta_vs_accepted_ms = [Math]::Round($median - $acceptedBestMs, 4)
    reproduced_accepted_best = ($sorted[0] -lt $acceptedBestMs)
    ledger = $ledgerPath.Substring($repo.Length + 1).Replace('\', '/')
} | ConvertTo-Json -Depth 6
