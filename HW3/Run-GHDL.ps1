[CmdletBinding()]
param(
    [string]$Ghdl
)

# 用 GHDL 跑 HW_3_tb（不需要開 Vivado）
#   編譯結果與擷取的 PPM 畫面放在 vivado/HW3/ghdl/（已被 .gitignore 排除）
#   安裝：winget install --id ghdl.ghdl.ucrt64.mcode -e

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Ghdl)) {
    $command = Get-Command ghdl -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $Ghdl = $command.Source
    } else {
        $installed = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Directory -Filter 'ghdl.ghdl*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'bin\ghdl.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($null -eq $installed) {
            throw '找不到 GHDL。請先執行 winget install --id ghdl.ghdl.ucrt64.mcode -e，或用 -Ghdl 指定 ghdl.exe。'
        }
        $Ghdl = $installed
    }
}

$hw = $PSScriptRoot
$work = Join-Path (Split-Path -Parent $hw) 'vivado\HW3\ghdl'
New-Item -ItemType Directory -Force $work | Out-Null

$sources = @(
    'src\HW_3_timing.vhd',
    'src\HW_3_btn.vhd',
    'src\HW_3_solid.vhd',
    'src\HW_3_hdmi_cfg.vhd',
    'src\HW_3.vhd',
    'sim\HW_3_tb.vhd'
) | ForEach-Object { Join-Path $hw $_ }

Push-Location $work
try {
    & $Ghdl -a --std=08 @sources
    if ($LASTEXITCODE -ne 0) { throw 'GHDL 分析失敗' }
    & $Ghdl -e --std=08 HW_3_tb
    if ($LASTEXITCODE -ne 0) { throw 'GHDL elaboration 失敗' }

    $elapsed = Measure-Command { & $Ghdl -r --std=08 HW_3_tb --ieee-asserts=disable-at-0 | Out-Host }
    Write-Host ("模擬時間：{0:N0} 秒；畫面存在 {1}" -f $elapsed.TotalSeconds, $work)
    if ($LASTEXITCODE -ne 0) { throw 'HW_3_tb 沒有通過' }
} finally {
    Pop-Location
}
