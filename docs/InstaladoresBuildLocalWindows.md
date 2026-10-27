# Gerar os instaladores Windows localmente

> **Última atualização:** 23/10/2026 17:30 (horário local, UTC-3) — instaladores em repositório próprio:
> os scripts rodam **neste** repositório e pinam o código do agente num clone do backend (`-BackendRoot`,
> §3). Antes (22/10/2026 16:35): PRD-INSTDEV-04.

Como preparar uma máquina Windows e gerar à mão o `TefAgentSetup-<versão>.exe`, o
`PrintMonitorSetup-<versão>.exe`, o `BalancaAgentSetup-<versão>.exe` e o `TotemSetup-<versão>.exe`.

**Este doc é sobre a máquina que GERA o pacote, não sobre a estação que o executa.** Os
pré-requisitos de quem instala estão, no backend, em [`TefAgentInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/TefAgentInstalador.md) §5.1,
[`PrintMonitorInstalacaoWindows.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/PrintMonitorInstalacaoWindows.md) §2 e
[`BalancaAgentInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/BalancaAgentInstalador.md). Para preparar o **runner** do CI, que é
outra coisa (conta de serviço, ACL, registro do runner), abra
[`RunnerWindowsInstaladores.md`](RunnerWindowsInstaladores.md).

> ### ⚠️ O pacote gerado aqui é de DESENVOLVIMENTO, nunca de campo
>
> O instalador que vai ao balcão é o **asset da GitHub Release**: `prod-vX.Y.Z` para produção, e
> (PRD-INSTDEV) `dev-latest` para homologação em estação de teste. O build local existe para iterar
> no `.iss` e para reproduzir um pacote que o CI já gerou.
>
> **Nunca** commite o `.exe` gerado à mão como se fosse o corrente. `artifacts/` está no `.gitignore`;
> a única exceção versionada é `artifacts/installer/` (o PrintMonitor em zip de partes de até 90 MiB e
> o TEF da última entrega manual — armadilha **(l)** do [`CLAUDE.md`](../CLAUDE.md)), sempre **uma
> versão só** e sempre gerada de `-Ref origin/<canal>`, nunca da árvore aberta. No backend chegaram a
> ficar ~207 MB rastreados, com um `TefAgentSetup` antigo aparentando ser o corrente.

---

## 1. Pré-requisitos da máquina

| Pré-requisito | Como obter | Por que |
|---|---|---|
| **Windows 10/11 ou Server 2022, x64** | — | o ISCC é Windows-only, e o `Setup.exe` (WinForms) e o `app.manifest` só se validam em Windows real |
| **.NET SDK 10** | `winget install --id Microsoft.DotNet.SDK.10 --scope machine` | `dotnet publish` dos projetos. A versão é resolvida pelo [`global.json`](../global.json) (`10.0.300`, `rollForward: latestMinor`) — o diagnóstico roda `dotnet --version` **na raiz do repo**, que é o que prova a compatibilidade, e não só "existe algum dotnet" |
| **Inno Setup 6.1+** | `winget install --id JRSoftware.InnoSetup --scope machine` | compila os `.iss`. **6.1 é piso**, não preferência: o instalador do TEF usa `CreateDownloadPage`/`DownloadTemporaryFile` para o pré-requisito do Elgin TEF HUB |
| ↳ **`BrazilianPortuguese.isl`** | reinstalar o Inno com os idiomas | os três `.iss` declaram pt-BR; sem o arquivo o ISCC reprova |
| **PowerShell 7 (`pwsh`)** | MSI da release oficial (`PowerShell-X.Y.Z-win-x64.msi`) — **não** `winget … --scope machine`, que é MSIX e remove o pwsh da Store (armadilha r) | os `build-installer.ps1` e o [`Empacotamento.psm1`](../installer/common/Empacotamento.psm1). O 5.1 que vem no Windows **não serve** — ver §4 |
| **Git for Windows** | `winget install --id Git.Git --scope machine` | o script materializa o repositório **inteiro** num worktree |
| ↳ `git config --global core.longpaths true` | como a conta que vai buildar | sem isso o `git worktree add` morre com `Filename too long` nos PRDs de caminho comprido |
| **`LongPathsEnabled = 1`** | `Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1 -Type DWord` (admin) | não é bloqueante com clone curto, mas protege a limpeza do worktree por `Remove-Item` |
| **Clone em caminho curto** | ex.: `C:\repos\sispedracaida\SisPedraCaida-Backend` | **o que mais reprova.** O MSBuild segue preso a **259** caracteres mesmo com `LongPathsEnabled`, e o caminho mais fundo é o `obj\Release\net10.0-windows\win-x64\refint\<projeto>.dll` **dentro do worktree**: com base longa o `dotnet publish` morre com `MSB3030 … apphost.exe … not found` |
| **Pester** | já vem no Windows (3.4, em `C:\Program Files\WindowsPowerShell\Modules`) | roda os testes do `Empacotamento.psm1`; o módulo aceita 3.4 ou 5 |
| **Payload do QZ Tray** — só PrintMonitor | 1 `.exe` + `payload.sha256` em [`installer/printmonitor/payload/`](../installer/printmonitor/payload/) | o `PrintMonitorSetup` embute e executa o QZ Tray na estação; o binário **não é versionado** |
| **Payload do driver Bematech** — só PrintMonitor | 1 `.exe` + `driver.sha256` em [`installer/printmonitor/payload-drivers/`](../installer/printmonitor/payload-drivers/) | **obrigatório desde o PRD-PMTRAY-02**: o `.iss` faz `#error` sem `BematechDriverFile` e o build falha (`Resolve-PayloadVerificado -Obrigatorio`) |
| **~500 MB livres por serviço** | — | o publish é self-contained `win-x64` (runtime embutido) |

**O runtime .NET não é pré-requisito da estação.** O publish é `--self-contained`, e os próprios
`checks.iss` dizem isso ao operador na tela de pré-requisitos. Aqui, na máquina de build, o que se
instala é o **SDK**.

### Os dois payloads do PrintMonitor

Cada um numa pasta própria, com nome de hash próprio — a pasta do QZ aceita **um único** `.exe` e o
build recusa ambiguidade. Os `README.md` das duas pastas trazem a origem, o formato do `.sha256` e a
versão homologada; o do driver registra também o SHA-256 e a assinatura Authenticode esperados. O
`build-installer.ps1` recalcula os hashes, **falha o build** se divergirem (ou se o `.sha256` nomear
outro arquivo) e copia os binários para o worktree pinado — eles nunca estão lá, porque estão fora do
git.

Para empacotar **só o TEF ou só a balança**, nenhum payload é necessário.

---

## 2. Conferir a máquina antes do primeiro build

Use o mesmo script do CI — ele foi escrito para rodar nos dois lugares e, fora do Actions, a base
default é `C:\actions-runner\_work\_temp`:

```powershell
pwsh scripts/runner-windows-diagnostico.ps1 -BaseDir "$PWD\.worktrees"
```

Uma linha por verificação (`OK` / `AVISO` / `FALHA`), com a correção ao lado; qualquer `FALHA`
devolve código 1. Sem `-ExigirPayload`, payload do QZ ausente é **`AVISO`** — é o que você quer ao
conferir a máquina antes de montar o cache, ou quando vai empacotar apenas o TEF.

Numa máquina de desenvolvimento ainda sem as duas ferramentas (medido em 22/10/2026):

```
Runner Windows dos instaladores — diagnóstico
  [OK   ] Sistema operacional          Microsoft Windows NT 10.0.26300.0
  [OK   ] LongPathsEnabled             1
  [FALHA] PowerShell 7 (pwsh)          ausente (esta sessão: 5.1.26100.9711). MSI da release oficial (PowerShell-X.Y.Z-win-x64.msi) ou scripts\preparar-runner-windows.ps1 — NÃO o winget de máquina (MSIX; armadilha r)
  [OK   ] .NET SDK (global.json)       10.0.402
  [OK   ] Git                          git version 2.56.0.windows.2
  [OK   ] git core.longpaths (global)  true
  [FALHA] Inno Setup (ISCC)            não encontrado para <conta>. winget install --id JRSoftware.InnoSetup --scope machine
  [OK   ] Pester                       3.4.0 — roda os testes do Empacotamento.psm1 antes de empacotar
  [OK   ] Caminho dos worktrees        base '…\SisPedraCaida-Backend\.worktrees': pior caso 218 de 259 caracteres (folga 41).
  [AVISO] Payload do QZ Tray           PRINTMONITOR_PAYLOAD_DIR não definido (variável de repositório).

2 verificação(ões) com FALHA — o runner NÃO está pronto.
```

Duas leituras dessa saída valem registro. O **diagnóstico roda no 5.1** (e é ele que acusa a falta do
`pwsh`), então não há ovo-e-galinha: confira a máquina primeiro, instale depois. E a folga de 41
caracteres é de um clone em `C:\repos\sispedracaida\SisPedraCaida-Backend` — o pior caso é o projeto
de nome mais longo (`SisPedraCaida.Services.Api.Cadastro.Interno`, 43 caracteres) dentro do worktree;
clonar dois níveis mais fundo, ou numa pasta com o nome do usuário, consome essa folga.

O `-BaseDir` existe porque a verificação de caminho é a que mais importa: o script monta o **pior
caso** (serviço de nome mais longo × projeto de nome mais longo) sob a base informada e compara com
os 259 caracteres. Passe a pasta onde os worktrees vão nascer — localmente,
`<repo>\.worktrees` (o default dos scripts).

Para conferir os payloads do PrintMonitor, aponte as duas pastas:

```powershell
pwsh scripts/runner-windows-diagnostico.ps1 `
  -PayloadDir C:\ci-cache\printmonitor-payload `
  -DriversPayloadDir C:\ci-cache\printmonitor-drivers
```

A distinção dos desfechos é deliberada: **ausência** de payload é `AVISO` (ou `FALHA` com
`-ExigirPayload`), mas **dois `.exe` na pasta e hash divergente são `FALHA` sempre** — o build lança
nos dois casos, em qualquer modo, então relatá-los como aviso seria mentir sobre o que vai acontecer.
E o texto diz o efeito de cada ausência: o QZ sai do pacote, o driver **reprova o build**.

---

## 3. Gerar o instalador

Os três scripts têm o **mesmo contrato**, não interativo:

| Parâmetro | Default | Para que |
|---|---|---|
| `-Ref <branch\|origin/branch\|tag\|sha>` | **`prod`** | referência git **do backend** que origina o pacote; o script faz `fetch` e materializa um worktree pinado nela |
| `-BackendRoot <dir>` | `$env:SISPEDRACAIDA_BACKEND`, depois `backend\` (CI) e `..\SisPedraCaida-Backend` | clone do backend de onde o worktree é criado |
| `-UseWorkingTree` | — | empacota a árvore aberta **do backend**, **sem procedência** (§4) |
| `-SkipFetch` | — | não busca no remoto (offline, ou SHA já local) |
| `-Version <X.Y.Z>` | `VersionPrefix` do [`Directory.Build.props`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/Directory.Build.props) **da fonte** (backend) | versão estampada no `.exe` e no `VersionInfoVersion` |
| `-Configuration Debug\|Release` | `Release` | build do agente |
| `-IsccPath <caminho>` | descoberto em `Program Files` e `%LOCALAPPDATA%` | ISCC fora do lugar padrão |
| `-WorktreeDir <dir>` | `<workspace>\.worktrees\<servico>-pacote` | onde a fonte pinada é materializada |
| `-PublishDir <dir>` | `artifacts\<servico>` | layout self-contained publicado |
| `-OutputDir <dir>` | `artifacts\installer` | onde saem o `.exe` e o `.sha256` |
| `-RemoveWorktree` | — | descarta o worktree no fim, com sucesso ou falha (o CI usa) |
| `-SkipPublish` | — | reaproveita o layout já publicado (iteração no `.iss`) |
| `-DryRun` | — | valida a cadeia (ISCC, layout, payloads e hashes) **sem compilar** |

Só o PrintMonitor tem, além disso: `-PayloadDir` (QZ Tray), `-DriversPayloadDir` (driver Bematech) e
`-OrigensPadrao` (origens do front-adm que o wizard traz pré-preenchidas na página *Identificação
pelo navegador*; omitido, vale o default do `.iss`).

### Os quatro usos que cobrem a vida real

```powershell
# 1. Pacote da dev, pinado no HEAD remoto — procedência rastreável.
pwsh installer/tefagent/build-installer.ps1 -Ref origin/dev

# 2. PrintMonitor da dev (exige os DOIS payloads).
pwsh installer/printmonitor/build-installer.ps1 -Ref origin/dev `
    -PayloadDir C:\ci-cache\printmonitor-payload `
    -DriversPayloadDir C:\ci-cache\printmonitor-drivers

# 3. Iterar no .iss sem commit: árvore aberta, sem republicar, sem compilar.
pwsh installer/tefagent/build-installer.ps1 -UseWorkingTree -SkipPublish -DryRun

# 4. Reproduzir um pacote exato que o CI gerou (o SHA-256 tem de bater com o publicado).
pwsh installer/tefagent/build-installer.ps1 -Ref <sha> -Version 3.10.0
```

A balança segue o molde do (1): `pwsh installer/balanca/build-installer.ps1 -Ref origin/dev`. O totem
também, com o bootstrapper do WebView2 opcional (sem ele o pacote sai sem o runtime e a checagem só avisa):
`pwsh installer/totem/build-installer.ps1 -Ref origin/dev -WebView2BootstrapperPath <pasta com o .exe e o webview2.sha256>`.

**Saída:** `artifacts/installer/<Nome>-<versão>.exe` + `<Nome>-<versão>.exe.sha256`, com
`<Nome>` ∈ { `TefAgentSetup`, `PrintMonitorSetup`, `BalancaAgentSetup`, `TotemSetup` }. O hash é a **única prova de
integridade** do pacote — ele não é assinado por CA pública (decisão D6 do PRD-TEFINST-00). Confira
com:

```powershell
Get-FileHash artifacts\installer\TefAgentSetup-3.10.0.exe -Algorithm SHA256
```

### A sequência que o script executa

1. resolve o ISCC e o clone do backend (`Resolve-RaizDoBackend`);
2. confere que **este** repositório tem o `.iss` e os includes, e materializa o **backend** num
   **worktree git pinado** na `-Ref` (ou usa a árvore aberta dele com `-UseWorkingTree`);
3. publica o layout self-contained chamando `scripts/<servico>-publish.ps1 -SkipZip` — o layout
   publicado é o **contrato de entrada** da seção `[Files]` do `.iss`, e é validado contra uma lista
   de arquivos obrigatórios (`Assert-FonteCompleta`);
4. copia os payloads verificados para a `payload\`/`payload-drivers\` ao lado do `.iss` (PrintMonitor);
5. compila o `.iss` **deste** repositório com o ISCC, injetando versão e diretório publicado por `/D`;
6. grava o `.sha256` ao lado do `.exe` e imprime as **duas** procedências: `Origem` (SHA do backend) e
   `Scripts` (SHA deste repositório, marcado quando `installer/` tem alteração local).

---

## 4. Armadilhas

- **O default de `-Ref` é `prod`, não a branch que você está editando.** Rodar o script sem
  parâmetro empacota **produção**. E, se a `prod` local estiver defasada, ele empacota código de
  semanas atrás **sem nada avisar** — já aconteceu com 61 commits de atraso. Para pacote da `dev`,
  `-Ref origin/dev` explícito.
- **`-UseWorkingTree` produz `.exe` sem procedência.** O `.sha256` impresso ao lado não corresponde a
  commit nenhum, e ele é a única prova de integridade que a TI confere antes de instalar. É modo de
  iteração no `.iss`, e só.
- **PowerShell 5.1 não serve.** Com `ErrorActionPreference = 'Stop'`, o progresso que o `git` escreve
  no **stderr** vira exceção e mata o script. O `Invoke-GitEmpacotamento` do `Empacotamento.psm1`
  contorna isso rodando com `Continue` e decidindo pelo código de saída — mas o resto da cadeia
  assume `pwsh` 7.
- **Inno Setup instalado "por usuário" não existe para outra conta.** É o padrão do `winget` sem
  `--scope machine`, e a causa nº 1 de `Inno Setup (ISCC) FALHA` no diagnóstico: quem preparou a
  máquina instalou no próprio `%LOCALAPPDATA%` e o build roda noutra conta (ou como serviço).
- **Os dois payloads do PrintMonitor falham de formas diferentes.** Sem o QZ Tray o instalador é
  gerado **sem** o componente; sem o driver Bematech o build **não sai** (`#error` no `.iss`). Até
  22/10/2026 o diagnóstico conferia só o primeiro, e máquina verde ainda reprovava o
  `PrintMonitorSetup` — hoje ele confere os dois.
- **O `.iss` não está mais pinado.** Ele sai do checkout atual deste repositório; quem reproduz um
  pacote do CI faz `git checkout <SHA de Scripts>` aqui **e** `-Ref <SHA de Origem>` no backend.
- **Worktree default é compartilhado entre execuções.** `<workspace>\.worktrees\<servico>-pacote` é
  reaproveitado; a execução seguinte o limpa antes de usar. Dois empacotamentos do **mesmo** serviço
  em paralelo disputam o checkout e o `bin/obj` — passe `-WorktreeDir` próprio, como o CI faz.
- **Versão com sufixo não compila.** O `.iss` grava `VersionInfoVersion`, que recusa `-rc.1`,
  `-sha` etc. Só `X.Y.Z`.

---

## 5. Diagnóstico por mensagem de erro

| O que aparece | Causa | O que fazer |
|---|---|---|
| `MSB3030 … apphost.exe … not found` | caminho do worktree passou de 259 para o MSBuild | clone (ou `-WorktreeDir`) num diretório mais curto; rode o diagnóstico com o `-BaseDir` real |
| `Filename too long` no `git worktree add` | `core.longpaths` desligado | `git config --global core.longpaths true` **na conta que builda** |
| `Inno Setup (ISCC) … não encontrado` | Inno por usuário, ou ausente | `winget install --id JRSoftware.InnoSetup --scope machine` |
| ISCC reclama de idioma | falta `Languages\BrazilianPortuguese.isl` | reinstalar o Inno com os idiomas |
| `… é obrigatório e o pacote não sai sem ele` | payload do driver (ou do QZ) ausente | montar a pasta com o `.exe` + `.sha256`, ou passar `-DriversPayloadDir`/`-PayloadDir` |
| hash divergente no payload | binário trocado sem atualizar o `.sha256` | conferir a origem e regravar o `.sha256` (nunca "ajustar" o hash para o que saiu) |
| `nenhum SDK compatível com 10.0.300` | SDK fora do `global.json` | `winget install --id Microsoft.DotNet.SDK.10 --scope machine` |
| exceção de `git` logo no início, só no 5.1 | `pwsh` 7 ausente | instalar o PowerShell 7 e repetir com `pwsh` |

---

## 6. Links

- [`RunnerWindowsInstaladores.md`](RunnerWindowsInstaladores.md) — preparar e registrar o runner do CI.
- [`CLAUDE.md`](../CLAUDE.md) §*CI/CD* — quando cada canal gera pacote, e as armadilhas do empacotamento.
- No backend: [`TefAgentInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/TefAgentInstalador.md) · [`PrintMonitorInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/PrintMonitorInstalador.md) · [`BalancaAgentInstalador.md`](https://github.com/b3r3ch1t/SisPedraCaida-Backend/blob/dev/docs/BalancaAgentInstalador.md) — o que cada instalador faz na estação.
