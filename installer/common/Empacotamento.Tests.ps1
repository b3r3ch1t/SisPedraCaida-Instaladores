<#
.SYNOPSIS
    Testes do núcleo comum de empacotamento (installer/common/Empacotamento.psm1) — PRD-INSTPROD-05.

.DESCRIPTION
    Rodam no Pester 3.4 (o que vem com o Windows, inclusive no runner dos instaladores) e no Pester 5,
    por isso NÃO usam `Should`: a sintaxe mudou entre as versões (`Should Be` × `Should -Be`) e nenhuma
    das duas funciona nas duas. As asserções são `Confirmar`, definida abaixo, que lança com a
    mensagem — o Pester trata qualquer exceção dentro do `It` como falha.

    Execução: `pwsh installer/common/Invoke-TestesEmpacotamento.ps1` (escolhe a chamada certa para a
    versão do Pester instalada e devolve código ≠ 0 em falha).

    Nada de código fora de `BeforeAll`/`It`: no Pester 5 isso rodaria na fase de descoberta.
#>

Describe 'Empacotamento.psm1' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Empacotamento.psm1') -Force

        function Confirmar {
            param([bool] $Condicao, [string] $Mensagem)
            if (-not $Condicao) { throw "Falhou: $Mensagem" }
        }

        function Confirmar-Lanca {
            param([scriptblock] $Bloco, [string] $Trecho)
            $mensagem = $null
            try { & $Bloco } catch { $mensagem = $_.Exception.Message }
            if ($null -eq $mensagem) { throw "Falhou: esperava exceção contendo '$Trecho', nada foi lançado." }
            if ($Trecho -and $mensagem -notlike "*$Trecho*") { throw "Falhou: exceção '$mensagem' sem '$Trecho'." }
        }

        # Repositório git descartável com dois commits, para o pino em worktree.
        function Novo-RepositorioDeTeste {
            param([string] $Caminho)
            New-Item -ItemType Directory -Path $Caminho -Force | Out-Null
            & git -C $Caminho init --quiet 2>&1 | Out-Null
            Set-Content -Path (Join-Path $Caminho 'versao.txt') -Value 'um' -Encoding ascii
            & git -C $Caminho add -A 2>&1 | Out-Null
            & git -C $Caminho -c user.name=teste -c user.email=teste@local commit --quiet -m 'um' 2>&1 | Out-Null
            $primeiro = (& git -C $Caminho rev-parse HEAD).Trim()
            Set-Content -Path (Join-Path $Caminho 'versao.txt') -Value 'dois' -Encoding ascii
            & git -C $Caminho -c user.name=teste -c user.email=teste@local commit --quiet -am 'dois' 2>&1 | Out-Null
            $segundo = (& git -C $Caminho rev-parse HEAD).Trim()
            return [pscustomobject]@{ Caminho = $Caminho; Primeiro = $primeiro; Segundo = $segundo }
        }
    }

    Context 'Write-ArquivoSha256 / Test-ArquivoSha256' {

        BeforeAll {
            $pasta = Join-Path $TestDrive 'sha'
            New-Item -ItemType Directory -Path $pasta -Force | Out-Null
            $arquivo = Join-Path $pasta 'Pacote-1.2.3.exe'
            [System.IO.File]::WriteAllBytes($arquivo, [byte[]](1..200))
        }

        It 'grava <hash>  <nome> + LF, sem BOM, e devolve o mesmo hash do Get-FileHash' {
            $hash = Write-ArquivoSha256 -Arquivo $arquivo
            $esperado = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash.ToLowerInvariant()
            $bytes = [System.IO.File]::ReadAllBytes("$arquivo.sha256")
            $texto = [System.Text.Encoding]::ASCII.GetString($bytes)

            Confirmar ($hash -eq $esperado) "hash devolvido $hash <> $esperado"
            Confirmar ($texto -eq "$esperado  Pacote-1.2.3.exe`n") "conteúdo '$texto' fora do formato sha256sum"
            Confirmar ($bytes[0] -ne 0xEF) 'o .sha256 começa com BOM'
        }

        It 'confere o par íntegro' {
            Write-ArquivoSha256 -Arquivo $arquivo | Out-Null
            Confirmar (Test-ArquivoSha256 -Arquivo $arquivo) 'par íntegro reprovado'
        }

        It 'aceita o marcador de modo binário (*nome) do sha256sum' {
            $hash = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash.ToLowerInvariant()
            Set-Content -Path "$arquivo.sha256" -Value "$hash *Pacote-1.2.3.exe" -Encoding ascii
            Confirmar (Test-ArquivoSha256 -Arquivo $arquivo) 'marcador * reprovado'
        }

        It 'reprova hash adulterado' {
            Set-Content -Path "$arquivo.sha256" -Value ('0' * 64 + '  Pacote-1.2.3.exe') -Encoding ascii
            Confirmar (-not (Test-ArquivoSha256 -Arquivo $arquivo)) 'hash adulterado aprovado'
        }

        It 'reprova .sha256 que nomeia outro arquivo, mesmo com o hash certo' {
            $hash = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash.ToLowerInvariant()
            Set-Content -Path "$arquivo.sha256" -Value "$hash  Outro-1.2.3.exe" -Encoding ascii
            Confirmar (-not (Test-ArquivoSha256 -Arquivo $arquivo)) 'nome divergente aprovado'
        }

        It 'reprova quando o .sha256 não existe' {
            Remove-Item "$arquivo.sha256" -ErrorAction SilentlyContinue
            Confirmar (-not (Test-ArquivoSha256 -Arquivo $arquivo)) 'ausência do .sha256 aprovada'
        }
    }

    Context 'Resolve-VersaoDoPacote' {

        It 'a versão informada vence o Directory.Build.props' {
            Confirmar ((Resolve-VersaoDoPacote -Fonte $TestDrive -Version '9.8.7') -eq '9.8.7') 'versão informada ignorada'
        }

        It 'lê o VersionPrefix do Directory.Build.props da fonte' {
            $fonte = Join-Path $TestDrive 'props'
            New-Item -ItemType Directory -Path $fonte -Force | Out-Null
            Set-Content -Path (Join-Path $fonte 'Directory.Build.props') -Encoding ascii -Value `
                '<Project><PropertyGroup><VersionPrefix>2.6.0</VersionPrefix></PropertyGroup></Project>'
            Confirmar ((Resolve-VersaoDoPacote -Fonte $fonte) -eq '2.6.0') 'VersionPrefix não lido'
        }

        It 'lança quando não há versão em lugar nenhum' {
            $vazia = Join-Path $TestDrive 'sem-props'
            New-Item -ItemType Directory -Path $vazia -Force | Out-Null
            Confirmar-Lanca { Resolve-VersaoDoPacote -Fonte $vazia } 'versao'
        }
    }

    Context 'Assert-FonteCompleta' {

        BeforeAll {
            $fonte = Join-Path $TestDrive 'cadeia'
            New-Item -ItemType Directory -Path (Join-Path $fonte 'installer') -Force | Out-Null
            Set-Content -Path (Join-Path (Join-Path $fonte 'installer') 'A.iss') -Value ';' -Encoding ascii
        }

        It 'passa calada com a cadeia inteira' {
            Assert-FonteCompleta -Fonte $fonte -Descricao 'A fonte' -Agente 'agente X' -Exigidos @('installer/A.iss')
        }

        It 'lista o que falta e diz de qual agente é' {
            Confirmar-Lanca {
                Assert-FonteCompleta -Fonte $fonte -Descricao 'A referencia prod' -Agente 'agente X' `
                    -Exigidos @('installer/A.iss', 'scripts/publica.ps1')
            } 'scripts/publica.ps1'
            Confirmar-Lanca {
                Assert-FonteCompleta -Fonte $fonte -Descricao 'A referencia prod' -Agente 'agente X' -Exigidos @('nada.txt')
            } 'agente X'
        }
    }

    Context 'Resolve-IsccExecutavel' {

        BeforeAll {
            $salvo = @{
                X86   = ${env:ProgramFiles(x86)}
                Pf    = $env:ProgramFiles
                Local = $env:LOCALAPPDATA
            }
        }

        AfterAll {
            ${env:ProgramFiles(x86)} = $salvo.X86
            $env:ProgramFiles = $salvo.Pf
            $env:LOCALAPPDATA = $salvo.Local
        }

        It 'devolve o caminho informado quando ele existe' {
            $falso = Join-Path $TestDrive 'ISCC-informado.exe'
            Set-Content -Path $falso -Value 'x' -Encoding ascii
            Confirmar ((Resolve-IsccExecutavel -IsccPath $falso) -eq $falso) 'caminho informado não devolvido'
        }

        It 'lança quando o caminho informado não existe' {
            Confirmar-Lanca { Resolve-IsccExecutavel -IsccPath (Join-Path $TestDrive 'nao-existe.exe') } 'nao encontrado'
        }

        # Regressão do defeito que o build-installer do PrintMonitor ainda tinha: com UM candidato o
        # pipeline devolvia string, e o [0] pegava o primeiro CARACTERE do caminho ("C").
        It 'com um único candidato devolve o caminho inteiro, não o primeiro caractere' {
            $raiz = Join-Path $TestDrive 'iscc-unico'
            $vazio = Join-Path $raiz 'vazio'
            $local = Join-Path $raiz 'local'
            New-Item -ItemType Directory -Path $vazio -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $local 'Programs\Inno Setup 6') -Force | Out-Null
            $iscc = Join-Path $local 'Programs\Inno Setup 6\ISCC.exe'
            Set-Content -Path $iscc -Value 'x' -Encoding ascii

            ${env:ProgramFiles(x86)} = $vazio
            $env:ProgramFiles = $vazio
            $env:LOCALAPPDATA = $local

            $resolvido = Resolve-IsccExecutavel
            Confirmar ($resolvido -eq $iscc) "resolvido '$resolvido' <> '$iscc'"
        }

        It 'sem candidato lança com a instrução de instalação' {
            $vazio = Join-Path $TestDrive 'iscc-nenhum'
            New-Item -ItemType Directory -Path $vazio -Force | Out-Null
            ${env:ProgramFiles(x86)} = $vazio
            $env:ProgramFiles = $vazio
            $env:LOCALAPPDATA = $vazio
            Confirmar-Lanca { Resolve-IsccExecutavel } 'winget install'
        }
    }

    Context 'Resolve-FonteDoPacote / Remove-WorktreeDoPacote' {

        BeforeAll {
            $repo = Novo-RepositorioDeTeste -Caminho (Join-Path $TestDrive 'repo')
        }

        It '-UseWorkingTree devolve a árvore aberta, sem commit' {
            $origem = Resolve-FonteDoPacote -RepoRoot $repo.Caminho -UseWorkingTree
            Confirmar ($origem.Caminho -eq $repo.Caminho) "caminho '$($origem.Caminho)'"
            Confirmar ($origem.Commit -eq '') 'árvore aberta com commit'
        }

        It 'sem -WorktreeDir (e sem -UseWorkingTree) lança' {
            Confirmar-Lanca { Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref $repo.Primeiro -SkipFetch } 'WorktreeDir'
        }

        It 'pina o worktree no commit pedido, não no HEAD do repositório' {
            $wt = Join-Path $TestDrive 'wt-pino'
            $origem = Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref $repo.Primeiro -WorktreeDir $wt -SkipFetch
            $conteudo = (Get-Content (Join-Path $wt 'versao.txt') -Raw).Trim()

            Confirmar ($origem.Commit -eq $repo.Primeiro) "commit $($origem.Commit)"
            Confirmar ($conteudo -eq 'um') "worktree com '$conteudo' (esperava o primeiro commit)"
            Confirmar ($origem.Descricao -like '*' + $repo.Primeiro.Substring(0, 8) + '*') "descrição '$($origem.Descricao)'"
        }

        It 'reaproveita o worktree trocando de commit e limpando o resto da execução anterior' {
            $wt = Join-Path $TestDrive 'wt-reuso'
            Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref $repo.Primeiro -WorktreeDir $wt -SkipFetch | Out-Null
            Set-Content -Path (Join-Path $wt 'sobra.tmp') -Value 'lixo' -Encoding ascii

            Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref $repo.Segundo -WorktreeDir $wt -SkipFetch | Out-Null

            Confirmar ((Get-Content (Join-Path $wt 'versao.txt') -Raw).Trim() -eq 'dois') 'não trocou de commit'
            Confirmar (-not (Test-Path (Join-Path $wt 'sobra.tmp'))) 'sobra da execução anterior seria empacotada'
        }

        It 'dois worktrees convivem em commits diferentes sem tocar o checkout principal' {
            $a = Join-Path $TestDrive 'wt-a'
            $b = Join-Path $TestDrive 'wt-b'
            Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref $repo.Primeiro -WorktreeDir $a -SkipFetch | Out-Null
            Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref $repo.Segundo -WorktreeDir $b -SkipFetch | Out-Null

            Confirmar ((Get-Content (Join-Path $a 'versao.txt') -Raw).Trim() -eq 'um') 'worktree A mudou'
            Confirmar ((Get-Content (Join-Path $b 'versao.txt') -Raw).Trim() -eq 'dois') 'worktree B mudou'
            $status = (& git -C $repo.Caminho status --porcelain) -join ''
            Confirmar ($status -eq '') "checkout principal sujo: '$status'"
        }

        It 'referência inexistente lança orientando -Ref/-UseWorkingTree' {
            Confirmar-Lanca {
                Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref 'nao-existe' -WorktreeDir (Join-Path $TestDrive 'wt-x') -SkipFetch
            } 'nao encontrada'
        }

        It 'Remove-WorktreeDoPacote apaga o diretório e a entrada do git' {
            $wt = Join-Path $TestDrive 'wt-remover'
            Resolve-FonteDoPacote -RepoRoot $repo.Caminho -Ref $repo.Primeiro -WorktreeDir $wt -SkipFetch | Out-Null

            Remove-WorktreeDoPacote -RepoRoot $repo.Caminho -WorktreeDir $wt

            Confirmar (-not (Test-Path $wt)) 'diretório do worktree sobrou'
            $lista = (& git -C $repo.Caminho worktree list) -join "`n"
            Confirmar ($lista -notlike '*wt-remover*') "git ainda lista o worktree: $lista"
        }

        It 'Remove-WorktreeDoPacote em diretório ausente não lança' {
            Remove-WorktreeDoPacote -RepoRoot $repo.Caminho -WorktreeDir (Join-Path $TestDrive 'nunca-existiu')
        }
    }

    Context 'Resolve-RaizDoBackend / Get-ProcedenciaDosScripts' {

        BeforeAll {
            # Workspace descartável: <ws>/SisPedraCaida-Instaladores ao lado de <ws>/SisPedraCaida-Backend.
            function Novo-Backend {
                param([string] $Caminho)
                $repo = Novo-RepositorioDeTeste -Caminho $Caminho
                Set-Content -Path (Join-Path $Caminho 'SisPedraCaida.slnx') -Value '<Solution />' -Encoding ascii
                return $repo
            }

            $ws = Join-Path $TestDrive 'ws'
            $instaladores = Join-Path $ws 'SisPedraCaida-Instaladores'
            New-Item -ItemType Directory -Path $instaladores -Force | Out-Null
            $irmao = Join-Path $ws 'SisPedraCaida-Backend'
            Novo-Backend -Caminho $irmao | Out-Null
            $envAnterior = $env:SISPEDRACAIDA_BACKEND
        }

        AfterEach {
            $env:SISPEDRACAIDA_BACKEND = $envAnterior
            $doCi = Join-Path $instaladores 'backend'
            if (Test-Path $doCi) { Remove-Item $doCi -Recurse -Force }
        }

        It 'sem nada informado, acha o repositório irmão do workspace' {
            $env:SISPEDRACAIDA_BACKEND = ''
            $raiz = Resolve-RaizDoBackend -RepoRoot $instaladores
            Confirmar ($raiz -eq (Resolve-Path $irmao).Path) "raiz '$raiz'"
        }

        It 'o checkout do CI em backend/ vence o repositório irmão' {
            $env:SISPEDRACAIDA_BACKEND = ''
            $doCi = Join-Path $instaladores 'backend'
            Novo-Backend -Caminho $doCi | Out-Null
            $raiz = Resolve-RaizDoBackend -RepoRoot $instaladores
            Confirmar ($raiz -eq (Resolve-Path $doCi).Path) "raiz '$raiz'"
        }

        It '-BackendRoot e SISPEDRACAIDA_BACKEND vencem a descoberta' {
            $outro = Join-Path $TestDrive 'outro-backend'
            Novo-Backend -Caminho $outro | Out-Null
            $env:SISPEDRACAIDA_BACKEND = $outro
            Confirmar ((Resolve-RaizDoBackend -RepoRoot $instaladores) -eq (Resolve-Path $outro).Path) 'variável ignorada'
            $env:SISPEDRACAIDA_BACKEND = ''
            Confirmar ((Resolve-RaizDoBackend -RepoRoot $instaladores -BackendRoot $outro) -eq (Resolve-Path $outro).Path) 'parâmetro ignorado'
        }

        It 'caminho explícito que não é o backend lança em vez de cair no próximo candidato' {
            $env:SISPEDRACAIDA_BACKEND = ''
            $falso = Join-Path $TestDrive 'nao-e-backend'
            New-Item -ItemType Directory -Path $falso -Force | Out-Null
            Confirmar-Lanca { Resolve-RaizDoBackend -RepoRoot $instaladores -BackendRoot $falso } 'nao e um clone'
        }

        It 'sem backend em lugar nenhum lança listando onde procurou' {
            $env:SISPEDRACAIDA_BACKEND = ''
            $sozinho = Join-Path (Join-Path $TestDrive 'ws-vazio') 'SisPedraCaida-Instaladores'
            New-Item -ItemType Directory -Path $sozinho -Force | Out-Null
            Confirmar-Lanca { Resolve-RaizDoBackend -RepoRoot $sozinho } 'Procurado em'
        }

        It 'procedência: SHA do HEAD, marcado quando installer/ tem alteração local' {
            $repo = Novo-RepositorioDeTeste -Caminho (Join-Path $TestDrive 'scripts')
            Confirmar ((Get-ProcedenciaDosScripts -RepoRoot $repo.Caminho) -eq $repo.Segundo) 'SHA do HEAD'

            New-Item -ItemType Directory -Path (Join-Path $repo.Caminho 'installer') -Force | Out-Null
            Set-Content -Path (Join-Path (Join-Path $repo.Caminho 'installer') 'x.iss') -Value ';' -Encoding ascii
            Confirmar ((Get-ProcedenciaDosScripts -RepoRoot $repo.Caminho) -like '*com alteracoes locais*') 'alteração não marcada'
        }

        It 'procedência fora do git não lança' {
            $solto = Join-Path $TestDrive 'solto'
            New-Item -ItemType Directory -Path $solto -Force | Out-Null
            Confirmar ((Get-ProcedenciaDosScripts -RepoRoot $solto) -eq '(fora do git)') 'fora do git'
        }
    }

    Context 'Resolve-PayloadVerificado' {

        BeforeAll {
            function Novo-Payload {
                param([string] $Nome, [string] $Hash = '', [string] $NomeNoHash = '')
                $pasta = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $pasta -Force | Out-Null
                $exe = Join-Path $pasta $Nome
                [System.IO.File]::WriteAllBytes($exe, [byte[]](1..64))
                $calculado = (Get-FileHash -Path $exe -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($Hash -ne '-') {
                    if (-not $Hash) { $Hash = $calculado }
                    if (-not $NomeNoHash) { $NomeNoHash = $Nome }
                    Set-Content -Path (Join-Path $pasta 'webview2.sha256') -Value "$Hash  $NomeNoHash" -Encoding ascii
                }
                return [pscustomobject]@{ Pasta = $pasta; Exe = $exe; Hash = $calculado }
            }
        }

        It 'confere o hash, copia para o destino e devolve o nome' {
            $p = Novo-Payload -Nome 'webview2-1.0.exe'
            $destino = Join-Path $TestDrive 'fonte-ok'
            $nome = Resolve-PayloadVerificado -PayloadDir $p.Pasta -ArquivoHash 'webview2.sha256' -Destino $destino -Descricao 'o WebView2'

            Confirmar ($nome -eq 'webview2-1.0.exe') "nome devolvido '$nome'"
            Confirmar (Test-Path (Join-Path $destino 'webview2-1.0.exe')) 'binário não copiado para o destino'
        }

        It 'sem pasta devolve vazio (instalador sai sem o componente)' {
            $nome = Resolve-PayloadVerificado -PayloadDir (Join-Path $TestDrive 'nao-existe') -ArquivoHash 'webview2.sha256' `
                -Destino (Join-Path $TestDrive 'fonte-vazia') -Descricao 'o WebView2'
            Confirmar ($nome -eq '') "esperava vazio, veio '$nome'"
        }

        It '-Obrigatorio sem pasta lança (componente obrigatório não sai do pacote — PRD-TOTEMINST-02)' {
            Confirmar-Lanca { Resolve-PayloadVerificado -PayloadDir (Join-Path $TestDrive 'nao-existe-obrig') `
                -ArquivoHash 'webview2.sha256' -Destino (Join-Path $TestDrive 'fonte-obrig') -Descricao 'o WebView2' `
                -Obrigatorio } 'ausente'
        }

        It '-Obrigatorio com pasta sem .exe lança' {
            $pasta = Join-Path $TestDrive 'obrig-sem-exe'
            New-Item -ItemType Directory -Path $pasta -Force | Out-Null
            Set-Content -Path (Join-Path $pasta 'README.md') -Value 'sem binário' -Encoding ascii
            Confirmar-Lanca { Resolve-PayloadVerificado -PayloadDir $pasta -ArquivoHash 'webview2.sha256' `
                -Destino (Join-Path $TestDrive 'fonte-obrig2') -Descricao 'o WebView2' -Obrigatorio } 'Nenhum .exe'
        }

        It '-Obrigatorio com payload íntegro devolve o nome, como sem a chave' {
            $p = Novo-Payload -Nome 'webview2-2.0.exe'
            $nome = Resolve-PayloadVerificado -PayloadDir $p.Pasta -ArquivoHash 'webview2.sha256' `
                -Destino (Join-Path $TestDrive 'fonte-obrig-ok') -Descricao 'o WebView2' -Obrigatorio
            Confirmar ($nome -eq 'webview2-2.0.exe') "nome devolvido '$nome'"
        }

        It 'reprova hash divergente' {
            $p = Novo-Payload -Nome 'webview2-1.0.exe' -Hash ('0' * 64)
            Confirmar-Lanca { Resolve-PayloadVerificado -PayloadDir $p.Pasta -ArquivoHash 'webview2.sha256' `
                -Destino (Join-Path $TestDrive 'fonte-div') -Descricao 'o WebView2' } 'divergente'
        }

        It 'reprova arquivo de hash que nomeia outro binário' {
            $p = Novo-Payload -Nome 'webview2-1.0.exe' -NomeNoHash 'outro.exe'
            Confirmar-Lanca { Resolve-PayloadVerificado -PayloadDir $p.Pasta -ArquivoHash 'webview2.sha256' `
                -Destino (Join-Path $TestDrive 'fonte-nome') -Descricao 'o WebView2' } 'outro.exe'
        }

        It 'reprova ausência do arquivo de hash, com a instrução do hash calculado' {
            $p = Novo-Payload -Nome 'webview2-1.0.exe' -Hash '-'
            Confirmar-Lanca { Resolve-PayloadVerificado -PayloadDir $p.Pasta -ArquivoHash 'webview2.sha256' `
                -Destino (Join-Path $TestDrive 'fonte-semhash') -Descricao 'o WebView2' } $p.Hash
        }

        It 'reprova mais de um executável' {
            $p = Novo-Payload -Nome 'webview2-1.0.exe'
            [System.IO.File]::WriteAllBytes((Join-Path $p.Pasta 'outro.exe'), [byte[]](1..8))
            Confirmar-Lanca { Resolve-PayloadVerificado -PayloadDir $p.Pasta -ArquivoHash 'webview2.sha256' `
                -Destino (Join-Path $TestDrive 'fonte-dois') -Descricao 'o WebView2' } 'apenas um'
        }
    }

    Context 'Test-PayloadDoRunner' {

        BeforeAll {
            # Payload de teste: um .exe e o arquivo de hash correspondente (ou o que o caso pedir).
            function Novo-PayloadDeRunner {
                param([string] $Nome = 'qz-tray-2.2.exe', [string] $ArquivoHash = 'payload.sha256',
                    [string] $Hash = '', [string] $NomeNoHash = '')
                $pasta = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $pasta -Force | Out-Null
                $exe = Join-Path $pasta $Nome
                [System.IO.File]::WriteAllBytes($exe, [byte[]](1..48))
                if ($Hash -ne '-') {
                    $valor = if ($Hash) { $Hash } else { (Get-FileHash -Path $exe -Algorithm SHA256).Hash.ToLowerInvariant() }
                    $alvo = if ($NomeNoHash) { $NomeNoHash } else { $Nome }
                    Set-Content -Path (Join-Path $pasta $ArquivoHash) -Value "$valor  $alvo" -Encoding ascii
                }
                return $pasta
            }

            # O diagnóstico relata e segue: exceção aqui esconderia as verificações seguintes.
            function Confirmar-NaoLanca {
                param([scriptblock] $Bloco)
                try { return & $Bloco }
                catch { throw "Falhou: Test-PayloadDoRunner lançou '$($_.Exception.Message)' em vez de relatar." }
            }
        }

        It 'payload íntegro devolve OK com o nome e o hash' {
            $pasta = Novo-PayloadDeRunner
            $r = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir $pasta -ArquivoHash 'payload.sha256' `
                    -Descricao 'o QZ Tray' -Variavel 'PRINTMONITOR_PAYLOAD_DIR' }

            Confirmar ($r.Estado -eq 'OK') "estado '$($r.Estado)'"
            Confirmar ($r.Detalhe -like '*qz-tray-2.2.exe*') "detalhe sem o nome do binário: '$($r.Detalhe)'"
        }

        It 'pasta não informada respeita o EstadoSeAusente e cita a variável e o efeito' {
            $aviso = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir '' -ArquivoHash 'webview2.sha256' `
                    -Descricao 'o WebView2' -Variavel 'TOTEM_WEBVIEW2_PAYLOAD_DIR' `
                    -EstadoSeAusente 'AVISO' -EfeitoSeAusente 'O build FALHA sem ele.' }
            $falha = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir '' -ArquivoHash 'webview2.sha256' `
                    -Descricao 'o WebView2' -Variavel 'TOTEM_WEBVIEW2_PAYLOAD_DIR' -EstadoSeAusente 'FALHA' }

            Confirmar ($aviso.Estado -eq 'AVISO') "sem o switch esperava AVISO, veio '$($aviso.Estado)'"
            Confirmar ($falha.Estado -eq 'FALHA') "com o switch esperava FALHA, veio '$($falha.Estado)'"
            Confirmar ($aviso.Detalhe -like '*TOTEM_WEBVIEW2_PAYLOAD_DIR*') "detalhe sem a variável: '$($aviso.Detalhe)'"
            Confirmar ($aviso.Detalhe -like '*O build FALHA sem ele.*') "detalhe sem o efeito: '$($aviso.Detalhe)'"
        }

        It 'pasta inexistente e pasta sem .exe também são ausência' {
            $semPasta = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir (Join-Path $TestDrive 'nao-existe-runner') `
                    -ArquivoHash 'payload.sha256' -Descricao 'o QZ Tray' -Variavel 'VAR' -EstadoSeAusente 'FALHA' }
            $vazia = Join-Path $TestDrive 'runner-sem-exe'
            New-Item -ItemType Directory -Path $vazia -Force | Out-Null
            $semExe = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir $vazia -ArquivoHash 'payload.sha256' `
                    -Descricao 'o QZ Tray' -Variavel 'VAR' -EstadoSeAusente 'AVISO' }

            Confirmar ($semPasta.Estado -eq 'FALHA') "pasta inexistente: '$($semPasta.Estado)'"
            Confirmar ($semExe.Estado -eq 'AVISO') "pasta sem .exe: '$($semExe.Estado)'"
        }

        It 'mais de um executável é FALHA mesmo sem ExigirPayload (ambiguidade, não ausência)' {
            $pasta = Novo-PayloadDeRunner
            [System.IO.File]::WriteAllBytes((Join-Path $pasta 'outro.exe'), [byte[]](1..8))
            $r = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir $pasta -ArquivoHash 'payload.sha256' `
                    -Descricao 'o QZ Tray' -Variavel 'VAR' -EstadoSeAusente 'AVISO' }

            Confirmar ($r.Estado -eq 'FALHA') "estado '$($r.Estado)'"
        }

        It 'arquivo de hash ausente, divergente ou que nomeia outro binário é FALHA' {
            $semHash = Novo-PayloadDeRunner -Hash '-'
            $divergente = Novo-PayloadDeRunner -Hash ('0' * 64)
            $outroNome = Novo-PayloadDeRunner -NomeNoHash 'outro.exe'

            $a = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir $semHash -ArquivoHash 'payload.sha256' -Descricao 'o QZ Tray' -Variavel 'VAR' }
            $b = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir $divergente -ArquivoHash 'payload.sha256' -Descricao 'o QZ Tray' -Variavel 'VAR' }
            $c = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir $outroNome -ArquivoHash 'payload.sha256' -Descricao 'o QZ Tray' -Variavel 'VAR' }

            Confirmar ($a.Estado -eq 'FALHA') "sem o .sha256: '$($a.Estado)'"
            Confirmar ($b.Estado -eq 'FALHA') "hash divergente: '$($b.Estado)'"
            Confirmar ($c.Estado -eq 'FALHA') "hash de outro binário: '$($c.Estado)'"
            Confirmar ($b.Detalhe -like '*divergente*') "detalhe do divergente: '$($b.Detalhe)'"
        }

        It 'o arquivo de hash é o do componente: o do QZ não serve ao WebView2' {
            # A pasta do WebView2 tem o binário e um payload.sha256 (nome do QZ) — falta o webview2.sha256.
            $pasta = Novo-PayloadDeRunner -Nome 'MicrosoftEdgeWebview2Setup.exe' -ArquivoHash 'payload.sha256'
            $r = Confirmar-NaoLanca { Test-PayloadDoRunner -PayloadDir $pasta -ArquivoHash 'webview2.sha256' `
                    -Descricao 'o WebView2' -Variavel 'VAR' }

            Confirmar ($r.Estado -eq 'FALHA') "estado '$($r.Estado)'"
            Confirmar ($r.Detalhe -like '*webview2.sha256*') "detalhe sem o nome esperado: '$($r.Detalhe)'"
        }
    }

    Context 'ConvertTo-ListaDeOrigens' {

        It 'normaliza para a forma do cabeçalho Origin (minúsculas, sem barra final), separada por vírgula' {
            $lista = ConvertTo-ListaDeOrigens -Origens ' HTTPS://Interno-Dev.Berechit.com.br/ ; http://localhost:4200 '
            Confirmar ($lista -eq 'https://interno-dev.berechit.com.br,http://localhost:4200') "veio '$lista'"
        }

        It 'lista vazia devolve vazio (instalador sem origem padrão)' {
            $lista = ConvertTo-ListaDeOrigens -Origens ''
            Confirmar ($lista -eq '') "esperava vazio, veio '$lista'"
        }

        It 'recusa curinga' {
            Confirmar-Lanca { ConvertTo-ListaDeOrigens -Origens 'https://*.exemplo.com' } 'Origem inválida'
        }

        It 'recusa caminho' {
            Confirmar-Lanca { ConvertTo-ListaDeOrigens -Origens 'https://admin.exemplo.com/app' } 'Origem inválida'
        }

        It 'recusa origem sem esquema' {
            Confirmar-Lanca { ConvertTo-ListaDeOrigens -Origens 'admin.exemplo.com' } 'Origem inválida'
        }
    }

    Context 'Split-ArquivoEmPartes / Join-PartesDoArquivo' {

        BeforeAll {
            # 2.500 bytes em partes de 1.000: duas cheias e uma parcial, o caso que um corte errado erra.
            function Novo-Pacote {
                param([string] $Pasta)
                New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
                $arquivo = Join-Path $Pasta 'Pacote-1.2.3.exe'
                $bytes = New-Object byte[] 2500
                for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte]($i % 251) }
                [System.IO.File]::WriteAllBytes($arquivo, $bytes)
                return $arquivo
            }
        }

        It 'gera .001, .002, .003 com o tamanho de parte e o resto na última' {
            $arquivo = Novo-Pacote -Pasta (Join-Path $TestDrive 'dividir')
            $partes = @(Split-ArquivoEmPartes -Arquivo $arquivo -TamanhoParte 1000)
            $nomes = ($partes | ForEach-Object { Split-Path $_ -Leaf }) -join ','
            $tamanhos = ($partes | ForEach-Object { (Get-Item $_).Length }) -join ','

            Confirmar ($nomes -eq 'Pacote-1.2.3.exe.001,Pacote-1.2.3.exe.002,Pacote-1.2.3.exe.003') "partes '$nomes'"
            Confirmar ($tamanhos -eq '1000,1000,500') "tamanhos '$tamanhos'"
        }

        It 'remonta o arquivo byte a byte, com o mesmo SHA-256' {
            $arquivo = Novo-Pacote -Pasta (Join-Path $TestDrive 'remontar')
            $original = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash
            Split-ArquivoEmPartes -Arquivo $arquivo -TamanhoParte 1000 | Out-Null
            Remove-Item $arquivo

            $remontado = Join-PartesDoArquivo -Arquivo $arquivo
            Confirmar ((Get-FileHash -Path $remontado -Algorithm SHA256).Hash -eq $original) 'hash do remontado diverge'
        }

        It 'apaga partes de uma divisão anterior maior, que corromperiam a montagem' {
            $pasta = Join-Path $TestDrive 'sobra'
            $arquivo = Novo-Pacote -Pasta $pasta
            Set-Content -Path "$arquivo.004" -Value 'sobra de pacote antigo' -Encoding ascii
            $partes = @(Split-ArquivoEmPartes -Arquivo $arquivo -TamanhoParte 1000)

            Confirmar ($partes.Count -eq 3) "esperava 3 partes, veio $($partes.Count)"
            Confirmar (-not (Test-Path "$arquivo.004")) 'a .004 antiga sobreviveu'
        }

        It 'recusa montar com parte faltando no meio' {
            $arquivo = Novo-Pacote -Pasta (Join-Path $TestDrive 'lacuna')
            Split-ArquivoEmPartes -Arquivo $arquivo -TamanhoParte 1000 | Out-Null
            Remove-Item "$arquivo.002"
            Confirmar-Lanca { Join-PartesDoArquivo -Arquivo $arquivo } 'Parte ausente'
        }

        It 'recusa montar sem nenhuma parte' {
            $pasta = Join-Path $TestDrive 'vazia'
            New-Item -ItemType Directory -Path $pasta -Force | Out-Null
            Confirmar-Lanca { Join-PartesDoArquivo -Arquivo (Join-Path $pasta 'Nada-1.0.0.exe') } 'Nenhuma parte'
        }
    }

    Context 'New-PacoteZipEmPartes / Expand-PacoteZipEmPartes' {

        BeforeAll {
            # 6.000 bytes aleatórios (o zip não encolhe, como o LZMA do Inno) hasheados como o build faz.
            function Novo-Instalador {
                param([string] $Pasta)
                New-Item -ItemType Directory -Path $Pasta -Force | Out-Null
                $arquivo = Join-Path $Pasta 'Setup-1.2.3.exe'
                $bytes = New-Object byte[] 6000
                (New-Object System.Random 42).NextBytes($bytes)
                [System.IO.File]::WriteAllBytes($arquivo, $bytes)
                Write-ArquivoSha256 -Arquivo $arquivo | Out-Null
                return $arquivo
            }

            # Pacote em 4 partes numa pasta só com as partes e o .cmd: o que a TI baixa do GitHub.
            function Nova-PastaAvulsa {
                param([string] $Nome)
                $origem = Novo-Instalador -Pasta (Join-Path $TestDrive "$Nome-origem")
                New-PacoteZipEmPartes -Instalador $origem -TamanhoParte 2000 | Out-Null
                $avulsa = Join-Path $TestDrive $Nome
                New-Item -ItemType Directory -Path $avulsa -Force | Out-Null
                Copy-Item -Path (Join-Path (Split-Path $origem -Parent) 'Setup-1.2.3.zip.*') -Destination $avulsa
                Copy-Item -Path (Join-Path (Split-Path $origem -Parent) 'montar-instalador.cmd') -Destination $avulsa
                return [pscustomobject]@{
                    Pasta    = $avulsa
                    Exe      = Join-Path $avulsa 'Setup-1.2.3.exe'
                    Original = (Get-FileHash -Path $origem -Algorithm SHA256).Hash
                }
            }

            function Invoke-Montador {
                param([string] $Pasta)
                & (Join-Path $Pasta 'montar-instalador.cmd') /semPausa | Out-Null
                return $LASTEXITCODE
            }
        }

        It 'grava Setup-1.2.3.zip.001… dentro do limite, sem deixar o .zip inteiro' {
            $pasta = Join-Path $TestDrive 'zip'
            $arquivo = Novo-Instalador -Pasta $pasta
            $partes = @(New-PacoteZipEmPartes -Instalador $arquivo -TamanhoParte 2000)
            $nomes = ($partes | ForEach-Object { Split-Path $_ -Leaf }) -join ','

            Confirmar ($nomes -eq 'Setup-1.2.3.zip.001,Setup-1.2.3.zip.002,Setup-1.2.3.zip.003,Setup-1.2.3.zip.004') "partes '$nomes'"
            Confirmar (@($partes | Where-Object { (Get-Item $_).Length -gt 2000 }).Count -eq 0) 'parte acima do limite'
            Confirmar (-not (Test-Path (Join-Path $pasta 'Setup-1.2.3.zip'))) 'o .zip intermediário ficou na pasta'
        }

        It 'remonta, extrai o .exe e o .sha256 e o hash confere' {
            $arquivo = Novo-Instalador -Pasta (Join-Path $TestDrive 'ida-e-volta')
            $original = (Get-FileHash -Path $arquivo -Algorithm SHA256).Hash
            New-PacoteZipEmPartes -Instalador $arquivo -TamanhoParte 2000 | Out-Null
            Remove-Item $arquivo, "$arquivo.sha256"

            $extraido = Expand-PacoteZipEmPartes -Pacote ([System.IO.Path]::ChangeExtension($arquivo, '.zip'))
            Confirmar ($extraido -eq $arquivo) "extraído em '$extraido'"
            Confirmar ((Get-FileHash -Path $extraido -Algorithm SHA256).Hash -eq $original) 'hash do extraído diverge'
            Confirmar (Test-ArquivoSha256 -Arquivo $extraido) 'o .sha256 de dentro do zip não confere'
        }

        It 'copia o montar-instalador.cmd para a pasta das partes' {
            $arquivo = Novo-Instalador -Pasta (Join-Path $TestDrive 'com-montador')
            New-PacoteZipEmPartes -Instalador $arquivo -TamanhoParte 2000 | Out-Null
            $copia = Join-Path (Split-Path $arquivo -Parent) 'montar-instalador.cmd'
            $fonte = Join-Path $PSScriptRoot 'montar-instalador.cmd'

            Confirmar (Test-Path $copia) 'montar-instalador.cmd ausente da pasta das partes'
            Confirmar ((Get-FileHash $copia).Hash -eq (Get-FileHash $fonte).Hash) 'a cópia diverge do montar-instalador.cmd'
        }

        It 'montar-instalador.cmd: remonta, extrai e confere o hash por conta própria' {
            $avulsa = Nova-PastaAvulsa -Nome 'avulsa-ok'
            $codigo = Invoke-Montador -Pasta $avulsa.Pasta

            Confirmar ($codigo -eq 0) "código de saída $codigo"
            Confirmar ((Get-FileHash -Path $avulsa.Exe -Algorithm SHA256).Hash -eq $avulsa.Original) 'hash do .exe montado diverge'
            Confirmar (Test-ArquivoSha256 -Arquivo $avulsa.Exe) 'o .sha256 extraído não confere'
            Confirmar (-not (Test-Path (Join-Path $avulsa.Pasta 'Setup-1.2.3.zip'))) 'o .zip intermediário ficou na pasta'
        }

        It 'montar-instalador.cmd: falha e não deixa .exe com parte corrompida' {
            $avulsa = Nova-PastaAvulsa -Nome 'avulsa-corrompida'
            $parte = Join-Path $avulsa.Pasta 'Setup-1.2.3.zip.002'
            $bytes = [System.IO.File]::ReadAllBytes($parte)
            $bytes[1000] = $bytes[1000] -bxor 0xFF
            [System.IO.File]::WriteAllBytes($parte, $bytes)
            $codigo = Invoke-Montador -Pasta $avulsa.Pasta

            Confirmar ($codigo -ne 0) 'montou com parte corrompida'
            Confirmar (-not (Test-Path $avulsa.Exe)) 'o .exe corrompido ficou na pasta'
        }

        It 'montar-instalador.cmd: falha e não deixa .exe com parte faltando no meio' {
            $avulsa = Nova-PastaAvulsa -Nome 'avulsa-lacuna'
            Remove-Item (Join-Path $avulsa.Pasta 'Setup-1.2.3.zip.002')
            $codigo = Invoke-Montador -Pasta $avulsa.Pasta

            Confirmar ($codigo -ne 0) 'montou com a .002 faltando'
            Confirmar (-not (Test-Path $avulsa.Exe)) 'o .exe truncado ficou na pasta'
        }

        It 'montar-instalador.cmd: falha quando a pasta não tem partes' {
            $vazia = Join-Path $TestDrive 'avulsa-vazia'
            New-Item -ItemType Directory -Path $vazia -Force | Out-Null
            Copy-Item -Path (Join-Path $PSScriptRoot 'montar-instalador.cmd') -Destination $vazia
            $codigo = Invoke-Montador -Pasta $vazia

            Confirmar ($codigo -ne 0) 'saiu com sucesso sem parte nenhuma'
        }

        It 'apaga as partes cruas do formato anterior do mesmo instalador' {
            $arquivo = Novo-Instalador -Pasta (Join-Path $TestDrive 'formato-anterior')
            Set-Content -Path "$arquivo.001" -Value 'parte crua antiga' -Encoding ascii
            New-PacoteZipEmPartes -Instalador $arquivo -TamanhoParte 2000 | Out-Null

            Confirmar (-not (Test-Path "$arquivo.001")) 'a parte crua antiga sobreviveu'
        }

        It 'recusa empacotar sem .sha256 que confira' {
            $arquivo = Novo-Instalador -Pasta (Join-Path $TestDrive 'sem-hash')
            Remove-Item "$arquivo.sha256"
            Confirmar-Lanca { New-PacoteZipEmPartes -Instalador $arquivo -TamanhoParte 2000 } '.sha256'
        }

        It 'recusa extrair entrada com pasta (zip que não saiu do build)' {
            $pasta = Join-Path $TestDrive 'entrada-com-pasta'
            New-Item -ItemType Directory -Path $pasta -Force | Out-Null
            $zip = Join-Path $pasta 'Setup-9.9.9.zip'
            Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
            $arquivoZip = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $entrada = $arquivoZip.CreateEntry('..\fora.exe')
                $fluxo = $entrada.Open(); try { $fluxo.WriteByte(1) } finally { $fluxo.Dispose() }
            }
            finally { $arquivoZip.Dispose() }
            Split-ArquivoEmPartes -Arquivo $zip -TamanhoParte 2000 | Out-Null
            Remove-Item $zip

            Confirmar-Lanca { Expand-PacoteZipEmPartes -Pacote $zip } 'Entrada inesperada'
            Confirmar (-not (Test-Path (Join-Path $TestDrive 'fora.exe'))) 'extraiu fora da pasta'
        }
    }
}
