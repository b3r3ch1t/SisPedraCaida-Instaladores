<#
.SYNOPSIS
    Confere se uma máquina Windows está pronta para empacotar os instaladores do CI de prod.

.DESCRIPTION
    Pré-requisitos do runner `[self-hosted, windows, instaladores]` (PRD-INSTPROD-01), conferidos um
    a um e com a correção ao lado. Roda em dois lugares:
      - no workflow `runner-windows-diagnostico.yml`, já como o usuário do serviço do runner — que é
        o que importa: o Inno instalado "por usuário" por quem preparou a máquina não existe para a
        conta do serviço;
      - direto na máquina, ANTES de registrar o runner, para não descobrir a falta no primeiro release.

    Saída: uma linha por verificação (OK / AVISO / FALHA) e, no Actions, a mesma tabela no resumo do
    job. Qualquer FALHA sai com código 1.

    ⚠️ A verificação de caminho é a que mais importa e a menos óbvia: o worktree de cada instalador
    materializa o repositório inteiro sob o diretório base, e o MSBuild segue preso a 260 caracteres
    mesmo com `LongPathsEnabled` — com base longa o `dotnet publish` morre com
    `MSB3030 … apphost.exe … not found` (reproduzido em 18/10/2026, PRD-INSTPROD-04).

.PARAMETER BaseDir
    Diretório sob o qual os worktrees serão criados. Padrão: `$env:RUNNER_TEMP` (no Actions) ou, fora
    dele, `C:\actions-runner\_work\_temp` — o caminho do runner recomendado no runbook.

.PARAMETER PayloadDir
    Cache do instalador do QZ Tray. Padrão: `$env:PRINTMONITOR_PAYLOAD_DIR`.

.PARAMETER WebView2PayloadDir
    Cache do bootstrapper do WebView2 Runtime do totem (`MicrosoftEdgeWebview2Setup.exe` +
    `webview2.sha256`). Padrão: `$env:TOTEM_WEBVIEW2_PAYLOAD_DIR` (PRD-TOTEMINST-02).

    Os dois parâmetros de pasta são só overrides: a LISTA de payloads conferidos vem do manifesto
    (`installer/instaladores-ci.json`, campo `payloads`), e cada um é lido da variável declarada lá.

.PARAMETER BackendRoot
    Checkout do SisPedraCaida-Backend (SDK do `global.json` e projetos de `src/`). Padrão: a mesma
    descoberta dos `build-installer.ps1` (`SISPEDRACAIDA_BACKEND`, `backend/`, repositório irmão).

.PARAMETER ExigirPayload
    Payload ausente vira FALHA (no CI todo payload do manifesto é obrigatório). Sem o switch, vira
    AVISO — útil para conferir a máquina antes de montar os caches, ou quando só se vai empacotar o
    agente TEF, que não tem payload.

.EXAMPLE
    pwsh scripts/runner-windows-diagnostico.ps1 -PayloadDir C:\ci-cache\printmonitor-payload

.EXAMPLE
    pwsh scripts/runner-windows-diagnostico.ps1 -BaseDir D:\r\_work\_temp -ExigirPayload
#>
[CmdletBinding()]
param(
    [string] $BaseDir = '',
    [string] $PayloadDir = '',
    [string] $WebView2PayloadDir = '',
    [switch] $ExigirPayload,
    [string] $BackendRoot = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path (Join-Path $repoRoot 'installer') (Join-Path 'common' 'Empacotamento.psm1')) -Force

# O SDK exigido (global.json) e os projetos de src/ são do BACKEND, que o workflow de diagnóstico
# clona em `backend/`; o manifesto e o módulo de empacotamento são deste repositório.
$backendRoot = Resolve-RaizDoBackend -RepoRoot $repoRoot -BackendRoot $BackendRoot

if (-not $BaseDir) {
    $BaseDir = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { 'C:\actions-runner\_work\_temp' }
}

# Overrides de linha de comando, pela variável que o manifesto declara para cada cache. Sem override, a
# pasta vem da própria variável de ambiente (no Actions, do `env:` do workflow).
$overridesDePayload = @{
    'PRINTMONITOR_PAYLOAD_DIR'   = $PayloadDir
    'TOTEM_WEBVIEW2_PAYLOAD_DIR' = $WebView2PayloadDir
}

# Limite do MSBuild/Win32 sem prefixo \\?\: 260 com o terminador, ou seja, 259 caracteres úteis.
$limiteCaminho = 259

$resultados = New-Object System.Collections.Generic.List[object]

<#
.SYNOPSIS
    Registra o resultado de uma verificação.
.PARAMETER Item
    O que foi conferido.
.PARAMETER Estado
    OK, AVISO ou FALHA.
.PARAMETER Detalhe
    O valor encontrado e, na falha, como corrigir.
#>
function Add-Resultado {
    param([string] $Item, [ValidateSet('OK', 'AVISO', 'FALHA')] [string] $Estado, [string] $Detalhe)
    $resultados.Add([pscustomobject]@{ Item = $Item; Estado = $Estado; Detalhe = $Detalhe })
}

<#
.SYNOPSIS
    Roda um executável e devolve a primeira linha da saída, ou $null se ele não existir/falhar.
#>
function Get-PrimeiraLinha {
    param([string] $Exe, [string[]] $Argumentos)
    try {
        $saida = & $Exe @Argumentos 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (($saida | Select-Object -First 1) -as [string]).Trim()
    }
    catch {
        return $null
    }
}

# ---------- sistema ----------

$ehWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if ($ehWindows -and [System.Environment]::Is64BitOperatingSystem) {
    Add-Resultado 'Sistema operacional' 'OK' ([System.Environment]::OSVersion.VersionString)
}
else {
    Add-Resultado 'Sistema operacional' 'FALHA' 'Exige Windows x64: o ISCC e os executáveis net10.0-windows só existem lá.'
}

$identidade = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$ehAdmin = (New-Object System.Security.Principal.WindowsPrincipal $identidade).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Resultado 'Conta em execução' $(if ($ehAdmin -and $env:GITHUB_ACTIONS) { 'AVISO' } else { 'OK' }) (
    "$($identidade.Name)" + $(if ($ehAdmin -and $env:GITHUB_ACTIONS) { ' — administrador: empacotar não precisa de elevação; prefira NETWORK SERVICE.' } else { '' }))

$longPaths = $null
try {
    $longPaths = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled
}
catch { }
if ($longPaths -eq 1) {
    Add-Resultado 'LongPathsEnabled' 'OK' '1'
}
else {
    # AVISO, não FALHA: com o runner num diretório curto o empacotamento passa sem ele (o limite que
    # reprova é o do MSBuild, conferido abaixo). Ele protege a limpeza de worktree por Remove-Item,
    # que percorre os PRDs de caminho comprido.
    Add-Resultado 'LongPathsEnabled' 'AVISO' ("valor '$longPaths'. Corrija (admin): Set-ItemProperty " +
        "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1 -Type DWord")
}

# ---------- ferramentas ----------

$versaoPwsh = $PSVersionTable.PSVersion
$pwshExe = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshExe) {
    Add-Resultado 'PowerShell 7 (pwsh)' 'OK' ((Get-PrimeiraLinha 'pwsh' @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')) + " ($($pwshExe.Source))")
}
else {
    Add-Resultado 'PowerShell 7 (pwsh)' 'FALHA' "ausente (esta sessão: $versaoPwsh). MSI da release oficial (PowerShell-X.Y.Z-win-x64.msi) ou scripts\preparar-runner-windows.ps1 — NÃO o winget de máquina (MSIX; armadilha r)"
}

# O SDK é resolvido pelo global.json do repositório: rodar na raiz é o que prova que a versão
# exigida está instalada, e não só "algum dotnet".
Push-Location $backendRoot
try {
    $sdk = Get-PrimeiraLinha 'dotnet' @('--version')
}
finally {
    Pop-Location
}
if ($sdk) {
    Add-Resultado '.NET SDK (global.json)' 'OK' $sdk
}
else {
    $exigido = ''
    try { $exigido = (Get-Content (Join-Path $backendRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version } catch { }
    Add-Resultado '.NET SDK (global.json)' 'FALHA' "nenhum SDK compatível com $exigido. winget install --id Microsoft.DotNet.SDK.10 --scope machine"
}

$git = Get-PrimeiraLinha 'git' @('--version')
if ($git) {
    Add-Resultado 'Git' 'OK' $git
    # Arquivo de configuração, não o valor efetivo: no Actions o GIT_CONFIG_* do job deixaria o efetivo
    # sempre `true` e o aviso cego. `--system` é o que o runbook (§3) e o preparar-runner-windows.ps1
    # gravam — vale para a conta do serviço; `--global` só se gravado COMO ela.
    $longGit = Get-PrimeiraLinha 'git' @('config', '--system', '--get', 'core.longpaths')
    $escopo = 'system'
    if ($longGit -ne 'true') {
        $longGit = Get-PrimeiraLinha 'git' @('config', '--global', '--get', 'core.longpaths')
        $escopo = 'global'
    }
    if ($longGit -eq 'true') {
        Add-Resultado 'git core.longpaths' 'OK' "true ($escopo)"
    }
    else {
        # O job de empacotamento liga por GIT_CONFIG_*, mas o actions/checkout roda antes dele.
        Add-Resultado 'git core.longpaths' 'AVISO' "'$longGit' — git config --system core.longpaths true (como administrador)"
    }
}
else {
    Add-Resultado 'Git' 'FALHA' 'ausente. winget install --id Git.Git --scope machine'
}

# O job `empacotar` anexa o pacote à release com `gh release upload` direto do runner (sem artifact do
# Actions, que esgota a cota da conta) — sem o gh no PATH da máquina o pacote sai e não é publicado.
$gh = Get-PrimeiraLinha 'gh' @('--version')
if ($gh) {
    Add-Resultado 'GitHub CLI (gh)' 'OK' $gh
}
else {
    Add-Resultado 'GitHub CLI (gh)' 'FALHA' 'ausente. winget install --id GitHub.cli --scope machine'
}

try {
    $iscc = Resolve-IsccExecutavel
    # O ISCC.exe não carrega versão no VersionInfo (sai 0.0.0.0): a única fonte é o cabeçalho que ele
    # imprime ("Inno Setup 6 Command-Line Compiler"). /? sai com código ≠ 0, então não há checagem dele.
    # `Continue` só nesta chamada: o uso vai para o stderr, e no Windows PowerShell 5.1 com `Stop` o
    # stderr de executável nativo vira exceção — o catch abaixo reportaria "não encontrado" com o ISCC
    # instalado (reproduzido em 27/10/2026; mesma causa da armadilha g).
    $eapAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $saidaIscc = & $iscc '/?' 2>&1 }
    finally { $ErrorActionPreference = $eapAnterior }
    $cabecalho = ($saidaIscc | Select-Object -First 1) -as [string]
    $versaoIscc = ([string]$cabecalho).Trim()
    $majorIscc = 0
    if ($versaoIscc -match 'Inno Setup (\d+)') { $majorIscc = [int]$Matches[1] }
    $idioma = Join-Path (Split-Path $iscc -Parent) 'Languages\BrazilianPortuguese.isl'
    if ($majorIscc -ne 6) {
        Add-Resultado 'Inno Setup (ISCC)' 'FALHA' "$iscc versão $versaoIscc — os .iss exigem o Inno Setup 6."
    }
    elseif (-not (Test-Path $idioma)) {
        Add-Resultado 'Inno Setup (ISCC)' 'FALHA' "$iscc sem Languages\BrazilianPortuguese.isl (os .iss usam pt-BR). Reinstale com os idiomas."
    }
    else {
        # A versão completa só existe na entrada de desinstalação (o cabeçalho diz apenas "6"), e o
        # instalador do TEF exige 6.1+ (CreateDownloadPage/DownloadTemporaryFile do pré-requisito do HUB).
        $pastaIscc = (Split-Path $iscc -Parent).TrimEnd('\')
        $completa = $null
        foreach ($chave in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1')) {
            $entrada = Get-ItemProperty -Path $chave -ErrorAction SilentlyContinue
            if ($entrada -and ([string]$entrada.InstallLocation).TrimEnd('\') -eq $pastaIscc) {
                $completa = [string]$entrada.DisplayVersion
                break
            }
        }
        $versaoNum = $null
        if ($completa -and [version]::TryParse($completa, [ref]$versaoNum) -and $versaoNum -lt [version]'6.1') {
            Add-Resultado 'Inno Setup (ISCC)' 'FALHA' "$completa ($iscc) — o instalador do TEF exige 6.1+. winget upgrade --id JRSoftware.InnoSetup --scope machine"
        }
        elseif ($completa) {
            Add-Resultado 'Inno Setup (ISCC)' 'OK' "$completa ($iscc)"
        }
        else {
            Add-Resultado 'Inno Setup (ISCC)' 'AVISO' "$versaoIscc ($iscc) — versão completa não confirmada (sem entrada de desinstalação); o TEF exige 6.1+."
        }
    }
}
catch {
    # Causa nº 1 aqui: o Inno foi instalado POR USUÁRIO (padrão do winget) por quem preparou a máquina,
    # e a conta do serviço do runner não enxerga o %LOCALAPPDATA% de outra pessoa.
    Add-Resultado 'Inno Setup (ISCC)' 'FALHA' ("não encontrado para $($identidade.Name). " +
        'winget install --id JRSoftware.InnoSetup --scope machine')
}

$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($pester) {
    Add-Resultado 'Pester' 'OK' "$($pester.Version) — roda os testes do Empacotamento.psm1 antes de empacotar"
}
else {
    Add-Resultado 'Pester' 'FALHA' 'ausente (o Windows traz o 3.4 em C:\Program Files\WindowsPowerShell\Modules — foi removido?).'
}

# ---------- caminho dos worktrees ----------

$manifesto = Get-Content (Join-Path (Join-Path $repoRoot 'installer') 'instaladores-ci.json') -Raw | ConvertFrom-Json
$maiorServico = ($manifesto.instaladores | ForEach-Object { $_.servico.Length } | Measure-Object -Maximum).Maximum
$projetos = @(Get-ChildItem -Path (Join-Path $backendRoot 'src') -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName "$($_.Name).csproj")
    })
$maiorProjeto = ($projetos | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum

# Pior caso do MSBuild dentro do worktree do workflow (`<base>\<servico>-<sha7>\wt\...`): o assembly
# de referência intermediário do projeto de nome mais longo, que é o caminho mais fundo do obj/.
$piorCaso = $BaseDir.TrimEnd('\') + '\' + ('x' * $maiorServico) + '-0000000\wt\src\' + ('x' * $maiorProjeto) +
    '\obj\Release\net10.0-windows\win-x64\refint\' + ('x' * $maiorProjeto) + '.dll'
$folga = $limiteCaminho - $piorCaso.Length
if ($folga -ge 20) {
    Add-Resultado 'Caminho dos worktrees' 'OK' "base '$BaseDir': pior caso $($piorCaso.Length) de $limiteCaminho caracteres (folga $folga)."
}
elseif ($folga -ge 0) {
    Add-Resultado 'Caminho dos worktrees' 'AVISO' ("base '$BaseDir': pior caso $($piorCaso.Length) de $limiteCaminho — " +
        "folga de só $folga; um projeto de nome maior estoura. Use um diretório de runner mais curto.")
}
else {
    Add-Resultado 'Caminho dos worktrees' 'FALHA' ("base '$BaseDir': pior caso $($piorCaso.Length) > $limiteCaminho. " +
        'O dotnet publish falharia com MSB3030. Reinstale o runner num diretório curto (ex.: C:\actions-runner).')
}

# ---------- payloads de terceiros ----------

# A lista vem do MANIFESTO (`payloads` de cada linha, PRD-TOTEMINST-02), a mesma que o job `empacotar`
# itera: payload novo é conferido aqui sem mexer neste script. Até 22/10/2026 o diagnóstico conferia só
# o QZ Tray, e máquina "pronta" aqui ainda reprovava o PrintMonitorSetup lá (PRD-INSTDEV-04); até
# 27/10/2026 conhecia os dois do PrintMonitor por nome, e o WebView2 do totem ficaria de fora.
$estadoSemPayload = if ($ExigirPayload) { 'FALHA' } else { 'AVISO' }

foreach ($instalador in $manifesto.instaladores) {
    foreach ($p in @($instalador.payloads)) {
        if (-not $p) { continue }

        $pasta = [string]$overridesDePayload[[string]$p.variavel]
        if (-not $pasta) { $pasta = [string][Environment]::GetEnvironmentVariable([string]$p.variavel) }

        $r = Test-PayloadDoRunner -PayloadDir $pasta -ArquivoHash $p.hash `
            -Descricao $p.descricao -Variavel $p.variavel `
            -EstadoSeAusente $estadoSemPayload -EfeitoSeAusente $p.seAusente
        Add-Resultado "Payload ($($instalador.servico))" $r.Estado "$($p.descricao): $($r.Detalhe)"
    }
}

# ---------- saída ----------

Write-Host ''
Write-Host 'Runner Windows dos instaladores — diagnóstico' -ForegroundColor Cyan
foreach ($r in $resultados) {
    $cor = switch ($r.Estado) { 'OK' { 'Green' } 'AVISO' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0,-5}] {1,-28} {2}' -f $r.Estado, $r.Item, $r.Detalhe) -ForegroundColor $cor
}

if ($env:GITHUB_STEP_SUMMARY) {
    $linhas = @('## Runner Windows dos instaladores', '', '| Estado | Verificação | Detalhe |', '|---|---|---|')
    $linhas += $resultados | ForEach-Object { "| $($_.Estado) | $($_.Item) | $($_.Detalhe -replace '\|', '/') |" }
    ($linhas -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

$falhas = @($resultados | Where-Object Estado -eq 'FALHA').Count
Write-Host ''
if ($falhas -gt 0) {
    Write-Host "$falhas verificação(ões) com FALHA — o runner NÃO está pronto." -ForegroundColor Red
    exit 1
}

Write-Host 'Runner pronto para empacotar os instaladores.' -ForegroundColor Green
exit 0
