# PRD-PMSEL-INST-01 — Instalador do PrintMonitor sem o driver da Bematech

> **Status:** Concluído — **Última atualização:** 29/10/2026 17:14

## Contexto

Épico `printmonitor-selecao-impressora`. O parque passou a ter vários modelos de impressora térmica: o técnico
escolhe a impressora no PrintMonitor (`Setup.exe --config-ui`) e instala o driver do modelo por fora. O
`PrintMonitorSetup-X.Y.Z.exe` embute e instala **sempre** o driver da Bematech MP-4200 TH desde o PRD-PMTRAY-02
(armadilha **#112f** do backend), o que deixa de fazer sentido: numa estação com outra impressora ele instala um
driver inútil, e o pacote não sai sem o binário (`#error` no `.iss` e `Resolve-PayloadVerificado -Obrigatorio`).

A parte do backend/agente (seleção da impressora, inventário, padrão da estação) é outra peça do épico, no
`SisPedraCaida-Backend`. Esta etapa é só este repositório e **não depende dela**: o `.iss` não troca nenhum
contrato com o C# ao perder o driver.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | O instalador do driver é **removido** do pacote, não vira opção | Decisão do usuário: o driver é do modelo, e o modelo é escolha do técnico. Uma tarefa opcional reabriria a página "Selecionar Tarefas Adicionais" para um único modelo |
| D2 | `/DRIVERBEMATECH=1` continua **aceito e ignorado** | Scripts de rollout de campo ainda podem passá-lo; o Inno não reclama de parâmetro desconhecido. Registrado no cabeçalho do `PrintMonitor.iss` |
| D3 | Upgrade **não** desinstala o driver | Ele tem desinstalador próprio e serve à impressora (outros programas podem usá-la). A estação que já o tem o mantém |
| D4 | `-DriversPayloadDir` sai do `build-installer.ps1` (não fica aceito e ignorado) | O CI só passa o que o manifesto declara, e o workflow vem do mesmo commit do script; quem roda à mão recebe erro de parâmetro e o runbook novo |
| D5 | O cache `C:\ci-cache\printmonitor-drivers` e a variável `PRINTMONITOR_DRIVERS_PAYLOAD_DIR` só são apagados **depois** da promoção `dev` → `prod` deste repo | A `prod` daqui ainda exige o driver até a promoção; a reemissão de prod quebraria sem o cache |
| D6 | O núcleo `Resolve-PayloadVerificado -Obrigatorio` fica | Continua servindo ao WebView2 do totem; os testes Pester dele trocam o exemplo do driver pelo do WebView2 |

## Mudanças

1. `installer/printmonitor/PrintMonitor.iss`: sai `BematechDriverFile` e o `#error`, a entrada de `[Files]`
   do driver, o `ResumoDriverBematech()` da tela final e os comentários de `[Tasks]`; o cabeçalho registra
   `/DRIVERBEMATECH=1` como descontinuado (aceito e ignorado).
2. `installer/printmonitor/provisioning.iss`: sai `InstalarDriverBematech` (e as variáveis e o resumo que só
   serviam a ele).
3. `installer/printmonitor/build-installer.ps1`: sai `-DriversPayloadDir`, `Resolve-PayloadDrivers` e
   `/DBematechDriverFile`.
4. `installer/printmonitor/payload-drivers/` removida; entrada do payload no `installer/instaladores-ci.json`
   removida; `PRINTMONITOR_DRIVERS_PAYLOAD_DIR` sai do `env:` dos dois workflows e dos scripts do runner.
5. Guardas xUnit: a do driver obrigatório vira guarda de **ausência** (nada de driver no pacote, nem no
   build) e de `/DRIVERBEMATECH` documentado; a de upgrade deixa de ancorar a ordem no driver.
6. Docs: `InstaladoresBuildLocalWindows.md`, `RunnerWindowsInstaladores.md` e o `CLAUDE.md` do repo.

## Critérios de aceite

- [x] Pester (`Invoke-TestesEmpacotamento.ps1`) e guardas (`dotnet test tests/SisPedraCaida.Instaladores.Tests`) verdes.
- [x] `build-installer.ps1` gera o `PrintMonitorSetup-X.Y.Z.exe` sem `payload-drivers` nem `-DriversPayloadDir`.
- [x] Nenhuma referência a `BematechDriverFile`, `payload-drivers` ou `PRINTMONITOR_DRIVERS_PAYLOAD_DIR` fora de PRDs concluídos e do histórico.
- [x] PR para a `dev`.

## Pós-merge (operador)

- Depois da promoção `dev` → `prod` **deste** repositório: apagar a variável `PRINTMONITOR_DRIVERS_PAYLOAD_DIR`
  e o cache `C:\ci-cache\printmonitor-drivers` no runner (D5).
- Backend: `docs/PrintMonitorInstalador.md` e a armadilha **#112f** ainda descrevem o driver obrigatório —
  atualizar na peça do backend do épico.
