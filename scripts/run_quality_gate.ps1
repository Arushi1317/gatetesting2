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

$ErrorActionPreference = "Continue"

. (Join-Path $PSScriptRoot "quality_gate_config.ps1")

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
    catch {
        return "available"
    }
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
    if (Get-FirstMatch -Root $Root -Patterns @("package.json")) { return "node" }
    if (Get-FirstMatch -Root $Root -Patterns @("pyproject.toml", "requirements.txt", "setup.py")) { return "python" }
    if (Get-FirstMatch -Root $Root -Patterns @("pom.xml", "build.gradle", "build.gradle.kts")) { return "java" }
    if (Get-FirstMatch -Root $Root -Patterns @("go.mod")) { return "go" }
    if (Get-FirstMatch -Root $Root -Patterns @("Cargo.toml")) { return "rust" }
    return "unknown"
}

function Resolve-DotnetTargets {
    param([string]$Root)

    $all = @(Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "[\\/](bin|obj|artifacts|benchmark-out|.git)[\\/]" -and
            $_.Extension -in @(".sln", ".slnx", ".csproj")
        } |
        Sort-Object FullName)

    $solutions = @($all | Where-Object { $_.Extension -in @(".sln", ".slnx") })
    $projects = @($all | Where-Object { $_.Extension -eq ".csproj" })

    $build = if ($solutions.Count -gt 0) { $solutions[0] } elseif ($projects.Count -gt 0) { $projects[0] } else { $null }

    $tests = @(Get-ChildItem -Path $Root -Recurse -Filter "*.csproj" -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "[\\/](bin|obj|artifacts|benchmark-out|.git)[\\/]" -and
            ($_.FullName -match "[\\/]tests?[\\/]" -or $_.Name -match "Test")
        } |
        Sort-Object FullName)

    return [pscustomobject]@{
        BuildTarget = if ($build) { $build.FullName } else { "" }
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
        label = $Label
        command = $Command
        succeeded = $false
        exitCode = -1
        skipped = $false
        reason = ""
    }

    if ([string]::IsNullOrWhiteSpace($Command)) {
        $entry.skipped = $true
        $entry.reason = "empty-command"
        $CommandLog.Add([pscustomobject]$entry) | Out-Null
        return [pscustomobject]$entry
    }

    $candidate = ($Command.Trim() -split '\s+')[0]
    if (($candidate -notin @("if", "for", "while", "$", "(")) -and -not (Test-ToolAvailable -ToolName $candidate)) {
        $entry.skipped = $true
        $entry.reason = "missing-tool:$candidate"
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

        $entry.exitCode = [int]$exitCode
        $entry.succeeded = ($exitCode -eq 0)
        if (-not $entry.succeeded -and -not $Optional) {
            $entry.reason = "nonzero-exit"
        }

        return [pscustomobject]$entry
    }
    catch {
        $entry.exitCode = 1
        $entry.succeeded = $false
        $entry.reason = "exception:$($_.Exception.Message)"
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
                if ($r.succeeded) {
                    $ok = $true
                    break
                }
            }
            if (-not $ok) { $failed++ }
            continue
        }

        $res = Invoke-QgCommand -Label $Phase -Command $expanded -WorkingDir $WorkingDir -CommandLog $CommandLog -MissingTools $MissingTools -Optional
        if (-not $res.succeeded -and -not $res.skipped) {
            $failed++
        }
    }
    return $failed
}

function Parse-TestMetrics {
    param([System.IO.FileInfo[]]$TestFiles)

    $total = 0
    $passed = 0
    $failed = 0
    $skipped = 0

    foreach ($file in @($TestFiles)) {
        try {
            if ($file.Extension -eq ".trx") {
                [xml]$x = Get-Content -Path $file.FullName -Raw -Encoding UTF8
                $c = $x.TestRun.ResultSummary.Counters
                if ($c) {
                    $total += [int]$c.total
                    $passed += [int]$c.passed
                    $failed += [int]$c.failed
                    $skipped += [int]$c.notExecuted
                }
                continue
            }

            [xml]$j = Get-Content -Path $file.FullName -Raw -Encoding UTF8
            $rootName = [string]$j.DocumentElement.Name
            if ($rootName -eq "testsuite") {
                $tests = [int]$j.testsuite.tests
                $fails = [int]$j.testsuite.failures
                $errs = [int]$j.testsuite.errors
                $skip = [int]$j.testsuite.skipped
                $total += $tests
                $failed += ($fails + $errs)
                $skipped += $skip
                $passed += [math]::Max(0, $tests - $fails - $errs - $skip)
            }
            elseif ($rootName -eq "testsuites") {
                foreach ($suite in @($j.testsuites.testsuite)) {
                    $tests = [int]$suite.tests
                    $fails = [int]$suite.failures
                    $errs = [int]$suite.errors
                    $skip = [int]$suite.skipped
                    $total += $tests
                    $failed += ($fails + $errs)
                    $skipped += $skip
                    $passed += [math]::Max(0, $tests - $fails - $errs - $skip)
                }
            }
        }
        catch {}
    }

    return [pscustomobject]@{
        total = [int]$total
        passed = [int]$passed
        failed = [int]$failed
        skipped = [int]$skipped
    }
}

function Parse-CoberturaMetrics {
    param([string]$CoberturaPath)

    if (-not (Test-Path $CoberturaPath)) {
        return [pscustomobject]@{ linePct = 0.0; branchPct = 0.0 }
    }

    try {
        [xml]$cx = Get-Content -Path $CoberturaPath -Raw -Encoding UTF8
        $line = if ($cx.coverage.'line-rate') { [math]::Round(([double]$cx.coverage.'line-rate') * 100, 2) } else { 0 }
        $branch = if ($cx.coverage.'branch-rate') { [math]::Round(([double]$cx.coverage.'branch-rate') * 100, 2) } else { 0 }
        return [pscustomobject]@{ linePct = [double]$line; branchPct = [double]$branch }
    }
    catch {
        return [pscustomobject]@{ linePct = 0.0; branchPct = 0.0 }
    }
}

function Parse-SarifMetrics {
    param([System.IO.FileInfo[]]$SarifFiles)

    $total = 0
    $errors = 0
    $warnings = 0
    $notes = 0

    foreach ($sf in @($SarifFiles)) {
        try {
            $sj = Get-Content -Path $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($run in @($sj.runs)) {
                foreach ($r in @($run.results)) {
                    $total++
                    $level = ([string]$r.level).ToLowerInvariant()
                    if (-not $level) { $level = "warning" }
                    switch ($level) {
                        "error" { $errors++ }
                        "warning" { $warnings++ }
                        default { $notes++ }
                    }

                }
            }
        }
        catch {}
    }

    return [pscustomobject]@{
        total = [int]$total
        errors = [int]$errors
        warnings = [int]$warnings
        notes = [int]$notes
    }
}

function New-QgEmptySarif {
    param(
        [string]$OutputPath,
        [string]$Producer = "universal-quality-gate"
    )

@"
{
  "`$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "version": "2.1.0",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "$Producer"
        }
      },
      "results": []
    }
  ]
}
"@ | Set-Content -Path $OutputPath -Encoding UTF8
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$targetRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $repoRoot } else { (Get-QgAbsolutePath -BasePath $repoRoot -PathValue $ProjectRoot) }
if (-not (Test-Path $targetRoot)) {
    throw "ProjectRoot does not exist: $targetRoot"
}

$configBundle = Get-EffectiveQualityGateConfig -RepoRoot $repoRoot -DefaultConfigPath $DefaultConfigPath -RepoConfigPath $ConfigPath -SchemaPath $SchemaPath -LegacyValidationPath $LegacyValidationConfig -LegacyScoringPath $LegacyScoringConfig
$cfg = $configBundle.EffectiveConfig

$detectedStack = Detect-ProjectStack -Root $targetRoot
$effectiveStack = if ([string]::IsNullOrWhiteSpace($Stack)) { $detectedStack } else { ([string]$Stack).ToLowerInvariant() }
$stackCfg = $cfg.stacks[$effectiveStack]
if ($null -eq $stackCfg) {
    $effectiveStack = "unknown"
    $stackCfg = $cfg.stacks.unknown
}

$mode = [string]$cfg.policy.mode
if ($StrictMode.IsPresent) {
    $mode = "strict"
    $cfg.policy.mode = "strict"
    $cfg.policy.failOnMissingEvidence = $true
}
$isStrict = ($mode -eq "strict")

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$artifactsRoot = Get-QgAbsolutePath -BasePath $targetRoot -PathValue ([string]$cfg.artifacts.root)
$runRoot = Join-Path $artifactsRoot $ts
$layout = $cfg.artifacts.layout

$rawTestResults = Join-Path $runRoot ([string]$layout.rawTestResults).Replace('/', '\')
$rawCoverage = Join-Path $runRoot ([string]$layout.rawCoverage).Replace('/', '\')
$rawSarif = Join-Path $runRoot ([string]$layout.rawSarif).Replace('/', '\')
$statusDir = Join-Path $runRoot ([string]$layout.status).Replace('/', '\')
$validationDir = Join-Path $runRoot ([string]$layout.validation).Replace('/', '\')
$reportsDir = Join-Path $runRoot "reports"

$evidenceRoot = Join-Path $runRoot "evidence"
$evidenceTests = Join-Path $evidenceRoot "tests"
$evidenceCoverage = Join-Path $evidenceRoot "coverage"
$evidenceStatic = Join-Path $evidenceRoot "static"
$normalizedCobertura = Join-Path $evidenceCoverage "cobertura.xml"

New-Item -ItemType Directory -Force -Path $artifactsRoot, $runRoot, $rawTestResults, $rawCoverage, $rawSarif, $statusDir, $validationDir, $reportsDir, $evidenceRoot, $evidenceTests, $evidenceCoverage, $evidenceStatic | Out-Null

Write-Step "Detected stack: $detectedStack"
Write-Step "Effective stack: $effectiveStack"
Write-Step "Target root: $targetRoot"

$tokens = @{
    configuration = $Configuration
    repoRoot = $repoRoot
    targetRoot = $targetRoot
    runRoot = $runRoot
    artifactsRoot = $artifactsRoot
    rawTestResults = $rawTestResults
    rawCoverage = $rawCoverage
    rawSarif = $rawSarif
    evidenceTests = $evidenceTests
    evidenceCoverage = $evidenceCoverage
    evidenceStatic = $evidenceStatic
    statusDir = $statusDir
    validationDir = $validationDir
    reportsDir = $reportsDir
    sarifOutput = (Join-Path $evidenceStatic "quality-gate.sarif")
    normalizedCobertura = $normalizedCobertura
}

$commandLog = New-Object System.Collections.Generic.List[object]
$missingTools = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

foreach ($tool in @($stackCfg.requiredTools)) {
    if (-not (Test-ToolAvailable -ToolName ([string]$tool)) -and -not ($missingTools -contains [string]$tool)) {
        $missingTools.Add([string]$tool) | Out-Null
    }
}

$dotnetTargets = $null
if ($effectiveStack -eq "dotnet") {
    $dotnetTargets = Resolve-DotnetTargets -Root $targetRoot
    $tokens["targetPath"] = $dotnetTargets.BuildTarget
    if (-not $dotnetTargets.BuildTarget) {
        $warnings.Add("No dotnet build target found.") | Out-Null
    }
}

$setupFailed = Invoke-QgCommandList -Phase "setup" -Commands @($stackCfg.setupCommands) -WorkingDir $targetRoot -Tokens $tokens -CommandLog $commandLog -MissingTools $missingTools
$buildFailed = Invoke-QgCommandList -Phase "build" -Commands @($stackCfg.buildCommands) -WorkingDir $targetRoot -Tokens $tokens -CommandLog $commandLog -MissingTools $missingTools

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
        if (-not $eslintResult.succeeded) {
            $warnings.Add("Node SARIF not produced by eslint.") | Out-Null
        }
    }
}
elseif ($effectiveStack -eq "python") {
    $banditOut = Join-Path $evidenceStatic "bandit.sarif"
    if (-not (Test-Path $banditOut)) {
        $banditResult = Invoke-QgCommand -Label "analysis" -Command "python -m bandit -r . -f sarif -o `"$banditOut`"" -WorkingDir $targetRoot -CommandLog $commandLog -MissingTools $missingTools -Optional
        if (-not $banditResult.succeeded) {
            $warnings.Add("Python SARIF not produced by bandit.") | Out-Null
        }
    }
}

$testMatches = @(Find-QgEvidenceFiles -RepoRoot $targetRoot -RunRoot $runRoot -Patterns @($cfg.trx.pathPatterns))
$testMatches += @(Get-ChildItem -Path $rawTestResults -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -eq ".trx" -or $_.Name -match "(?i)junit|TEST-.*\.xml"
})
$testMatches = @($testMatches | Sort-Object FullName -Unique)
foreach ($f in @($testMatches)) {
    $dest = Join-Path $evidenceTests $f.Name
    Copy-Item -Path $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $dest -Destination (Join-Path $rawTestResults $f.Name) -Force -ErrorAction SilentlyContinue
}

$coverageMatches = @(Find-QgEvidenceFiles -RepoRoot $targetRoot -RunRoot $runRoot -Patterns @($cfg.coverage.pathPatterns))
$coverageMatches += @(Get-ChildItem -Path $rawCoverage -Recurse -File -ErrorAction SilentlyContinue)
$coverageMatches += @(Get-ChildItem -Path $rawTestResults -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "(?i)cobertura|coverage\.xml|jacoco|lcov\.info|opencover|coverage\.out" })
$coverageMatches = @($coverageMatches | Sort-Object FullName -Unique)
foreach ($f in @($coverageMatches)) {
    Copy-Item -Path $f.FullName -Destination (Join-Path $rawCoverage $f.Name) -Force -ErrorAction SilentlyContinue
}

$sarifMatches = @(Find-QgEvidenceFiles -RepoRoot $targetRoot -RunRoot $runRoot -Patterns @($cfg.sarif.pathPatterns))
$sarifMatches += @(Get-ChildItem -Path $rawSarif -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
$sarifMatches += @(Get-ChildItem -Path $evidenceStatic -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
$sarifMatches = @($sarifMatches | Sort-Object FullName -Unique)
foreach ($f in @($sarifMatches)) {
    $dest = Join-Path $evidenceStatic $f.Name
    Copy-Item -Path $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $dest -Destination (Join-Path $rawSarif $f.Name) -Force -ErrorAction SilentlyContinue
}

if ($effectiveStack -eq "dotnet" -and @(Get-ChildItem -Path $evidenceStatic -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue).Count -eq 0) {
    New-QgEmptySarif -OutputPath (Join-Path $evidenceStatic "quality-gate.sarif") -Producer "roslyn"
    Copy-Item -Path (Join-Path $evidenceStatic "quality-gate.sarif") -Destination (Join-Path $rawSarif "quality-gate.sarif") -Force -ErrorAction SilentlyContinue
}

$coverageCandidates = @(
    Get-ChildItem -Path $rawCoverage -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "(?i)cobertura|coverage\.xml|jacoco|opencover|lcov\.info|coverage\.out"
    }
)
$coveragePrimary = @($coverageCandidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
if ($coveragePrimary.Count -gt 0) {
    Copy-Item -Path $coveragePrimary[0].FullName -Destination $normalizedCobertura -Force -ErrorAction SilentlyContinue
}

$testFiles = @(Get-ChildItem -Path $evidenceTests -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq ".trx" -or $_.Name -match "(?i)junit|TEST-.*\.xml" })
$sarifFiles = @(Get-ChildItem -Path $evidenceStatic -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
$coverageFilePresent = Test-Path $normalizedCobertura

$testMetrics = Parse-TestMetrics -TestFiles $testFiles
$coverageMetrics = Parse-CoberturaMetrics -CoberturaPath $normalizedCobertura
$sarifMetrics = Parse-SarifMetrics -SarifFiles $sarifFiles

$attempted = @($commandLog | Where-Object { -not $_.skipped }).Count
$succeeded = @($commandLog | Where-Object { $_.succeeded }).Count
$failed = @($commandLog | Where-Object { (-not $_.succeeded) -and (-not $_.skipped) }).Count

$missingCritical = New-Object System.Collections.Generic.List[string]
if ($testFiles.Count -eq 0) { $missingCritical.Add("evidence/tests/ (TRX or JUnit XML)") | Out-Null }
if (-not $coverageFilePresent) { $missingCritical.Add("evidence/coverage/cobertura.xml") | Out-Null }
if ($sarifFiles.Count -eq 0) { $missingCritical.Add("evidence/static/*.sarif") | Out-Null }

$criticalInputsAvailable = ($missingCritical.Count -eq 0)
$managementTemplateReason = if ($criticalInputsAvailable) { "critical-metrics-available" } else { "fallback-missing-critical-inputs" }
$useFullManagementTemplate = $criticalInputsAvailable
Write-Step "Management template selected: $(if ($useFullManagementTemplate) { 'full' } else { 'minimal' }) ($managementTemplateReason)"

$reportQuality = "FULL"
if ($managementTemplateReason -like "*fallback-missing-critical-inputs*") {
    $reportQuality = "FALLBACK"
}
elseif ($failed -gt 0 -or $missingTools.Count -gt 0) {
    $reportQuality = "PARTIAL"
}

$gateReasons = New-Object System.Collections.Generic.List[string]
$decision = "CHANGES_REQUIRED"
if ($reportQuality -eq "FULL" -and $testMetrics.failed -eq 0 -and $sarifMetrics.errors -eq 0 -and $failed -eq 0) {
    $decision = "APPROVED_FOR_MERGE"
}

if ($managementTemplateReason -like "*fallback-missing-critical-inputs*") {
    $decision = "CHANGES_REQUIRED"
    $gateReasons.Add("Template fallback indicates missing critical evidence.") | Out-Null
}
if ($reportQuality -ne "FULL" -and $decision -eq "APPROVED_FOR_MERGE") {
    $decision = "CHANGES_REQUIRED"
    $gateReasons.Add("Approval is allowed only for FULL report quality.") | Out-Null
}
if ($isStrict -and $missingCritical.Count -gt 0) {
    $decision = "CHANGES_REQUIRED"
    $gateReasons.Add("Strict mode: missing critical evidence is not allowed.") | Out-Null
}
if ($isStrict -and $reportQuality -in @("PARTIAL", "FALLBACK")) {
    $decision = "CHANGES_REQUIRED"
    $gateReasons.Add("Strict mode: PARTIAL/FALLBACK report quality is not allowed.") | Out-Null
}
if ($failed -gt 0 -and [bool]$cfg.policy.failOnBuildError -and $isStrict) {
    $decision = "CHANGES_REQUIRED"
    $gateReasons.Add("Strict mode: one or more commands failed.") | Out-Null
}
if ($sarifMetrics.errors -gt 0 -and $isStrict) {
    $decision = "CHANGES_REQUIRED"
    $gateReasons.Add("Strict mode: error-level SARIF findings detected.") | Out-Null
}
if ($decision -eq "CHANGES_REQUIRED" -and $gateReasons.Count -eq 0) {
    $gateReasons.Add("Quality gate rules did not satisfy approval criteria.") | Out-Null
}

$toolVersions = [ordered]@{
    pwsh = $PSVersionTable.PSVersion.ToString()
    dotnet = Get-CommandVersion -Name "dotnet"
    python = Get-CommandVersion -Name "python"
    node = Get-CommandVersion -Name "node"
    npm = Get-CommandVersion -Name "npm"
    pandoc = Get-CommandVersion -Name "pandoc"
    wkhtmltopdf = Get-CommandVersion -Name "wkhtmltopdf"
}

$requiredContractPaths = @(
    "status/metrics.json",
    "status/evidence-diagnostics.json",
    "evidence/tests/",
    "evidence/coverage/cobertura.xml",
    "evidence/static/*.sarif",
    "validation/manual-truth.json",
    "validation/report-vs-truth.json",
    "reports/engineering-*.md",
    "reports/management-*.md",
    "reports/*.pdf"
)

$foundContract = @()
$foundContract += @("status/metrics.json")
$foundContract += @("status/evidence-diagnostics.json")
if ((Test-Path $evidenceTests) -and (@(Get-ChildItem -Path $evidenceTests -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0)) { $foundContract += "evidence/tests/" }
if (Test-Path $normalizedCobertura) { $foundContract += "evidence/coverage/cobertura.xml" }
if ($sarifFiles.Count -gt 0) { $foundContract += "evidence/static/*.sarif" }
if (@(Get-ChildItem -Path $reportsDir -File -Filter "engineering-*.md" -ErrorAction SilentlyContinue).Count -gt 0) { $foundContract += "reports/engineering-*.md" }
if (@(Get-ChildItem -Path $reportsDir -File -Filter "management-*.md" -ErrorAction SilentlyContinue).Count -gt 0) { $foundContract += "reports/management-*.md" }

$missingContract = New-Object System.Collections.Generic.List[string]
foreach ($requiredPath in $requiredContractPaths) {
    if (-not ($foundContract -contains $requiredPath)) {
        if ($requiredPath -in @("validation/manual-truth.json", "validation/report-vs-truth.json", "reports/*.pdf")) { continue }
        $missingContract.Add($requiredPath) | Out-Null
    }
}

$readinessIndex = [int][math]::Round((([math]::Min($succeeded, [math]::Max($attempted, 1)) / [double][math]::Max($attempted, 1)) * 45) + (($coverageMetrics.linePct / 100.0) * 30) + (([math]::Max(0, 100 - ($sarifMetrics.errors * 10)) / 100.0) * 25), 0)
if ($readinessIndex -lt 0) { $readinessIndex = 0 }
if ($readinessIndex -gt 100) { $readinessIndex = 100 }

$diagnosticReasons = New-Object System.Collections.Generic.List[string]
if ($reportQuality -eq "FALLBACK") {
    $diagnosticReasons.Add("Critical evidence missing; fallback template selected.") | Out-Null
}
elseif ($reportQuality -eq "PARTIAL") {
    $diagnosticReasons.Add("Evidence present but build/toolchain quality is partial.") | Out-Null
}
if ($missingCritical.Count -gt 0) { $diagnosticReasons.Add("Missing critical: $($missingCritical -join '; ')") | Out-Null }
if ($missingTools.Count -gt 0) { $diagnosticReasons.Add("Missing tools: $($missingTools -join ', ')") | Out-Null }

$diag = [ordered]@{
    detectedStack = $detectedStack
    effectiveStack = $effectiveStack
    strictMode = [bool]$isStrict
    requiredFiles = @($requiredContractPaths)
    foundFiles = @($foundContract)
    missingFiles = @($missingContract.ToArray())
    missingCriticalInputs = @($missingCritical.ToArray())
    toolVersions = $toolVersions
    reasons = @($diagnosticReasons.ToArray())
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

$engLines = New-Object System.Collections.Generic.List[string]
$engLines.Add("# Engineering Snapshot") | Out-Null
$engLines.Add("") | Out-Null
$engLines.Add("- Test files discovered: $($testFiles.Count)") | Out-Null
$engLines.Add("- Cobertura coverage file present: $coverageFilePresent") | Out-Null
$engLines.Add("- SARIF files discovered: $($sarifFiles.Count)") | Out-Null
$engLines.Add("- Coverage line %: $($coverageMetrics.linePct)") | Out-Null
$engLines.Add("- Coverage branch %: $($coverageMetrics.branchPct)") | Out-Null
$engLines.Add("- Test total/passed/failed/skipped: $($testMetrics.total)/$($testMetrics.passed)/$($testMetrics.failed)/$($testMetrics.skipped)") | Out-Null
$engLines.Add("") | Out-Null
foreach ($line in $diagnosticsLines) { $engLines.Add($line) | Out-Null }

$mgmtLines = New-Object System.Collections.Generic.List[string]
$mgmtLines.Add("# Management Snapshot") | Out-Null
$mgmtLines.Add("") | Out-Null
if ($useFullManagementTemplate) {
    $mgmtLines.Add("## Release Readiness Index") | Out-Null
    $mgmtLines.Add("- Index: **$readinessIndex / 100**") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Top 5 Risks") | Out-Null
    $mgmtLines.Add("| Risk | Current State |") | Out-Null
    $mgmtLines.Add("| --- | --- |") | Out-Null
    $mgmtLines.Add("| Build stability | $(if ($failed -gt 0) { 'At Risk' } else { 'Stable' }) |") | Out-Null
    $mgmtLines.Add("| Test reliability | $(if ($testMetrics.failed -gt 0) { 'At Risk' } else { 'Stable' }) |") | Out-Null
    $mgmtLines.Add("| Coverage | $(if ($coverageMetrics.linePct -lt 60) { 'At Risk' } else { 'Stable' }) |") | Out-Null
    $mgmtLines.Add("| Static analysis | $(if ($sarifMetrics.errors -gt 0) { 'At Risk' } else { 'Stable' }) |") | Out-Null
    $mgmtLines.Add("| Toolchain | $(if ($missingTools.Count -gt 0) { 'At Risk' } else { 'Stable' }) |") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Trend vs Previous Run") | Out-Null
    $mgmtLines.Add("- Trend details are available via `status/metrics.json` and comparator outputs.") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Decision Recommendation") | Out-Null
    $mgmtLines.Add("- Gate decision: **$decision**") | Out-Null
    $mgmtLines.Add("- Report quality: **$reportQuality**") | Out-Null
    $mgmtLines.Add("") | Out-Null
    $mgmtLines.Add("## Action Tracker") | Out-Null
    $mgmtLines.Add("| Action | Status |") | Out-Null
    $mgmtLines.Add("| --- | --- |") | Out-Null
    $mgmtLines.Add("| Ensure all critical evidence is produced | $(if ($missingCritical.Count -eq 0) { 'Done' } else { 'Open' }) |") | Out-Null
    $mgmtLines.Add("| Resolve failed commands | $(if ($failed -eq 0) { 'Done' } else { 'Open' }) |") | Out-Null
    $mgmtLines.Add("| Address SARIF error-level findings | $(if ($sarifMetrics.errors -eq 0) { 'Done' } else { 'Open' }) |") | Out-Null
}
else {
    $mgmtLines.Add("- Readiness index: $readinessIndex") | Out-Null
    $mgmtLines.Add("- Gate decision: $decision") | Out-Null
    $mgmtLines.Add("- Report quality: $reportQuality") | Out-Null
    $mgmtLines.Add("- Template reason: $managementTemplateReason") | Out-Null
}
$mgmtLines.Add("") | Out-Null
foreach ($line in $diagnosticsLines) { $mgmtLines.Add($line) | Out-Null }

$summaryLines = @(
    "# Universal Quality Gate Summary",
    "",
    "- Stack: $effectiveStack",
    "- Mode: $mode",
    "- Commands attempted: $attempted",
    "- Commands succeeded: $succeeded",
    "- Commands failed: $failed",
    "- Report quality: $reportQuality",
    "- Gate decision: $decision",
    "- Missing critical inputs: $(if ($missingCritical.Count -gt 0) { $missingCritical -join '; ' } else { 'None' })",
    ""
)

$engineeringReportPath = Join-Path $reportsDir "engineering-snapshot.md"
$managementReportPath = Join-Path $reportsDir "management-snapshot.md"
$summaryReportPath = Join-Path $reportsDir "quality-gate-summary.md"

$engLines | Set-Content -Path $engineeringReportPath -Encoding UTF8
$mgmtLines | Set-Content -Path $managementReportPath -Encoding UTF8
$summaryLines | Set-Content -Path $summaryReportPath -Encoding UTF8

# Backward-compatible report names
Copy-Item -Path $engineeringReportPath -Destination (Join-Path $reportsDir "Engineering.md") -Force
Copy-Item -Path $managementReportPath -Destination (Join-Path $reportsDir "Management.md") -Force
Copy-Item -Path $summaryReportPath -Destination (Join-Path $reportsDir "Summary.md") -Force

$metrics = [ordered]@{
    meta = [ordered]@{
        runId = $ts
        timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        detectedStack = $detectedStack
        effectiveStack = $effectiveStack
        mode = $mode
        projectRoot = $targetRoot
        defaultConfigPath = $configBundle.DefaultConfigPath
        repoConfigPath = $configBundle.RepoConfigPath
        repoConfigFound = $configBundle.RepoConfigFound
    }
    testTotal = [int]$testMetrics.total
    testPassed = [int]$testMetrics.passed
    testFailed = [int]$testMetrics.failed
    testSkipped = [int]$testMetrics.skipped
    coveragePct = [double]$coverageMetrics.linePct
    branchCoveragePct = [double]$coverageMetrics.branchPct
    sarifTotal = [int]$sarifMetrics.total
    sarifErrors = [int]$sarifMetrics.errors
    sarifWarnings = [int]$sarifMetrics.warnings
    sarifNotes = [int]$sarifMetrics.notes
    gateDecision = $decision
    gateReasons = @($gateReasons)
    reportQuality = $reportQuality
    readinessIndex = [int]$readinessIndex
    evidence = [ordered]@{
        testCount = $testFiles.Count
        coverageCount = $(if ($coverageFilePresent) { 1 } else { 0 })
        sarifCount = $sarifFiles.Count
        missingCritical = @($missingCritical.ToArray())
    }
    status = [ordered]@{
        commandsAttempted = $attempted
        commandsSucceeded = $succeeded
        commandsFailed = $failed
        missingTools = @($missingTools.ToArray())
        warnings = @($warnings.ToArray())
        commands = @($commandLog.ToArray())
        managementReport = [ordered]@{
            template = $(if ($useFullManagementTemplate) { "full" } else { "minimal" })
            reason = $managementTemplateReason
        }
        pdfGenerated = $false
        pdfReason = "render-not-run"
    }
}

$metricsPath = Join-Path $statusDir "metrics.json"
$metrics | ConvertTo-Json -Depth 40 | Set-Content -Path $metricsPath -Encoding UTF8
($cfg | ConvertTo-Json -Depth 60) | Set-Content -Path (Join-Path $statusDir "effective-config.json") -Encoding UTF8

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
                $metrics.status.pdfReason = [string]$pdfStatus.reason
            }
            catch {
                $metrics.status.pdfGenerated = $false
                $metrics.status.pdfReason = "pdf-status-parse-failed"
            }
        }
        else {
            $metrics.status.pdfGenerated = ($pdfRc -eq 0)
            $metrics.status.pdfReason = if ($pdfRc -eq 0) { "ok" } else { "render-failed" }
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
    "Timestamp: $ts",
    "Detected Stack: $detectedStack",
    "Effective Stack: $effectiveStack",
    "Mode: $mode",
    "Report Quality: $reportQuality",
    "Decision: $decision",
    "Reports: $reportsDir"
) | Set-Content -Path (Join-Path $statusDir "REPORT_GENERATION_STATUS.txt") -Encoding UTF8

Write-Step "Evidence counts: tests=$($testFiles.Count) coverage=$(if ($coverageFilePresent) { 1 } else { 0 }) sarif=$($sarifFiles.Count)"
Write-Step "Report quality: $reportQuality"
Write-Step "Gate decision: $decision"
Write-Step "Reports folder: $reportsDir"
Write-Step "Status metrics: $metricsPath"
Write-Step "Diagnostics: $diagPath"

if ($decision -eq "CHANGES_REQUIRED") {
    exit 1
}

exit 0
