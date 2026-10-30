# PRD-ELGPRE-02 — Partes do PrintMonitor remontadas por duplo clique

> **Status:** Em andamento — **Última atualização:** 30/10/2026 15:50

## Contexto

Épico `prerequisito-elgin-e-montagem`. O `PrintMonitorSetup-X.Y.Z.exe` (~185 MB) passa do limite de 100 MiB do
GitHub e é versionado em `artifacts/installer/` como `PrintMonitorSetup-X.Y.Z.zip.001`, `.002`… (armadilha **l**).
Em 30/10/2026 a TI não conseguiu juntar as partes do 5.14.0.

As partes estão **íntegras**: concatenadas, o zip abre e o `.exe` confere com o `.sha256` (verificado com o
`montar-instalador.ps1` no Windows PowerShell 5.1). O problema é o caminho de quem está fora do repositório:

- o Explorer não abre `.zip.001`, e o que existia para o cmd era a receita
  `copy /b ….zip.001+….zip.002+….zip.003 ….zip` — com uma **`.003` fixa** que o 5.14.0 não tem (são duas partes).
  O `copy` aborta com "O sistema não pode encontrar o arquivo especificado" e nada é montado;
- o `montar-instalador.ps1` exige o repositório inteiro (importa o `Empacotamento.psm1` ao lado dele).

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | `montar-instalador.cmd` **ao lado das partes**, versionado junto: duplo clique monta, extrai e confere | Só ferramentas do Windows 10+ (`copy /b`, `tar`, `certutil`); funciona com a pasta baixada avulsa |
| D2 | O `.cmd` descobre as partes (contíguas a partir de `.001`), nunca uma lista fixa | A lista fixa de três partes é a causa do incidente |
| D3 | Hash divergente apaga o `.exe` e termina com código ≠ 0 | A mesma regra do `montar-instalador.ps1`: instalador corrompido não fica na pasta parecendo bom |
| D4 | `New-PacoteZipEmPartes` copia o `.cmd` para a pasta das partes | O pacote sai sempre com o montador, sem passo manual no build |
| D5 | `/semPausa` no `.cmd` | O duplo clique pausa para o técnico ler o resultado; o Pester roda sem pausa |

## Mudanças

1. `installer/common/montar-instalador.cmd` (novo).
2. `Empacotamento.psm1`: `New-PacoteZipEmPartes` copia o `.cmd`; Pester cobre a cópia, a montagem pelo `.cmd`
   (ida e volta) e a recusa com parte corrompida.
3. `montar-instalador.ps1`, `build-installer.ps1` do PrintMonitor e `CLAUDE.md`: a receita do `copy /b` sai; entra o
   `.cmd`.
4. `artifacts/installer/montar-instalador.cmd` versionado ao lado do `PrintMonitorSetup-5.14.0.zip.001/.002`.
5. Backend: `docs/PrintMonitorInstalador.md` §2.2.1 (mesmo PR de documentação do PRD-ELGPRE-01).

## Critérios de aceite

- Pasta só com `PrintMonitorSetup-X.Y.Z.zip.00N` + `montar-instalador.cmd`: duplo clique produz o `.exe` e o
  `.sha256`, e diz que o hash confere.
- Parte corrompida ou faltando: mensagem clara, código ≠ 0, nenhum `.exe` deixado na pasta.
- Pester verde no Windows PowerShell 5.1 e no pwsh.
