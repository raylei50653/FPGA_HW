[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'status', 'import', 'create', 'open')]
    [string]$Action = 'help',
    [Parameter(Position = 1)]
    [ValidatePattern('^HW[1-9][0-9]*$')]
    [string]$Homework = 'HW1',
    [switch]$Update,
    [string]$VivadoProjectPath,
    [string]$VivadoExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$homeworkDir = Join-Path $repoRoot $Homework
$projectFile = Join-Path (Join-Path (Join-Path $repoRoot 'vivado') $Homework) "$Homework.xpr"
if ([string]::IsNullOrWhiteSpace($VivadoProjectPath)) {
    $VivadoProjectPath = Join-Path (Split-Path -Parent $repoRoot) 'project_1'
}

function Get-VivadoExecutable {
    if (-not [string]::IsNullOrWhiteSpace($VivadoExecutable)) {
        if (-not (Test-Path -LiteralPath $VivadoExecutable -PathType Leaf)) {
            throw "找不到 Vivado 執行檔：$VivadoExecutable"
        }
        return (Resolve-Path -LiteralPath $VivadoExecutable).Path
    }

    $command = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $installed = 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat'
    if (Test-Path -LiteralPath $installed -PathType Leaf) {
        return $installed
    }
    throw '找不到 Vivado。請用 -VivadoExecutable 指定 vivado.bat 的完整路徑。'
}

switch ($Action) {
    'help' {
        Write-Host '用法：.\fpga.ps1 <status|import|create|open> [HW編號]'
        Write-Host '  status HW1          查看來源、專案與 Git 狀態'
        Write-Host '  import HW1          從舊專案匯入，內容衝突時停止'
        Write-Host '  import HW1 -Update  確認後以舊專案版本更新'
        Write-Host '  create HW1          從 Git 原始碼建立 Vivado 專案'
        Write-Host '  open HW1            開啟已建立的 Vivado 專案'
        break
    }
    'status' {
        Write-Host "作業：$Homework"
        Write-Host "舊專案：$VivadoProjectPath"
        Write-Host "作業目錄：$homeworkDir"
        Write-Host "Vivado 專案：$(if (Test-Path -LiteralPath $projectFile) { $projectFile } else { '尚未建立' })"
        Write-Host 'Git 變更：'
        git -C $repoRoot status --short -- $Homework
        if ($LASTEXITCODE -ne 0) {
            throw '無法讀取 Git 狀態。'
        }
        break
    }
    'import' {
        & (Join-Path $repoRoot 'scripts\Import-VivadoSources.ps1') -Homework $Homework -VivadoProjectPath $VivadoProjectPath -Update:$Update
        Write-Host "請檢查 $Homework 的 Git 變更："
        git -C $repoRoot status --short -- $Homework
        if ($LASTEXITCODE -ne 0) {
            throw '無法讀取 Git 狀態。'
        }
        break
    }
    'create' {
        if (Test-Path -LiteralPath $projectFile -PathType Leaf) {
            Write-Host "專案已存在：$projectFile。可直接使用 open $Homework。"
            break
        }
        if (-not (Test-Path -LiteralPath $homeworkDir -PathType Container)) {
            throw "找不到作業目錄：$homeworkDir"
        }
        $vivado = Get-VivadoExecutable
        $homeworkScript = Join-Path $homeworkDir 'Create-Project.tcl'
        if (Test-Path -LiteralPath $homeworkScript -PathType Leaf) {
            & $vivado -mode batch -source $homeworkScript
        } else {
            & $vivado -mode batch -source (Join-Path $repoRoot 'scripts\Create-VivadoProject.tcl') -tclargs $Homework
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Vivado 建立 $Homework 專案失敗。"
        }
        break
    }
    'open' {
        if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
            throw "專案尚未建立。請先執行 create $Homework。"
        }
        $vivado = Get-VivadoExecutable
        Start-Process -FilePath $vivado -ArgumentList ('"' + $projectFile + '"') -WorkingDirectory $repoRoot
        Write-Host "正在開啟：$projectFile"
        break
    }
}
