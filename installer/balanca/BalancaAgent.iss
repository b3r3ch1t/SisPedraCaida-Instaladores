; ============================================================================================
;  Agente da balança do self-service — instalador da estação Windows (Inno Setup 6)
;  Épico: ci-instaladores-prod (PRD-INSTPROD-03)
;
;  Compile SEMPRE por `build-installer.ps1`: ele publica o layout self-contained do agente e
;  injeta as definições abaixo por /D no ISCC. Compilar este arquivo direto na IDE falha de
;  propósito (as definições não existem).
;
;  Diferente do TEF e do PrintMonitor, aqui NÃO há `Setup.exe`: o agente precisa só de um serviço
;  registrado e de quatro valores (identidade, segredo do loopback, porta e velocidade da serial).
;  Um provisionador em C# para isso seria mais código a manter do que a regra que ele protege — o
;  instalador faz, e confirma no fim que o loopback responde.
;
;  Onde a configuração mora: no ambiente DO SERVIÇO (valor `Environment` da chave do serviço no
;  registro), não em `appsettings.json` nem em variável de máquina:
;    - {app} é sobrescrito a cada upgrade (`ignoreversion`, armadilha #101b) — configuração ali é
;      configuração perdida;
;    - o SCM aplica esse valor a cada início do serviço, e só o processo do agente o recebe — uma
;      variável de máquina ficaria visível a todo processo da estação;
;    - o host lê variável de ambiente por cima do `appsettings.json` (`BalancaAgent__Porta` etc.),
;      então nenhuma linha de código do agente mudou.
;  Desinstalar remove o serviço e, com ele, esses valores.
; ============================================================================================

#ifndef AppVersion
  #error Defina AppVersion pelo build-installer.ps1 (/DAppVersion=...)
#endif
#ifndef PublishDir
  #error Defina PublishDir pelo build-installer.ps1 (/DPublishDir=...)
#endif

#define AppNome "SisPedraCaida Agente da Balança"
#define AppPublisher "B3R3CH1T Desenvolvimento de Sistemas"
#define AppCopyright "© 2026 B3R3CH1T Desenvolvimento de Sistemas"
#define AppSuporteEmail "anderson.meneses@gmail.com"
#define AgenteExe "SisPedraCaida.Balanca.Agent.exe"

; Nome do serviço: TEM de ser o mesmo que o agente declara em `UseWindowsService` (Program.cs).
; Divergir registra um serviço que o host não reconhece como seu. Cobrado por
; InstaladoresCiArchitectureTests.
#define ServicoNome "SisPedraCaida Balanca Agent"

; Porta do loopback (`BalancaAgent:PortaLoopback` do appsettings.json). Usada só pela sonda final.
#define PortaLoopback "8184"
#define PortaSerialPadrao "COM3"
#define BaudRatePadrao "9600"

; Identidade do PrintMonitor na mesma estação. Quando existe, o agente da balança ADOTA o mesmo
; AgentId (o cadastro `PdvBalanca` foi desenhado para isso): duas identidades para o mesmo PC
; obrigariam o operador a descobrir qual GUID é de qual agente.
#define AgentIdPrintMonitor "{commonappdata}\SisPedraCaida\PrintMonitor\agent-id"

[Setup]
; AppId é a IDENTIDADE da instalação: gerado uma única vez e NUNCA alterado. Próprio, nunca o do
; TEF ou do PrintMonitor — os três convivem na mesma estação.
AppId={{5E2B9C17-4D83-4A6F-B1E0-7C9A2F3D8B64}
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
DefaultDirName={autopf}\SisPedraCaida\BalancaAgent
DefaultGroupName=SisPedraCaida
DisableProgramGroupPage=yes
OutputBaseFilename=BalancaAgentSetup-{#AppVersion}
OutputDir=..\..\artifacts\installer
SetupIconFile=..\assets\sispedracaida.ico
UninstallDisplayIcon={app}\{#AgenteExe}
UninstallDisplayName={#AppNome}

; Registro de serviço exige elevação.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.14393
Compression=lzma2/max
SolidCompression=yes

; Log sempre gravado. ⚠️ O log registra a LINHA DE COMANDO: o segredo do loopback NUNCA entra como
; parâmetro — ele é gerado aqui dentro (armadilha #78b).
SetupLogging=yes

; Quem para o serviço é este script, confirmando a parada antes de copiar (cópia sobre processo
; vivo falha parcial e silenciosa). Deixar o Inno fechar processos atropelaria essa sequência.
CloseApplications=no

WizardStyle=modern
ShowLanguageDialog=no

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
; ignoreversion é OBRIGATÓRIO: sem ele o Inno compara versão de arquivo e PULA binários, produzindo
; layout misturado entre duas versões. Por isso a configuração não vive aqui (ver cabeçalho).
Source: "{#PublishDir}\*"; DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs ignoreversion; \
  Excludes: "*.pdb,appsettings.Development.json"

[Code]
const
  ChaveServico = 'SYSTEM\CurrentControlSet\Services\{#ServicoNome}';
  VarSegredo = 'SISPEDRACAIDA_BALANCA_ROUTE_SECRET';
  VarAgentId = 'BalancaAgent__AgentId';
  VarPorta = 'BalancaAgent__Porta';
  VarBaudRate = 'BalancaAgent__BaudRate';

type
  { GUID como 16 bytes crus. Quatro LongWord em vez do layout clássico (com array) porque o
    Pascal Script não garante o alinhamento de array dentro de record numa chamada de DLL. }
  TGuidBruto = record
    D1, D2, D3, D4: LongWord;
  end;

function CoCreateGuid(var G: TGuidBruto): Integer;
  external 'CoCreateGuid@ole32.dll stdcall';

var
  PaginaSerial: TInputQueryWizardPage;
  { Valores efetivos desta instalação (preservados da anterior ou gerados agora). }
  AgentIdEfetivo, SegredoEfetivo, OrigemAgentId: String;
  { Se o serviço existia antes: em falha, só a instalação NOVA é desfeita (desfazer um upgrade
    apagaria a identidade e o segredo que o PDV já conhece). }
  ServicoExistiaAntes: Boolean;

{ ---------- utilitários ---------- }

{ Hexadecimal de 8 dígitos por aritmética sem sinal: IntToHex recebe inteiro com sinal e erraria
  metade dos valores de 32 bits. }
function Hex8(V: LongWord): String;
var
  I: Integer;
  Digito: LongWord;
begin
  Result := '';
  for I := 1 to 8 do
  begin
    Digito := V mod 16;
    V := V div 16;
    Result := Copy('0123456789abcdef', Integer(Digito) + 1, 1) + Result;
  end;
end;

{ 32 dígitos hexadecimais aleatórios. O CoCreateGuid gera o GUID v4 a partir do gerador
  criptográfico do Windows — o Pascal Script não tem outro e `Random` é previsível. }
function Hex32Aleatorio(): String;
var
  G: TGuidBruto;
begin
  if CoCreateGuid(G) <> 0 then
    RaiseException('Não foi possível gerar um identificador aleatório (CoCreateGuid).');
  Result := Hex8(G.D1) + Hex8(G.D2) + Hex8(G.D3) + Hex8(G.D4);
end;

function NovoGuid(): String;
var
  H: String;
begin
  H := Hex32Aleatorio();
  Result := Copy(H, 1, 8) + '-' + Copy(H, 9, 4) + '-' + Copy(H, 13, 4) + '-' +
            Copy(H, 17, 4) + '-' + Copy(H, 21, 12);
end;

function PareceGuid(const S: String): Boolean;
var
  I: Integer;
  C: String;
begin
  Result := Length(S) = 36;
  if not Result then Exit;
  for I := 1 to 36 do
  begin
    C := Copy(S, I, 1);
    if (I = 9) or (I = 14) or (I = 19) or (I = 24) then
      Result := C = '-'
    else
      Result := Pos(Lowercase(C), '0123456789abcdef') > 0;
    if not Result then Exit;
  end;
end;

{ Lê VALOR de NOME no ambiente gravado do serviço (multi-string `NOME=valor`). Vazio se ausente. }
function LerAmbienteDoServico(const Nome: String): String;
var
  Bruto, Linha: String;
  P: Integer;
begin
  Result := '';
  if not RegQueryMultiStringValue(HKLM, ChaveServico, 'Environment', Bruto) then Exit;
  Bruto := Bruto + #0;
  while Bruto <> '' do
  begin
    P := Pos(#0, Bruto);
    Linha := Copy(Bruto, 1, P - 1);
    Delete(Bruto, 1, P);
    if CompareText(Copy(Linha, 1, Length(Nome) + 1), Nome + '=') = 0 then
    begin
      Result := Copy(Linha, Length(Nome) + 2, Length(Linha));
      Exit;
    end;
  end;
end;

function ServicoRegistrado(): Boolean;
begin
  Result := RegKeyExists(HKLM, ChaveServico);
end;

function Sc(const Parametros: String): Integer;
begin
  if not Exec(ExpandConstant('{sys}\sc.exe'), Parametros, '', SW_HIDE, ewWaitUntilTerminated, Result) then
    Result := -1;
  Log('[Balanca] sc ' + Parametros + ' -> ' + IntToStr(Result));
end;

{ Roda um comando PowerShell curto e devolve o código de saída (-1 se nem iniciou). Nenhum segredo
  passa por aqui: a linha de comando de processo é legível por qualquer usuário da estação. }
function PowerShell(const Comando: String): Integer;
begin
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
              '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + Comando + '"',
              '', SW_HIDE, ewWaitUntilTerminated, Result) then
    Result := -1;
end;

{ Para o serviço e CONFIRMA a parada — `sc stop` devolve 0 ao enfileirar, não ao parar (#101d). }
function PararServico(): Boolean;
begin
  if not ServicoRegistrado() then
  begin
    Result := True;
    Exit;
  end;
  Result := PowerShell('$s = Get-Service -Name ''{#ServicoNome}'' -ErrorAction Stop; ' +
                       'if ($s.Status -ne ''Stopped'') { Stop-Service -InputObject $s -Force -ErrorAction Stop; ' +
                       '$s.WaitForStatus(''Stopped'', [TimeSpan]::FromSeconds(30)) }') = 0;
  Log('[Balanca] Parada do serviço confirmada: ' + IntToStr(Ord(Result)));
end;

procedure RemoverServico();
begin
  PararServico();
  Sc('delete "{#ServicoNome}"');
end;

{ ---------- wizard ---------- }

{ Identidade: a já gravada no serviço > a do PrintMonitor desta estação > uma nova. Nunca o nome
  da máquina (armadilha #56: se repete entre PCs e é falsificável). }
procedure ResolverIdentidade();
var
  DoPrintMonitor: AnsiString;
begin
  AgentIdEfetivo := Lowercase(Trim(LerAmbienteDoServico(VarAgentId)));
  OrigemAgentId := 'preservada da instalação anterior';

  if not PareceGuid(AgentIdEfetivo) then
  begin
    AgentIdEfetivo := '';
    if LoadStringFromFile(ExpandConstant('{#AgentIdPrintMonitor}'), DoPrintMonitor) then
    begin
      AgentIdEfetivo := Lowercase(Trim(String(DoPrintMonitor)));
      OrigemAgentId := 'a mesma do PrintMonitor desta estação';
    end;
  end;

  if not PareceGuid(AgentIdEfetivo) then
  begin
    AgentIdEfetivo := NovoGuid();
    OrigemAgentId := 'gerada nesta instalação';
  end;

  { O segredo também é preservado: o PDV desta estação já o conhece, e trocá-lo a cada upgrade
    deixaria a balança "desconectada" até alguém reconfigurar o navegador. }
  SegredoEfetivo := Trim(LerAmbienteDoServico(VarSegredo));
  if Length(SegredoEfetivo) < 32 then
    SegredoEfetivo := Hex32Aleatorio() + Hex32Aleatorio();
end;

procedure InitializeWizard();
var
  PortaAtual, BaudAtual: String;
begin
  ServicoExistiaAntes := ServicoRegistrado();
  ResolverIdentidade();

  PortaAtual := LerAmbienteDoServico(VarPorta);
  if PortaAtual = '' then PortaAtual := '{#PortaSerialPadrao}';
  BaudAtual := LerAmbienteDoServico(VarBaudRate);
  if BaudAtual = '' then BaudAtual := '{#BaudRatePadrao}';

  PaginaSerial := CreateInputQueryPage(wpSelectDir,
    'Balança do self-service',
    'Porta serial em que a balança está ligada',
    'Confira no Gerenciador de Dispositivos (Portas COM e LPT). Os parâmetros de leitura (tara, ' +
    'faixas, estabilidade) continuam vindo do cadastro da balança no sistema.');
  PaginaSerial.Add('Porta serial (ex.: COM3):', False);
  PaginaSerial.Add('Velocidade (baud rate):', False);

  { Silencioso: /PORTA= e /BAUD= (sem segredo na linha de comando — ele é gerado aqui). }
  PaginaSerial.Values[0] := ExpandConstant('{param:PORTA|' + PortaAtual + '}');
  PaginaSerial.Values[1] := ExpandConstant('{param:BAUD|' + BaudAtual + '}');
end;

function PortaValida(const Porta: String): Boolean;
var
  I: Integer;
begin
  Result := (Length(Porta) >= 4) and (Length(Porta) <= 6) and (CompareText(Copy(Porta, 1, 3), 'COM') = 0);
  if not Result then Exit;
  for I := 4 to Length(Porta) do
    if Pos(Copy(Porta, I, 1), '0123456789') = 0 then
    begin
      Result := False;
      Exit;
    end;
end;

function ParametrosValidos(var Mensagem: String): Boolean;
begin
  Mensagem := '';
  PaginaSerial.Values[0] := Uppercase(Trim(PaginaSerial.Values[0]));
  PaginaSerial.Values[1] := Trim(PaginaSerial.Values[1]);

  if not PortaValida(PaginaSerial.Values[0]) then
    Mensagem := 'Porta serial inválida: "' + PaginaSerial.Values[0] + '". Use o formato COMn (ex.: COM3).'
  else if StrToIntDef(PaginaSerial.Values[1], 0) <= 0 then
    Mensagem := 'Velocidade inválida: "' + PaginaSerial.Values[1] + '". Informe um número (ex.: 9600).';

  Result := Mensagem = '';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Mensagem: String;
begin
  Result := True;
  if CurPageID = PaginaSerial.ID then
  begin
    Result := ParametrosValidos(Mensagem);
    if not Result then
      MsgBox(Mensagem, mbError, MB_OK);
  end;
end;

{ Antes do primeiro arquivo copiado (inclusive no silencioso): valida os parâmetros e tira o
  serviço anterior do caminho. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not ParametrosValidos(Result) then Exit;

  if not PararServico() then
    Result := 'Não foi possível parar o serviço "{#ServicoNome}" em execução. Pare-o em ' +
              'services.msc e execute o instalador novamente.';
end;

{ ---------- pós-instalação ---------- }

procedure Falhar(const Mensagem: String);
begin
  if not ServicoExistiaAntes then
    RemoverServico();
  RaiseException(Mensagem + #13#10#13#10 + 'Detalhe no log da instalação (%TEMP%\Setup Log*.txt).');
end;

procedure ConfigurarServico();
var
  Exe, Ambiente: String;
  Codigo: Integer;
begin
  Exe := ExpandConstant('{app}\{#AgenteExe}');

  { binPath= exige espaço depois do `=` e aspas DENTRO do valor: sem elas o SCM registra
    `C:\Program` como imagem e o serviço reinicia em laço (armadilha #101c). }
  if ServicoRegistrado() then
    Codigo := Sc('config "{#ServicoNome}" binPath= "\"' + Exe + '\"" start= auto')
  else
    Codigo := Sc('create "{#ServicoNome}" binPath= "\"' + Exe + '\"" start= auto ' +
                 'DisplayName= "SisPedraCaida Agente da Balanca"');
  if Codigo <> 0 then
  begin
    Falhar('Não foi possível registrar o serviço "{#ServicoNome}" (sc código ' + IntToStr(Codigo) + ').');
    Exit;
  end;

  Sc('description "{#ServicoNome}" "Le a balanca serial do self-service e entrega o peso estabilizado ao PDV (loopback 127.0.0.1:{#PortaLoopback})."');
  { Recuperação: o agente nunca desiste da serial, mas o PROCESSO pode cair; sem isto o balcão
    fica sem balança até alguém reiniciar o PC. }
  Sc('failure "{#ServicoNome}" reset= 86400 actions= restart/5000/restart/10000/restart/30000');

  Ambiente := VarAgentId + '=' + AgentIdEfetivo + #0 +
              VarSegredo + '=' + SegredoEfetivo + #0 +
              VarPorta + '=' + PaginaSerial.Values[0] + #0 +
              VarBaudRate + '=' + PaginaSerial.Values[1];
  if not RegWriteMultiStringValue(HKLM, ChaveServico, 'Environment', Ambiente) then
  begin
    Falhar('Não foi possível gravar a configuração do serviço no registro.');
    Exit;
  end;
  Log('[Balanca] Configuração gravada: AgentId ' + AgentIdEfetivo + ' (' + OrigemAgentId + '), porta ' +
      PaginaSerial.Values[0] + ', ' + PaginaSerial.Values[1] + ' baud. Segredo NÃO registrado no log.');

  Codigo := Sc('start "{#ServicoNome}"');
  { "Comando aceito" não é "serviço em execução" (#101d): confirma RUNNING. }
  if PowerShell('(Get-Service -Name ''{#ServicoNome}'' -ErrorAction Stop).WaitForStatus(''Running'', ' +
                '[TimeSpan]::FromSeconds(30))') <> 0 then
  begin
    Falhar('O serviço "{#ServicoNome}" foi registrado mas não entrou em execução.');
    Exit;
  end;

  { "Em execução" ainda não é "loopback no ar": sem segredo o endpoint não sobe, e porta ocupada
    derruba o host. A sonda usa um segredo ERRADO de propósito — 404 prova que o Kestrel está
    ouvindo com o segredo carregado, sem pôr o segredo verdadeiro numa linha de comando. }
  if PowerShell('for ($i = 0; $i -lt 20; $i++) { try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 ' +
                '-Uri ''http://127.0.0.1:{#PortaLoopback}/sonda/balanca/estado'' | Out-Null; exit 0 } ' +
                'catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { exit 0 } }; ' +
                'Start-Sleep -Seconds 1 }; exit 1') <> 0 then
  begin
    Falhar('O serviço está em execução, mas o loopback 127.0.0.1:{#PortaLoopback} não respondeu. ' +
           'Verifique se outra aplicação ocupa a porta {#PortaLoopback}.');
    Exit;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    ConfigurarServico();
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption :=
      'O agente da balança está instalado, em execução e respondendo em 127.0.0.1:{#PortaLoopback}.' + #13#10#13#10 +
      'Identidade da estação (' + OrigemAgentId + '):' + #13#10 + AgentIdEfetivo + #13#10#13#10 +
      'Segredo do loopback (configure-o no PDV desta estação):' + #13#10 + SegredoEfetivo + #13#10#13#10 +
      'Porta serial: ' + PaginaSerial.Values[0] + ' (' + PaginaSerial.Values[1] + ' baud).';
end;

{ ---------- desinstalação ---------- }

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { Antes de apagar os arquivos: com o serviço vivo o executável está travado. Remover o serviço
    leva junto a configuração gravada no ambiente dele. }
  if CurUninstallStep = usUninstall then
    RemoverServico();
end;
