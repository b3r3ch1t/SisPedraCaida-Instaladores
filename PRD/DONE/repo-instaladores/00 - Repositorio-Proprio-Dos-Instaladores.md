# PRD-REPOINST-00 — Repositório próprio dos instaladores Windows

> **Status:** Concluído — **Última atualização:** 24/10/2026 12:07

## Objetivo

Tirar do `SisPedraCaida-Backend` os instaladores Inno Setup dos agentes de estação (TEF, PrintMonitor,
totem), o núcleo de empacotamento, o manifesto da matriz, o diagnóstico do runner, as guardas `.iss`
× C# e os workflows de empacotamento, e recriá-los aqui, sem perder nenhuma rotina de CI/CD existente.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | O código dos agentes **fica no backend**; os scripts pinam um clone dele num worktree (`-BackendRoot`, `Resolve-RaizDoBackend`) | Os agentes são projetos da solution do backend, com as guardas de arquitetura de lá; mover código C# quebraria o build e a cobertura dele |
| D2 | O `.iss` sai do checkout **deste** repositório; a procedência vira **dois SHAs** (`Origem` + `Scripts`) | O `.iss` já não está no commit do backend; imprimir os dois mantém o pacote reproduzível |
| D3 | Releases de instalador passam a viver **aqui** (`prod-vX.Y.Z` com a mesma tag do backend, e `dev-latest`) | Publicar no backend exigiria token com escrita lá; o instalador é artefato deste repositório |
| D4 | O backend **dispara** por `gh workflow run` (token `INSTALADORES_DISPATCH_TOKEN`); este repo lê o backend com `SISPEDRACAIDA_BACKEND_TOKEN` | `workflow_call` não cruza repositório privado de conta pessoal; o `GITHUB_TOKEN` não enxerga o outro repo |
| D5 | Jobs leves em `ubuntu-latest`; `testar`/`empacotar` no runner `[self-hosted, windows, instaladores]` **registrado neste repo** | Conta pessoal: runner é por repositório, os Linux self-hosted não servem aqui |
| D6 | As guardas `.iss` × C# viram o projeto `tests/SisPedraCaida.Instaladores.Tests`, com `ProjectReference` para o backend (`BackendDir`) e o caminho gravado no assembly | Precisam dos dois lados; o assembly diz contra qual árvore compilou |
| D7 | Docs de **estação** (`TefAgentInstalador.md` etc.) ficam no backend; só os de **empacotamento** vêm | Descrevem o `Setup.exe`, que é código do backend, e são referenciados por dezenas de armadilhas de lá |
| D8 | Tudo atrás de `INSTALADORES_WINDOWS`, nos dois repositórios | Não havia runner Windows nem variáveis em 23/10/2026; nada pode ficar enfileirado |

## Entregue

- `installer/**`, `scripts/runner-windows-diagnostico.ps1`, `artifacts/installer/**` (pacotes versionados),
  `docs/RunnerWindowsInstaladores.md`, `docs/InstaladoresBuildLocalWindows.md`.
- `Empacotamento.psm1`: `Resolve-RaizDoBackend` e `Get-ProcedenciaDosScripts` (+7 testes Pester, 60 no total, verdes no pwsh 7 e no 5.1).
- Totem (`installer/totem/`, 24/10/2026): entrou no backend pelo PRD-TOTEM-04 (#1226) depois do corte
  desta migração; `.iss` e includes vieram sem alteração, o `build-installer.ps1` ganhou o mesmo
  `-BackendRoot`/dois SHAs dos outros três e a linha `totem` (canais dev e prod) entrou no manifesto. A
  guarda do manifesto passa a exigir os 4 Windows services (`Totem.Agent` incluso).
- `build-installer.ps1` (3): `-BackendRoot`, cadeia local × cadeia do backend, `.iss` e payloads deste checkout. Validado gerando `TefAgentSetup-3.17.0.exe` de `origin/dev` do backend.
- Guardas: 57 testes (as 4 classes de guarda + 4 testes avulsos que estavam em classes de outro assunto no backend).
- Workflows: `instaladores-windows.yml`, `instaladores-dev.yml`, `runner-windows-diagnostico.yml`, `commitlint.yml`, `ci.yml` (novo: PR).
- Backend: instaladores, workflows e guardas removidos; `instaladores-dev.yml` vira disparador; job `instaladores` do `release-please-prod.yml` dispara por `gh workflow run`; docs e `CLAUDE.md` apontam para cá.

## Pendências operacionais (fora do código)

1. Criar o token fine-grained e os dois segredos (runbook §6.1).
2. Registrar o runner Windows **neste** repositório (runbook §4) e as variáveis de payload.
3. Diagnóstico verde → `INSTALADORES_WINDOWS=true` aqui e no backend.
