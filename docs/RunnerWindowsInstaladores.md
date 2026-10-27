# Runner Windows dos instaladores — runbook

> **Última atualização:** 27/10/2026 16:40 (horário local) — **terceiro payload: bootstrapper do WebView2
> do totem** (PRD-TOTEMINST-02, §5.3) e payloads **declarados no manifesto** (`installer/instaladores-ci.json`,
> campo `payloads`): o job `empacotar` e o diagnóstico só iteram a lista. Antes (27/10/2026 08:45): **runner registrado** (`instaladores-win-01`,
> PRD-RUNWIN-01): §3 ganhou o `scripts/preparar-runner-windows.ps1` e a armadilha do pwsh via winget/MSIX;
> pacotes publicados sem artifact (release móvel `prod-latest` para prod sem tag). Antes (23/10/2026 17:30): **mudou de repositório**: runner,
> variáveis, segredos e workflows passaram para o **SisPedraCaida-Instaladores** (§4, §6). O backend só
> dispara (§6.4). Antes (22/10/2026 16:35): §5 cobre os **dois** payloads do PrintMonitor.
>
> Épico `ci-instaladores-prod`, **PRD-INSTPROD-01**. É o runner que os jobs `testar` e `empacotar` do
> [`instaladores-windows.yml`](../.github/workflows/instaladores-windows.yml) exigem
> (`[self-hosted, windows, instaladores]`). Visão do pipeline: [`CLAUDE.md`](../CLAUDE.md) §*CI/CD*.

## 1. Por que um runner Windows

Os workflows dos outros três repositórios rodam no `[self-hosted, sispedracaida]`, que é **Linux** (e,
numa conta pessoal, runner é **por repositório**: aqueles não servem a este — os jobs leves daqui rodam
no `ubuntu-latest`). O ISCC (Inno
Setup 6) só existe para Windows, e os `Setup.exe`/bandeja são `net10.0-windows` — o empacotamento
precisa de um Windows de verdade (decisão **D1**: self-hosted, sem minutos pagos; Wine foi descartado
porque o `app.manifest` precisa ser validado num Windows real, armadilha #104).

Enquanto o runner não existir, nada empacota: o job `instaladores` do `release-please-prod` **do
backend** (que dispara este repositório) e o `instaladores-dev.yml` daqui só rodam com a variável
`INSTALADORES_WINDOWS=true` — que existe nos **dois** repositórios (§6).

## 2. Máquina

| Item | Mínimo |
|---|---|
| Sistema | Windows 10/11 ou Server 2022, **x64** (pode ser VM) |
| CPU / RAM / disco | 4 vCPU · 8 GB · 40 GB livres (cada serviço publica ~400 MB de layout self-contained) |
| Rede | saída HTTPS para `github.com`, `*.actions.githubusercontent.com` e `api.nuget.org` |

## 3. Preparar (como administrador, uma vez)

> **Atalho (27/10/2026):** [`scripts/preparar-runner-windows.ps1`](../scripts/preparar-runner-windows.ps1)
> faz §3, a permissão dos caches de §5 e o registro de §4 de uma vez, idempotente, num PowerShell **de
> administrador** (roda no 5.1 de uma máquina limpa). Pré-requisitos: `gh` autenticado com admin neste
> repositório (o token de registro é pedido à API e vai direto ao `config.cmd`, sem ser impresso), o
> pacote do runner extraído em `C:\actions-runner` e os caches de §5 montados.
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File scripts\preparar-runner-windows.ps1
> ```

Tudo **em escopo de máquina**: o serviço do runner roda com outra conta, e o que foi instalado *por
usuário* por quem preparou a máquina **não existe para ela**. É a causa nº 1 de "ISCC não encontrado".

```powershell
winget install --id Microsoft.DotNet.SDK.10 --scope machine
winget install --id Git.Git --scope machine
winget install --id JRSoftware.InnoSetup --scope machine
# PowerShell 7: MSI da release oficial (PowerShell-X.Y.Z-win-x64.msi), msiexec /qn ADD_PATH=1
```

⚠️ **PowerShell 7 não vai pelo winget.** O manifesto `Microsoft.PowerShell` com `--scope machine` é um
`.msixbundle`: falha com `0x80070005 Access is denied` e, no caminho, **remove o pwsh da Store** de quem
rodou (reproduzido em 27/10/2026). E o pwsh da Store, que mora em `%LOCALAPPDATA%\Microsoft\WindowsApps`,
não existe para `NETWORK SERVICE` — todo `shell: pwsh` do workflow falharia. O MSI instala em
`C:\Program Files\PowerShell\7` e põe a pasta no PATH da máquina; o script confere o SHA-256 do MSI contra
o digest da release antes de instalar.

```powershell
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1 -Type DWord
git config --system core.longpaths true
```

> `--system` (não `--global`) vale para todas as contas, inclusive a do serviço. O job de
> empacotamento ainda liga `core.longpaths` por `GIT_CONFIG_*`, mas o `actions/checkout` roda antes.

⚠️ **O SDK precisa casar com o [`global.json`](../global.json)** (`10.0.300`, `rollForward:
latestMinor`, o mesmo do backend) — o diagnóstico roda `dotnet --version` **na raiz do checkout do
backend** justamente para isso.

## 4. Registrar o runner

⚠️ **Diretório curto, sem negociação:** `C:\actions-runner`. O worktree de cada instalador contém o
**backend** inteiro sob `RUNNER_TEMP`, e o **MSBuild continua preso a 260 caracteres** mesmo com
`LongPathsEnabled`. Com base longa o `dotnet publish` falha com `MSB3030 … apphost.exe … not found`
(reproduzido em 18/10/2026: base de 140 caracteres ⇒ pior caso de 305). Com `C:\actions-runner` o pior
caso fica em ~190.

1. GitHub → **`SisPedraCaida-Instaladores`** → **Settings → Actions → Runners → New self-hosted runner** →
   Windows x64. Copie o **token de registro** da página (vale ~1 h; **nunca** o cole em arquivo, chamado
   ou commit).
2. Baixe e extraia o pacote indicado na página em `C:\actions-runner`.
3. Registre **como serviço**, com o label do épico:

   ```powershell
   cd C:\actions-runner
   .\config.cmd --url https://github.com/b3r3ch1t/SisPedraCaida-Instaladores --token <TOKEN> `
     --name instaladores-win-01 --labels instaladores --runasservice
   ```

   `self-hosted`, `Windows` e `X64` são acrescentados sozinhos (labels não diferenciam maiúsculas, então
   `windows` do workflow casa com `Windows`). Aceite a conta padrão do serviço, **`NT AUTHORITY\NETWORK
   SERVICE`**: empacotar não precisa de administrador, e uma conta de usuário com login interativo seria
   superfície à toa.
4. Confira em **Settings → Actions → Runners**: `instaladores-win-01` **Idle**, com os labels
   `self-hosted, Windows, X64, instaladores`.

## 5. Payloads (três)

Dois instaladores embutem binários de terceiro, nenhum deles versionado, cada um na sua pasta de cache
e com o seu arquivo de hash. **No CI todo payload é obrigatório:** o job `empacotar` reprova o serviço
com "Payload ausente" em vez de gerar pacote de campo incompleto.

| Payload | Instalador | Pasta / hash | Variável no CI | Sem ele, no build local |
|---|---|---|---|---|
| **QZ Tray** | PrintMonitor | [`installer/printmonitor/payload/`](../installer/printmonitor/payload/README.md) · `payload.sha256` | `PRINTMONITOR_PAYLOAD_DIR` | o instalador **sai sem** o componente |
| **Driver Bematech MP-4200 TH** | PrintMonitor | [`installer/printmonitor/payload-drivers/`](../installer/printmonitor/payload-drivers/README.md) · `driver.sha256` | `PRINTMONITOR_DRIVERS_PAYLOAD_DIR` | o **build falha** (`Resolve-PayloadVerificado -Obrigatorio` + `#error` no `.iss`, desde o PRD-PMTRAY-02) |
| **Bootstrapper do WebView2 Runtime** | totem | [`installer/totem/payload-webview2/`](../installer/totem/payload-webview2/README.md) · `webview2.sha256` | `TOTEM_WEBVIEW2_PAYLOAD_DIR` | o instalador **sai sem** o runtime: em Windows sem ele a tela do totem fica "fora de serviço" |

**A lista é o manifesto**, não este runbook nem o YAML: cada linha de `installer/instaladores-ci.json` tem
`payloads` com o parâmetro do `build-installer.ps1`, a variável, o arquivo de hash e o efeito da ausência.
O job `empacotar` e o diagnóstico (§6) só iteram essa lista (PRD-TOTEMINST-02). Payload novo = linha no
manifesto **e** a variável no `env:` dos dois workflows (`instaladores-windows.yml` e
`runner-windows-diagnostico.yml`): o contexto `vars` não é enumerável, e a guarda
`TodaVariavelDePayload_EstaNosDoisWorkflows` cobra a linha.

As pastas são separadas de propósito: cada uma aceita **um único** `.exe` e o build recusa
ambiguidade.

### 5.1 Cache do QZ Tray

No CI ele vem de um cache no runner:

```powershell
New-Item -ItemType Directory C:\ci-cache\printmonitor-payload -Force
# copie para lá SÓ o qz-tray-<versão>.exe homologado (baixado da origem oficial) e crie o hash:
cd C:\ci-cache\printmonitor-payload
"$((Get-FileHash .\qz-tray-<versão>.exe -Algorithm SHA256).Hash.ToLower())  qz-tray-<versão>.exe" |
  Set-Content payload.sha256 -Encoding ascii
icacls C:\ci-cache\printmonitor-payload /grant "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)RX"
```

Depois, no GitHub: **Settings → Secrets and variables → Actions → Variables** →
`PRINTMONITOR_PAYLOAD_DIR` = `C:\ci-cache\printmonitor-payload`.

⚠️ Confira o hash **contra a origem oficial** antes de gravá-lo: calcular o hash do arquivo que já está
na pasta só prova que ele não mudou desde então, não que é o QZ Tray verdadeiro. No CI o payload é
**obrigatório** — sem ele o job do PrintMonitor reprova em vez de gerar pacote de campo sem o QZ.

### 5.2 Cache do driver Bematech

Mesma receita, outra pasta e outro nome de hash:

```powershell
New-Item -ItemType Directory C:\ci-cache\printmonitor-drivers -Force
# copie para lá SÓ o instalador do driver homologado (ver o README da pasta: nome, tamanho, SHA-256 e
# assinatura Authenticode esperados) e crie o hash:
cd C:\ci-cache\printmonitor-drivers
"$((Get-FileHash .\bematech-mp4200th-spooler-x64-5.0.0.4.exe -Algorithm SHA256).Hash.ToLower())  bematech-mp4200th-spooler-x64-5.0.0.4.exe" |
  Set-Content driver.sha256 -Encoding ascii
icacls C:\ci-cache\printmonitor-drivers /grant "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)RX"
```

E a variável **`PRINTMONITOR_DRIVERS_PAYLOAD_DIR`** = `C:\ci-cache\printmonitor-drivers`.

⚠️ O `README.md` da pasta publica o SHA-256 esperado do binário homologado — confira-o, e a
assinatura, com `Get-AuthenticodeSignature` antes de trocar o arquivo (o certificado expirou em 2019,
mas a assinatura tem carimbo de tempo).

### 5.3 Cache do bootstrapper do WebView2 (totem)

O `MicrosoftEdgeWebview2Setup.exe` é o *Evergreen Bootstrapper* oficial da Microsoft (cerca de 2 MB): na
estação ele baixa o runtime atual, só quando a máquina não o tem. A Microsoft não publica SHA-256 dele, então
a procedência é a **assinatura Authenticode**, conferida antes de gravar o hash:

```powershell
$pasta = 'C:\ci-cache\totem-webview2'
New-Item -ItemType Directory $pasta -Force | Out-Null
$exe = Join-Path $pasta 'MicrosoftEdgeWebview2Setup.exe'
Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $exe
Get-AuthenticodeSignature $exe   # Status Valid, SignerCertificate.Subject com CN=Microsoft Corporation
"$((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower())  MicrosoftEdgeWebview2Setup.exe" |
  Set-Content (Join-Path $pasta 'webview2.sha256') -Encoding ascii
icacls $pasta /grant "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)RX"
```

E a variável **`TOTEM_WEBVIEW2_PAYLOAD_DIR`** = `C:\ci-cache\totem-webview2`. O
[`preparar-runner-windows.ps1`](../scripts/preparar-runner-windows.ps1) já dá a leitura nessa pasta
(`-WebView2PayloadDir`). A receita comentada está no
[`README.md` da pasta](../installer/totem/payload-webview2/README.md).

⚠️ **Crie o cache e a variável antes de mesclar na `dev`** qualquer mudança que torne o payload obrigatório
(foi o caso do PRD-TOTEMINST-02): o push dispara o `instaladores-dev.yml`, e sem a variável o job do totem
reprova. Os outros serviços seguem empacotando (`fail-fast: false`).

## 6. Diagnosticar e ligar

1. **Actions → Runner Windows - diagnóstico (instaladores) → Run workflow**
   ([`runner-windows-diagnostico.yml`](../.github/workflows/runner-windows-diagnostico.yml)). Ele roda
   [`scripts/runner-windows-diagnostico.ps1`](../scripts/runner-windows-diagnostico.ps1) **como a conta
   do serviço** (com o backend clonado em `backend/`, para o `global.json` e os projetos de `src/`) e
   reprova se faltar qualquer coisa:

   | Verificação | FALHA quando |
   |---|---|
   | Sistema operacional | não é Windows x64 |
   | PowerShell 7, Git | ausentes para a conta do serviço |
   | .NET SDK (global.json) | nenhum SDK compatível com o `global.json` |
   | Inno Setup (ISCC) | ausente, abaixo da **6.1** (o TEF usa `CreateDownloadPage`), ou sem `BrazilianPortuguese.isl` |
   | Pester | ausente (o Windows traz o 3.4; os testes do `Empacotamento.psm1` rodam antes de empacotar) |
   | Caminho dos worktrees | o pior caminho do MSBuild sob `RUNNER_TEMP` passa de 259 caracteres |
   | Payload (printmonitor): o QZ Tray | variável/pasta ausente, ≠ 1 `.exe`, sem `payload.sha256` ou hash divergente |
   | Payload (printmonitor): o driver da Bematech | idem, com `driver.sha256` (PRD-INSTDEV-04) |
   | Payload (totem): o bootstrapper do WebView2 | idem, com `webview2.sha256` (PRD-TOTEMINST-02) |

   As linhas de payload saem do manifesto: uma por item de `payloads`, na ordem das linhas.

   `LongPathsEnabled` e `core.longpaths` saem como AVISO. **Ausência** de payload só é FALHA com
   `-ExigirPayload` (o que o workflow passa); sem o switch vira AVISO, para conferir a máquina antes
   de montar os caches. **Ambiguidade e hash divergente são FALHA sempre** — o build lança nos dois
   casos, em qualquer modo. O mesmo script roda direto na máquina, antes de registrar o runner:

   ```powershell
   pwsh scripts/runner-windows-diagnostico.ps1 -BackendRoot ..\SisPedraCaida-Backend `
     -PayloadDir C:\ci-cache\printmonitor-payload `
     -DriversPayloadDir C:\ci-cache\printmonitor-drivers `
     -WebView2PayloadDir C:\ci-cache\totem-webview2
   ```

   Os três parâmetros de pasta são só overrides: sem eles, cada pasta vem da variável que o manifesto
   declara (`PRINTMONITOR_PAYLOAD_DIR`, `PRINTMONITOR_DRIVERS_PAYLOAD_DIR`, `TOTEM_WEBVIEW2_PAYLOAD_DIR`).

2. Com o diagnóstico verde, crie a variável **`INSTALADORES_WINDOWS`** = `true` **nos dois
   repositórios** (aqui liga o `instaladores-dev.yml`; no backend, os disparos de §6.4). A partir daí
   todo push na `prod` do backend empacota.
3. Ensaio (etapa 05): **Actions → Instaladores Windows → Run workflow** (branch `prod`) com `sha` vazio
   (HEAD da `prod` do backend) e `tag` vazia — gera os quatro instaladores na release móvel `prod-latest`.

### 6.1 Segredos (um token, dois repositórios)

Os dois repositórios são **privados**, e o `GITHUB_TOKEN` de um não enxerga o outro. Crie **um**
token *fine-grained* (dono `b3r3ch1t`, expiração anotada no calendário) com acesso a **só** estes dois
repositórios e as permissões:

| Permissão | Por quê |
|---|---|
| `Contents: read` em **SisPedraCaida-Backend** | o `instaladores-windows.yml` clona o backend no SHA pedido (`backend/`) |
| `Actions: write` em **SisPedraCaida-Instaladores** | o backend dispara o `instaladores-windows.yml` daqui por `gh workflow run` |

Grave-o (pela tela **Settings → Secrets and variables → Actions**, nunca colado em chamado ou commit):

| Repositório | Segredo |
|---|---|
| SisPedraCaida-Instaladores | `SISPEDRACAIDA_BACKEND_TOKEN` |
| SisPedraCaida-Backend | `INSTALADORES_DISPATCH_TOKEN` |

Sem o primeiro, o job `matriz` reprova dizendo o que criar; sem o segundo, o job de disparo do backend
reprova — e, como os dois ficam atrás de `INSTALADORES_WINDOWS`, nenhum roda antes de o runner existir.

### 6.4 Quem dispara

| Evento | Workflow | Chamada |
|---|---|---|
| Push na `prod` do backend (com ou sem release) | backend: `release-please-prod.yml`, job `instaladores` | `gh workflow run instaladores-windows.yml --ref prod -f canal=prod -f sha -f versao -f tag` |
| Push na `dev` do backend que toque os agentes | backend: `instaladores-dev.yml` (filtro de `paths` lá) | `gh workflow run instaladores-windows.yml --ref dev -f canal=dev -f sha` |
| Push na `dev` deste repositório que toque `installer/`, `tests/` ou os workflows | daqui: `instaladores-dev.yml` | `workflow_call`, HEAD da `dev` do backend |

O disparo é **fire-and-forget**: o run do backend fica verde ao disparar, e o resultado do empacotamento
aparece **aqui** (Actions deste repositório e a release `prod-vX.Y.Z` daqui). Isso só reforça a D3 —
falha de instalador nunca encostou no deploy das imagens.

## 7. Operação

| Situação | O que fazer |
|---|---|
| Runner **offline** com `INSTALADORES_WINDOWS=true` | o job fica **na fila** (não falha) e é cancelado após 24 h; o deploy das imagens não é afetado (D3). Religue o serviço `actions.runner.*` ou desligue a variável |
| Release saiu sem algum instalador | o run **deste repositório** fica vermelho no job que falhou; corrija e **reemita**: `Instaladores Windows` (branch `prod`) com `sha` = commit do release no backend e `tag` = `prod-vX.Y.Z` (os anexos são substituídos) |
| Nova versão do QZ Tray | troque o `.exe` e o `payload.sha256` em `C:\ci-cache\printmonitor-payload` e rode o diagnóstico |
| Nova versão do driver Bematech | troque o `.exe` e o `driver.sha256` em `C:\ci-cache\printmonitor-drivers`, atualize o `README.md` da pasta (hash e assinatura) e rode o diagnóstico |
| Novo bootstrapper do WebView2 | baixe de novo pela §5.3, confira a assinatura, troque o `.exe` e o `webview2.sha256` em `C:\ci-cache\totem-webview2` e rode o diagnóstico |
| Novo SDK / Inno | atualize com `winget upgrade … --scope machine` e rode o diagnóstico |
| Disco enchendo | `RUNNER_TEMP` é limpo pelo runner a cada job; os worktrees são removidos pelo próprio script. Para run cancelado no meio, uma tarefa agendada semanal com `git -C C:\actions-runner\_work\SisPedraCaida-Instaladores\SisPedraCaida-Instaladores\backend worktree prune` |
| Segundo runner | registre outro com o mesmo label `instaladores`: os três empacotamentos passam a rodar em paralelo, sem mudar o workflow (cada um já usa o seu worktree) |

## 8. Estado verificado em 19/10/2026 — nenhuma release de prod tem instalador

> **Histórico:** levantado quando o pipeline ainda vivia no backend. Em 23/10/2026 (mudança de
> repositório) o quadro era o mesmo: nenhum runner Windows e nenhuma variável — agora a preparar
> **neste** repositório.

Levantado direto no GitHub depois da **promoção 28** (`prod-v2.16.0`), que promoveu justamente o
agente TEF do terminal Windows — `Tef.Agent`, `Tef.Agent.Setup` e `Tef.Agent.Tray`:

| Item | Estado |
|---|---|
| Runner `[self-hosted, windows, instaladores]` | **não existe** — os 3 runners do repo são Linux (`self-hosted, Linux, X64, sispedracaida, docker`), todos `online` |
| Variável `INSTALADORES_WINDOWS` | **não existe** (`gh variable list` traz só `DEPLOY_COMPOSE_PATH`) |
| Variável `PRINTMONITOR_PAYLOAD_DIR` | **não existe** — é o **segundo** bloqueio: sem o payload o empacotamento do PrintMonitor **reprova** de propósito (§5.1) |
| Variável `PRINTMONITOR_DRIVERS_PAYLOAD_DIR` | **não existe** — mesmo bloqueio, e aqui o build falha de verdade: o driver é obrigatório (§5.2) |
| Job `instaladores` do `release-please-prod` | **`skipped`** em todo push na `prod`, pela condição de §6.2 |
| Assets de `prod-v2.16.0` (`4408470`) e de `prod-v2.15.0` (`071e5d5`) | **zero** |

**Consequência prática:** `Tef.Agent.Setup` e `Tef.Agent.Tray` são Windows-only e vão a campo por
**instalador Inno Setup**, não por imagem de container — o que a promoção 28 colocou em produção
**não chega ao balcão**. Não é regressão da promoção: é a lacuna do PRD-INSTPROD-01, que ela torna
concreta. O deploy das imagens segue intacto (D3), e os dois workflows (`instaladores-windows.yml` e
o `release-please-prod.yml` com o job) **já existem na branch `prod`** — falta só a máquina.

⚠️ **Não crie a variável antes do runner.** Com `INSTALADORES_WINDOWS=true` e nenhum runner no label,
o job fica **enfileirado** em todo push na `prod` e é cancelado em 24 h (§7): o run de produção fica
vermelho por um runner que não existe, que é exatamente o que a condição evita.

### O que só pode ser feito na máquina (fora do alcance de uma sessão de código)

Tudo o que falta é operação de host, nesta ordem — nenhum passo é automatizável daqui, e o **token de
registro** da §4 nem deve sair da página que o emite:

1. §3 — preparar a máquina, tudo `--scope machine`.
2. §4 — registrar o runner em `C:\actions-runner`, como serviço, com o label `instaladores`.
3. §5 — os **dois** caches do PrintMonitor + as variáveis `PRINTMONITOR_PAYLOAD_DIR` e `PRINTMONITOR_DRIVERS_PAYLOAD_DIR`.
4. §6.1 — rodar o diagnóstico até ficar **verde**.
5. §6.1 — o token e os dois segredos.
6. §6.2 — só então criar `INSTALADORES_WINDOWS=true` (nos dois repositórios).
7. §6.3 — ensaio com `sha` e `tag` vazios (gera os pacotes na release móvel `prod-latest`).

### Reemitir para uma tag que já existe

A release **não** precisa ser refeita — o job `publicar` sobe os anexos com `--clobber`. Com o runner
`Idle` e o diagnóstico verde:

```bash
gh workflow run instaladores-windows.yml -R b3r3ch1t/SisPedraCaida-Instaladores --ref prod -f canal=prod \
  -f sha=44084709420d6332b1f0a7dad260594a6717f1e9 -f tag=prod-v2.16.0
```

`versao` fica vazio: ela sai da própria tag (`prod-v` + `X.Y.Z`). Conferir com
`gh release view prod-v2.16.0 -R b3r3ch1t/SisPedraCaida-Instaladores --json assets` (a release nasce
aqui se não existir) — devem aparecer
`TefAgentSetup-2.16.0.exe` e `PrintMonitorSetup-2.16.0.exe`, cada um
com o `.sha256` ao lado. O mesmo comando serve para `prod-v2.15.0` (`071e5d5`), se o pacote daquela
versão ainda interessar.
