# Payload do QZ Tray

Esta pasta guarda o **instalador do QZ Tray** que o `PrintMonitorSetup-<versão>.exe` embute e
executa na estação antes de provisionar o agente.

## Por que payload local, e não download

O `QzTrayInstaller` do agente **recusa** `InstallerUrl` que não comece com `https://`
([`QzTrayInstaller.cs`](../../../src/SisPedraCaida.PrintMonitor.Infrastructure/Provisioning/QzTrayInstaller.cs)),
e a API do piloto está em **HTTP puro**. Com o QZ Tray já instalado pelo instalador, a etapa 3 do
`Setup.exe --all` encontra o executável e devolve **`Ignorado`** sem tocar em URL nem em SHA-256 —
sem nenhuma alteração de código.

Em troca, a verificação de integridade que o download dava passa a ser **do build**.

## O que colocar aqui

1. Baixe o instalador do QZ Tray da origem oficial, na versão homologada.
2. Copie **apenas esse `.exe`** para esta pasta (o build recusa mais de um executável aqui).
3. Crie `payload.sha256` com o hash conferido na origem, no formato:

```
<sha256-em-minúsculas>  qz-tray-<versão>.exe
```

O `build-installer.ps1` recalcula o hash e **falha o build** se divergir.

## O binário não é versionado

O `.exe` do QZ Tray e o `payload.sha256` ficam **fora do git** (ver `.gitignore` desta pasta):
binário grande de terceiro na árvore encarece todo clone e o hash muda a cada bump de versão. O que
é versionado é este README e a regra de verificação, que vive no script de build.

⚠️ Consequência operacional: a máquina que gera o instalador precisa ter o payload posicionado
antes do build. Sem ele, o build **prossegue** e produz um instalador sem o QZ Tray embutido — útil
para estação que já o tem, inútil para VM limpa.

## Licenciamento (etapa 04 §4)

O instalador **redistribui** binário de terceiro (QZ Tray, com JRE embutido). Antes do primeiro
release externo, confirme a licença da versão empacotada e inclua os avisos na pasta de instalação
e na tela de licença do wizard.
