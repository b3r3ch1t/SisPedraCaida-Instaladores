# PRD-ELGPRE-01 — Instalador do TEF bloqueia sem o Elgin TEF HUB e o E1_Connect

> **Status:** Em andamento — **Última atualização:** 30/10/2026 15:50

## Contexto

Épico `prerequisito-elgin-e-montagem`. Desde o PRD-TEFHUB-01 (D7-bis, 15/10/2026) o `TefAgentSetup-X.Y.Z.exe`
detecta o Elgin TEF HUB e, quando ausente, **baixa** o instalador oficial (~396 MB, Git LFS do repositório da Elgin)
e o executa com `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.

Em campo (30/10/2026) o wizard **trava** nessa etapa, na instalação do TEF HUB e do E1_Connect. O pacote da Elgin
não é um produto só: ele encadeia os instaladores dos componentes (E1_Connect, E1_ETH_Service, providers 2/3/5 —
tabela "Componentes" do README de `ElginTEFHUB/ELGIN TEF HUB/Instaladores Windows`). O `/VERYSILENT` que passamos
vale para o instalador externo; o que os componentes fazem com a janela deles não está sob nosso controle, e o
`Exec(..., ewWaitUntilTerminated)` espera para sempre.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | O instalador **não baixa nem instala** mais nada da Elgin — volta a D7 original | Pedido do usuário. O instalador de terceiro encadeado não é controlável em silêncio, e o travamento deixa o balcão sem nada |
| D2 | TEF HUB **e** E1_Connect são pré-requisitos **bloqueantes**, conferidos em `InitializeSetup` | Pedido do usuário: "parar a instalação até que o requisito seja atendido". Antes da primeira página, antes de copiar um arquivo |
| D3 | No interativo, um diálogo com o link e três saídas: **abrir a página de download**, **verificar novamente**, cancelar | O técnico instala o TEF HUB com o diálogo aberto e segue sem reabrir o nosso instalador |
| D4 | O link é a **pasta** "Instaladores Windows" do repositório oficial, não a URL do `.exe` | O `.exe` é ponteiro de Git LFS (134 bytes pelo `raw`), e a pasta mostra x64/x86 e as notas de versão. O E1_Connect vem dentro do pacote do TEF HUB: um link só |
| D5 | Em `/SILENT`/`/VERYSILENT` a ausência **reprova** (`InitializeSetup` = False, código de saída 1) com a razão no log | Rollout silencioso não pode instalar um caixa que não processa cartão e devolver sucesso |
| D6 | `/SEMTEFHUB=1` continua **aceito e ignorado** (registrado no log) | Scripts de rollout ainda podem passá-lo; ele significava "não baixar", e nada é baixado agora. Não vira válvula para pular a checagem: D2 |
| D7 | Detecção pelo registro de desinstalação, visão de 32 bits, AppId exato com varredura por nome de rede de segurança — a mesma regra para os dois produtos | É a regra já validada para o TEF HUB (os dois são x86, sob `WOW6432Node`). AppId do E1_Connect levantado num terminal com o 02.01.00: `{28910153-EEED-4710-BBD3-7B6BADF2E103}_is1` |

## Mudanças

1. `installer/tefagent/tefhub.iss`: sai a página de download, o SHA-256 e o `Exec` do instalador da Elgin; entra
   `GarantirPreRequisitosElgin` (diálogo com link + nova verificação; reprova no silencioso).
2. `installer/tefagent/checks.iss`: detecção genérica por produto (`ProdutoElginInstalado`), `E1ConnectInstalado`,
   linhas da tela de pré-requisitos sem "a instalação CONTINUA".
3. `installer/tefagent/TefAgent.iss`: `InitializeSetup` chama a checagem; sai `CriarPaginaDownloadTefHub` e a
   chamada no `wpReady`.
4. Guarda `tests/…/TefAgent/TefAgentPreRequisitosElginGuardTests.cs`: nada de download no `.iss` do TEF, os dois
   AppIds declarados e a checagem no `InitializeSetup`.
5. Backend: `docs/TefAgentInstalador.md` §1.3 e D7-bis (PR próprio, só documentação).

## Critérios de aceite

- Terminal sem TEF HUB (ou sem E1_Connect): o instalador mostra o link antes da primeira página e não segue até os
  dois aparecerem no registro ou o operador cancelar.
- Terminal com os dois: nenhuma mudança de fluxo (sem diálogo, sem download).
- `/VERYSILENT` sem os dois: sai com código ≠ 0 e `BLOQUEIO` no log.
- ISCC compila o `.iss` do TEF; guardas e Pester verdes.
