; ============================================================================================
;  Totem de autoatendimento — instalador do terminal Windows (Inno Setup 6)
;  Épico: totem-autoatendimento (PRD-TOTEM-04 §1)
;
;  Compile SEMPRE por `build-installer.ps1`: ele publica o layout self-contained dos três
;  executáveis e injeta as definições abaixo por /D no ISCC. Compilar este arquivo direto na IDE
;  falha de propósito (as definições não existem).
;
;  Decisão arquitetural central (a mesma do agente TEF, Master D3): o instalador COPIA ARQUIVOS;
;  quem provisiona é o `Setup.exe`, que é código C# testado. Este script não registra serviço, não
;  grava configuração, não escreve a chave Run e não mexe nas políticas da sessão — duplicar isso
;  criaria dois lugares para a mesma regra, e o daqui sem teste nenhum.
;
;  Diferença deliberada para o TEF: o upgrade é NO LUGAR (como o do PrintMonitor), sem rodar o
;  desinstalador anterior. O `--all` já para, re-registra e reinicia o serviço, e desinstalar antes
;  restauraria as políticas da sessão só para o serviço reaplicá-las segundos depois — com o totem
;  exposto no intervalo.
; ============================================================================================

#ifndef AppVersion
  #error Defina AppVersion pelo build-installer.ps1 (/DAppVersion=...)
#endif
#ifndef PublishDir
  #error Defina PublishDir pelo build-installer.ps1 (/DPublishDir=...)
#endif

; Caminho ABSOLUTO do bootstrapper do WebView2 Runtime (MicrosoftEdgeWebview2Setup.exe), já
; conferido por SHA-256 no build. Opcional: sem ele o pacote sai sem o componente e a checagem só
; AVISA que o runtime está ausente — a casca mostra "fora de serviço" sem o runtime, o que não é
; motivo para recusar a instalação (o serviço, a identidade e o sinal com a API funcionam sem ele).
#ifndef WebView2Bootstrapper
  #define WebView2Bootstrapper ""
#endif
#if WebView2Bootstrapper != ""
  #define WebView2BootstrapperNome ExtractFileName(WebView2Bootstrapper)
#else
  #define WebView2BootstrapperNome ""
#endif

#define AppNome "SisPedraCaida Totem de Autoatendimento"

; Editor do pacote: o nome fantasia de quem desenvolve o sistema (mesmo texto do TEF e do
; PrintMonitor). ⚠️ Se o pacote passar a ser assinado, precisa BATER com o subject do certificado.
#define AppPublisher "B3R3CH1T Desenvolvimento de Sistemas"
#define AppCopyright "© 2026 B3R3CH1T Desenvolvimento de Sistemas"
#define AppSuporteEmail "anderson.meneses@gmail.com"

; Nomes que o Setup.exe, o serviço e a casca também usam — a fonte única é TotemPaths (C#). Os
; literais aqui só servem ao instalador para achar os arquivos e o serviço; alterar lá exige alterar
; aqui, senão o upgrade para "o serviço de antes do rename" e deixa o novo rodando por cima.
#define SetupExe "SisPedraCaida.Totem.Setup.exe"
#define AgenteExe "SisPedraCaida.Totem.Agent.exe"
#define CascaExe "SisPedraCaida.Totem.Shell.exe"
#define ServicoNome "SisPedraCaida.Totem.Agent"

; Pasta de dados do totem. NÃO é removida na desinstalação: ali vivem a identidade (gerada uma vez —
; apagá-la faz a mesma máquina virar um totem novo no painel), a configuração deste terminal, o
; estado anterior das políticas da sessão e os logs.
#define PastaDados "{commonappdata}\SisPedraCaida\Totem"

[Setup]
; AppId é a IDENTIDADE da instalação: gerado uma única vez e NUNCA alterado. Trocá-lo faz o pacote
; novo não reconhecer o antigo — duas entradas em "Programas e Recursos" e dois conjuntos de
; binários brigando pelo mesmo nome de serviço. Próprio, nunca o do TEF ou do PrintMonitor: os três
; podem conviver na mesma máquina.
AppId={{C9D9108B-9DB0-450D-986B-7470728B6123}
AppName={#AppNome}
AppVersion={#AppVersion}
AppVerName={#AppNome} {#AppVersion}
AppPublisher={#AppPublisher}
AppCopyright={#AppCopyright}
AppContact={#AppSuporteEmail}
AppSupportURL=mailto:{#AppSuporteEmail}

VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoCopyright={#AppCopyright}
VersionInfoProductName={#AppNome}
VersionInfoDescription=Instalador do {#AppNome}
DefaultDirName={autopf}\SisPedraCaida\Totem
DefaultGroupName=SisPedraCaida
DisableProgramGroupPage=yes
OutputBaseFilename=TotemSetup-{#AppVersion}
OutputDir=..\..\artifacts\installer

; Ícone do TotemSetup-<versão>.exe, relativo a ESTE .iss e compartilhado com os outros instaladores.
; ⚠️ O ícone da entrada em "Aplicativos e Recursos" vem do UninstallDisplayIcon, ou seja, do ícone
; EMBUTIDO no Setup.exe (o ApplicationIcon do .csproj) — são dois lugares.
SetupIconFile=..\assets\sispedracaida.ico
UninstallDisplayIcon={app}\{#SetupExe}
UninstallDisplayName={#AppNome}

; Registro de serviço, chave Run da máquina, hive do usuário do totem e %PROGRAMDATA% exigem elevação.
PrivilegesRequired=admin

; Pacote win-x64 (o layout é publicado para esse RID).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Windows 10 1607 — piso técnico do runtime .NET; o WebView2 Runtime cobre Windows 10 e 11.
MinVersion=10.0.14393

; O layout self-contained dos três executáveis (runtime .NET + WindowsDesktop + WebView2) passa
; de 100 MB.
Compression=lzma2/max
SolidCompression=yes

; Log sempre gravado, mesmo sem /LOG. O log registra a linha de comando: nada aqui é segredo
; (endereço, nome, local e URL do conteúdo) — a credencial do totem é emitida pela API e gravada
; pelo serviço, nunca passa pelo instalador.
SetupLogging=yes

; Quem para o serviço e fecha a casca é o provisioning.iss, na ordem certa (serviço parado e
; confirmado → casca → o resto da pasta). Deixar o Inno fechar processos por conta própria
; atropela essa sequência — e o watchdog do serviço relançaria a casca que ele fechasse.
CloseApplications=no

WizardStyle=modern
ShowLanguageDialog=no

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
; ignoreversion é OBRIGATÓRIO: sem ele o Inno compara versão de arquivo e PULA binários, produzindo
; layout misturado entre duas versões. É também a razão de a configuração viver em %PROGRAMDATA%.
; restartreplace + uninsrestartdelete: lição do PrintMonitor (PRD-PMTRAY-04, #112h) — se algum
; processo escapar do fechamento por caminho e travar um arquivo, ele é trocado no PRÓXIMO REINÍCIO
; em vez de parar a instalação na caixa "DeleteFile falhou; código 5".
; ⚠️ Em /VERYSILENT sem /NORESTART o Inno REINICIA a máquina sozinho quando isso acontece: distribua
; com /NORESTART.
Source: "{#PublishDir}\*"; DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs ignoreversion restartreplace uninsrestartdelete; \
  Excludes: "*.pdb,appsettings.Development.json"

#if WebView2Bootstrapper != ""
; Extraído só quando o runtime falta na máquina; instalado por Exec()+ResultCode no
; provisioning.iss, ANTES do provisionamento — o [Run] ignoraria o código de saída (#101a).
Source: "{#WebView2Bootstrapper}"; DestDir: "{tmp}"; DestName: "{#WebView2BootstrapperNome}"; \
  Flags: deleteafterinstall; Check: WebView2DaMaquinaAusente
#endif

[Icons]
; A superfície que torna o endereço da API, o nome, o local e a URL do conteúdo editáveis sem
; reinstalar. O Setup.exe pede elevação pelo próprio manifesto (requireAdministrator) — não há
; flag `runas` aqui.
Name: "{group}\Configurar o totem"; Filename: "{app}\{#SetupExe}"; \
  Parameters: "--config-ui"; Comment: "Alterar o endereço da API, o nome, o local e o conteúdo deste totem"

; Estado da instalação (serviço, identidade, credencial, API, sessão bloqueada, tela no logon).
Name: "{group}\Estado do totem"; Filename: "{app}\{#SetupExe}"; \
  Parameters: "--status"; Comment: "Mostrar o estado do serviço e da identidade deste totem"

; ⚠️ SEM seção [Registry]: a chave HKLM\...\Run da casca é escrita pelo `Setup.exe --all` e removida
; pelo `--uninstall` (InicioDaCascaWindows). Escrever também aqui seria a segunda fonte da mesma
; regra — e o uninsdeletevalue do Inno apagaria o valor antes de o --uninstall conferir o estado.

[Run]
; Abre a casca ao fim da instalação INTERATIVA, para o técnico ver o ícone sem encerrar a sessão.
; ⚠️ `runasoriginaluser` é obrigatório: o instalador roda ELEVADO, e a casca é `asInvoker` de
; propósito — elevada, ela nasceria no contexto do administrador e com um privilégio que existe para
; não ter. ⚠️ `nowait`: a casca é residente. ⚠️ Apresentação, não provisionamento: o [Run] IGNORA o
; código de saída (#101a), e por isso o provisionamento está em Exec()+ResultCode no provisioning.iss.
; ⚠️ `Check: TotemProvisionado`: numa instalação reprovada a casca não sobe.
; No silencioso (e nos logons seguintes) quem sobe a casca é a chave Run; com o totem em uso, o
; watchdog do serviço a relança em até 15 s.
Filename: "{app}\{#CascaExe}"; \
  Description: "Abrir a tela do totem agora"; \
  Flags: runasoriginaluser nowait postinstall skipifsilent; Check: TotemProvisionado

; ⚠️ SEM [UninstallRun]: o `Setup.exe --uninstall` é chamado por Exec() no
; CurUninstallStepChanged(usUninstall), DEPOIS de o serviço parar e a casca fechar e ANTES da
; remoção dos arquivos — por código, para conferir o ResultCode: falha ali pode deixar a conta do
; totem sem Gerenciador de Tarefas e sem Executar, e o operador precisa saber.
;
; ⚠️ NADA de [Dirs]/[UninstallDelete] sob {commonappdata} (#101b): `identidade.json` é a identidade
; do totem, `estado-bloqueio.json` é o que permite restaurar as políticas da sessão, e
; `totem.settings.json` é a configuração que precisa sobreviver a uma reinstalação.

[Code]
#include "checks.iss"
#include "pages.iss"
{ Depois de checks.iss e pages.iss de propósito: consome as checagens de um e os valores do outro.
  ⚠️ Comentário aqui é de chaves ou barra dupla, NUNCA ponto e vírgula: dentro desta seção o
  compilador lê Pascal. E comentário de chaves NÃO aninha: um fecha-chave no meio do texto encerra o
  comentário ali, e o resto da linha vira código — por isso nenhuma constante do Inno aparece
  escrita dentro destes comentários. }
#include "provisioning.iss"

{ ------------------------------------------------------------------------------------------
  Eventos do instalador. Mantidos por último porque consomem o que os includes declaram.
  ------------------------------------------------------------------------------------------ }

{ Bloqueio de downgrade: o Inno instala um pacote antigo por cima sem reclamar, e o totem volta no
  tempo em silêncio. }
function InitializeSetup(): Boolean;
var
  VersaoInstalada: String;
begin
  Result := True;

  if not ChecagensBloqueantesAprovadas() then
  begin
    Result := False;
    Exit;
  end;

  { Resolvido AQUI, e não só no wizard: em /VERYSILENT nenhuma página customizada roda.
    ⚠️ A validação SÓ no silencioso (WizardSilent): sem a guarda, o interativo recusaria a instalação
    antes de a primeira página abrir, exigindo por linha de comando o que a página ia perguntar (#101). }
  ValoresIniciais();
  if WizardSilent() and (not ValidarParametrosSilenciosos()) then
  begin
    Result := False;
    Exit;
  end;

  VersaoInstalada := VersaoJaInstalada();
  if (VersaoInstalada <> '') and (CompareVersaoInstalada(VersaoInstalada, '{#AppVersion}') > 0) then
  begin
    SuppressibleMsgBox('Uma versão mais recente do ' + '{#AppNome}' + ' já está instalada neste terminal (' +
           VersaoInstalada + '). Instalar a versão {#AppVersion} por cima faria o totem regredir.' + #13#10#13#10 +
           'Desinstale a versão atual antes, se a regressão for intencional.',
           mbError, MB_OK, IDOK);
    Log('[Totem] BLOQUEIO: downgrade de ' + VersaoInstalada + ' para {#AppVersion}.');
    Result := False;
  end;
end;

procedure InitializeWizard();
begin
  CriarPaginasDoWizard();
end;

{ Na tela final, o caminho do log do provisionamento e o que ficou pendente (WebView2). Sem isso o
  operador vê só "instalado" e descobre a tela "fora de serviço" no primeiro cliente. }
procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID <> wpFinished then
    Exit;

  WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
    TextoFinalDoProvisionamento() + #13#10#13#10 +
    'Para alterar o endereço da API, o nome ou o local depois, use o atalho "Configurar o totem" ' +
    'no menu Iniciar. O totem aparece no painel aguardando liberação.';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := ValidarPagina(CurPageID);
end;

{ Resumo da tela "Pronto para instalar". }
function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
            'Terminal:' + NewLine +
            Space + 'Nome: ' + TextoOuNaoInformado(ValorNome) + NewLine +
            Space + 'Local: ' + TextoOuNaoInformado(ValorLocal) + NewLine + NewLine +
            'Conexão:' + NewLine +
            Space + 'Endereço da API Interno: ' + ValorApiUrl + NewLine +
            Space + 'URL do conteúdo: ' + TextoOuPadrao(ValorConteudoUrl, '(a informada pelo servidor)') + NewLine +
            NewLine + 'WebView2 Runtime:' + NewLine +
            Space + LinhaDoWebView2() + NewLine;

  if InstalacaoAnteriorPresente() then
    Result := Result + NewLine + 'Instalação anterior (' + VersaoJaInstalada() + ' → {#AppVersion}):' + NewLine +
              Space + 'O serviço será parado (com confirmação) e a tela do totem fechada antes da cópia;' + NewLine +
              Space + 'no fim, o serviço volta a rodar. Identidade e configuração gravadas são preservadas.' + NewLine;
end;

{ Roda depois da tela "Pronto para instalar" e antes de o primeiro arquivo ser copiado — inclusive
  no silencioso. É o ponto certo para tirar do caminho o que trava os binários. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := ChecagensDePreparacao();

  if Result = '' then
    Result := PrepararUpgrade();
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    ExecutarProvisionamento();
end;

{ Desinstalação: o usUninstall vem depois da confirmação do usuário e ANTES da remoção dos
  arquivos. Para o serviço (confirmando a parada), fecha a casca e tudo o que roda da pasta e só
  então chama o Setup.exe --uninstall, que remove o serviço e a casca do logon e restaura as
  políticas da sessão. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    DesprovisionarParaDesinstalar();
end;
