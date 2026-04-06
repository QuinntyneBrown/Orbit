#Requires -Version 7.2
<#
.SYNOPSIS
    Builds a DOCX (and optionally PDF) resume from a Markdown source file.
.DESCRIPTION
    - Determines output directory: content/base/ -> resumes/base/, content/tailored/ -> resumes/tailored/
    - Requires Pandoc on PATH and templates/reference.docx
    - Optionally generates a PDF via scripts/build-pdf.mjs (requires Node.js)
.PARAMETER InputFile
    Path to the Markdown (.md) source file.
.PARAMETER PDF
    Switch. If specified, also generate a PDF via Playwright after building the DOCX.
.EXAMPLE
    .\build-resume.ps1 -InputFile content/base/focused-base.md
    .\build-resume.ps1 -InputFile content/tailored/acme-sra.md -PDF
#>
param(
    [Parameter(Mandatory)]
    [string]$InputFile,

    [switch]$PDF
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)

# Resolve absolute input path
if (-not [System.IO.Path]::IsPathRooted($InputFile)) {
    $InputFile = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $InputFile))
}

if (-not (Test-Path $InputFile)) {
    [Console]::Error.WriteLine("ERROR: Input file not found: $InputFile")
    exit 1
}

# --- Determine output directory ---
$normalizedInput = $InputFile.Replace('\', '/')
$baseContentDir    = (Join-Path $repoRoot 'content\base').Replace('\', '/')
$tailoredContentDir = (Join-Path $repoRoot 'content\tailored').Replace('\', '/')

if ($normalizedInput.StartsWith($baseContentDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    $outputDir = Join-Path $repoRoot 'resumes\base'
} elseif ($normalizedInput.StartsWith($tailoredContentDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    $outputDir = Join-Path $repoRoot 'resumes\tailored'
} else {
    [Console]::Error.WriteLine("ERROR: InputFile must be under content/base/ or content/tailored/. Got: $InputFile")
    exit 1
}

# Ensure output directory exists
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# --- Check Pandoc is available ---
$pandocCmd = Get-Command pandoc -ErrorAction SilentlyContinue
if (-not $pandocCmd) {
    [Console]::Error.WriteLine("ERROR: pandoc is not on PATH. Install Pandoc from https://pandoc.org/installing.html")
    exit 1
}

# --- Check reference.docx exists ---
$referenceDoc = Join-Path $repoRoot 'templates\reference.docx'
if (-not (Test-Path $referenceDoc)) {
    [Console]::Error.WriteLine("ERROR: templates/reference.docx not found. Place your reference DOCX at: $referenceDoc")
    exit 1
}

# --- Build DOCX output path ---
$baseName   = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
$outputPath = Join-Path $outputDir "$baseName.docx"

# --- Run Pandoc ---
Write-Host "Building DOCX: $outputPath"
$pandocArgs = @(
    $InputFile,
    '-o', $outputPath,
    "--reference-doc=$referenceDoc"
)
& pandoc @pandocArgs
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("ERROR: Pandoc exited with code $LASTEXITCODE")
    exit 1
}
Write-Host "DOCX built successfully: $outputPath"

# --- Optionally build PDF ---
if ($PDF) {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        [Console]::Error.WriteLine("ERROR: node is not on PATH. Install Node.js to generate PDFs.")
        exit 1
    }
    $buildPdfScript = Join-Path $repoRoot 'scripts\build-pdf.mjs'
    Write-Host "Building PDF via: $buildPdfScript"
    & node $buildPdfScript $InputFile
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("ERROR: build-pdf.mjs exited with code $LASTEXITCODE")
        exit 1
    }
    Write-Host "PDF built successfully."
}

exit 0
