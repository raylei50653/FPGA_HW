[CmdletBinding()]
param(
    [string]$VivadoProjectPath = 'D:\Documents\vivado_2\project_1',
    [string]$HomeworkRoot,
    [string]$ProjectCopyPath,
    [switch]$SkipProjectCopy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($HomeworkRoot)) {
    $HomeworkRoot = Split-Path -Parent $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($ProjectCopyPath)) {
    $ProjectCopyPath = Join-Path $HomeworkRoot 'vivado\project_1'
}

$sourceRoot = (Resolve-Path -LiteralPath $VivadoProjectPath).Path
$homeworkRootFull = [System.IO.Path]::GetFullPath($HomeworkRoot)
$projectCopyFull = [System.IO.Path]::GetFullPath($ProjectCopyPath)

New-Item -ItemType Directory -Path $homeworkRootFull -Force | Out-Null

if (-not $SkipProjectCopy) {
    if ($sourceRoot.TrimEnd('\') -ieq $projectCopyFull.TrimEnd('\')) {
        throw 'The source project and project-copy destination must be different paths.'
    }

    New-Item -ItemType Directory -Path $projectCopyFull -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $projectCopyFull -Recurse -Force
    Write-Host "Project copy updated: $projectCopyFull"
}

$supportedExtensions = @(
    '.vhd', '.vhdl', '.v', '.sv', '.svh', '.vh',
    '.xdc', '.tcl', '.xci', '.bd', '.coe'
)

$copied = 0
$skipped = 0

$sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Where-Object {
    $_.FullName -match '\.srcs[\\/]' -and
    $supportedExtensions -contains $_.Extension.ToLowerInvariant()
}

foreach ($file in $sourceFiles) {
    $homeworkMatch = [regex]::Match($file.BaseName, '(?i)^HW[_-]?(\d+)')
    if (-not $homeworkMatch.Success) {
        Write-Warning "Skipped file without an HW number: $($file.FullName)"
        $skipped++
        continue
    }

    $homeworkName = "HW$($homeworkMatch.Groups[1].Value)"
    $isSimulation =
        $file.BaseName -match '(?i)(?:_tb|testbench)$' -or
        $file.FullName -match '(?i)[\\/]sim_\d+[\\/]'
    $category = if ($isSimulation) { 'sim' } else { 'src' }
    $destinationDirectory = Join-Path (Join-Path $homeworkRootFull $homeworkName) $category

    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destinationDirectory $file.Name) -Force
    Write-Host "[$homeworkName/$category] $($file.Name)"
    $copied++
}

Write-Host "Done. Copied $copied source file(s); skipped $skipped file(s)."
