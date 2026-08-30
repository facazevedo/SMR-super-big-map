param(
    [Parameter(Mandatory = $true)][string]$ContractPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ContractSha256,
    [Parameter(Mandatory = $true)][string]$CacheRoot,
    [switch]$Launch
)

# Content-addressed loop entry point for a cold Surface-only acceptance.  It caches
# only the offline static receipt; the executor remains the sole owner of deploy,
# T0/T1, post-T1 validation, tracked quit, and restoration.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required file missing: $Path" }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-TreeManifest([string]$Root, [string[]]$RelativeRoots) {
    $items = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relativeRoot in $RelativeRoots) {
        $path = Join-Path $Root $relativeRoot
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $file = Get-Item -LiteralPath $path
            $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            $items.Add(('{0}|{1}|{2}' -f $relative, $file.Length, (Get-Sha256 $file.FullName)))
            continue
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $path -File -Recurse | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            $items.Add(('{0}|{1}|{2}' -f $relative, $file.Length, (Get-Sha256 $file.FullName)))
        }
    }
    ($items | Sort-Object) -join "`n"
}

function Require-GitValue([string[]]$Arguments, [string]$Description) {
    $value = (& git @Arguments).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { throw "unable to resolve $Description" }
    $value
}

if ((Get-Sha256 $ContractPath) -cne $ContractSha256.ToUpperInvariant()) { throw 'contract SHA-256 mismatch' }
$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
if ($contract.schema -cne 'smr.ralph.surface-only-acceptance-contract.v1') { throw 'unsupported contract schema' }
$repo = [IO.Path]::GetFullPath([string]$contract.repo)
$executor = Join-Path $repo '_ralph\tools\execute_surface_only_acceptance.ps1'
$checker = Join-Path $repo '_ralph\tools\check_surface_only_acceptance_harness.py'
$reference = Join-Path $repo '_ralph\tools\surface_loading_reference.py'
$runParity = Join-Path $repo '_ralph\tools\parity\run_parity.py'
$deployTool = Join-Path $repo '_ralph\tools\deploy.py'
$stage = [IO.Path]::GetFullPath([string]$contract.stage)
$harness = [IO.Path]::GetFullPath([string]$contract.harness)
$gameExecutable = [IO.Path]::GetFullPath([string]$contract.game_executable)
$interpreterPath = [IO.Path]::GetFullPath([string]$contract.interpreter_path)
$luaCompiler = [IO.Path]::GetFullPath([string]$contract.luac)
foreach ($required in @('task_identity', 'scenario_identity', 'interpreter_command')) {
    if ([string]::IsNullOrWhiteSpace([string]$contract.$required)) { throw "contract missing loop identity: $required" }
}
foreach ($path in @($executor, $checker, $reference, $runParity, $deployTool, $stage, $harness, $gameExecutable, $interpreterPath, $luaCompiler)) {
    if ($path -eq $stage) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "required loop stage missing: $path" }
        continue
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "required loop tool missing: $path" }
}

# These are every tracked parity input that the static checker can render or parse.
# Hashing them is inexpensive and makes a cache hit fail closed if any affected
# generator/checker input changes.  No candidate-stage or deployed file is touched.
$parityFiles = @(& git -C $repo ls-files -- _ralph/tools/parity)
if ($LASTEXITCODE -ne 0 -or $parityFiles.Count -eq 0) { throw 'unable to enumerate static parity inputs' }
$headCommit = Require-GitValue @('-C', $repo, 'rev-parse', 'HEAD') 'HEAD commit'
$headTree = Require-GitValue @('-C', $repo, 'rev-parse', 'HEAD^{tree}') 'HEAD tree'
$auditOutput = & python $deployTool audit 2>&1
$auditExit = $LASTEXITCODE
try { $audit = ($auditOutput -join "`n") | ConvertFrom-Json } catch { throw 'external deploy audit emitted invalid JSON' }
if ($auditExit -ne 0 -or $audit.ok -ne $true -or $audit.source_files -ne $contract.expected_deploy_file_count -or
    $audit.destination_files -ne $contract.expected_deploy_file_count) {
    throw 'external deploy audit is not the exact disabled 36-file topology'
}
$deployedCode = Split-Path -Parent ([IO.Path]::GetFullPath([string]$contract.deployed_config))
$deployedRoot = Split-Path -Parent $deployedCode
$sourcePayloadManifest = Get-TreeManifest $repo @('Code', 'Images', 'metadata.lua', 'items.lua')
$deployedPayloadManifest = Get-TreeManifest $deployedRoot @('.')
if ($sourcePayloadManifest -ne $deployedPayloadManifest) { throw 'external full payload manifest/hash mismatch' }
$stageManifest = Get-TreeManifest $stage @('.')
$launchCommand = ('{0} -NoLogo -NoProfile -ExecutionPolicy Bypass -File {1} -ContractPath {2} -ContractSha256 {3} -Launch' -f
    $interpreterPath, $executor, ([IO.Path]::GetFullPath($ContractPath)), $ContractSha256.ToUpperInvariant())
$material = [ordered]@{
    contract = Get-Sha256 $ContractPath
    head_commit = $headCommit
    head_tree = $headTree
    task_identity = [string]$contract.task_identity
    scenario_identity = [string]$contract.scenario_identity
    executor = Get-Sha256 $executor
    checker = Get-Sha256 $checker
    reference = Get-Sha256 $reference
    run_parity = Get-Sha256 $runParity
    deploy_tool = Get-Sha256 $deployTool
    harness = Get-Sha256 $harness
    game_executable = Get-Sha256 $gameExecutable
    interpreter = Get-Sha256 $interpreterPath
    lua_compiler = Get-Sha256 $luaCompiler
    interpreter_command = [string]$contract.interpreter_command
    live_executor_command = $launchCommand
    source_payload_manifest = $sourcePayloadManifest
    deployed_payload_manifest = $deployedPayloadManifest
    stage_manifest = $stageManifest
}
foreach ($relative in $parityFiles | Sort-Object) {
    $path = Join-Path $repo $relative
    $material["parity:$relative"] = Get-Sha256 $path
}
$canonical = (($material.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n") + "`n"
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $cacheKey = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '')
} finally {
    $sha.Dispose()
}
$cacheRootFull = [IO.Path]::GetFullPath($CacheRoot)
if (-not (Test-Path -LiteralPath $cacheRootFull -PathType Container)) {
    New-Item -ItemType Directory -Path $cacheRootFull -Force | Out-Null
}
$cachePath = Join-Path $cacheRootFull ("surface_static_$cacheKey.json")
$cacheHit = $false
if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
    try {
        $cached = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        $cacheHit = $cached.schema -ceq 'smr.ralph.surface-loop-static-cache.v1' -and
            $cached.cache_key -ceq $cacheKey -and $cached.contract_sha256 -ceq $ContractSha256.ToUpperInvariant() -and
            $cached.ok -eq $true -and $cached.material_json -ceq $canonical
    } catch { $cacheHit = $false }
}
if (-not $cacheHit) {
    $checkerOutput = & python $checker 2>&1
    if ($LASTEXITCODE -ne 0) { throw "offline Surface checker failed: $($checkerOutput -join "`n")" }
    try { $checkerReceipt = ($checkerOutput -join "`n") | ConvertFrom-Json } catch { throw 'offline Surface checker emitted invalid JSON' }
    if ($checkerReceipt.ok -ne $true) { throw 'offline Surface checker returned non-accepting receipt' }
    $cache = [ordered]@{
        schema = 'smr.ralph.surface-loop-static-cache.v1'
        cache_key = $cacheKey
        contract_sha256 = $ContractSha256.ToUpperInvariant()
        material_json = $canonical
        checker_schema = $checkerReceipt.schema
        checker_sha256 = $material.checker
        generated_lua_parse = $checkerReceipt.generator_lua_parse
        ok = $true
    }
    Write-Utf8NoBom $cachePath (($cache | ConvertTo-Json -Depth 8 -Compress) + "`n")
}

if (-not $Launch) {
    Write-Output ("SURFACE_LOOP_PREFLIGHT_OK cache_hit={0} cache_key={1} cache_path={2}" -f $cacheHit, $cacheKey, $cachePath)
    return
}

# There is precisely one live executor invocation.  It performs the sole deploy,
# event-driven T1 waits, bounded post-T1 scalar/hash/census checks, tracked quit,
# and restoration.  This wrapper has no underground command or route.
try {
    & $interpreterPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $executor -ContractPath $ContractPath -ContractSha256 $ContractSha256 -Launch
    if ($LASTEXITCODE -ne 0) { throw "surface executor exited $LASTEXITCODE" }
    Write-Output ("SURFACE_LOOP_ACCEPT cache_hit={0} cache_key={1}" -f $cacheHit, $cacheKey)
} catch {
    Write-Error ("SURFACE_LOOP_REJECT cache_hit={0} cache_key={1} cause={2}" -f $cacheHit, $cacheKey, $_.Exception.Message)
    exit 1
}
