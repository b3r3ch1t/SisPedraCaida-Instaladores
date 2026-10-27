{ ============================================================================================
   pages.iss — páginas customizadas do wizard e parametrização (PRD-TEFINST-06 §4)

   É a etapa que CUMPRE O PEDIDO: hoje instalar o agente exige copiar binários à mão, editar o
   appsettings.json dentro de Program Files e montar um `sc create` correto. Aqui isso vira duplo
   clique.

   ⚠️ Página customizada NÃO RODA em modo silencioso. Toda validação que vive aqui tem caminho
   equivalente na leitura dos parâmetros (ValoresIniciais + ValidarParametrosSilenciosos), senão o
   silencioso aceitaria o que o interativo recusa — e a divergência só apareceria semanas depois,
   em campo.
   ============================================================================================ }

var
  PaginaPreRequisitos: TOutputMsgMemoWizardPage;
  PaginaTerminal: TInputQueryWizardPage;
  PaginaConexao: TInputQueryWizardPage;
  BotaoTestar: TNewButton;
  RotuloTeste: TNewStaticText;

  { Valores efetivos, já resolvidos a partir de parâmetros + tela. São a fonte única consumida
    pelo provisionamento e pelo resumo da tela "Pronto para instalar". }
  ValorTerminalId: String;
  ValorStoreId: String;
  ValorName: String;
  ValorApiUrl: String;
  ValorTefWebUrl: String;
  ValorAmbiente: String;
  AvisoHttpConfirmado: Boolean;

  { Conteúdo do agent.settings.json já gravado neste terminal (vazio quando não há). Lido uma vez. }
  ConfiguracaoGravada: String;
  ConfiguracaoGravadaLida: Boolean;

{ Lê um parâmetro /NOME=valor da linha de comando, com default. }
function Parametro(Nome, Padrao: String): String;
begin
  Result := ExpandConstant('{param:' + Nome + '|' + Padrao + '}');
end;

{ ⚠️ O log do Inno registra a linha de comando COMPLETA e não existe equivalente do
  MsiHiddenProperties. /CONFIGFILE= aponta um arquivo texto com pares Chave=valor — é o artefato do
  rollout (um por caixa) e o formato previsto para quando o TEF passar a exigir credencial. }
function LerDoArquivoDeConfiguracao(Caminho, Chave: String): String;
var
  Linhas: TArrayOfString;
  i, Igual: Integer;
  Nome, Valor: String;
begin
  Result := '';

  if (Caminho = '') or (not FileExists(Caminho)) then
    Exit;

  if not LoadStringsFromFile(Caminho, Linhas) then
  begin
    Log('[TefAgent] Não foi possível ler o arquivo de configuração: ' + Caminho);
    Exit;
  end;

  for i := 0 to GetArrayLength(Linhas) - 1 do
  begin
    Igual := Pos('=', Linhas[i]);
    if Igual > 1 then
    begin
      Nome := Trim(Copy(Linhas[i], 1, Igual - 1));
      Valor := Trim(Copy(Linhas[i], Igual + 1, Length(Linhas[i])));

      if CompareText(Nome, Chave) = 0 then
      begin
        Result := Valor;
        Exit;
      end;
    end;
  end;
end;

{ Lê um valor do arquivo de resposta e, na ausência, do parâmetro de linha de comando.
  Precedência: /CONFIGFILE → parâmetro explícito → default (a mesma do Setup.exe). }
function ValorInicial(ChaveDoArquivo, NomeDoParametro, Padrao: String): String;
var
  Arquivo, Valor: String;
begin
  Arquivo := Parametro('CONFIGFILE', '');

  Valor := LerDoArquivoDeConfiguracao(Arquivo, ChaveDoArquivo);
  if Valor = '' then
    Valor := Parametro(NomeDoParametro, '');

  // O padrão entra aqui, e não dentro da constante param do Inno: ele pode vir da configuração
  // gravada no disco, e uma chave ou uma barra vertical no valor quebraria a expansão.
  if Valor = '' then
    Valor := Padrao;

  Result := Valor;
end;

{ Normaliza uma URL: completa o esquema quando ausente e remove barras finais.
  Recusa valor vazio — endereço de API vazio instala um terminal que nunca registra. }
function NormalizarUrl(Entrada, Rotulo: String; var Normalizada: String; var Erro: String): Boolean;
var
  Valor, Resto: String;
begin
  Result := False;
  Normalizada := '';
  Erro := '';
  Valor := Trim(Entrada);

  if Valor = '' then
  begin
    Erro := 'Informe o ' + Rotulo + '.';
    Exit;
  end;

  if Pos('://', Valor) = 0 then
    Valor := 'http://' + Valor;

  while (Length(Valor) > 0) and (Valor[Length(Valor)] = '/') do
    Valor := Copy(Valor, 1, Length(Valor) - 1);

  Resto := Copy(Valor, Pos('://', Valor) + 3, Length(Valor));
  if Trim(Resto) = '' then
  begin
    Erro := 'O ' + Rotulo + ' não tem servidor (recebido apenas o esquema).';
    Exit;
  end;

  Normalizada := Valor;
  Result := True;
end;

{ Normaliza a URL do Elgin TEF Web, que é gravada COM barra final — a mesma forma do
  appsettings.json do agente. }
function NormalizarUrlTefWeb(Entrada: String; var Normalizada: String; var Erro: String): Boolean;
begin
  Result := NormalizarUrl(Entrada, 'endereço do Elgin TEF Web', Normalizada, Erro);

  if Result then
    Normalizada := Normalizada + '/';
end;

{ Lê um valor de texto de um corpo JSON, por nome de propriedade. Busca literal de propósito: o
  Pascal Script não tem parser de JSON, e o que se precisa daqui são poucos campos de texto (os de
  diagnóstico da sonda e os da configuração já gravada). }
function ValorJson(Corpo, Nome: String): String;
var
  Inicio, Fim: Integer;
  Resto: String;
begin
  Result := '';

  { A busca é na cópia em minúsculas para ignorar a caixa do nome, mas o VALOR é recortado do corpo
    original — recortá-lo da cópia devolveria o texto todo em minúsculas. }
  Inicio := Pos('"' + Lowercase(Nome) + '"', Lowercase(Corpo));
  if Inicio = 0 then
    Exit;

  Resto := Copy(Corpo, Inicio + Length(Nome) + 2, Length(Corpo));

  { Depois do nome tem de vir ':' e então uma string entre aspas. Valor numérico ou objeto não
    interessa — e seguir procurando a próxima aspa devolveria o valor de OUTRA propriedade, que é
    pior que não achar nada. }
  Inicio := Pos(':', Resto);
  if Inicio = 0 then
    Exit;

  Resto := Trim(Copy(Resto, Inicio + 1, Length(Resto)));
  if (Length(Resto) = 0) or (Resto[1] <> '"') then
    Exit;

  Resto := Copy(Resto, 2, Length(Resto));

  Fim := Pos('"', Resto);
  if Fim = 0 then
    Exit;

  Result := Copy(Resto, 1, Fim - 1);
end;

{ Conteúdo do agent.settings.json que um instalação anterior deixou em %PROGRAMDATA% (vazio quando
  o terminal nunca foi configurado). Lido uma única vez, no início do instalador. }
function ConteudoDaConfiguracaoGravada(): String;
var
  Linhas: TArrayOfString;
  i: Integer;
begin
  if not ConfiguracaoGravadaLida then
  begin
    ConfiguracaoGravadaLida := True;
    ConfiguracaoGravada := '';

    if LoadStringsFromFile(ExpandConstant('{#PastaDados}\config\agent.settings.json'), Linhas) then
      for i := 0 to GetArrayLength(Linhas) - 1 do
        ConfiguracaoGravada := ConfiguracaoGravada + Linhas[i] + #10;
  end;

  Result := ConfiguracaoGravada;
end;

{ Lê um campo de texto de uma seção da configuração já gravada ("Agent", "Api", "TefWeb").

  ⚠️ A busca começa NA SEÇÃO porque "BaseUrl" existe em duas delas (Api e TefWeb): procurar no
  arquivo inteiro devolveria sempre a primeira. }
function ValorGravado(Secao, Nome: String): String;
var
  Corpo: String;
  Inicio: Integer;
begin
  Result := '';
  Corpo := ConteudoDaConfiguracaoGravada();

  if Corpo = '' then
    Exit;

  Inicio := Pos('"' + Lowercase(Secao) + '"', Lowercase(Corpo));
  if Inicio = 0 then
    Exit;

  Result := Trim(ValorJson(Copy(Corpo, Inicio + Length(Secao) + 2, Length(Corpo)), Nome));
end;

{ O gravado no terminal, ou o padrão do pacote quando não há nada gravado. }
function GravadoOuPadrao(Secao, Nome, Padrao: String): String;
begin
  Result := ValorGravado(Secao, Nome);

  if Result = '' then
    Result := Padrao;
end;

{ Resolve os valores iniciais. Precedência: /CONFIGFILE → parâmetro da linha de comando →
  configuração já gravada neste terminal → padrão do pacote.

  ⚠️ Ler a configuração gravada é o que torna seguro remover a instalação anterior antes de
  instalar (RemoverInstalacaoAnterior): o serviço sai junto, e se o wizard abrisse com a
  identificação em branco a reinstalação ADIARIA o provisionamento e o caixa ficaria sem serviço.

  ⚠️ O nome amigável NÃO é lido do arquivo: ele pode ter acento, e a leitura aqui não garante a
  codificação — gravá-lo de volta corrompido seria pior que deixá-lo em branco, que PRESERVA o valor
  gravado (parâmetro ausente não sobrescreve no Setup.exe). }
procedure ValoresIniciais();
begin
  ValorTerminalId := ValorInicial('TerminalId', 'TERMINALID', ValorGravado('Agent', 'TerminalId'));
  ValorStoreId := ValorInicial('StoreId', 'STOREID', ValorGravado('Agent', 'StoreId'));
  ValorName := ValorInicial('Name', 'NAME', '');
  ValorApiUrl := ValorInicial('ApiBaseUrl', 'APIURL',
    GravadoOuPadrao('Api', 'BaseUrl', '{#ApiUrlPadrao}'));
  ValorTefWebUrl := ValorInicial('TefWebBaseUrl', 'TEFWEBURL',
    GravadoOuPadrao('TefWeb', 'BaseUrl', '{#TefWebUrlPadrao}'));
  ValorAmbiente := ValorInicial('Environment', 'ENVIRONMENTNAME', '{#AmbientePadrao}');

  AvisoHttpConfirmado := False;
end;

function NomeInformado(): String;
begin
  if Trim(ValorName) = '' then
    Result := '(não informado — mantém o já gravado ou, sem ele, o painel exibe a identificação)'
  else
    Result := ValorName;
end;

{ ------------------------------------------------------------------------------------------
  Sonda de conexão da página de conexão.

  ⚠️ Por que NÃO chama `Setup.exe --validate-connection` aqui. O modo existe e é o que o editor
  pós-instalação usa, mas o agente é publicado SELF-CONTAINED: rodá-lo antes da cópia exigiria
  extrair o layout inteiro (>100 MB) para a pasta temporária só para clicar num botão — e o
  operador pagaria a extração duas vezes em toda instalação. A sonda daqui faz as MESMAS
  requisições e usa a MESMA classificação do HttpConnectionProbe.cs, inclusive nos códigos:
  0 Ok · 11 CredencialRecusada · 12 NaoAlcancavel · 13 CertificadoInvalido · 14 RespostaInesperada ·
  15 CanalDivergente · 16 TefWebIndisponivel. Alterar um lado exige alterar o outro.
  ------------------------------------------------------------------------------------------ }

{ Executa um GET e devolve o status HTTP (0 quando não houve resposta). }
function Obter(Url: String; var Corpo: String): Integer;
var
  Requisicao: Variant;
begin
  Corpo := '';

  try
    Requisicao := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Requisicao.SetTimeouts(5000, 5000, 5000, 5000);
    Requisicao.Open('GET', Url, False);
    Requisicao.SetRequestHeader('Accept', 'application/json');
    Requisicao.Send('');
    Corpo := Requisicao.ResponseText;
    Result := Requisicao.Status;
  except
    { WinHttp lança em falha de transporte e em falha de TLS. Distinguir com precisão exigiria ler
      o código nativo; a mensagem do chamador cita as duas causas para não induzir o operador ao
      erro. }
    Result := 0;
  end;
end;

{ Classifica um status HTTP como o ProbeStatusParser faz do lado do Setup.exe. }
function ClassificarStatus(Status: Integer): Integer;
begin
  if Status = 0 then
    Result := 12
  else if (Status >= 200) and (Status < 300) then
    Result := 0
  else if (Status = 401) or (Status = 403) then
    Result := 11
  else
    Result := 14;
end;

{ Sonda a API: responde? é o canal certo? }
function SondarApi(Url: String; var Mensagem: String): Integer;
var
  Corpo, Ambiente, Versao, Anterior: String;
  Status, Tentativa: Integer;
begin
  Status := Obter(Url + '/api/environment', Corpo);
  Result := ClassificarStatus(Status);

  if Result <> 0 then
  begin
    if Result = 12 then
      Mensagem := 'Não foi possível alcançar ' + Url + '. Verifique rede, endereço, porta e ' +
                  'firewall; se o endereço for https, verifique também o certificado do servidor.'
    else if Result = 11 then
      Mensagem := 'A API recusou a credencial (HTTP ' + IntToStr(Status) + ').'
    else
      Mensagem := 'O host respondeu HTTP ' + IntToStr(Status) + ', mas não como a API do ' +
                  'SisPedraCaida — confira porta, caminho e se há proxy no meio.';
    Exit;
  end;

  Ambiente := ValorJson(Corpo, 'environment');
  if Ambiente = '' then
    Ambiente := ValorJson(Corpo, 'ambiente');
  if Ambiente = '' then
    Ambiente := '(não informado)';

  { Três leituras da versão: versão alternando entre respostas é o sintoma de alias de serviço
    duplicado — "a porta respondeu" não prova que o canal é o certo. }
  Anterior := '';
  for Tentativa := 1 to 3 do
  begin
    Status := Obter(Url + '/api/v1/versao', Corpo);
    if ClassificarStatus(Status) <> 0 then
    begin
      Mensagem := 'A API respondeu em /api/environment mas não em /api/v1/versao (HTTP ' +
                  IntToStr(Status) + ').';
      Result := 14;
      Exit;
    end;

    Versao := ValorJson(Corpo, 'versao');

    if (Tentativa > 1) and (Versao <> Anterior) then
    begin
      Mensagem := 'O endereço ' + Url + ' respondeu versões diferentes na mesma sequência de ' +
                  'leituras (' + Anterior + ' e ' + Versao + '): há mais de um canal atendendo por ' +
                  'esse nome. Aponte o terminal para o endereço do canal correto antes de operar.';
      Result := 15;
      Exit;
    end;

    Anterior := Versao;
  end;

  if Anterior = '' then
    Anterior := '(não informada)';

  Mensagem := 'A API em ' + Url + ' respondeu (ambiente ' + Ambiente + ', versão ' + Anterior + ').';
  Result := 0;
end;

{ Sonda o Elgin TEF Web local — o mesmo recurso que o TefWebService consulta como sinal de vida.

  Regra única com o agente, a sonda do Setup.exe e o painel da bandeja (ElginTefSinalDeVida, no
  Domain): status abaixo de 500 é o serviço respondendo — o GET cai numa rota POST, e o E1_Connect
  05.09.00 devolve 405. Sem resposta (0) ou 5xx é fora do ar. Alterar um lado exige alterar o outro. }
function SondarTefWeb(Url: String; var Mensagem: String): Integer;
var
  Corpo: String;
  Status: Integer;
begin
  Status := Obter(Url + 'venda', Corpo);

  if (Status = 0) or (Status >= 500) then
  begin
    if Status = 0 then
      Mensagem := 'O Elgin TEF Web em ' + Url + ' não respondeu.'
    else
      Mensagem := 'O Elgin TEF Web em ' + Url + ' respondeu com erro interno (HTTP ' + IntToStr(Status) + ').';

    Mensagem := Mensagem + ' Confira se o produto está instalado e em execução nesta máquina e qual ' +
                'porta ele atende. Isto NÃO impede a instalação: o endereço é editável depois, pelo ' +
                'atalho "Configurar o agente TEF".';
    Result := 16;
    Exit;
  end;

  Mensagem := 'O Elgin TEF Web em ' + Url + ' respondeu (HTTP ' + IntToStr(Status) + ').';
  Result := 0;
end;

{ Clique do botão "Testar conexão". Falhar aqui NÃO bloqueia a instalação (terminal sem rede, ou com
  o Elgin ainda por instalar, é cenário legítimo), mas o desfecho fica visível antes de instalar. }
procedure TestarConexao(Sender: TObject);
var
  Mensagem, MensagemTef, UrlApi, UrlTef, Erro, Texto: String;
  Codigo: Integer;
begin
  RotuloTeste.Caption := 'Testando...';
  BotaoTestar.Enabled := False;
  WizardForm.Update();

  try
    if not NormalizarUrl(PaginaConexao.Values[0], 'endereço da API', UrlApi, Erro) then
    begin
      RotuloTeste.Caption := Erro;
      Exit;
    end;

    Codigo := SondarApi(UrlApi, Mensagem);
    Texto := Mensagem;
    Log('[TefAgent] Teste da API: código ' + IntToStr(Codigo) + ' — ' + Mensagem);

    if (Codigo = 0) and NormalizarUrlTefWeb(PaginaConexao.Values[1], UrlTef, Erro) then
    begin
      Codigo := SondarTefWeb(UrlTef, MensagemTef);
      Texto := Texto + #13#10 + MensagemTef;
      Log('[TefAgent] Teste do Elgin TEF Web: código ' + IntToStr(Codigo) + ' — ' + MensagemTef);
    end;

    RotuloTeste.Caption := Texto;
  finally
    BotaoTestar.Enabled := True;
  end;
end;

procedure CriarPaginasDoWizard();
begin
  { Os valores já foram resolvidos em InitializeSetup (que roda antes, inclusive no silencioso). }
  PaginaPreRequisitos := CreateOutputMsgMemoPage(
    wpLicense,
    'Pré-requisitos do terminal',
    'Verificação do que esta máquina precisa ter',
    'Resultado das verificações. Um aviso não impede a instalação; um bloqueio já teria ' +
    'encerrado o instalador com o motivo.',
    TextoDasChecagens());

  PaginaTerminal := CreateInputQueryPage(
    PaginaPreRequisitos.ID,
    'Identificação do terminal',
    'Como este caixa aparece no sistema',
    'A identificação do terminal é a IDENTIDADE deste caixa no painel: trocá-la depois cria um ' +
    'terminal novo em vez de renomear este. Combine o valor com a operação antes de instalar.');

  PaginaTerminal.Add('Identificação do terminal (ex.: CAIXA-01):', False);
  PaginaTerminal.Add('Loja (ex.: LOJA-001):', False);
  PaginaTerminal.Add('Nome amigável (opcional):', False);
  PaginaTerminal.Values[0] := ValorTerminalId;
  PaginaTerminal.Values[1] := ValorStoreId;
  PaginaTerminal.Values[2] := ValorName;

  PaginaConexao := CreateInputQueryPage(
    PaginaTerminal.ID,
    'Conexão',
    'Com quem este terminal conversa',
    'A API central e o Elgin TEF Web local (que controla o pinpad). Os dois endereços podem ser ' +
    'alterados depois, pelo atalho "Configurar o agente TEF", sem reinstalar.');

  PaginaConexao.Add('Endereço da API:', False);
  PaginaConexao.Add('Endereço do Elgin TEF Web:', False);
  PaginaConexao.Values[0] := ValorApiUrl;
  PaginaConexao.Values[1] := ValorTefWebUrl;

  BotaoTestar := TNewButton.Create(PaginaConexao);
  BotaoTestar.Parent := PaginaConexao.Surface;
  BotaoTestar.Caption := 'Testar conexão';
  BotaoTestar.Width := ScaleX(120);
  BotaoTestar.Height := ScaleY(25);
  BotaoTestar.Left := PaginaConexao.SurfaceWidth - BotaoTestar.Width;
  BotaoTestar.Top := PaginaConexao.Edits[1].Top + PaginaConexao.Edits[1].Height + ScaleY(12);
  BotaoTestar.OnClick := @TestarConexao;

  RotuloTeste := TNewStaticText.Create(PaginaConexao);
  RotuloTeste.Parent := PaginaConexao.Surface;
  RotuloTeste.Left := 0;
  RotuloTeste.Top := BotaoTestar.Top + BotaoTestar.Height + ScaleY(10);
  RotuloTeste.Width := PaginaConexao.SurfaceWidth;
  RotuloTeste.Height := ScaleY(60);
  RotuloTeste.WordWrap := True;
  RotuloTeste.Caption := 'Recomendado: teste a conexão antes de instalar. O teste também diz QUAL ' +
                         'canal responde no endereço informado — já houve endereço respondendo ora ' +
                         'por um ambiente, ora por outro.';

  { Não há página de PIX: todo terminal aceita PIX, e o Setup.exe grava sempre PixEnabled=true. }
end;

{ Indica se a identificação mínima do terminal foi informada.

  Espelha StationConfiguration.TemIdentificacao do Setup.exe: é o PAR (terminal + loja) que conta,
  porque é ele que o provisionador exige. Meio preenchido não serve, e tratar os dois campos como
  um só evita a instalação que passa pelo wizard e morre no provisionamento. }
function IdentificacaoInformada(): Boolean;
begin
  Result := (Trim(ValorTerminalId) <> '') and (Trim(ValorStoreId) <> '');
end;

{ Confirmação de instalação sem identificação (modo interativo).

  O texto diz o que NÃO vai acontecer — serviço não registrado, caixa fora do painel, cartão não
  processa — porque "instalado" sem essa ressalva é exatamente o terminal mudo que o operador
  descobre no primeiro cartão do dia. E diz, em duas linhas, como concluir depois. }
function ConfirmarInstalacaoSemIdentificacao(): Boolean;
begin
  Result := MsgBox(
    'A identificação do terminal e/ou a loja não foram informadas.' + #13#10#13#10 +
    'A instalação PODE continuar: os arquivos são copiados e os atalhos criados. Mas o terminal ' +
    'NÃO entra em operação agora — o serviço do Windows não é registrado, este caixa não aparece ' +
    'no painel e não processa cartão.' + #13#10#13#10 +
    'Para concluir depois, no menu Iniciar, nesta ordem:' + #13#10 +
    '   1. "Configurar o agente TEF" — informe a identificação e a loja;' + #13#10 +
    '   2. "Concluir a instalação do agente TEF" — registra e inicia o serviço.' + #13#10#13#10 +
    'Continuar sem a identificação?',
    mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
end;

{ Validação do Avançar. Vale tanto para o interativo quanto — pela chamada equivalente em
  ValidarParametrosSilenciosos — para o modo silencioso. }
function ValidarPagina(CurPageID: Integer): Boolean;
var
  Url, Erro: String;
begin
  Result := True;

  if (PaginaTerminal <> nil) and (CurPageID = PaginaTerminal.ID) then
  begin
    { Identificação em branco AVISA, não impede. Recusar o Avançar transformava "ainda não decidi o
      código deste caixa" em "não dá para instalar hoje" — e o técnico que está na loja com a
      máquina aberta não tem como resolver isso sozinho. O preço de continuar está escrito na
      confirmação, e o default do botão é Não. }
    if (Trim(PaginaTerminal.Values[0]) = '') or (Trim(PaginaTerminal.Values[1]) = '') then
    begin
      if not ConfirmarInstalacaoSemIdentificacao() then
      begin
        Result := False;
        Exit;
      end;
    end;

    ValorTerminalId := Trim(PaginaTerminal.Values[0]);
    ValorStoreId := Trim(PaginaTerminal.Values[1]);
    ValorName := Trim(PaginaTerminal.Values[2]);
  end;

  if (PaginaConexao <> nil) and (CurPageID = PaginaConexao.ID) then
  begin
    if not NormalizarUrl(PaginaConexao.Values[0], 'endereço da API', Url, Erro) then
    begin
      MsgBox(Erro, mbError, MB_OK);
      Result := False;
      Exit;
    end;

    { Aviso de canal sem TLS: o tráfego do terminal vai em claro na rede. O instalador não esconde
      isso — o operador confirma cientemente. }
    if (Pos('https://', Lowercase(Url)) <> 1) and (not AvisoHttpConfirmado) then
    begin
      if SuppressibleMsgBox(
           'O endereço da API informado não usa TLS (https). O tráfego entre este terminal e a API ' +
           'vai em claro na rede.' + #13#10#13#10 +
           'Aceitável apenas em rede interna, com prazo para TLS. Continuar?',
           mbConfirmation, MB_YESNO, IDYES) <> IDYES then
      begin
        Result := False;
        Exit;
      end;

      AvisoHttpConfirmado := True;
      Log('[TefAgent] Aviso de canal sem TLS exibido e confirmado pelo operador.');
    end;

    ValorApiUrl := Url;

    if not NormalizarUrlTefWeb(PaginaConexao.Values[1], Url, Erro) then
    begin
      MsgBox(Erro, mbError, MB_OK);
      Result := False;
      Exit;
    end;

    ValorTefWebUrl := Url;
  end;
end;

{ Equivalente silencioso da validação das páginas: em /VERYSILENT nenhuma página customizada roda.
  Sem isto, o silencioso instalaria um terminal sem identificação ou apontado para lugar nenhum.

  ⚠️ O aviso de canal sem TLS NÃO vira MsgBox aqui: em /VERYSILENT sem /SUPPRESSMSGBOXES uma caixa
  de mensagem trava a instalação INVISIVELMENTE até alguém logar na máquina. Fica no log. }
function ValidarParametrosSilenciosos(): Boolean;
var
  Normalizada, Erro: String;
begin
  Result := False;

  { Identificação ausente NÃO bloqueia mais o rollout: ela só adia o provisionamento, e a
    instalação segue copiando os arquivos. Fica no LOG, nunca em MsgBox — em /VERYSILENT sem
    /SUPPRESSMSGBOXES uma caixa de mensagem trava a instalação INVISIVELMENTE até alguém logar na
    máquina, que é o mesmo motivo do aviso de TLS logo abaixo.

    ⚠️ A diferença para as URLs: identificação em branco é uma decisão adiada (o operador ainda não
    definiu o código do caixa), enquanto URL malformada é ERRO DE DIGITAÇÃO — adiar a segunda só
    produziria um terminal apontado para lugar nenhum, que ninguém vai reconferir. }
  if not IdentificacaoInformada() then
  begin
    Log('[TefAgent] AVISO: sem identificação (/TERMINALID= e /STOREID=, ou TerminalId/StoreId no ' +
        '/CONFIGFILE=). Os arquivos serão instalados, mas o serviço NÃO será registrado e o ' +
        'terminal não entrará em operação até ser configurado e concluído nesta máquina.');
  end;

  if not NormalizarUrl(ValorApiUrl, 'endereço da API (/APIURL=)', Normalizada, Erro) then
  begin
    Log('[TefAgent] BLOQUEIO: ' + Erro);
    SuppressibleMsgBox(Erro, mbCriticalError, MB_OK, IDOK);
    Exit;
  end;

  ValorApiUrl := Normalizada;

  if not NormalizarUrlTefWeb(ValorTefWebUrl, Normalizada, Erro) then
  begin
    Log('[TefAgent] BLOQUEIO: ' + Erro);
    SuppressibleMsgBox(Erro, mbCriticalError, MB_OK, IDOK);
    Exit;
  end;

  ValorTefWebUrl := Normalizada;

  if Pos('https://', Lowercase(ValorApiUrl)) <> 1 then
    Log('[TefAgent] AVISO: o endereço ' + ValorApiUrl + ' não usa TLS; o tráfego deste terminal ' +
        'vai em claro na rede.');

  Result := True;
end;
