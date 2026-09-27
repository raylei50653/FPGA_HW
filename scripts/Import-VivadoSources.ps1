[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^HW[1-9][0-9]*$')]
    [string]$Homework,
    [Parameter(Mandatory)]
    [string]$VivadoProjectPath,
    [switch]$Update
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath $VivadoProjectPath).Path
$projectFiles = @(Get-ChildItem -LiteralPath $projectRoot -Filter '*.xpr' -File)
if ($projectFiles.Count -ne 1) {
    throw "來源目錄必須包含一個 Vivado .xpr 專案檔：$projectRoot"
}
$projectName = $projectFiles[0].BaseName
$sourceRoot = Join-Path $projectRoot "$projectName.srcs"
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "找不到 Vivado 原始碼目錄：$sourceRoot"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$homeworkRoot = Join-Path $repoRoot $Homework
$homeworkNumber = $Homework.Substring(2)
$extensions = @('.vhd', '.vhdl', '.v', '.sv', '.svh', '.vh', '.xdc')
$unchanged = 0
$matched = 0
$pending = @()
$conflicts = @()

$sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Where-Object {
    $extensions -contains $_.Extension.ToLowerInvariant() -and
    $_.BaseName -match '^(?i:HW[_-]?[0-9]+)(?:$|[_-])'
}

foreach ($file in $sourceFiles) {
    $match = [regex]::Match($file.BaseName, '^(?i:HW[_-]?([0-9]+))(?:$|[_-])')
    if ([int]$match.Groups[1].Value -ne [int]$homeworkNumber) {
        continue
    }
    $matched++

    $category = if ($file.Extension -ieq '.xdc') {
        'constraints'
    } elseif ($file.FullName -match '[\\/]sim_[0-9]+[\\/]' -or
              $file.BaseName -match '(?i)(?:_tb|testbench)$') {
        'sim'
    } else {
        'src'
    }
    $destinationDir = Join-Path $homeworkRoot $category
    $destination = Join-Path $destinationDir $file.Name

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($sourceHash -eq $destinationHash) {
            $unchanged++
            continue
        }
        if (-not $Update) {
            $conflicts += $destination
            continue
        }
    }

    $pending += [pscustomobject]@{
        File = $file
        Directory = $destinationDir
        Destination = $destination
        Category = $category
    }
}

if ($matched -eq 0) {
    throw "舊專案中找不到 $Homework 的 HDL 或 XDC 檔案：$sourceRoot"
}
if ($conflicts.Count -gt 0) {
    throw "下列檔案內容不同，未匯入任何檔案：$($conflicts -join ', ')。確認後加上 -Update 重新執行。"
}

foreach ($item in $pending) {
    New-Item -ItemType Directory -Path $item.Directory -Force | Out-Null
    Copy-Item -LiteralPath $item.File.FullName -Destination $item.Destination -Force
    Write-Host "已匯入：$Homework/$($item.Category)/$($item.File.Name)"
}

Write-Host "完成：匯入 $($pending.Count) 個檔案，$unchanged 個檔案內容相同。"
