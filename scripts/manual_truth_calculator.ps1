param(
    [Parameter(Mandatory = $true)]
    [string]$RunFolderPath,
    [string]$ConfigPath = "quality-gate.config.json",
    [string]$DefaultConfigPath = "config/quality-gate.default.json",
    [string]$SchemaPath = "config/quality-gate.schema.json",
    [string]$LegacyValidationConfig = "config/report-validation.json",
    [string]$LegacyScoringConfig = "config/report-scoring.json"
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "quality_gate_config.ps1")

function Write-Step {
    param([string]$Message)
    Write-Host "[manual-truth] $Message"
}

function Get-RunRoot {
    param([string]$InputPath)

    if ([System.IO.Path]::IsPathRooted($InputPath)) {
        return [System.IO.Path]::GetFullPath($InputPath)
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $InputPath))
}

function Parse-Trx {
    param([string]$Path)

    [xml]$x = Get-Content -Path $Path -Raw -Encoding UTF8
    $c = $x.TestRun.ResultSummary.Counters
    if ($null -eq $c) {
        throw "TRX counters not found: $Path"
    }

    return [pscustomobject]@{
        total = [int]$c.total
        passed = [int]$c.passed
        failed = [int]$c.failed
        skipped = [int]$c.notExecuted
    }
}

function Parse-JUnitXml {
    param([string]$Path)

    [xml]$x = Get-Content -Path $Path -Raw -Encoding UTF8
    $rootName = [string]$x.DocumentElement.Name

    $tests = 0
    $failures = 0
    $errors = 0
    $skipped = 0

    if ($rootName -eq "testsuites") {
        foreach ($suite in @($x.testsuites.testsuite)) {
            $tests += [int]($suite.tests | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
            $failures += [int]($suite.failures | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
            $errors += [int]($suite.errors | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
            $skipped += [int]($suite.skipped | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
        }
    }
    elseif ($rootName -eq "testsuite") {
        $suite = $x.testsuite
        $tests = [int]($suite.tests | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
        $failures = [int]($suite.failures | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
        $errors = [int]($suite.errors | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
        $skipped = [int]($suite.skipped | ForEach-Object { if ($_ -ne $null) { $_ } else { 0 } })
    }
    else {
        throw "Unsupported JUnit XML root '$rootName' in $Path"
    }

    $failed = $failures + $errors
    $passed = [Math]::Max(0, ($tests - $failed - $skipped))

    return [pscustomobject]@{
        total = [int]$tests
        passed = [int]$passed
        failed = [int]$failed
        skipped = [int]$skipped
    }
}

function Parse-Cobertura {
    param([string]$Path)

    [xml]$x = Get-Content -Path $Path -Raw -Encoding UTF8
    $lineRate = [double]$x.coverage.'line-rate'
    $branchRate = [double]$x.coverage.'branch-rate'

    return [pscustomobject]@{
        format = "cobertura"
        linePct = [Math]::Round($lineRate * 100, 2)
        branchPct = [Math]::Round($branchRate * 100, 2)
        denominator = 1
    }
}

function Parse-Jacoco {
    param([string]$Path)

    [xml]$x = Get-Content -Path $Path -Raw -Encoding UTF8
    $lineCounter = @($x.report.counter | Where-Object { $_.type -eq "LINE" } | Select-Object -First 1)
    $branchCounter = @($x.report.counter | Where-Object { $_.type -eq "BRANCH" } | Select-Object -First 1)

    $lineMissed = if ($lineCounter) { [double]$lineCounter[0].missed } else { 0 }
    $lineCovered = if ($lineCounter) { [double]$lineCounter[0].covered } else { 0 }
    $lineTotal = $lineMissed + $lineCovered

    $branchMissed = if ($branchCounter) { [double]$branchCounter[0].missed } else { 0 }
    $branchCovered = if ($branchCounter) { [double]$branchCounter[0].covered } else { 0 }
    $branchTotal = $branchMissed + $branchCovered

    $linePct = if ($lineTotal -gt 0) { [Math]::Round(($lineCovered / $lineTotal) * 100, 2) } else { 0 }
    $branchPct = if ($branchTotal -gt 0) { [Math]::Round(($branchCovered / $branchTotal) * 100, 2) } else { 0 }

    return [pscustomobject]@{
        format = "jacoco"
        linePct = [double]$linePct
        branchPct = [double]$branchPct
        denominator = [int]$lineTotal
    }
}

function Parse-OpenCover {
    param([string]$Path)

    [xml]$x = Get-Content -Path $Path -Raw -Encoding UTF8
    $s = $x.CoverageSession.Summary

    $lineTotal = [double]$s.numSequencePoints
    $lineCovered = [double]$s.visitedSequencePoints
    $branchTotal = [double]$s.numBranchPoints
    $branchCovered = [double]$s.visitedBranchPoints

    $linePct = if ($lineTotal -gt 0) { [Math]::Round(($lineCovered / $lineTotal) * 100, 2) } else { 0 }
    $branchPct = if ($branchTotal -gt 0) { [Math]::Round(($branchCovered / $branchTotal) * 100, 2) } else { 0 }

    return [pscustomobject]@{
        format = "opencover"
        linePct = [double]$linePct
        branchPct = [double]$branchPct
        denominator = [int]$lineTotal
    }
}

function Parse-Lcov {
    param([string]$Path)

    $lf = 0
    $lh = 0
    $brf = 0
    $brh = 0

    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        if ($line -match '^LF:(\d+)$') { $lf += [int]$matches[1]; continue }
        if ($line -match '^LH:(\d+)$') { $lh += [int]$matches[1]; continue }
        if ($line -match '^BRF:(\d+)$') { $brf += [int]$matches[1]; continue }
        if ($line -match '^BRH:(\d+)$') { $brh += [int]$matches[1]; continue }
    }

    $linePct = if ($lf -gt 0) { [Math]::Round(($lh / [double]$lf) * 100, 2) } else { 0 }
    $branchPct = if ($brf -gt 0) { [Math]::Round(($brh / [double]$brf) * 100, 2) } else { 0 }

    return [pscustomobject]@{
        format = "lcov"
        linePct = [double]$linePct
        branchPct = [double]$branchPct
        denominator = [int]$lf
    }
}

function Parse-GoCoverage {
    param([string]$Path)

    $totalStatements = 0
    $coveredStatements = 0

    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        if ($line -match '^mode:\s*') { continue }
        if ($line -match '^[^:]+:\d+\.\d+,\d+\.\d+\s+(\d+)\s+(\d+)$') {
            $numStmt = [int]$matches[1]
            $count = [int]$matches[2]
            $totalStatements += $numStmt
            if ($count -gt 0) {
                $coveredStatements += $numStmt
            }
        }
    }

    $linePct = if ($totalStatements -gt 0) { [Math]::Round(($coveredStatements / [double]$totalStatements) * 100, 2) } else { 0 }

    return [pscustomobject]@{
        format = "go-coverage"
        linePct = [double]$linePct
        branchPct = 0
        denominator = [int]$totalStatements
    }
}

function Parse-Sarif {
    param([string]$Path)

    $obj = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $results = @($obj.runs[0].results)

    $errors = 0
    $warnings = 0
    $notes = 0
    foreach ($r in $results) {
        $level = ([string]$r.level).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($level)) { $level = "warning" }
        switch ($level) {
            "error" { $errors++ }
            "warning" { $warnings++ }
            default { $notes++ }
        }
    }

    return [pscustomobject]@{
        total = [int]$results.Count
        errors = [int]$errors
        warnings = [int]$warnings
        notes = [int]$notes
    }
}

$runRoot = Get-RunRoot -InputPath $RunFolderPath
if (-not (Test-Path $runRoot)) {
    throw "Run folder not found: $runRoot"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$configBundle = Get-EffectiveQualityGateConfig -RepoRoot $repoRoot -DefaultConfigPath $DefaultConfigPath -RepoConfigPath $ConfigPath -SchemaPath $SchemaPath -LegacyValidationPath $LegacyValidationConfig -LegacyScoringPath $LegacyScoringConfig
$cfg = $configBundle.EffectiveConfig

$evidenceRoot = Join-Path $runRoot "evidence"
$testRoot = Join-Path $evidenceRoot "tests"
$coverageRoot = Join-Path $evidenceRoot "coverage"
$sarifRoot = Join-Path $evidenceRoot "static"
$legacyRawRoot = Join-Path $runRoot "raw"
$legacyTestRoot = Join-Path $legacyRawRoot "test-results"
$legacyCoverageRoot = Join-Path $legacyRawRoot "coverage"
$legacySarifRoot = Join-Path $legacyRawRoot "sarif"
$validationRoot = Join-Path $runRoot "validation"

New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null

$testFiles = @()
if (Test-Path $testRoot) {
    $testFiles = @(Get-ChildItem -Path $testRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -eq ".trx" -or $_.Name -match "(?i)junit|TEST-.*\.xml"
    })
}
if ($testFiles.Count -eq 0 -and (Test-Path $legacyTestRoot)) {
    $testFiles = @(Get-ChildItem -Path $legacyTestRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -eq ".trx" -or $_.Name -match "(?i)junit|TEST-.*\.xml"
    })
}

$coverageFiles = @()
if (Test-Path $coverageRoot) {
    $coverageFiles = @(Get-ChildItem -Path $coverageRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "(?i)cobertura|jacoco|lcov\.info|opencover|coverage\.xml|coverage\.out"
    })
}
if ($coverageFiles.Count -eq 0 -and (Test-Path $legacyCoverageRoot)) {
    $coverageFiles = @(Get-ChildItem -Path $legacyCoverageRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "(?i)cobertura|jacoco|lcov\.info|opencover|coverage\.xml|coverage\.out"
    })
}

$sarifFiles = @()
if (Test-Path $sarifRoot) {
    $sarifFiles = @(Get-ChildItem -Path $sarifRoot -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
}
if ($sarifFiles.Count -eq 0 -and (Test-Path $legacySarifRoot)) {
    $sarifFiles = @(Get-ChildItem -Path $legacySarifRoot -Recurse -File -Filter "*.sarif" -ErrorAction SilentlyContinue)
}

$testTotal = 0
$testPassed = 0
$testFailed = 0
$testSkipped = 0
$testParserUsed = "none"
$testEvidencePath = ""

$trx = @($testFiles | Where-Object { $_.Extension -eq ".trx" } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
if ($trx.Count -gt 0) {
    $parsed = Parse-Trx -Path $trx[0].FullName
    $testTotal = $parsed.total
    $testPassed = $parsed.passed
    $testFailed = $parsed.failed
    $testSkipped = $parsed.skipped
    $testParserUsed = "trx-v1"
    $testEvidencePath = $trx[0].FullName
}
else {
    $junit = @($testFiles | Where-Object { $_.Extension -eq ".xml" } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($junit.Count -gt 0) {
        $parsed = Parse-JUnitXml -Path $junit[0].FullName
        $testTotal = $parsed.total
        $testPassed = $parsed.passed
        $testFailed = $parsed.failed
        $testSkipped = $parsed.skipped
        $testParserUsed = "junit-v1"
        $testEvidencePath = $junit[0].FullName
    }
}

$coveragePct = 0.0
$branchCoveragePct = 0.0
$coverageFormat = "none"
$coverageEvidencePath = ""

$coverageCandidates = New-Object System.Collections.Generic.List[object]
foreach ($f in $coverageFiles) {
    try {
        $parsed = $null
        if ($f.Name -match "(?i)lcov\.info$") {
            $parsed = Parse-Lcov -Path $f.FullName
        }
        elseif ($f.Name -match "(?i)coverage\.out$") {
            $parsed = Parse-GoCoverage -Path $f.FullName
        }
        else {
            [xml]$probe = Get-Content -Path $f.FullName -Raw -Encoding UTF8
            $rootName = [string]$probe.DocumentElement.Name
            if ($rootName -eq "coverage") {
                if ($f.Name -match "(?i)opencover") {
                    $parsed = Parse-OpenCover -Path $f.FullName
                }
                else {
                    $parsed = Parse-Cobertura -Path $f.FullName
                }
            }
            elseif ($rootName -eq "CoverageSession") {
                $parsed = Parse-OpenCover -Path $f.FullName
            }
            elseif ($rootName -eq "report") {
                $parsed = Parse-Jacoco -Path $f.FullName
            }
        }

        if ($parsed) {
            $coverageCandidates.Add([pscustomobject]@{
                file = $f.FullName
                parsed = $parsed
            }) | Out-Null
        }
    }
    catch {
        Write-Step "Coverage parse skipped for $($f.FullName): $($_.Exception.Message)"
    }
}

if ($coverageCandidates.Count -gt 0) {
    $best = $coverageCandidates | Sort-Object { [int]$_.parsed.denominator } -Descending | Select-Object -First 1
    $coveragePct = [double]$best.parsed.linePct
    $branchCoveragePct = [double]$best.parsed.branchPct
    $coverageFormat = [string]$best.parsed.format
    $coverageEvidencePath = [string]$best.file
}

$sarifTotal = 0
$sarifErrors = 0
$sarifWarnings = 0
$sarifNotes = 0
$sarifParserUsed = "none"
$sarifEvidencePath = ""

if ($sarifFiles.Count -gt 0) {
    foreach ($sf in @($sarifFiles | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $parsedSarif = Parse-Sarif -Path $sf.FullName
            $sarifTotal += $parsedSarif.total
            $sarifErrors += $parsedSarif.errors
            $sarifWarnings += $parsedSarif.warnings
            $sarifNotes += $parsedSarif.notes
            if ([string]::IsNullOrWhiteSpace($sarifEvidencePath)) {
                $sarifEvidencePath = $sf.FullName
            }
            $sarifParserUsed = "sarif-v1"
        }
        catch {
            Write-Step "SARIF parse skipped for $($sf.FullName): $($_.Exception.Message)"
        }
    }
}

$weights = $cfg.scoring.weights
if ($null -eq $weights) {
    $weights = @{
        staticQualityWeight = 0.35
        testWeight = 0.30
        coverageWeight = 0.25
        securityWeight = 0.10
        staticErrorPenaltyPerItem = 8
    }
}

$thresholds = $cfg.scoring.thresholds
if ($null -eq $thresholds) {
    $thresholds = @{
        goMin = 85
        conditionalGoMin = 70
    }
}

$testScore = if ($testTotal -gt 0) { [Math]::Round(($testPassed / [double]$testTotal) * 100, 2) } else { 0 }
$staticPenalty = if ($weights.staticErrorPenaltyPerItem) { [double]$weights.staticErrorPenaltyPerItem } else { 8 }
$staticQualityScore = [Math]::Max(0, [Math]::Round(100 - ($sarifErrors * $staticPenalty), 2))
$securityScore = [Math]::Max(0, [Math]::Round(100 - ($sarifErrors * 10), 2))

$totalWeight = [double]$weights.staticQualityWeight + [double]$weights.testWeight + [double]$weights.coverageWeight + [double]$weights.securityWeight
if ($totalWeight -le 0) { $totalWeight = 1 }

$readinessRaw = (
    ($staticQualityScore * [double]$weights.staticQualityWeight) +
    ($testScore * [double]$weights.testWeight) +
    ($coveragePct * [double]$weights.coverageWeight) +
    ($securityScore * [double]$weights.securityWeight)
) / $totalWeight

$readinessIndex = [int][Math]::Round($readinessRaw, 0)
if ($readinessIndex -lt 0) { $readinessIndex = 0 }
if ($readinessIndex -gt 100) { $readinessIndex = 100 }

$truthVerdict = "CHANGES_REQUIRED"
if ($readinessIndex -ge [int]$thresholds.goMin -and $testFailed -eq 0 -and $sarifErrors -eq 0) {
    $truthVerdict = "APPROVED_FOR_MERGE"
}

$missingEvidence = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($testEvidencePath)) { $missingEvidence.Add("tests") | Out-Null }
if ([string]::IsNullOrWhiteSpace($coverageEvidencePath)) { $missingEvidence.Add("coverage") | Out-Null }
if ([string]::IsNullOrWhiteSpace($sarifEvidencePath)) { $missingEvidence.Add("sarif") | Out-Null }

$result = [ordered]@{
    meta = [ordered]@{
        runFolder = $runRoot
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        parserVersions = [ordered]@{
            tests = $testParserUsed
            coverage = if ($coverageFormat -ne "none") { "$coverageFormat-v1" } else { "none" }
            sarif = $sarifParserUsed
        }
    }
    evidence = [ordered]@{
        testsFile = $testEvidencePath
        coverageFile = $coverageEvidencePath
        sarifFile = $sarifEvidencePath
        missing = @($missingEvidence.ToArray())
    }
    truth = [ordered]@{
        testTotal = [int]$testTotal
        testPassed = [int]$testPassed
        testFailed = [int]$testFailed
        testSkipped = [int]$testSkipped
        coveragePct = [double]$coveragePct
        branchCoveragePct = [double]$branchCoveragePct
        sarifTotal = [int]$sarifTotal
        sarifErrors = [int]$sarifErrors
        sarifWarnings = [int]$sarifWarnings
        sarifNotes = [int]$sarifNotes
        readinessIndex = [int]$readinessIndex
        verdict = $truthVerdict
        scoring = [ordered]@{
            testScore = [double]$testScore
            staticQualityScore = [double]$staticQualityScore
            securityScore = [double]$securityScore
            weights = [ordered]@{
                staticQualityWeight = [double]$weights.staticQualityWeight
                testWeight = [double]$weights.testWeight
                coverageWeight = [double]$weights.coverageWeight
                securityWeight = [double]$weights.securityWeight
            }
        }
    }
}

$outPath = Join-Path $validationRoot "manual-truth.json"
$result | ConvertTo-Json -Depth 30 | Set-Content -Path $outPath -Encoding UTF8

Write-Step "Run folder: $runRoot"
Write-Step "Truth verdict: $truthVerdict"
Write-Step "Readiness index: $readinessIndex"
Write-Step "Output: $outPath"

exit 0
