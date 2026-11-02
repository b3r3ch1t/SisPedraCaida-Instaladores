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

{ ------------------------------------------------------------------------------------------
  Impressoras desta estação (PRD-PMSEL-INST-02): quais filas do spooler o PrintMonitor usa e qual é a
  padrão. Só a fila escolhida, de qualquer modelo, é aceita pelo servidor; sem escolha, só os modelos
  homologados da lista fixa de lá.

  As regras abaixo ESPELHAM SelecaoImpressorasEstacao (PrintMonitor.Core): Criar (apara, descarta vazio e
  repetição sem diferenciar maiúsculas, a padrão entra nas habilitadas, na frente se faltava) e
  MontarOpcoes (escolhida que o spooler não tem aparece marcada e sinalizada). A escolha vai ao Setup.exe
  pelo arquivo de resposta (ImpressorasHabilitadas / ImpressoraPadrao), que grava as variáveis de máquina
  relidas pelo Helper a cada coleta. Alterar um lado exige alterar o outro (guarda em InstaladorInnoGuardTests).

  ⚠️ O Setup.exe não tem como receber "nenhuma": as duas chaves ausentes preservam o gravado. Por isso
  desmarcar tudo aqui MANTÉM a escolha gravada (o Avançar avisa) — retirar é pelo "Configurar PrintMonitor".
  ------------------------------------------------------------------------------------------ }

const
  VarImpressorasHabilitadas = 'PrintMonitor__Enrollment__ImpressorasHabilitadas';
  VarImpressoraPadrao = 'PrintMonitor__Enrollment__ImpressoraPadrao';
  { Nome de fila do Windows não aceita a barra vertical; vírgula e ponto e vírgula, sim. }
  SeparadorImpressoras = '|';
  SemImpressoraPadrao = '(nenhuma)';
  SufixoImpressoraAusente = ' (não encontrada nesta máquina)';

var
  PaginaImpressoras: TWizardPage;
  ListaImpressoras: TNewCheckListBox;
  ComboImpressoraPadrao: TNewComboBox;
  RotuloImpressoras: TNewStaticText;
  { Nome da fila de cada linha da lista, no mesmo índice: o rótulo da ausente leva o sufixo. }
  NomesDasOpcoesDeImpressora: TArrayOfString;
  FilasDoSpooler: TArrayOfString;
  SpoolerLido: Boolean;
  ErroDoSpooler: String;

  { Escolha efetiva, já normalizada (filas separadas pela barra vertical), e a gravada nesta estação. }
  ValorImpressoras: String;
  ValorImpressoraPadrao: String;
  ImpressorasJaGravadas: String;
  PadraoJaGravada: String;

{ Índice da fila na lista, sem diferenciar maiúsculas (como o spooler); -1 quando ausente. }
function IndiceDaImpressora(Lista: TArrayOfString; Nome: String): Integer;
var
  i: Integer;
begin
  Result := -1;

  for i := 0 to GetArrayLength(Lista) - 1 do
    if CompareText(Lista[i], Nome) = 0 then
    begin
      Result := i;
      Exit;
    end;
end;

procedure AcrescentarImpressora(var Lista: TArrayOfString; Nome: String);
var
  N: Integer;
begin
  N := GetArrayLength(Lista);
  SetArrayLength(Lista, N + 1);
  Lista[N] := Nome;
end;

{ Divide o texto da variável nas filas, já aparadas e sem vazio nem repetição. }
procedure DividirImpressoras(Texto: String; var Lista: TArrayOfString);
var
  i: Integer;
  Atual: String;
  C: Char;
begin
  SetArrayLength(Lista, 0);
  Atual := '';

  for i := 1 to Length(Texto) + 1 do
  begin
    if i <= Length(Texto) then
      C := Texto[i]
    else
      C := SeparadorImpressoras;

    if C = SeparadorImpressoras then
    begin
      Atual := Trim(Atual);
      if (Atual <> '') and (IndiceDaImpressora(Lista, Atual) < 0) then
        AcrescentarImpressora(Lista, Atual);
      Atual := '';
    end
    else
      Atual := Atual + C;
  end;
end;

function JuntarImpressoras(Lista: TArrayOfString; Separador: String): String;
var
  i: Integer;
begin
  Result := '';

  for i := 0 to GetArrayLength(Lista) - 1 do
  begin
    if Result <> '' then
      Result := Result + Separador;
    Result := Result + Lista[i];
  end;
end;

{ Espelha SelecaoImpressorasEstacao.Criar: a padrão fora da lista seria ignorada pelo servidor, e a
  estação ficaria sem impressora com o técnico achando que escolheu uma. }
procedure NormalizarSelecaoDeImpressoras(Habilitadas, Padrao: String; var HabilitadasNormalizadas: String;
  var PadraoNormalizada: String);
var
  Lista: TArrayOfString;
  i, Indice: Integer;
begin
  DividirImpressoras(Habilitadas, Lista);
  PadraoNormalizada := Trim(Padrao);

  if PadraoNormalizada <> '' then
  begin
    Indice := IndiceDaImpressora(Lista, PadraoNormalizada);

    if Indice >= 0 then
      { A grafia da lista: é a que o técnico viu marcada. }
      PadraoNormalizada := Lista[Indice]
    else
    begin
      SetArrayLength(Lista, GetArrayLength(Lista) + 1);
      for i := GetArrayLength(Lista) - 1 downto 1 do
        Lista[i] := Lista[i - 1];
      Lista[0] := PadraoNormalizada;
    end;
  end;

  HabilitadasNormalizadas := JuntarImpressoras(Lista, SeparadorImpressoras);
end;

{ Filas do spooler pela MESMA fonte do inventário (WmiPrinterInventoryCollector: Win32_Printer, campo
  Name): o nome marcado aqui precisa ser o NomeSistema que o Helper manda. Lida uma vez; falha não impede
  a instalação — a página mostra só as já escolhidas e diz por quê. }
procedure LerFilasDoSpooler();
var
  Localizador, Servico, Resultado, Item: Variant;
  i: Integer;
  Nome: String;
begin
  if SpoolerLido then
    Exit;

  SpoolerLido := True;
  ErroDoSpooler := '';
  SetArrayLength(FilasDoSpooler, 0);

  try
    Localizador := CreateOleObject('WbemScripting.SWbemLocator');
    Servico := Localizador.ConnectServer('.', 'root\CIMV2');
    Resultado := Servico.ExecQuery('SELECT Name FROM Win32_Printer');

    for i := 0 to Resultado.Count - 1 do
    begin
      Item := Resultado.ItemIndex(i);
      Nome := Item.Name;
      Nome := Trim(Nome);

      if (Nome <> '') and (IndiceDaImpressora(FilasDoSpooler, Nome) < 0) then
        AcrescentarImpressora(FilasDoSpooler, Nome);
    end;

    Log('[PrintMonitor] Impressoras do Windows: ' + IntToStr(GetArrayLength(FilasDoSpooler)) + ' fila(s).');
  except
    ErroDoSpooler := GetExceptionMessage();
    Log('[PrintMonitor] AVISO: não foi possível ler as impressoras do Windows (Win32_Printer): ' + ErroDoSpooler);
  end;
end;

{ Valores iniciais da escolha, com a precedência do Setup.exe (SetupParameters.Parse, chave a chave):
  /CONFIGFILE → parâmetro. Nenhuma das duas informada → a gravada nesta estação. }
procedure ValoresIniciaisDasImpressoras(Arquivo: String);
var
  Habilitadas, Padrao: String;
begin
  NormalizarSelecaoDeImpressoras(VariavelDeMaquina(VarImpressorasHabilitadas), VariavelDeMaquina(VarImpressoraPadrao),
    ImpressorasJaGravadas, PadraoJaGravada);

  Habilitadas := LerDoArquivoDeConfiguracao(Arquivo, 'ImpressorasHabilitadas');
  if Habilitadas = '' then
    Habilitadas := Parametro('IMPRESSORAS', '');

  Padrao := LerDoArquivoDeConfiguracao(Arquivo, 'ImpressoraPadrao');
  if Padrao = '' then
    Padrao := Parametro('IMPRESSORAPADRAO', '');

  if (Trim(Habilitadas) = '') and (Trim(Padrao) = '') then
  begin
    Habilitadas := ImpressorasJaGravadas;
    Padrao := PadraoJaGravada;
  end;

  NormalizarSelecaoDeImpressoras(Habilitadas, Padrao, ValorImpressoras, ValorImpressoraPadrao);
end;

{ A escolha efetiva difere da gravada — só então ela vai ao Setup.exe (mesma regra das origens). }
function SelecaoDeImpressorasMudou(): Boolean;
begin
  Result := (ValorImpressoras <> '') and
            ((ValorImpressoras <> ImpressorasJaGravadas) or (ValorImpressoraPadrao <> PadraoJaGravada));
end;

function ImpressorasHabilitadasInformadas(): String;
begin
  if ValorImpressoras = '' then
    Result := '(nenhuma — o servidor só aceita os modelos homologados; escolha depois em "Configurar PrintMonitor")'
  else
  begin
    Result := ValorImpressoras;
    StringChangeEx(Result, SeparadorImpressoras, ', ', True);

    if not SelecaoDeImpressorasMudou() then
      Result := Result + ' (já gravadas nesta estação)';
  end;
end;

function ImpressoraPadraoInformada(): String;
begin
  if ValorImpressoraPadrao <> '' then
    Result := ValorImpressoraPadrao
  else
    Result := SemImpressoraPadrao;
end;

{ Log da escolha (o silencioso não tem página): a fila informada que o spooler não tem NÃO bloqueia — o
  driver pode ser instalado depois, e o --config-ui também a aceita sinalizada. }
procedure RegistrarSelecaoDeImpressorasNoLog();
var
  Lista: TArrayOfString;
  i: Integer;
begin
  if ValorImpressoras = '' then
  begin
    Log('[PrintMonitor] AVISO: nenhuma impressora escolhida para a estação (ImpressorasHabilitadas); o servidor ' +
        'só aceitará os modelos homologados. Escolha depois em "Configurar PrintMonitor".');
    Exit;
  end;

  Log('[PrintMonitor] Impressoras da estação: ' + ImpressorasHabilitadasInformadas() + ' — padrão: ' +
      ImpressoraPadraoInformada());

  LerFilasDoSpooler();
  if ErroDoSpooler <> '' then
    Exit;

  DividirImpressoras(ValorImpressoras, Lista);
  for i := 0 to GetArrayLength(Lista) - 1 do
    if IndiceDaImpressora(FilasDoSpooler, Lista[i]) < 0 then
      Log('[PrintMonitor] AVISO: a impressora "' + Lista[i] + '" foi escolhida, mas o Windows não tem essa fila ' +
          '(driver não instalado ou nome diferente). Ela fica habilitada e aparece sinalizada no "Configurar".');
end;

{ Restringe a padrão às impressoras marcadas, preservando a escolhida enquanto ela continuar marcada
  (o mesmo do AtualizarPadraoPossiveis do --config-ui). }
procedure AtualizarImpressoraPadraoPossiveis(Sender: TObject);
var
  Atual: String;
  i: Integer;
begin
  Atual := '';
  if ComboImpressoraPadrao.ItemIndex > 0 then
    Atual := ComboImpressoraPadrao.Items[ComboImpressoraPadrao.ItemIndex];

  ComboImpressoraPadrao.Items.Clear();
  ComboImpressoraPadrao.Items.Add(SemImpressoraPadrao);

  for i := 0 to ListaImpressoras.Items.Count - 1 do
    if ListaImpressoras.Checked[i] then
      ComboImpressoraPadrao.Items.Add(NomesDasOpcoesDeImpressora[i]);

  ComboImpressoraPadrao.ItemIndex := 0;
  for i := 1 to ComboImpressoraPadrao.Items.Count - 1 do
    if (Atual <> '') and (CompareText(ComboImpressoraPadrao.Items[i], Atual) = 0) then
      ComboImpressoraPadrao.ItemIndex := i;
end;

{ Linhas da lista: as filas do spooler, marcadas conforme a escolha, seguidas das escolhidas que o spooler
  não tem (marcadas e sinalizadas, em vez de sumirem em silêncio) — SelecaoImpressorasEstacao.MontarOpcoes. }
procedure PreencherListaDeImpressoras();
var
  Selecao: TArrayOfString;
  i: Integer;
begin
  LerFilasDoSpooler();
  DividirImpressoras(ValorImpressoras, Selecao);
  SetArrayLength(NomesDasOpcoesDeImpressora, 0);
  ListaImpressoras.Items.Clear();

  for i := 0 to GetArrayLength(FilasDoSpooler) - 1 do
  begin
    AcrescentarImpressora(NomesDasOpcoesDeImpressora, FilasDoSpooler[i]);
    ListaImpressoras.AddCheckBox(FilasDoSpooler[i], '', 0, IndiceDaImpressora(Selecao, FilasDoSpooler[i]) >= 0,
      True, False, False, nil);
  end;

  for i := 0 to GetArrayLength(Selecao) - 1 do
    if IndiceDaImpressora(FilasDoSpooler, Selecao[i]) < 0 then
    begin
      AcrescentarImpressora(NomesDasOpcoesDeImpressora, Selecao[i]);
      ListaImpressoras.AddCheckBox(Selecao[i] + SufixoImpressoraAusente, '', 0, True, True, False, False, nil);
    end;

  AtualizarImpressoraPadraoPossiveis(nil);
  for i := 1 to ComboImpressoraPadrao.Items.Count - 1 do
    if CompareText(ComboImpressoraPadrao.Items[i], ValorImpressoraPadrao) = 0 then
      ComboImpressoraPadrao.ItemIndex := i;

  if ErroDoSpooler <> '' then
    RotuloImpressoras.Caption := 'Não foi possível ler as impressoras do Windows: ' + ErroDoSpooler +
                                 ' Escolha depois em "Configurar PrintMonitor…" (bandeja).'
  else if GetArrayLength(FilasDoSpooler) = 0 then
    RotuloImpressoras.Caption := 'Nenhuma impressora instalada no Windows. Instale o driver do modelo e escolha ' +
                                 'depois em "Configurar PrintMonitor…" (bandeja ou menu Iniciar).'
  else
    RotuloImpressoras.Caption := 'Para trocar depois, sem reinstalar: "Configurar PrintMonitor…" na bandeja ' +
                                 'ou no menu Iniciar.';
end;

procedure CriarPaginaDeImpressoras(AfterID: Integer);
var
  Explicacao, RotuloPadrao: TNewStaticText;
begin
  PaginaImpressoras := CreateCustomPage(
    AfterID,
    'Impressoras desta estação',
    'Quais impressoras o PrintMonitor vai usar');

  Explicacao := TNewStaticText.Create(PaginaImpressoras);
  Explicacao.Parent := PaginaImpressoras.Surface;
  Explicacao.Left := 0;
  Explicacao.Top := 0;
  Explicacao.Width := PaginaImpressoras.SurfaceWidth;
  Explicacao.Height := ScaleY(40);
  Explicacao.AutoSize := False;
  Explicacao.WordWrap := True;
  Explicacao.Caption := 'Marque as impressoras que esta estação usa. Só as marcadas, de qualquer modelo, chegam ' +
                        'ao servidor para serem liberadas na gestão de impressoras; a padrão passa a ser a da ' +
                        'estação ao ser liberada.';

  ListaImpressoras := TNewCheckListBox.Create(PaginaImpressoras);
  ListaImpressoras.Parent := PaginaImpressoras.Surface;
  ListaImpressoras.Left := 0;
  ListaImpressoras.Top := Explicacao.Top + Explicacao.Height + ScaleY(4);
  ListaImpressoras.Width := PaginaImpressoras.SurfaceWidth;
  ListaImpressoras.Height := ScaleY(100);
  ListaImpressoras.OnClickCheck := @AtualizarImpressoraPadraoPossiveis;

  RotuloPadrao := TNewStaticText.Create(PaginaImpressoras);
  RotuloPadrao.Parent := PaginaImpressoras.Surface;
  RotuloPadrao.Left := 0;
  RotuloPadrao.Top := ListaImpressoras.Top + ListaImpressoras.Height + ScaleY(8);
  RotuloPadrao.Caption := 'Impressora padrão da estação (entre as marcadas):';

  ComboImpressoraPadrao := TNewComboBox.Create(PaginaImpressoras);
  ComboImpressoraPadrao.Parent := PaginaImpressoras.Surface;
  ComboImpressoraPadrao.Style := csDropDownList;
  ComboImpressoraPadrao.Left := 0;
  ComboImpressoraPadrao.Top := RotuloPadrao.Top + RotuloPadrao.Height + ScaleY(4);
  ComboImpressoraPadrao.Width := PaginaImpressoras.SurfaceWidth;

  RotuloImpressoras := TNewStaticText.Create(PaginaImpressoras);
  RotuloImpressoras.Parent := PaginaImpressoras.Surface;
  RotuloImpressoras.Left := 0;
  RotuloImpressoras.Top := ComboImpressoraPadrao.Top + ComboImpressoraPadrao.Height + ScaleY(8);
  RotuloImpressoras.Width := PaginaImpressoras.SurfaceWidth;
  RotuloImpressoras.Height := ScaleY(32);
  RotuloImpressoras.AutoSize := False;
  RotuloImpressoras.WordWrap := True;

  PreencherListaDeImpressoras();
end;

{ Avançar da página: nenhuma marcada MANTÉM a escolha gravada (o Setup.exe não recebe "nenhuma") — o
  técnico confirma ciente, e o aviso aponta o caminho para retirar. }
function ValidarPaginaDeImpressoras(): Boolean;
var
  Marcadas, Padrao, Habilitadas, PadraoNormalizada, Mensagem: String;
  i: Integer;
begin
  Result := True;
  Marcadas := '';

  for i := 0 to ListaImpressoras.Items.Count - 1 do
    if ListaImpressoras.Checked[i] then
      Marcadas := Marcadas + NomesDasOpcoesDeImpressora[i] + SeparadorImpressoras;

  Padrao := '';
  if ComboImpressoraPadrao.ItemIndex > 0 then
    Padrao := ComboImpressoraPadrao.Items[ComboImpressoraPadrao.ItemIndex];

  NormalizarSelecaoDeImpressoras(Marcadas, Padrao, Habilitadas, PadraoNormalizada);

  if Habilitadas = '' then
  begin
    if ImpressorasJaGravadas <> '' then
    begin
      Mensagem := ImpressorasJaGravadas;
      StringChangeEx(Mensagem, SeparadorImpressoras, ', ', True);
      Mensagem := 'Nenhuma impressora marcada. A escolha já gravada nesta estação (' + Mensagem + ') será ' +
                  'MANTIDA: o instalador não retira impressoras.' + #13#10#13#10 +
                  'Para retirá-las, use "Configurar PrintMonitor…" na bandeja depois da instalação. Continuar?';
    end
    else
      Mensagem := 'Nenhuma impressora marcada. Sem escolha, o servidor só aceita os modelos homologados — uma ' +
                  'impressora de outro modelo não chega à gestão de impressoras.' + #13#10#13#10 +
                  'Você pode escolher depois em "Configurar PrintMonitor…" na bandeja. Continuar sem impressora?';

    if MsgBox(Mensagem, mbConfirmation, MB_YESNO) <> IDYES then
    begin
      Result := False;
      Exit;
    end;

    Habilitadas := ImpressorasJaGravadas;
    PadraoNormalizada := PadraoJaGravada;
  end;

  ValorImpressoras := Habilitadas;
  ValorImpressoraPadrao := PadraoNormalizada;
  Log('[PrintMonitor] Impressoras escolhidas na página: ' + ImpressorasHabilitadasInformadas() + ' — padrão: ' +
      ImpressoraPadraoInformada());
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

  ValoresIniciaisDasImpressoras(Arquivo);
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

  CriarPaginaDeImpressoras(PaginaIdentidade.ID);

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

  if (PaginaImpressoras <> nil) and (CurPageID = PaginaImpressoras.ID) then
    Result := ValidarPaginaDeImpressoras();
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

  { Mesma escolha da página "Impressoras desta estação": no silencioso ela não roda. Nada aqui bloqueia. }
  RegistrarSelecaoDeImpressorasNoLog();
end;
