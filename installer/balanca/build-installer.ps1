<#
.SYNOPSIS
    Gera o instalador Windows do agente da balança (BalancaAgentSetup-<versão>.exe).

.DESCRIPTION
    Um comando, do repositório limpo ao .exe distribuível — sem licença paga em nenhum ponto da
    cadeia (Inno Setup 6 é gratuito inclusive para uso comercial; o SDK .NET é MIT).

    Mesmo contrato dos instaladores do agente TEF e do PrintMonitor (PRD-INSTPROD-02/03), com a
    lógica comum em `installer/common/Empacotamento.psm1`:
      1. resolve a FONTE: por padrão um worktree pinado em `origin/prod` — `.iss`, publicador e
         projeto saem do mesmo commit;
      2. publica o layout self-contained chamando `scripts/balanca-publish.ps1 -SkipZip` da fonte;
      3. compila `BalancaAgent.iss` com o ISCC, injetando versão e diretório publicado por /D;
      4. grava o SHA-256 do instalador em `<instalador>.sha256`.

    Sem payload de terceiro e sem `Setup.exe`: o próprio .iss registra o serviço (ver cabeçalho dele).

.PARAMETER Version
    Versão a estampar. Padrão: a lida de Directory.Build.props da fonte.

.PARAMETER Configuration
    Configuração de build do agente. Padrão: Release.

.PARAMETER IsccPath
    Caminho do ISCC.exe. Padrão: descoberto em Program Files e em %LOCALAPPDATA%.

.PARAMETER Ref
    Referência git que origina o pacote. Padrão: **prod**. Aceita branch, `origin/<branch>`, tag ou SHA.

.PARAMETER BackendRoot
    Checkout do SisPedraCaida-Backend de onde o código do agente é pinado (`-Ref` resolve NELE). Padrão:
    `$env:SISPEDRACAIDA_BACKEND`, depois `backend/` (checkout do CI) e por fim o repositório irmão
    `../SisPedraCaida-Backend` do workspace.

.PARAMETER UseWorkingTree
    Empacota a árvore de trabalho atual DO BACKEND. Modo de desenvolvimento: **nunca** para pacote de campo.

.PARAMETER SkipFetch
    Não busca a referência no remoto antes de empacotar.

.PARAMETER WorktreeDir
    Worktree da fonte pinada. Padrão: `<workspace>/.worktrees/balanca-pacote`.

.PARAMETER PublishDir
    Onde o layout self-contained é publicado. Padrão: `artifacts/balanca`.

.PARAMETER OutputDir
    Onde o instalador e o `.sha256` são gravados. Padrão: `artifacts/installer`.

.PARAMETER RemoveWorktree
    Remove o worktree ao final, com sucesso ou falha (CI).

.PARAMETER SkipPublish
    Reaproveita o layout já publicado em -PublishDir (iteração rápida no .iss).

.PARAMETER DryRun
    Valida a cadeia (ISCC e layout publicado) sem compilar o instalador.

.EXAMPLE
    pwsh installer/balanca/build-installer.ps1

.EXAMPLE
    pwsh installer/balanca/build-installer.ps1 -UseWorkingTree -SkipPublish -DryRun

.EXAMPLE
    # Modo CI: SHA exato, versão da tag, diretórios próprios, worktree descartado no fim.
    pwsh installer/balanca/build-installer.ps1 -Ref <sha> -Version 2.6.0 -SkipFetch -RemoveWorktree `
        -WorktreeDir $env:RUNNER_TEMP/wt-balanca -PublishDir $env:RUNNER_TEMP/pub-balanca `
        -OutputDir $env:RUNNER_TEMP/out-balanca
#>
[CmdletBinding()]
param(
    [string] $Version = '',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [string] $IsccPath = '',
    [string] $Ref = 'prod',
    [string] $BackendRoot = '',
    [string] $WorktreeDir = '',
    [string] $PublishDir = '',
    [string] $OutputDir = '',
    [switch] $UseWorkingTree,
    [switch] $SkipFetch,
    [switch] $SkipPublish,
    [switch] $RemoveWorktree,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = [string](Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'common' 'Empacotamento.psm1')) -Force

# O código dos agentes vem do checkout do BACKEND (repositório irmão no workspace, ou `backend/` no
# CI); o `.iss` e os includes vêm DESTE repositório (SisPedraCaida-Instaladores).
$backendRoot = Resolve-RaizDoBackend -RepoRoot $repoRoot -BackendRoot $BackendRoot

# Defaults resolvidos no corpo, não no param(): no Windows PowerShell 5.1 o $PSScriptRoot pode chegar
# VAZIO à avaliação do default do parâmetro, e o Join-Path recusa string vazia.
if (-not $PublishDir) { $PublishDir = Join-Path (Join-Path $repoRoot 'artifacts') 'balanca' }
if (-not $OutputDir) { $OutputDir = Join-Path (Join-Path $repoRoot 'artifacts') 'installer' }
if (-not $WorktreeDir) { $WorktreeDir = Join-Path (Join-Path (Split-Path $repoRoot -Parent) '.worktrees') 'balanca-pacote' }

# Cadeia que a fonte pinada (backend) precisa ter: `.iss`, publicador e o projeto do agente.
$exigidos = @(
    'scripts/balanca-publish.ps1',
    'src/SisPedraCaida.Balanca.Agent/SisPedraCaida.Balanca.Agent.csproj'
)

# Cadeia que ESTE repositório precisa ter: o `.iss` e os includes saíram do backend.
$exigidosLocais = @(
    'installer/balanca/BalancaAgent.iss'
)

Write-Host 'Agente da balanca - instalador Windows' -ForegroundColor Cyan

try {
    $iscc = Resolve-IsccExecutavel -IsccPath $IsccPath
    Write-Host "  ISCC: $iscc" -ForegroundColor DarkGray

    Assert-FonteCompleta -Fonte $repoRoot -Descricao 'O checkout do SisPedraCaida-Instaladores' `
        -Agente 'agente da balanca' -Exigidos $exigidosLocais

    $origem = Resolve-FonteDoPacote -RepoRoot $backendRoot -Ref $Ref -WorktreeDir $WorktreeDir `
        -UseWorkingTree:$UseWorkingTree -SkipFetch:$SkipFetch
    $fonte = $origem.Caminho
    Assert-FonteCompleta -Fonte $fonte -Descricao $origem.Descricao -Agente 'agente da balanca' -Exigidos $exigidos

    $versaoResolvida = Resolve-VersaoDoPacote -Fonte $fonte -Version $Version
    Write-Host "  versao: $versaoResolvida" -ForegroundColor DarkGray

    if (-not $SkipPublish) {
        Write-Host '  publicando o layout self-contained do agente...' -ForegroundColor DarkGray
        & (Join-Path (Join-Path $fonte 'scripts') 'balanca-publish.ps1') `
            -OutputPath $PublishDir -Version $versaoResolvida -Configuration $Configuration -SkipZip
        if ($LASTEXITCODE -ne 0) { throw "Falha ao publicar o layout do agente (codigo $LASTEXITCODE)." }
    }

    if (-not (Test-Path (Join-Path $PublishDir 'SisPedraCaida.Balanca.Agent.exe'))) {
        throw 'Layout publicado sem o SisPedraCaida.Balanca.Agent.exe. Rode sem -SkipPublish.'
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry-run: cadeia validada (ISCC e layout publicado). Nada foi compilado.' -ForegroundColor Green
        return
    }

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $argumentos = @(
        "/DAppVersion=$versaoResolvida",
        "/DPublishDir=$PublishDir",
        "/O$OutputDir",
        (Join-Path $PSScriptRoot 'BalancaAgent.iss')
    )

    Write-Host '  compilando o instalador...' -ForegroundColor DarkGray
    & $iscc @argumentos
    if ($LASTEXITCODE -ne 0) { throw "ISCC falhou (codigo $LASTEXITCODE)." }

    $instalador = Join-Path $OutputDir "BalancaAgentSetup-$versaoResolvida.exe"
    if (-not (Test-Path $instalador)) { throw "ISCC terminou sem produzir $instalador." }

    $shaInstalador = Write-ArquivoSha256 -Arquivo $instalador

    Write-Host ''
    Write-Host "Instalador: $instalador" -ForegroundColor Green
    Write-Host "SHA-256:    $shaInstalador  (gravado em $(Split-Path $instalador -Leaf).sha256)" -ForegroundColor Green
    if ($origem.Commit) {
        Write-Host "Origem:     $($origem.Descricao)" -ForegroundColor Green
        Write-Host "            $($origem.Commit)" -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Origem:     arvore de trabalho (-UseWorkingTree) - NAO distribuir em campo' -ForegroundColor Yellow
    }
    Write-Host "Scripts:    SisPedraCaida-Instaladores @ $(Get-ProcedenciaDosScripts -RepoRoot $repoRoot)" -ForegroundColor Green
}
finally {
    if ($RemoveWorktree -and -not $UseWorkingTree) {
        Remove-WorktreeDoPacote -RepoRoot $backendRoot -WorktreeDir $WorktreeDir
    }
}
