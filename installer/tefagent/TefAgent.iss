; ============================================================================================
;  Agente TEF — instalador do terminal Windows (Inno Setup 6)
;  Épico: tefagent-installer-windows (PRD-TEFINST-00..07)
;
;  Compile SEMPRE por `build-installer.ps1`: ele publica o layout self-contained do agente e
;  injeta as definições abaixo por /D no ISCC. Compilar este arquivo direto na IDE falha de
;  propósito (as definições não existem).
;
;  Decisão arquitetural central (Master D3): o instalador COPIA ARQUIVOS; quem provisiona é o
;  `Setup.exe`, que é código C# testado. Este script não registra serviço, não grava configuração
;  e não decide nada sobre o terminal — duplicar isso criaria dois lugares para a mesma regra, e o
;  daqui sem teste nenhum.
; ============================================================================================

#ifndef AppVersion
  #error Defina AppVersion pelo build-installer.ps1 (/DAppVersion=...)
#endif
#ifndef PublishDir
  #error Defina PublishDir pelo build-installer.ps1 (/DPublishDir=...)
#endif

#define AppNome "SisPedraCaida Agente TEF"

; Editor do pacote: o NOME FANTASIA de quem desenvolve o sistema, não o nome do produto. É este
; texto que o UAC mostra como editor e que a entrada em "Aplicativos e Recursos" exibe — até aqui
; dizia "SisPedraCaida", que é o sistema, e deixava o instalador sem dono identificável.
; ⚠️ Se o pacote passar a ser assinado, ele precisa BATER com o subject do certificado: divergir
; deixa o UAC afirmando um nome e a assinatura outro, que é pior que não ter nenhum dos dois.
#define AppPublisher "B3R3CH1T Desenvolvimento de Sistemas"
#define AppCopyright "© 2026 B3R3CH1T Desenvolvimento de Sistemas"

; Canal de suporte gravado na entrada de desinstalação (campos Contato e Link da Ajuda). É o que o
; técnico do balcão tem à mão sem precisar descobrir por outro caminho a quem recorrer.
#define AppSuporteEmail "anderson.meneses@gmail.com"
#define SetupExe "SisPedraCaida.Tef.Agent.Setup.exe"
#define AgenteExe "SisPedraCaida.Tef.Agent.exe"
#define BandejaExe "SisPedraCaida.Tef.Agent.Tray.exe"

; Nome do VALOR na chave Run. Fixo e proprio: trocar o nome numa versao futura deixaria o valor
; antigo orfao apontando para um binario removido, e a bandeja subiria duas vezes enquanto as duas
; versoes convivessem no mesmo terminal.
#define BandejaValorRun "SisPedraCaidaTefAgentTray"
#define ServicoNome "SisPedraCaida.Tef.Agent"

; Pasta de dados do terminal. NÃO é removida na desinstalação: ali vivem o banco local com o
; estado das transações e o arquivo de configuração deste terminal.
#define PastaDados "{commonappdata}\SisPedraCaida\TefAgent"

; Endereços que o wizard já traz preenchidos (editáveis) quando o terminal ainda não tem
; configuração gravada; numa reinstalação valem os gravados. Decisão de 17/10/2026: todas as
; implantações apontam para a mesma API, e o Elgin TEF Web do terminal atende na porta 2001,
; em /tef/v1/ (collection oficial v3.14.10; sem o v1 as rotas caem fora do serviço).
#define ApiUrlPadrao "http://148.72.177.161:5302"
#define TefWebUrlPadrao "http://localhost:2001/tef/v1/"
#define AmbientePadrao "Production"

[Setup]
; AppId é a IDENTIDADE da instalação: gerado uma única vez e NUNCA alterado. Trocá-lo faz o pacote
; novo não reconhecer o antigo — duas entradas em "Programas e Recursos" e dois conjuntos de
; binários brigando pelo mesmo nome de serviço. É próprio, nunca o do PrintMonitor: os dois podem
; conviver no mesmo balcão.
AppId={{C3F1A7D2-6B48-4E95-9A1C-2D7E8F4B5106}
AppName={#AppNome}
AppVersion={#AppVersion}
AppVerName={#AppNome} {#AppVersion}
AppPublisher={#AppPublisher}
AppCopyright={#AppCopyright}

; Contato vira o campo "Contato" da entrada de desinstalação; o mailto vira o "Link da Ajuda" que
; o Windows oferece ali. São os dois lugares onde o Windows aceita um canal de suporte sem que
; ninguém precise abrir a documentação.
AppContact={#AppSuporteEmail}
AppSupportURL=mailto:{#AppSuporteEmail}

; Aba Detalhes do próprio TefAgentSetup-<versão>.exe. O Inno deriva parte disto das diretivas App*
; acima, mas declarar é o que garante o texto quando a derivação muda entre versões do compilador.
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoCopyright={#AppCopyright}
VersionInfoProductName={#AppNome}
VersionInfoDescription=Instalador do {#AppNome}
DefaultDirName={autopf}\SisPedraCaida\TefAgent
DefaultGroupName=SisPedraCaida
DisableProgramGroupPage=yes
OutputBaseFilename=TefAgentSetup-{#AppVersion}
OutputDir=..\..\artifacts\installer

; Ícone do TefAgentSetup-<versão>.exe. Caminho relativo a ESTE .iss (installer/tefagent/), e o
; arquivo é compartilhado com o instalador do PrintMonitor — um .ico por instalador divergiria no
; primeiro ajuste de marca.
; ⚠️ Isto NÃO resolve o ícone da entrada em "Aplicativos e Recursos": aquele vem do
; UninstallDisplayIcon logo abaixo, ou seja, do ícone EMBUTIDO no Setup.exe — que é o
; <ApplicationIcon> do .csproj. São dois lugares, e mexer só aqui deixa a desinstalação genérica.
SetupIconFile=..\assets\sispedracaida.ico

UninstallDisplayIcon={app}\{#SetupExe}
UninstallDisplayName={#AppNome}

; Registro de serviço e escrita em %PROGRAMDATA% exigem elevação.
PrivilegesRequired=admin

; Pacote win-x64 (o layout é publicado para esse RID).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Windows 10 1607 — piso técnico do runtime .NET, para dar mensagem clara em vez de erro genérico.
MinVersion=10.0.14393

; O layout self-contained passa de 100 MB.
Compression=lzma2/max
SolidCompression=yes

; Log sempre gravado, mesmo sem /LOG. ⚠️ O log registra a LINHA DE COMANDO: nenhum valor sensível
; entra como parâmetro — hoje não há segredo no TEF, e quando houver o caminho é /CONFIGFILE=.
SetupLogging=yes

; Quem para o serviço é o `Setup.exe --uninstall`, na ordem certa (parar → confirmar a parada →
; remover). Deixar o Inno tentar fechar processos por conta própria atropela essa sequência.
CloseApplications=no

WizardStyle=modern
ShowLanguageDialog=no

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
; ignoreversion é OBRIGATÓRIO: sem ele o Inno compara versão de arquivo e PULA binários, produzindo
; layout misturado entre duas versões. É também a razão de a configuração do terminal viver em
; %PROGRAMDATA% e não aqui — tudo o que está em {app} é sobrescrito.
Source: "{#PublishDir}\*"; DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs ignoreversion; \
  Excludes: "*.pdb,appsettings.Development.json"

[Icons]
; A superfície que torna o endereço da API e a identificação do terminal editáveis sem reinstalar
; (PRD-TEFINST-05). O Setup.exe pede elevação pelo próprio manifesto — não há flag `runas` aqui.
Name: "{group}\Configurar o agente TEF"; Filename: "{app}\{#SetupExe}"; \
  Parameters: "--config-ui"; Comment: "Alterar o endereço da API e a identificação deste terminal"

; Segundo passo de uma instalação que ficou SEM identificação: registra e inicia o serviço com o
; que o editor gravou. `--all` sem parâmetros é o caminho certo justamente porque parâmetro ausente
; PRESERVA o valor gravado — ele provisiona a partir da configuração em %PROGRAMDATA%, sem repetir
; nada na linha de comando (e sem a credencial aparecer nela, armadilha #78b).
; ⚠️ Só existe quando o provisionamento foi adiado: criá-lo sempre convidaria a reprovisionar um
; terminal que já opera, e "concluir" o que já está concluído não quer dizer nada para o operador.
Name: "{group}\Concluir a instalação do agente TEF"; Filename: "{app}\{#SetupExe}"; \
  Parameters: "--all"; Check: ProvisionamentoSeraAdiado; \
  Comment: "Registrar e iniciar o serviço depois de informar a identificação do terminal"

; A bandeja no menu Iniciar, para quando o operador fechar o ícone e quiser trazê-lo de volta sem
; encerrar a sessão. Ela NÃO pede elevação (asInvoker): toda escrita é delegada ao Setup.exe.
Name: "{group}\Bandeja do agente TEF"; Filename: "{app}\{#BandejaExe}"; \
  Comment: "Mostrar o status do agente TEF na área de notificação"

[Registry]
; A bandeja sobe com a SESSÃO do operador, pela chave Run da MÁQUINA (HKLM): o terminal do balcão
; é usado por várias contas, e HKCU registraria só a conta de quem instalou — que normalmente é o
; técnico, não o caixa.
; ⚠️ Entrada em HKLM\...\Run NÃO dispara processo elevado: ela roda como o usuário que fez logon.
; É por isso que o manifesto da bandeja é `asInvoker`; com `requireAdministrator` ela simplesmente
; não subiria, ou pediria UAC a cada logon do caixa.
; ⚠️ `uninsdeletevalue`, NUNCA `uninsdeletekey`: a chave Run é compartilhada com todo o Windows, e
; apagá-la inteira levaria junto a inicialização de todos os outros programas da máquina.
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "{#BandejaValorRun}"; \
  ValueData: """{app}\{#BandejaExe}"""; Flags: uninsdeletevalue

[Run]
; Sobe a bandeja ao fim da instalação, para o técnico conferir o ícone sem encerrar a sessão.
; ⚠️ `runasoriginaluser` é obrigatório: o instalador roda ELEVADO, e sem essa flag a bandeja
; nasceria no contexto do administrador — o ícone apareceria na área de notificação errada (ou em
; nenhuma) e o processo ficaria com um privilégio que ele existe para não ter.
; ⚠️ `nowait`: a bandeja não termina, fica residente. Sem isso o instalador esperaria para sempre.
; ⚠️ Este [Run] é apresentação, não provisionamento: o `[Run]` do Inno IGNORA o código de saída
; (armadilha #101a), e é por isso que o provisionamento continua em `Exec()`+`ResultCode` no
; provisioning.iss, nunca aqui.
Filename: "{app}\{#BandejaExe}"; \
  Description: "Mostrar o status do agente TEF na área de notificação"; \
  Flags: runasoriginaluser nowait postinstall skipifsilent

[UninstallRun]
; Fecha a bandeja ANTES de remover os binários: no Windows um executável em uso fica travado, e a
; desinstalação terminaria deixando o arquivo — e o ícone na barra — para trás até o próximo
; logoff. `taskkill`, e não o Setup.exe: a bandeja é processo da sessão do usuário, não um serviço.
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#BandejaExe}"; \
  RunOnceId: "FecharBandejaTefAgent"; Flags: runhidden waituntilterminated
; Roda no INÍCIO da desinstalação, antes da remoção dos arquivos — que é exatamente o necessário:
; o --uninstall para o serviço e AGUARDA a parada efetiva. Remover binário antes deixaria o serviço
; em STOP_PENDING e um registro órfão no SCM.
Filename: "{app}\{#SetupExe}"; Parameters: "--uninstall"; \
  RunOnceId: "DesprovisionarTefAgent"; Flags: runhidden waituntilterminated

; ⚠️ NADA de [Dirs]/[UninstallDelete] sob {commonappdata}: ali estão o `agent.db` (estado de
; transações em voo — apagá-lo destrói a recuperação) e o `agent.settings.json` (a configuração
; deste terminal, que precisa sobreviver a uma reinstalação).

[Code]
#include "checks.iss"
#include "pages.iss"
{ Depois de checks.iss e pages.iss de propósito: consome o `TefHubInstalado`/`E1ConnectInstalado`
  de um e o `Parametro` do outro.
  ⚠️ Comentário aqui é de chaves ou `//`, NUNCA `;`: dentro de [Code] o compilador lê Pascal, e a
  linha iniciada por `;` reprova com "'BEGIN' expected" apontando para ela — o `;` só comenta nas
  seções de diretiva, acima. E comentário de chaves NÃO aninha: uma chave de fechamento no meio
  do texto encerra o comentário ali, e o resto da linha vira código. }
#include "tefhub.iss"
#include "provisioning.iss"

{ ------------------------------------------------------------------------------------------
  Eventos do instalador. Mantidos por último porque consomem o que os includes declaram.
  ------------------------------------------------------------------------------------------ }

{ Bloqueio de downgrade: o Inno instala um pacote antigo por cima sem reclamar, e o terminal volta
  no tempo em silêncio. É a lacuna que o MSI cobriria com AllowDowngrades=no. }
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

  { TEF HUB e E1_Connect (PRD-ELGPRE-01): sem eles o caixa não processa cartão. Aqui, antes do
    wizard, para valer também no silencioso; o diálogo do interativo segura até o técnico instalar. }
  if not GarantirPreRequisitosElgin() then
  begin
    Result := False;
    Exit;
  end;

  { Resolvido AQUI, e não só no wizard: em /VERYSILENT nenhuma página customizada roda, e sem esta
    chamada o silencioso aceitaria o que o interativo nem chega a perguntar.

    ⚠️ SÓ no silencioso, e o `WizardSilent()` é o ponto todo: sem ele a validação rodava também no
    interativo e recusava a instalação ANTES de a primeira página abrir — com a mensagem
    "Informe a identificação do terminal (/TERMINALID= ...)", que manda o operador informar por
    linha de comando o que a página seguinte ia perguntar. O instalador de duplo clique ficava
    impossível de usar, e a página de identificação, inalcançável. }
  ValoresIniciais();
  if WizardSilent() and (not ValidarParametrosSilenciosos()) then
  begin
    Result := False;
    Exit;
  end;

  VersaoInstalada := VersaoJaInstalada();
  if (VersaoInstalada <> '') and (CompareVersaoInstalada(VersaoInstalada, '{#AppVersion}') > 0) then
  begin
    MsgBox('Uma versão mais recente do ' + '{#AppNome}' + ' já está instalada neste terminal (' +
           VersaoInstalada + '). Instalar a versão {#AppVersion} por cima faria o terminal regredir.' + #13#10#13#10 +
           'Desinstale a versão atual antes, se a regressão for intencional.',
           mbError, MB_OK);
    Result := False;
  end;
end;

procedure InitializeWizard();
begin
  CriarPaginasDoWizard();
end;

{ Na tela final, o caminho do log do provisionamento — é ele que responde "por que esse terminal
  não apareceu no painel", e sem isso o operador vê só "instalado". }
procedure CurPageChanged(CurPageID: Integer);
var
  TextoConfiguracaoInicial: String;
begin
  if CurPageID <> wpFinished then
    Exit;

  { Instalação adiada tem tela final PRÓPRIA, e ela não menciona log de provisionamento — não houve
    nenhum. O que o operador precisa ler aqui é que o terminal ainda não opera e quais são os dois
    passos; "Concluído" sozinho é como o caixa mudo começa. }
  if ProvisionamentoAdiado then
  begin
    { A frase sobre a configuração inicial muda conforme a gravação: dizer "gravada" quando o
      Setup.exe falhou mandaria o operador abrir o editor esperando os valores e encontrá-lo vazio. }
    if ConfiguracaoInicialGravada then
      TextoConfiguracaoInicial :=
        'O que foi informado nesta instalação (endereços e nome) ficou gravado como ' +
        'configuração inicial: no editor, basta completar a identificação e a loja.'
    else
      TextoConfiguracaoInicial :=
        'ATENÇÃO: não foi possível gravar a configuração inicial (detalhe em ' +
        LogDoProvisionamento() + '). Informe todos os dados no editor.';

    WizardForm.FinishedLabel.Caption :=
      'Os arquivos foram instalados, mas o terminal AINDA NÃO ESTÁ EM OPERAÇÃO: a identificação ' +
      'não foi informada, então o serviço do Windows não foi registrado. Este caixa não aparece ' +
      'no painel e não processa cartão.' + #13#10#13#10 +
      TextoConfiguracaoInicial + #13#10#13#10 +
      'Para concluir, no menu Iniciar, nesta ordem:' + #13#10 +
      '   1. "Configurar o agente TEF" — informe a identificação do terminal e a loja;' + #13#10 +
      '   2. "Concluir a instalação do agente TEF" — registra e inicia o serviço.';
    Exit;
  end;

  { Provisionado aguardando liberação (código 4, PRD-TEFZERA-01): o serviço está em execução, mas
    "Concluído" sozinho seria o caixa mudo da #101a — a tela diz que ele ainda não opera e qual é
    o único passo, que acontece no painel e não nesta máquina. }
  if AguardandoLiberacao then
  begin
    WizardForm.FinishedLabel.Caption :=
      'Os arquivos foram instalados e o serviço está em execução, mas o terminal AINDA NÃO ESTÁ EM ' +
      'OPERAÇÃO: a API recusou a credencial deste terminal. Este caixa não processa cartão até ser ' +
      'liberado.' + #13#10#13#10 +
      'Para concluir, no painel (Terminais TEF), libere este terminal. O agente retira a chave nova ' +
      'sozinho em poucos segundos — não é preciso reinstalar nem reiniciar. Se ele já estiver ' +
      'liberado, reemita a credencial.' + #13#10#13#10 +
      'Resumo do provisionamento (etapa a etapa):' + #13#10 + LogDoProvisionamento();
    Exit;
  end;

  WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
    'Resumo do provisionamento (etapa a etapa):' + #13#10 + LogDoProvisionamento() + #13#10#13#10 +
    'Para alterar o endereço da API ou a identificação do terminal depois, use o atalho ' +
    '"Configurar o agente TEF" no menu Iniciar.';
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
            Space + 'Identificação: ' + ValorTerminalId + NewLine +
            Space + 'Loja: ' + ValorStoreId + NewLine +
            Space + 'Nome: ' + NomeInformado() + NewLine + NewLine +
            'Conexão:' + NewLine +
            Space + 'Endereço da API: ' + ValorApiUrl + NewLine +
            Space + 'Elgin TEF Web: ' + ValorTefWebUrl + NewLine;

  if InstalacaoAnteriorPresente() then
    Result := Result + NewLine + 'Instalação anterior:' + NewLine +
              Space + 'O serviço será parado e a instalação atual removida antes de continuar.' + NewLine +
              Space + 'A configuração e o banco local deste terminal são preservados.' + NewLine;
end;

{ Roda depois da tela "Pronto para instalar" e antes de o primeiro arquivo ser copiado — inclusive
  no silencioso. É o ponto certo para tirar a instalação anterior do caminho. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := ChecagensDePreparacao();

  if Result = '' then
    Result := RemoverInstalacaoAnterior();
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    ExecutarProvisionamento();
end;
