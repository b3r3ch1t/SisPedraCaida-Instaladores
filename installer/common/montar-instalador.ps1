<#
.SYNOPSIS
    Remonta um instalador versionado em partes e confere o SHA-256.

.DESCRIPTION
    O instalador do PrintMonitor passa do limite de 100 MiB por arquivo do GitHub e é versionado em
    partes (`build-installer.ps1 -DividirEmPartes`): `PrintMonitorSetup-X.Y.Z.zip.001`, `.002`… de até
    90 MiB, um zip com o `.exe` e o `.sha256` dentro. Este script concatena as partes na ordem, extrai e
    confere o `.exe` contra `<instalador>.sha256`, que é o hash do instalador INTEIRO: se não bater, o
    `.exe` é apagado e o script falha — instalador corrompido não pode ficar na pasta parecendo bom.

    Pacotes anteriores a 23/10/2026 eram as partes cruas do `.exe` (`<instalador>.001`…); sem
    `.zip.001` ao lado, o script remonta esse formato.

    Sem PowerShell à mão: o 7-Zip abre a `.zip.001` direto; ou, no cmd,
    `copy /b PrintMonitorSetup-X.Y.Z.zip.001+PrintMonitorSetup-X.Y.Z.zip.002+PrintMonitorSetup-X.Y.Z.zip.003 PrintMonitorSetup-X.Y.Z.zip`,
    extrair pelo Explorer e conferir com `certutil -hashfile PrintMonitorSetup-X.Y.Z.exe SHA256` contra
    o `.sha256`.

    Compatível com Windows PowerShell 5.1.

.PARAMETER Instalador
    Caminho do `.exe` a produzir; as partes e o `.sha256` ficam ao lado dele.

.EXAMPLE
    pwsh installer/common/montar-instalador.ps1 -Instalador artifacts/installer/PrintMonitorSetup-3.14.1.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Instalador
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Empacotamento.psm1') -Force

$pacote = [System.IO.Path]::ChangeExtension($Instalador, '.zip')
if (Test-Path "$pacote.001") {
    $remontado = Expand-PacoteZipEmPartes -Pacote $pacote
}
else {
    $remontado = Join-PartesDoArquivo -Arquivo $Instalador
}

if (-not (Test-Path "$remontado.sha256")) {
    Remove-Item $remontado -Force
    throw "Sem $(Split-Path $remontado -Leaf).sha256 ao lado das partes: nao ha como conferir o instalador remontado."
}

if (-not (Test-ArquivoSha256 -Arquivo $remontado)) {
    Remove-Item $remontado -Force
    throw "SHA-256 do instalador remontado nao confere com $(Split-Path $remontado -Leaf).sha256. Parte corrompida ou de outra versao."
}

$hash = (Get-FileHash -Path $remontado -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Instalador: $remontado" -ForegroundColor Green
Write-Host "SHA-256:    $hash  (confere com o .sha256)" -ForegroundColor Green
