# PRD-MGGINST-01 — Instalador Windows do Migrador Galileu

> **Status:** Concluído — **Última atualização:** 31/10/2026 13:28

## Contexto

O Migrador Galileu → SisPedraCaida (épico `migracao-galileu` do backend, PR
b3r3ch1t/SisPedraCaida-Backend#1396, branch `feat/migracao-galileu`) é um assistente **WinForms**
(`SisPedraCaida.Tools.MigracaoGalileu.App`, `net10.0-windows`) que lê o MariaDB do Galileu e grava no
PostgreSQL por pacote `.sql`. O PRD-MGG-00 §9 de lá deixava o instalador fora de escopo, e a publicação era
só o `.exe` portátil de `scripts/migracao-galileu-publish.ps1`. O usuário mudou de ideia: a ferramenta passa a
ter instalador, no mesmo padrão dos agentes (TEF como modelo).

Diferente dos agentes, o migrador **não é Windows Service**, não tem provisionamento, configuração de rede
nem dados em `%PROGRAMDATA%`. O que ele grava é por usuário e criado pelo próprio app:

- `%APPDATA%\SisPedraCaida\MigracaoGalileu\ultima-sessao.json` (último preenchimento, senha por DPAPI);
- `%LOCALAPPDATA%\SisPedraCaida\MigracaoGalileu\restore\<execução>` (log e rejeitados quando a pasta do pacote
  é só leitura).

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | `installer/migracao-galileu/MigracaoGalileu.iss`, um arquivo só, sem `[Code]` de provisionamento | O app não provisiona nada: o instalador copia o layout, cria o atalho e recusa downgrade. Includes só existem nos agentes porque há wizard e `Setup.exe` |
| D2 | O `build-installer.ps1` chama o **`scripts/migracao-galileu-publish.ps1 -SkipZip` do backend pinado** | Mesmo princípio do TEF: o layout publicado é o contrato do `[Files]`; replicar o `dotnet publish` aqui criaria dois publicadores |
| D3 | Instalação por máquina (`{autopf}\SisPedraCaida\MigracaoGalileu`, admin), app `asInvoker` | Igual aos demais pacotes, e o técnico pode usar outra conta no mesmo servidor do Galileu. O app em si não pede elevação |
| D4 | Desinstalação **não** apaga `%APPDATA%`/`%LOCALAPPDATA%` | Elevado, `{userappdata}` seria o perfil do administrador, não do técnico; e a sessão anterior/log do restore são evidência da migração |
| D5 | `CloseApplications=yes` (Restart Manager) — o migrador **não** entra na teoria de identidade de `InstaladoresUpgradeArchitectureTests` (que exige `CloseApplications=no`), só nas de downgrade e `%PROGRAMDATA%` | Nos agentes quem para processo é o `Setup.exe`; aqui não há `Setup.exe`, e um assistente aberto travaria o `.exe` sobrescrito |
| D6 | Manifesto ganha `tipo` (`servico`, padrão; `aplicativo`) | `TodaLinhaDoManifesto_EstaViva` exigia que todo projeto da linha fosse Windows Service. Para `aplicativo` a regra é o `.csproj` existir em `src/` |
| D7 | Manifesto ganha `aguardaBackend` (texto: o PR do backend) | O código ainda não está na `dev` nem na `prod` do backend. Ver "Backend ainda não mesclado" |
| D8 | Canais `dev` e `prod`, como os demais | O pacote de campo sai da `prod-vX.Y.Z`; a guarda exige `prod` em toda linha |
| D9 | Guardas leem **código** do backend (`.csproj` e o publicador), nunca doc (armadilha u) | Nome do projeto/`.exe`, `WinExe`, TFM `-windows`, `asInvoker`, ícone e o contrato `-OutputPath/-Version/-Configuration/-SkipZip` do publicador. Leitura textual, sem `ProjectReference`: o App é casca WinForms (#104a do backend) e o projeto nem existe na `dev` de lá |

## Backend ainda não mesclado (D7)

Os `build-installer.ps1` pinam o backend em `-Ref` (default `prod`) e o CI roda as guardas contra a `dev`
(PR para a `dev`) ou a `prod` (PR para a `prod` e empacotamento de campo) **do backend** — nenhuma das duas tem
o migrador hoje. Sem tratamento, este PR nasceria com o `ci.yml` vermelho e todo dispatch de empacotamento
reprovaria o job `empacotar (migracao-galileu)`.

Com `aguardaBackend` preenchido na linha do manifesto:

- **guardas**: a linha pode apontar para projeto ausente de `src/`; as guardas do migrador, sem o projeto,
  conferem só o lado deste repositório (o `.iss` e o script) e não reprovam. Linha **sem** `aguardaBackend` e
  com projeto ausente reprova, como sempre;
- **job `matriz`**: linha com `aguardaBackend` cujo projeto não existe no backend daquele SHA sai da matriz
  com `::warning::` citando o PR — visível no run, não em silêncio (armadilha h);
- **build local**: `-Ref origin/feat/migracao-galileu` (ou o SHA) até o PR do backend mesclar.

Retirar o campo **só depois** de a `prod` do backend ter o migrador (como na armadilha x): antes disso o
`ci.yml` de PR para a `prod` e o empacotamento de campo reprovariam.

**Atualização 31/10/2026 13:02:** durante este trabalho o #1396 foi mesclado na `dev` do backend (`61e55ed27`).
O campo continua: a `prod` do backend ainda não tem o migrador. Prova da regra, num worktree descartável da `dev`
do backend com `src/SisPedraCaida.Tools.MigracaoGalileu.App` removido: com `aguardaBackend`, 105/105 verdes; sem o
campo, 3 vermelhos (`TodaLinhaDoManifesto_EstaViva` e as duas guardas do lado do backend). Contra a `prod` do
backend o projeto de testes nem compila hoje — armadilha x do PrintMonitor, anterior a este PRD.

## Mudanças

1. `installer/migracao-galileu/MigracaoGalileu.iss` + `build-installer.ps1` (D1–D5).
2. `installer/instaladores-ci.json`: linha `migracao-galileu` com `tipo` e `aguardaBackend` (D6–D8).
3. `instaladores-windows.yml` (job `matriz`): filtro de `aguardaBackend` com aviso.
4. `tests/…/Ci/InstaladoresCiArchitectureTests.cs`: `tipo` e `aguardaBackend`;
   `tests/…/Ci/InstaladoresUpgradeArchitectureTests.cs`: migrador nas teorias de downgrade e `%PROGRAMDATA%`;
   `tests/…/MigracaoGalileu/MigracaoGalileuInnoGuardTests.cs` (D9).
5. Docs: `CLAUDE.md` (tabela, manifesto, armadilha y), `README.md`, `docs/InstaladoresBuildLocalWindows.md`.

## Pronto quando

- `MigracaoGalileuSetup-X.Y.Z.exe` gerado localmente por
  `pwsh installer/migracao-galileu/build-installer.ps1 -Ref origin/feat/migracao-galileu`;
- Pester e `dotnet test` verdes contra a `dev` do backend **e** contra `feat/migracao-galileu`;
- PR aberto para a `dev` deste repositório.
