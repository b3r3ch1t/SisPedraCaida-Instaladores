<#
.SYNOPSIS
    Roda os testes Pester do núcleo de empacotamento e sai com código ≠ 0 se algum falhar.

.DESCRIPTION
    Os testes (`Empacotamento.Tests.ps1`) funcionam no Pester 3.4 — o que já vem com o Windows, e
    portanto com o runner dos instaladores, sem instalar nada — e no Pester 5. O que muda entre as
    versões é só a CHAMADA e o objeto de resultado; este script escolhe a certa.

    Usado pelo job `testar-scripts` do `instaladores-windows.yml`, que roda ANTES de empacotar: um
    módulo quebrado reprova ali, com o teste que diz o quê, em vez de no meio do terceiro instalador.

.EXAMPLE
    pwsh installer/common/Invoke-TestesEmpacotamento.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    throw 'Pester não encontrado. O Windows traz o 3.4 em C:\Program Files\WindowsPowerShell\Modules; ' +
        'no Linux: Install-Module Pester -Scope CurrentUser.'
}

Import-Module $pester.Path -Force
$alvo = Join-Path $PSScriptRoot 'Empacotamento.Tests.ps1'
Write-Host "Pester $($pester.Version) — $alvo" -ForegroundColor DarkGray

if ($pester.Version.Major -ge 5) {
    $resultado = Invoke-Pester -Path $alvo -PassThru -Output Detailed
    $falhas = $resultado.FailedCount
}
else {
    $resultado = Invoke-Pester -Script $alvo -PassThru
    $falhas = $resultado.FailedCount
}

if ($falhas -gt 0) {
    Write-Host "$falhas teste(s) falharam." -ForegroundColor Red
    exit 1
}

Write-Host 'Testes do Empacotamento.psm1: todos verdes.' -ForegroundColor Green
exit 0
