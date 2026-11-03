# PRD-ICC-INST-01 — Remoção do MigracaoGalileuSetup

> **Status:** Em andamento — **Última atualização:** 03/11/2026 13:40

| Campo | Valor |
|-------|-------|
| **Épico** | `importacao-cadastros-csv` (master no backend: `PRD-ICC-00`) |
| **Branch** | `feat/importacao-cadastros-csv` |

## 1. Escopo

O migrador Galileu sai do backend (`PRD-ICC-05`), substituído pela importação por CSV no Interno. Sai daqui:
`installer/migracao-galileu/`, a linha do manifesto `installer/instaladores-ci.json`, as guardas do `.iss`, os binários
`artifacts/installer/MigracaoGalileuSetup-5.21.0.*` e as citações em docs e workflows.

Ficam o tipo `aplicativo` e o campo `aguardaBackend` do manifesto, que são genéricos, e as releases já publicadas.

## 2. Ordem de merge

**Este PR entra antes do PR do backend:** a matriz daqui compila `Tools.MigracaoGalileu.App`, então remover o projeto
primeiro quebraria o empacotamento. É a exceção à regra "backend primeiro": aqui o backend perde um contrato.

## 3. Critérios de aceite

`dotnet test tests/SisPedraCaida.Instaladores.Tests` e `pwsh installer/common/Invoke-TestesEmpacotamento.ps1` verdes.
