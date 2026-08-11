[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsRoot,

    [Parameter(Mandatory = $false)]
    [string]$RunFolder,

    [Parameter(Mandatory = $false)]
    [string]$PandocPath,

    [Parameter(Mandatory = $false)]
    [string]$WkhtmltopdfPath,

    [switch]$StrictMode
)

$ErrorActionPreference = "Continue"

function Resolve-ToolPath {
    param(
        [string]$ToolName,
        [string]$ExplicitPath,
        [string[]]$FallbackPaths
    )

    if ($ExplicitPath) {
        if (Test-Path $ExplicitPath) { return (Resolve-Path $ExplicitPath).Path }
        return $null
    }

    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    foreach ($f in $FallbackPaths) {
        if ($f -and (Test-Path $f)) { return (Resolve-Path $f).Path }
    }

    return $null
}

function Get-LatestRunFolder {
    param([string]$RootPath)

    return (Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}_\d{6}$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactsRootPath = if ([System.IO.Path]::IsPathRooted($ArtifactsRoot)) { $ArtifactsRoot } else { Join-Path $repoRoot $ArtifactsRoot }

if (-not (Test-Path $artifactsRootPath)) {
    Write-Host "[pdf] Artifacts root not found: $artifactsRootPath"
    exit 0
}

$runDir = if ($RunFolder) {
    if ([System.IO.Path]::IsPathRooted($RunFolder)) { Get-Item -Path $RunFolder -ErrorAction SilentlyContinue } else { Get-Item -Path (Join-Path $artifactsRootPath $RunFolder) -ErrorAction SilentlyContinue }
}
else {
    Get-LatestRunFolder -RootPath $artifactsRootPath
}

if (-not $runDir) {
    Write-Host "[pdf] No run folder found."
    exit 0
}

$runRoot = $runDir.FullName
$reportsDir = Join-Path $runRoot "reports"
$statusDir = Join-Path $runRoot "status"
New-Item -ItemType Directory -Force -Path $reportsDir, $statusDir | Out-Null

$mdFiles = @(Get-ChildItem -Path $reportsDir -File -Filter "*.md" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "PDF_FALLBACK_NOTE.md" })

$pdfGenerated = $false
$reason = ""
$converted = 0
$failed = 0

if ($mdFiles.Count -eq 0) {
    $reason = "missing-markdown-source"
    Write-Host "[pdf] No markdown report found under $reportsDir"

    $pdfStatus = [pscustomobject]@{
        pdfGenerated = $false
        reason = $reason
        markdownCount = 0
        pdfCount = 0
    }
    $pdfStatus | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $statusDir "pdf-status.json") -Encoding UTF8
    if ($StrictMode) {
        exit 1
    }
    exit 0
}

$pandocExe = Resolve-ToolPath -ToolName "pandoc" -ExplicitPath $PandocPath -FallbackPaths @(
    (Join-Path $env:ProgramFiles "Pandoc\pandoc.exe"),
    (Join-Path $env:LocalAppData "Pandoc\pandoc.exe")
)

$wkhtmlExe = Resolve-ToolPath -ToolName "wkhtmltopdf" -ExplicitPath $WkhtmltopdfPath -FallbackPaths @(
    (Join-Path $env:ProgramFiles "wkhtmltopdf\bin\wkhtmltopdf.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "wkhtmltopdf\bin\wkhtmltopdf.exe")
)

if (-not $pandocExe -or -not $wkhtmlExe) {
    $reason = "missing-pdf-toolchain:pandoc-or-wkhtmltopdf"
    $notePath = Join-Path $reportsDir "PDF_FALLBACK_NOTE.md"
    @(
        "# PDF Fallback",
        "",
        "PDF generation was skipped because required tools were not found.",
        "",
        "- pandoc found: $([bool]$pandocExe)",
        "- wkhtmltopdf found: $([bool]$wkhtmlExe)",
        "",
        "Markdown reports remain available in this reports folder."
    ) | Set-Content -Path $notePath -Encoding UTF8
}
else {
    foreach ($md in $mdFiles) {
        $pdfPath = Join-Path $reportsDir (([System.IO.Path]::GetFileNameWithoutExtension($md.Name)) + ".pdf")
        $args = @(
            "--from", "gfm",
            "--standalone",
            "--pdf-engine=$wkhtmlExe",
            "--pdf-engine-opt=--enable-local-file-access",
            "--output", $pdfPath,
            $md.FullName
        )
        & $pandocExe @args
        if ($LASTEXITCODE -eq 0 -and (Test-Path $pdfPath)) {
            $converted++
        }
        else {
            $failed++
        }
    }

    $pdfGenerated = $converted -gt 0
    if ($pdfGenerated) {
        $reason = "ok"
    }
    else {
        $reason = "conversion-failed"
        $notePath = Join-Path $reportsDir "PDF_FALLBACK_NOTE.md"
        @(
            "# PDF Fallback",
            "",
            "PDF conversion was attempted but did not produce output.",
            "",
            "- Markdown files: $($mdFiles.Count)",
            "- Converted: $converted",
            "- Failed: $failed"
        ) | Set-Content -Path $notePath -Encoding UTF8
    }
}

$pdfStatus = [pscustomobject]@{
    pdfGenerated = [bool]$pdfGenerated
    reason = $reason
    markdownCount = $mdFiles.Count
    pdfCount = @(Get-ChildItem -Path $reportsDir -File -Filter "*.pdf" -ErrorAction SilentlyContinue).Count
}
$pdfStatus | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $statusDir "pdf-status.json") -Encoding UTF8

Write-Host "[pdf] Run folder: $runRoot"
Write-Host "[pdf] Markdown count: $($mdFiles.Count)"
Write-Host "[pdf] PDF generated: $pdfGenerated"
Write-Host "[pdf] Reason: $reason"

if ($StrictMode -and -not $pdfGenerated -and $reason -eq "missing-markdown-source") {
    exit 1
}

exit 0
