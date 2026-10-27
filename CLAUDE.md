# SisPedraCaida-Instaladores — Guia

> **Última atualização deste CLAUDE.md:** 27/10/2026 08:45 (horário local, UTC-3) — runner Windows registrado e
> CI/CD ligado (PRD-RUNWIN-01): armadilhas **(r)** pwsh via MSI e **(s)** pacote sem artifact, release móvel
> `prod-latest` · antes (24/10/2026 13:50): armadilha **(q)**:
> `startup_failure` por permissão do `GITHUB_TOKEN` · antes (24/10/2026 12:07): instalador do
> **totem** (`installer/totem/`) trazido junto: entrou no backend (PRD-TOTEM-04, PR #1226) depois do corte
> desta migração · antes (23/10/2026 17:30): repositório criado com os instaladores Windows e o CI/CD que
> viviam no `SisPedraCaida-Backend` (épico `repo-instaladores`, [`PRD/DONE/repo-instaladores/`](PRD/DONE/repo-instaladores/)).
>
> **Premissa de tamanho:** máximo **500K**; conferir com `wc -c CLAUDE.md` a cada atualização.
>
> **Conflito só no `CLAUDE.md` — sem testes:** alteração restrita a este arquivo dispensa build e testes.

Instaladores **Inno Setup 6** dos Windows services do SisPedraCaida — o que vai ao PC do balcão — e o
pipeline que os gera e publica. Comunicação, docs, commits e PRDs em **português-BR**.

| Instalador | Agente (projetos no backend) | Script | Canais do CI |
|---|---|---|---|
| `TefAgentSetup-X.Y.Z.exe` | `Tef.Agent` + `Tef.Agent.Setup` + `Tef.Agent.Tray` | [`installer/tefagent/build-installer.ps1`](installer/tefagent/build-installer.ps1) | dev, prod |
| `PrintMonitorSetup-X.Y.Z.exe` | `PrintMonitor.{Service,Setup,Helper,Bootstrapper,Tray}` | [`installer/printmonitor/build-installer.ps1`](installer/printmonitor/build-installer.ps1) | dev, prod |
| `BalancaAgentSetup-X.Y.Z.exe` | `Balanca.Agent` | [`installer/balanca/build-installer.ps1`](installer/balanca/build-installer.ps1) | prod |
| `TotemSetup-X.Y.Z.exe` | `Totem.Agent` + `Totem.Setup` + `Totem.Shell` (publish no próprio script; WebView2 opcional, fora do CI) | [`installer/totem/build-installer.ps1`](installer/totem/build-installer.ps1) | dev, prod |

A matriz é **[`installer/instaladores-ci.json`](installer/instaladores-ci.json)** — nunca o YAML.

## Duas procedências: este repositório + o backend

**O código dos agentes continua no [`SisPedraCaida-Backend`](https://github.com/b3r3ch1t/SisPedraCaida-Backend)**
(`src/`, `scripts/<agente>-publish.ps1`, `Directory.Build.props`, `global.json`). Aqui vivem só o
`.iss` e includes, o núcleo de empacotamento, o manifesto, o diagnóstico do runner, as guardas e os
workflows. Consequências:

- Os `build-installer.ps1` pinam o **backend** num worktree (`-Ref`, default **`prod`**) e compilam o
  `.iss` **deste** checkout. O backend é achado por `Resolve-RaizDoBackend`: `-BackendRoot` >
  `$env:SISPEDRACAIDA_BACKEND` > `backend/` (checkout do CI) > `../SisPedraCaida-Backend` (workspace).
- O pacote tem **dois SHAs**: `Origem` (backend) e `Scripts` (este repo, marcado `com alteracoes locais`
  se `installer/` estiver sujo). Os dois saem no console, no resumo do job e nas notas da release.
  Reproduzir um pacote = `git checkout <Scripts>` aqui **e** `-Ref <Origem>`.
- **Mudança de contrato entre `.iss` e C#** (código de saída novo, porta, nome de serviço, argumento do
  Helper, URL do dashboard) é **um PR em cada repositório**: backend primeiro, depois o `.iss` aqui. As
  guardas de `tests/` pegam a divergência — mas só quando rodam contra o backend novo (CI de PR usa a
  `dev` do backend; o `testar` do empacotamento usa o SHA exato).
- Os docs **do que o instalador faz na estação** ficaram no backend, ao lado do código que provisiona:
  [`TefAgentInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/TefAgentInstalador.md),
  [`PrintMonitorInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/PrintMonitorInstalador.md),
  [`BalancaAgentInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/BalancaAgentInstalador.md),
  [`TotemInstalacaoWindows.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/TotemInstalacaoWindows.md)
  e as armadilhas **#78, #101, #104, #112, #119** do `CLAUDE.md` de lá. **Leia o doc do agente antes de mexer
  no `.iss` dele.**

## Estrutura

```
installer/
├── instaladores-ci.json        # matriz do CI por canal (fonte única; guarda InstaladoresCiArchitectureTests)
├── assets/sispedracaida.ico
├── common/                     # Empacotamento.psm1 (núcleo) + Pester + montar-instalador.ps1
├── tefagent/  printmonitor/  balanca/  totem/   # .iss + includes + build-installer.ps1 (+ payloads fora do git)
scripts/runner-windows-diagnostico.ps1   # pré-requisitos do runner Windows
scripts/preparar-runner-windows.ps1      # prepara e registra o runner (admin, idempotente)
tests/SisPedraCaida.Instaladores.Tests/  # guardas .iss × C# do backend (xUnit, net10.0-windows)
artifacts/installer/            # pacotes versionados à força (git add -f) — uma versão só
docs/                           # RunnerWindowsInstaladores.md · InstaladoresBuildLocalWindows.md
PRD/                            # TODO → DOING → DONE
```

## Comandos

```powershell
# Pacote (backend clonado ao lado, em ../SisPedraCaida-Backend)
pwsh installer/tefagent/build-installer.ps1 -Ref origin/dev
pwsh installer/printmonitor/build-installer.ps1 -Ref origin/dev -PayloadDir <qz> -DriversPayloadDir <driver>
pwsh installer/tefagent/build-installer.ps1 -UseWorkingTree -SkipPublish -DryRun   # iterar no .iss

# Testes
pwsh installer/common/Invoke-TestesEmpacotamento.ps1                        # Pester (3.4 ou 5; também no 5.1)
dotnet test tests/SisPedraCaida.Instaladores.Tests                           # guardas; Windows; backend irmão
dotnet test tests/SisPedraCaida.Instaladores.Tests -p:BackendDir=<clone>/   # outro clone do backend

# Diagnóstico da máquina que empacota
pwsh scripts/runner-windows-diagnostico.ps1 -BackendRoot ..\SisPedraCaida-Backend
```

Contrato completo dos scripts e diagnóstico por mensagem de erro:
[`docs/InstaladoresBuildLocalWindows.md`](docs/InstaladoresBuildLocalWindows.md). Pacote local é de
**desenvolvimento**; o de campo é o asset da release `prod-vX.Y.Z` **deste** repositório.

## CI/CD

| Workflow | Gatilho | O que faz |
|---|---|---|
| [`instaladores-windows.yml`](.github/workflows/instaladores-windows.yml) | `workflow_dispatch` (o backend dispara) e `workflow_call` | `matriz` (ubuntu: clona o backend no `sha`, resolve versão pelo manifest do canal, filtra a matriz) → `testar` (Windows: Pester + guardas contra o backend naquele SHA) → `empacotar` (Windows, um worktree por serviço, `fail-fast: false`) → `publicar` (ubuntu: confere `.sha256`, publica **aqui**) |
| [`instaladores-dev.yml`](.github/workflows/instaladores-dev.yml) | push na `dev` deste repo em `installer/**`, `tests/**` ou nos dois workflows | chama o anterior com `canal=dev`, HEAD da `dev` do backend |
| [`runner-windows-diagnostico.yml`](.github/workflows/runner-windows-diagnostico.yml) | manual | `runner-windows-diagnostico.ps1 -ExigirPayload` + Pester, como a conta do serviço do runner |
| [`ci.yml`](.github/workflows/ci.yml) | PR para `dev`/`prod` | Pester + guardas (`windows-latest`, backend `dev` ou `prod` conforme a base) |
| [`commitlint.yml`](.github/workflows/commitlint.yml) | PR para `dev`/`prod` | commits e título em Conventional Commits ([`commitlint.config.mjs`](commitlint.config.mjs), header ≤ 100) |

**Quem dispara a partir do backend** (token `INSTALADORES_DISPATCH_TOKEN` de lá):

| Evento no backend | Workflow de lá | Chamada aqui |
|---|---|---|
| push na `prod` (com ou sem release) | `release-please-prod.yml`, job `instaladores` | `--ref prod -f canal=prod -f sha -f versao -f tag` |
| push na `dev` que toque os agentes (`paths`) | `instaladores-dev.yml` | `--ref dev -f canal=dev -f sha` |

**Publicação (neste repositório):** `prod` → release `prod-vX.Y.Z` (mesma tag da release do backend,
criada aqui com `--target` no commit dos scripts se não existir) com `.exe` + `.sha256` e a tabela de
hashes entre marcadores nas notas; `prod` sem tag → release móvel **`prod-latest`** (pré-lançamento);
`dev` → release móvel **`dev-latest`** (pré-lançamento). **Sem artifact do Actions** desde 27/10/2026 (armadilha **s**):
o job `empacotar` anexa cada `.exe` direto na release que o job `preparar` deixou pronta.

**Configuração do repositório** (runbook: [`docs/RunnerWindowsInstaladores.md`](docs/RunnerWindowsInstaladores.md)):

| Tipo | Nome | Para quê |
|---|---|---|
| Runner | `[self-hosted, windows, instaladores]` em `C:\actions-runner`, **registrado neste repo** | `testar`, `empacotar`, diagnóstico |
| Variável | `INSTALADORES_WINDOWS=true` (aqui **e** no backend) | liga-desliga: só depois do diagnóstico verde |
| Variável | `PRINTMONITOR_PAYLOAD_DIR` / `PRINTMONITOR_DRIVERS_PAYLOAD_DIR` | caches do QZ Tray e do driver Bematech no runner |
| Segredo | `SISPEDRACAIDA_BACKEND_TOKEN` | `contents: read` no backend privado (checkout em `backend/`) |

**Branches:** `dev` (integração, default) e `prod` (o que o backend dispara no canal de produção).
Sem release-please aqui: a versão do pacote é a do **backend**. Promover `dev` → `prod` é PR
(**merge commit**), e precisa acontecer **antes** da promoção do backend que dependa do `.iss` novo.

## Convenções

- **PRD:** trabalho não trivial em `PRD/TODO → DOING → DONE`, um arquivo por etapa movido
  individualmente, linha `> **Status:** … — **Última atualização:** dd/mm/yyyy HH:mm` (UTC-3). **Um
  épico = uma branch** a partir da `dev`; nunca commitar direto na `dev`/`prod`; commit + push a cada
  ~20 min; PR para a `dev`.
- **Commit:** Conventional Commits (`feat|fix|docs|chore|refactor|test|ci|build|perf|style|revert`),
  minúscula, header ≤ 100, corpo ≤ 100 por linha. Merge commit com `chore(escopo):`, nunca `merge:`.
  Na ferramenta Bash, `git commit -F arquivo` (heredoc com crase se perde).
- **Testes:** toda mudança em `Empacotamento.psm1` ganha teste Pester (sem `Should` — Pester 3.4 e 5);
  toda regra que o `.iss` espelha do C# ganha guarda em `tests/`. Pester e guardas não podem regredir.
- **PowerShell 5.1 compatível** no módulo e nos scripts: nada de `Join-Path` com 3 argumentos,
  ternário, `-Encoding utf8NoBOM`; defaults que dependem de `$PSScriptRoot` resolvidos no corpo.
- **Comentários** explicam o porquê (o padrão do repositório é denso, em português).
- **XML em `.csproj`:** comentário não pode conter `--` (ex.: `--config-ui`) — o MSBuild recusa o arquivo.

## Armadilhas

Herdadas da armadilha **#108** do backend (épicos `ci-instaladores-prod`/`-dev`), mais as da mudança de
repositório (`m`–`p`).

| # | Sintoma | Causa e correção |
|---|---|---|
| a | Windows service novo no backend e a release sai **sem** o instalador dele, tudo verde | A matriz é o manifesto. `InstaladoresCiArchitectureTests` varre o `src/` do backend por `UseWindowsService`/`AddWindowsService`: sem linha (ou `pendentes` com PRD) reprova — **mas só aqui**. Agente novo no backend ⇒ PR aqui no mesmo ciclo |
| b | Dois empacotamentos corrompem um ao outro | Cada serviço no **seu** worktree (`-WorktreeDir`, `-RemoveWorktree`) |
| c | `Filename too long` / `MSB3030 … apphost.exe … not found` | O worktree tem o backend inteiro sob `RUNNER_TEMP`; `core.longpaths` resolve o git, mas o **MSBuild segue em 260** — runner em `C:\actions-runner`; o diagnóstico mede o pior caso |
| d | Run fica na fila 24 h e é cancelado | Sem runner registrado **neste** repo. Só ligue `INSTALADORES_WINDOWS` com o diagnóstico verde |
| e | ISCC recusa a versão | Só `X.Y.Z` (`VersionInfoVersion`) |
| f | PrintMonitor sai sem QZ Tray ou não compila | No CI os **dois** payloads são exigidos: sem QZ o pacote sairia incompleto; sem o driver o `.iss` faz `#error` |
| g | Script morre no `git worktree add` só no 5.1 | Progresso do git no stderr vira exceção com `Stop`; `Invoke-GitEmpacotamento` roda com `Continue` e decide pelo código de saída |
| h | Linha some da matriz em silêncio | `canais` vazio/errado. A guarda exige `canais` válido, sem repetição, `prod` em todas, e cobra a lista **fixa** `CanaisQueEmpacotam = ["dev","prod"]` — derivá-la do manifesto deixa a guarda cega (#74 do backend) |
| i | `dev-latest`/`prod-latest` servindo duas versões | Tag móvel movida pela API **antes** do upload, assets anteriores apagados (`--clobber` só cobre nome igual). A tag aponta para o commit **deste** repo — tag não aponta para commit de outro repositório; o SHA do backend vai nas notas |
| j | Ensaio da dev cancela o release da prod | `cancel-in-progress` só na dev, com o canal na chave do `concurrency.group` |
| k | Vários `.exe` com o mesmo nome na dev | O nome repete entre SHAs; a procedência está nas notas da release (SHA do backend e dos scripts) e no `.sha256` |
| l | Push recusado / clone pesado | PrintMonitor (~200 MB) passa de 100 MiB: versionar só `PrintMonitorSetup-X.Y.Z.zip.001…` (zip de até 90 MiB, `-DividirEmPartes`) + `.exe.sha256` com `git add -f`; remontar e conferir com `montar-instalador.ps1` antes; **uma versão só** (o mesmo commit faz `git rm` da anterior) |
| m | Job `matriz` reprova "SISPEDRACAIDA_BACKEND_TOKEN ausente" / checkout do backend dá 404 | Os dois repos são privados e o `GITHUB_TOKEN` não cruza repositório: token fine-grained com `contents: read` no backend (runbook §6.1). 404 no checkout = token sem acesso ao backend |
| n | O backend "disparou" e nada empacotou | `gh workflow run` é fire-and-forget: o run do backend fica verde e o resultado está **aqui**. Conferir: `INSTALADORES_WINDOWS` neste repo, `--ref` existente (`dev`/`prod`) e o workflow presente nessa branch |
| o | Guarda verde aqui e estação quebrada em campo | A guarda compara com o backend que ela compilou: o CI de PR usa a `dev` do backend. Mudança de contrato vai **backend primeiro**; o `testar` do empacotamento repete as guardas contra o SHA exato antes de empacotar |
| p | Pacote "igual" com hash diferente | O `.iss` não é pinado pelo `-Ref` (ele é deste checkout). Para reproduzir, `git checkout` do SHA de `Scripts` aqui. `Scripts … (com alteracoes locais)` = nunca distribuir |
| q | `Instaladores Windows (dev)` termina em **`startup_failure`** ("workflow file issue") no push, mesmo com `INSTALADORES_WINDOWS` desligada | O `GITHUB_TOKEN` deste repositório nasce **só de leitura** (`default_workflow_permissions = read`), e o reusable `instaladores-windows.yml` pede `contents: write`. Chamador que não concede a permissão é recusado **no startup**, antes do `if`. Todo workflow que faz `uses: ./.github/workflows/instaladores-windows.yml` declara `permissions: contents: write`. Os disparos do backend (`workflow_dispatch`) não passam por aqui: o próprio reusable declara a permissão |
| r | Job Windows morre com "pwsh não encontrado" (ou `winget install Microsoft.PowerShell --scope machine` dá `0x80070005` e o pwsh do usuário some) | O pwsh da Store é por usuário e não existe para `NETWORK SERVICE`; o manifesto de máquina do winget é `.msixbundle`, que falha e remove o da Store. PowerShell 7 vai pelo **MSI** da release oficial — é o que o [`preparar-runner-windows.ps1`](scripts/preparar-runner-windows.ps1) faz |
| s | Pacotes gerados e o job reprova com `Artifact storage quota has been hit` | A cota de artifacts é **da conta**, somada entre os repositórios privados (o backend guarda ~35 MB de `coverage-report` por run). Os `.exe` (~350 MB por run) **não** passam por artifact: `gh release upload` do runner direto para a release; não reintroduzir `upload-artifact` para pacote |
