# Payload do WebView2 Runtime (totem)

Esta pasta descreve o **bootstrapper do WebView2 Runtime** que o `TotemSetup-<versão>.exe` embute. Na
estação, o instalador o executa (`/silent /install`) **só quando a máquina não tem o runtime**, antes de
provisionar o totem. Sem o runtime, a tela do totem fica em "fora de serviço" (PRD-TOTEMINST-02).

## Qual binário

- **`MicrosoftEdgeWebview2Setup.exe`**, o *Evergreen Bootstrapper* oficial da Microsoft (cerca de 2 MB).
- Não tem versão no nome: na instalação ele **baixa** o runtime atual. O totem precisa de internet nesse
  momento, e o `provisioning.iss` já registra isso.
- Permalink oficial: `https://go.microsoft.com/fwlink/p/?LinkId=2124703`.
- O *Standalone* (cerca de 150 MB, offline) não é usado: o `.iss` foi desenhado para o bootstrapper.

## Como a procedência é provada

A Microsoft não publica SHA-256 do bootstrapper. A prova de origem é a **assinatura Authenticode**:
`Status = Valid` com o signatário `CN=Microsoft Corporation`. O `webview2.sha256` é gerado **depois** de
conferir a assinatura e pina a cópia do cache. O build recusa binário trocado
(`Resolve-BootstrapperWebView2` → `Resolve-PayloadVerificado -Obrigatorio`).

## Montar o cache no runner (ou numa máquina de build)

Num PowerShell **como administrador**, na máquina do runner:

```powershell
$pasta = 'C:\ci-cache\totem-webview2'
New-Item -ItemType Directory $pasta -Force | Out-Null
$exe = Join-Path $pasta 'MicrosoftEdgeWebview2Setup.exe'
Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $exe

$assinatura = Get-AuthenticodeSignature $exe
if ($assinatura.Status -ne 'Valid' -or $assinatura.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation') {
    Remove-Item $exe; throw "Assinatura inesperada: $($assinatura.Status) $($assinatura.SignerCertificate.Subject)"
}

$h = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
"$h  MicrosoftEdgeWebview2Setup.exe" | Set-Content (Join-Path $pasta 'webview2.sha256') -Encoding ascii

# Leitura para a conta do serviço do runner (NETWORK SERVICE) — o mesmo que o preparar-runner-windows.ps1 faz.
icacls $pasta /grant "*S-1-5-20:(OI)(CI)RX"
```

Depois, crie a variável de repositório **`TOTEM_WEBVIEW2_PAYLOAD_DIR`** = `C:\ci-cache\totem-webview2` e
rode o workflow `runner-windows-diagnostico.yml`. O passo a passo completo está no runbook
[`docs/RunnerWindowsInstaladores.md`](../../../docs/RunnerWindowsInstaladores.md) §5.3.

## No CI e no build local

- **CI:** obrigatório. O job `empacotar` reprova o totem com "Payload ausente" sem a variável ou sem o
  `.exe` na pasta. O payload é declarado em `installer/instaladores-ci.json` (`payloads` da linha `totem`).
- **Build local:** opcional. `pwsh installer/totem/build-installer.ps1 -WebView2BootstrapperPath <pasta>`
  embute o bootstrapper; sem o parâmetro, o pacote sai sem ele e o script avisa.

## Troca de versão

O bootstrapper é Evergreen e raramente precisa de troca. Quando a Microsoft publicar outro, baixe de novo,
confira a assinatura, regrave o `webview2.sha256` e rode o diagnóstico. Nunca "ajuste" o hash para o que
saiu sem conferir a assinatura.
