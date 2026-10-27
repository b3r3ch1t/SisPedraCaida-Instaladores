# PRD-TOTEMINST-02 — WebView2 embutido pelo CI

> **Status:** Em andamento — código, guardas e docs prontos; faltam o cache e a variável no runner e o run pós-merge — **Última atualização:** 27/10/2026 17:00

## Objetivo

O `TotemSetup-X.Y.Z.exe` gerado pelo CI passa a trazer o bootstrapper do WebView2 Runtime, vindo de um cache
no runner, como já acontece com o QZ Tray e o driver Bematech no PrintMonitor. De passagem, o significado de
"payload" sai do YAML e vai para o manifesto. Fecha as lacunas L3 e L4 do master.

## Como o bootstrapper é obtido

- **Arquivo:** `MicrosoftEdgeWebview2Setup.exe`, o **Evergreen Bootstrapper** da Microsoft (~2 MB). Não tem versão
  no nome; na instalação ele baixa o runtime atual. O totem precisa de internet nesse momento, o que o
  `provisioning.iss` já registra.
- **Origem:** permalink oficial `https://go.microsoft.com/fwlink/p/?LinkId=2124703`.
- **Procedência:** a Microsoft não publica SHA-256 do bootstrapper. A prova é a assinatura Authenticode:
  `Get-AuthenticodeSignature` com `Status = Valid` e subject `CN=Microsoft Corporation`.
- **`webview2.sha256`:** o operador o gera no runner, **depois** de conferir a assinatura, no formato sha256sum que
  `Resolve-PayloadVerificado` exige (`<hash em minúsculas>  MicrosoftEdgeWebview2Setup.exe`). O hash pina a cópia
  do cache; o build recusa binário trocado (`Resolve-BootstrapperWebView2` → `Resolve-PayloadVerificado -Obrigatorio`).
- O `build-installer.ps1` do totem **não muda**: o parâmetro `-WebView2BootstrapperPath` já existe.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | No CI o bootstrapper é **obrigatório**: o job do totem reprova sem `TOTEM_WEBVIEW2_PAYLOAD_DIR` | Pacote de campo tem de sair completo (D3 do master). O custo é um cache de ~2 MB montado uma vez |
| D2 | O manifesto troca `payload: bool` por `payloads: [ { parametro, variavel, hash, descricao, seAusente } ]` | O `empacotar` e o diagnóstico só iteram; o `if ($env:PAYLOAD -eq 'true')` com as variáveis do PrintMonitor fixas no YAML deixa de existir |
| D3 | Variável de repositório `TOTEM_WEBVIEW2_PAYLOAD_DIR` = `C:\ci-cache\totem-webview2` | Mesma convenção `<SERVICO>_<COMPONENTE>_PAYLOAD_DIR` das duas variáveis existentes |
| D4 | O `env:` dos workflows continua listando cada variável explicitamente | O contexto `vars` não é enumerável em runtime. Por isso a guarda nova confere que cada `variavel` do manifesto está no `env:` |
| D5 | Bootstrapper Evergreen, não o Standalone | O `.iss` foi desenhado para ele (`/silent /install` em `{tmp}`); o standalone (~150 MB) fica fora do escopo |
| D6 | `installer/totem/payload-webview2/README.md` com a receita, binário fora do git | Espelho de `installer/printmonitor/payload/` e `payload-drivers/` |
| D7 | O cache e a variável são criados **antes** do merge na `dev` | O push na `dev` dispara o `instaladores-dev.yml`; sem a variável o job do totem reprova por payload ausente |

## Mudanças

### 1. `installer/instaladores-ci.json`

Nas quatro linhas, `payload` vira `payloads`; o `_comentario` é atualizado.

| Linha | `payloads` |
|---|---|
| `tefagent`, `balanca` | `[]` |
| `printmonitor` | `{ "parametro": "PayloadDir", "variavel": "PRINTMONITOR_PAYLOAD_DIR", "hash": "payload.sha256", "descricao": "o QZ Tray", "seAusente": "…" }` e `{ "parametro": "DriversPayloadDir", "variavel": "PRINTMONITOR_DRIVERS_PAYLOAD_DIR", "hash": "driver.sha256", "descricao": "o driver da Bematech MP-4200 TH", "seAusente": "…" }` |
| `totem` | `{ "parametro": "WebView2BootstrapperPath", "variavel": "TOTEM_WEBVIEW2_PAYLOAD_DIR", "hash": "webview2.sha256", "descricao": "o bootstrapper do WebView2 Runtime", "seAusente": "…" }` |

`seAusente` carrega a frase que hoje está fixa no YAML e no diagnóstico (por exemplo: "O pacote do totem sairia
sem o WebView2 e a tela ficaria 'fora de serviço' em máquina sem o runtime.").

### 2. `.github/workflows/instaladores-windows.yml`, job `empacotar`

- `env:` perde `PAYLOAD: ${{ matrix.payload }}` e ganha `PAYLOADS: ${{ toJson(matrix.payloads) }}` e
  `TOTEM_WEBVIEW2_PAYLOAD_DIR: ${{ vars.TOTEM_WEBVIEW2_PAYLOAD_DIR }}`.
- O bloco `if ($env:PAYLOAD -eq 'true') { … }` vira um laço sobre `$env:PAYLOADS | ConvertFrom-Json`. Para cada
  item: lê a pasta com `[Environment]::GetEnvironmentVariable($p.variavel)`, exige ao menos um `.exe` nela
  (senão `throw "Payload ausente: defina a variável <variavel> … (<descricao>)"`) e faz
  `$parametros[$p.parametro] = $pasta`.
- O resumo do job ganha a linha do WebView2 quando o serviço é `totem`.

### 3. `.github/workflows/runner-windows-diagnostico.yml`

`env:` ganha `TOTEM_WEBVIEW2_PAYLOAD_DIR`; o comentário do cabeçalho passa de "os DOIS payloads do PrintMonitor"
para "os payloads do manifesto".

### 4. `scripts/runner-windows-diagnostico.ps1`

- As duas chamadas fixas a `Test-PayloadDoRunner` viram um laço sobre `$manifesto.instaladores[].payloads` (o
  script já lê o manifesto para medir o pior caminho).
- Os parâmetros `-PayloadDir` e `-DriversPayloadDir` ficam como override, para não quebrar os comandos do runbook;
  entra `-WebView2PayloadDir` no mesmo papel.
- `-ExigirPayload` continua transformando ausência em `FALHA`.

### 5. `scripts/preparar-runner-windows.ps1`

Parâmetro `-WebView2PayloadDir = 'C:\ci-cache\totem-webview2'`, incluído no `foreach` do `icacls`
(`*S-1-5-20:(OI)(CI)RX`, a conta `NETWORK SERVICE` do runner).

### 6. `installer/totem/payload-webview2/README.md` (+ `.gitignore` do binário)

A receita do cache:

```powershell
$pasta = 'C:\ci-cache\totem-webview2'
New-Item -ItemType Directory $pasta -Force | Out-Null
Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile "$pasta\MicrosoftEdgeWebview2Setup.exe"
Get-AuthenticodeSignature "$pasta\MicrosoftEdgeWebview2Setup.exe"   # Valid, CN=Microsoft Corporation
$h = (Get-FileHash "$pasta\MicrosoftEdgeWebview2Setup.exe" -Algorithm SHA256).Hash.ToLower()
"$h  MicrosoftEdgeWebview2Setup.exe" | Set-Content "$pasta\webview2.sha256" -Encoding ascii
```

### 7. `tests/SisPedraCaida.Instaladores.Tests/Ci/InstaladoresCiArchitectureTests.cs`

- O record `Instalador` troca `bool Payload` por `List<Payload> Payloads`, com
  `record Payload(string Parametro, string Variavel, string Hash, string Descricao, string SeAusente)`, normalizado
  para `[]` como `Canais`.
- `TodaLinhaDoManifesto_EstaViva` passa a exigir, para cada payload:
  - `variavel` casando `^[A-Z][A-Z0-9_]*_PAYLOAD_DIR$`, sem repetição no manifesto;
  - `hash` terminando em `.sha256`;
  - `parametro` declarado como `[string] $<parametro>` no `build-installer.ps1` da linha.
- Novo `TodaVariavelDePayload_EstaNosDoisWorkflows`: cada `variavel` aparece como
  `<VAR>: ${{ vars.<VAR> }}` no `instaladores-windows.yml` **e** no `runner-windows-diagnostico.yml`.
- Novo `Totem_DeclaraOBootstrapperDoWebView2`: a linha `totem` tem o payload com `parametro`
  `WebView2BootstrapperPath` e `hash` `webview2.sha256`. Fecha o par com a guarda do PRD-01, que trava o lado `.iss`.

### 8. Documentação deste repositório (no mesmo commit)

| Arquivo | Mudança |
|---|---|
| `docs/RunnerWindowsInstaladores.md` | §5 passa a "Payloads (três)", com a linha do WebView2 na tabela; novo §5.3 com a receita do cache; §6 ganha o item do diagnóstico; §7 ganha "Novo bootstrapper do WebView2: troque o `.exe` e o `webview2.sha256` e rode o diagnóstico"; cabeçalho com a data |
| `docs/InstaladoresBuildLocalWindows.md` | A linha do totem cita `C:\ci-cache\totem-webview2` como exemplo e diz que no CI ele é obrigatório |
| `CLAUDE.md` | Linha do totem: "WebView2 do cache do runner; opcional só no build local". Tabela de configuração com `TOTEM_WEBVIEW2_PAYLOAD_DIR`. Estrutura com `totem/payload-webview2/`. Armadilha **(f)** reescrita para "todo payload declarado no manifesto é exigido no CI". Armadilha nova **(t)**: variável de payload no manifesto e ausente do `env:` de um workflow faz o job reprovar "Payload ausente" ou deixa o diagnóstico cego; a guarda `TodaVariavelDePayload_EstaNosDoisWorkflows` cobra |

## Critérios de aceite

1. Guardas (`dotnet test`) e Pester verdes, sem regressão.
2. `pwsh scripts/runner-windows-diagnostico.ps1` local lista o payload do WebView2 como `AVISO` sem a pasta e `OK`
   com o cache montado.
3. `pwsh installer/totem/build-installer.ps1 -UseWorkingTree -WebView2BootstrapperPath C:\ci-cache\totem-webview2`
   imprime `WebView2:   bootstrapper embutido`. O `.exe` local não é versionado.
4. `runner-windows-diagnostico.yml` disparado **da branch**, com a variável criada, termina verde.
5. Depois do merge, o run do `instaladores-dev.yml` fica verde nos três serviços da `dev`. O `TotemSetup` de
   `dev-latest` cresce o tamanho do bootstrapper e o log do job mostra a linha do WebView2.

## Pendências operacionais (fora do código, antes do merge)

1. No runner `instaladores-win-01`: montar `C:\ci-cache\totem-webview2` pela receita do §6 e dar a ACL
   (`scripts/preparar-runner-windows.ps1` da branch, como administrador, ou `icacls` direto).
2. GitHub → Settings → Variables deste repositório: `TOTEM_WEBVIEW2_PAYLOAD_DIR = C:\ci-cache\totem-webview2`.
3. `runner-windows-diagnostico.yml` da branch verde.

## Entregue (27/10/2026)

- Manifesto com `payloads` nas quatro linhas (TEF e balança `[]`, PrintMonitor com os dois, totem com o
  WebView2) e `_comentario` atualizado.
- `instaladores-windows.yml`, job `empacotar`: `PAYLOADS: ${{ toJson(matrix.payloads) }}`, a linha
  `TOTEM_WEBVIEW2_PAYLOAD_DIR` no `env:` e o laço único no lugar do `if ($env:PAYLOAD -eq 'true')`. O laço
  desdobra o array com `ForEach-Object { $_ }`, porque o `ConvertFrom-Json` do Windows PowerShell 5.1 devolve o
  array como um objeto só (achado na simulação, ver abaixo). O resumo do job não ganhou linha própria do
  WebView2: o `build-installer.ps1` já imprime `WebView2:` no log do passo.
- `runner-windows-diagnostico.ps1` itera o manifesto; `-WebView2PayloadDir` entrou como override.
  `runner-windows-diagnostico.yml` com a variável no `env:`.
- `preparar-runner-windows.ps1` com `-WebView2PayloadDir` no `icacls`.
- `installer/totem/payload-webview2/README.md` + `.gitignore`.
- Guardas em `InstaladoresCiArchitectureTests`: forma de cada payload em `TodaLinhaDoManifesto_EstaViva`,
  `TodaVariavelDePayload_EstaNosDoisWorkflows`, `Empacotar_IteraOsPayloadsDoManifesto` e
  `Totem_DeclaraOBootstrapperDoWebView2`. O `build-installer.ps1` do totem não mudou.
- Docs: runbook (§5 com três payloads, §5.3 nova, §6 e §7), build local e `CLAUDE.md` (linha do totem,
  variável, armadilha **f** reescrita, **t** nova).

### Verificação

| O quê | Resultado |
|---|---|
| Guardas (`dotnet test`, backend `origin/dev`) | **88/88** (eram 85) |
| Pester | 60/60 |
| Laço do `empacotar` simulado com o manifesto real, pwsh 7 e 5.1 | TEF e balança sem parâmetro; PrintMonitor com `PayloadDir` + `DriversPayloadDir`; totem com `WebView2BootstrapperPath`; cache ausente ⇒ "Payload ausente" nomeando a variável |
| Diagnóstico local, cinco cenários | sem cache ⇒ `AVISO`; sem `webview2.sha256` ⇒ `FALHA`; hash certo ⇒ `OK`; `-ExigirPayload` ⇒ ausente vira `FALHA`; igual no 5.1 |
| Build local do totem com `-WebView2BootstrapperPath` | `TotemSetup-4.3.0.exe` compilado, log com `WebView2:   bootstrapper embutido`. Feito com um `.exe` **falso** num cache temporário (prova a canalização, não o binário da Microsoft); pacote apagado depois |

### Prova por mutação (revertida)

| Mutação | Reprovou |
|---|---|
| Diagnóstico sem a linha `TOTEM_WEBVIEW2_PAYLOAD_DIR` | `TodaVariavelDePayload_…` |
| `empacotar` volta a `PAYLOAD: ${{ matrix.payload }}` | `Empacotar_…` |
| `empacotar` com `$parametros.WebView2BootstrapperPath = …` por nome | `Empacotar_…` |
| Totem com `payloads: []` | `Totem_Declara…` |
| `parametro` que o script não declara | `Totem_Declara…` e `TodaLinhaDoManifesto_…` |
| Variável de payload repetida | `TodaLinhaDoManifesto_…` |

### Fica para depois do PR (critérios 4 e 5)

O cache não é visível desta sessão (`C:\ci-cache` não existe para ela) e montá-lo exige administrador no
runner. As pendências operacionais acima continuam, e o PR **não pode ser mesclado** antes delas: o push na
`dev` dispara o `instaladores-dev.yml`, e sem a variável o job do totem reprova.
