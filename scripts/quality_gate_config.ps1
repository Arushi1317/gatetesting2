Set-StrictMode -Version 2

function Get-QgAbsolutePath {
    param(
        [string]$BasePath,
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $BasePath }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $BasePath $PathValue)
}

function ConvertTo-QgHashtable {
    param([object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [hashtable]) {
        $h = @{}
        foreach ($k in $Value.Keys) {
            $h[$k] = ConvertTo-QgHashtable -Value $Value[$k]
        }
        return $h
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-QgHashtable -Value $p.Value
        }
        return $h
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $arr = @()
        foreach ($item in $Value) {
            $arr += ,(ConvertTo-QgHashtable -Value $item)
        }
        return ,$arr
    }

    return $Value
}

function Merge-QgDeep {
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )

    $merged = @{}
    foreach ($k in $Base.Keys) {
        $merged[$k] = $Base[$k]
    }

    foreach ($k in $Override.Keys) {
        if ($merged.ContainsKey($k) -and $merged[$k] -is [hashtable] -and $Override[$k] -is [hashtable]) {
            $merged[$k] = Merge-QgDeep -Base $merged[$k] -Override $Override[$k]
        }
        else {
            $merged[$k] = $Override[$k]
        }
    }

    return $merged
}

function Get-QgMappedLegacyOverride {
    param(
        [string]$RepoRoot,
        [string]$LegacyValidationPath,
        [string]$LegacyScoringPath
    )

    $mapped = @{}

    $validationAbs = Get-QgAbsolutePath -BasePath $RepoRoot -PathValue $LegacyValidationPath
    if (Test-Path $validationAbs) {
        try {
            $legacy = Get-Content -Path $validationAbs -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $mapped.ContainsKey("tolerances")) { $mapped["tolerances"] = @{} }
            if ($legacy.tolerance) {
                if ($null -ne $legacy.tolerance.coveragePct) { $mapped["tolerances"]["coveragePct"] = [double]$legacy.tolerance.coveragePct }
                if ($null -ne $legacy.tolerance.testCounts) { $mapped["tolerances"]["testCounts"] = [double]$legacy.tolerance.testCounts }
                if ($null -ne $legacy.tolerance.severityCounts) { $mapped["tolerances"]["sarifCounts"] = [double]$legacy.tolerance.severityCounts }
            }

            if (-not $mapped.ContainsKey("policy")) { $mapped["policy"] = @{} }
            if ($legacy.passCriteria) {
                if ($null -ne $legacy.passCriteria.minCompletenessPct) { $mapped["policy"]["minCompletenessPct"] = [double]$legacy.passCriteria.minCompletenessPct }
                if ($legacy.passCriteria.requiredConfidence) { $mapped["policy"]["minConfidence"] = [string]$legacy.passCriteria.requiredConfidence }
            }

            if ($legacy.requiredInputs) {
                if (($legacy.requiredInputs.trx -eq $false) -or ($legacy.requiredInputs.coverage -eq $false) -or ($legacy.requiredInputs.sarif -eq $false)) {
                    $mapped["policy"]["failOnMissingEvidence"] = $false
                }
            }
        }
        catch {
            Write-Warning "Legacy validation config could not be parsed: $validationAbs"
        }
    }

    $scoringAbs = Get-QgAbsolutePath -BasePath $RepoRoot -PathValue $LegacyScoringPath
    if (Test-Path $scoringAbs) {
        try {
            $legacyScore = Get-Content -Path $scoringAbs -Raw -Encoding UTF8 | ConvertFrom-Json
            $mapped["scoring"] = @{}
            if ($legacyScore.thresholds) { $mapped["scoring"]["thresholds"] = ConvertTo-QgHashtable -Value $legacyScore.thresholds }
            if ($legacyScore.weights) { $mapped["scoring"]["weights"] = ConvertTo-QgHashtable -Value $legacyScore.weights }
        }
        catch {
            Write-Warning "Legacy scoring config could not be parsed: $scoringAbs"
        }
    }

    return $mapped
}

function Ensure-QgDefaults {
    param([hashtable]$Config)

    if (-not $Config.ContainsKey("artifacts")) { $Config["artifacts"] = @{} }
    if (-not $Config["artifacts"].ContainsKey("root")) { $Config["artifacts"]["root"] = "artifacts" }
    if (-not $Config["artifacts"].ContainsKey("layout")) { $Config["artifacts"]["layout"] = @{} }

    $layout = $Config["artifacts"]["layout"]
    if (-not $layout.ContainsKey("rawTestResults")) { $layout["rawTestResults"] = "raw/test-results" }
    if (-not $layout.ContainsKey("rawCoverage")) { $layout["rawCoverage"] = "raw/coverage" }
    if (-not $layout.ContainsKey("rawSarif")) { $layout["rawSarif"] = "raw/sarif" }
    if (-not $layout.ContainsKey("status")) { $layout["status"] = "status" }
    if (-not $layout.ContainsKey("validation")) { $layout["validation"] = "validation" }

    if (-not $Config.ContainsKey("policy")) { $Config["policy"] = @{} }
    if (-not $Config["policy"].ContainsKey("mode")) { $Config["policy"]["mode"] = "permissive" }
    if (-not $Config["policy"].ContainsKey("failOnBuildError")) { $Config["policy"]["failOnBuildError"] = $false }
    if (-not $Config["policy"].ContainsKey("failOnMissingEvidence")) { $Config["policy"]["failOnMissingEvidence"] = $false }

    if (-not $Config.ContainsKey("stacks")) { $Config["stacks"] = @{} }
    foreach ($s in @("dotnet", "node", "python", "java", "go", "rust", "unknown")) {
        if (-not $Config["stacks"].ContainsKey($s)) {
            $Config["stacks"][$s] = @{
                requiredTools = @()
                setupCommands = @()
                buildCommands = @()
                testCommands = @()
                analysisCommands = @()
            }
        }
    }
}

function Test-QgConfigSemantics {
    param([hashtable]$Config)

    $errors = New-Object System.Collections.Generic.List[string]
    function Add-Err { param([string]$M) $errors.Add($M) | Out-Null }

    if (-not $Config.ContainsKey("version") -or [string]::IsNullOrWhiteSpace([string]$Config["version"])) {
        Add-Err "version must be a non-empty string."
    }

    $covAllowed = @("cobertura", "opencover", "lcov", "jacoco")
    if ($Config.ContainsKey("coverage") -and $Config["coverage"].ContainsKey("format")) {
        if (-not ($covAllowed -contains [string]$Config["coverage"]["format"])) {
            Add-Err "coverage.format must be one of: cobertura, opencover, lcov, jacoco."
        }
    }

    $modeAllowed = @("strict", "permissive")
    if (-not ($modeAllowed -contains [string]$Config["policy"]["mode"])) {
        Add-Err "policy.mode must be one of: strict, permissive."
    }

    $confAllowed = @("Low", "Medium", "High")
    if ($Config["policy"].ContainsKey("minConfidence") -and -not ($confAllowed -contains [string]$Config["policy"]["minConfidence"])) {
        Add-Err "policy.minConfidence must be one of: Low, Medium, High."
    }

    if ([double]$Config["policy"]["minCompletenessPct"] -lt 0 -or [double]$Config["policy"]["minCompletenessPct"] -gt 100) {
        Add-Err "policy.minCompletenessPct must be within 0..100."
    }

    foreach ($stackName in @("dotnet", "node", "python", "java", "go", "rust", "unknown")) {
        if (-not $Config["stacks"].ContainsKey($stackName)) {
            Add-Err "stacks.$stackName is required."
            continue
        }
        $s = $Config["stacks"][$stackName]
        foreach ($k in @("requiredTools", "setupCommands", "buildCommands", "testCommands", "analysisCommands")) {
            if (-not $s.ContainsKey($k)) {
                Add-Err "stacks.$stackName.$k is required."
            }
        }
    }

    return $errors
}

function Get-EffectiveQualityGateConfig {
    param(
        [string]$RepoRoot,
        [string]$DefaultConfigPath = "config/quality-gate.default.json",
        [string]$RepoConfigPath = "quality-gate.config.json",
        [string]$SchemaPath = "config/quality-gate.schema.json",
        [string]$LegacyValidationPath = "config/report-validation.json",
        [string]$LegacyScoringPath = "config/report-scoring.json"
    )

    $defaultAbs = Get-QgAbsolutePath -BasePath $RepoRoot -PathValue $DefaultConfigPath
    $repoAbs = Get-QgAbsolutePath -BasePath $RepoRoot -PathValue $RepoConfigPath
    $schemaAbs = Get-QgAbsolutePath -BasePath $RepoRoot -PathValue $SchemaPath

    if (-not (Test-Path $defaultAbs)) { throw "Missing baseline config: $defaultAbs" }

    $defaultHash = ConvertTo-QgHashtable -Value (Get-Content -Path $defaultAbs -Raw -Encoding UTF8 | ConvertFrom-Json)
    $legacyHash = Get-QgMappedLegacyOverride -RepoRoot $RepoRoot -LegacyValidationPath $LegacyValidationPath -LegacyScoringPath $LegacyScoringPath
    $effective = Merge-QgDeep -Base $defaultHash -Override $legacyHash

    $repoExists = Test-Path $repoAbs
    if ($repoExists) {
        $repoHash = ConvertTo-QgHashtable -Value (Get-Content -Path $repoAbs -Raw -Encoding UTF8 | ConvertFrom-Json)
        $effective = Merge-QgDeep -Base $effective -Override $repoHash
    }

    Ensure-QgDefaults -Config $effective
    $errors = @(Test-QgConfigSemantics -Config $effective)

    if ((Get-Command Test-Json -ErrorAction SilentlyContinue) -and (Test-Path $schemaAbs)) {
        try {
            $effectiveJson = ($effective | ConvertTo-Json -Depth 60)
            if (-not ($effectiveJson | Test-Json -SchemaFile $schemaAbs)) {
                $errors += "Schema validation failed against $schemaAbs."
            }
        }
        catch {
            $errors += "Schema validation execution failed: $($_.Exception.Message)"
        }
    }

    if (@($errors).Count -gt 0) {
        throw ("Invalid quality gate config:`n - " + ($errors -join "`n - "))
    }

    return [pscustomobject]@{
        EffectiveConfig = $effective
        DefaultConfigPath = $defaultAbs
        RepoConfigPath = $repoAbs
        RepoConfigFound = $repoExists
        SchemaPath = $schemaAbs
    }
}

function Expand-QgTemplate {
    param(
        [string]$Template,
        [hashtable]$Values
    )

    $out = [string]$Template
    foreach ($k in $Values.Keys) {
        $out = $out.Replace("{" + $k + "}", [string]$Values[$k])
    }
    return $out
}

function Find-QgEvidenceFiles {
    param(
        [string]$RepoRoot,
        [string]$RunRoot,
        [string[]]$Patterns
    )

    $allFiles = @(Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue)
    $hits = @()

    foreach ($rawPattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace([string]$rawPattern)) { continue }

        $expanded = Expand-QgTemplate -Template ([string]$rawPattern) -Values @{
            repoRoot = $RepoRoot
            runRoot = $RunRoot
        }

        if ($expanded.StartsWith("regex:")) {
            $rx = $expanded.Substring(6)
            foreach ($f in $allFiles) {
                if ($f.FullName -match $rx) { $hits += $f }
            }
            continue
        }

        $pattern = $expanded.Replace('/', '\\')
        if (-not [System.IO.Path]::IsPathRooted($pattern)) {
            $pattern = Join-Path $RepoRoot $pattern
        }

        $wc = New-Object System.Management.Automation.WildcardPattern($pattern, ([System.Management.Automation.WildcardOptions]::IgnoreCase))
        foreach ($f in $allFiles) {
            if ($wc.IsMatch($f.FullName)) { $hits += $f }
        }
    }

    $runRootCanonical = [System.IO.Path]::GetFullPath($RunRoot)
    $filtered = @()
    foreach ($f in $hits) {
        $full = [System.IO.Path]::GetFullPath($f.FullName)
        if ($full.StartsWith($runRootCanonical, [System.StringComparison]::OrdinalIgnoreCase)) {
            $filtered += $f
            continue
        }
        if ($full -match '\\artifacts\\\d{8}_\d{6}\\') {
            continue
        }
        $filtered += $f
    }

    return @($filtered | Sort-Object FullName -Unique)
}

function New-QgEmptySarif {
    param(
        [string]$OutputPath,
        [string]$Producer = "universal-quality-gate"
    )

        @'
{
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "version": "2.1.0",
  "runs": [
    {
      "tool": {
        "driver": {
                    "name": "__PRODUCER__"
        }
      },
      "results": []
    }
  ]
}
'@ | ForEach-Object { $_.Replace('__PRODUCER__', $Producer) } | Set-Content -Path $OutputPath -Encoding UTF8
}
