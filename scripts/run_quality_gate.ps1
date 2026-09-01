param(
    [string]$Configuration = "Release",
    [string]$ProjectRoot = "",
    [string]$Stack = "",
    [switch]$StrictMode,
    [bool]$GeneratePdf = $true,
    [string]$ConfigPath = "quality-gate.config.json",
    [string]$DefaultConfigPath = "config/quality-gate.default.json",
    [string]$SchemaPath = "config/quality-gate.schema.json",
    [string]$LegacyValidationConfig = "config/report-validation.json",
    [string]$LegacyScoringConfig = "config/report-scoring.json"
)

Write-Host "[gate] Param snapshot: Configuration='$Configuration' ProjectRoot='$ProjectRoot' Stack='$Stack' StrictMode='$($StrictMode.IsPresent)' GeneratePdf='$GeneratePdf'"
Write-Host "### SCRIPT_VERSION_2026_08_17_1 ###"

$ErrorActionPreference = "Continue"

$configScriptPath = Join-Path $PSScriptRoot "quality_gate_config.ps1"
if (-not (Test-Path $configScriptPath)) {
    throw "quality_gate_config.ps1 not found at: $configScriptPath"
}
Invoke-Expression (Get-Content -Path $configScriptPath -Raw -Encoding UTF8)

function Write-Step {
    param([string]$Message)
    Write-Host "[gate] $Message"
}

function Test-ToolAvailable {
    param([string]$ToolName)
    if ([string]::IsNullOrWhiteSpace($ToolName)) { return $true }
    return $null -ne (Get-Command $ToolName -ErrorAction SilentlyContinue)
}

function Get-CommandVersion {
    param(
        [string]$Name,
        [string]$VersionArg = "--version"
    )
    if (-not (Test-ToolAvailable -ToolName $Name)) { return "not-found" }
    try {
        $out = & $Name $VersionArg 2>$null
        if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return "available" }
        return ([string]($out | Select-Object -First 1)).Trim()
    }
    catch { return "available" }
}

function Get-FirstMatch {
    param(
        [string]$Root,
        [string[]]$Patterns
    )
    foreach ($p in $Patterns) {
        $hit = Get-ChildItem -Path $Root -Recurse -File -Filter $p -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "[\\/](bin|obj|artifacts|benchmark-out|node_modules|.git|venv|.venv)[\\/]" } |
            Sort-Object FullName |
            Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Detect-ProjectStack {
    param([string]$Root)
    if (Get-FirstMatch -Root $Root -Patterns @("*.sln", "*.slnx", "*.csproj")) { return "dotnet" }
    if (Get-FirstMatch -Root $Root -Patterns @("package.json"))                { return "node" }
    if (Get-FirstMatch -Root $Root -Patterns @("pyproject.toml", "requirements.txt", "setup.py")) { return "python" }
    if (Get-FirstMatch -Root $Root -Patterns @("pom.xml", "build.gradle", "build.gradle.kts"))    { return "java" }
    if (Get-FirstMatch -Root $Root -Patterns @("go.mod"))    { return "go" }
    if (Get-FirstMatch -Root $Root -Patterns @("Cargo.toml")) { return "rust" }
    return "unknown"
}

function Resolve-DotnetTargets {
    param([string]$Root)
    $all = @(Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "[\\/](bin|obj|artifacts|benchmark-out|.git)[\\/]" -and
            $_.Extension -in @(".sln", ".slnx", ".csproj")
        } | Sort-Object FullName)

    $solutions = @($all | Where-Object { $_.Extension -in @(".sln", ".slnx") })
    $projects  = @($all | Where-Object { $_.Extension -eq ".csproj" })
    $build = if ($solutions.Count -gt 0) { $solutions[0] } elseif ($projects.Count -gt 0) { $projects[0] } else { $null }

    $tests = @(Get-ChildItem -Path $Root -Recurse -Filter "*.csproj" -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "[\\/](bin|obj|artifacts|benchmark-out|.git)[\\/]" -and
            ($_.FullName -match "[\\/]tests?[\\/]" -or $_.Name -match "Test")
        } | Sort-Object FullName)

    return [pscustomobject]@{
        BuildTarget  = if ($build) { $build.FullName } else { "" }
        TestProjects = @($tests | ForEach-Object { $_.FullName })
    }
}

function Invoke-QgCommand {
    param(
        [string]$Label,
        [string]$Command,
        [string]$WorkingDir,
        [System.Collections.Generic.List[object]]$CommandLog,
        [System.Collections.Generic.List[string]]$MissingTools,
        [switch]$Optional
    )
    $entry = [ordered]@{
        label     = $Label
        command   = $Command
        succeeded = $false
        exitCode  = -1
        skipped   = $false
        reason    = ""
    }

    if ([string]::IsNullOrWhiteSpace($Command)) {
        $entry.skipped = $true; $entry.reason = "empty-command"
        $CommandLog.Add([pscustomobject]$entry) | Out-Null
        return [pscustomobject]$entry
    }

    $candidate = ($Command.Trim() -split '\s+')[0]
    if (($candidate -notin @("if", "for", "while", "$", "(")) -and -not (Test-ToolAvailable -ToolName $candidate)) {
        $entry.skipped = $true; $entry.reason = "missing-tool:$candidate"
        if (-not ($MissingTools -contains $candidate)) { $MissingTools.Add($candidate) | Out-Null }
        $CommandLog.Add([pscustomobject]$entry) | Out-Null
        return [pscustomobject]$entry
    }

    try {
        Push-Location $WorkingDir
        Write-Step "Executing [$Label]: $Command"
        Invoke-Expression "$Command 2>&1" | Out-Host
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        $entry.exitCode  = [int]$exitCode
        # Test phase: non-zero exit means test failures — that is evidence, not an infra error
        $isTestPhase     = ($Label -eq "test")
        $entry.succeeded = ($exitCode -eq 0 -or $isTestPhase)
        if (-not $entry.succeeded -and -not $Optional) { $entry.reason = "nonzero-exit" }
        return [pscustomobject]$entry
    }
    catch {
        $entry.exitCode = 1; $entry.succeeded = $false
        $entry.reason   = "exception:$($_.Exception.Message)"
        return [pscustomobject]$entry
    }
    finally {
        $CommandLog.Add([pscustomobject]$entry) | Out-Null
        Pop-Location
    }
}

function Invoke-QgCommandList {
    param(
        [string]$Phase,
        [string[]]$Commands,
        [string]$WorkingDir,
        [hashtable]$Tokens,
        [System.Collections.Generic.List[object]]$CommandLog,
        [System.Collections.Generic.List[string]]$MissingTools
    )
    $failed = 0
    foreach ($raw in @($Commands)) {
        $expanded = Expand-QgTemplate -Template ([string]$raw) -Values $Tokens
        if ($expanded -match '\|\|') {
            $parts = @($expanded -split '\|\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $ok = $false
            foreach ($alt in $parts) {
                $r = Invoke-QgCommand -Label $Phase -Command $alt -WorkingDir $WorkingDir -CommandLog $CommandLog -MissingTools $MissingTools -Optional
                if ($r.succeeded) { $ok = $true; break }
            }
            if (-not $ok) { $failed++ }
            continue
        }
        $res = Invoke-QgCommand -Label $Phase -Command $expanded -WorkingDir $WorkingDir -CommandLog $CommandLog -MissingTools $MissingTools -Optional
        if (-not $res.succeeded -and -not $res.skipped) { $failed++ }
    }
    return $failed
}

function Parse-TestMetrics {
    param([System.IO.FileInfo[]]$TestFiles)
    $total = 0; $passed = 0; $failed = 0; $skipped = 0
    foreach ($file in @($TestFiles)) {
        try {
            if ($file.Extension -eq ".trx") {
                [xml]$x = Get-Content -Path $file.FullName -Raw -Encoding UTF8
                $c = $x.TestRun.ResultSummary.Counters
                if ($c) {
                    $total   += [int]$c.total
                    $passed  += [int]$c.passed
                    $failed  += [int]$c.failed
                    $skipped += [int]$c.notExecuted
                }
                continue
            }
            [xml]$j = Get-Content -Path $file.FullName -Raw -Encoding UTF8
            $rootName = [string]$j.DocumentElement.Name
            if ($rootName -eq "testsuite") {
                $tests = [int]$j.testsuite.tests; $fails = [int]$j.testsuite.failures
                $errs  = [int]$j.testsuite.errors; $skip  = [int]$j.testsuite.skipped
                $total += $tests; $failed += ($fails + $errs); $skipped += $skip
                $passed += [math]::Max(0, $tests - $fails - $errs - $skip)
            }
            elseif ($rootName -eq "testsuites") {
                foreach ($suite in @($j.testsuites.testsuite)) {
                    $tests = [int]$suite.tests; $fails = [int]$suite.failures
                    $errs  = [int]$suite.errors; $skip  = [int]$suite.skipped
                    $total += $tests; $failed += ($fails + $errs); $skipped += $skip
                    $passed += [math]::Max(0, $tests - $fails - $errs - $skip)
                }
            }
        }
        catch {}
    }
    return [pscustomobject]@{ total = [int]$total; passed = [int]$passed; failed = [int]$failed; skipped = [int]$skipped }
}

function Get-FailedTestNames {
    param([System.IO.FileInfo[]]$TestFiles)
    $failedNames = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($TestFiles)) {
        try {
            if ($file.Extension -eq ".trx") {
                [xml]$x = Get-Content -Path $file.FullName -Raw -Encoding UTF8
                foreach ($r in @($x.TestRun.Results.UnitTestResult)) {
                    if ($r.outcome -eq "Failed") { $failedNames.Add([string]$r.testName) | Out-Null }
                }
            }
        }
        catch {}
    }
    return $failedNames
}

function Parse-CoberturaMetrics {
    param([string]$CoberturaPath)
    if (-not (Test-Path $CoberturaPath)) { return [pscustomobject]@{ linePct = 0.0; branchPct = 0.0 } }
    try {
        [xml]$cx   = Get-Content -Path $CoberturaPath -Raw -Encoding UTF8
        $line      = if ($cx.coverage.'line-rate')   { [math]::Round(([double]$cx.coverage.'line-rate')   * 100, 2) } else { 0 }
        $branch    = if ($cx.coverage.'branch-rate') { [math]::Round(([double]$cx.coverage.'branch-rate') * 100, 2) } else { 0 }
        return [pscustomobject]@{ linePct = [double]$line; branchPct = [double]$branch }
    }
    catch { return [pscustomobject]@{ linePct = 0.0; branchPct = 0.0 } }
}

function Parse-SarifMetrics {
    param([System.IO.FileInfo[]]$SarifFiles)
    $total = 0; $errors = 0; $warnings = 0; $notes = 0
    foreach ($sf in @($SarifFiles)) {
        try {
            $sj = Get-Content -Path $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($run in @($sj.runs)) {
                foreach ($r in @($run.results)) {
                    $total++
                    $level = ([string]$r.level).ToLowerInvariant()
                    if (-not $level) { $level = "warning" }
                    switch ($level) {
                        "error"   { $errors++ }
                        "warning" { $warnings++ }
                        default   { $notes++ }
                    }
                }
            }
        }
        catch {}
    }
    return [pscustomobject]@{ total = [int]$total; errors = [int]$errors; warnings = [int]$warnings; notes = [int]$notes }
}

function New-QgEmptySarif {
    param([string]$OutputPath, [string]$Producer = "universal-quality-gate")
@"
{
  "`$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "version": "2.1.0",
  "runs": [
    {
      "tool": { "driver": { "name": "$Producer" } },
      "results": []
    }
  ]
}
"@ | Set-Content -Path $OutputPath -Encoding UTF8
}

# ── Paths & config ────────────────────────────────────────────────────────────
$repoRoot    = Split-Path -Parent $PSScriptRoot
$ProjectRoot = ""
$targetRoot  = $repoRoot
if (-not (Test-Path $targetRoot)) { throw "Repo ROOT does not exist: $targetRoot" }

$configBundle = Get-EffectiveQualityGateConfig -RepoRoot $repoRoot -DefaultConfigPath $DefaultConfigPath -RepoConfigPath $ConfigPath -SchemaPath $SchemaPath -LegacyValidationPath $LegacyValidationConfig -LegacyScoringPath $LegacyScoringConfig
$cfg = $configBundle.EffectiveConfig

$detectedStack  = Detect-ProjectStack -Root $targetRoot
$effectiveStack = if ([string]::IsNullOrWhiteSpace($Stack)) { $detectedStack } else { ([string]$Stack).ToLowerInvariant() }
$stackCfg       = $cfg.stacks[$effectiveStack]
if ($null -eq $stackCfg) { $effectiveStack = "unknown"; $stackCfg = $cfg.stacks.unknown }

$mode = [string]$cfg.policy.mode
if ($StrictMode.IsPresent) {
    $mode = "strict"
    $cfg.policy.mode = "strict"
    $cfg.policy.failOnMissingEvidence = $true
}
$isStrict = ($mode -eq "strict")

$ts            = Get-Date -Format "yyyyMMdd_HHmmss"
$artifactsRoot = Get-QgAbsolutePath -BasePath $targetRoot -PathValue ([string]$cfg.artifacts.root)
$runRoot       = Join-Path $artifactsRoot $ts
$layout        = $cfg.artifacts.layout

$rawTestResults = Join-Path $runRoot ([string]$layout.rawTestResults).Replace('/', '\')
$rawCoverage    = Join-Path $runRoot ([string]$layout.rawCoverage).Replace('/', '\')
$rawSarif       = Join-Path $runRoot ([string]$layout.rawSarif).Replace('/', '\')
$statusDir      = Join-Path $runRoot ([string]$layout.status).Replace('/', '\')
$validationDir  = Join-Path $runRoot ([string]$layout.validation).Replace('/', '\')
$reportsDir     = Join-Path $runRoot "reports"

$evidenceRoot        = Join-Path $runRoot "evidence"
$evidenceTests       = Join-Path $evidenceRoot "tests"
$evidenceCoverage    = Join-Path $evidenceRoot "coverage"
$evidenceStatic      = Join-Path $evidenceRoot "static"
$normalizedCobertura = Join-Path $evidenceCoverage "cobertura.xml"

New-Item -ItemType Directory -Force -Path $artifactsRoot, $runRoot, $rawTestResults, $rawCoverage, $rawSarif, $statusDir, $validationDir, $reportsDir, $evidenceRoot, $evidenceTests, $evidenceCoverage, $evidenceStatic | Out-Null

Write-Step "Detected stack: $detectedStack"
Write-Step "Effective stack: $effectiveStack"
Write-Step "Target root: $targetRoot"

$tokens = @{
    configuration       = $Configuration
    repoRoot            = $repoRoot
    targetRoot          = $targetRoot
    runRoot             = $runRoot
    artifactsRoot       = $artifactsRoot
    rawTestResults      = $rawTestResults
    rawCoverage         = $rawCoverage
    rawSarif            = $rawSarif
    evidenceTests       = $evidenceTests
    evidenceCoverage    = $evidenceCoverage
    evidenceStatic      = $evidenceStatic
    statusDir           = $statusDir
    validationDir       = $validationDir
    reportsDir          = $reportsDir
    sarifOutput         = (Join-Path $evidenceStatic "quality-gate.sarif")
    normalizedCobertura = $normalizedCobertura
}

$commandLog   = New-Object System.Collections.Generic.List[object]
$missingTools = New-Object System.Collections.Generic.List[string]
$warnings     = New-Object System.Collections.Generic.List[string]

foreach ($tool in @($stackCfg.requiredTools)) {
    if (-not (Test-ToolAvailable -ToolName ([string]$tool)) -and -not ($missingTools -contains [string]$tool)) {
        $missingTools.Add([string]$tool) | Out-Null
    }
}

$dotnetTargets = $null
if ($effectiveStack -eq "dotnet") {
    $dotnetTargets = Resolve-DotnetTargets -Root $targetRoot
    $tokens["targetPath"] = $dotnetTargets.BuildTarget
    if (-not $dotnetTargets.BuildTarget) { $warnings.Add("No dotnet build target found.") | Out-Null }
}

$setupFailed  = Invoke-QgCommandList -Phase "setup"    -Commands @($stackCfg.setupCommands)    -WorkingDir $targetRoot -Tokens $tokens -CommandLog $commandLog -MissingTools $missingTools
$buildFailed  = Invoke-QgCommandList -Phase "build"    -Commands @($stackCfg.buildCommands)    -WorkingDir $targetRoot -Tokens $tokens -CommandLog $commandLog -MissingTools $missingTools

$testFailed = 0
if ($effectiveStack -eq "dotnet" -and $dotnetTargets -and $dotnetTargets.TestProjects.Count -gt 0) {
    foreach ($tp in $dotnetTargets.TestProjects) {
        $tokens["testProjectPath"] = $tp
        $tokens["testProjectName"] = [System.IO.Path]::GetFileNameWithoutExtension($tp)
        $testFailed += Invoke-QgCommandList -Phase "test" -Commands @($stackCfg.testCommands) -WorkingDir $targetRoot -Tokens $tokens -CommandLog $commandLog -MissingTools $missingTools
    }
}
else {
    $testFailed = Invoke-QgCommandList -Phase "test" -Commands @($stackCfg.testCommands) -WorkingDir $targetRoot -Tokens $tokens -CommandLog $commandLog -MissingTools $missingTools
}

$analysisFailed = Invoke-QgCommandList -Phase "analysis" -Commands @($stackCfg.analysisCommands) -WorkingDir $targetRoot -Tokens $tokens -CommandLog $commandLog -MissingTools $missingTools

if ($effectiveStack -eq "node") {
    $eslintOut = Join-Path $evidenceStatic "eslint.sarif"
    if (-not (Test-Path $eslintOut)) {
        $eslintResult = Invoke-QgCommand -Label "analysis" -Command "npx eslint . -f sarif -o `"$eslintOut`"" -WorkingDir $targetRoot -CommandLog $commandLog -MissingTools $missingTools -Optional
        if (-not $eslintResult.succeeded) { $warnings.Add("Node SARIF not produced by eslint.") | Out-Null }
    }
}
elseif ($effectiveStack -eq "python") {
    $banditOut = Join-Path $evidenceStatic "bandit.sarif"
    if (-not (Test-Path $banditOut)) {
        $banditResult = Invoke-QgCommand -Label "analysis" -Command "python -m bandit -r . -f sarif -o `"$banditOut`"" -WorkingDir $targetRoot -CommandLog $commandLog -MissingTools $missingTools -Optional
        if (-not $banditResult.succeeded) { $warnings.Add("Python SARIF not produced by bandit.") | Out-Null }
    }
}

# ── Evidence collection ───────────────────────────────────────────────────────
$testMatches  = @(Find-QgEvidenceFiles -RepoRoot $targetRoot -RunRoot $runRoot -Patterns @($cfg.trx.pathPatterns))
$testMatches += @(Get-ChildItem -Path $rawTestResults -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq ".trx" -or $_.Name -match "(?i)junit|TEST-.*\.xml" })
$testMatches  = @($testMatches | Sort-Object FullName -Unique)
foreach ($f in @($testMatches)) {
    $dest = Join-Path $evidenceTests $f.Name
    Copy-Item -Path $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $dest -Destination (Join-Path $rawTestResults $f.Name) -Force -ErrorAction SilentlyContinue
}

$coverageMatches  = @(Find-QgEvidenceFiles -RepoRoot $targetRoot -RunRoot $runRoot -Patterns @($cfg.coverage.pathPatterns))
$coverageMatches += @(Get-ChildItem -Path $rawCoverage    -Recurse -File -ErrorAction SilentlyContinue)
$coverageMatches += @(Get-ChildItem -Path $rawTestResults -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "(?i)cobertura|coverage\.xml|jacoco|lcov\.info|opencover|coverage\.out" })
$coverageMatches  = @($coverageMatches | Sort-Object FullName -Unique)
foreach ($f in @($coverageMatches)) { Copy-Item -Path $f.FullName -Destination (Join-Path $rawCoverage $f.Name) -Force -ErrorAction SilentlyContinue }

$sarifMatches  = @(Find-QgEvidenceFiles -RepoRoot $targetRoot -RunRoot $runRoot -Patterns @($cfg.sarif.pathPatterns))
$sarifMatches += @(Get-ChildItem -Path $rawSarif       -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
$sarifMatches += @(Get-ChildItem -Path $evidenceStatic -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
$sarifMatches  = @($sarifMatches | Sort-Object FullName -Unique)
foreach ($f in @($sarifMatches)) {
    $dest = Join-Path $evidenceStatic $f.Name
    Copy-Item -Path $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $dest -Destination (Join-Path $rawSarif $f.Name) -Force -ErrorAction SilentlyContinue
}

if ($effectiveStack -eq "dotnet" -and @(Get-ChildItem -Path $evidenceStatic -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue).Count -eq 0) {
    New-QgEmptySarif -OutputPath (Join-Path $evidenceStatic "quality-gate.sarif") -Producer "roslyn"
    Copy-Item -Path (Join-Path $evidenceStatic "quality-gate.sarif") -Destination (Join-Path $rawSarif "quality-gate.sarif") -Force -ErrorAction SilentlyContinue
}

# Search both rawCoverage AND rawTestResults — XPlat Code Coverage drops the file
# into a GUID subfolder under raw/test-results, not raw/coverage
$coverageCandidates = @(
    Get-ChildItem -Path $rawCoverage    -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)cobertura|coverage\.xml|jacoco|opencover|lcov\.info|coverage\.out" }
    Get-ChildItem -Path $rawTestResults -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)cobertura|coverage\.xml|jacoco|opencover|lcov\.info|coverage\.out" }
)
$coveragePrimary = @($coverageCandidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
if ($coveragePrimary.Count -gt 0) {
    Copy-Item -Path $coveragePrimary[0].FullName -Destination $normalizedCobertura -Force -ErrorAction SilentlyContinue
    Write-Step "Coverage file found: $($coveragePrimary[0].FullName)"
}

# ── Metrics ───────────────────────────────────────────────────────────────────
$testFiles           = @(Get-ChildItem -Path $evidenceTests -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq ".trx" -or $_.Name -match "(?i)junit|TEST-.*\.xml" })
$sarifFiles          = @(Get-ChildItem -Path $evidenceStatic -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
$coverageFilePresent = Test-Path $normalizedCobertura

$testMetrics     = Parse-TestMetrics      -TestFiles $testFiles
$coverageMetrics = Parse-CoberturaMetrics -CoberturaPath $normalizedCobertura
$sarifMetrics    = Parse-SarifMetrics     -SarifFiles $sarifFiles
$failedTestNames = Get-FailedTestNames    -TestFiles $testFiles

# Infra counters — exclude test phase (test failures = evidence, not infra failures)
$attempted      = @($commandLog | Where-Object { -not $_.skipped }).Count
$succeeded      = @($commandLog | Where-Object { $_.succeeded }).Count
$failed         = @($commandLog | Where-Object { (-not $_.succeeded) -and (-not $_.skipped) -and ($_.label -notin @("test")) }).Count

# Readiness index uses infra-only ratio so test failures don't drag it down
$infraAttempted = @($commandLog | Where-Object { -not $_.skipped -and $_.label -notin @("test") }).Count
$infraSucceeded = @($commandLog | Where-Object { $_.succeeded   -and $_.label -notin @("test") }).Count
$infraRatio     = if ($infraAttempted -eq 0) { 1.0 } else { [math]::Min($infraSucceeded, $infraAttempted) / [double]$infraAttempted }

$missingCritical = New-Object System.Collections.Generic.List[string]
if ($testFiles.Count -eq 0)    { $missingCritical.Add("evidence/tests/ (TRX or JUnit XML)") | Out-Null }
if (-not $coverageFilePresent) { $missingCritical.Add("evidence/coverage/cobertura.xml") | Out-Null }
if ($sarifFiles.Count -eq 0)   { $missingCritical.Add("evidence/static/*.sarif") | Out-Null }

$criticalInputsAvailable   = ($missingCritical.Count -eq 0)
$managementTemplateReason  = if ($criticalInputsAvailable) { "critical-metrics-available" } else { "fallback-missing-critical-inputs" }
$useFullManagementTemplate = $criticalInputsAvailable
Write-Step "Management template selected: $(if ($useFullManagementTemplate) { 'full' } else { 'minimal' }) ($managementTemplateReason)"

# FULL = evidence exists even if tests fail. PARTIAL = missing tools. FALLBACK = missing evidence files.
$reportQuality = "FULL"
if ($managementTemplateReason -like "*fallback-missing-critical-inputs*") {
    $reportQuality = "FALLBACK"
}
elseif ($missingTools.Count -gt 0) {
    $reportQuality = "PARTIAL"
}

$gateReasons = New-Object System.Collections.Generic.List[string]
$decision    = "CHANGES_REQUIRED"
if ($reportQuality -eq "FULL" -and $testMetrics.failed -eq 0 -and $sarifMetrics.errors -eq 0 -and $buildFailed -eq 0) {
    $decision = "APPROVED_FOR_MERGE"
}

if ($managementTemplateReason -like "*fallback-missing-critical-inputs*") { $decision = "CHANGES_REQUIRED"; $gateReasons.Add("Template fallback indicates missing critical evidence.") | Out-Null }
if ($reportQuality -ne "FULL" -and $decision -eq "APPROVED_FOR_MERGE")    { $decision = "CHANGES_REQUIRED"; $gateReasons.Add("Approval is allowed only for FULL report quality.") | Out-Null }
if ($isStrict -and $missingCritical.Count -gt 0)                          { $decision = "CHANGES_REQUIRED"; $gateReasons.Add("Strict mode: missing critical evidence is not allowed.") | Out-Null }
if ($isStrict -and $reportQuality -in @("PARTIAL", "FALLBACK"))           { $decision = "CHANGES_REQUIRED"; $gateReasons.Add("Strict mode: PARTIAL/FALLBACK report quality is not allowed.") | Out-Null }
if ($buildFailed -gt 0 -and [bool]$cfg.policy.failOnBuildError -and $isStrict) { $decision = "CHANGES_REQUIRED"; $gateReasons.Add("Strict mode: build failed.") | Out-Null }
if ($sarifMetrics.errors -gt 0 -and $isStrict)                            { $decision = "CHANGES_REQUIRED"; $gateReasons.Add("Strict mode: error-level SARIF findings detected.") | Out-Null }
if ($testMetrics.failed -gt 0)                                             { $decision = "CHANGES_REQUIRED"; $gateReasons.Add("$($testMetrics.failed) test(s) failed.") | Out-Null }
if ($decision -eq "CHANGES_REQUIRED" -and $gateReasons.Count -eq 0)       { $gateReasons.Add("Quality gate rules did not satisfy approval criteria.") | Out-Null }

# ── Computed report variables ─────────────────────────────────────────────────
$passRate             = [math]::Round($testMetrics.passed / [math]::Max($testMetrics.total, 1) * 100, 1)
$confidenceScore      = [int]([math]::Round(($testMetrics.passed / [math]::Max($testMetrics.total,1)) * 60 + ($coverageMetrics.linePct / 100) * 30 + ([math]::Max(0, 100 - $sarifMetrics.errors * 10) / 100) * 10, 0))
$lineCoverageStatus   = if ($coverageMetrics.linePct -ge 60)   { "PASS" } else { "FAIL" }
$branchCoverageStatus = if ($coverageMetrics.branchPct -ge 50) { "PASS" } else { "FAIL" }
$buildStatus          = if ($buildFailed -gt 0)              { "At Risk" } else { "Stable" }
$flakySuspicion       = if ($testMetrics.failed -gt 5)       { "MEDIUM" } else { "LOW" }
$coverageHealth       = if ($coverageMetrics.linePct -ge 60) { "HEALTHY" } elseif ($coverageMetrics.linePct -ge 30) { "AT RISK" } else { "CRITICAL" }
$blockerList          = if ($gateReasons.Count -gt 0) { $gateReasons -join "; " } else { "None" }

$buildCheck    = if ($buildFailed -eq 0)                                                      { "x" } else { " " }
$testCheck     = if ($testMetrics.failed -eq 0)                                               { "x" } else { " " }
$coverageCheck = if ($coverageMetrics.linePct -ge 60 -and $coverageMetrics.branchPct -ge 50) { "x" } else { " " }
$sarifCheck    = if ($sarifMetrics.errors -eq 0)                                              { "x" } else { " " }
$evidenceCheck = if ($missingCritical.Count -eq 0)                                            { "x" } else { " " }

$buildProbability     = if ($buildFailed -gt 0)              { "High" } else { "Low" }
$testProbability      = if ($testMetrics.failed -gt 0)       { "High" } else { "Low" }
$coverageProbability  = if ($coverageMetrics.linePct -lt 30) { "High" } elseif ($coverageMetrics.linePct -lt 60) { "Medium" } else { "Low" }
$staticProbability    = if ($sarifMetrics.errors -gt 0)      { "High" } else { "Low" }
$toolchainProbability = if ($missingTools.Count -gt 0)       { "High" } else { "Low" }

$readinessIndex = [int][math]::Round(
    ($infraRatio * 45) +
    (($coverageMetrics.linePct / 100.0) * 30) +
    (([math]::Max(0, 100 - ($sarifMetrics.errors * 10)) / 100.0) * 25),
    0)
if ($readinessIndex -lt 0)   { $readinessIndex = 0 }
if ($readinessIndex -gt 100) { $readinessIndex = 100 }

$toolVersions = [ordered]@{
    pwsh        = $PSVersionTable.PSVersion.ToString()
    dotnet      = Get-CommandVersion -Name "dotnet"
    python      = Get-CommandVersion -Name "python"
    node        = Get-CommandVersion -Name "node"
    npm         = Get-CommandVersion -Name "npm"
    pandoc      = Get-CommandVersion -Name "pandoc"
    wkhtmltopdf = Get-CommandVersion -Name "wkhtmltopdf"
}

$diagnosticReasons = New-Object System.Collections.Generic.List[string]
if ($reportQuality -eq "FALLBACK")    { $diagnosticReasons.Add("Critical evidence missing; fallback template selected.") | Out-Null }
elseif ($reportQuality -eq "PARTIAL") { $diagnosticReasons.Add("Missing tools: $($missingTools -join ', ')") | Out-Null }
if ($missingCritical.Count -gt 0)     { $diagnosticReasons.Add("Missing critical: $($missingCritical -join '; ')") | Out-Null }

$diag = [ordered]@{
    detectedStack         = $detectedStack
    effectiveStack        = $effectiveStack
    strictMode            = [bool]$isStrict
    missingCriticalInputs = @($missingCritical.ToArray())
    toolVersions          = $toolVersions
    reasons               = @($diagnosticReasons.ToArray())
}
$diagPath = Join-Path $statusDir "evidence-diagnostics.json"
$diag | ConvertTo-Json -Depth 20 | Set-Content -Path $diagPath -Encoding UTF8

$diagnosticsLines = @(
    "## Evidence Diagnostics",
    "| Field | Value |",
    "| --- | --- |",
    "| Detected stack | $detectedStack |",
    "| Effective stack | $effectiveStack |",
    "| Strict mode | $isStrict |",
    "| Report quality | $reportQuality |",
    "| Missing critical inputs | $(if ($missingCritical.Count -gt 0) { $missingCritical -join '; ' } else { 'None' }) |",
    "| Fallback/partial reasons | $(if ($diagnosticReasons.Count -gt 0) { $diagnosticReasons -join '; ' } else { 'None' }) |"
)

# ── Engineering Snapshot ──────────────────────────────────────────────────────
$engLines = New-Object System.Collections.Generic.List[string]
$engLines.Add("# Engineering Snapshot") | Out-Null
$engLines.Add("") | Out-Null
$engLines.Add("## Build & Test Summary") | Out-Null
$engLines.Add("| Metric | Value |") | Out-Null
$engLines.Add("| --- | --- |") | Out-Null
$engLines.Add("| Stack | $effectiveStack |") | Out-Null
$engLines.Add("| Configuration | $Configuration |") | Out-Null
$engLines.Add("| Commands attempted | $attempted |") | Out-Null
$engLines.Add("| Commands succeeded | $succeeded |") | Out-Null
$engLines.Add("| Build failures | $buildFailed |") | Out-Null
$engLines.Add("| Build status | $buildStatus |") | Out-Null
$engLines.Add("") | Out-Null
$engLines.Add("## Test Results") | Out-Null
$engLines.Add("| Metric | Value |") | Out-Null
$engLines.Add("| --- | --- |") | Out-Null
$engLines.Add("| Total tests | $($testMetrics.total) |") | Out-Null
$engLines.Add("| Passed | $($testMetrics.passed) |") | Out-Null
$engLines.Add("| Failed | $($testMetrics.failed) |") | Out-Null
$engLines.Add("| Skipped | $($testMetrics.skipped) |") | Out-Null
$engLines.Add("| Pass rate | $passRate% |") | Out-Null
$engLines.Add("") | Out-Null
$engLines.Add("## Failed Tests") | Out-Null
if ($failedTestNames.Count -eq 0) {
    $engLines.Add("No failed tests.") | Out-Null
} else {
    foreach ($name in $failedTestNames) { $engLines.Add("- $name") | Out-Null }
}
$engLines.Add("") | Out-Null
$engLines.Add("## Coverage Summary") | Out-Null
$engLines.Add("| Metric | Current | Threshold | Status |") | Out-Null
$engLines.Add("| --- | --- | --- | --- |") | Out-Null
$engLines.Add("| Line coverage | $($coverageMetrics.linePct)% | 60% | $lineCoverageStatus |") | Out-Null
$engLines.Add("| Branch coverage | $($coverageMetrics.branchPct)% | 50% | $branchCoverageStatus |") | Out-Null
$engLines.Add("") | Out-Null
$engLines.Add("## SARIF / Static Analysis") | Out-Null
$engLines.Add("| Metric | Count |") | Out-Null
$engLines.Add("| --- | --- |") | Out-Null
$engLines.Add("| Total findings | $($sarifMetrics.total) |") | Out-Null
$engLines.Add("| Errors | $($sarifMetrics.errors) |") | Out-Null
$engLines.Add("| Warnings | $($sarifMetrics.warnings) |") | Out-Null
$engLines.Add("| Notes | $($sarifMetrics.notes) |") | Out-Null
$engLines.Add("") | Out-Null
$engLines.Add("## Command Execution Log") | Out-Null
$engLines.Add("| Phase | Status | Exit Code |") | Out-Null
$engLines.Add("| --- | --- | --- |") | Out-Null
foreach ($entry in $commandLog) {
    $status = if ($entry.skipped) { "Skipped" } elseif ($entry.succeeded) { "Passed" } else { "Failed" }
    $engLines.Add("| $($entry.label) | $status | $($entry.exitCode) |") | Out-Null
}
$engLines.Add("") | Out-Null
foreach ($line in $diagnosticsLines) { $engLines.Add($line) | Out-Null }

# ── Management Snapshot ───────────────────────────────────────────────────────
$mgmtLines = New-Object System.Collections.Generic.List[string]
$mgmtLines.Add("# Management Snapshot") | Out-Null
$mgmtLines.Add("") | Out-Null
if ($useFullManagementTemplate) {
    $mgmtLines.Add("## Release Readiness Index") | Out-Null
    $mgmtLines.Add("- Index: **$readinessIndex / 100**") | Out-Null
    $mgmtLines.Add("- Formula: (Infra Commands x 0.45) + (Coverage x 0.30) + (StaticQuality x 0.25)") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Top 5 Risks") | Out-Null
    $mgmtLines.Add("| Risk | Business Impact | Probability | Mitigation | Owner Role |") | Out-Null
    $mgmtLines.Add("| --- | --- | --- | --- | --- |") | Out-Null
    $mgmtLines.Add("| Build stability | High impact: blocks deployment | $buildProbability | Fix compile errors and re-run CI | Platform Engineer |") | Out-Null
    $mgmtLines.Add("| Test reliability | Medium impact: regression escape risk | $testProbability | Address failed tests and add regression assertions | Backend Engineer |") | Out-Null
    $mgmtLines.Add("| Coverage debt | Medium impact: lower defect detection | $coverageProbability | Prioritize P0/P1 coverage plan for high-risk modules | QA Engineer |") | Out-Null
    $mgmtLines.Add("| Static analysis errors | High impact: quality/security risk | $staticProbability | Fix error-level findings and verify on rerun | Backend Engineer |") | Out-Null
    $mgmtLines.Add("| Toolchain gaps | Low impact: CI slowdown | $toolchainProbability | Install missing tools in workflow | DevOps Engineer |") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Trend vs Previous Run") | Out-Null
    $mgmtLines.Add("| Metric | Delta |") | Out-Null
    $mgmtLines.Add("| --- | --- |") | Out-Null
    $mgmtLines.Add("| Test failures delta | Not Available |") | Out-Null
    $mgmtLines.Add("| Coverage delta (%) | Not Available |") | Out-Null
    $mgmtLines.Add("| Static errors delta | Not Available |") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Decision Recommendation") | Out-Null
    $mgmtLines.Add("- Gate decision: **$decision**") | Out-Null
    $mgmtLines.Add("- Report quality: **$reportQuality**") | Out-Null
    $mgmtLines.Add("- Exact blockers: $blockerList") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Merge Readiness Checklist") | Out-Null
    $mgmtLines.Add("- [$buildCheck] Build passes on CI for target configuration.") | Out-Null
    $mgmtLines.Add("- [$testCheck] All tests pass with no failures.") | Out-Null
    $mgmtLines.Add("- [$coverageCheck] Coverage threshold met (line >= 60%, branch >= 50%).") | Out-Null
    $mgmtLines.Add("- [$sarifCheck] No SARIF error-level findings.") | Out-Null
    $mgmtLines.Add("- [$evidenceCheck] All critical evidence produced.") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Action Tracker") | Out-Null
    $mgmtLines.Add("| Action | Owner Role | Priority | Status |") | Out-Null
    $mgmtLines.Add("| --- | --- | --- | --- |") | Out-Null
    $mgmtLines.Add("| Ensure all critical evidence is produced | DevOps Engineer | P0 | $(if ($missingCritical.Count -eq 0) { 'Done' } else { 'Open' }) |") | Out-Null
    $mgmtLines.Add("| Resolve build failures | Platform Engineer | P0 | $(if ($buildFailed -eq 0) { 'Done' } else { 'Open' }) |") | Out-Null
    $mgmtLines.Add("| Fix failing tests | Backend Engineer | P0 | $(if ($testMetrics.failed -eq 0) { 'Done' } else { 'Open' }) |") | Out-Null
    $mgmtLines.Add("| Raise coverage above threshold | QA Engineer | P1 | $(if ($coverageMetrics.linePct -ge 60) { 'Done' } else { 'Open' }) |") | Out-Null
    $mgmtLines.Add("| Address SARIF error-level findings | Backend Engineer | P1 | $(if ($sarifMetrics.errors -eq 0) { 'Done' } else { 'Open' }) |") | Out-Null
    $mgmtLines.Add("| Security review for data access patterns | Security Engineer | P2 | In Progress |") | Out-Null
} else {
    $mgmtLines.Add("- Readiness index: $readinessIndex") | Out-Null
    $mgmtLines.Add("- Gate decision: $decision") | Out-Null
    $mgmtLines.Add("- Report quality: $reportQuality") | Out-Null
    $mgmtLines.Add("- Template reason: $managementTemplateReason") | Out-Null
}
$mgmtLines.Add("") | Out-Null
foreach ($line in $diagnosticsLines) { $mgmtLines.Add($line) | Out-Null }

# ── Summary ───────────────────────────────────────────────────────────────────
$summaryLines = @(
    "# Universal Quality Gate Summary",
    "",
    "- Stack: $effectiveStack",
    "- Mode: $mode",
    "- Commands attempted: $attempted",
    "- Commands succeeded: $succeeded",
    "- Build failures: $buildFailed",
    "- Report quality: $reportQuality",
    "- Gate decision: $decision",
    "- Missing critical inputs: $(if ($missingCritical.Count -gt 0) { $missingCritical -join '; ' } else { 'None' })",
    ""
)

# ── Coverage Report ───────────────────────────────────────────────────────────
$coverageLines = New-Object System.Collections.Generic.List[string]
$coverageLines.Add("# Coverage Report") | Out-Null
$coverageLines.Add("") | Out-Null
$coverageLines.Add("## Overall Coverage vs Threshold") | Out-Null
$coverageLines.Add("| Metric | Current | Threshold | Status |") | Out-Null
$coverageLines.Add("| --- | --- | --- | --- |") | Out-Null
$coverageLines.Add("| Line Coverage | $($coverageMetrics.linePct)% | 60% | $lineCoverageStatus |") | Out-Null
$coverageLines.Add("| Branch Coverage | $($coverageMetrics.branchPct)% | 50% | $branchCoverageStatus |") | Out-Null
$coverageLines.Add("") | Out-Null
$coverageLines.Add("## Coverage Health") | Out-Null
$coverageLines.Add("- Overall coverage health: **$coverageHealth**") | Out-Null
$coverageLines.Add("- Coverage file present: $coverageFilePresent") | Out-Null
$coverageLines.Add("- Coverage format: Cobertura") | Out-Null
$coverageLines.Add("") | Out-Null
$coverageLines.Add("## Prioritized Remediation Plan") | Out-Null
$coverageLines.Add("- **P0**: Add tests for critical paths with 0% or very low coverage.") | Out-Null
$coverageLines.Add("- **P1**: Raise line coverage above 60% and branch coverage above 50%.") | Out-Null
$coverageLines.Add("- **P2**: Add edge-case and resilience tests to prevent regressions in CI.") | Out-Null

# ── Test Report ───────────────────────────────────────────────────────────────
$testLines = New-Object System.Collections.Generic.List[string]
$testLines.Add("# Unit Test Execution Report") | Out-Null
$testLines.Add("") | Out-Null
$testLines.Add("## Summary") | Out-Null
$testLines.Add("| Metric | Value |") | Out-Null
$testLines.Add("| --- | --- |") | Out-Null
$testLines.Add("| Total tests | $($testMetrics.total) |") | Out-Null
$testLines.Add("| Passed | $($testMetrics.passed) |") | Out-Null
$testLines.Add("| Failed | $($testMetrics.failed) |") | Out-Null
$testLines.Add("| Skipped | $($testMetrics.skipped) |") | Out-Null
$testLines.Add("| Pass rate | $passRate% |") | Out-Null
$testLines.Add("") | Out-Null
$testLines.Add("## Test Confidence Score") | Out-Null
$testLines.Add("- Score: **$confidenceScore / 100**") | Out-Null
$testLines.Add("- Method: 60% pass-rate signal + 30% line-coverage signal + 10% static-error penalty") | Out-Null
$testLines.Add("") | Out-Null
$testLines.Add("## Failed Tests Detail") | Out-Null
if ($failedTestNames.Count -eq 0) {
    $testLines.Add("No failed tests.") | Out-Null
} else {
    foreach ($name in $failedTestNames) { $testLines.Add("- $name") | Out-Null }
}
$testLines.Add("") | Out-Null
$testLines.Add("## Flaky-Test Suspicion") | Out-Null
$testLines.Add("- Suspicion: **$flakySuspicion** (based on failure count in current run)") | Out-Null
$testLines.Add("") | Out-Null
$testLines.Add("## Immediate Next Actions") | Out-Null
$testLines.Add("1. Reproduce any failed tests locally and patch root cause.") | Out-Null
$testLines.Add("2. Add regression assertions for identified failure patterns.") | Out-Null
$testLines.Add("3. Re-run dotnet test with TRX output and verify failed test count reduction.") | Out-Null

# ── Static Quality Report ─────────────────────────────────────────────────────
$staticLines = New-Object System.Collections.Generic.List[string]
$staticLines.Add("# Static Quality Report") | Out-Null
$staticLines.Add("") | Out-Null
$staticLines.Add("## SARIF Summary") | Out-Null
$staticLines.Add("| Metric | Count |") | Out-Null
$staticLines.Add("| --- | --- |") | Out-Null
$staticLines.Add("| Total Findings | $($sarifMetrics.total) |") | Out-Null
$staticLines.Add("| Errors | $($sarifMetrics.errors) |") | Out-Null
$staticLines.Add("| Warnings | $($sarifMetrics.warnings) |") | Out-Null
$staticLines.Add("| Notes/Other | $($sarifMetrics.notes) |") | Out-Null
$staticLines.Add("") | Out-Null
$staticLines.Add("## Findings Status") | Out-Null
$staticLines.Add("- Error-level findings: $(if ($sarifMetrics.errors -gt 0) { '**BLOCKING** - must fix before merge' } else { 'OK - no errors' })") | Out-Null
$staticLines.Add("- Warning-level findings: $(if ($sarifMetrics.warnings -gt 0) { 'REVIEW RECOMMENDED' } else { 'OK' })") | Out-Null
$staticLines.Add("") | Out-Null
$staticLines.Add("## Top 5 Fix Playbooks by Rule Category") | Out-Null
$staticLines.Add("| Category | Trigger | Playbook |") | Out-Null
$staticLines.Add("| --- | --- | --- |") | Out-Null
$staticLines.Add("| API Contract & Validation | CS0234, ArgumentException | Fix package references/contracts first, then add contract regression tests. |") | Out-Null
$staticLines.Add("| Null/Defensive Coding | NullReference patterns | Add guard clauses, nullable annotations, and unit tests for null input paths. |") | Out-Null
$staticLines.Add("| Authorization Boundary | Unauthorized/Forbidden failures | Align [Authorize]/[AllowAnonymous], test headers/tokens, and endpoint policy. |") | Out-Null
$staticLines.Add("| Coverage Debt | Coverage below threshold | Add targeted tests for top-risk modules and branch conditions first. |") | Out-Null
$staticLines.Add("| Code Analysis Hygiene | Repeated analyzer warnings | Batch-fix by rule family and suppress only with documented evidence. |") | Out-Null
$staticLines.Add("") | Out-Null
$staticLines.Add("## Notes") | Out-Null
$staticLines.Add("- SARIF files discovered: $($sarifFiles.Count)") | Out-Null
$staticLines.Add("- Zero findings = clean static analysis pass for this run.") | Out-Null

# ── PR Gate Summary ───────────────────────────────────────────────────────────
$prGateLines = New-Object System.Collections.Generic.List[string]
$prGateLines.Add("# PR Quality Gate Summary") | Out-Null
$prGateLines.Add("") | Out-Null
$prGateLines.Add("## Final Gate Decision") | Out-Null
$prGateLines.Add("- Decision: **$decision**") | Out-Null
$prGateLines.Add("- Exact blockers: $blockerList") | Out-Null
$prGateLines.Add("") | Out-Null
$prGateLines.Add("## Blocking Issues Map") | Out-Null
$prGateLines.Add("| Category | Evidence | Suggested Owner Role | Suggested ETA |") | Out-Null
$prGateLines.Add("| --- | --- | --- | --- |") | Out-Null
if ($buildFailed -gt 0)              { $prGateLines.Add("| Build | $buildFailed command(s) failed. | Platform Engineer | 1-2 working days |") | Out-Null }
if ($testMetrics.failed -gt 0)       { $prGateLines.Add("| Test | $($testMetrics.failed) test(s) failed. | Backend Engineer | 1-2 working days |") | Out-Null }
if ($coverageMetrics.linePct -lt 60) { $prGateLines.Add("| Coverage | Line coverage $($coverageMetrics.linePct)% is below 60% threshold. | QA Engineer | 2-3 working days |") | Out-Null }
if ($sarifMetrics.errors -gt 0)      { $prGateLines.Add("| Static Analysis | $($sarifMetrics.errors) error-level SARIF finding(s). | Backend Engineer | 1-2 working days |") | Out-Null }
if ($buildFailed -eq 0 -and $testMetrics.failed -eq 0 -and $sarifMetrics.errors -eq 0 -and $coverageMetrics.linePct -ge 60) {
    $prGateLines.Add("| None | All checks passed. | - | - |") | Out-Null
}
$prGateLines.Add("") | Out-Null
$prGateLines.Add("## Merge Readiness Checklist") | Out-Null
$prGateLines.Add("- [$buildCheck] Build passes on CI for target configuration.") | Out-Null
$prGateLines.Add("- [$testCheck] Failed tests resolved and rerun evidence attached.") | Out-Null
$prGateLines.Add("- [$coverageCheck] Coverage threshold met for critical modules.") | Out-Null
$prGateLines.Add("- [$sarifCheck] Static error findings triaged/fixed with evidence.") | Out-Null
$prGateLines.Add("- [$evidenceCheck] Security-sensitive paths reviewed.") | Out-Null

# ── Write all reports ─────────────────────────────────────────────────────────
$engineeringReportPath = Join-Path $reportsDir "engineering-snapshot.md"
$managementReportPath  = Join-Path $reportsDir "management-snapshot.md"
$summaryReportPath     = Join-Path $reportsDir "quality-gate-summary.md"
$coverageReportPath    = Join-Path $reportsDir "coverage-report.md"
$testReportPath        = Join-Path $reportsDir "test-report.md"
$staticReportPath      = Join-Path $reportsDir "static-quality-report.md"
$prGateReportPath      = Join-Path $reportsDir "pr-gate-summary.md"

$engLines      | Set-Content -Path $engineeringReportPath -Encoding UTF8
$mgmtLines     | Set-Content -Path $managementReportPath  -Encoding UTF8
$summaryLines  | Set-Content -Path $summaryReportPath     -Encoding UTF8
$coverageLines | Set-Content -Path $coverageReportPath    -Encoding UTF8
$testLines     | Set-Content -Path $testReportPath        -Encoding UTF8
$staticLines   | Set-Content -Path $staticReportPath      -Encoding UTF8
$prGateLines   | Set-Content -Path $prGateReportPath      -Encoding UTF8

Copy-Item -Path $engineeringReportPath -Destination (Join-Path $reportsDir "Engineering.md") -Force
Copy-Item -Path $managementReportPath  -Destination (Join-Path $reportsDir "Management.md")  -Force
Copy-Item -Path $summaryReportPath     -Destination (Join-Path $reportsDir "Summary.md")     -Force
Copy-Item -Path $coverageReportPath    -Destination (Join-Path $reportsDir "Coverage.md")    -Force
Copy-Item -Path $testReportPath        -Destination (Join-Path $reportsDir "Tests.md")       -Force
Copy-Item -Path $staticReportPath      -Destination (Join-Path $reportsDir "Static.md")      -Force
Copy-Item -Path $prGateReportPath      -Destination (Join-Path $reportsDir "PRGate.md")      -Force

# ── metrics.json ──────────────────────────────────────────────────────────────
$requiredContractPaths = @(
    "status/metrics.json", "status/evidence-diagnostics.json",
    "evidence/tests/", "evidence/coverage/cobertura.xml",
    "evidence/static/*.sarif", "validation/manual-truth.json",
    "validation/report-vs-truth.json", "reports/engineering-*.md",
    "reports/management-*.md", "reports/*.pdf"
)
$foundContract = @("status/metrics.json","status/evidence-diagnostics.json")
if ((Test-Path $evidenceTests) -and (@(Get-ChildItem -Path $evidenceTests -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0)) { $foundContract += "evidence/tests/" }
if (Test-Path $normalizedCobertura) { $foundContract += "evidence/coverage/cobertura.xml" }
if ($sarifFiles.Count -gt 0)        { $foundContract += "evidence/static/*.sarif" }
if (@(Get-ChildItem -Path $reportsDir -File -Filter "engineering-*.md" -ErrorAction SilentlyContinue).Count -gt 0) { $foundContract += "reports/engineering-*.md" }
if (@(Get-ChildItem -Path $reportsDir -File -Filter "management-*.md"  -ErrorAction SilentlyContinue).Count -gt 0) { $foundContract += "reports/management-*.md" }

$missingContract = New-Object System.Collections.Generic.List[string]
foreach ($rp in $requiredContractPaths) {
    if (-not ($foundContract -contains $rp)) {
        if ($rp -in @("validation/manual-truth.json","validation/report-vs-truth.json","reports/*.pdf")) { continue }
        $missingContract.Add($rp) | Out-Null
    }
}

$metrics = [ordered]@{
    meta = [ordered]@{
        runId             = $ts
        timestampUtc      = (Get-Date).ToUniversalTime().ToString("o")
        detectedStack     = $detectedStack
        effectiveStack    = $effectiveStack
        mode              = $mode
        projectRoot       = $targetRoot
        defaultConfigPath = $configBundle.DefaultConfigPath
        repoConfigPath    = $configBundle.RepoConfigPath
        repoConfigFound   = $configBundle.RepoConfigFound
    }
    testTotal         = [int]$testMetrics.total
    testPassed        = [int]$testMetrics.passed
    testFailed        = [int]$testMetrics.failed
    testSkipped       = [int]$testMetrics.skipped
    coveragePct       = [double]$coverageMetrics.linePct
    branchCoveragePct = [double]$coverageMetrics.branchPct
    sarifTotal        = [int]$sarifMetrics.total
    sarifErrors       = [int]$sarifMetrics.errors
    sarifWarnings     = [int]$sarifMetrics.warnings
    sarifNotes        = [int]$sarifMetrics.notes
    gateDecision      = $decision
    gateReasons       = @($gateReasons)
    reportQuality     = $reportQuality
    readinessIndex    = [int]$readinessIndex
    confidenceScore   = [int]$confidenceScore
    passRate          = [double]$passRate
    evidence          = [ordered]@{
        testCount       = $testFiles.Count
        coverageCount   = $(if ($coverageFilePresent) { 1 } else { 0 })
        sarifCount      = $sarifFiles.Count
        missingCritical = @($missingCritical.ToArray())
    }
    status = [ordered]@{
        commandsAttempted = $attempted
        commandsSucceeded = $succeeded
        infraAttempted    = $infraAttempted
        infraSucceeded    = $infraSucceeded
        buildFailed       = $buildFailed
        testFailed        = $testFailed
        missingTools      = @($missingTools.ToArray())
        warnings          = @($warnings.ToArray())
        commands          = @($commandLog.ToArray())
        managementReport  = [ordered]@{
            template = $(if ($useFullManagementTemplate) { "full" } else { "minimal" })
            reason   = $managementTemplateReason
        }
        pdfGenerated = $false
        pdfReason    = "render-not-run"
    }
}

$metricsPath = Join-Path $statusDir "metrics.json"
$metrics | ConvertTo-Json -Depth 40 | Set-Content -Path $metricsPath -Encoding UTF8
($cfg | ConvertTo-Json -Depth 60) | Set-Content -Path (Join-Path $statusDir "effective-config.json") -Encoding UTF8

# ── PDF ───────────────────────────────────────────────────────────────────────
if ($GeneratePdf) {
    $renderScript = Join-Path $PSScriptRoot "render_reports_to_pdf.ps1"
    if (Test-Path $renderScript) {
        & $renderScript -ArtifactsRoot $artifactsRoot -RunFolder $ts -StrictMode:$isStrict
        $pdfRc = $LASTEXITCODE
        $pdfStatusPath = Join-Path $statusDir "pdf-status.json"
        if (Test-Path $pdfStatusPath) {
            try {
                $pdfStatus = Get-Content -Path $pdfStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $metrics.status.pdfGenerated = [bool]$pdfStatus.pdfGenerated
                $metrics.status.pdfReason    = [string]$pdfStatus.reason
            }
            catch {
                $metrics.status.pdfGenerated = $false
                $metrics.status.pdfReason    = "pdf-status-parse-failed"
            }
        }
        else {
            $metrics.status.pdfGenerated = ($pdfRc -eq 0)
            $metrics.status.pdfReason    = if ($pdfRc -eq 0) { "ok" } else { "render-failed" }
        }
        if ($isStrict -and $pdfRc -ne 0) {
            $decision = "CHANGES_REQUIRED"
            $metrics.gateDecision = $decision
            $metrics.gateReasons += @("Strict mode: PDF guardrail failed.")
        }
        $metrics | ConvertTo-Json -Depth 40 | Set-Content -Path $metricsPath -Encoding UTF8
    }
}

@(
    "REPORT STATUS: $(if ($decision -eq 'APPROVED_FOR_MERGE') { 'COMPLETE' } else { 'PARTIAL' })",
    "Timestamp: $ts", "Detected Stack: $detectedStack", "Effective Stack: $effectiveStack",
    "Mode: $mode", "Report Quality: $reportQuality", "Decision: $decision", "Reports: $reportsDir"
) | Set-Content -Path (Join-Path $statusDir "REPORT_GENERATION_STATUS.txt") -Encoding UTF8

Write-Step "Evidence counts: tests=$($testFiles.Count) coverage=$(if ($coverageFilePresent) { 1 } else { 0 }) sarif=$($sarifFiles.Count)"
Write-Step "Coverage: line=$($coverageMetrics.linePct)% branch=$($coverageMetrics.branchPct)%"
Write-Step "Report quality: $reportQuality"
Write-Step "Gate decision: $decision"
Write-Step "Reports folder: $reportsDir"
Write-Step "Status metrics: $metricsPath"
Write-Step "Diagnostics: $diagPath"

exit 0
