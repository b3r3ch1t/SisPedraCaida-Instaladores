<#
.SYNOPSIS
    Gera o instalador Windows do Migrador Galileu (MigracaoGalileuSetup-<versão>.exe).

.DESCRIPTION
    Mesmo molde do installer/tefagent/build-installer.ps1 (PRD-MGGINST-01):

      1. pina o backend num worktree (-Ref, padrão prod) e publica o layout self-contained single-file
         chamando o `scripts/migracao-galileu-publish.ps1 -SkipZip` DELE — o layout publicado é o
         contrato de entrada do [Files]; replicar o `dotnet publish` aqui criaria dois publicadores;
      2. compila `MigracaoGalileu.iss` (DESTE repositório) com o ISCC, injetando versão e layout por /D;
      3. grava e imprime o SHA-256 do instalador, com a procedência dos dois repositórios.

    Sem payload de terceiro: o migrador fala com o MariaDB e o PostgreSQL pelos drivers .NET que o
    publish embute no próprio .exe.

    ⚠️ Enquanto o b3r3ch1t/SisPedraCaida-Backend#1396 não chegar à `prod` do backend, o padrão `-Ref prod`
    não tem o migrador e o script para em "Fonte incompleta". Use `-Ref origin/feat/migracao-galileu`
    (ou o SHA) — e, depois de mesclado, `-Ref origin/dev`.

.PARAMETER Version
    Versão a estampar. Padrão: a lida de Directory.Build.props do backend pinado.

.PARAMETER Configuration
    Configuração de build do app. Padrão: Release.

.PARAMETER IsccPath
    Caminho do ISCC.exe. Padrão: descoberto em Program Files e em %LOCALAPPDATA%.

.PARAMETER SkipPublish
    Reaproveita o layout já publicado em artifacts/migracao-galileu (iteração rápida no .iss).

.PARAMETER DryRun
    Valida a cadeia (ISCC presente e layout publicado) sem compilar o instalador.

.PARAMETER Ref
    Referência git do BACKEND que origina o pacote. Padrão: prod. Aceita branch local,
    `origin/<branch>`, tag ou SHA.

.PARAMETER BackendRoot
    Checkout do SisPedraCaida-Backend. Padrão: `$env:SISPEDRACAIDA_BACKEND`, `backend/` (CI) e por fim
    `../SisPedraCaida-Backend` do workspace.

.PARAMETER UseWorkingTree
    Empacota a árvore de trabalho atual do backend. Só desenvolvimento: o .exe sai sem procedência.

.PARAMETER SkipFetch
    Não busca a referência no remoto antes de empacotar.

.PARAMETER WorktreeDir
    Worktree da fonte pinada. Padrão: `<workspace>/.worktrees/migracao-galileu-pacote`.

.PARAMETER PublishDir
    Onde o layout é publicado. Padrão: `artifacts/migracao-galileu`.

.PARAMETER OutputDir
    Onde o instalador e o `.sha256` são gravados. Padrão: `artifacts/installer`.

.PARAMETER RemoveWorktree
    Remove o worktree ao final, com sucesso ou falha (CI).

.EXAMPLE
    pwsh installer/migracao-galileu/build-installer.ps1 -Ref origin/feat/migracao-galileu

.EXAMPLE
    pwsh installer/migracao-galileu/build-installer.ps1 -UseWorkingTree -SkipPublish -DryRun
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

$backendRoot = Resolve-RaizDoBackend -RepoRoot $repoRoot -BackendRoot $BackendRoot

# Defaults resolvidos no corpo, não no param(): no Windows PowerShell 5.1 o $PSScriptRoot pode chegar
# VAZIO à avaliação do default do parâmetro.
if (-not $PublishDir) { $PublishDir = Join-Path (Join-Path $repoRoot 'artifacts') 'migracao-galileu' }
if (-not $OutputDir) { $OutputDir = Join-Path (Join-Path $repoRoot 'artifacts') 'installer' }
if (-not $WorktreeDir) { $WorktreeDir = Join-Path (Join-Path (Split-Path $repoRoot -Parent) '.worktrees') 'migracao-galileu-pacote' }

# Nome do projeto = nome do .exe publicado (o publish não troca o AssemblyName). Guarda
# MigracaoGalileuInnoGuardTests confere este nome contra o .iss e o backend.
$projeto = 'SisPedraCaida.Tools.MigracaoGalileu.App'

# Cadeia que a fonte pinada (backend) precisa ter: o publicador e os dois projetos (casca + núcleo).
$exigidos = @(
    'scripts/migracao-galileu-publish.ps1',
    "src/$projeto/$projeto.csproj",
    'src/SisPedraCaida.Tools.MigracaoGalileu.Core/SisPedraCaida.Tools.MigracaoGalileu.Core.csproj'
)

$exigidosLocais = @(
    'installer/migracao-galileu/MigracaoGalileu.iss'
)

Write-Host 'Migrador Galileu - instalador Windows' -ForegroundColor Cyan

try {
    $iscc = Resolve-IsccExecutavel -IsccPath $IsccPath
    Write-Host "  ISCC: $iscc" -ForegroundColor DarkGray

    Assert-FonteCompleta -Fonte $repoRoot -Descricao 'O checkout do SisPedraCaida-Instaladores' `
        -Agente 'Migrador Galileu' -Exigidos $exigidosLocais

    $origem = Resolve-FonteDoPacote -RepoRoot $backendRoot -Ref $Ref -WorktreeDir $WorktreeDir `
        -UseWorkingTree:$UseWorkingTree -SkipFetch:$SkipFetch
    $fonte = $origem.Caminho
    Assert-FonteCompleta -Fonte $fonte -Descricao $origem.Descricao -Agente 'Migrador Galileu' -Exigidos $exigidos

    $versaoResolvida = Resolve-VersaoDoPacote -Fonte $fonte -Version $Version
    Write-Host "  versao: $versaoResolvida" -ForegroundColor DarkGray

    if (-not $SkipPublish) {
        Write-Host '  publicando o layout self-contained do migrador...' -ForegroundColor DarkGray
        & (Join-Path (Join-Path $fonte 'scripts') 'migracao-galileu-publish.ps1') `
            -OutputPath $PublishDir -Version $versaoResolvida -Configuration $Configuration -SkipZip
        if ($LASTEXITCODE -ne 0) { throw "Falha ao publicar o layout do migrador (codigo $LASTEXITCODE)." }
    }

    if (-not (Test-Path (Join-Path $PublishDir "$projeto.exe"))) {
        throw "Layout publicado sem o $projeto.exe. Rode sem -SkipPublish."
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
        (Join-Path $PSScriptRoot 'MigracaoGalileu.iss')
    )

    Write-Host '  compilando o instalador...' -ForegroundColor DarkGray
    & $iscc @argumentos
    if ($LASTEXITCODE -ne 0) { throw "ISCC falhou (codigo $LASTEXITCODE)." }

    $instalador = Join-Path $OutputDir "MigracaoGalileuSetup-$versaoResolvida.exe"
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
        Write-Host 'Origem:     arvore de trabalho (-UseWorkingTree) - NAO distribuir' -ForegroundColor Yellow
    }
    Write-Host "Scripts:    SisPedraCaida-Instaladores @ $(Get-ProcedenciaDosScripts -RepoRoot $repoRoot)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Publique o SHA-256 ao lado do artefato: o pacote nao e assinado por CA publica, e o hash' -ForegroundColor Yellow
    Write-Host 'e a unica prova de integridade que o time tecnico tem antes de instalar.' -ForegroundColor Yellow
}
finally {
    if ($RemoveWorktree -and -not $UseWorkingTree) {
        Remove-WorktreeDoPacote -RepoRoot $backendRoot -WorktreeDir $WorktreeDir
    }
}
