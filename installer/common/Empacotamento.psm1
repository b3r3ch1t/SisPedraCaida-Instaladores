<#
.SYNOPSIS
    Núcleo comum dos `build-installer.ps1` dos agentes Windows (PRD-INSTPROD-02).

.DESCRIPTION
    Resolução do ISCC, pino da fonte num worktree, versão, checagem da cadeia de empacotamento e o
    arquivo `.sha256` — a parte de um empacotador que NÃO depende do agente. Antes deste módulo cada
    `build-installer.ps1` tinha a sua cópia, e elas já divergiam: o do PrintMonitor não pinava a
    fonte e indexava o primeiro caractere do caminho do ISCC quando havia um único candidato (o
    defeito que o do TEF já tinha corrigido). Três cópias da mesma lógica garantem que uma fique
    desatualizada sem ninguém perceber.

    Compatível com Windows PowerShell 5.1: nada de `Join-Path` com três argumentos, de operador
    ternário ou de `-Encoding utf8NoBOM`.
#>

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Roda `git -C <RepoRoot>` e devolve a saída aparada.
.PARAMETER RepoRoot
    Repositório em que o comando roda.
.PARAMETER Argumentos
    Argumentos do git.
.PARAMETER Silencioso
    Em falha devolve `$null` em vez de lançar (sondagens: fetch sem rede, ref que pode não existir).
#>
function Invoke-GitEmpacotamento {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string[]] $Argumentos,
        [switch] $Silencioso
    )

    # ⚠️ 'Continue' só aqui dentro: no Windows PowerShell 5.1, com 'Stop', cada linha que o git
    # escreve no STDERR vira exceção — e o git usa o stderr para progresso ("Preparing worktree
    # (detached HEAD …)"), então o `worktree add` morria com sucesso. Quem decide é o código de saída.
    $ErrorActionPreference = 'Continue'
    $saida = & git -C $RepoRoot @Argumentos 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        if ($Silencioso) { return $null }
        throw "git $($Argumentos -join ' ') falhou: $saida"
    }

    return ($saida | Out-String).Trim()
}

<#
.SYNOPSIS
    Localiza o ISCC.exe do Inno Setup 6.
.PARAMETER IsccPath
    Caminho explícito; vazio = descoberta em Program Files e em %LOCALAPPDATA%.
.OUTPUTS
    Caminho do ISCC.exe.
#>
function Resolve-IsccExecutavel {
    param([string] $IsccPath = '')

    if ($IsccPath) {
        if (-not (Test-Path $IsccPath)) { throw "ISCC.exe nao encontrado em $IsccPath." }
        return $IsccPath
    }

    # A instalação por winget (JRSoftware.InnoSetup) é POR USUÁRIO e cai em LOCALAPPDATA — procurar
    # só em Program Files faz o build falhar dizendo "instale o Inno" numa máquina que já o tem.
    #
    # ⚠️ O @() EXTERNO é obrigatório. Com UM único candidato o pipeline devolve uma STRING, não um
    # array, e o `$candidatos[0]` abaixo passa a indexar o primeiro CARACTERE: o build morria com
    # `The term 'C' is not recognized as a name of a cmdlet`. Um único candidato é o caso NORMAL.
    $candidatos = @(@(
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe' }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe' })
    ) | Where-Object { $_ -and (Test-Path $_) })

    if (-not $candidatos) {
        throw @'
ISCC.exe (Inno Setup 6) nao encontrado.

Instale o Inno Setup 6 — gratuito, inclusive para uso comercial:

    winget install --id JRSoftware.InnoSetup

ou baixe de https://jrsoftware.org/isdl.php, ou informe o caminho com -IsccPath. A IDE
(Compil32.exe) NAO entra neste fluxo: o build e por linha de comando para ser reproduzivel.
'@
    }

    return [string]$candidatos[0]
}

<#
.SYNOPSIS
    Localiza o checkout do SisPedraCaida-Backend de onde os agentes são publicados.

.DESCRIPTION
    Os instaladores vivem num repositório próprio, mas os binários que eles empacotam continuam
    nascendo do backend: o script precisa de um clone dele para pinar o commit num worktree. Ordem:
      1. `-BackendRoot` explícito;
      2. variável de ambiente `SISPEDRACAIDA_BACKEND`;
      3. `<este repositório>/backend` — onde o CI faz o checkout do backend;
      4. `<workspace>/SisPedraCaida-Backend` — o repositório irmão do layout local.

    Explícito que não confere LANÇA em vez de cair no próximo candidato: quem apontou um caminho errado
    quer saber disso, e empacotar silenciosamente de outro clone produziria um pacote de outra fonte.

.PARAMETER RepoRoot
    Raiz deste repositório (SisPedraCaida-Instaladores).
.PARAMETER BackendRoot
    Caminho explícito do checkout do backend; vazio = descoberta.
.OUTPUTS
    Caminho absoluto do checkout do backend.
#>
function Resolve-RaizDoBackend {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $BackendRoot = ''
    )

    $ehBackend = {
        param([string] $Caminho)
        $Caminho -and (Test-Path (Join-Path $Caminho 'SisPedraCaida.slnx')) -and (Test-Path (Join-Path $Caminho '.git'))
    }

    foreach ($explicito in @(@{ Valor = $BackendRoot; Origem = '-BackendRoot' }, @{ Valor = [string]$env:SISPEDRACAIDA_BACKEND; Origem = 'SISPEDRACAIDA_BACKEND' })) {
        if (-not $explicito.Valor) { continue }
        if (-not (& $ehBackend $explicito.Valor)) {
            throw "$($explicito.Origem) aponta '$($explicito.Valor)', que nao e um clone do SisPedraCaida-Backend (sem SisPedraCaida.slnx ou sem .git)."
        }
        return [string](Resolve-Path $explicito.Valor)
    }

    $candidatos = @(
        (Join-Path $RepoRoot 'backend'),
        (Join-Path (Split-Path $RepoRoot -Parent) 'SisPedraCaida-Backend')
    )
    foreach ($candidato in $candidatos) {
        if (& $ehBackend $candidato) { return [string](Resolve-Path $candidato) }
    }

    throw @"
Checkout do SisPedraCaida-Backend nao encontrado.

Procurado em:
$(($candidatos | ForEach-Object { "  - $_" }) -join "`n")

Clone o backend ao lado deste repositorio (layout do workspace) ou informe -BackendRoot /
`$env:SISPEDRACAIDA_BACKEND.
"@
}

<#
.SYNOPSIS
    Descreve de qual commit DESTE repositório saíram o `.iss` e os scripts do pacote.
.DESCRIPTION
    Com os instaladores fora do backend, o SHA do backend não basta para reproduzir o pacote: o mesmo
    binário compilado com outro `.iss` é outro instalador. Árvore com alteração não commitada sai
    marcada — pacote assim é de desenvolvimento, nunca de campo.
.PARAMETER RepoRoot
    Raiz deste repositório.
.OUTPUTS
    Texto `<sha>` ou `<sha> (com alteracoes locais)`; `(fora do git)` sem repositório.
#>
function Get-ProcedenciaDosScripts {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $sha = Invoke-GitEmpacotamento -RepoRoot $RepoRoot -Argumentos @('rev-parse', 'HEAD') -Silencioso
    if (-not $sha) { return '(fora do git)' }

    $sujo = Invoke-GitEmpacotamento -RepoRoot $RepoRoot -Argumentos @('status', '--porcelain', '--', 'installer') -Silencioso
    if ($sujo) { return "$sha (com alteracoes locais)" }
    return $sha
}

<#
.SYNOPSIS
    Resolve a ÁRVORE que origina o pacote: um worktree pinado num commit, ou a árvore aberta.

.DESCRIPTION
    O instalador é um artefato de campo — copiado para o PC do balcão, fica lá até o próximo técnico
    aparecer. Empacotar a árvore de trabalho fazia o pacote carregar qualquer coisa não commitada, e
    o SHA-256 publicado ao lado dele (única prova de integridade) não correspondia a commit nenhum.

    O pino cobre o CÓDIGO dos agentes: publicador e projetos saem do mesmo commit do backend. Desde
    que os instaladores ganharam repositório próprio (SisPedraCaida-Instaladores), o `.iss` e os
    includes saem do commit DESTE repositório — os dois SHAs compõem a procedência do pacote
    (`Get-ProcedenciaDosScripts`). Cada empacotamento usa o SEU worktree (`-WorktreeDir`): dois empacotamentos no mesmo diretório
    disputariam `bin/obj` e o checkout, que é exatamente o que o CI faz ao empacotar os agentes
    lado a lado (PRD-INSTPROD-04).

.PARAMETER RepoRoot
    Repositório de onde o worktree é criado — o checkout do BACKEND (`Resolve-RaizDoBackend`).
.PARAMETER Ref
    Branch, `origin/<branch>`, tag ou SHA. `origin/<Ref>` tem precedência: "a prod" é o que está
    publicado no remoto, não a cópia local, que pode estar semanas atrasada sem nada avisar.
.PARAMETER WorktreeDir
    Diretório do worktree. Reaproveitado entre execuções (o publish é caro) e limpo a cada uma.
.PARAMETER UseWorkingTree
    Devolve a árvore aberta, sem pino (modo de desenvolvimento — pacote sem procedência).
.PARAMETER SkipFetch
    Não busca `Ref` no remoto antes de resolver (máquina offline, ou SHA já presente).
.OUTPUTS
    Objeto com `Caminho`, `Commit` (vazio na árvore aberta) e `Descricao`.
#>
function Resolve-FonteDoPacote {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $Ref = 'prod',
        [string] $WorktreeDir = '',
        [switch] $UseWorkingTree,
        [switch] $SkipFetch
    )

    if ($UseWorkingTree) {
        Write-Host '  fonte: arvore de trabalho (-UseWorkingTree)' -ForegroundColor Yellow
        return [pscustomobject]@{ Caminho = [string]$RepoRoot; Commit = ''; Descricao = 'A arvore de trabalho' }
    }

    if (-not $WorktreeDir) { throw 'Resolve-FonteDoPacote: informe -WorktreeDir (ou -UseWorkingTree).' }

    if (-not $SkipFetch) {
        # Silencioso: sem rede (ou sem remoto) o pino num SHA/branch já local continua valendo.
        Invoke-GitEmpacotamento -RepoRoot $RepoRoot -Argumentos @('fetch', '--quiet', 'origin', $Ref) -Silencioso | Out-Null
    }

    $commit = $null
    $refResolvida = $null
    foreach ($candidato in @("origin/$Ref", $Ref)) {
        $commit = Invoke-GitEmpacotamento -RepoRoot $RepoRoot -Argumentos @('rev-parse', '--verify', '--quiet', "$candidato^{commit}") -Silencioso
        if ($commit) {
            $refResolvida = $candidato
            break
        }
    }

    if (-not $commit) {
        throw "Referencia '$Ref' nao encontrada (nem como origin/$Ref). Informe -Ref ou use -UseWorkingTree."
    }

    if (Test-Path (Join-Path $WorktreeDir '.git')) {
        Invoke-GitEmpacotamento -RepoRoot $WorktreeDir -Argumentos @('checkout', '--detach', '--force', $commit) | Out-Null
        # Resto de um pacote anterior seria empacotado junto, então a árvore é limpa a cada vez.
        Invoke-GitEmpacotamento -RepoRoot $WorktreeDir -Argumentos @('clean', '-xdf', '--quiet') | Out-Null
    }
    else {
        New-Item -ItemType Directory -Path (Split-Path $WorktreeDir -Parent) -Force | Out-Null
        Invoke-GitEmpacotamento -RepoRoot $RepoRoot -Argumentos @('worktree', 'add', '--detach', '--force', $WorktreeDir, $commit) | Out-Null
    }

    $curto = $commit.Substring(0, 8)
    Write-Host "  fonte: $refResolvida @ $curto" -ForegroundColor DarkGray
    Write-Host "         $WorktreeDir" -ForegroundColor DarkGray

    return [pscustomobject]@{
        Caminho   = [string](Resolve-Path $WorktreeDir)
        Commit    = [string]$commit
        Descricao = "A referencia $refResolvida ($curto)"
    }
}

<#
.SYNOPSIS
    Remove o worktree de empacotamento (CI: o diretório é descartável e não pode sobrar entre runs).
.PARAMETER RepoRoot
    Repositório dono do worktree.
.PARAMETER WorktreeDir
    Worktree a remover. Ausente = nada a fazer.
#>
function Remove-WorktreeDoPacote {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $WorktreeDir
    )

    if (Test-Path $WorktreeDir) {
        Invoke-GitEmpacotamento -RepoRoot $RepoRoot -Argumentos @('worktree', 'remove', '--force', $WorktreeDir) -Silencioso | Out-Null
        if (Test-Path $WorktreeDir) { Remove-Item $WorktreeDir -Recurse -Force }
    }

    Invoke-GitEmpacotamento -RepoRoot $RepoRoot -Argumentos @('worktree', 'prune') -Silencioso | Out-Null
}

<#
.SYNOPSIS
    Confirma que a fonte resolvida contém a cadeia de empacotamento inteira.

.DESCRIPTION
    Sem esta checagem, uma referência que ainda não recebeu o épico do instalador falha no meio do
    caminho com "arquivo não encontrado" — que não diz o que o operador precisa saber: que o pacote
    não existe naquela branch porque a promoção ainda não chegou lá.

.PARAMETER Fonte
    Árvore resolvida por `Resolve-FonteDoPacote`.
.PARAMETER Descricao
    Descrição da fonte, para a mensagem.
.PARAMETER Agente
    Nome legível do agente, para a mensagem.
.PARAMETER Exigidos
    Caminhos relativos que a fonte precisa ter.
#>
function Assert-FonteCompleta {
    param(
        [Parameter(Mandatory)] [string] $Fonte,
        [Parameter(Mandatory)] [string] $Descricao,
        [Parameter(Mandatory)] [string] $Agente,
        [Parameter(Mandatory)] [string[]] $Exigidos
    )

    $faltando = @($Exigidos | Where-Object { -not (Test-Path (Join-Path $Fonte $_)) })
    if (-not $faltando) { return }

    throw @"
$Descricao nao contem a cadeia de empacotamento do $Agente.

Faltando:
$(($faltando | ForEach-Object { "  - $_" }) -join "`n")

A promocao do epico do instalador ainda nao chegou nessa branch. Caminhos:
  - promover staging -> prod (docs/PromocaoStagingProd.md do backend) e empacotar de novo; ou
  - empacotar de outra referencia:  -Ref staging
  - empacotar a arvore aberta (so desenvolvimento):  -UseWorkingTree
"@
}

<#
.SYNOPSIS
    Resolve a versão a estampar no pacote.
.PARAMETER Fonte
    Árvore de onde ler o `Directory.Build.props`.
.PARAMETER Version
    Versão explícita; tem precedência (o CI passa a da tag `prod-vX.Y.Z`).
.OUTPUTS
    Versão.
#>
function Resolve-VersaoDoPacote {
    param(
        [Parameter(Mandatory)] [string] $Fonte,
        [string] $Version = ''
    )

    if ($Version) { return $Version }

    $props = Join-Path $Fonte 'Directory.Build.props'
    if (Test-Path $props) {
        $xml = [xml](Get-Content $props -Raw)
        $prefix = $xml.Project.PropertyGroup.VersionPrefix | Where-Object { $_ } | Select-Object -First 1
        if ($prefix) { return [string]$prefix }
    }

    throw 'Nao foi possivel resolver a versao: informe -Version ou verifique Directory.Build.props.'
}

<#
.SYNOPSIS
    Grava `<Arquivo>.sha256` no formato do `sha256sum` e devolve o hash.

.DESCRIPTION
    O pacote não é assinado por CA pública (D6 do PRD-TEFINST-00): o hash é a única prova de
    integridade que a TI tem antes de instalar, e só imprimi-lo no console fazia ele se perder
    junto com o log. Formato `<hash>  <nome>` + LF, sem BOM — o que `sha256sum -c` e o
    `Get-FileHash` comparado à mão aceitam igualmente.

.PARAMETER Arquivo
    Arquivo a resumir.
.OUTPUTS
    Hash SHA-256 em minúsculas.
#>
function Write-ArquivoSha256 {
    param([Parameter(Mandatory)] [string] $Arquivo)

    $caminho = (Resolve-Path $Arquivo).Path
    $hash = (Get-FileHash -Path $caminho -Algorithm SHA256).Hash.ToLowerInvariant()
    $linha = "$hash  $(Split-Path $caminho -Leaf)`n"
    [System.IO.File]::WriteAllText("$caminho.sha256", $linha, (New-Object System.Text.UTF8Encoding $false))
    return $hash
}

<#
.SYNOPSIS
    Confere `<Arquivo>` contra o seu `<Arquivo>.sha256`.
.DESCRIPTION
    Recalcula o hash: o `.sha256` não é confiável por si — ele só prova algo se bater com o binário
    e se nomear o mesmo arquivo.
.PARAMETER Arquivo
    Arquivo a conferir.
.OUTPUTS
    `$true` quando o hash e o nome conferem.
#>
function Test-ArquivoSha256 {
    param([Parameter(Mandatory)] [string] $Arquivo)

    $declarado = "$Arquivo.sha256"
    if (-not (Test-Path $Arquivo) -or -not (Test-Path $declarado)) { return $false }

    $partes = (Get-Content $declarado -Raw).Trim() -split '\s+', 2
    if ($partes.Count -ne 2) { return $false }

    $nome = $partes[1].TrimStart('*')
    if ($nome -ne (Split-Path $Arquivo -Leaf)) { return $false }

    $calculado = (Get-FileHash -Path $Arquivo -Algorithm SHA256).Hash.ToLowerInvariant()
    return $partes[0].ToLowerInvariant() -eq $calculado
}

<#
.SYNOPSIS
    Resolve um payload de terceiro (UM `.exe` + arquivo de hash), confere o SHA-256 e o copia para a
    pasta que o `.iss` da fonte pinada referencia.
.DESCRIPTION
    Binário de terceiro redistribuído no pacote não é versionado (fica no `.gitignore` da pasta), então
    a integridade passa a ser do BUILD: o hash declarado precisa bater com o binário e nomear o mesmo
    arquivo, senão o build falha. Sem pasta ou sem `.exe`, devolve vazio com aviso — o instalador sai
    sem aquele componente (cenário legítimo) — ou, com `-Obrigatorio`, LANÇA: componente obrigatório
    ausente é pacote incompleto (o driver da Bematech desde PRD-PMTRAY-02). Mais de um `.exe` é ambíguo e
    lança sempre.
.PARAMETER PayloadDir
    Pasta de onde o binário é lido.
.PARAMETER ArquivoHash
    Nome do arquivo de hash dentro de `PayloadDir` (formato sha256sum: `<hash>  <nome>`).
.PARAMETER Destino
    Pasta (na fonte pinada) para onde o binário conferido é copiado.
.PARAMETER Descricao
    Nome do componente nas mensagens.
.PARAMETER Obrigatorio
    Sem pasta ou sem `.exe`, falha o build em vez de devolver vazio.
.OUTPUTS
    Nome do arquivo do payload, ou vazio quando não há payload (só sem `-Obrigatorio`).
#>
function Resolve-PayloadVerificado {
    param(
        [Parameter(Mandatory)] [string] $PayloadDir,
        [Parameter(Mandatory)] [string] $ArquivoHash,
        [Parameter(Mandatory)] [string] $Destino,
        [Parameter(Mandatory)] [string] $Descricao,
        [switch] $Obrigatorio
    )

    if (-not (Test-Path $PayloadDir)) {
        if ($Obrigatorio) {
            throw "$PayloadDir ausente: $Descricao é obrigatório e o pacote não sai sem ele."
        }
        Write-Host "  $PayloadDir ausente — o instalador sairá sem $Descricao." -ForegroundColor Yellow
        return ''
    }

    $arquivos = @(Get-ChildItem -Path $PayloadDir -Filter '*.exe' -File)
    if ($arquivos.Count -eq 0) {
        if ($Obrigatorio) {
            throw "Nenhum .exe em ${PayloadDir}: $Descricao é obrigatório e o pacote não sai sem ele."
        }
        Write-Host "  Nenhum .exe em $PayloadDir — o instalador sairá sem $Descricao." -ForegroundColor Yellow
        return ''
    }

    if ($arquivos.Count -gt 1) {
        throw "O payload de $Descricao tem $($arquivos.Count) executáveis em $PayloadDir; deixe apenas um."
    }

    $payload = $arquivos[0]
    $sha = (Get-FileHash -Path $payload.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashFile = Join-Path $PayloadDir $ArquivoHash

    if (-not (Test-Path $hashFile)) {
        throw @"
$hashFile não existe.

Crie-o com o hash de $Descricao que você conferiu na origem oficial:

    $sha  $($payload.Name)

Sem esse arquivo o build aceitaria qualquer binário largado no payload.
"@
    }

    $partes = (Get-Content $hashFile -Raw).Trim() -split '\s+', 2
    $declarado = $partes[0].ToLowerInvariant()
    if ($partes.Count -eq 2 -and $partes[1].TrimStart('*') -ne $payload.Name) {
        throw "O $ArquivoHash de $Descricao nomeia '$($partes[1])', mas o binário é '$($payload.Name)'."
    }

    if ($declarado -ne $sha) {
        throw "Hash do payload de $Descricao divergente.`n  declarado: $declarado`n  calculado: $sha"
    }

    $alvo = Join-Path $Destino $payload.Name
    if ([System.IO.Path]::GetFullPath($payload.FullName) -ne [System.IO.Path]::GetFullPath($alvo)) {
        New-Item -ItemType Directory -Path $Destino -Force | Out-Null
        Copy-Item -Path $payload.FullName -Destination $alvo -Force
    }

    Write-Host "  payload de ${Descricao}: $($payload.Name) (SHA-256 conferido)" -ForegroundColor DarkGray
    return $payload.Name
}

<#
.SYNOPSIS
    Confere uma pasta de payload de terceiro para o DIAGNÓSTICO do runner, sem lançar.
.DESCRIPTION
    Mesma régua do `Resolve-PayloadVerificado` (pasta existe, um único `.exe`, arquivo de hash presente,
    nomeando o binário certo, hash que confere), mas **relatando em vez de abortar**: o diagnóstico
    precisa listar todas as verificações e decidir o código de saída no fim, então uma exceção aqui
    esconderia tudo o que vem depois.

    Vive no módulo, e não dentro do script, porque é comportamento com desfecho — e aqui ele é coberto
    pelo Pester que o job `testar-scripts` já roda (PRD-INSTDEV-04).
.PARAMETER PayloadDir
    Pasta do payload. Vazia ou inexistente é tratada como ausente.
.PARAMETER ArquivoHash
    Nome do arquivo de hash esperado (`payload.sha256`, `driver.sha256`).
.PARAMETER Descricao
    Como o componente é chamado nas mensagens (ex.: `o QZ Tray`).
.PARAMETER Variavel
    Variável de repositório que aponta a pasta no CI, citada quando ela não está definida.
.PARAMETER EstadoSeAusente
    `AVISO` ou `FALHA` — o que vale quando a pasta/binário não existe. O CI exige (`FALHA`); na máquina
    do dev que só vai empacotar o TEF, ausente é `AVISO`.
.PARAMETER EfeitoSeAusente
    O que acontece com o build sem este payload. O QZ sai do pacote; o driver **reprova o build**
    (`-Obrigatorio`, PRD-PMTRAY-02) — a diferença precisa aparecer na tela, senão os dois parecem
    igualmente dispensáveis.
.OUTPUTS
    `[pscustomobject]` com `Estado` (OK/AVISO/FALHA) e `Detalhe`.
#>
function Test-PayloadDoRunner {
    param(
        [AllowEmptyString()] [string] $PayloadDir,
        [Parameter(Mandatory)] [string] $ArquivoHash,
        [Parameter(Mandatory)] [string] $Descricao,
        [Parameter(Mandatory)] [string] $Variavel,
        [ValidateSet('AVISO', 'FALHA')] [string] $EstadoSeAusente = 'AVISO',
        [string] $EfeitoSeAusente = ''
    )

    $sufixo = if ($EfeitoSeAusente) { " $EfeitoSeAusente" } else { '' }

    if (-not $PayloadDir) {
        return [pscustomobject]@{ Estado = $EstadoSeAusente; Detalhe = "$Variavel não definido (variável de repositório).$sufixo" }
    }
    if (-not (Test-Path $PayloadDir)) {
        return [pscustomobject]@{ Estado = $EstadoSeAusente; Detalhe = "'$PayloadDir' não existe (ou a conta em execução não lê a pasta).$sufixo" }
    }

    $exes = @(Get-ChildItem -Path $PayloadDir -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 0) {
        return [pscustomobject]@{ Estado = $EstadoSeAusente; Detalhe = "nenhum .exe em '$PayloadDir'.$sufixo" }
    }
    # Mais de um binário NÃO é "ausente": é ambiguidade, e o build lança em qualquer modo.
    if ($exes.Count -gt 1) {
        return [pscustomobject]@{ Estado = 'FALHA'; Detalhe = "'$PayloadDir' tem $($exes.Count) executáveis; deixe exatamente o instalador de $Descricao." }
    }

    $hashFile = Join-Path $PayloadDir $ArquivoHash
    if (-not (Test-Path $hashFile)) {
        return [pscustomobject]@{ Estado = 'FALHA'; Detalhe = "falta $ArquivoHash em '$PayloadDir'." }
    }

    $partes = (Get-Content $hashFile -Raw).Trim() -split '\s+', 2
    $declarado = $partes[0].ToLowerInvariant()
    if ($partes.Count -eq 2 -and $partes[1].TrimStart('*') -ne $exes[0].Name) {
        return [pscustomobject]@{ Estado = 'FALHA'; Detalhe = "$ArquivoHash nomeia '$($partes[1])', mas o binário é '$($exes[0].Name)'." }
    }

    $calculado = (Get-FileHash -Path $exes[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($declarado -ne $calculado) {
        return [pscustomobject]@{ Estado = 'FALHA'; Detalhe = "hash divergente em $($exes[0].Name): declarado $declarado, calculado $calculado." }
    }

    return [pscustomobject]@{ Estado = 'OK'; Detalhe = "$($exes[0].Name) — SHA-256 $calculado confere." }
}

<#
.SYNOPSIS
    Normaliza uma lista de origens do navegador para embutir como default num instalador (`/D` do ISCC).
.DESCRIPTION
    Espelha `NormalizarOrigem` do `pages.iss` do PrintMonitor e `SetupParameters.NormalizarOrigem`: aceita
    `http(s)://servidor[:porta]`, em minúsculas e sem barra final; recusa caminho, consulta, fragmento,
    credencial e curinga. Validar aqui, no build, é o que impede um default inválido de virar instalador
    que bloqueia TODA estação logo na abertura (o `.iss` valida as origens no InitializeSetup).
.PARAMETER Origens
    Lista separada por vírgula, ponto e vírgula ou espaço. Vazia devolve vazio (instalador sem default).
.OUTPUTS
    As origens normalizadas, separadas por vírgula.
#>
function ConvertTo-ListaDeOrigens {
    param([AllowEmptyString()] [string] $Origens)

    $normalizadas = foreach ($item in ($Origens -split '[,;\s]+' | Where-Object { $_ })) {
        $valor = $item.Trim().ToLowerInvariant().TrimEnd('/')
        if ($valor -notmatch '^https?://[^/?#@*\s]+$') {
            throw ("Origem inválida: '$item'. Informe a origem exata do front-adm (esquema, servidor e porta, " +
                'sem caminho e sem curinga), ex.: https://admin.exemplo.com.br')
        }
        $valor
    }

    return (@($normalizadas) -join ',')
}

<#
.SYNOPSIS
    Divide um arquivo em partes numeradas `<arquivo>.001`, `.002`… de no máximo `TamanhoParte` bytes.
.DESCRIPTION
    O GitHub recusa no push qualquer arquivo acima de 100 MiB, e o instalador do PrintMonitor (QZ Tray
    com JRE + driver Bematech embutidos) passa disso. Versionar em partes evita a cota do Git LFS;
    remontar é concatenar na ordem (`Join-PartesDoArquivo`, ou `copy /b` no cmd).

    Partes de uma divisão anterior do mesmo arquivo são apagadas antes: uma `.003` que sobrasse de um
    pacote maior seria concatenada na montagem e corromperia o instalador.
.PARAMETER Arquivo
    Arquivo a dividir. Não é alterado.
.PARAMETER TamanhoParte
    Tamanho máximo de cada parte, em bytes. Padrão: 90 MiB — folga sob o limite de 100 MiB.
.OUTPUTS
    Caminhos das partes, em ordem.
#>
function Split-ArquivoEmPartes {
    param(
        [Parameter(Mandatory)] [string] $Arquivo,
        [long] $TamanhoParte = 90MB
    )

    if ($TamanhoParte -le 0) { throw "TamanhoParte invalido: $TamanhoParte." }
    $caminho = (Resolve-Path $Arquivo).Path
    $pasta = Split-Path $caminho -Parent
    $nome = Split-Path $caminho -Leaf

    Get-ChildItem -Path $pasta -File | Where-Object { $_.Name -match ('^' + [regex]::Escape($nome) + '\.\d{3}$') } |
        Remove-Item -Force

    $partes = New-Object System.Collections.Generic.List[string]
    $buffer = New-Object byte[] (4MB)
    $origem = [System.IO.File]::OpenRead($caminho)
    try {
        $indice = 0
        while ($origem.Position -lt $origem.Length) {
            $indice++
            if ($indice -gt 999) { throw "Arquivo grande demais para $TamanhoParte bytes por parte (mais de 999 partes)." }
            $destino = Join-Path $pasta ('{0}.{1:D3}' -f $nome, $indice)
            $saida = [System.IO.File]::Create($destino)
            try {
                $restante = $TamanhoParte
                while ($restante -gt 0) {
                    $lidos = $origem.Read($buffer, 0, [int][Math]::Min([long]$buffer.Length, $restante))
                    if ($lidos -le 0) { break }
                    $saida.Write($buffer, 0, $lidos)
                    $restante -= $lidos
                }
            }
            finally { $saida.Dispose() }
            $partes.Add($destino)
        }
    }
    finally { $origem.Dispose() }

    return $partes.ToArray()
}

<#
.SYNOPSIS
    Remonta `<Arquivo>` concatenando `<Arquivo>.001`, `.002`… na ordem.
.DESCRIPTION
    Exige a sequência contígua a partir de `.001`: parte faltando no meio produziria um instalador
    truncado que só falha na estação. Não confere hash — quem chama confere com `Test-ArquivoSha256`,
    porque o `.sha256` é do arquivo inteiro, não das partes.
.PARAMETER Arquivo
    Caminho do arquivo a produzir; as partes ficam ao lado dele. Sobrescrito se existir.
.OUTPUTS
    Caminho do arquivo remontado.
#>
function Join-PartesDoArquivo {
    param([Parameter(Mandatory)] [string] $Arquivo)

    $pasta = Split-Path $Arquivo -Parent
    if (-not $pasta) { $pasta = (Get-Location).Path }
    $pasta = (Resolve-Path $pasta).Path
    $nome = Split-Path $Arquivo -Leaf
    $destino = Join-Path $pasta $nome

    $partes = @(Get-ChildItem -Path $pasta -File |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($nome) + '\.\d{3}$') } |
        Sort-Object Name)
    if ($partes.Count -eq 0) { throw "Nenhuma parte de $nome encontrada em $pasta ($nome.001...)." }

    for ($i = 0; $i -lt $partes.Count; $i++) {
        $esperado = '{0}.{1:D3}' -f $nome, ($i + 1)
        if ($partes[$i].Name -ne $esperado) { throw "Parte ausente: $esperado. As partes precisam ser contiguas a partir de .001." }
    }

    $saida = [System.IO.File]::Create($destino)
    try {
        foreach ($parte in $partes) {
            $entrada = [System.IO.File]::OpenRead($parte.FullName)
            try { $entrada.CopyTo($saida) } finally { $entrada.Dispose() }
        }
    }
    finally { $saida.Dispose() }

    return $destino
}

<#
.SYNOPSIS
    Empacota o instalador num `.zip` — com o `.sha256` dentro — dividido em `<base>.zip.001`, `.002`… de no
    máximo `TamanhoParte` bytes: o formato do pacote versionado no git.
.DESCRIPTION
    O zip leva o hash junto do binário (quem recebe só as partes ainda confere o instalador) e o CRC de cada
    entrada; as partes seguem a convenção que o 7-Zip abre direto pela `.001` e que `copy /b` remonta. O
    `.exe` é LZMA do Inno, então o zip quase não encolhe: o ganho é o formato, não o tamanho.

    Partes cruas do formato anterior do mesmo instalador (`<instalador>.001`…) são apagadas — duas formas do
    mesmo pacote lado a lado confundem quem remonta. O `.zip` inteiro é intermediário e não fica na pasta.
.PARAMETER Instalador
    `.exe` já hasheado por `Write-ArquivoSha256`; sem `<instalador>.sha256` que confira, lança.
.PARAMETER TamanhoParte
    Tamanho máximo de cada parte, em bytes. Padrão: 90 MiB.
.OUTPUTS
    Caminhos das partes, em ordem.
#>
function New-PacoteZipEmPartes {
    param(
        [Parameter(Mandatory)] [string] $Instalador,
        [long] $TamanhoParte = 90MB
    )

    $caminho = (Resolve-Path $Instalador).Path
    if (-not (Test-ArquivoSha256 -Arquivo $caminho)) {
        throw "Sem $(Split-Path $caminho -Leaf).sha256 que confira: o pacote em zip leva o hash do instalador."
    }

    $pasta = Split-Path $caminho -Parent
    $nome = Split-Path $caminho -Leaf
    $zip = Join-Path $pasta ([System.IO.Path]::GetFileNameWithoutExtension($caminho) + '.zip')

    Get-ChildItem -Path $pasta -File | Where-Object { $_.Name -match ('^' + [regex]::Escape($nome) + '\.\d{3}$') } |
        Remove-Item -Force

    # Windows PowerShell 5.1 não carrega as APIs de zip sozinho.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $arquivoZip = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in @($caminho, "$caminho.sha256")) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $arquivoZip, $item, (Split-Path $item -Leaf), [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally { $arquivoZip.Dispose() }

    try { return @(Split-ArquivoEmPartes -Arquivo $zip -TamanhoParte $TamanhoParte) }
    finally { Remove-Item $zip -Force }
}

<#
.SYNOPSIS
    Remonta `<Pacote>` (o `.zip`) a partir de `.001`, `.002`… e extrai o instalador e o `.sha256` ao lado.
.DESCRIPTION
    Só aceita entradas na raiz do zip: caminho com pasta (ou `..`) é pacote que não saiu de
    `New-PacoteZipEmPartes` e não é extraído. Não confere hash — quem chama confere com `Test-ArquivoSha256`.
    O `.zip` remontado é intermediário e é apagado.
.PARAMETER Pacote
    Caminho do `.zip`; as partes ficam ao lado dele.
.OUTPUTS
    Caminho do `.exe` extraído.
#>
function Expand-PacoteZipEmPartes {
    param([Parameter(Mandatory)] [string] $Pacote)

    $zip = Join-PartesDoArquivo -Arquivo $Pacote
    $pasta = Split-Path $zip -Parent

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $extraidos = New-Object System.Collections.Generic.List[string]
    $arquivoZip = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entrada in $arquivoZip.Entries) {
            if (-not $entrada.Name -or $entrada.FullName -ne $entrada.Name) {
                throw "Entrada inesperada no pacote: '$($entrada.FullName)'. O pacote só leva arquivos na raiz."
            }
            $destino = Join-Path $pasta $entrada.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entrada, $destino, $true)
            $extraidos.Add($destino)
        }
    }
    finally {
        $arquivoZip.Dispose()
        Remove-Item $zip -Force
    }

    $instaladores = @($extraidos | Where-Object { $_ -like '*.exe' })
    if ($instaladores.Count -ne 1) {
        throw "O pacote deveria ter exatamente um .exe; tem $($instaladores.Count)."
    }

    return $instaladores[0]
}

Export-ModuleMember -Function @(
    'Split-ArquivoEmPartes',
    'Join-PartesDoArquivo',
    'New-PacoteZipEmPartes',
    'Expand-PacoteZipEmPartes',
    'ConvertTo-ListaDeOrigens',
    'Resolve-PayloadVerificado',
    'Test-PayloadDoRunner',
    'Invoke-GitEmpacotamento',
    'Resolve-IsccExecutavel',
    'Resolve-RaizDoBackend',
    'Get-ProcedenciaDosScripts',
    'Resolve-FonteDoPacote',
    'Remove-WorktreeDoPacote',
    'Assert-FonteCompleta',
    'Resolve-VersaoDoPacote',
    'Write-ArquivoSha256',
    'Test-ArquivoSha256'
)
