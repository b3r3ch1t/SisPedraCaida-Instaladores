# PRD-TOTEMINST-03 — Documentação cruzada e sincronização

> **Status:** Em andamento — §1, §3 e a sincronização feitos; #1275 do backend aberta, aguardando o merge do épico — **Última atualização:** 27/10/2026 17:15

## Objetivo

Os lugares que descrevem este repositório e a instalação do totem **fora dele** passam a dizer o mesmo que o
código: o instalador do totem vive aqui, tem guardas e o pacote do CI traz o WebView2. Os clones locais e a
configuração do runner ficam alinhados. Fecha a lacuna L5 do master.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | O runbook do totem continua no backend; só o trecho do pacote muda | Decisão D7 do PRD-REPOINST-00: docs de estação ficam ao lado do `Setup.exe` que provisiona |
| D2 | O backend recebe **dois** PRs só de documentação, sem build nem testes | Regra do `CLAUDE.md` do backend para alteração restrita a doc. O primeiro destrava a guarda do PRD-01; o segundo descreve o que o PRD-02 já entregou |
| D3 | O `CLAUDE.md` da raiz do workspace é editado direto | A raiz não é repositório git; não há PR |

## Mudanças

### 1. Backend — PR de doc antes do PRD-01

`docs/TotemInstalacaoWindows.md` §2: a linha "Silencioso" passa a mostrar `/CONTEUDOURL=` (opcional; vazio usa a
URL configurada no servidor), ao lado de `/APIURL=`, `/NOME=` e `/LOCAL=`. Os quatro são os que o `pages.iss`
lê. Branch `docs/totem-conteudourl` a partir da `dev` do backend, PR para a `dev`.

### 2. Backend — PR de doc depois do merge do PRD-02

`docs/TotemInstalacaoWindows.md` §6, item **WebView2**. Hoje:

> O pacote do CI sai **sem** ele (`payload: false` no `instaladores-ci.json`) …

Passa a dizer que o pacote do CI (`dev-latest`, `prod-latest` e `prod-vX.Y.Z` do SisPedraCaida-Instaladores)
**traz** o bootstrapper, vindo do cache `TOTEM_WEBVIEW2_PAYLOAD_DIR` do runner, e que o build local só o traz com
`-WebView2BootstrapperPath`. O item §1.1 (WebView2 Runtime no Windows 10) deixa de exigir instalação prévia.

### 3. `C:\repos\SisPedraCaida\CLAUDE.md` (raiz do workspace)

- **Adiantado em 27/10/2026, junto com este PRD:** na tabela, o Instaladores passa a listar o totem entre os
  agentes; o callout "Instaladores (desde 23/10/2026)" registra que `installer/totem/` está lá desde 24/10/2026 e
  aponta para este épico.
- **Ao fechar o PRD-02:** o callout ganha "o pacote do CI embute o bootstrapper do WebView2 a partir do cache do
  runner (`TOTEM_WEBVIEW2_PAYLOAD_DIR`); guardas `.iss` × C# do totem em `tests/…/Totem/`". Cabeçalho com a nova
  data, mantendo o "antes".

### 4. `CLAUDE.md` deste repositório

Cabeçalho final do épico: data, "épico `totem-instalador`", link para `PRD/DONE/totem-instalador/`.

## Pendências operacionais

1. **Clones locais:**
   - `C:\repos\SisPedraCaida\SisPedraCaida-Instaladores` está em `fix/permissoes-instaladores-dev` (já mesclada) e
     atrás da `origin/dev`: `git checkout dev && git pull`.
   - `C:\repos\SisPedraCaida\SisPedraCaida-Backend` está na `dev`, 15 commits atrás da `origin/dev`, ainda com os PRDs
     do totem em `DOING` e a pasta `installer/` que já saiu de lá: `git pull`.
   - Antes, conferir com `ListAgents` se outra sessão usa esses checkouts.
2. **Runner:** cache `C:\ci-cache\totem-webview2` e variável `TOTEM_WEBVIEW2_PAYLOAD_DIR` (detalhe no PRD-02).
3. **Herdadas do PRD-RUNWIN-01, só citadas aqui:** segredo `INSTALADORES_DISPATCH_TOKEN` no backend e, depois dele,
   `INSTALADORES_WINDOWS=true` no backend. Sem isso, os pushes do backend não disparam o empacotamento; o pacote
   do totem segue saindo pelos pushes deste repositório e pelos disparos manuais.

## Critérios de aceite

1. Os dois PRs de doc do backend mesclados na `dev` de lá.
2. `grep -i totem C:\repos\SisPedraCaida\CLAUDE.md` mostra o totem na linha do Instaladores e no callout.
3. Os dois clones locais na `dev`, sem commits atrás da `origin/dev`.
4. O master e as três etapas em `PRD/DONE/totem-instalador/`.

## Entregue (27/10/2026)

| Item | Estado |
|---|---|
| §1 — backend: `/CONTEUDOURL=` no runbook | [b3r3ch1t/SisPedraCaida-Backend#1272](https://github.com/b3r3ch1t/SisPedraCaida-Backend/pull/1272) **mesclada** (15:09 UTC) |
| §2 — backend: §1 e §6 do runbook dizem que o pacote do CI traz o WebView2 | [b3r3ch1t/SisPedraCaida-Backend#1275](https://github.com/b3r3ch1t/SisPedraCaida-Backend/pull/1275) **aberta**; mesclar depois da PR deste épico e do primeiro `TotemSetup` com WebView2 em `dev-latest` |
| §3 — `C:\repos\SisPedraCaida\CLAUDE.md` | feito: totem na tabela, callout com as guardas, o runbook como contrato e o WebView2/`payloads` |
| §4 — `CLAUDE.md` deste repositório | cabeçalho do PRD-01 e do PRD-02 feitos; o do fechamento entra com o master em `DONE` |
| Pendência 1 — clones locais | feito: `SisPedraCaida-Instaladores` saiu da `fix/permissoes-instaladores-dev` para a `dev`; `SisPedraCaida-Backend` avançou 43 commits na `dev` (`pull --ff-only`). A pasta não versionada `src/SisPedraCaida.Balanca.Agent/Properties/` do backend foi preservada |
| Pendência 2 — cache e variável no runner | **aberta** (PRD-02): `C:\ci-cache` não é visível desta sessão e a montagem exige administrador |
| Pendência 3 — herdadas do PRD-RUNWIN-01 | só citadas, como previsto |
