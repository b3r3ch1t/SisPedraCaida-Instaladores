# PRD-TOTEMINST-00 — Consolidação do instalador do totem no SisPedraCaida-Instaladores (Master)

> **Status:** Em andamento — 01, 02 e 03 implementados; faltam o cache e a variável do WebView2 no runner, o merge e o run da `dev` — **Última atualização:** 27/10/2026 17:15

## Objetivo

Pôr o instalador do **totem de autoatendimento** (`TotemSetup-X.Y.Z.exe`, `installer/totem/`) no mesmo patamar
dos outros três instaladores deste repositório:

1. **Contrato `.iss` × C# com guarda.** Toda regra que o `.iss` espelha do C# do totem tem teste em `tests/`.
2. **Pacote de campo completo.** O pacote gerado pelo CI embute o bootstrapper do WebView2 Runtime.
3. **Documentação coerente.** Os lugares que descrevem este repositório e a instalação do totem dizem a mesma coisa.

## Estado de partida (27/10/2026)

O instalador **já existe e já é publicado**. Este épico não cria o instalador, consolida o que veio do backend.

| Item | Estado |
|---|---|
| `installer/totem/` (`Totem.iss`, `checks.iss`, `pages.iss`, `provisioning.iss`, `build-installer.ps1`) | Criado no backend pelo PRD-TOTEM-04 (backend #1226); veio para cá em 24/10/2026 com o PRD-REPOINST-00 |
| Linha `totem` em `installer/instaladores-ci.json` | `payload: false`, canais `dev` e `prod` |
| Releases | `TotemSetup-4.1.2.exe` em `dev-latest`, `prod-latest` e `prod-v4.1.2` |
| `prod` deste repositório | Promovida (#4 e #7); o runner `instaladores-win-01` está ligado (PRD-RUNWIN-01) |
| Código C# do totem | No backend: `src/SisPedraCaida.Totem.{Agent,Setup,Shell}` |
| Doc de estação | Backend, `docs/TotemInstalacaoWindows.md` (decisão D7 do PRD-REPOINST-00) |

### Lacunas que motivam o épico

| # | Lacuna | Risco |
|---|---|---|
| L1 | Nenhuma guarda `.iss` × C# cobre o totem. O `.iss` repete "alterar um lado exige alterar o outro" em vários pontos (códigos de saída, normalização da URL, rota da sonda) e nada confere | Rename no backend gera serviço órfão ou provisionamento que reprova só em campo |
| L2 | O totem está fora de `InstaladoresUpgradeArchitectureTests` (a `TheoryData` só tem `tefagent` e `printmonitor`) | Troca de AppId ou perda de `ignoreversion` passa verde |
| L3 | O CI não passa `-WebView2BootstrapperPath`; o pacote de campo sai **sem** o WebView2 | No Windows 10 sem o runtime a instalação só avisa e a tela fica "fora de serviço" |
| L4 | O `payload: true` do manifesto tem significado fixo no YAML (variáveis do PrintMonitor) | Um segundo serviço com payload vira `if` por serviço no YAML: segunda fonte de verdade, cega à guarda (armadilha h) |
| L5 | O `CLAUDE.md` da raiz do workspace não cita o totem; o runbook do backend diz que o CI sai sem WebView2 e não documenta `/CONTEUDOURL=` | A TI instala com informação errada |

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | As guardas do totem leem as constantes por **`ProjectReference`** a `SisPedraCaida.Totem.Agent` e `SisPedraCaida.Totem.Setup` | É o padrão das guardas do PrintMonitor: a constante compilada muda com o backend e o teste quebra na compilação. Os dois projetos são `net10.0` puro, consumíveis por `net10.0-windows`; o `PrintMonitor.Setup` (também `OutputType Exe`) já é referenciado do mesmo jeito. O `app.manifest` `requireAdministrator` vai só no apphost, que o testhost não carrega |
| D2 | `SisPedraCaida.Totem.Shell` **nunca** entra no projeto de testes | Armadilha #104a do backend: a casca é `net10.0-windows` (WinForms + WebView2) e não tem decisão. `TotemArchitectureTests` de lá proíbe a referência |
| D3 | O bootstrapper do WebView2 é **obrigatório no CI** e opcional no build local | Pacote de campo incompleto é a mesma classe de falha do QZ Tray: tudo verde e estação quebrada. Localmente se itera no `.iss` sem o payload |
| D4 | Os payloads passam a ser **declarados no manifesto** (`payloads[]` por linha) e o YAML e o diagnóstico só iteram a lista | Fecha L4; a guarda passa a conferir que a variável de cada payload está nos workflows |
| D5 | O totem entra na política de upgrade comum | Já cumpre os cinco critérios (AppId fixo, `ignoreversion`, `CloseApplications=no`, nada apagado em `{commonappdata}`, downgrade recusado com a frase padrão). Segue o modelo do PrintMonitor: upgrade no lugar, sem desinstalador anterior |
| D6 | No backend, **só documentação** | Nenhum contrato `.iss` × C# muda. O PR de doc vai antes do PR-01 aqui (a guarda de parâmetros lê o runbook de lá) e outro depois do 02 |
| D7 | Uma branch para o épico inteiro: `feat/totem-instalador`, a partir da `dev` | Regra do repositório (um épico = uma branch) |

## Etapas

| Arquivo | ID | Escopo | Depende de |
|---|---|---|---|
| `01 - Guardas-Iss-Vs-CSharp-Do-Totem.md` | PRD-TOTEMINST-01 | Guardas xUnit do totem e totem na política de upgrade | PR de doc no backend com `/CONTEUDOURL=` (pré-requisito, PRD-03 §1) |
| `02 - WebView2-Embutido-Pelo-CI.md` | PRD-TOTEMINST-02 | Payloads declarados no manifesto, cache do bootstrapper no runner, `empacotar`, diagnóstico, guardas e runbook | 01 (a guarda do 01 trava o lado `.iss` do WebView2) e o cache montado no runner |
| `03 - Documentacao-Cruzada-E-Sincronizacao.md` | PRD-TOTEMINST-03 | `CLAUDE.md` da raiz, runbook do backend, sincronização dos clones e pendências operacionais | 02 mesclado na `dev` |

Ordem: **03 §1 (doc no backend)** → **01** → **02** → **03 (restante)**. Cada arquivo vai para `DOING` quando
começa e para `DONE` quando seu critério de aceite fecha, individualmente.

## Critério de fechamento do épico

- 01, 02 e 03 em `PRD/DONE/totem-instalador/`.
- `ci.yml` e `commitlint.yml` verdes no PR para a `dev`.
- Depois do merge, o run do `instaladores-dev.yml` publica `TotemSetup-X.Y.Z.exe` em `dev-latest`, e o log do job
  do totem mostra `WebView2:   bootstrapper embutido (MicrosoftEdgeWebview2Setup.exe)`.
- `runner-windows-diagnostico.yml` verde com os **três** payloads.
- O `CLAUDE.md` deste repositório, o da raiz do workspace e o `docs/TotemInstalacaoWindows.md` do backend dizem
  que o pacote do CI traz o WebView2.

## Fora do escopo

- Automatizar a preparação da estação (conta `totem`, autologon, BitLocker, exceção de antivírus). Hoje é manual,
  em `docs/TotemInstalacaoWindows.md` §1 do backend, e mexe no `Setup.exe`. Fica para um épico próprio.
- WebView2 **Standalone** (~150 MB, instalação offline). O `.iss` foi desenhado para o bootstrapper Evergreen, que
  baixa o runtime na hora; o standalone só se surgir totem sem internet.
- Assinatura de código do pacote (decisão D6 do PRD-TEFINST-00: o `.sha256` publicado é a prova de integridade).
- Execução do roteiro manual `docs/TotemRoteiroValidacao.md` num terminal real (pendência do PRD-TOTEM-04 no
  backend).
