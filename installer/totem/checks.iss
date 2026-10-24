{ ============================================================================================
   checks.iss — pré-requisitos do totem (PRD-TOTEM-04 §1)

   Duas famílias, de propósito separadas (o mesmo desenho do agente TEF):
     • BLOQUEANTES, avaliadas em InitializeSetup — antes de o wizard existir e antes de copiar um
       único arquivo. Em modo silencioso encerram com código de falha e a razão no log, nunca
       "sucesso" silencioso.
     • AVISOS, montados para a tela de pré-requisitos e para o log.

   ⚠️ O WebView2 Runtime é AVISO, não bloqueio. Sem ele a casca mostra a tela "fora de serviço" e
   registra o motivo no log; o serviço, a identidade e o sinal com a API funcionam normalmente, e o
   totem aparece no painel para ser liberado. Recusar a instalação por isso deixaria a máquina sem
   nada, quando o que falta é um componente que o próprio Windows Update costuma trazer.
   ============================================================================================ }

const
  DiscoMinimoMB = 600;

  // Entrada de desinstalação do próprio AppId (o sufixo _is1 é a assinatura do Inno).
  ChaveDesinstalacao =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{C9D9108B-9DB0-450D-986B-7470728B6123}_is1';

  // Chave de cliente do EdgeUpdate que identifica o WebView2 Runtime "Evergreen" (GUID publicado
  // pela Microsoft). O valor `pv` é a versão instalada; vazio ou 0.0.0.0 significa AUSENTE — é o
  // que fica para trás quando o runtime é removido.
  // ⚠️ O caminho vai SEM o WOW6432Node: o runtime da máquina é registrado pelo EdgeUpdate, que é
  // 32 bits, e a leitura pela raiz HKLM32 (abaixo) já cai em WOW6432Node. Este instalador roda em
  // modo 64 bits (ArchitecturesInstallIn64BitMode), onde HKLM é a visão de 64 bits — ler só HKLM com
  // este caminho devolveria "ausente" numa máquina que tem o runtime (o mesmo falso negativo do
  // TEF HUB no instalador do TEF).
  ChaveWebView2 = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

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

{ Espaço livre em MB no volume dos programas. }
function EspacoLivreMB(): Cardinal;
var
  Livre, Total: Int64;
begin
  Result := 0;
  if GetSpaceOnDisk64(ExpandConstant('{autopf}'), Livre, Total) then
    Result := Cardinal(Livre div 1048576);
end;

{ Indica se o serviço do totem já está registrado neste terminal. Reinstalação é normal: o
  Setup.exe para, re-registra e reinicia o serviço em vez de falhar. }
function ServicoJaRegistrado(): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if Exec(ExpandConstant('{sys}\sc.exe'), 'query "{#ServicoNome}"', '', SW_HIDE,
          ewWaitUntilTerminated, Codigo) then
    Result := (Codigo = 0);
end;

{ Indica se este terminal já tem identidade (já foi provisionado alguma vez). Ela é preservada:
  o Setup.exe a reaproveita e o totem continua sendo o mesmo no painel. }
function IdentidadeExiste(): Boolean;
begin
  Result := FileExists(ExpandConstant('{#PastaDados}\config\identidade.json'));
end;

{ Indica se a sessão do totem ficou BLOQUEADA por uma instalação anterior (as políticas foram
  aplicadas e o estado anterior guardado). Informativo: o --uninstall restaura, o upgrade mantém. }
function SessaoBloqueadaGravada(): Boolean;
begin
  Result := FileExists(ExpandConstant('{#PastaDados}\config\estado-bloqueio.json'));
end;

{ Versão do WebView2 Runtime numa raiz do registro, ou vazio quando ausente. }
function VersaoWebView2Em(Raiz: Integer): String;
var
  Valor: String;
begin
  Result := '';

  if RegQueryStringValue(Raiz, ChaveWebView2, 'pv', Valor) then
  begin
    Valor := Trim(Valor);
    if (Valor <> '') and (Valor <> '0.0.0.0') then
      Result := Valor;
  end;
end;

{ Versão do WebView2 Runtime instalado PARA A MÁQUINA (vazio quando ausente). Primeiro a visão de
  32 bits, onde o EdgeUpdate registra; depois a de 64 bits, por segurança.

  ⚠️ É a instalação da máquina que decide, não a do usuário: o instalador roda com a conta do
  técnico, e a casca roda com a conta padrão do totem. Um runtime instalado só no perfil do
  técnico (HKCU) não existe para a conta do totem — então, sem o da máquina, o bootstrapper roda
  (elevado, ele instala para a máquina). }
function VersaoWebView2DaMaquina(): String;
begin
  Result := VersaoWebView2Em(HKLM32);

  if Result = '' then
    Result := VersaoWebView2Em(HKLM64);
end;

{ Versão do WebView2 Runtime instalado só no perfil de quem está instalando (informativo). }
function VersaoWebView2DoUsuario(): String;
begin
  Result := VersaoWebView2Em(HKCU);
end;

{ Usado pelo Check do [Files]: o bootstrapper só é extraído quando o runtime falta na máquina. }
function WebView2DaMaquinaAusente(): Boolean;
begin
  Result := VersaoWebView2DaMaquina() = '';
end;

{ Indica se este pacote traz o bootstrapper do WebView2 (definido no build por /D). }
function PacoteTrazBootstrapperWebView2(): Boolean;
begin
  Result := '{#WebView2BootstrapperNome}' <> '';
end;

{ Linha do WebView2 para a tela de pré-requisitos, o resumo e o log. }
function LinhaDoWebView2(): String;
var
  Maquina, Usuario: String;
begin
  Maquina := VersaoWebView2DaMaquina();
  Usuario := VersaoWebView2DoUsuario();

  if Maquina <> '' then
    Result := 'instalado na máquina (versão ' + Maquina + ') — OK'
  else if PacoteTrazBootstrapperWebView2() then
    Result := 'ausente na máquina — será instalado agora pelo instalador oficial da Microsoft ' +
              '(precisa de acesso à internet nesta máquina).'
  else
    Result := 'AUSENTE na máquina, e este pacote não traz o instalador do runtime. A instalação ' +
              'continua, mas a tela do totem mostrará "fora de serviço" até o WebView2 Runtime ser ' +
              'instalado (Windows Update ou o instalador oficial da Microsoft).';

  if (Maquina = '') and (Usuario <> '') then
    Result := Result + ' Há uma cópia só no perfil deste usuário (versão ' + Usuario + '), que não ' +
              'vale para a conta do totem.';
end;

{ Checagens que impedem a instalação. MinVersion, ArchitecturesAllowed e PrivilegesRequired da
  seção Setup já recusam a maioria; aqui fica o que o Inno não sabe checar sozinho, com mensagem clara.
  ⚠️ Em modo silencioso MsgBox não aparece: SuppressibleMsgBox devolve o default e o log registra a
  razão, de modo que a instalação falha explicitamente em vez de travar invisivelmente. }
function ChecagensBloqueantesAprovadas(): Boolean;
var
  Livre: Cardinal;
  Mensagem: String;
begin
  Result := True;

  if not Is64BitInstallMode() then
  begin
    Mensagem := 'Este terminal não é 64 bits. O pacote do totem é win-x64 e não roda aqui.';
    Log('[Totem] BLOQUEIO: ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbCriticalError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;

  { Redundante com o PrivilegesRequired=admin de propósito: um /VERYSILENT disparado por
    ferramenta sem elevação não abre o UAC, e a razão precisa ficar escrita no log. }
  if not IsAdminInstallMode() then
  begin
    Mensagem := 'O instalador do totem precisa rodar como administrador: ele registra um serviço ' +
                'do Windows, grava em %PROGRAMDATA% e aplica as políticas da sessão do totem.';
    Log('[Totem] BLOQUEIO: ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbCriticalError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;

  Livre := EspacoLivreMB();
  if (Livre > 0) and (Livre < DiscoMinimoMB) then
  begin
    Mensagem := 'Espaço insuficiente em ' + ExpandConstant('{autopf}') + ': ' + IntToStr(Livre) +
                ' MB livres, mínimo de ' + IntToStr(DiscoMinimoMB) + ' MB.' + #13#10 +
                'O totem é publicado self-contained (traz o runtime .NET embutido).';
    Log('[Totem] BLOQUEIO: ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbCriticalError, MB_OK, IDOK);
    Result := False;
  end;
end;

{ Monta (uma vez) o texto de pré-requisitos exibido na tela e gravado no log. }
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
  Linhas := Linhas + 'Privilégio: administrador — OK' + #13#10;
  Linhas := Linhas + 'Disco livre em ' + ExpandConstant('{autopf}') + ': ' +
            IntToStr(EspacoLivreMB()) + ' MB — OK' + #13#10;
  Linhas := Linhas + 'WebView2 Runtime: ' + LinhaDoWebView2() + #13#10;

  if ServicoJaRegistrado() then
    Linhas := Linhas + 'Serviço ' + '{#ServicoNome}' + ': já registrado — será PARADO antes da ' +
              'cópia e reiniciado no fim (atualização no lugar).' + #13#10
  else
    Linhas := Linhas + 'Serviço ' + '{#ServicoNome}' + ': ausente — será registrado com início ' +
              'automático.' + #13#10;

  if IdentidadeExiste() then
    Linhas := Linhas + 'Identidade: este terminal já tem identidade — ela é PRESERVADA (o totem ' +
              'continua sendo o mesmo no painel).' + #13#10
  else
    Linhas := Linhas + 'Identidade: ausente — será criada agora; o totem aparece no painel ' +
              'aguardando liberação.' + #13#10;

  if SessaoBloqueadaGravada() then
    Linhas := Linhas + 'Sessão do totem: bloqueada por uma instalação anterior — continua assim ' +
              'depois da atualização (a desinstalação é que restaura).' + #13#10;

  ResultadoDasChecagens := Linhas;
  Log('[Totem] Pré-requisitos:' + #13#10 + Linhas);
  Result := Linhas;
end;

{ Contrato do PrepareToInstall: string vazia libera a instalação. As checagens já rodaram; aqui
  elas só são reavaliadas para constar do log da instalação silenciosa, que não tem a tela. }
function ChecagensDePreparacao(): String;
begin
  TextoDasChecagens();
  Result := '';
end;
