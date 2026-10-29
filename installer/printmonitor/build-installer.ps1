<#
.SYNOPSIS
    Gera o instalador Windows 10 do PrintMonitor (PrintMonitorSetup-<versão>.exe).

.DESCRIPTION
    Um comando, do repositório limpo ao .exe distribuível — e sem licença paga em nenhum ponto da
    cadeia (Inno Setup 6 é gratuito inclusive para uso comercial; o SDK .NET é MIT).

    Sequência:
      1. resolve a FONTE do pacote: por padrão um worktree pinado em `origin/prod` (PRD-INSTPROD-02,
         paridade com o instalador do agente TEF) — `.iss`, includes, publicador e projetos saem do
         mesmo commit. Antes daqui o script empacotava a árvore aberta, e o SHA-256 publicado não
         correspondia a commit nenhum;
      2. publica o layout self-contained win-x64 chamando `scripts/printmonitor-publish.ps1 -SkipZip`
         da fonte — o layout publicado é o CONTRATO de entrada, o mesmo que o Bootstrapper troca no
         auto-update. Copiar binário à mão produziria dois empacotadores e um deles desatualizado;
      3. confere o SHA-256 do payload do QZ Tray contra `payload.sha256`, quando houver payload — é a
         proteção equivalente à do download verificado, sem depender da rede do resort;
      4. compila `PrintMonitor.iss` com o ISCC, injetando versão, diretório publicado e nome do
         payload por /D;
      5. grava o SHA-256 do instalador em `<instalador>.sha256`, publicado ao lado do artefato.

.PARAMETER Version
    Versão a estampar. Padrão: a lida de Directory.Build.props da fonte.

.PARAMETER Configuration
    Configuração de build do agente. Padrão: Release.

.PARAMETER IsccPath
    Caminho do ISCC.exe. Padrão: descoberto em Program Files e em %LOCALAPPDATA%.

.PARAMETER Ref
    Referência git que origina o pacote. Padrão: **prod** — o instalador vai para a estação do
    cliente, então ele nasce do código que está em produção. Aceita branch, `origin/<branch>`, tag
    ou SHA.

.PARAMETER BackendRoot
    Checkout do SisPedraCaida-Backend de onde o código do agente é pinado (`-Ref` resolve NELE). Padrão:
    `$env:SISPEDRACAIDA_BACKEND`, depois `backend/` (checkout do CI) e por fim o repositório irmão
    `../SisPedraCaida-Backend` do workspace.

.PARAMETER UseWorkingTree
    Empacota a árvore de trabalho atual DO BACKEND (o comportamento anterior ao pino). Modo de desenvolvimento:
    **nunca** para pacote de campo — o .exe sai sem procedência rastreável.

.PARAMETER SkipFetch
    Não busca a referência no remoto antes de empacotar (máquina offline, ou SHA já local).

.PARAMETER WorktreeDir
    Worktree da fonte pinada. Padrão: `<workspace>/.worktrees/printmonitor-pacote`. O CI passa um
    diretório próprio por run, para empacotar lado a lado com os outros agentes.

.PARAMETER PublishDir
    Onde o layout self-contained é publicado. Padrão: `artifacts/printmonitor`.

.PARAMETER OutputDir
    Onde o instalador e o `.sha256` são gravados. Padrão: `artifacts/installer`.

.PARAMETER PayloadDir
    Pasta com o instalador do QZ Tray + `payload.sha256`. Padrão: `installer/printmonitor/payload`
    DESTE checkout — o binário não é versionado, então ele nunca está no worktree pinado; o script o
    copia para lá antes de compilar. No CI vem de `PRINTMONITOR_PAYLOAD_DIR` (cache do runner).

.PARAMETER RemoveWorktree
    Remove o worktree ao final, com sucesso ou falha (CI).

.PARAMETER SkipPublish
    Reaproveita o layout já publicado em -PublishDir (iteração rápida no .iss).

.PARAMETER DryRun
    Valida a cadeia (ISCC presente, layout, payload e hash) sem compilar o instalador.

.PARAMETER DividirEmPartes
    Além do `.exe`, grava o pacote versionável no git: `PrintMonitorSetup-<versão>.zip` (o `.exe` + o
    `.sha256`) em partes `.zip.001`, `.002`… de até 90 MiB — o GitHub recusa arquivo acima de 100 MiB, e o
    instalador passa disso (QZ Tray com JRE). Remontar: `installer/common/montar-instalador.ps1`
    ou o 7-Zip pela `.001`. Desligado por padrão — o CI anexa o `.exe` inteiro à release, que aceita até
    2 GiB.

.PARAMETER OrigensPadrao
    Origens do front-adm que o wizard traz pré-preenchidas (página "Identificação pelo navegador") e que o
    modo silencioso usa quando nada é informado nem está gravado na estação. Omitido, vale o default do
    `.iss` (`https://interno-dev.berechit.com.br`); vazio gera um instalador sem origem padrão. Validado e
    normalizado aqui: um default inválido bloquearia toda estação na abertura do instalador.

.EXAMPLE
    pwsh installer/printmonitor/build-installer.ps1

.EXAMPLE
    # Admin de outro ambiente como origem padrão (lista separada por vírgula).
    pwsh installer/printmonitor/build-installer.ps1 -OrigensPadrao 'https://admin.exemplo.com.br'

.EXAMPLE
    # Pacote versionável no git (zip em partes de 90 MiB em artifacts/installer).
    pwsh installer/printmonitor/build-installer.ps1 -Ref origin/dev -DividirEmPartes

.EXAMPLE
    pwsh installer/printmonitor/build-installer.ps1 -UseWorkingTree -SkipPublish -DryRun

.EXAMPLE
    # Modo CI: SHA exato, versão da tag, diretórios próprios, payload do cache do runner.
    pwsh installer/printmonitor/build-installer.ps1 -Ref <sha> -Version 2.6.0 -SkipFetch -RemoveWorktree `
        -WorktreeDir $env:RUNNER_TEMP/wt-printmonitor -PublishDir $env:RUNNER_TEMP/pub-printmonitor `
        -OutputDir $env:RUNNER_TEMP/out-printmonitor -PayloadDir $env:PRINTMONITOR_PAYLOAD_DIR
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
    [string] $PayloadDir = '',
    [AllowEmptyString()]
    [string] $OrigensPadrao,
    [switch] $UseWorkingTree,
    [switch] $SkipFetch,
    [switch] $SkipPublish,
    [switch] $RemoveWorktree,
    [switch] $DividirEmPartes,
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
if (-not $PublishDir) { $PublishDir = Join-Path (Join-Path $repoRoot 'artifacts') 'printmonitor' }
if (-not $OutputDir) { $OutputDir = Join-Path (Join-Path $repoRoot 'artifacts') 'installer' }
if (-not $PayloadDir) { $PayloadDir = Join-Path $PSScriptRoot 'payload' }
if (-not $WorktreeDir) { $WorktreeDir = Join-Path (Join-Path (Split-Path $repoRoot -Parent) '.worktrees') 'printmonitor-pacote' }

# Cadeia que a fonte pinada (backend) precisa ter: `.iss` + includes, publicador e os projetos do layout.
$exigidos = @(
    'scripts/printmonitor-publish.ps1',
    'src/SisPedraCaida.PrintMonitor.Setup/SisPedraCaida.PrintMonitor.Setup.csproj',
    'src/SisPedraCaida.PrintMonitor.Service/SisPedraCaida.PrintMonitor.Service.csproj',
    'src/SisPedraCaida.PrintMonitor.Helper/SisPedraCaida.PrintMonitor.Helper.csproj',
    'src/SisPedraCaida.PrintMonitor.Bootstrapper/SisPedraCaida.PrintMonitor.Bootstrapper.csproj',
    'src/SisPedraCaida.PrintMonitor.Tray/SisPedraCaida.PrintMonitor.Tray.csproj'
)

# Cadeia que ESTE repositório precisa ter: o `.iss` e os includes saíram do backend.
$exigidosLocais = @(
    'installer/printmonitor/PrintMonitor.iss',
    'installer/printmonitor/checks.iss',
    'installer/printmonitor/pages.iss',
    'installer/printmonitor/provisioning.iss',
    'installer/printmonitor/upgrade.iss',
    'installer/printmonitor/processos.iss',
    'installer/printmonitor/licencas/AVISOS-TERCEIROS.txt'
)

<#
.SYNOPSIS
    Resolve o payload do QZ Tray, confere o hash declarado e o leva para a pasta do .iss da fonte.
.DESCRIPTION
    O instalador do QZ Tray é redistribuído dentro do pacote em vez de baixado: a API do piloto
    está em HTTP puro e o QzTrayInstaller recusa InstallerUrl sem https. Em troca, o binário precisa
    ser verificado em TEMPO DE BUILD — senão trocamos "download verificado" por "arquivo que alguém
    largou na pasta".

    O `.iss` referencia `payload\<arquivo>` relativo a si mesmo, e ele vive neste repositório: o binário
    conferido é copiado para a `payload\` ao lado do script quando vem de outra pasta (o cache do runner).
    A cópia é ignorada pelo `.gitignore` da pasta; no CI o `actions/checkout` a apaga a cada run.
.OUTPUTS
    Nome do arquivo do payload, ou vazio quando não há payload.
#>
function Resolve-Payload {
    $destino = Join-Path $PSScriptRoot 'payload'
    return Resolve-PayloadVerificado -PayloadDir $PayloadDir -ArquivoHash 'payload.sha256' `
        -Destino $destino -Descricao 'o QZ Tray embutido'
}

Write-Host 'PrintMonitor - instalador Windows 10' -ForegroundColor Cyan

try {
    $iscc = Resolve-IsccExecutavel -IsccPath $IsccPath
    Write-Host "  ISCC: $iscc" -ForegroundColor DarkGray

    # Só vira /D quando informado: omitido, vale o default do .iss.
    $definicaoOrigens = @()
    if ($PSBoundParameters.ContainsKey('OrigensPadrao')) {
        $origensNormalizadas = ConvertTo-ListaDeOrigens -Origens $OrigensPadrao
        $definicaoOrigens = @("/DOrigensPadrao=$origensNormalizadas")
        Write-Host "  origens padrao do front-adm: $(if ($origensNormalizadas) { $origensNormalizadas } else { '(nenhuma)' })" `
            -ForegroundColor DarkGray
    }

    Assert-FonteCompleta -Fonte $repoRoot -Descricao 'O checkout do SisPedraCaida-Instaladores' `
        -Agente 'PrintMonitor' -Exigidos $exigidosLocais

    $origem = Resolve-FonteDoPacote -RepoRoot $backendRoot -Ref $Ref -WorktreeDir $WorktreeDir `
        -UseWorkingTree:$UseWorkingTree -SkipFetch:$SkipFetch
    $fonte = $origem.Caminho
    Assert-FonteCompleta -Fonte $fonte -Descricao $origem.Descricao -Agente 'PrintMonitor' -Exigidos $exigidos

    $versaoResolvida = Resolve-VersaoDoPacote -Fonte $fonte -Version $Version
    Write-Host "  versao: $versaoResolvida" -ForegroundColor DarkGray

    if (-not $SkipPublish) {
        Write-Host '  publicando o layout self-contained do agente...' -ForegroundColor DarkGray
        & (Join-Path (Join-Path $fonte 'scripts') 'printmonitor-publish.ps1') `
            -OutputPath $PublishDir -Version $versaoResolvida -Configuration $Configuration -SkipZip
        if ($LASTEXITCODE -ne 0) { throw "Falha ao publicar o layout do agente (codigo $LASTEXITCODE)." }
    }

    $setupExe = Join-Path $PublishDir 'SisPedraCaida.PrintMonitor.Setup.exe'
    if (-not (Test-Path $setupExe)) {
        throw "Layout publicado sem o Setup.exe ($setupExe). Rode sem -SkipPublish."
    }

    $payloadFile = Resolve-Payload

    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry-run: cadeia validada (ISCC, layout publicado e payload). Nada foi compilado.' -ForegroundColor Green
        return
    }

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $argumentos = @(
        "/DAppVersion=$versaoResolvida",
        "/DPublishDir=$PublishDir",
        "/DQzInstallerFile=$payloadFile"
    ) + $definicaoOrigens + @(
        "/O$OutputDir",
        # O .iss sai DESTE repositório (includes relativos ao arquivo) e os binários do commit pinado do
        # backend: a procedência do pacote são os DOIS SHAs, impressos no fim (Origem + Scripts).
        (Join-Path $PSScriptRoot 'PrintMonitor.iss')
    )

    Write-Host '  compilando o instalador...' -ForegroundColor DarkGray
    & $iscc @argumentos
    if ($LASTEXITCODE -ne 0) { throw "ISCC falhou (codigo $LASTEXITCODE)." }

    $instalador = Join-Path $OutputDir "PrintMonitorSetup-$versaoResolvida.exe"
    if (-not (Test-Path $instalador)) { throw "ISCC terminou sem produzir $instalador." }

    $shaInstalador = Write-ArquivoSha256 -Arquivo $instalador

    # O zip sai do .exe já hasheado e leva o .sha256 dentro: o hash continua sendo do instalador inteiro,
    # que é o que a TI confere depois de remontar — hash por parte provaria só que cada pedaço chegou.
    $partes = @()
    if ($DividirEmPartes) { $partes = @(New-PacoteZipEmPartes -Instalador $instalador) }

    Write-Host ''
    Write-Host "Instalador: $instalador" -ForegroundColor Green
    Write-Host "SHA-256:    $shaInstalador  (gravado em $(Split-Path $instalador -Leaf).sha256)" -ForegroundColor Green
    if ($partes.Count -gt 0) {
        Write-Host "Partes:     $(($partes | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')" -ForegroundColor Green
        Write-Host '            remontar: pwsh installer/common/montar-instalador.ps1 -Instalador <.exe>' -ForegroundColor DarkGray
    }
    if ($origem.Commit) {
        Write-Host "Origem:     $($origem.Descricao)" -ForegroundColor Green
        Write-Host "            $($origem.Commit)" -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Origem:     arvore de trabalho (-UseWorkingTree) - NAO distribuir em campo' -ForegroundColor Yellow
    }
    Write-Host "Scripts:    SisPedraCaida-Instaladores @ $(Get-ProcedenciaDosScripts -RepoRoot $repoRoot)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Publique o SHA-256 ao lado do artefato: o pacote não é assinado por CA pública (D4,' -ForegroundColor Yellow
    Write-Host 'custo zero), e o hash é a única prova de integridade que a TI tem antes de instalar.' -ForegroundColor Yellow
    Write-Host 'Distribua por compartilhamento interno ou pendrive — download por navegador anexa a' -ForegroundColor Yellow
    Write-Host 'Mark-of-the-Web e dispara o SmartScreen.' -ForegroundColor Yellow
}
finally {
    if ($RemoveWorktree -and -not $UseWorkingTree) {
        Remove-WorktreeDoPacote -RepoRoot $backendRoot -WorktreeDir $WorktreeDir
    }
}
