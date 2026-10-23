; ============================================================================================
;  PrintMonitor — instalador da estação Windows 10 (Inno Setup 6)
;  Épico: printmonitor-installer-windows10 (etapas 02, 03, 04, 06 e 08)
;
;  Compile SEMPRE por `build-installer.ps1`: ele publica o layout self-contained do agente,
;  confere o hash do payload do QZ Tray e injeta as definições abaixo por /D no ISCC.
;  Compilar este arquivo direto na IDE falha de propósito (as definições não existem).
;
;  Decisão arquitetural central (Master §4): o instalador COPIA ARQUIVOS; quem provisiona é o
;  `Setup.exe` já existente e testado. Este script não registra serviço, não escreve a Run key
;  e não gera o AgentId — duplicar isso criaria dois lugares para a mesma regra, e o daqui sem
;  teste nenhum.
; ============================================================================================

#ifndef AppVersion
  #error Defina AppVersion pelo build-installer.ps1 (/DAppVersion=...)
#endif
#ifndef PublishDir
  #error Defina PublishDir pelo build-installer.ps1 (/DPublishDir=...)
#endif
#ifndef QzInstallerFile
  ; Nome do arquivo do payload do QZ Tray dentro de payload/. Vazio = instalador sem payload
  ; (permitido: estação que já tem o QZ Tray instalado — a etapa 3 do Setup.exe reporta Ignorado).
  #define QzInstallerFile ""
#endif
#ifndef BematechDriverFile
  ; Nome do instalador do driver da Bematech MP-4200 TH dentro de payload-drivers/ (PRD-PMTRAY-02).
  #define BematechDriverFile ""
#endif
#if BematechDriverFile == ""
  ; O driver da Bematech é OBRIGATÓRIO desde PRD-PMTRAY-02: o pacote sem ele deixou de existir. O
  ; build-installer.ps1 também reprova sem o payload (Resolve-PayloadVerificado -Obrigatorio).
  #error Defina BematechDriverFile pelo build-installer.ps1: o driver da Bematech MP-4200 TH e obrigatorio.
#endif

#define AppNome "SisPedraCaida PrintMonitor"
#define AppPublisher "SisPedraCaida"
#define SetupExe "SisPedraCaida.PrintMonitor.Setup.exe"
#define ServicoNome "SisPedraCaidaPrintMonitor"

; Bandeja do sistema (épico printmonitor-systray, PRD-PMTRAY-01). O nome do VALOR na chave Run é fixo e
; próprio: trocá-lo numa versão futura deixaria o valor antigo órfão apontando para um binário removido, e
; a bandeja subiria duas vezes enquanto as duas versões convivessem na estação.
#define BandejaExe "SisPedraCaida.PrintMonitor.Tray.exe"
#define BandejaValorRun "SisPedraCaidaPrintMonitorTray"

; Processos que vivem na pasta {app} e travam os binários (upgrade no lugar, PRD-PMTRAY-03 — upgrade.iss).
; Espelham InstallOptions (Service/Helper/BootstrapperExecutableName); guarda em InstaladorUpgradeGuardTests.
#define ServicoExe "SisPedraCaida.PrintMonitor.Service.exe"
#define HelperExe "SisPedraCaida.PrintMonitor.Helper.exe"
#define BootstrapperExe "SisPedraCaida.PrintMonitor.Bootstrapper.exe"

; Endereço default do canal do piloto (etapa 08 §4). É DEFAULT, não decisão: a URL é editável no
; wizard, no modo silencioso e depois de instalada (atalho "Configurar PrintMonitor").
#define DashboardUrlPadrao "http://148.72.177.161:5302/api/v1/printagents"
#define AmbientePadrao "Production"

; Origens do front-adm autorizadas a ler a identidade da estação (GET http://127.0.0.1:8183/identidade, sem
; segredo — decisão de 21/10/2026: a proteção é a lista EXATA de origens). Pré-preenchem a página
; "Identificação pelo navegador" e valem no silencioso quando nada foi informado nem está gravado na estação;
; informadas, o Setup.exe liga o loopback e gera o RouteSecret que faltar. Sobrescreva no build com
; `build-installer.ps1 -OrigensPadrao '...'` (vazio = sem default) e, por estação, com /LOOPBACKORIGINS= ou
; LoopbackPrintOrigensPermitidas no /CONFIGFILE.
#ifndef OrigensPadrao
  #define OrigensPadrao "https://interno-dev.berechit.com.br"
#endif

; Caminho canônico do recurso de agentes na API (rota [controller] do PrintAgentsController). Espelha
; DashboardUrlNormalizer.CaminhoCanonico / CaminhoAlternativo — mudar um lado exige mudar o outro, e
; PrintAgentsControllerCatalogoTests (Api.Tests) reprova se os dois divergirem. A alternativa é a
; grafia kebab gravada até 17/10/2026, que NÃO casava rota nenhuma (PRD-PMKEBAB-00): ela é aceita na
; entrada e sempre reescrita na canônica, e a API a atende como rota secundária durante a migração.
#define CaminhoRecurso "/api/v1/printagents"
#define CaminhoRecursoAlternativo "/api/v1/print-agents"

[Setup]
; AppId é a IDENTIDADE da instalação: gerado uma única vez e NUNCA alterado. Trocá-lo faz o pacote
; novo não reconhecer o antigo — duas entradas em "Programas e Recursos" e dois conjuntos de
; binários brigando pelo mesmo nome de serviço. É próprio, nunca o do agente TEF: os dois convivem no
; mesmo balcão. É também o que permite o upgrade por instalador (PRD-PMTRAY-03): a chave de
; desinstalação deste AppId diz a versão instalada (bloqueio de downgrade) e a pasta anterior.
AppId={{8B6F2C41-77F3-4B2E-9E5A-1D0C4A9E7B31}
AppName={#AppNome}
AppVersion={#AppVersion}
AppVerName={#AppNome} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\SisPedraCaida\PrintMonitor

; Upgrade no lugar (PRD-PMTRAY-03, igual ao TEF): a pasta da instalação anterior é REUTILIZADA e a página de
; diretório some quando há instalação anterior. Escolher outra pasta num upgrade deixaria a antiga órfã, com o
; serviço re-registrado apontando para a nova e o Bootstrapper/InstallOptions olhando para a de sempre.
UsePreviousAppDir=yes
DisableDirPage=auto
DefaultGroupName=SisPedraCaida
DisableProgramGroupPage=yes
OutputBaseFilename=PrintMonitorSetup-{#AppVersion}
OutputDir=..\..\artifacts\installer

; Ícone do PrintMonitorSetup-<versão>.exe (PRD-PMTRAY-01 D2): o MESMO arquivo do instalador do agente TEF
; (caminho relativo a ESTE .iss) — um .ico por instalador divergiria no primeiro ajuste de marca.
; ⚠️ Isto não resolve o ícone de "Aplicativos e Recursos": aquele vem do UninstallDisplayIcon abaixo, ou
; seja, do ícone EMBUTIDO no Setup.exe — o <ApplicationIcon> do .csproj. São dois lugares.
SetupIconFile=..\assets\sispedracaida.ico
UninstallDisplayIcon={app}\{#SetupExe}
UninstallDisplayName={#AppNome}

; Serviço + HKLM + variáveis de máquina exigem elevação.
PrivilegesRequired=admin

; Pacote win-x64. Estação x86 é decisão de escopo (etapa 01), não de instalador.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Windows 10 1607 — piso TÉCNICO do runtime, para dar mensagem clara em vez de erro genérico.
; ⚠️ Piso técnico ≠ piso suportado: conferir a matriz de SOs do .NET no release (etapa 01 §2.1).
MinVersion=10.0.14393

; O payload passa de 100 MB (self-contained + QZ Tray com JRE embutido).
Compression=lzma2/max
SolidCompression=yes

; Log sempre gravado, mesmo sem /LOG. ⚠️ O log registra a LINHA DE COMANDO: uma chave passada em
; /APIKEY= vai em claro para o arquivo. Use /CONFIGFILE= no rollout (etapa 03 §4).
SetupLogging=yes

; Quem para o serviço é o `Setup.exe --uninstall`, na ordem certa (parar → confirmar a parada →
; remover). Deixar o Inno tentar fechar processos por conta própria atropela essa sequência.
; No upgrade, quem fecha é o PrepararUpgrade (upgrade.iss + processos.iss, PRD-PMTRAY-04).
CloseApplications=no

WizardStyle=modern
ShowLanguageDialog=no

#if QzInstallerFile != ""
; Pacote que REDISTRIBUI o QZ Tray (LGPL-2.1, com JRE embutido): os avisos de terceiros aparecem na
; tela de licença (pulada em /VERYSILENT) e ficam em {app}\licencas. Texto integral da LGPL e dos
; avisos do JRE é pendência da etapa 08 (ver PRD-GIMP-BE-06, seção "Instalador").
LicenseFile=licencas\AVISOS-TERCEIROS.txt
#endif

; ⚠️ Sem [Tasks] desde PRD-PMTRAY-02: o driver da Bematech deixou de ser opcional (é sempre instalado) e
; a página "Selecionar Tarefas Adicionais" ficou vazia. /DRIVERBEMATECH=1 continua ACEITO e é ignorado —
; o Inno não reclama de parâmetro desconhecido, e scripts de rollout antigos seguem funcionando.

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
; ignoreversion é OBRIGATÓRIO: sem ele o Inno compara versão de arquivo e PULA binários que o
; auto-update deixou "mais novos" na pasta, produzindo layout misturado entre duas versões.
; restartreplace + uninsrestartdelete são OBRIGATÓRIOS em toda entrada de {app} (PRD-PMTRAY-04, campo
; 21/10/2026: "DeleteFile falhou; código 5" na Accessibility.dll, com Tentar novamente / Ignorar /
; Cancelar). O PrepararUpgrade fecha tudo que roda da pasta antes da cópia; se ainda assim um arquivo
; estiver travado, ele é trocado no PRÓXIMO REINÍCIO e o Inno pede o reinício no fim, em vez de parar
; na caixa. ⚠️ Em /VERYSILENT sem /NORESTART o Inno REINICIA a estação sozinho quando isso acontece:
; distribua com /NORESTART (o log registra "Need to restart Windows? Yes"). Guarda: InstaladorUpgradeGuardTests.
Source: "{#PublishDir}\*"; DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs ignoreversion restartreplace uninsrestartdelete; \
  Excludes: "*.pdb,appsettings.Development.json"

#if QzInstallerFile != ""
Source: "payload\{#QzInstallerFile}"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "licencas\AVISOS-TERCEIROS.txt"; DestDir: "{app}\licencas"; Flags: ignoreversion restartreplace uninsrestartdelete
#endif

; Driver OBRIGATÓRIO (PRD-PMTRAY-02): sempre extraído; a instalação é por Exec()+ResultCode em
; InstalarDriverBematech (provisioning.iss), depois do provisionamento — [Run] ignora o código de saída (#101a).
Source: "payload-drivers\{#BematechDriverFile}"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
; A superfície que torna o endereço da API editável sem reinstalar e sem linha de comando
; (etapa 08 §3). O Setup.exe pede elevação pelo próprio manifesto — não há flag `runas` no Inno.
Name: "{group}\Configurar PrintMonitor"; Filename: "{app}\{#SetupExe}"; \
  Parameters: "--config-ui"; Comment: "Alterar o endereço da API e a chave desta estação"

; A bandeja no menu Iniciar, para o operador que fechou o ícone trazê-lo de volta sem encerrar a sessão.
; Ela NÃO pede elevação (asInvoker): toda escrita é delegada ao Setup.exe com `runas`.
Name: "{group}\Bandeja do PrintMonitor"; Filename: "{app}\{#BandejaExe}"; \
  Comment: "Mostrar o status do PrintMonitor na área de notificação"

[Registry]
; A bandeja sobe com a SESSÃO do operador, pela chave Run da MÁQUINA (HKLM): a estação do balcão é usada
; por várias contas, e HKCU registraria só a de quem instalou — normalmente o técnico, não o caixa.
; ⚠️ Entrada em HKLM\...\Run NÃO dispara processo elevado: é por isso que o manifesto da bandeja é
; `asInvoker` (com `requireAdministrator` ela não subiria, ou pediria UAC a cada logon).
; ⚠️ `uninsdeletevalue`, NUNCA `uninsdeletekey`: a chave Run é compartilhada com todo o Windows.
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "{#BandejaValorRun}"; \
  ValueData: """{app}\{#BandejaExe}"""; Flags: uninsdeletevalue

[Run]
; Sobe a bandeja ao fim da instalação INTERATIVA, para o técnico conferir o ícone sem encerrar a sessão. É o
; último dos três (PRD-PMTRAY-05): QZ Tray e Helper já foram iniciados no fim do provisionamento
; (IniciarProcessosDaSessao); no silencioso a bandeja também sobe por lá, por código.
; ⚠️ `runasoriginaluser` é obrigatório: o instalador roda ELEVADO, e sem a flag a bandeja nasceria como
; administrador — ícone na área de notificação errada (ou em nenhuma) e privilégio que ela existe para não ter.
; ⚠️ `nowait`: a bandeja fica residente. ⚠️ Apresentação, não provisionamento: [Run] IGNORA o código de saída
; (#101a), e por isso o provisionamento e o driver continuam em Exec()+ResultCode no provisioning.iss.
; ⚠️ `Check: EstacaoProvisionada`: numa instalação REPROVADA (e desprovisionada) a bandeja não sobe — aberta numa
; estação sem agente ela só mostraria "Serviço não registrado" e confundiria o operador (campo, 21/10/2026).
Filename: "{app}\{#BandejaExe}"; \
  Description: "Mostrar o status do PrintMonitor na área de notificação"; \
  Flags: runasoriginaluser nowait postinstall skipifsilent; Check: EstacaoProvisionada

[UninstallRun]
; Fecha a bandeja ANTES de remover os binários: executável em uso fica travado, e a desinstalação deixaria
; o arquivo — e o ícone — para trás até o próximo logoff. `taskkill`, não o Setup.exe: a bandeja é
; processo da sessão do usuário, não um serviço.
; PRD-PMTRAY-04: antes destas entradas, CurUninstallStepChanged(usUninstall) já parou o serviço e fechou
; todo processo rodando de {app} (LimparProcessosParaDesinstalar); este taskkill fica como redundância.
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#BandejaExe}"; \
  RunOnceId: "FecharBandejaPrintMonitor"; Flags: runhidden waituntilterminated
; Roda no INÍCIO da desinstalação, antes da remoção dos arquivos — que é exatamente o necessário:
; o --uninstall para o serviço e AGUARDA a parada efetiva. Remover binário antes deixaria o serviço
; em STOP_PENDING e um registro órfão no SCM.
Filename: "{app}\{#SetupExe}"; Parameters: "--uninstall"; \
  RunOnceId: "DesprovisionarPrintMonitor"; Flags: runhidden waituntilterminated

; ⚠️ NADA de [Dirs]/[UninstallDelete] sob {commonappdata}: `agent-id` é a identidade da estação
; (apagá-lo faz a mesma máquina virar estação nova no painel), e logs/update/coletas são evidência
; de diagnóstico. O QZ Tray tem desinstalador próprio e não é removido junto — nem o driver obrigatório
; da Bematech, que serve à impressora (outros programas podem usá-la) e tem desinstalador próprio.
; ⚠️ Épico gestao-impressoras: ao lado do `agent-id` vivem o `enrollment-secret` (prova de posse do
; enrolamento — sem ele a API recusa em silêncio a mesma InstallationId) e o `impressao-agent-key`
; (credencial retirada na liberação). Upgrade e desinstalação os PRESERVAM: reinstalar uma estação
; bloqueada não pode virar beco sem saída (#103) — a chave nova é retirada pelo serviço em execução
; depois da re-liberação. O `--uninstall` do Setup.exe também não os toca, nem apaga as variáveis do
; loopback (LoopbackPrint:*), que só mudam quando informadas de novo.

[Code]
#include "checks.iss"
#include "pages.iss"
{ Fechar e confirmar processos por imagem e por caminho (PRD-PMTRAY-04): antes do upgrade.iss e do
  provisioning.iss, que o usam no upgrade, na reversão e na desinstalação. }
#include "processos.iss"
{ Antes do provisioning.iss de propósito: ele chama IniciarProcessosDaSessao no fim do provisionamento,
  e o upgrade.iss consome ServicoJaRegistrado, VersaoJaInstalada e o caminho do QZ Tray do checks.iss.
  ⚠️ Comentário aqui é de chaves, NUNCA ponto e vírgula: dentro de [Code] o compilador lê Pascal. }
#include "upgrade.iss"
#include "provisioning.iss"

{ ------------------------------------------------------------------------------------------
  Eventos do instalador. Mantidos por último porque consomem o que os includes declaram.
  ------------------------------------------------------------------------------------------ }

{ Bloqueio de downgrade: o Inno instala um pacote antigo por cima sem reclamar, e a estação volta
  no tempo em silêncio. É a lacuna que o MSI cobria com AllowDowngrades="no" (etapa 06 §2).
  PRD-PMTRAY-03: a MESMA mensagem e o mesmo desfecho do TEF (TefAgent.iss) — recusa antes de o wizard
  existir; a MESMA versão passa (reinstalar é legítimo). Diferença deliberada: SuppressibleMsgBox + log,
  porque MsgBox aparece mesmo em /VERYSILENT e travaria invisível uma distribuição como LocalSystem; no
  silencioso o Setup sai com código de falha e a razão fica no log. }
function InitializeSetup(): Boolean;
var
  VersaoInstalada, Mensagem: String;
begin
  Result := True;

  if not ChecagensBloqueantesAprovadas() then
  begin
    Result := False;
    Exit;
  end;

  { Resolvido AQUI, e não só no wizard: em /VERYSILENT nenhuma página customizada roda, e sem esta
    chamada o silencioso aceitaria uma URL que o interativo recusaria. }
  ValoresIniciais();
  if not ValidarParametrosSilenciosos() then
  begin
    Result := False;
    Exit;
  end;

  VersaoInstalada := VersaoJaInstalada();
  if (VersaoInstalada <> '') and (CompareVersaoInstalada(VersaoInstalada, '{#AppVersion}') > 0) then
  begin
    Mensagem := 'Uma versão mais recente do ' + '{#AppNome}' + ' já está instalada nesta estação (' +
                VersaoInstalada + '). Instalar a versão {#AppVersion} por cima faria a estação regredir.' + #13#10#13#10 +
                'Desinstale a versão atual antes, se a regressão for intencional.';
    Log('[PrintMonitor] BLOQUEIO (downgrade): ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbError, MB_OK, IDOK);
    Result := False;
  end;
end;

procedure InitializeWizard();
begin
  CriarPaginasDoWizard();
end;

{ Na tela final, o caminho do log do provisionamento — é ele que responde "por que essa estação
  não apareceu no painel", e sem isso o operador vê só "instalado". }
procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
      'Resumo do provisionamento (etapa a etapa):' + #13#10 + LogDoProvisionamento() + #13#10#13#10 +
      'Para trocar o endereço da API depois, use o atalho "Configurar PrintMonitor" no menu Iniciar.' +
      ResumoProcessosDaSessao() + ResumoAvisoProvisionamento() + ResumoDriverBematech();
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := ValidarPagina(CurPageID);
end;

{ Resumo da tela "Pronto para instalar" — a chave NUNCA aparece por inteiro. }
function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
            'Conexão com o servidor:' + NewLine +
            Space + 'Endereço da API: ' + UrlInformada() + NewLine +
            Space + 'Chave de API: ' + ChaveMascarada() + NewLine +
            Space + 'Ambiente: ' + AmbienteInformado() + NewLine +
            Space + 'Atualização automática: ' + AutoUpdateInformado() + NewLine + NewLine +
            'Identificação pelo navegador (front-adm):' + NewLine +
            Space + 'Origens permitidas: ' + OrigensInformadas() + NewLine +
            Space + 'Endereço consultado pelo admin: http://127.0.0.1:8183/identidade' + NewLine;

  { Mesmo bloco do TEF, com a política do PrintMonitor: atualiza NO LUGAR, sem desinstalar. }
  if InstalacaoAnteriorPresente() then
    Result := Result + NewLine + 'Instalação anterior (' + VersaoJaInstalada() + ' → {#AppVersion}):' + NewLine +
              Space + 'O serviço será parado (com confirmação) e a bandeja, o Helper e todo processo da pasta' + NewLine +
              Space + 'fechados antes da cópia; no fim, o serviço volta a rodar e QZ Tray, Helper e bandeja são iniciados.' + NewLine +
              Space + 'A identidade da estação (agent-id, credenciais) e a configuração gravada são preservadas.' + NewLine;
end;

{ Roda depois da tela "Pronto para instalar" e antes de o primeiro arquivo ser copiado — inclusive
  no silencioso. É o ponto certo para tirar do caminho o que trava os binários (upgrade.iss).
  PRD-PMTRAY-04: o PrepararUpgrade roda SEMPRE (não só com instalação anterior detectada) e nunca
  recusa por arquivo em uso — o que sobrar travado é trocado no reinício (restartreplace). }
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

{ Desinstalação (PRD-PMTRAY-04): a MESMA limpeza do upgrade, antes de apagar qualquer arquivo. O
  usUninstall vem depois da confirmação do usuário e ANTES do [UninstallRun] (que roda o --uninstall)
  e da remoção dos arquivos. Serviço parado e confirmado no SCM, bandeja, Helper e todo processo
  rodando da pasta. Nada de caixa: o que não sair vai para o log e o uninsrestartdelete do [Files]
  apaga o arquivo no próximo reinício. O --uninstall do Setup.exe aceita o serviço já parado. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    LimparProcessosParaDesinstalar();
end;
