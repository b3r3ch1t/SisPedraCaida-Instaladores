{ ============================================================================================
   pages.iss — páginas do wizard e parametrização do totem (PRD-TOTEM-04 §1)

   Uma página só de dados: endereço da API Cadastro.Interno (obrigatório), nome e local do
   terminal e a URL do conteúdo (opcional; vazia = a que o servidor informa no sinal). Nenhum desses
   valores é segredo — a credencial do totem é emitida pela API depois da liberação no painel e
   gravada pelo serviço, nunca pelo instalador.

   ⚠️ Página customizada NÃO RODA em modo silencioso. Toda validação que vive aqui tem caminho
   equivalente na leitura dos parâmetros (ValoresIniciais + ValidarParametrosSilenciosos), senão o
   silencioso aceitaria o que o interativo recusa. Parâmetros do silencioso:
       /APIURL=  /NOME=  /LOCAL=  /CONTEUDOURL=

   ⚠️ Upgrade: os valores GRAVADOS em totem.settings.json são relidos e pré-preenchem a página (e
   valem no silencioso sem parâmetro). E o que não mudou NÃO vai para a linha de comando do
   Setup.exe: parâmetro ausente preserva o valor gravado (merge do TotemSettingsFile), então o que o
   técnico não tocou não faz a ida e volta pela leitura de JSON daqui — que não é um parser completo.
   ============================================================================================ }

var
  PaginaPreRequisitos: TOutputMsgMemoWizardPage;
  PaginaTerminal: TInputQueryWizardPage;
  BotaoTestar: TNewButton;

  { Valores efetivos, já resolvidos a partir de parâmetros + tela. Fonte única consumida pelo
    provisionamento e pelo resumo da tela "Pronto para instalar". }
  ValorApiUrl: String;
  ValorNome: String;
  ValorLocal: String;
  ValorConteudoUrl: String;
  AvisoHttpConfirmado: Boolean;

  { O que já está gravado neste terminal (vazio quando não há, ou quando o valor não pôde ser lido
    com segurança). É a base de comparação para decidir o que vai para a linha de comando. }
  GravadoApiUrl: String;
  GravadoNome: String;
  GravadoLocal: String;
  GravadoConteudoUrl: String;

  ConfiguracaoGravada: String;
  ConfiguracaoGravadaLida: Boolean;

{ Lê um parâmetro /NOME=valor da linha de comando, com default vazio. }
function Parametro(Nome: String): String;
begin
  Result := Trim(ExpandConstant('{param:' + Nome + '|}'));
end;

function TextoOuPadrao(Valor, Padrao: String): String;
begin
  if Trim(Valor) = '' then
    Result := Padrao
  else
    Result := Valor;
end;

function TextoOuNaoInformado(Valor: String): String;
begin
  Result := TextoOuPadrao(Valor, '(não informado)');
end;

{ ------------------------------------------------------------------------------------------
  Leitura da configuração gravada (totem.settings.json).

  Busca literal de propósito: o Pascal Script não tem parser de JSON, e o que se precisa daqui são
  quatro campos de texto. Duas proteções que o leitor do TEF não precisava:
    • a busca do campo fica RESTRITA ao objeto da seção (Api, Terminal, Conteudo) — o nome de um
      campo ausente na seção não pode ser achado na seção seguinte;
    • o texto é DECODIFICADO (aspas, barra e escapes de unicode). O System.Text.Json escreve todo
      caractere fora do ASCII como escape de unicode — "São" sai com o "ã" escapado —, então
      recortar sem decodificar devolveria a sequência crua, e gravá-la de volta corromperia o nome.
      Caractere fora do ASCII CRU no arquivo (edição à mão) não tem codificação garantida nesta
      leitura: o valor é tratado como não lido, o campo abre vazio e, sem alteração, o gravado é
      preservado.
  ------------------------------------------------------------------------------------------ }

function ConteudoDaConfiguracaoGravada(): String;
var
  Linhas: TArrayOfString;
  i: Integer;
begin
  if not ConfiguracaoGravadaLida then
  begin
    ConfiguracaoGravadaLida := True;
    ConfiguracaoGravada := '';

    if LoadStringsFromFile(ExpandConstant('{#PastaDados}\config\totem.settings.json'), Linhas) then
      for i := 0 to GetArrayLength(Linhas) - 1 do
        ConfiguracaoGravada := ConfiguracaoGravada + Linhas[i] + #10;
  end;

  Result := ConfiguracaoGravada;
end;

{ Posição do fim da string JSON que começa na aspa em Inicio (a aspa de fechamento), ou 0. }
function FimDaStringJson(Corpo: String; Inicio: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  i := Inicio + 1;

  while i <= Length(Corpo) do
  begin
    if Corpo[i] = '\' then
      i := i + 2
    else if Corpo[i] = '"' then
    begin
      Result := i;
      Exit;
    end
    else
      i := i + 1;
  end;
end;

{ Recorta o objeto que é o valor da propriedade Secao na raiz (com as chaves externas), ou vazio.
  Conta chaves fora de string — chave de abertura ou fechamento DENTRO de um valor não conta. }
function ObjetoDaSecao(Corpo, Secao: String): String;
var
  Minusculo, Alvo: String;
  Inicio, i, Nivel, Abertura: Integer;
begin
  Result := '';
  Minusculo := Lowercase(Corpo);
  Alvo := '"' + Lowercase(Secao) + '"';
  Inicio := Pos(Alvo, Minusculo);
  if Inicio = 0 then
    Exit;

  Abertura := 0;
  for i := Inicio + Length(Alvo) to Length(Corpo) do
  begin
    if Corpo[i] = Chr(123) then
    begin
      Abertura := i;
      Break;
    end;

    { Entre o nome e o objeto só pode haver espaço e dois-pontos. }
    if (Corpo[i] <> ':') and (Corpo[i] <> ' ') and (Corpo[i] <> #9) and (Corpo[i] <> #10) and (Corpo[i] <> #13) then
      Exit;
  end;

  if Abertura = 0 then
    Exit;

  Nivel := 0;
  i := Abertura;
  while i <= Length(Corpo) do
  begin
    if Corpo[i] = '"' then
    begin
      i := FimDaStringJson(Corpo, i);
      if i = 0 then
        Exit;
    end
    else if Corpo[i] = Chr(123) then
      Nivel := Nivel + 1
    else if Corpo[i] = Chr(125) then
    begin
      Nivel := Nivel - 1;
      if Nivel = 0 then
      begin
        Result := Copy(Corpo, Abertura, i - Abertura + 1);
        Exit;
      end;
    end;

    i := i + 1;
  end;
end;

{ Valor de um dígito hexadecimal (-1 quando não é). }
function DigitoHex(C: Char): Integer;
begin
  if (C >= '0') and (C <= '9') then
    Result := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then
    Result := Ord(C) - Ord('a') + 10
  else if (C >= 'A') and (C <= 'F') then
    Result := Ord(C) - Ord('A') + 10
  else
    Result := -1;
end;

{ Decodifica o miolo de uma string JSON. Devolve False quando o texto não é confiável (escape
  malformado, escape acima de 255, ou caractere fora do ASCII cru — ver o cabeçalho da seção). }
function DecodificarStringJson(Cru: String; var Texto: String): Boolean;
var
  i, j, Codigo, Digito: Integer;
  C: Char;
begin
  Result := False;
  Texto := '';
  i := 1;

  while i <= Length(Cru) do
  begin
    C := Cru[i];

    if Ord(C) > 127 then
      Exit;

    if C <> '\' then
    begin
      Texto := Texto + C;
      i := i + 1;
    end
    else
    begin
      if i = Length(Cru) then
        Exit;

      C := Cru[i + 1];
      case C of
        '"', '\', '/': Texto := Texto + C;
        'b': Texto := Texto + #8;
        'f': Texto := Texto + #12;
        'n': Texto := Texto + #10;
        'r': Texto := Texto + #13;
        't': Texto := Texto + #9;
        'u':
          begin
            if i + 5 > Length(Cru) then
              Exit;

            Codigo := 0;
            for j := i + 2 to i + 5 do
            begin
              Digito := DigitoHex(Cru[j]);
              if Digito < 0 then
                Exit;
              Codigo := Codigo * 16 + Digito;
            end;

            { ⚠️ O Chr do Pascal Script do Inno trunca para um byte (medido: o escape do euro virava
              o sinal de negação). Até 255 cobre todo acento do português; acima disso o valor é
              tratado como não lido e, sem alteração, o gravado é preservado. }
            if Codigo > 255 then
              Exit;

            Texto := Texto + Chr(Codigo);
            i := i + 4;
          end;
      else
        Exit;
      end;

      i := i + 2;
    end;
  end;

  Result := True;
end;

{ Lê um campo de texto de uma seção da configuração gravada; vazio quando ausente ou não confiável. }
function ValorGravado(Secao, Nome: String): String;
var
  Objeto, Minusculo, Alvo, Cru, Texto: String;
  Inicio, Base, i, Fim: Integer;
begin
  Result := '';
  Objeto := ObjetoDaSecao(ConteudoDaConfiguracaoGravada(), Secao);
  if Objeto = '' then
    Exit;

  Minusculo := Lowercase(Objeto);
  Alvo := '"' + Lowercase(Nome) + '"';
  Base := 0;

  { Uma ocorrência que não é seguida de dois-pontos é VALOR, não nome de campo ("Local": "Nome"),
    e a busca continua dali. }
  repeat
    Inicio := Pos(Alvo, Copy(Minusculo, Base + 1, Length(Minusculo)));
    if Inicio = 0 then
      Exit;
    Inicio := Base + Inicio;
    Base := Inicio + Length(Alvo) - 1;

    i := Base + 1;
    while (i <= Length(Objeto)) and ((Objeto[i] = ' ') or (Objeto[i] = #9) or (Objeto[i] = #10) or (Objeto[i] = #13)) do
      i := i + 1;
  until (i <= Length(Objeto)) and (Objeto[i] = ':');

  i := i + 1;
  while (i <= Length(Objeto)) and ((Objeto[i] = ' ') or (Objeto[i] = #9) or (Objeto[i] = #10) or (Objeto[i] = #13)) do
    i := i + 1;

  { Valor nulo, numérico ou objeto não interessa: só texto. }
  if (i > Length(Objeto)) or (Objeto[i] <> '"') then
    Exit;

  Fim := FimDaStringJson(Objeto, i);
  if Fim = 0 then
    Exit;

  Cru := Copy(Objeto, i + 1, Fim - i - 1);
  if DecodificarStringJson(Cru, Texto) then
    Result := Trim(Texto)
  else
    Log('[Totem] AVISO: o campo ' + Secao + '.' + Nome + ' de totem.settings.json não pôde ser lido com ' +
        'segurança (caractere fora do ASCII sem escape, ou escape malformado). Ele é preservado se não ' +
        'for alterado nesta instalação.');
end;

{ ------------------------------------------------------------------------------------------
  Normalização e validação.
  ------------------------------------------------------------------------------------------ }

{ Normaliza a ORIGEM da API: esquema obrigatório (http/https), sem barra final e sem um caminho
  "/api..." colado por engano — a mesma regra do TotemSettingsFile.NormalizarOrigem do Setup.exe,
  para o instalador comparar com o gravado na mesma forma. Alterar um lado exige alterar o outro. }
function NormalizarApiUrl(Entrada: String; var Normalizada: String; var Erro: String): Boolean;
var
  Valor, Resto: String;
  InicioDoCaminho, IndiceApi: Integer;
begin
  Result := False;
  Normalizada := '';
  Erro := '';
  Valor := Trim(Entrada);

  if Valor = '' then
  begin
    Erro := 'Informe o endereço da API Cadastro.Interno (ex.: https://api-interno.exemplo).';
    Exit;
  end;

  { Esquema explícito, sem palpite: completar com http:// mandaria o totem para um canal sem TLS
    sem ninguém ter decidido isso. }
  if (Pos('http://', Lowercase(Valor)) <> 1) and (Pos('https://', Lowercase(Valor)) <> 1) then
  begin
    Erro := 'O endereço da API precisa começar por https:// (ou http://, só em rede interna): ' + Valor;
    Exit;
  end;

  { As barras finais saem só do que vem depois do esquema: tirá-las do valor inteiro faria
    "https://" virar "https:", e a mensagem de erro abaixo nunca seria alcançada. }
  Resto := Copy(Valor, Pos('://', Valor) + 3, Length(Valor));
  while (Length(Resto) > 0) and (Resto[Length(Resto)] = '/') do
    Resto := Copy(Resto, 1, Length(Resto) - 1);

  if Trim(Resto) = '' then
  begin
    Erro := 'O endereço da API não tem servidor (recebido apenas o esquema).';
    Exit;
  end;

  { O /api só é procurado no CAMINHO: o servidor pode se chamar "api.exemplo". }
  InicioDoCaminho := Pos('/', Resto);
  if InicioDoCaminho > 0 then
  begin
    IndiceApi := Pos('/api', Lowercase(Copy(Resto, InicioDoCaminho, Length(Resto))));
    if IndiceApi > 0 then
      Resto := Copy(Resto, 1, InicioDoCaminho + IndiceApi - 2);
  end;

  Normalizada := Copy(Valor, 1, Pos('://', Valor) + 2) + Resto;
  Result := True;
end;

{ Valida a URL do conteúdo (opcional). Vazia é válida: vale a URL que o servidor informa no sinal. }
function NormalizarConteudoUrl(Entrada: String; var Normalizada: String; var Erro: String): Boolean;
begin
  Result := True;
  Erro := '';
  Normalizada := Trim(Entrada);

  if Normalizada = '' then
    Exit;

  if (Pos('http://', Lowercase(Normalizada)) <> 1) and (Pos('https://', Lowercase(Normalizada)) <> 1) then
  begin
    Erro := 'A URL do conteúdo precisa começar por https:// (ou http://). Deixe em branco para usar a ' +
            'que o servidor informa.';
    Result := False;
  end;
end;

{ Recusa o que não atravessa a linha de comando do provisionamento. A chamada passa pelo cmd (para
  redirecionar a saída do Setup.exe ao log): aspa quebraria o argumento, e o cmd expande
  porcentagem como variável de ambiente mesmo entre aspas. }
function ValorCabeNaLinhaDeComando(Valor, Rotulo: String; var Erro: String): Boolean;
begin
  Result := (Pos('"', Valor) = 0) and (Pos('%', Valor) = 0);
  if not Result then
    Erro := 'O campo "' + Rotulo + '" não pode conter aspas (") nem porcentagem (%).'
  else
    Erro := '';
end;

{ Resolve os valores iniciais. Precedência: parâmetro da linha de comando → configuração já
  gravada neste terminal → vazio.

  ⚠️ Ler o gravado é o que faz o upgrade não pedir tudo de novo — e, no silencioso, é o que deixa
  uma atualização por ferramenta rodar sem repetir /APIURL=. }
procedure ValoresIniciais();
var
  Normalizada, Erro: String;
begin
  GravadoApiUrl := ValorGravado('Api', 'BaseUrl');
  GravadoNome := ValorGravado('Terminal', 'Nome');
  GravadoLocal := ValorGravado('Terminal', 'Local');
  GravadoConteudoUrl := ValorGravado('Conteudo', 'Url');

  { O gravado é comparado na MESMA forma em que o valor novo será normalizado. }
  if (GravadoApiUrl <> '') and NormalizarApiUrl(GravadoApiUrl, Normalizada, Erro) then
    GravadoApiUrl := Normalizada;

  ValorApiUrl := TextoOuPadrao(Parametro('APIURL'), GravadoApiUrl);
  ValorNome := TextoOuPadrao(Parametro('NOME'), GravadoNome);
  ValorLocal := TextoOuPadrao(Parametro('LOCAL'), GravadoLocal);
  ValorConteudoUrl := TextoOuPadrao(Parametro('CONTEUDOURL'), GravadoConteudoUrl);

  AvisoHttpConfirmado := False;

  if (GravadoApiUrl <> '') or (GravadoNome <> '') or (GravadoLocal <> '') or (GravadoConteudoUrl <> '') then
    Log('[Totem] Configuração gravada encontrada: API=' + GravadoApiUrl + '; nome=' + GravadoNome +
        '; local=' + GravadoLocal + '; conteúdo=' + TextoOuPadrao(GravadoConteudoUrl, '(do servidor)') + '.');
end;

{ ------------------------------------------------------------------------------------------
  Sonda de conexão (botão "Testar conexão").

  A MESMA requisição da SondaDaApi do Setup.exe: POST api/v1/Totens/enrollment com corpo vazio —
  rota anônima que SÓ existe no Cadastro.Interno e responde sucesso sem gravar nada. GET de versão
  não serve: ela responde também no host Externo, e o totem apontado para o Externo só falharia no
  primeiro sinal, depois da instalação "concluída". Alterar um lado exige alterar o outro.

  Por que não chamar o Setup.exe --validate-connection aqui: o layout é self-contained e ainda não
  foi copiado; extraí-lo inteiro para a pasta temporária só para um clique custaria a extração duas
  vezes em toda instalação.
  ------------------------------------------------------------------------------------------ }

function SondarApi(Url: String; var Mensagem: String): Boolean;
var
  Requisicao: Variant;
  Status: Integer;
  Corpo: String;
begin
  Result := False;
  Status := 0;
  Corpo := '';

  try
    Requisicao := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Requisicao.SetTimeouts(5000, 5000, 5000, 10000);
    Requisicao.Open('POST', Url + '/api/v1/Totens/enrollment', False);
    Requisicao.SetRequestHeader('Content-Type', 'application/json');
    Requisicao.SetRequestHeader('Accept', 'application/json');
    Requisicao.SetRequestHeader('x-pedracaida', 'true');
    Requisicao.Send('{}');
    Status := Requisicao.Status;
    Corpo := Requisicao.ResponseText;
  except
    { WinHttp lança em falha de transporte e em falha de TLS; a mensagem cita as duas causas. }
    Mensagem := 'Não foi possível alcançar ' + Url + '. Verifique rede, endereço, porta e firewall; se ' +
                'o endereço for https, verifique também o certificado do servidor.';
    Exit;
  end;

  StringChangeEx(Corpo, ' ', '', True);
  if (Status >= 200) and (Status < 300) and (Pos('"success":true', Lowercase(Corpo)) > 0) then
  begin
    Mensagem := 'A API Cadastro.Interno respondeu em ' + Url + '.';
    Result := True;
  end
  else if Status = 404 then
    Mensagem := 'O endereço ' + Url + ' respondeu, mas não tem a rota do totem (HTTP 404). Confira se é ' +
                'a API Cadastro.Interno — o totem não fala com o host Externo nem com o front.'
  else
    Mensagem := 'O endereço ' + Url + ' respondeu HTTP ' + IntToStr(Status) + ', mas não como a API ' +
                'Cadastro.Interno. Confira porta, caminho e se há proxy no meio.';
end;

{ Clique do botão. Falhar aqui NÃO bloqueia a instalação (totem sem rede na hora da instalação é
  cenário legítimo: o serviço tenta de novo a cada ciclo), mas o desfecho fica visível antes. }
procedure TestarConexao(Sender: TObject);
var
  Url, Erro, Mensagem: String;
begin
  if not NormalizarApiUrl(PaginaTerminal.Values[0], Url, Erro) then
  begin
    MsgBox(Erro, mbError, MB_OK);
    Exit;
  end;

  BotaoTestar.Caption := 'Testando...';
  BotaoTestar.Enabled := False;
  WizardForm.Update();

  try
    if SondarApi(Url, Mensagem) then
      MsgBox(Mensagem, mbInformation, MB_OK)
    else
      MsgBox(Mensagem + #13#10#13#10 + 'Isto NÃO impede a instalação: o serviço tenta de novo sozinho, e ' +
             'o endereço é editável depois pelo atalho "Configurar o totem".', mbError, MB_OK);
    Log('[Totem] Teste da API: ' + Mensagem);
  finally
    BotaoTestar.Caption := 'Testar';
    BotaoTestar.Enabled := True;
  end;
end;

procedure CriarPaginasDoWizard();
begin
  { Os valores já foram resolvidos em InitializeSetup (que roda antes, inclusive no silencioso). }
  PaginaPreRequisitos := CreateOutputMsgMemoPage(
    wpLicense,
    'Pré-requisitos do totem',
    'Verificação do que esta máquina precisa ter',
    'Resultado das verificações. Um aviso não impede a instalação; um bloqueio já teria ' +
    'encerrado o instalador com o motivo.',
    TextoDasChecagens());

  PaginaTerminal := CreateInputQueryPage(
    PaginaPreRequisitos.ID,
    'Terminal e conexão',
    'Com quem este totem conversa e como ele aparece no painel',
    'O endereço é o da API Cadastro.Interno (sem /api). Nome e local identificam o totem no ' +
    'painel. Tudo pode ser alterado depois pelo atalho "Configurar o totem", sem reinstalar.');

  PaginaTerminal.Add('Endereço da API Cadastro.Interno (obrigatório):', False);
  PaginaTerminal.Add('Nome do terminal (ex.: Totem da Recepção):', False);
  PaginaTerminal.Add('Local (ex.: Recepção principal):', False);
  PaginaTerminal.Add('URL do conteúdo (opcional — vazio usa a do servidor):', False);
  PaginaTerminal.Values[0] := ValorApiUrl;
  PaginaTerminal.Values[1] := ValorNome;
  PaginaTerminal.Values[2] := ValorLocal;
  PaginaTerminal.Values[3] := ValorConteudoUrl;

  { O botão fica AO LADO do campo da API, e o resultado sai em caixa de mensagem: quatro campos já
    ocupam a página, e um rótulo de resultado embaixo deles sairia cortado no tamanho padrão do
    wizard. }
  BotaoTestar := TNewButton.Create(PaginaTerminal);
  BotaoTestar.Parent := PaginaTerminal.Surface;
  BotaoTestar.Caption := 'Testar';
  BotaoTestar.Width := ScaleX(75);
  BotaoTestar.Height := PaginaTerminal.Edits[0].Height + ScaleY(2);
  BotaoTestar.Left := PaginaTerminal.SurfaceWidth - BotaoTestar.Width;
  BotaoTestar.Top := PaginaTerminal.Edits[0].Top - ScaleY(1);
  BotaoTestar.OnClick := @TestarConexao;
  PaginaTerminal.Edits[0].Width := BotaoTestar.Left - ScaleX(8) - PaginaTerminal.Edits[0].Left;
end;

{ Recusa só o valor que VAI para a linha de comando, isto é, o que mudou em relação ao gravado. O que
  não mudou não é repassado ao Setup.exe (ver ParametroSeAlterado, no provisioning.iss) — recusar um
  nome gravado com aspas, que o técnico nem tocou, travaria a atualização por um valor que nunca
  atravessa o cmd. }
function ValorAlteradoCabe(Valor, Gravado, Rotulo: String; var Erro: String): Boolean;
begin
  Erro := '';
  Result := (Valor = Gravado) or ValorCabeNaLinhaDeComando(Valor, Rotulo, Erro);
end;

{ Validação comum ao interativo e ao silencioso. Atualiza os Valor* com a forma normalizada. }
function ValidarValores(ApiUrl, Nome, Local, ConteudoUrl: String; var Erro: String): Boolean;
var
  Normalizada: String;
begin
  Result := False;

  if not NormalizarApiUrl(ApiUrl, Normalizada, Erro) then
    Exit;
  if not ValorAlteradoCabe(Normalizada, GravadoApiUrl, 'Endereço da API', Erro) then
    Exit;
  ValorApiUrl := Normalizada;

  if not ValorAlteradoCabe(Trim(Nome), GravadoNome, 'Nome do terminal', Erro) then
    Exit;
  ValorNome := Trim(Nome);

  if not ValorAlteradoCabe(Trim(Local), GravadoLocal, 'Local', Erro) then
    Exit;
  ValorLocal := Trim(Local);

  { A URL gravada que não mudou é aceita como está: quem a gravou foi o Setup.exe ou o suporte. }
  if Trim(ConteudoUrl) = GravadoConteudoUrl then
    Normalizada := GravadoConteudoUrl
  else if not NormalizarConteudoUrl(ConteudoUrl, Normalizada, Erro) then
    Exit;
  if not ValorAlteradoCabe(Normalizada, GravadoConteudoUrl, 'URL do conteúdo', Erro) then
    Exit;
  ValorConteudoUrl := Normalizada;

  Result := True;
end;

{ Validação do Avançar (modo interativo). }
function ValidarPagina(CurPageID: Integer): Boolean;
var
  Erro: String;
begin
  Result := True;

  if (PaginaTerminal = nil) or (CurPageID <> PaginaTerminal.ID) then
    Exit;

  if not ValidarValores(PaginaTerminal.Values[0], PaginaTerminal.Values[1], PaginaTerminal.Values[2],
                        PaginaTerminal.Values[3], Erro) then
  begin
    MsgBox(Erro, mbError, MB_OK);
    Result := False;
    Exit;
  end;

  { Canal sem TLS: o tráfego do totem (inclusive o da jornada de pagamento) vai em claro na rede.
    O instalador não esconde isso — o operador confirma cientemente. }
  if (Pos('https://', Lowercase(ValorApiUrl)) <> 1) and (not AvisoHttpConfirmado) then
  begin
    if MsgBox('O endereço da API informado não usa TLS (https). O tráfego entre este totem e a API vai ' +
              'em claro na rede.' + #13#10#13#10 +
              'Aceitável apenas em rede interna, com prazo para TLS. Continuar?',
              mbConfirmation, MB_YESNO or MB_DEFBUTTON2) <> IDYES then
    begin
      Result := False;
      Exit;
    end;

    AvisoHttpConfirmado := True;
    Log('[Totem] Aviso de canal sem TLS exibido e confirmado pelo operador.');
  end;

  if (ValorNome = '') or (ValorLocal = '') then
    Log('[Totem] AVISO: nome e/ou local do terminal em branco — o painel mostra o código da instalação.');
end;

{ Equivalente silencioso da validação da página: em /VERYSILENT nenhuma página customizada roda.
  ⚠️ Nada de MsgBox interativa aqui: em /VERYSILENT sem /SUPPRESSMSGBOXES uma caixa de mensagem
  trava a instalação INVISIVELMENTE até alguém logar na máquina. O aviso de TLS fica no log, e o
  erro de validação vai por SuppressibleMsgBox (que o /SUPPRESSMSGBOXES responde sozinho). }
function ValidarParametrosSilenciosos(): Boolean;
var
  Erro: String;
begin
  Result := ValidarValores(ValorApiUrl, ValorNome, ValorLocal, ValorConteudoUrl, Erro);

  if not Result then
  begin
    if ValorApiUrl = '' then
      Erro := Erro + ' No silencioso: /APIURL= (ou uma configuração já gravada neste terminal).';
    Log('[Totem] BLOQUEIO: ' + Erro);
    SuppressibleMsgBox(Erro, mbCriticalError, MB_OK, IDOK);
    Exit;
  end;

  if Pos('https://', Lowercase(ValorApiUrl)) <> 1 then
    Log('[Totem] AVISO: o endereço ' + ValorApiUrl + ' não usa TLS; o tráfego deste totem vai em claro na rede.');
end;
