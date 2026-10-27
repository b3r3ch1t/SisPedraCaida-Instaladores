<#
.SYNOPSIS
    Gera o instalador Windows do totem de autoatendimento (TotemSetup-<versão>.exe).

.DESCRIPTION
    Um comando, do repositório limpo ao .exe distribuível — e sem licença paga em nenhum ponto da
    cadeia (Inno Setup 6 é gratuito inclusive para uso comercial; o SDK .NET é MIT).

    Mesmo contrato do `installer/tefagent/build-installer.ps1` (o CI chama os dois do mesmo jeito,
    pela matriz de `installer/instaladores-ci.json`). Sequência:
      1. resolve a FONTE do pacote: por padrão um worktree do BACKEND pinado em `prod` — os três
         projetos saem desse commit; o `.iss` e os includes saem DESTE repositório
         (SisPedraCaida-Instaladores), e a procedência são os dois SHAs (Origem + Scripts);
      2. publica o layout self-contained win-x64 dos TRÊS executáveis do totem numa pasta única —
         Setup, Agent (o Windows Service) e Shell (a casca). O publish vive AQUI, e não num
         `scripts/totem-publish.ps1`: o totem não tem auto-update nem pacote .zip que reaproveite o
         layout fora do instalador, então um segundo script só seria um segundo lugar para errar;
      3. confere, quando informado, o bootstrapper do WebView2 Runtime contra o seu `.sha256`;
      4. compila `Totem.iss` com o ISCC, injetando versão, diretório publicado e o bootstrapper
         por /D;
      5. grava o SHA-256 do instalador em `<instalador>.sha256`, publicado ao lado do artefato — o
         pacote não é assinado por CA pública, e o hash é a única prova de integridade que a TI tem
         antes de instalar.

    Os três executáveis ficam lado a lado na mesma pasta de propósito: o Setup resolve o serviço e a
    casca por `AppContext.BaseDirectory`, nunca por PATH nem por literal de `Program Files`.

.PARAMETER Version
    Versão a estampar (X.Y.Z). Padrão: a lida de Directory.Build.props da fonte (backend).

.PARAMETER Configuration
    Configuração de build. Padrão: Release.

.PARAMETER IsccPath
    Caminho do ISCC.exe. Padrão: descoberto em Program Files e em %LOCALAPPDATA%.

.PARAMETER Ref
    Referência git que origina o pacote. Padrão: **prod** — o instalador vai para o totem do
    cliente, então ele nasce do código que está em produção. Aceita branch, `origin/<branch>`, tag
    ou SHA.

.PARAMETER BackendRoot
    Checkout do SisPedraCaida-Backend de onde o código do totem é pinado (`-Ref` resolve NELE). Padrão:
    `$env:SISPEDRACAIDA_BACKEND`, depois `backend/` (checkout do CI) e por fim o repositório irmão
    `../SisPedraCaida-Backend` do workspace.

.PARAMETER UseWorkingTree
    Empacota a árvore de trabalho atual DO BACKEND. Modo de desenvolvimento: **nunca** para pacote de campo — o
    .exe sai sem procedência rastreável, e o SHA-256 impresso não corresponde a nenhum commit.

.PARAMETER SkipFetch
    Não busca a referência no remoto antes de empacotar (máquina offline, ou SHA já local).

.PARAMETER WorktreeDir
    Worktree da fonte pinada. Padrão: `<workspace>/.worktrees/totem-pacote`. O CI passa um diretório
    próprio por run: dois empacotamentos no mesmo worktree disputariam o checkout e o `bin/obj`.

.PARAMETER PublishDir
    Onde o layout self-contained é publicado. Padrão: `artifacts/totem`.

.PARAMETER OutputDir
    Onde o instalador e o `.sha256` são gravados. Padrão: `artifacts/installer`.

.PARAMETER WebView2BootstrapperPath
    Opcional. Pasta (ou o próprio arquivo) do bootstrapper do WebView2 Runtime —
    `MicrosoftEdgeWebview2Setup.exe`, o instalador oficial da Microsoft — com um `webview2.sha256` ao
    lado (formato sha256sum: `<hash>  MicrosoftEdgeWebview2Setup.exe`). O build NÃO baixa nada: o
    binário é conferido contra o hash declarado e embutido. Sem ele, o instalador sai sem o
    componente e a checagem só AVISA que o runtime está ausente na máquina (a casca mostra "fora de
    serviço" sem o runtime). O binário não é versionado e não é copiado para a fonte — o `.iss` o
    recebe por caminho absoluto.

.PARAMETER RemoveWorktree
    Remove o worktree ao final, com sucesso ou falha (CI).

.PARAMETER SkipPublish
    Reaproveita o layout já publicado em -PublishDir (iteração rápida no .iss).

.PARAMETER DryRun
    Valida a cadeia (ISCC presente, layout publicado e bootstrapper conferido) sem compilar.

.EXAMPLE
    pwsh installer/totem/build-installer.ps1

.EXAMPLE
    pwsh installer/totem/build-installer.ps1 -UseWorkingTree -WebView2BootstrapperPath C:\payload\webview2

.EXAMPLE
    # Modo CI: SHA exato, versão da tag, diretórios próprios, worktree descartado no fim.
    pwsh installer/totem/build-installer.ps1 -Ref <sha> -Version 2.6.0 -SkipFetch -RemoveWorktree `
        -WorktreeDir $env:RUNNER_TEMP/wt-totem -PublishDir $env:RUNNER_TEMP/pub-totem `
        -OutputDir $env:RUNNER_TEMP/out-totem
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
    [string] $WebView2BootstrapperPath = '',
    [switch] $UseWorkingTree,
    [switch] $SkipFetch,
    [switch] $SkipPublish,
    [switch] $RemoveWorktree,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = [string](Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..'))
Import-Module (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'common' 'Empacotamento.psm1')) -Force

# O código do totem vem do checkout do BACKEND (repositório irmão no workspace, ou `backend/` no
# CI); o `.iss` e os includes vêm DESTE repositório (SisPedraCaida-Instaladores).
$backendRoot = Resolve-RaizDoBackend -RepoRoot $repoRoot -BackendRoot $BackendRoot

# Defaults resolvidos no corpo, não no param(): no Windows PowerShell 5.1 o $PSScriptRoot pode chegar
# VAZIO à avaliação do default do parâmetro, e o Join-Path recusa string vazia.
if (-not $PublishDir) { $PublishDir = Join-Path (Join-Path $repoRoot 'artifacts') 'totem' }
if (-not $OutputDir) { $OutputDir = Join-Path (Join-Path $repoRoot 'artifacts') 'installer' }
if (-not $WorktreeDir) { $WorktreeDir = Join-Path (Join-Path (Split-Path $repoRoot -Parent) '.worktrees') 'totem-pacote' }

# Cadeia que a fonte pinada (backend) precisa ter: os três projetos do layout.
$exigidos = @(
    'src/SisPedraCaida.Totem.Setup/SisPedraCaida.Totem.Setup.csproj',
    'src/SisPedraCaida.Totem.Agent/SisPedraCaida.Totem.Agent.csproj',
    'src/SisPedraCaida.Totem.Shell/SisPedraCaida.Totem.Shell.csproj'
)

# Cadeia que ESTE repositório precisa ter: o `.iss`, os includes e o ícone saíram do backend.
$exigidosLocais = @(
    'installer/totem/Totem.iss',
    'installer/totem/checks.iss',
    'installer/totem/pages.iss',
    'installer/totem/provisioning.iss',
    'installer/assets/sispedracaida.ico'
)

# O Setup vem PRIMEIRO: ele referencia o agente, então a publicação dele já traz os binários comuns.
# A casca vem por ÚLTIMO: é a única net10.0-windows (WinForms + WebView2) e traz por cima o runtime
# de desktop — publicada antes, ela teria o que é só dela sobrescrito por nada, mas a ordem documenta
# qual é a raiz do layout (a mesma do publicador do TEF).
$projetos = @(
    'SisPedraCaida.Totem.Setup',
    'SisPedraCaida.Totem.Agent',
    'SisPedraCaida.Totem.Shell'
)

# Sem estes arquivos o instalador "conclui" e o totem não funciona — melhor o build falhar aqui.
$essenciais = @(
    'SisPedraCaida.Totem.Setup.exe',
    'SisPedraCaida.Totem.Agent.exe',
    'SisPedraCaida.Totem.Shell.exe',
    # O serviço lê a configuração base daqui (a do terminal vive em %PROGRAMDATA%).
    'appsettings.json',
    # O loader nativo do WebView2: sem ele a casca cai em "fora de serviço" mesmo com o runtime
    # instalado — e a mensagem no log diria "runtime ausente", mandando o técnico atrás do lugar errado.
    'WebView2Loader.dll',
    'Microsoft.Web.WebView2.WinForms.dll',
    'Microsoft.Web.WebView2.Core.dll'
)

<#
.SYNOPSIS
    Publica o layout self-contained win-x64 dos três executáveis do totem numa pasta única.
.PARAMETER Fonte
    Árvore da qual os projetos são publicados.
.PARAMETER Destino
    Pasta do layout. Limpa a cada execução: uma DLL que deixou de ser referenciada seria empacotada
    junto e enviada aos totens.
.PARAMETER Versao
    Versão a estampar nos binários.
#>
function Publish-LayoutDoTotem {
    param(
        [Parameter(Mandatory)] [string] $Fonte,
        [Parameter(Mandatory)] [string] $Destino,
        [Parameter(Mandatory)] [string] $Versao
    )

    if (Test-Path $Destino) { Remove-Item $Destino -Recurse -Force }
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null

    foreach ($projeto in $projetos) {
        $csproj = Join-Path (Join-Path (Join-Path $Fonte 'src') $projeto) "$projeto.csproj"
        Write-Host "  publicando $projeto..." -ForegroundColor DarkGray

        # SELF-CONTAINED: o totem é uma máquina sem SDK e, muitas vezes, sem runtime .NET. Sem
        # single-file: os três executáveis dividem o runtime da pasta, e o Setup acha os outros dois
        # ao lado dele.
        dotnet publish $csproj `
            --configuration $Configuration `
            --runtime win-x64 `
            --self-contained true `
            -p:PublishSingleFile=false `
            -p:Version=$Versao `
            --output $Destino `
            --nologo `
            --verbosity quiet
        if ($LASTEXITCODE -ne 0) { throw "Falha ao publicar $projeto (codigo $LASTEXITCODE)." }
    }

    # Carimbo da versão no layout: permite conferir, no totem em campo, qual pacote está instalado sem
    # depender do que "Programas e Recursos" diz. Sem BOM (o -Encoding UTF8 do 5.1 escreveria um).
    [System.IO.File]::WriteAllText(
        (Join-Path $Destino 'package.version'),
        $Versao,
        (New-Object System.Text.UTF8Encoding $false))
}

<#
.SYNOPSIS
    Resolve o bootstrapper do WebView2 (opcional), conferido por SHA-256.
.DESCRIPTION
    Mesma régua do payload do QZ Tray no PrintMonitor (`Resolve-PayloadVerificado`): um único `.exe`
    na pasta, `webview2.sha256` presente, nomeando o mesmo arquivo e com o hash que confere — senão o
    build FALHA, porque "binário que alguém largou na pasta" não pode virar componente instalado
    elevado em todo totem. Diferente do PrintMonitor, o binário NÃO é copiado para a fonte: o `.iss`
    o recebe por caminho absoluto, e uma cópia na árvore aberta (-UseWorkingTree) seria um
    executável de terceiro solto no repositório, a um `git add` de ser versionado.
.OUTPUTS
    Caminho absoluto do bootstrapper, ou vazio quando não informado.
#>
function Resolve-BootstrapperWebView2 {
    if (-not $WebView2BootstrapperPath) {
        Write-Host '  sem -WebView2BootstrapperPath — o instalador sairá sem o WebView2 Runtime (a checagem só avisa).' `
            -ForegroundColor Yellow
        return ''
    }

    $pasta = $WebView2BootstrapperPath
    if (Test-Path $pasta -PathType Leaf) { $pasta = Split-Path (Resolve-Path $pasta).Path -Parent }
    if (-not (Test-Path $pasta -PathType Container)) {
        throw "-WebView2BootstrapperPath '$WebView2BootstrapperPath' não existe."
    }
    $pasta = (Resolve-Path $pasta).Path

    $nome = Resolve-PayloadVerificado -PayloadDir $pasta -ArquivoHash 'webview2.sha256' `
        -Destino $pasta -Descricao 'o bootstrapper do WebView2 Runtime' -Obrigatorio
    return (Join-Path $pasta $nome)
}

Write-Host 'Totem de autoatendimento - instalador Windows' -ForegroundColor Cyan

try {
    $iscc = Resolve-IsccExecutavel -IsccPath $IsccPath
    Write-Host "  ISCC: $iscc" -ForegroundColor DarkGray

    Assert-FonteCompleta -Fonte $repoRoot -Descricao 'O checkout do SisPedraCaida-Instaladores' `
        -Agente 'totem' -Exigidos $exigidosLocais

    $origem = Resolve-FonteDoPacote -RepoRoot $backendRoot -Ref $Ref -WorktreeDir $WorktreeDir `
        -UseWorkingTree:$UseWorkingTree -SkipFetch:$SkipFetch
    $fonte = $origem.Caminho
    Assert-FonteCompleta -Fonte $fonte -Descricao $origem.Descricao -Agente 'totem' -Exigidos $exigidos

    $versaoResolvida = Resolve-VersaoDoPacote -Fonte $fonte -Version $Version
    # O Inno grava VersionInfoVersion, que recusa sufixo (-rc, -sha...): melhor dizer aqui do que no ISCC.
    if ($versaoResolvida -notmatch '^\d+\.\d+\.\d+$') {
        throw "Versao '$versaoResolvida' fora de X.Y.Z (o Inno nao aceita sufixo em VersionInfoVersion)."
    }
    Write-Host "  versao: $versaoResolvida" -ForegroundColor DarkGray

    if (-not $SkipPublish) {
        Write-Host '  publicando o layout self-contained do totem...' -ForegroundColor DarkGray
        Publish-LayoutDoTotem -Fonte $fonte -Destino $PublishDir -Versao $versaoResolvida
    }

    $faltando = @($essenciais | Where-Object { -not (Test-Path (Join-Path $PublishDir $_)) })
    if ($faltando.Count -gt 0) {
        throw "Layout publicado em $PublishDir sem arquivos essenciais: $($faltando -join ', '). Rode sem -SkipPublish."
    }

    $bootstrapper = Resolve-BootstrapperWebView2

    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry-run: cadeia validada (ISCC, layout publicado e bootstrapper). Nada foi compilado.' -ForegroundColor Green
        return
    }

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $argumentos = @(
        "/DAppVersion=$versaoResolvida",
        "/DPublishDir=$PublishDir"
    )
    # Só vira /D quando há bootstrapper: omitido, o .iss compila sem o componente.
    if ($bootstrapper) { $argumentos += "/DWebView2Bootstrapper=$bootstrapper" }
    $argumentos += @(
        "/O$OutputDir",
        # O .iss sai DESTE repositório (includes checks/pages/provisioning relativos ao arquivo) e
        # os binários do commit pinado do backend: a procedência são os DOIS SHAs (Origem + Scripts).
        (Join-Path $PSScriptRoot 'Totem.iss')
    )

    Write-Host '  compilando o instalador...' -ForegroundColor DarkGray
    & $iscc @argumentos
    if ($LASTEXITCODE -ne 0) { throw "ISCC falhou (codigo $LASTEXITCODE)." }

    $instalador = Join-Path $OutputDir "TotemSetup-$versaoResolvida.exe"
    if (-not (Test-Path $instalador)) { throw "ISCC terminou sem produzir $instalador." }

    $shaInstalador = Write-ArquivoSha256 -Arquivo $instalador

    Write-Host ''
    Write-Host "Instalador: $instalador" -ForegroundColor Green
    Write-Host "SHA-256:    $shaInstalador  (gravado em $(Split-Path $instalador -Leaf).sha256)" -ForegroundColor Green
    if ($bootstrapper) {
        Write-Host "WebView2:   bootstrapper embutido ($(Split-Path $bootstrapper -Leaf))" -ForegroundColor Green
    }
    else {
        Write-Host 'WebView2:   NAO embutido - em maquina sem o runtime a tela do totem fica "fora de servico"' -ForegroundColor Yellow
    }
    # A procedência sai junto do hash: o SHA-256 só prova algo se a TI souber de qual commit ele veio.
    if ($origem.Commit) {
        Write-Host "Origem:     $($origem.Descricao)" -ForegroundColor Green
        Write-Host "            $($origem.Commit)" -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Origem:     arvore de trabalho (-UseWorkingTree) - NAO distribuir em campo' -ForegroundColor Yellow
    }
    Write-Host "Scripts:    SisPedraCaida-Instaladores @ $(Get-ProcedenciaDosScripts -RepoRoot $repoRoot)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Publique o SHA-256 ao lado do artefato: o pacote nao e assinado por CA publica, e o hash' -ForegroundColor Yellow
    Write-Host 'e a unica prova de integridade que a TI tem antes de instalar. Distribua com /NORESTART' -ForegroundColor Yellow
    Write-Host 'no silencioso (arquivo travado e trocado no reinicio, e o Inno reiniciaria sozinho).' -ForegroundColor Yellow
}
finally {
    if ($RemoveWorktree -and -not $UseWorkingTree) {
        Remove-WorktreeDoPacote -RepoRoot $backendRoot -WorktreeDir $WorktreeDir
    }
}
