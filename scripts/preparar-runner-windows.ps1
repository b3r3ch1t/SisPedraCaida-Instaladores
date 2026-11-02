<#
.SYNOPSIS
    Prepara esta máquina Windows como o runner `[self-hosted, windows, instaladores]` deste repositório
    (runbook docs/RunnerWindowsInstaladores.md §3, §4 e §5), de forma idempotente.

.DESCRIPTION
    Junta num script só os passos do runbook que exigem ADMINISTRADOR — e que, por isso, uma sessão de
    código não executa sozinha:
      1. PowerShell 7 (MSI oficial) e Inno Setup 6 (`winget --scope machine`). O pwsh da Microsoft
         Store mora em `%LOCALAPPDATA%\Microsoft\WindowsApps` e NÃO existe para
         `NT AUTHORITY\NETWORK SERVICE`, a conta do serviço — todo `shell: pwsh` do workflow morreria
         com "pwsh não encontrado" (é a causa nº 1 do runbook, §3).
      2. `LongPathsEnabled` e `git config --system core.longpaths` (o `--system` vale para a conta do
         serviço; o `--global` de quem roda o script, não).
      3. Leitura e execução para a conta do serviço nos dois caches de payload do PrintMonitor (§5).
      4. Registro do runner em `C:\actions-runner` como serviço, com o label `instaladores`. O token de
         registro é pedido à API pelo `gh` autenticado de quem roda o script e vai direto ao
         `config.cmd`: nunca é impresso nem gravado em arquivo (§4).

    O pacote do runner já precisa estar extraído em `-RunnerDir` (o `config.cmd` presente). Os pacotes
    instalados pelo `winget` mudam o PATH da máquina: por isso o registro (que cria e inicia o serviço)
    vem por último — um serviço iniciado antes não enxergaria o pwsh novo até reiniciar.

    Compatível com o Windows PowerShell 5.1: é o que existe numa máquina limpa antes do passo 1.

.PARAMETER RunnerDir
    Onde o pacote do runner foi extraído. Padrão `C:\actions-runner` — curto de propósito, o MSBuild
    segue preso a 260 caracteres (armadilha c do CLAUDE.md).

.PARAMETER RunnerName
    Nome do runner no GitHub. Padrão `instaladores-win-01`.

.PARAMETER Repositorio
    `dono/repo` em que o runner é registrado. Padrão `b3r3ch1t/SisPedraCaida-Instaladores`.

.PARAMETER PayloadDir
    Cache do QZ Tray. Padrão `C:\ci-cache\printmonitor-payload`.

.PARAMETER WebView2PayloadDir
    Cache do bootstrapper do WebView2 Runtime do totem. Padrão `C:\ci-cache\totem-webview2`
    (PRD-TOTEMINST-02; receita em `installer/totem/payload-webview2/README.md`).

.PARAMETER PwshVersion
    Versão do PowerShell 7 instalada pelo MSI da release oficial. Padrão `7.6.9`.

.EXAMPLE
    # Num PowerShell aberto como administrador:
    powershell -ExecutionPolicy Bypass -File scripts\preparar-runner-windows.ps1
#>
[CmdletBinding()]
param(
    [string] $RunnerDir = 'C:\actions-runner',
    [string] $RunnerName = 'instaladores-win-01',
    [string] $Repositorio = 'b3r3ch1t/SisPedraCaida-Instaladores',
    [string] $PayloadDir = 'C:\ci-cache\printmonitor-payload',
    [string] $WebView2PayloadDir = 'C:\ci-cache\totem-webview2',
    [string] $PwshVersion = '7.6.9'
)

$ErrorActionPreference = 'Stop'

function Write-Etapa([string] $Texto) { Write-Host "`n==> $Texto" -ForegroundColor Cyan }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Rode este script num PowerShell aberto como ADMINISTRADOR.' }

if (-not (Test-Path (Join-Path $RunnerDir 'config.cmd'))) {
    throw "Pacote do runner não encontrado em $RunnerDir (extraia o actions-runner-win-x64-*.zip lá antes)."
}

# Conta do serviço do runner (§4: empacotar não precisa de administrador). Pelo SID, que não muda com o
# idioma do Windows ("SERVIÇO DE REDE" no pt-BR).
$contaServico = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-20').Translate([Security.Principal.NTAccount]).Value

# ---- 1. Ferramentas em escopo de máquina ----
# PowerShell 7 pelo MSI da release oficial, NÃO pelo winget: o manifesto `Microsoft.PowerShell` com
# `--scope machine` é um .msixbundle (provisionamento MSIX), que falha com 0x80070005 e ainda remove o pwsh
# da Store de quem roda o script (reproduzido em 27/10/2026). O MSI instala em Program Files\PowerShell\7 e
# põe o diretório no PATH da máquina — que é o que a conta do serviço enxerga.
Write-Etapa "PowerShell $PwshVersion (MSI, máquina)"
$pwshMaquina = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (Test-Path $pwshMaquina) {
    Write-Host "Já instalado: $pwshMaquina"
}
else {
    $msi = "PowerShell-$PwshVersion-win-x64.msi"
    $tmp = Join-Path $env:TEMP "preparar-runner-$PID"
    New-Item -ItemType Directory $tmp -Force | Out-Null
    try {
        & gh release download "v$PwshVersion" -R PowerShell/PowerShell -p $msi -D $tmp --clobber
        if ($LASTEXITCODE -ne 0) { throw "Download de $msi falhou." }
        # O digest da release (API) é a referência: hash calculado só do arquivo baixado não prova nada.
        # ConvertFrom-Json, não `--jq`: o 5.1 engole aspas embutidas no argumento de executável nativo.
        $release = (& gh api "repos/PowerShell/PowerShell/releases/tags/v$PwshVersion") -join "`n" | ConvertFrom-Json
        $esperado = [string](@($release.assets | Where-Object { $_.name -eq $msi })[0].digest) -replace '^sha256:', ''
        $obtido = (Get-FileHash (Join-Path $tmp $msi) -Algorithm SHA256).Hash.ToLower()
        if (-not $esperado -or $obtido -ne $esperado) { throw "SHA-256 de $msi não confere ($obtido × $esperado)." }

        $log = Join-Path $tmp 'pwsh-msi.log'
        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
            '/i', "`"$(Join-Path $tmp $msi)`"", '/qn', '/norestart', '/l*v', "`"$log`"",
            'ADD_PATH=1', 'REGISTER_MANIFEST=1', 'USE_MU=0', 'ENABLE_MU=0',
            'ENABLE_PSREMOTING=0', 'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0')
        # 3010 = instalado, reinício pendente: o serviço do runner é criado depois e já pega o PATH novo.
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "msiexec $msi falhou ($($p.ExitCode)); log em $log." }
    }
    finally {
        Remove-Item (Join-Path $tmp $msi) -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $pwshMaquina)) { throw "pwsh de máquina não encontrado em $pwshMaquina." }
}

Write-Etapa 'Inno Setup 6 (winget, --scope machine)'
& winget install --id JRSoftware.InnoSetup --scope machine --exact --silent --accept-package-agreements --accept-source-agreements
# -1978335189 (sem atualização aplicável) e -1978335135 (já instalado): não são erro — reexecutar o
# script tem de ser seguro.
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189 -and $LASTEXITCODE -ne -1978335135) {
    throw "winget install JRSoftware.InnoSetup falhou ($LASTEXITCODE)."
}
$iscc = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'ISCC.exe não encontrado em Program Files após a instalação do Inno Setup.' }
Write-Host "pwsh: $pwshMaquina"
Write-Host "ISCC: $iscc"

# ---- 2. Caminhos longos ----
Write-Etapa 'LongPathsEnabled e core.longpaths (--system)'
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1 -Type DWord
& git config --system core.longpaths true
if ($LASTEXITCODE -ne 0) { throw 'git config --system core.longpaths falhou.' }

# ---- 3. Caches de payload legíveis pela conta do serviço ----
Write-Etapa "Permissão de leitura nos caches para $contaServico"
foreach ($pasta in $PayloadDir, $WebView2PayloadDir) {
    if (-not (Test-Path $pasta)) { Write-Warning "Cache ausente, pulando: $pasta"; continue }
    & icacls $pasta /grant "*S-1-5-20:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls falhou em $pasta." }
    Write-Host "OK  $pasta"
}

# ---- 4. Registro do runner como serviço ----
Write-Etapa "Runner $RunnerName em $RunnerDir"
if (Test-Path (Join-Path $RunnerDir '.runner')) {
    Write-Host 'Runner já registrado nesta pasta — nada a fazer (para refazer: config.cmd remove).'
}
else {
    $token = & gh api -X POST "repos/$Repositorio/actions/runners/registration-token" --jq .token
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw "Não consegui o token de registro (gh auth status; admin em $Repositorio)." }

    Push-Location $RunnerDir
    try {
        # --unattended aceita a conta padrão do serviço (NETWORK SERVICE); --work curto pela armadilha c.
        & .\config.cmd --unattended --url "https://github.com/$Repositorio" --token $token `
            --name $RunnerName --labels instaladores --work _work --runasservice --replace
        if ($LASTEXITCODE -ne 0) { throw "config.cmd falhou ($LASTEXITCODE)." }
    }
    finally {
        Pop-Location
        $token = $null
    }
}

Get-Service 'actions.runner.*' | Format-Table Name, Status, StartType -AutoSize
Write-Host "`nPronto. Confira o runner Idle em https://github.com/$Repositorio/settings/actions/runners" -ForegroundColor Green
