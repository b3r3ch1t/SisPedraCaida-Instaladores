{ ============================================================================================
   pages.iss — páginas customizadas do wizard e parametrização (etapa 03)

   É a etapa que CUMPRE O PEDIDO: hoje a instalação exige PowerShell elevado e uma linha de
   comando com quatro parâmetros; aqui ela vira duplo clique.

   ⚠️ Página customizada NÃO RODA em modo silencioso. Toda validação que vive aqui tem caminho
   equivalente na leitura dos parâmetros (ValoresIniciais), senão o silencioso aceitaria uma URL
   que o interativo recusaria — e a divergência só apareceria semanas depois, em campo.
   ============================================================================================ }

var
  PaginaPreRequisitos: TOutputMsgMemoWizardPage;
  PaginaConexao: TInputQueryWizardPage;
  PaginaIdentidade: TInputQueryWizardPage;
  BotaoTestar: TNewButton;
  RotuloTeste: TNewStaticText;

  { Valores efetivos, já resolvidos a partir de parâmetros + tela. São a fonte única consumida
    pelo provisionamento e pelo resumo da tela "Pronto para instalar". }
  ValorUrl: String;
  ValorChave: String;
  ValorAmbiente: String;
  ValorManifestUrl: String;
  ValorOtlp: String;
  AvisoHttpConfirmado: Boolean;

  { Loopback do Helper (épico gestao-impressoras, PRD-GIMP-BE-06): é por ele que o front-adm descobre
    "qual estação é esta máquina" (GET http://127.0.0.1:8183/identidade, SEM segredo — decisão de 21/10/2026:
    a proteção é a lista exata de origens). A tela pede só as origens, pré-preenchidas com OrigensPadrao. Os
    segredos (RouteSecret e o SegredoIdentidade legado, ambos opcionais e só pelo /CONFIGFILE) e a chave vão ao
    Setup.exe por ARQUIVO de resposta temporário, nunca pela linha de comando (#78b) — ver
    GravarArquivoDeResposta em provisioning.iss. }
  ValorOrigens: String;
  OrigensJaGravadas: String;
  ValorSegredoIdentidade: String;
  ValorRouteSecret: String;
  ValorLoopbackEnabled: String;

{ Lê um parâmetro /NOME=valor da linha de comando, com default. }
function Parametro(Nome, Padrao: String): String;
begin
  Result := ExpandConstant('{param:' + Nome + '|' + Padrao + '}');
end;

{ ⚠️ A chave de API não deve ir na linha de comando: o log do Inno registra a linha COMPLETA e não
  existe equivalente do MsiHiddenProperties. /CONFIGFILE= aponta um arquivo texto com pares
  Chave=valor (ApiKey, DashboardUrl, ManifestUrl e, do épico gestao-impressoras, LoopbackPrintSegredoIdentidade,
  LoopbackPrintOrigensPermitidas, LoopbackPrintRouteSecret, LoopbackPrintEnabled), com ACL restrita e
  apagado pela TI após o rollout. }
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
    Log('[PrintMonitor] Não foi possível ler o arquivo de configuração: ' + Caminho);
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

{ ------------------------------------------------------------------------------------------
  Loopback do Helper — identidade da estação para o front-adm (PRD-GIMP-BE-06).

  As regras abaixo ESPELHAM SetupParameters.Validar / NormalizarOrigem (PrintMonitor.Setup): o
  Setup.exe confere de novo e sai com código 3 se divergir — mas aí os arquivos já foram copiados e
  o tratamento de falha desprovisiona. Alterar um lado exige alterar o outro.
  ------------------------------------------------------------------------------------------ }

const
  ChaveAmbienteMaquina = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  VarLoopbackOrigemPrefixo = 'PrintMonitor__LoopbackPrint__OrigensPermitidas__';
  TamanhoMinimoSegredoLoopback = 16;
  OrigensPadraoDoPacote = '{#OrigensPadrao}';

  { Variáveis de máquina que o upgrade relê (PRD-PMTRAY-03). Espelham StationEnvironmentVariables
    (guarda em InstaladorUpgradeGuardTests). }
  VarDashboardUrl = 'PrintMonitor__Reporting__DashboardUrl';
  VarChaveApi = 'PrintMonitor__Reporting__ApiKey';
  VarAmbiente = 'DOTNET_ENVIRONMENT';

var
  { O endereço inicial veio do gravado na estação (e não de parâmetro): inválido, cai no padrão do
    pacote em vez de recusar a instalação — ver ValidarParametrosSilenciosos. }
  UrlVeioDaEstacao: Boolean;

{ Valor de uma variável de ambiente de MÁQUINA ('' quando ausente). Lido do registro, e não do
  ambiente do processo: o instalador herda o ambiente de quem o abriu, não o da máquina. }
function VariavelDeMaquina(Nome: String): String;
begin
  if not RegQueryStringValue(HKLM, ChaveAmbienteMaquina, Nome, Result) then
    Result := '';
  Result := Trim(Result);
end;

{ Endereço da API gravado nesta estação ('' numa estação nova). Normalizado depois, junto com o
  informado (ValidarParametrosSilenciosos), o que também migra a grafia kebab antiga. }
function UrlGravada(): String;
begin
  Result := VariavelDeMaquina(VarDashboardUrl);
  UrlVeioDaEstacao := Result <> '';
end;

{ Origens já gravadas nesta estação (variáveis de máquina), separadas por vírgula. Pré-preenchem o
  wizard numa reinstalação (vencem OrigensPadraoDoPacote); e, sem nada informado, o Setup.exe preserva o
  gravado. }
function OrigensGravadas(): String;
var
  i: Integer;
  Valor: String;
begin
  Result := '';

  for i := 0 to 63 do
  begin
    if not RegQueryStringValue(HKLM, ChaveAmbienteMaquina, VarLoopbackOrigemPrefixo + IntToStr(i), Valor) then
      Break;

    if Result <> '' then
      Result := Result + ',';
    Result := Result + Valor;
  end;
end;

{ Normaliza uma origem do navegador (esquema://servidor[:porta], minúsculas, sem barra final). Recusa
  caminho, consulta, credencial e curinga: a comparação do Helper é EXATA. }
function NormalizarOrigem(Entrada: String; var Normalizada: String): Boolean;
var
  Valor, Resto: String;
begin
  Result := False;
  Normalizada := '';
  Valor := Lowercase(Trim(Entrada));

  while (Length(Valor) > 0) and (Valor[Length(Valor)] = '/') do
    Valor := Copy(Valor, 1, Length(Valor) - 1);

  if (Valor = '') or (Pos('*', Valor) > 0) then
    Exit;

  if (Pos('http://', Valor) <> 1) and (Pos('https://', Valor) <> 1) then
    Exit;

  Resto := Copy(Valor, Pos('://', Valor) + 3, Length(Valor));
  if (Resto = '') or (Pos('/', Resto) > 0) or (Pos('?', Resto) > 0) or (Pos('#', Resto) > 0) or
     (Pos('@', Resto) > 0) then
    Exit;

  Normalizada := Valor;
  Result := True;
end;

{ Normaliza uma lista de origens separadas por vírgula, ponto e vírgula ou espaço. }
function NormalizarListaDeOrigens(Entrada: String; var Normalizada: String; var Erro: String): Boolean;
var
  i: Integer;
  Atual, Origem: String;
  C: Char;
begin
  Result := True;
  Normalizada := '';
  Erro := '';
  Atual := '';

  for i := 1 to Length(Entrada) + 1 do
  begin
    if i <= Length(Entrada) then
      C := Entrada[i]
    else
      C := ',';

    if (C = ',') or (C = ';') or (C = ' ') or (C = #9) then
    begin
      if Trim(Atual) <> '' then
      begin
        if not NormalizarOrigem(Atual, Origem) then
        begin
          Erro := 'Origem inválida: "' + Trim(Atual) + '". Informe a origem exata do front-adm (esquema, ' +
                  'servidor e porta, sem caminho e sem curinga), ex.: https://admin.exemplo.com.br';
          Result := False;
          Exit;
        end;

        if Normalizada <> '' then
          Normalizada := Normalizada + ',';
        Normalizada := Normalizada + Origem;
      end;

      Atual := '';
    end
    else
      Atual := Atual + C;
  end;
end;

{ Segredo de rota do loopback: compõe o caminho da URL, então só caracteres seguros e tamanho mínimo. }
function SegredoDeRotaValido(Segredo: String): Boolean;
var
  i: Integer;
  C: Char;
begin
  Result := Length(Segredo) >= TamanhoMinimoSegredoLoopback;

  for i := 1 to Length(Segredo) do
  begin
    C := Segredo[i];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or ((C >= '0') and (C <= '9')) or
            (C = '-') or (C = '_') or (C = '.') or (C = '~')) then
      Result := False;
  end;
end;

{ Valida o loopback (interativo e silencioso passam por aqui). As mensagens nunca carregam o valor de
  um segredo — vão para o log do Inno. }
function ValidarLoopback(var Erro: String): Boolean;
var
  Normalizadas: String;
begin
  Result := False;

  if not NormalizarListaDeOrigens(ValorOrigens, Normalizadas, Erro) then
    Exit;
  ValorOrigens := Normalizadas;

  { O segredo de identidade é OPCIONAL e legado (rota antiga /<segredo>/identidade): só chega pelo
    /CONFIGFILE, e quem o manda ainda precisa que ele seja um segmento de URL válido. }
  if (ValorSegredoIdentidade <> '') and (not SegredoDeRotaValido(ValorSegredoIdentidade)) then
  begin
    Erro := 'LoopbackPrintSegredoIdentidade (opcional) deve ter ao menos ' + IntToStr(TamanhoMinimoSegredoLoopback) +
            ' caracteres, só letras, dígitos, "-", "_", "." ou "~" (ele compõe o caminho da URL). ' +
            'Omita-o: a rota /identidade dispensa segredo.';
    Exit;
  end;

  if (ValorRouteSecret <> '') and (not SegredoDeRotaValido(ValorRouteSecret)) then
  begin
    Erro := 'LoopbackPrintRouteSecret deve ter ao menos ' + IntToStr(TamanhoMinimoSegredoLoopback) +
            ' caracteres, só letras, dígitos, "-", "_", "." ou "~" (ele compõe o caminho da URL).';
    Exit;
  end;

  if (ValorRouteSecret <> '') and (ValorRouteSecret = ValorSegredoIdentidade) then
  begin
    Erro := 'LoopbackPrintSegredoIdentidade (opcional) não pode ser igual ao segredo de impressão ' +
            '(LoopbackPrintRouteSecret): o de impressão nunca sai da estação. Omita o de identidade.';
    Exit;
  end;

  if (ValorSegredoIdentidade <> '') and (ValorOrigens = '') then
  begin
    Erro := 'Informe as origens do front-adm: são elas que protegem a identificação pelo navegador, e ' +
            'sem elas a identificação fica desligada (a tela mostra a máquina como não identificada).';
    Exit;
  end;

  Result := True;
end;

function OrigensInformadas(): String;
begin
  if ValorOrigens <> '' then
    Result := ValorOrigens
  else
    Result := '(nenhuma — identificação pelo navegador desligada: a tela do front-adm mostrará esta ' +
              'máquina como não identificada)';
end;

{ Resolve os valores iniciais a partir do arquivo de resposta e dos parâmetros da linha de comando.
  A ordem de precedência é: /CONFIGFILE → parâmetro explícito → default do épico. }
procedure ValoresIniciais();
var
  Arquivo, Erro: String;
begin
  Arquivo := Parametro('CONFIGFILE', '');

  { Upgrade (PRD-PMTRAY-03, como o TEF): /CONFIGFILE → parâmetro → GRAVADO nesta estação → padrão do
    pacote. Antes o padrão do pacote vencia o gravado, e o --dashboard-url sempre presente na linha do
    Setup.exe sobrescrevia, num upgrade silencioso, o endereço que o operador editou no "Configurar". }
  ValorUrl := LerDoArquivoDeConfiguracao(Arquivo, 'DashboardUrl');
  if ValorUrl = '' then
    ValorUrl := Parametro('DASHBOARDURL', '');
  if ValorUrl = '' then
    ValorUrl := UrlGravada();
  if ValorUrl = '' then
    ValorUrl := '{#DashboardUrlPadrao}';

  { A chave NÃO é relida: ausente, o Setup.exe preserva a gravada (o resumo diz "mantida"). }
  ValorChave := LerDoArquivoDeConfiguracao(Arquivo, 'ApiKey');
  if ValorChave = '' then
    ValorChave := Parametro('APIKEY', '');

  ValorAmbiente := Parametro('ENVIRONMENTNAME', '');
  if ValorAmbiente = '' then
    ValorAmbiente := VariavelDeMaquina(VarAmbiente);
  if ValorAmbiente = '' then
    ValorAmbiente := '{#AmbientePadrao}';
  { Feed do auto-update: arquivo de resposta, depois parâmetro; ausente preserva o gravado. A atualização
    automática em si é SEMPRE ligada pelo Setup.exe (PRD-PMTRAY-02) — não há opção na tela nem parâmetro. }
  ValorManifestUrl := LerDoArquivoDeConfiguracao(Arquivo, 'ManifestUrl');
  if ValorManifestUrl = '' then
    ValorManifestUrl := Parametro('MANIFESTURL', '');
  ValorOtlp := Parametro('OTLPENDPOINT', '');
  AvisoHttpConfirmado := False;

  { Loopback: segredos SÓ pelo arquivo; as origens (que não são segredo) também por /LOOPBACKORIGINS=.
    Na falta de ambos ficam as já gravadas — que só voltam ao Setup.exe se o operador as mudar — e, numa
    estação sem nenhuma, as do pacote (OrigensPadrao): é o que deixa o loopback LIGADO depois da instalação
    padrão. O default não passa pela constante param do Inno (Parametro): lista com vírgula exigiria
    %-encoding ali. ⚠️ Nada de chaves dentro deste tipo de comentário: a primeira que fecha encerra-o. }
  if not NormalizarListaDeOrigens(OrigensGravadas(), OrigensJaGravadas, Erro) then
    OrigensJaGravadas := '';

  ValorOrigens := LerDoArquivoDeConfiguracao(Arquivo, 'LoopbackPrintOrigensPermitidas');
  if ValorOrigens = '' then
    ValorOrigens := Parametro('LOOPBACKORIGINS', '');
  if ValorOrigens = '' then
    ValorOrigens := OrigensJaGravadas;
  if ValorOrigens = '' then
    ValorOrigens := OrigensPadraoDoPacote;

  ValorSegredoIdentidade := LerDoArquivoDeConfiguracao(Arquivo, 'LoopbackPrintSegredoIdentidade');
  ValorRouteSecret := LerDoArquivoDeConfiguracao(Arquivo, 'LoopbackPrintRouteSecret');
  ValorLoopbackEnabled := LerDoArquivoDeConfiguracao(Arquivo, 'LoopbackPrintEnabled');
end;

{ Mascara a chave para o resumo: nunca em claro na tela, nem no log. }
function ChaveMascarada(): String;
begin
  if (ValorChave = '') and (VariavelDeMaquina(VarChaveApi) <> '') then
    Result := '(mantida — a já gravada nesta estação)'
  else if ValorChave = '' then
    Result := '(não informada — a estação receberá 401 até ser configurada)'
  else if Length(ValorChave) <= 4 then
    Result := '••••'
  else
    Result := '••••••••' + Copy(ValorChave, Length(ValorChave) - 3, 4);
end;

function UrlInformada(): String;
begin
  Result := ValorUrl;
end;

function AmbienteInformado(): String;
begin
  Result := ValorAmbiente;
end;

{ Sempre ligada (PRD-PMTRAY-02): o Setup.exe grava PrintMonitor__Update__Enabled=true em toda execução. }
function AutoUpdateInformado(): String;
begin
  if ValorManifestUrl <> '' then
    Result := 'ligada (feed ' + ValorManifestUrl + ')'
  else
    Result := 'ligada (feed: o já gravado na estação, se houver)';
end;

{ ------------------------------------------------------------------------------------------
  Sonda de conexão da tela 4.

  ⚠️ Por que NÃO chama `Setup.exe --validate-connection` aqui. O modo existe e é o que o editor
  pós-instalação usa (etapa 08 §3), mas o agente é publicado SELF-CONTAINED: rodá-lo antes da
  cópia exigiria extrair o layout inteiro (>150 MB) para a pasta temporária só para clicar num botão — e o
  operador pagaria a extração duas vezes em toda instalação. A sonda daqui é a MESMA requisição
  (POST <url>/report com o header X-PrintMonitor-Key e AgentId vazio) e a MESMA classificação de
  HttpConnectionValidator.cs, inclusive nos códigos: 0 Ok · 11 ChaveInvalida · 12 NaoAlcancavel ·
  13 CertificadoInvalido · 14 RespostaInesperada. Alterar um lado exige alterar o outro.
  ------------------------------------------------------------------------------------------ }

{ Normaliza a URL como DashboardUrlNormalizer.TryNormalize: completa o recurso canônico quando só
  vieram servidor e porta, remove a barra final e reescreve a grafia alternativa (kebab, gravada até
  17/10/2026) na canônica — é assim que uma estação antiga migra ao passar pelo instalador.
  Caminho divergente é recusado. }
function NormalizarUrl(Entrada: String; var Normalizada: String; var Erro: String): Boolean;
var
  Valor, Caminho: String;
  BarraDupla, Barra: Integer;
begin
  Result := False;
  Normalizada := '';
  Erro := '';
  Valor := Trim(Entrada);

  if Valor = '' then
  begin
    Erro := 'Informe o endereço da API (exemplo: http://148.72.177.161:5302).';
    Exit;
  end;

  if Pos('://', Valor) = 0 then
    Valor := 'http://' + Valor;

  while (Length(Valor) > 0) and (Valor[Length(Valor)] = '/') do
    Valor := Copy(Valor, 1, Length(Valor) - 1);

  BarraDupla := Pos('://', Valor);
  Barra := Pos('/', Copy(Valor, BarraDupla + 3, Length(Valor)));

  if Barra = 0 then
  begin
    Normalizada := Valor + '{#CaminhoRecurso}';
    Result := True;
    Exit;
  end;

  Caminho := Copy(Valor, BarraDupla + 3 + Barra - 1, Length(Valor));

  if (CompareText(Caminho, '{#CaminhoRecurso}') = 0) or
     (CompareText(Caminho, '{#CaminhoRecursoAlternativo}') = 0) then
  begin
    { Reconstrói com o recurso canônico: servidor e porta + CaminhoRecurso, qualquer que tenha sido a
      grafia aceita (o mesmo que o Setup.exe grava depois). }
    Normalizada := Copy(Valor, 1, BarraDupla + 3 + Barra - 2) + '{#CaminhoRecurso}';
    Result := True;
    Exit;
  end;

  Erro := 'O endereço deve terminar em {#CaminhoRecurso} (recebido: ' + Caminho + ').' + #13#10 +
          'Informe apenas o servidor e a porta que o caminho é completado automaticamente.';
end;

{ Executa a sonda e devolve o código do desfecho, preenchendo a mensagem exibida ao operador. }
function SondarConexao(Entrada, Chave: String; var Mensagem: String): Integer;
var
  Requisicao: Variant;
  Url, Erro: String;
  Status: Integer;
begin
  if not NormalizarUrl(Entrada, Url, Erro) then
  begin
    Mensagem := Erro;
    Result := 14;
    Exit;
  end;

  try
    Requisicao := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Requisicao.SetTimeouts(5000, 10000, 10000, 15000);
    Requisicao.Open('POST', Url + '/report', False);
    Requisicao.SetRequestHeader('Content-Type', 'application/json');

    if Chave <> '' then
      Requisicao.SetRequestHeader('X-PrintMonitor-Key', Chave);

    { AgentId vazio de propósito: a controller o recusa com 400 DEPOIS de a credencial ter sido
      aceita, então a sonda prova a chave sem registrar uma estação fantasma no painel. }
    Requisicao.Send('{"agentId":"00000000-0000-0000-0000-000000000000",' +
                    '"machineName":"printmonitor-setup-probe","agentVersion":"probe","status":0,' +
                    '"processRunning":false,"securePortOpen":false,"timestampUtc":"2000-01-01T00:00:00Z"}');
    Status := Requisicao.Status;
  except
    { WinHttp lança em falha de transporte e em falha de TLS. Distinguir com precisão exigiria ler
      o código nativo; a mensagem cita as duas causas para não induzir o operador ao erro. }
    Mensagem := 'Não foi possível alcançar ' + Url + '. Verifique rede, endereço, porta e firewall ' +
                '(se o endereço for https, também o certificado do servidor). Detalhe: ' +
                GetExceptionMessage();
    Result := 12;
    Exit;
  end;

  if (Status = 400) or ((Status >= 200) and (Status < 300)) then
  begin
    Mensagem := 'Conexão bem-sucedida: a API em ' + Url + ' respondeu e aceitou a chave informada.';
    Result := 0;
  end
  else if Status = 401 then
  begin
    Mensagem := 'A API recusou a chave de API do agente (401). Cada canal tem a sua chave — ' +
                'confira a do canal informado.';
    Result := 11;
  end
  else if Status = 404 then
  begin
    Mensagem := 'O servidor respondeu 404. O host está no ar, mas esse endereço não é o da API do ' +
                'PrintMonitor — confira a porta e o canal.';
    Result := 14;
  end
  else if Status = 413 then
  begin
    Mensagem := 'O servidor respondeu 413 (corpo grande demais): há um proxy com limite de corpo ' +
                'entre a estação e a API. Ver a decisão de canal no runbook.';
    Result := 14;
  end
  else
  begin
    Mensagem := 'Resposta inesperada da API: ' + IntToStr(Status) + '.';
    Result := 14;
  end;
end;

{ Clique do botão "Testar conexão". Falhar aqui NÃO bloqueia a instalação (instalar sem rede e
  configurar depois é cenário legítimo), mas o desfecho fica visível antes de instalar — em vez de
  virar 401 no log de uma máquina de balcão, minutos depois. }
procedure TestarConexao(Sender: TObject);
var
  Mensagem: String;
  Codigo: Integer;
begin
  RotuloTeste.Caption := 'Testando...';
  BotaoTestar.Enabled := False;
  WizardForm.Update();

  try
    Codigo := SondarConexao(PaginaConexao.Values[0], PaginaConexao.Values[1], Mensagem);
    RotuloTeste.Caption := Mensagem;
    Log('[PrintMonitor] Teste de conexão: código ' + IntToStr(Codigo) + ' — ' + Mensagem);
  finally
    BotaoTestar.Enabled := True;
  end;
end;

procedure CriarPaginasDoWizard();
begin
  { Os valores já foram resolvidos em InitializeSetup (que roda antes, inclusive no silencioso). }
  PaginaPreRequisitos := CreateOutputMsgMemoPage(
    wpLicense,
    'Pré-requisitos da estação',
    'Verificação do que esta máquina precisa ter',
    'Resultado das verificações. Um aviso não impede a instalação; um bloqueio já teria ' +
    'encerrado o instalador com o motivo.',
    TextoDasChecagens());

  PaginaConexao := CreateInputQueryPage(
    PaginaPreRequisitos.ID,
    'Conexão com o servidor',
    'Onde esta estação vai reportar',
    'Informe o endereço da API e a chave do agente. O endereço pode ser alterado depois, pelo ' +
    'atalho "Configurar PrintMonitor", sem reinstalar.');

  PaginaConexao.Add('Endereço da API:', False);
  PaginaConexao.Add('Chave de API:', True);
  PaginaConexao.Values[0] := ValorUrl;
  PaginaConexao.Values[1] := ValorChave;

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
  RotuloTeste.Height := ScaleY(46);
  RotuloTeste.WordWrap := True;
  RotuloTeste.Caption := 'Recomendado: teste a conexão antes de instalar. Chave errada só apareceria ' +
                         'depois, como 401 no log da estação.';

  { Identificação pelo navegador (PRD-GIMP-BE-06; sem segredo desde 21/10/2026): sem ela a tela de
    impressoras do front-adm mostra a máquina como "não identificada". Só as ORIGENS são perguntadas — são
    elas a proteção da rota. Nenhum segredo aparece aqui: o de impressão (RouteSecret) o Setup.exe gera
    quando falta, e o de identidade (legado, opcional) só vem pelo /CONFIGFILE. }
  PaginaIdentidade := CreateInputQueryPage(
    PaginaConexao.ID,
    'Identificação pelo navegador',
    'Como o front-adm reconhece esta estação',
    'O front-adm pergunta ao PrintMonitor (em http://127.0.0.1:8183/identidade) qual estação é esta ' +
    'máquina, e só responde às origens exatas informadas abaixo (ex.: https://admin.exemplo.com.br). ' +
    'O campo já vem com o admin padrão. Em branco, o que já estiver gravado nesta estação é mantido.');

  PaginaIdentidade.Add('Origens do front-adm (separadas por vírgula):', False);
  PaginaIdentidade.Values[0] := ValorOrigens;

  { Sem página de opções desde PRD-PMTRAY-02: o checkbox da atualização automática era o único conteúdo
    dela, e a atualização passou a ser sempre ligada. }
end;

{ Validação do Avançar. Vale tanto para o interativo quanto — pela chamada equivalente em
  ValidarParametrosSilenciosos — para o modo silencioso. }
function ValidarPagina(CurPageID: Integer): Boolean;
var
  Url, Erro: String;
begin
  Result := True;

  if (PaginaConexao <> nil) and (CurPageID = PaginaConexao.ID) then
  begin
    if not NormalizarUrl(PaginaConexao.Values[0], Url, Erro) then
    begin
      MsgBox(Erro, mbError, MB_OK);
      Result := False;
      Exit;
    end;

    { Aviso de canal sem TLS: a chave do agente trafega em claro a cada relatório e vale para toda
      a frota. O instalador não esconde isso — o operador confirma cientemente (etapa 05 §2). }
    if (Pos('https://', Lowercase(Url)) <> 1) and (not AvisoHttpConfirmado) then
    begin
      if SuppressibleMsgBox(
           'O endereço informado não usa TLS (https). A chave de API do agente trafegará em claro ' +
           'na rede a cada relatório, e ela vale para todas as estações.' + #13#10#13#10 +
           'Aceitável apenas em rede interna, com prazo para TLS. Continuar?',
           mbConfirmation, MB_YESNO, IDYES) <> IDYES then
      begin
        Result := False;
        Exit;
      end;

      AvisoHttpConfirmado := True;
      Log('[PrintMonitor] Aviso de canal sem TLS exibido e confirmado pelo operador.');
    end;

    ValorUrl := Url;
    ValorChave := Trim(PaginaConexao.Values[1]);
  end;

  if (PaginaIdentidade <> nil) and (CurPageID = PaginaIdentidade.ID) then
  begin
    ValorOrigens := Trim(PaginaIdentidade.Values[0]);

    if not ValidarLoopback(Erro) then
    begin
      MsgBox(Erro, mbError, MB_OK);
      Result := False;
      Exit;
    end;

    PaginaIdentidade.Values[0] := ValorOrigens;
  end;
end;

{ Equivalente silencioso da validação da tela 4: em /VERYSILENT nenhuma página customizada roda.
  Sem isto, o silencioso aceitaria uma URL que o interativo recusaria — e a estação instalaria "com
  sucesso" apontada para lugar nenhum.

  ⚠️ O aviso de canal sem TLS NÃO vira MsgBox aqui: em /VERYSILENT sem /SUPPRESSMSGBOXES uma caixa
  de mensagem trava a instalação INVISIVELMENTE até alguém logar na máquina. Fica no log. }
function ValidarParametrosSilenciosos(): Boolean;
var
  Normalizada, Erro: String;
begin
  Result := NormalizarUrl(ValorUrl, Normalizada, Erro);

  { Endereço relido da estação e inválido (gravado à mão, por exemplo): não é motivo para recusar o
    upgrade — o operador nem o informou. Cai no padrão do pacote, com o motivo no log. }
  if (not Result) and UrlVeioDaEstacao then
  begin
    Log('[PrintMonitor] AVISO: o endereço gravado nesta estação (' + ValorUrl + ') é inválido: ' + Erro +
        ' Usando o padrão do pacote.');
    UrlVeioDaEstacao := False;
    ValorUrl := '{#DashboardUrlPadrao}';
    Result := NormalizarUrl(ValorUrl, Normalizada, Erro);
  end;

  if not Result then
  begin
    Log('[PrintMonitor] BLOQUEIO: ' + Erro);
    SuppressibleMsgBox(Erro, mbCriticalError, MB_OK, IDOK);
    Exit;
  end;

  ValorUrl := Normalizada;

  if Pos('https://', Lowercase(ValorUrl)) <> 1 then
    Log('[PrintMonitor] AVISO: o endereço ' + ValorUrl + ' não usa TLS; a chave do agente trafega ' +
        'em claro na rede a cada relatório e vale para toda a frota.');

  { Mesmas regras da página "Identificação pelo navegador": no silencioso ela não roda. }
  if not ValidarLoopback(Erro) then
  begin
    Log('[PrintMonitor] BLOQUEIO: ' + Erro);
    SuppressibleMsgBox(Erro, mbCriticalError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;

  if ValorOrigens = '' then
    Log('[PrintMonitor] AVISO: sem origens do front-adm (LoopbackPrintOrigensPermitidas); a identificação ' +
        'pelo navegador fica desligada e a tela de impressoras mostrará esta máquina como não identificada.')
  else
    Log('[PrintMonitor] Origens do front-adm para a identificação pelo navegador: ' + ValorOrigens);
end;
