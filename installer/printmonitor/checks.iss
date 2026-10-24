{ ============================================================================================
   checks.iss — pré-requisitos da estação Windows 10 (etapa 04 §2)

   Duas famílias, de propósito separadas:
     • BLOQUEANTES, avaliadas em InitializeSetup — antes de o wizard existir e antes de copiar
       um único arquivo. Em modo silencioso encerram com código de falha e a razão no log,
       nunca "sucesso" silencioso.
     • AVISOS, montados para a tela 3 do wizard. Instalar sem rede (ou com a 8181 ocupada) é
       cenário legítimo: a estação é configurável depois, pelo atalho "Configurar PrintMonitor".

   O alvo Windows 10 eliminou a cadeia de KBs, o TLS 1.2 manual e o VC++ Redistributable que o
   caminho Windows 7 exigia — o Universal CRT faz parte do SO. Sobra o que é do produto.
   ============================================================================================ }

const
  DiscoMinimoMB = 1024;
  { Porta wss do QZ Tray (QzTrayConstants.SecurePort) — a 8182 é a ws, HTTP puro. }
  PortaSeguraQz = 8181;
  { Imagem do processo do QZ Tray (QzTrayConstants.ProcessName + .exe) — usada pelo upgrade.iss. }
  QzTrayImagem = 'qz-tray.exe';
  ChaveDesinstalacao =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8B6F2C41-77F3-4B2E-9E5A-1D0C4A9E7B31}_is1';

var
  ResultadoDasChecagens: String;

{ Lê a versão já instalada a partir da chave de desinstalação do próprio AppId. }
function VersaoJaInstalada(): String;
begin
  Result := '';

  if not RegQueryStringValue(HKLM, ChaveDesinstalacao, 'DisplayVersion', Result) then
    if not RegQueryStringValue(HKCU, ChaveDesinstalacao, 'DisplayVersion', Result) then
      Result := '';
end;

{ Extrai o n-ésimo componente numérico de uma versão "a.b.c.d" (0 quando ausente).
  Escrito à mão: StringSplitEx só existe a partir do Inno 6.3 e este script precisa compilar em
  qualquer 6.x que a máquina de build tenha. }
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

{ Espaço livre em MB no volume do diretório de destino. }
function EspacoLivreMB(): Cardinal;
var
  Livre, Total: Int64;
begin
  Result := 0;
  if GetSpaceOnDisk64(ExpandConstant('{autopf}'), Livre, Total) then
    Result := Cardinal(Livre div 1048576);
end;

{ Indica se o QZ Tray já está instalado nesta estação. }
function QzTrayJaInstalado(): Boolean;
begin
  Result := FileExists(ExpandConstant('{commonpf}\QZ Tray\qz-tray.exe')) or
            FileExists(ExpandConstant('{commonpf32}\QZ Tray\qz-tray.exe'));
end;

{ Caminho do executável do QZ Tray instalado ('' quando ausente) — o upgrade o reabre se o fechou. }
function CaminhoDoQzTray(): String;
begin
  Result := ExpandConstant('{commonpf}\QZ Tray\qz-tray.exe');
  if not FileExists(Result) then
    Result := ExpandConstant('{commonpf32}\QZ Tray\qz-tray.exe');
  if not FileExists(Result) then
    Result := '';
end;

{ Indica se o serviço do PrintMonitor já está registrado nesta estação (reinstalação ou upgrade). }
function ServicoJaRegistrado(): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if Exec(ExpandConstant('{sys}\sc.exe'), 'query "{#ServicoNome}"', '', SW_HIDE,
          ewWaitUntilTerminated, Codigo) then
    Result := (Codigo = 0);
end;

{ Porta segura do QZ Tray livre em localhost. `netstat` é o caminho sem dependência externa;
  ocupada por outro processo, a impressão falha DEPOIS — por isso é aviso, não bloqueio. }
function PortaSeguraLivre(): Boolean;
var
  Codigo: Integer;
begin
  Result := True;

  if Exec(ExpandConstant('{cmd}'),
          '/C netstat -ano -p TCP | findstr /R /C:":' + IntToStr(PortaSeguraQz) + ' .*LISTENING" > nul',
          '', SW_HIDE, ewWaitUntilTerminated, Codigo) then
    Result := (Codigo <> 0);
end;

{ Checagens que impedem a instalação. MinVersion e ArchitecturesAllowed do [Setup] já recusam a
  maioria; aqui fica o que o Inno não sabe checar sozinho, com mensagem em texto claro.
  ⚠️ Em modo silencioso MsgBox não aparece: SuppressibleMsgBox devolve o default e o log registra
  a razão, de modo que a instalação falha explicitamente em vez de travar invisivelmente. }
function ChecagensBloqueantesAprovadas(): Boolean;
var
  Livre: Cardinal;
  Mensagem: String;
begin
  Result := True;

  if not Is64BitInstallMode() then
  begin
    Mensagem := 'Esta estação não é 64 bits. O pacote do PrintMonitor é win-x64 e não roda aqui.' + #13#10 +
                'Uma estação 32 bits exige um pacote win-x86 (decisão de escopo, etapa 01 do épico).';
    Log('[PrintMonitor] BLOQUEIO: ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbCriticalError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;

  Livre := EspacoLivreMB();
  if (Livre > 0) and (Livre < DiscoMinimoMB) then
  begin
    Mensagem := 'Espaço insuficiente em ' + ExpandConstant('{autopf}') + ': ' + IntToStr(Livre) +
                ' MB livres, mínimo de ' + IntToStr(DiscoMinimoMB) + ' MB.' + #13#10 +
                'O agente é self-contained e o QZ Tray traz um JRE embutido.';
    Log('[PrintMonitor] BLOQUEIO: ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbCriticalError, MB_OK, IDOK);
    Result := False;
  end;
end;

{ Monta (uma vez) o texto de pré-requisitos exibido na tela 3 e gravado no log. }
function TextoDasChecagens(): String;
var
  Linhas: String;
begin
  if ResultadoDasChecagens <> '' then
  begin
    Result := ResultadoDasChecagens;
    Exit;
  end;

  Linhas := 'Windows: ' + GetWindowsVersionString() + ' (mínimo 10.0.14393) — OK' + #13#10;
  Linhas := Linhas + 'Arquitetura: x64 — OK' + #13#10;
  Linhas := Linhas + 'Disco livre em ' + ExpandConstant('{autopf}') + ': ' +
            IntToStr(EspacoLivreMB()) + ' MB — OK' + #13#10;

  if PortaSeguraLivre() then
    Linhas := Linhas + 'Porta ' + IntToStr(PortaSeguraQz) + ' (QZ Tray): livre — OK' + #13#10
  else
    Linhas := Linhas + 'Porta ' + IntToStr(PortaSeguraQz) + ' (QZ Tray): OCUPADA — aviso: outro ' +
              'processo já escuta nessa porta e a impressão pode falhar depois.' + #13#10;

  { Upgrade no lugar (PRD-PMTRAY-03): mesma pasta, serviço parado com confirmação, identidade e
    configuração preservadas. A versão anterior vem da entrada de desinstalação do AppId. }
  if ServicoJaRegistrado() or (VersaoJaInstalada() <> '') then
    Linhas := Linhas + 'Instalação anterior: ' + VersaoJaInstalada() + ' — ATUALIZAÇÃO no lugar: o serviço ' +
              'será PARADO (com confirmação), a bandeja e o Helper fechados e reabertos no fim; a identidade ' +
              'da estação e a configuração gravada são PRESERVADAS.' + #13#10
  else
    Linhas := Linhas + 'Instalação anterior: nenhuma — instalação nova.' + #13#10;

  if QzTrayJaInstalado() then
    Linhas := Linhas + 'QZ Tray: já instalado — a instalação do payload será pulada.' + #13#10
  else
    Linhas := Linhas + 'QZ Tray: ausente — será instalado a partir do payload local.' + #13#10;

  ResultadoDasChecagens := Linhas;
  Log('[PrintMonitor] Pré-requisitos:' + #13#10 + Linhas);
  Result := Linhas;
end;

{ Contrato do PrepareToInstall: string vazia libera a instalação. As checagens já rodaram; aqui
  elas só são reavaliadas para constar do log da instalação silenciosa, que não tem tela 3.
  Parar o serviço e fechar bandeja e Helper antes da cópia é do upgrade.iss (PrepararUpgrade,
  PRD-PMTRAY-03), chamado logo depois desta pelo PrepareToInstall. }
function ChecagensDePreparacao(): String;
begin
  TextoDasChecagens();
  Result := '';
end;
