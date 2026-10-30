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

    Fora do repositório (pasta baixada avulsa do GitHub): duplo clique no `montar-instalador.cmd` que vai
    ao lado das partes (PRD-ELGPRE-02) — junta, extrai e confere o hash só com o que o Windows traz. O
    7-Zip também abre a `.zip.001` direto. ⚠️ Não monte um `copy /b` com a lista de partes à mão: o
    número de partes muda entre versões (o 5.14.0 tem duas), e uma parte que não existe aborta o `copy`.

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
