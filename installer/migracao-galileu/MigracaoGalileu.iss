; ============================================================================================
;  Migrador Galileu → SisPedraCaida — instalador Windows (Inno Setup 6)
;  PRD-MGGINST-01 (épico migracao-galileu-instalador)
;
;  Compile SEMPRE por `build-installer.ps1`: ele publica o layout self-contained single-file do
;  app (`scripts/migracao-galileu-publish.ps1` do backend pinado) e injeta as definições abaixo
;  por /D no ISCC. Compilar este arquivo direto na IDE falha de propósito.
;
;  Diferente dos agentes, o migrador NÃO é Windows Service: não há Setup.exe, provisionamento,
;  configuração de rede nem dado em %PROGRAMDATA%. O instalador copia o layout, cria o atalho e
;  recusa downgrade — nada mais. O que o app grava é POR USUÁRIO e criado por ele mesmo:
;    %APPDATA%\SisPedraCaida\MigracaoGalileu\ultima-sessao.json   (senha protegida por DPAPI)
;    %LOCALAPPDATA%\SisPedraCaida\MigracaoGalileu\restore\...     (log/rejeitados do restore)
; ============================================================================================

#ifndef AppVersion
  #error Defina AppVersion pelo build-installer.ps1 (/DAppVersion=...)
#endif
#ifndef PublishDir
  #error Defina PublishDir pelo build-installer.ps1 (/DPublishDir=...)
#endif

#define AppNome "SisPedraCaida Migrador Galileu"

; Mesmo editor e canal de suporte dos instaladores dos agentes (ver TefAgent.iss): é o texto que o
; UAC e "Aplicativos e Recursos" mostram.
#define AppPublisher "B3R3CH1T Desenvolvimento de Sistemas"
#define AppCopyright "© 2026 B3R3CH1T Desenvolvimento de Sistemas"
#define AppSuporteEmail "anderson.meneses@gmail.com"

; Nome do executável publicado: é o AssemblyName do projeto do backend (o nome da pasta sob src/).
; Guarda MigracaoGalileuInnoGuardTests.
#define AppExe "SisPedraCaida.Tools.MigracaoGalileu.App.exe"

[Setup]
; AppId é a IDENTIDADE da instalação: gerado uma vez (31/10/2026) e NUNCA alterado — trocá-lo faz o
; pacote novo não reconhecer o antigo. Próprio, nunca o de um agente.
AppId={{84138E5C-EAA9-4D1E-947F-9E3BE09DCBE8}
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

DefaultDirName={autopf}\SisPedraCaida\MigracaoGalileu
DefaultGroupName=SisPedraCaida
DisableProgramGroupPage=yes
OutputBaseFilename=MigracaoGalileuSetup-{#AppVersion}
OutputDir=..\..\artifacts\installer

; Ícone compartilhado com os demais instaladores (um .ico por instalador divergiria no primeiro
; ajuste de marca). O de "Aplicativos e Recursos" vem do UninstallDisplayIcon: o ícone embutido
; no próprio .exe, que é o <ApplicationIcon> do .csproj — o mesmo .ico, do lado do backend.
SetupIconFile=..\assets\sispedracaida.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppNome}

; Por máquina, em Program Files (PRD-MGGINST-01 D3): o técnico pode abrir o assistente com outra
; conta no mesmo servidor do Galileu. O APP é asInvoker — só a instalação pede elevação.
PrivilegesRequired=admin

; Pacote win-x64 (o layout é publicado para esse RID).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Windows 10 1607 — piso técnico do runtime .NET.
MinVersion=10.0.14393

Compression=lzma2/max
SolidCompression=yes
SetupLogging=yes

; ⚠️ Ao contrário dos agentes (CloseApplications=no, quem para o processo é o Setup.exe), aqui não
; há Setup.exe: o Restart Manager fecha o assistente aberto antes de sobrescrever o .exe, que de
; outro modo ficaria travado (PRD-MGGINST-01 D5). Sem reabrir: uma migração em curso não é algo
; que se retome sozinho.
CloseApplications=yes
RestartApplications=no

WizardStyle=modern
ShowLanguageDialog=no

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "atalhodesktop"; Description: "Criar atalho na área de trabalho"; \
  GroupDescription: "Atalhos:"; Flags: unchecked

[Files]
; ignoreversion é OBRIGATÓRIO: sem ele o Inno compara versão de arquivo e PULA binários, deixando o
; .exe da versão anterior no lugar. `*.xml` são os doc-comments do build: inúteis na máquina.
Source: "{#PublishDir}\*"; DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs ignoreversion; \
  Excludes: "*.pdb,*.xml"

[Icons]
Name: "{group}\Migrador Galileu"; Filename: "{app}\{#AppExe}"; \
  Comment: "Migrar a base do Galileu (MariaDB) para o SisPedraCaida (PostgreSQL)"
Name: "{autodesktop}\Migrador Galileu"; Filename: "{app}\{#AppExe}"; Tasks: atalhodesktop

[Run]
; ⚠️ `runasoriginaluser`: o instalador roda elevado, e sem a flag o assistente nasceria como
; administrador — gravando a sessão (DPAPI do usuário) no perfil errado.
Filename: "{app}\{#AppExe}"; Description: "Abrir o Migrador Galileu"; \
  Flags: runasoriginaluser nowait postinstall skipifsilent

; ⚠️ NADA de [UninstallDelete] sob {userappdata}/{localappdata} (PRD-MGGINST-01 D4): elevado, estes
; seriam o perfil do ADMINISTRADOR, não o do técnico; e a sessão anterior e o log do restore são a
; evidência da migração. Nada em {commonappdata}: o app não grava lá.

[Code]
{ Comentário aqui é de chaves ou `//`, NUNCA `;` (dentro de [Code] o compilador lê Pascal). }

const
  ChaveDesinstalacao = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{84138E5C-EAA9-4D1E-947F-9E3BE09DCBE8}_is1';

{ Lê a versão já instalada a partir da chave de desinstalação do próprio AppId. }
function VersaoJaInstalada(): String;
begin
  Result := '';

  if not RegQueryStringValue(HKLM, ChaveDesinstalacao, 'DisplayVersion', Result) then
    if not RegQueryStringValue(HKCU, ChaveDesinstalacao, 'DisplayVersion', Result) then
      Result := '';
end;

{ Extrai o n-ésimo componente numérico de uma versão "a.b.c.d" (0 quando ausente). Escrito à mão,
  como no checks.iss do TEF: StringSplitEx só existe a partir do Inno 6.3. }
function ComponenteDaVersao(Versao: String; Indice: Integer): Integer;
var
  i, Atual: Integer;
  Parte: String;
begin
  Result := 0;
  Atual := 0;
  Parte := '';

  for i := 1 to Length(Versao) + 1 do
  begin
    if (i > Length(Versao)) or (Versao[i] = '.') then
    begin
      if Atual = Indice then
      begin
        Result := StrToIntDef(Parte, 0);
        Exit;
      end;

      Atual := Atual + 1;
      Parte := '';
    end
    else
      Parte := Parte + Versao[i];
  end;
end;

{ Compara duas versões. >0 quando A é maior, 0 quando iguais, <0 quando menor. }
function CompareVersaoInstalada(A, B: String): Integer;
var
  i, NumA, NumB: Integer;
begin
  Result := 0;

  for i := 0 to 3 do
  begin
    NumA := ComponenteDaVersao(A, i);
    NumB := ComponenteDaVersao(B, i);

    if NumA > NumB then
    begin
      Result := 1;
      Exit;
    end;

    if NumA < NumB then
    begin
      Result := -1;
      Exit;
    end;
  end;
end;

{ Bloqueio de downgrade, a mesma política dos agentes: a mesma versão reinstala, a menor é recusada.
  Uma versão antiga do migrador geraria pacote .sql com regras de mapeamento já corrigidas. }
function InitializeSetup(): Boolean;
var
  VersaoInstalada: String;
begin
  Result := True;

  VersaoInstalada := VersaoJaInstalada();
  if (VersaoInstalada <> '') and (CompareVersaoInstalada(VersaoInstalada, '{#AppVersion}') > 0) then
  begin
    MsgBox('Uma versão mais recente do ' + '{#AppNome}' + ' já está instalada nesta máquina (' +
           VersaoInstalada + '). Instalar a versão {#AppVersion} por cima faria a ferramenta regredir.' + #13#10#13#10 +
           'Desinstale a versão atual antes, se a regressão for intencional.',
           mbError, MB_OK);
    Result := False;
  end;
end;
