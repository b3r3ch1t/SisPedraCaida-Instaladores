<#
.SYNOPSIS
    Gera o instalador Windows do agente TEF (TefAgentSetup-<versão>.exe).

.DESCRIPTION
    Um comando, do repositório limpo ao .exe distribuível — e sem licença paga em nenhum ponto da
    cadeia (Inno Setup 6 é gratuito inclusive para uso comercial; o SDK .NET é MIT).

    Sequência:
      1. publica o layout self-contained chamando `scripts/tefagent-publish.ps1 -SkipZip` — o
         layout publicado é o CONTRATO de entrada da seção [Files]. Copiar binário à mão produziria
         dois empacotadores e um deles desatualizado;
      2. compila `TefAgent.iss` com o ISCC, injetando versão e diretório publicado por /D;
      3. imprime o SHA-256 do instalador, que é publicado ao lado do artefato — o pacote não é
         assinado por CA pública (decisão D6 do PRD-TEFINST-00), e o hash é a única prova de
         integridade que a TI tem antes de instalar.

    Diferente do instalador do PrintMonitor, aqui NÃO há payload de terceiro: o Elgin TEF Web é
    licenciado e instalado pelo técnico da Elgin, não redistribuído por nós.

.PARAMETER Version
    Versão a estampar. Padrão: a lida de Directory.Build.props (fonte única para agente e instalador).

.PARAMETER Configuration
    Configuração de build do agente. Padrão: Release.

.PARAMETER IsccPath
    Caminho do ISCC.exe. Padrão: descoberto em Program Files e em %LOCALAPPDATA%.

.PARAMETER SkipPublish
    Reaproveita o layout já publicado em artifacts/tefagent (iteração rápida no .iss).

.PARAMETER DryRun
    Valida a cadeia (ISCC presente e layout publicado) sem compilar o instalador.

.PARAMETER Ref
    Referência git que origina o pacote. Padrão: **prod** — o instalador vai para o balcão do
    cliente, então ele nasce do código que está em produção, não do que está aberto no editor.
    Aceita branch local, `origin/<branch>`, tag ou SHA.

.PARAMETER BackendRoot
    Checkout do SisPedraCaida-Backend de onde o código do agente é pinado (`-Ref` resolve NELE). Padrão:
    `$env:SISPEDRACAIDA_BACKEND`, depois `backend/` (checkout do CI) e por fim o repositório irmão
    `../SisPedraCaida-Backend` do workspace.

.PARAMETER UseWorkingTree
    Empacota a árvore de trabalho atual DO BACKEND (comportamento anterior ao pino na `prod`). É o modo de
    desenvolvimento: valida o .iss sem precisar de commit. **Nunca** para pacote de campo — o .exe
    sai sem procedência rastreável, e o SHA-256 impresso não corresponde a nenhum commit.

.PARAMETER SkipFetch
    Não busca a referência no remoto antes de empacotar (máquina offline, ou pino num SHA já local).

.PARAMETER WorktreeDir
    Worktree em que a fonte pinada é materializada. Padrão: `<workspace>/.worktrees/tefagent-pacote`
    (reaproveitado entre execuções). O CI passa um diretório próprio por run
    (`$RUNNER_TEMP/wt-tefagent-<sha7>`): dois empacotamentos no mesmo worktree disputariam o checkout
    e o `bin/obj`.

.PARAMETER PublishDir
    Onde o layout self-contained é publicado. Padrão: `artifacts/tefagent`.

.PARAMETER OutputDir
    Onde o instalador e o `.sha256` são gravados. Padrão: `artifacts/installer`.

.PARAMETER RemoveWorktree
    Remove o worktree ao final, com sucesso ou falha (CI). Sem ele o worktree fica para a próxima
    execução, que o limpa antes de usar.

.EXAMPLE
    pwsh installer/tefagent/build-installer.ps1

.EXAMPLE
    pwsh installer/tefagent/build-installer.ps1 -UseWorkingTree -SkipPublish -DryRun

.EXAMPLE
    # Modo CI: SHA exato, versão da tag, diretórios próprios, worktree descartado no fim.
    pwsh installer/tefagent/build-installer.ps1 -Ref <sha> -Version 2.6.0 -SkipFetch -RemoveWorktree `
        -WorktreeDir $env:RUNNER_TEMP/wt-tefagent -PublishDir $env:RUNNER_TEMP/pub-tefagent `
        -OutputDir $env:RUNNER_TEMP/out-tefagent
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
if (-not $PublishDir) { $PublishDir = Join-Path (Join-Path $repoRoot 'artifacts') 'tefagent' }
if (-not $OutputDir) { $OutputDir = Join-Path (Join-Path $repoRoot 'artifacts') 'installer' }

# O worktree de empacotamento fica ao lado dos repositórios do workspace, em `.worktrees/` —
# nunca num caminho irmão fora dele, onde o git perde o estado do worktree entre sessões.
if (-not $WorktreeDir) { $WorktreeDir = Join-Path (Join-Path (Split-Path $repoRoot -Parent) '.worktrees') 'tefagent-pacote' }

# Cadeia que a fonte pinada (backend) precisa ter: `.iss`, publicador e os três projetos do terminal.
$exigidos = @(
    'scripts/tefagent-publish.ps1',
    'src/SisPedraCaida.Tef.Agent/SisPedraCaida.Tef.Agent.csproj',
    'src/SisPedraCaida.Tef.Agent.Setup/SisPedraCaida.Tef.Agent.Setup.csproj',
    'src/SisPedraCaida.Tef.Agent.Tray/SisPedraCaida.Tef.Agent.Tray.csproj'
)

# Cadeia que ESTE repositório precisa ter: o `.iss` e os includes saíram do backend.
$exigidosLocais = @(
    'installer/tefagent/TefAgent.iss'
)

Write-Host 'Agente TEF - instalador Windows' -ForegroundColor Cyan

try {
    $iscc = Resolve-IsccExecutavel -IsccPath $IsccPath
    Write-Host "  ISCC: $iscc" -ForegroundColor DarkGray

    Assert-FonteCompleta -Fonte $repoRoot -Descricao 'O checkout do SisPedraCaida-Instaladores' `
        -Agente 'agente TEF' -Exigidos $exigidosLocais

    $origem = Resolve-FonteDoPacote -RepoRoot $backendRoot -Ref $Ref -WorktreeDir $WorktreeDir `
        -UseWorkingTree:$UseWorkingTree -SkipFetch:$SkipFetch
    $fonte = $origem.Caminho
    Assert-FonteCompleta -Fonte $fonte -Descricao $origem.Descricao -Agente 'agente TEF' -Exigidos $exigidos

    $versaoResolvida = Resolve-VersaoDoPacote -Fonte $fonte -Version $Version
    Write-Host "  versao: $versaoResolvida" -ForegroundColor DarkGray

    if (-not $SkipPublish) {
        Write-Host '  publicando o layout self-contained do agente...' -ForegroundColor DarkGray
        & (Join-Path (Join-Path $fonte 'scripts') 'tefagent-publish.ps1') `
            -OutputPath $PublishDir -Version $versaoResolvida -Configuration $Configuration -SkipZip
        if ($LASTEXITCODE -ne 0) { throw "Falha ao publicar o layout do agente (codigo $LASTEXITCODE)." }
    }

    foreach ($exigido in @('SisPedraCaida.Tef.Agent.Setup.exe', 'SisPedraCaida.Tef.Agent.exe')) {
        if (-not (Test-Path (Join-Path $PublishDir $exigido))) {
            throw "Layout publicado sem o $exigido. Rode sem -SkipPublish."
        }
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
        # O .iss sai DESTE repositório (includes checks/pages/tefhub/provisioning relativos ao arquivo) e
        # os binários do commit pinado do backend: a procedência são os DOIS SHAs (Origem + Scripts).
        (Join-Path $PSScriptRoot 'TefAgent.iss')
    )

    Write-Host '  compilando o instalador...' -ForegroundColor DarkGray
    & $iscc @argumentos
    if ($LASTEXITCODE -ne 0) { throw "ISCC falhou (codigo $LASTEXITCODE)." }

    $instalador = Join-Path $OutputDir "TefAgentSetup-$versaoResolvida.exe"
    if (-not (Test-Path $instalador)) { throw "ISCC terminou sem produzir $instalador." }

    $shaInstalador = Write-ArquivoSha256 -Arquivo $instalador

    Write-Host ''
    Write-Host "Instalador: $instalador" -ForegroundColor Green
    Write-Host "SHA-256:    $shaInstalador  (gravado em $(Split-Path $instalador -Leaf).sha256)" -ForegroundColor Green
    # A procedência sai junto do hash, não separada: o SHA-256 só serve de prova de integridade se a
    # TI souber de qual commit ele veio — "o hash do pacote de ontem" não identifica nada.
    if ($origem.Commit) {
        Write-Host "Origem:     $($origem.Descricao)" -ForegroundColor Green
        Write-Host "            $($origem.Commit)" -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Origem:     arvore de trabalho (-UseWorkingTree) - NAO distribuir em campo' -ForegroundColor Yellow
    }
    Write-Host "Scripts:    SisPedraCaida-Instaladores @ $(Get-ProcedenciaDosScripts -RepoRoot $repoRoot)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Publique o SHA-256 ao lado do artefato: o pacote nao e assinado por CA publica (D6,' -ForegroundColor Yellow
    Write-Host 'custo zero), e o hash e a unica prova de integridade que a TI tem antes de instalar.' -ForegroundColor Yellow
    Write-Host 'Distribua por compartilhamento interno ou pendrive — download por navegador anexa a' -ForegroundColor Yellow
    Write-Host 'Mark-of-the-Web e dispara o SmartScreen.' -ForegroundColor Yellow
}
finally {
    if ($RemoveWorktree -and -not $UseWorkingTree) {
        Remove-WorktreeDoPacote -RepoRoot $backendRoot -WorktreeDir $WorktreeDir
    }
}
