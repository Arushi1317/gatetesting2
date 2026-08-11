param(
    [string]$GeneratedMetricsPath = "",
    [string]$ManualTruthPath = "",
    [string]$RunFolderPath = "",
    [double]$AccuracyThreshold = 98,
    [switch]$FailOnVerdictMismatch,
    [switch]$FailOnHardMismatch,
    [string]$ConfigPath = "quality-gate.config.json",
    [string]$DefaultConfigPath = "config/quality-gate.default.json",
    [string]$SchemaPath = "config/quality-gate.schema.json",
    [string]$LegacyValidationConfig = "config/report-validation.json",
    [string]$LegacyScoringConfig = "config/report-scoring.json"
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "quality_gate_config.ps1")

if (-not $PSBoundParameters.ContainsKey("FailOnVerdictMismatch")) { $FailOnVerdictMismatch = $true }
if (-not $PSBoundParameters.ContainsKey("FailOnHardMismatch")) { $FailOnHardMismatch = $true }

function Write-Step {
    param([string]$Message)
    Write-Host "[compare] $Message"
}

function Get-RunRootFromMetrics {
    param([string]$MetricsPath)
    $statusDir = Split-Path -Parent $MetricsPath
    return (Split-Path -Parent $statusDir)
}

function Compare-Number {
    param(
        [string]$Name,
        [double]$Generated,
        [double]$Truth,
        [double]$Tolerance
    )

    $delta = [Math]::Abs($Generated - $Truth)
    return [pscustomobject]@{
        name = $Name
        generated = [Math]::Round($Generated, 4)
        truth = [Math]::Round($Truth, 4)
        delta = [Math]::Round($delta, 4)
        tolerance = [Math]::Round($Tolerance, 4)
        pass = ($delta -le $Tolerance)
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$configBundle = Get-EffectiveQualityGateConfig -RepoRoot $repoRoot -DefaultConfigPath $DefaultConfigPath -RepoConfigPath $ConfigPath -SchemaPath $SchemaPath -LegacyValidationPath $LegacyValidationConfig -LegacyScoringPath $LegacyScoringConfig
$cfg = $configBundle.EffectiveConfig

if ([string]::IsNullOrWhiteSpace($RunFolderPath)) {
    if ([string]::IsNullOrWhiteSpace($GeneratedMetricsPath) -or [string]::IsNullOrWhiteSpace($ManualTruthPath)) {
        throw "Provide either -RunFolderPath or both -GeneratedMetricsPath and -ManualTruthPath."
    }
}

if (-not [string]::IsNullOrWhiteSpace($RunFolderPath)) {
    $runRoot = if ([System.IO.Path]::IsPathRooted($RunFolderPath)) { $RunFolderPath } else { Join-Path $repoRoot $RunFolderPath }
    $GeneratedMetricsPath = Join-Path $runRoot "status/metrics.json"
    $ManualTruthPath = Join-Path $runRoot "validation/manual-truth.json"
}

if (-not (Test-Path $GeneratedMetricsPath)) { throw "Generated metrics not found: $GeneratedMetricsPath" }
if (-not (Test-Path $ManualTruthPath)) { throw "Manual truth not found: $ManualTruthPath" }

$generated = Get-Content -Path $GeneratedMetricsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$truthDoc = Get-Content -Path $ManualTruthPath -Raw -Encoding UTF8 | ConvertFrom-Json
$truth = $truthDoc.truth

$runRootResolved = Get-RunRootFromMetrics -MetricsPath $GeneratedMetricsPath
$validationRoot = Join-Path $runRootResolved "validation"
$reportsRoot = Join-Path $runRootResolved "reports"
New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null

$tolTest = [double]$cfg.tolerances.testCounts
$tolCoverage = [double]$cfg.tolerances.coveragePct
$tolBranch = [double]$cfg.tolerances.branchCoveragePct
$tolSarif = [double]$cfg.tolerances.sarifCounts

$comparisons = @(
    (Compare-Number -Name "testTotal" -Generated ([double]$generated.testTotal) -Truth ([double]$truth.testTotal) -Tolerance $tolTest),
    (Compare-Number -Name "testPassed" -Generated ([double]$generated.testPassed) -Truth ([double]$truth.testPassed) -Tolerance $tolTest),
    (Compare-Number -Name "testFailed" -Generated ([double]$generated.testFailed) -Truth ([double]$truth.testFailed) -Tolerance $tolTest),
    (Compare-Number -Name "testSkipped" -Generated ([double]$generated.testSkipped) -Truth ([double]$truth.testSkipped) -Tolerance $tolTest),
    (Compare-Number -Name "coveragePct" -Generated ([double]$generated.coveragePct) -Truth ([double]$truth.coveragePct) -Tolerance $tolCoverage),
    (Compare-Number -Name "branchCoveragePct" -Generated ([double]$generated.branchCoveragePct) -Truth ([double]$truth.branchCoveragePct) -Tolerance $tolBranch),
    (Compare-Number -Name "sarifTotal" -Generated ([double]$generated.sarifTotal) -Truth ([double]$truth.sarifTotal) -Tolerance $tolSarif),
    (Compare-Number -Name "sarifErrors" -Generated ([double]$generated.sarifErrors) -Truth ([double]$truth.sarifErrors) -Tolerance $tolSarif),
    (Compare-Number -Name "sarifWarnings" -Generated ([double]$generated.sarifWarnings) -Truth ([double]$truth.sarifWarnings) -Tolerance $tolSarif),
    (Compare-Number -Name "sarifNotes" -Generated ([double]$generated.sarifNotes) -Truth ([double]$truth.sarifNotes) -Tolerance $tolSarif)
)

$hardFailures = @($comparisons | Where-Object { -not $_.pass })
$verdictMatch = ([string]$generated.gateDecision -eq [string]$truth.verdict)

$requiredManagementHeaders = @(
    "## Release Readiness Index",
    "## Top 5 Risks",
    "## Trend vs Previous Run",
    "## Decision Recommendation",
    "## Action Tracker"
)

$managementCandidate = @(Get-ChildItem -Path $reportsRoot -File -Filter "management-*.md" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1)
$managementPath = if ($managementCandidate) { $managementCandidate[0].FullName } else { Join-Path $reportsRoot "Management.md" }
$managementFound = 0
if (Test-Path $managementPath) {
    $mgmt = Get-Content -Path $managementPath -Raw -Encoding UTF8
    foreach ($header in $requiredManagementHeaders) {
        if ($mgmt.Contains($header)) { $managementFound++ }
    }
}
$managementComplete = ($managementFound -eq $requiredManagementHeaders.Count)

$testFields = @($comparisons | Where-Object { $_.name -in @("testTotal", "testPassed", "testFailed", "testSkipped") })
$coverageFields = @($comparisons | Where-Object { $_.name -in @("coveragePct", "branchCoveragePct") })
$staticFields = @($comparisons | Where-Object { $_.name -in @("sarifTotal", "sarifErrors", "sarifWarnings", "sarifNotes") })

$testPassRatio = if ($testFields.Count -gt 0) { (@($testFields | Where-Object { $_.pass }).Count / [double]$testFields.Count) } else { 1.0 }
$coveragePassRatio = if ($coverageFields.Count -gt 0) { (@($coverageFields | Where-Object { $_.pass }).Count / [double]$coverageFields.Count) } else { 1.0 }
$staticPassRatio = if ($staticFields.Count -gt 0) { (@($staticFields | Where-Object { $_.pass }).Count / [double]$staticFields.Count) } else { 1.0 }

$scoreVerdict = if ($verdictMatch) { 40.0 } else { 0.0 }
$scoreTests = [Math]::Round(20.0 * $testPassRatio, 2)
$scoreCoverage = [Math]::Round(20.0 * $coveragePassRatio, 2)
$scoreStatic = [Math]::Round(10.0 * $staticPassRatio, 2)
$scoreManagement = if ($managementComplete) { 10.0 } else { 0.0 }

$accuracyScore = [Math]::Round(($scoreVerdict + $scoreTests + $scoreCoverage + $scoreStatic + $scoreManagement), 2)

$guardrailWarnings = New-Object System.Collections.Generic.List[string]

$artifactsRoot = Split-Path -Parent $runRootResolved
$currentRunId = Split-Path -Leaf $runRootResolved
$previousRun = Get-ChildItem -Path $artifactsRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{8}_\d{6}$' -and $_.Name -lt $currentRunId } |
    Sort-Object Name | Select-Object -Last 1

if ($previousRun) {
    $prevTruthPath = Join-Path $previousRun.FullName "validation/manual-truth.json"
    if (Test-Path $prevTruthPath) {
        try {
            $prevTruth = (Get-Content -Path $prevTruthPath -Raw -Encoding UTF8 | ConvertFrom-Json).truth
            $failIncrease = ([int]$truth.testFailed - [int]$prevTruth.testFailed)
            $readinessIncrease = ([int]$truth.readinessIndex - [int]$prevTruth.readinessIndex)
            if ($failIncrease -ge 2 -and $readinessIncrease -gt 0) {
                $guardrailWarnings.Add("Metamorphic warning: readiness increased despite significant test failure increase.") | Out-Null
            }

            $coverageJump = [Math]::Abs(([double]$truth.coveragePct - [double]$prevTruth.coveragePct))
            if ($coverageJump -ge 20) {
                $guardrailWarnings.Add("Differential warning: suspicious coverage jump of $coverageJump points vs previous run.") | Out-Null
            }

            $readinessJump = [Math]::Abs(([double]$truth.readinessIndex - [double]$prevTruth.readinessIndex))
            if ($readinessJump -ge 20) {
                $guardrailWarnings.Add("Differential warning: suspicious readiness jump of $readinessJump points vs previous run.") | Out-Null
            }
        }
        catch {
            $guardrailWarnings.Add("Could not parse previous manual truth for differential checks.") | Out-Null
        }
    }
}

$missingEvidenceCount = @($truthDoc.evidence.missing).Count
$warningCount = @($generated.status.warnings).Count
if ($missingEvidenceCount -gt 0 -and $warningCount -eq 0) {
    $guardrailWarnings.Add("Metamorphic warning: missing evidence detected but generated warnings are empty.") | Out-Null
}
if ($missingEvidenceCount -eq 0 -and $warningCount -gt 0) {
    $guardrailWarnings.Add("Metamorphic warning: warnings present with no missing evidence; inspect warning quality.") | Out-Null
}

$failureReasons = New-Object System.Collections.Generic.List[string]
if ($FailOnVerdictMismatch -and -not $verdictMatch) {
    $failureReasons.Add("Verdict mismatch") | Out-Null
}
if ($FailOnHardMismatch -and $hardFailures.Count -gt 0) {
    $failureReasons.Add("Hard metric mismatch beyond tolerance") | Out-Null
}
$generatedReportQuality = if ($generated.PSObject.Properties.Name -contains "reportQuality") { [string]$generated.reportQuality } else { "" }
if ([string]$generated.gateDecision -eq "APPROVED_FOR_MERGE" -and $generatedReportQuality -ne "" -and $generatedReportQuality -ne "FULL") {
    $failureReasons.Add("Invalid approval: APPROVED_FOR_MERGE requires reportQuality FULL") | Out-Null
}
if ($accuracyScore -lt $AccuracyThreshold) {
    $failureReasons.Add("Accuracy score below threshold") | Out-Null
}

$overallStatus = if ($failureReasons.Count -gt 0) { "FAIL" } elseif ($guardrailWarnings.Count -gt 0) { "WARN" } else { "PASS" }

$outJson = [ordered]@{
    meta = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        runFolder = $runRootResolved
        generatedMetricsPath = $GeneratedMetricsPath
        manualTruthPath = $ManualTruthPath
    }
    threshold = [ordered]@{
        accuracyThreshold = [double]$AccuracyThreshold
        failOnVerdictMismatch = [bool]$FailOnVerdictMismatch
        failOnHardMismatch = [bool]$FailOnHardMismatch
    }
    verdict = [ordered]@{
        generated = [string]$generated.gateDecision
        truth = [string]$truth.verdict
        match = [bool]$verdictMatch
    }
    management = [ordered]@{
        path = $managementPath
        requiredHeaders = @($requiredManagementHeaders)
        headersFound = $managementFound
        complete = [bool]$managementComplete
    }
    comparisons = @($comparisons)
    scoring = [ordered]@{
        weights = [ordered]@{
            verdict = 40
            tests = 20
            coverage = 20
            staticSecurity = 10
            managementCompleteness = 10
        }
        components = [ordered]@{
            verdict = $scoreVerdict
            tests = $scoreTests
            coverage = $scoreCoverage
            staticSecurity = $scoreStatic
            managementCompleteness = $scoreManagement
        }
        accuracyScore = [double]$accuracyScore
    }
    guardrails = [ordered]@{
        warnings = @($guardrailWarnings.ToArray())
    }
    failures = @($failureReasons.ToArray())
    overallStatus = $overallStatus
}

$jsonPath = Join-Path $validationRoot "report-vs-truth.json"
$mdPath = Join-Path $validationRoot "report-vs-truth.md"

$outJson | ConvertTo-Json -Depth 40 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Report vs Truth Comparison") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Summary") | Out-Null
$lines.Add("| Field | Value |") | Out-Null
$lines.Add("| --- | --- |") | Out-Null
$lines.Add("| Overall Status | **$overallStatus** |") | Out-Null
$lines.Add("| Accuracy Score | **$accuracyScore%** |") | Out-Null
$lines.Add("| Accuracy Threshold | $AccuracyThreshold% |") | Out-Null
$lines.Add("| Verdict Match | $verdictMatch |") | Out-Null
$lines.Add("| Management Completeness | $managementFound/$($requiredManagementHeaders.Count) |") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Weighted Components") | Out-Null
$lines.Add("| Component | Score | Max |") | Out-Null
$lines.Add("| --- | --- | --- |") | Out-Null
$lines.Add("| Verdict | $scoreVerdict | 40 |") | Out-Null
$lines.Add("| Test metrics | $scoreTests | 20 |") | Out-Null
$lines.Add("| Coverage | $scoreCoverage | 20 |") | Out-Null
$lines.Add("| Static/Security | $scoreStatic | 10 |") | Out-Null
$lines.Add("| Management completeness | $scoreManagement | 10 |") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Field Deltas") | Out-Null
$lines.Add("| Field | Generated | Truth | Delta | Tolerance | Pass |") | Out-Null
$lines.Add("| --- | --- | --- | --- | --- | --- |") | Out-Null
foreach ($c in $comparisons) {
    $lines.Add("| $($c.name) | $($c.generated) | $($c.truth) | $($c.delta) | $($c.tolerance) | $($c.pass) |") | Out-Null
}
$lines.Add("") | Out-Null

if ($guardrailWarnings.Count -gt 0) {
    $lines.Add("## Guardrail Warnings") | Out-Null
    foreach ($w in $guardrailWarnings) {
        $lines.Add("- $w") | Out-Null
    }
    $lines.Add("") | Out-Null
}

if ($failureReasons.Count -gt 0) {
    $lines.Add("## Fail Reasons") | Out-Null
    foreach ($f in $failureReasons) {
        $lines.Add("- $f") | Out-Null
    }
}

$lines | Set-Content -Path $mdPath -Encoding UTF8

Write-Step "Status: $overallStatus"
Write-Step "Accuracy: $accuracyScore"
Write-Step "Verdict match: $verdictMatch"
Write-Step "Output: $jsonPath"
Write-Step "Output: $mdPath"

if ($overallStatus -eq "FAIL") {
    exit 1
}

exit 0
