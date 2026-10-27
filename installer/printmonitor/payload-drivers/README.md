# Payload de drivers (obrigatório)

Esta pasta guarda o instalador do **driver da impressora Bematech MP-4200 TH** (spooler do Windows
x64, v5.0.0.4) que o `PrintMonitorSetup-<versão>.exe` embute e **sempre instala** desde 21/10/2026
(PRD-PMTRAY-02). Antes era componente opcional ("Driver da impressora Bematech MP-4200 TH (USB)",
desmarcado); a tarefa e a página "Selecionar Tarefas Adicionais" saíram. O antigo `/DRIVERBEMATECH=1`
continua aceito e é ignorado.

Pasta separada de `payload/` de propósito: aquela aceita um único `.exe` (o QZ Tray), e o build
recusa ambiguidade.

## Origem e assinatura esperada

- Arquivo: `bematech-mp4200th-spooler-x64-5.0.0.4.exe` (13.109.440 bytes), instalador Inno Setup
  5.5.7, ProductName "Bematech Spooler Drivers x64 v5.0.0.4".
- SHA-256: `1c49eb59ffc89a8e4faeabf48d06160952d111fbdbc70b9afd36a5e34f66955c`.
- Assinatura Authenticode de `CN=BEMATECH S.A, O=BEMATECH S.A, L=SAO JOSE DOS PINHAIS, S=PARANA, C=BR`.
  O certificado expirou em 2019, mas a assinatura tem carimbo de tempo — confira com
  `Get-AuthenticodeSignature` antes de trocar o binário.
- `driver.sha256`, no formato `<sha256-em-minúsculas>  <arquivo>.exe`.

## O binário não é versionado — e o build não sai sem ele

O `.exe` e o `driver.sha256` ficam **fora do git** (ver `.gitignore` desta pasta). O
`build-installer.ps1` recalcula o hash, **falha o build** se divergir (ou se o `.sha256` nomear outro
arquivo) e copia o binário para o worktree pinado. **Sem o payload o build também falha**
(`Resolve-PayloadVerificado -Obrigatorio`), e o `.iss` faz `#error` sem `BematechDriverFile`: o pacote
sem driver deixou de existir.

No CI de prod o payload vem da variável de repositório **`PRINTMONITOR_DRIVERS_PAYLOAD_DIR`** (pasta no
runner `instaladores` com o `.exe` e o `driver.sha256`). ⚠️ Ela precisa ser criada no GitHub — sem ela o
job do PrintMonitor falha.

## Política de falha na estação

O driver roda **depois** do provisionamento, por `Exec()` + `ResultCode` com
`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`. Falha do driver **não** reprova a instalação do agente
(aviso na tela final e no log): reprovar deixaria a estação sem agente por causa de um driver. O
desinstalador do PrintMonitor não remove o driver.

## Pendências

- **Licença de redistribuição** do driver da Bematech não confirmada — registrar antes do primeiro
  release externo.
- Instalação silenciosa **não testada** numa estação real: o Windows pode pedir confirmação de
  instalação de driver e pode pedir reinício.
