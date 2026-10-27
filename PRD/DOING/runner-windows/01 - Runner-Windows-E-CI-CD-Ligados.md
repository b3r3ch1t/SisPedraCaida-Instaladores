# PRD-RUNWIN-01 — Runner Windows registrado e CI/CD dos instaladores ligado

> **Status:** Em andamento — **Última atualização:** 27/10/2026 08:40

## Objetivo

Fechar as "pendências operacionais" do PRD-REPOINST-00: o pipeline de empacotamento existia, mas nunca
tinha rodado — nenhum runner `[self-hosted, windows, instaladores]`, nenhuma variável, segredo de disparo
ausente no backend e a `prod` deste repositório ainda no commit inicial (sem workflows), justamente a
branch que o backend dispara no canal de produção.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | Runner `instaladores-win-01` nesta máquina (`C:\actions-runner`, serviço como `NETWORK SERVICE`) | Runbook §4; caminho curto pela armadilha c (pior caso medido: 192 de 259) |
| D2 | `scripts/preparar-runner-windows.ps1` junta os passos de administrador, idempotente | Instalar em escopo de máquina, `LongPathsEnabled`, `--system`, ACL dos caches e `config.cmd --runasservice` exigem admin — uma sessão de código não os faz; o token de registro vai da API ao `config.cmd` sem ser impresso |
| D3 | PowerShell 7 pelo **MSI** da release oficial (hash pelo digest da API), não pelo winget | O manifesto de máquina do winget é `.msixbundle`: falhou com `0x80070005` e removeu o pwsh da Store do usuário (armadilha r) |
| D4 | Pacotes vão do runner **direto para a release** (`gh release upload`), sem `upload-artifact` | O primeiro ensaio gerou os três pacotes e reprovou por "Artifact storage quota has been hit": a cota é da conta (o backend guarda ~1,3 GB de `coverage-report`) e cada run da dev pesa ~350 MB (armadilha s) |
| D5 | Prod sem tag publica na móvel **`prod-latest`** (pré-lançamento), simétrica à `dev-latest` | Era "só artifact (90 dias)" — sem artifact, precisava de um destino; uma móvel mantém o link fixo e não polui as releases de campo |
| D6 | `concurrency` pela release de destino | O `preparar` da móvel limpa os assets: dois runs na mesma release se atropelariam |

## Entregue

- Máquina: pwsh 7.6.9 (MSI), Inno Setup 6.7.3, `LongPathsEnabled=1`, `core.longpaths` no `--system`,
  caches `C:\ci-cache\printmonitor-payload` (QZ Tray 2.3.0, SHA-256 = digest da release oficial, assinatura
  QZ Industries) e `C:\ci-cache\printmonitor-drivers` (Bematech 5.0.0.4, SHA-256 do README, assinatura
  Bematech com carimbo de tempo).
- GitHub: runner `instaladores-win-01` online; variáveis `PRINTMONITOR_PAYLOAD_DIR` e
  `PRINTMONITOR_DRIVERS_PAYLOAD_DIR`.
- Diagnóstico (`runner-windows-diagnostico.yml`) verde como `NETWORK SERVICE`, 60/60 Pester; o script
  agora confere `core.longpaths` no `--system` e o `gh` (necessário ao `empacotar`).
- `instaladores-windows.yml`: job `preparar`, upload direto do runner, `publicar` confere o que a release serve.

## Pendente

- Ensaio verde do canal dev com o fluxo novo.
- `INSTALADORES_WINDOWS=true` aqui e no backend.
- Segredo `INSTALADORES_DISPATCH_TOKEN` no backend (criado pelo dono da conta; Actions: write aqui).
- Promoção `dev` → `prod` deste repositório (a `prod` não tem workflow nenhum).
