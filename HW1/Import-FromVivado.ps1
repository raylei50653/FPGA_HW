[CmdletBinding()]
param(
    [string]$VivadoProjectPath = 'D:\Documents\vivado_2\project_1',
    [switch]$Update
)

& (Join-Path $PSScriptRoot '..\scripts\Import-VivadoSources.ps1') -Homework HW1 -VivadoProjectPath $VivadoProjectPath -Update:$Update
