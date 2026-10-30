{ ============================================================================================
   checks.iss — pré-requisitos do terminal (PRD-TEFINST-06 §3)

   Duas famílias, de propósito separadas:
     • BLOQUEANTES, avaliadas em InitializeSetup — antes de o wizard existir e antes de copiar um
       único arquivo. Em modo silencioso encerram com código de falha e a razão no log, nunca
       "sucesso" silencioso.
     • AVISOS, montados para a tela de pré-requisitos. Instalar sem rede, ou antes de o técnico da
       Elgin configurar o pinpad, é cenário legítimo: o endereço é editável depois pelo atalho
       "Configurar o agente TEF".

   ⚠️ O Elgin TEF Web NÃO é procurado por pasta de instalação: não redistribuímos o produto e não
   fixamos o caminho dele. Quem responde "o Elgin está no ar?" é o botão "Testar conexão" da página
   de conexão, sobre a URL que o operador informou — inventar aqui um caminho provável produziria
   um "ausente" falso num terminal que opera.

   ⚠️ A detecção do Elgin TEF HUB e do E1_Connect (PRD-TEFHUB-01, PRD-ELGPRE-01) é a MESMA regra por
   outro caminho: lemos a chave de desinstalação do produto, que é identidade registrada por ele, e NÃO
   uma pasta que chutamos. Este instalador **não baixa e não instala** nenhum dos dois (D7, de volta
   desde 30/10/2026): a ausência BLOQUEIA a instalação (tefhub.iss). "Instalado" continua não sendo
   "pronto para operar" — isso é o "Testar conexão".
   ============================================================================================ }

const
  DiscoMinimoMB = 500;
  ChaveDesinstalacao =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{C3F1A7D2-6B48-4E95-9A1C-2D7E8F4B5106}_is1';

  { Raiz das entradas de "Programas e Recursos", usada tanto pelo AppId exato quanto pela varredura. }
  BaseDesinstalacao = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';

  { AppId do instalador (Inno) da Elgin — o sufixo `_is1` é a assinatura do próprio Inno. Levantado
    em 15/10/2026 num terminal com o "Elgin TEFHUB versão 06.02.00" instalado, publisher Elgin S/A. }
  ChaveTefHub = BaseDesinstalacao + '\{404E58AC-6853-41C7-B076-0E2036F9E04B}_is1';

  { Usado só pela varredura de segurança, quando o AppId não bate. }
  MarcaTefHub = 'TEFHUB';

  { AppId do E1_Connect, componente que o pacote do TEF HUB instala junto (é ele que atende o Elgin
    TEF Web). Levantado em 30/10/2026 num terminal com o "E1_Connect versão 02.01.00", publisher Elgin
    S/A — também x86, também sob WOW6432Node. }
  ChaveE1Connect = BaseDesinstalacao + '\{28910153-EEED-4710-BBD3-7B6BADF2E103}_is1';
  MarcaE1Connect = 'E1_CONNECT';

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

{ Indica se o serviço do agente já está registrado neste terminal. Reinstalação é normal: o
  provisionamento atualiza o caminho em vez de falhar. }
function ServicoJaRegistrado(): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if Exec(ExpandConstant('{sys}\sc.exe'), 'query "{#ServicoNome}"', '', SW_HIDE,
          ewWaitUntilTerminated, Codigo) then
    Result := (Codigo = 0);
end;

{ Indica se este terminal já operou (existe banco local com estado de transações). }
function BancoLocalExiste(): Boolean;
begin
  Result := FileExists(ExpandConstant('{#PastaDados}\data\agent.db'));
end;

{ Varre as entradas de desinstalação de UMA visão do registro procurando o produto pelo nome.
  Rede de segurança do AppId: se a Elgin trocar o AppId num release futuro, um "ausente" falso
  bloquearia a instalação num terminal que já tem o produto. }
function ProcurarProdutoPorNome(Raiz: Integer; Marca: String; var Nome: String; var Versao: String): Boolean;
var
  Chaves: TArrayOfString;
  i: Integer;
  NomeAtual: String;
begin
  Result := False;

  if not RegGetSubkeyNames(Raiz, BaseDesinstalacao, Chaves) then
    Exit;

  for i := 0 to GetArrayLength(Chaves) - 1 do
  begin
    if RegQueryStringValue(Raiz, BaseDesinstalacao + '\' + Chaves[i], 'DisplayName', NomeAtual) then
    begin
      if Pos(Marca, Uppercase(NomeAtual)) > 0 then
      begin
        Nome := NomeAtual;

        if not RegQueryStringValue(Raiz, BaseDesinstalacao + '\' + Chaves[i], 'DisplayVersion', Versao) then
          Versao := '';

        Result := True;
        Exit;
      end;
    end;
  end;
end;

{ Indica se um produto da Elgin está INSTALADO neste terminal (não se está no ar — ver o cabeçalho):
  pelo AppId exato e, quando ele não bate, pela marca no nome. }
function ProdutoElginInstalado(Chave, Marca: String; var Nome: String; var Versao: String): Boolean;
begin
  Nome := '';
  Versao := '';

  { ⚠️ HKLM32, não HKLM: os produtos da Elgin são x86 e registram sob WOW6432Node, enquanto ESTE
    instalador roda em modo 64 bits (ArchitecturesInstallIn64BitMode) — onde `HKLM` aponta para a
    visão de 64 bits. Ler `HKLM` aqui devolve "ausente" num terminal que opera, que é exatamente o
    falso negativo que o cabeçalho deste arquivo proíbe. Verificado: as chaves existem SÓ sob
    WOW6432Node. }
  if RegQueryStringValue(HKLM32, Chave, 'DisplayName', Nome) then
  begin
    if not RegQueryStringValue(HKLM32, Chave, 'DisplayVersion', Versao) then
      Versao := '';

    Result := True;
    Exit;
  end;

  Result := ProcurarProdutoPorNome(HKLM32, Marca, Nome, Versao);

  if not Result then
    Result := ProcurarProdutoPorNome(HKLM, Marca, Nome, Versao);
end;

function TefHubInstalado(var Nome: String; var Versao: String): Boolean;
begin
  Result := ProdutoElginInstalado(ChaveTefHub, MarcaTefHub, Nome, Versao);
end;

function E1ConnectInstalado(var Nome: String; var Versao: String): Boolean;
begin
  Result := ProdutoElginInstalado(ChaveE1Connect, MarcaE1Connect, Nome, Versao);
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
    Mensagem := 'Este terminal não é 64 bits. O pacote do agente TEF é win-x64 e não roda aqui.';
    Log('[TefAgent] BLOQUEIO: ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbCriticalError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;

  Livre := EspacoLivreMB();
  if (Livre > 0) and (Livre < DiscoMinimoMB) then
  begin
    Mensagem := 'Espaço insuficiente em ' + ExpandConstant('{autopf}') + ': ' + IntToStr(Livre) +
                ' MB livres, mínimo de ' + IntToStr(DiscoMinimoMB) + ' MB.' + #13#10 +
                'O agente é publicado self-contained (traz o runtime .NET embutido).';
    Log('[TefAgent] BLOQUEIO: ' + Mensagem);
    SuppressibleMsgBox(Mensagem, mbCriticalError, MB_OK, IDOK);
    Result := False;
  end;
end;

{ Monta (uma vez) o texto de pré-requisitos exibido na tela e gravado no log. }
function TextoDasChecagens(): String;
var
  Linhas: String;
  NomeTefHub, VersaoTefHub, NomeE1Connect, VersaoE1Connect: String;
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

  if ServicoJaRegistrado() then
    Linhas := Linhas + 'Serviço ' + '{#ServicoNome}' + ': já registrado — será PARADO e a ' +
              'instalação anterior removida antes de continuar (reinstalação).' + #13#10
  else
    Linhas := Linhas + 'Serviço ' + '{#ServicoNome}' + ': ausente — será registrado com início ' +
              'automático.' + #13#10;

  if BancoLocalExiste() then
    Linhas := Linhas + 'Banco local: este terminal já operou — o banco e a configuração atual ' +
              'serão PRESERVADOS.' + #13#10
  else
    Linhas := Linhas + 'Banco local: ausente — será criado no primeiro início do serviço.' + #13#10;

  { Duas perguntas distintas, de propósito em linhas distintas: "está instalado?" responde o
    registro, aqui; "está no ar e é o canal certo?" só o botão "Testar conexão" responde. Juntar
    as duas numa linha só produziria um "OK" que o terminal não sustenta. }
  { "não localizado" só aparece aqui se o produto sumir entre o InitializeSetup (que bloqueia a
    ausência) e esta tela — o texto não promete que a instalação continua sem ele. }
  if TefHubInstalado(NomeTefHub, VersaoTefHub) then
    Linhas := Linhas + 'Elgin TEF HUB: ' + NomeTefHub + ' — instalado neste terminal.' + #13#10
  else
    Linhas := Linhas + 'Elgin TEF HUB: não localizado.' + #13#10;

  if E1ConnectInstalado(NomeE1Connect, VersaoE1Connect) then
    Linhas := Linhas + 'Elgin E1_Connect: ' + NomeE1Connect + ' — instalado neste terminal.' + #13#10
  else
    Linhas := Linhas + 'Elgin E1_Connect: não localizado.' + #13#10;

  Linhas := Linhas + 'Elgin TEF Web: verificado na próxima página, pelo botão "Testar conexão" ' +
            '(o produto é instalado pelo técnico da Elgin, não por este instalador).' + #13#10;

  ResultadoDasChecagens := Linhas;
  Log('[TefAgent] Pré-requisitos:' + #13#10 + Linhas);
  Result := Linhas;
end;

{ Contrato do PrepareToInstall: string vazia libera a instalação. As checagens já rodaram; aqui
  elas só são reavaliadas para constar do log da instalação silenciosa, que não tem a tela. }
function ChecagensDePreparacao(): String;
begin
  TextoDasChecagens();
  Result := '';
end;
