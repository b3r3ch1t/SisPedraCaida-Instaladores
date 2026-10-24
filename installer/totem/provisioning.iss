{ ============================================================================================
   provisioning.iss — upgrade, WebView2, chamada do Setup.exe e desinstalação (PRD-TOTEM-04 §1)

   ⚠️ ARMADILHA Nº 1 DESTE INSTALADOR (#101a): [Run] IGNORA o código de saída do processo. O
   Setup.exe pode falhar inteiro e o wizard exibir "Concluído" — totem instalado e mudo, que o
   cliente descobre na frente da tela. Por isso o provisionamento é chamado por Exec(), com o
   ResultCode conferido, e nunca por uma entrada de [Run].

   Ordem na instalação:
     0. PrepareToInstall → PrepararUpgrade: serviço PARADO e confirmado no SCM, casca fechada e
                            todo processo rodando da pasta de instalação encerrado (por CAMINHO);
     1. copiar o layout                → [Files], já feito quando chegamos ao ssPostInstall;
     2. criar as pastas de dados       → logs, config, web;
     3. WebView2 Runtime ausente       → bootstrapper por Exec()+ResultCode, quando o pacote o traz;
                                         falha só AVISA (a casca mostra "fora de serviço");
     4. Setup.exe --all ...            → código conferido; em falha, --uninstall e REPROVA.

   Na desinstalação (CurUninstallStepChanged, usUninstall): serviço parado e confirmado, casca e
   processos da pasta fechados, e então Setup.exe --uninstall — ANTES da remoção dos arquivos.

   ⚠️ Por que o serviço para ANTES de a casca fechar, nas duas pontas: com o totem em uso, o watchdog
   do serviço relança a casca em até 15 s (CreateProcessAsUser). Fechá-la com o serviço no ar é
   fechá-la para ela voltar no meio da cópia, travando os arquivos de novo.

   ⚠️ Fechamento por CAMINHO, não por nome (lição do PrintMonitor, #112h): o tasklist em TABELA corta
   o nome da imagem em 25 caracteres — todos os executáveis do totem passam disso, e o find nunca os
   acharia. Aqui o tasklist é sempre CSV, e a varredura da pasta é por WMI (Win32_Process,
   ExecutablePath sob a pasta), via COM do próprio Inno. Se o WMI falhar, a reserva fecha por nome
   os SisPedraCaida*.exe da pasta; o que ainda sobrar não reprova a instalação — o [Files] tem
   restartreplace e troca o arquivo travado no próximo reinício.

   ⚠️ Comentário aqui é de chaves e não aninha; linha de comentário começando com colchete reprova a
   compilação. Nenhum fecha-chave dentro destes textos.
   ============================================================================================ }

const
  EsperaParadaSegundos = 45;
  EsperaProcessoSegundos = 15;
  PrefixoDosExecutaveis = 'SISPEDRACAIDA.';

var
  CaminhoLogProvisionamento: String;
  ProvisionamentoConcluido: Boolean;
  WebView2InstaladoAgora: Boolean;
  WebView2FalhaAoInstalar: String;

{ Caminho do log do provisionamento desta execução. O resumo por etapa do Setup.exe é o primeiro
  artefato de diagnóstico em campo — e o wizard, sozinho, o engoliria. }
function LogDoProvisionamento(): String;
begin
  if CaminhoLogProvisionamento = '' then
    CaminhoLogProvisionamento := ExpandConstant('{#PastaDados}') + '\logs\install-' +
      GetDateTimeString('yyyymmdd_hhnnss', #0, #0) + '.log';

  Result := CaminhoLogProvisionamento;
end;

{ Atualiza a linha de status do wizard. Sem isso, o operador vê a barra parada por dezenas de
  segundos (WebView2, registro do serviço, primeiro start, sonda) e conclui que travou. }
procedure Status(Texto: String);
begin
  if WizardForm <> nil then
  begin
    WizardForm.StatusLabel.Caption := Texto;
    WizardForm.Update();
  end;

  Log('[Totem] ' + Texto);
end;

{ ------------------------------------------------------------------------------------------
  Processos: achar, fechar e confirmar a saída.
  ------------------------------------------------------------------------------------------ }

{ Ferramenta do Windows pelo caminho de sistema, nunca pelo PATH. Medido ao validar este script: com
  o Git for Windows no PATH, "find" resolve para o find do Unix, que recusa /I — o pipe devolve
  sempre "não achou", e o processo vivo passava por encerrado. Sem aspas de propósito: a pasta de
  sistema não tem espaço, e aspa no início do /C mudaria a regra de aspas do cmd. }
function FerramentaDoSistema(Nome: String): String;
begin
  Result := ExpandConstant('{sys}') + '\' + Nome;
end;

{ Indica se há processo com a imagem informada, em QUALQUER sessão. CSV, nunca tabela (ver o
  cabeçalho). Sem processo, o tasklist imprime só a linha INFO, que não contém o nome. }
function ProcessoEmExecucao(Imagem: String): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if Exec(ExpandConstant('{cmd}'),
          '/C ' + FerramentaDoSistema('tasklist.exe') + ' /FI "IMAGENAME eq ' + Imagem + '" /FO CSV /NH | ' +
          FerramentaDoSistema('find.exe') + ' /I "' + Imagem + '" > nul',
          '', SW_HIDE, ewWaitUntilTerminated, Codigo) then
    Result := (Codigo = 0);
end;

{ Aguarda a imagem sumir da lista de processos. }
function AguardarProcessoSumir(Imagem: String; Segundos: Integer): Boolean;
var
  i: Integer;
begin
  Result := True;

  for i := 1 to Segundos * 2 do
  begin
    if not ProcessoEmExecucao(Imagem) then
      Exit;

    Sleep(500);
  end;

  Result := not ProcessoEmExecucao(Imagem);
end;

{ Encerra à força todas as instâncias da imagem, em todas as sessões, e CONFIRMA que saíram. }
function EncerrarProcesso(Imagem: String): Boolean;
var
  Codigo: Integer;
begin
  Result := True;

  if not ProcessoEmExecucao(Imagem) then
    Exit;

  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im ' + Imagem, '', SW_HIDE, ewWaitUntilTerminated, Codigo);
  Log('[Totem] taskkill ' + Imagem + ': código ' + IntToStr(Codigo));

  Result := AguardarProcessoSumir(Imagem, EsperaProcessoSegundos);
end;

{ Indica se o caminho do executável está dentro da pasta (sem caixa, com a barra final: uma pasta
  "TotemAntigo" ao lado não casa com "Totem"). }
function CaminhoNaPasta(Caminho, Pasta: String): Boolean;
begin
  Result := (Caminho <> '') and (Pasta <> '') and
            (Pos(AnsiUppercase(AddBackslash(Pasta)), AnsiUppercase(Caminho)) = 1);
end;

{ Processo que NÃO se encerra mesmo estando na pasta: o próprio instalador (Ignorar) e o
  desinstalador do Inno, cuja primeira fase mora em unins000.exe na pasta. }
function ProcessoPoupado(Caminho, Ignorar: String): Boolean;
var
  Nome: String;
begin
  Nome := AnsiUppercase(ExtractFileName(Caminho));
  Result := ((Ignorar <> '') and (CompareText(Caminho, Ignorar) = 0)) or (Pos('UNINS', Nome) = 1);
end;

{ Pasta como padrão LIKE do WQL: barra invertida e apóstrofo escapados pela regra de literal do WQL;
  colchete, sublinhado e porcentagem viram classe de um caractere só, para casar literalmente. }
function PadraoLikeWql(Pasta: String): String;
var
  i: Integer;
  C: String;
begin
  Result := '';
  Pasta := AddBackslash(Pasta);

  for i := 1 to Length(Pasta) do
  begin
    C := Copy(Pasta, i, 1);
    if C = '\' then
      C := '\\'
    else if C = '''' then
      C := '\'''
    else if (C = '[') or (C = '_') or (C = '%') then
      C := '[' + C + ']';

    Result := Result + C;
  end;

  Result := Result + '%';
end;

{ Lista, via WMI, os processos cujo executável está sob a pasta e, com Encerrar, os derruba com
  taskkill /f /pid. Devolve quantos achou, ou -1 se o WMI não respondeu. Descricao recebe
  "nome (PID n)" de cada um, para o log. O filtro LIKE vai no WQL: iterar todos os processos no
  Pascal custa segundos por volta, e o laço de confirmação faz dezenas de voltas. }
function ProcessosDaPastaPorWmi(Pasta, Ignorar: String; Encerrar: Boolean; var Descricao: String): Integer;
var
  Localizador, Servico, Conjunto, Item: Variant;
  Caminho, Pid: String;
  i, Codigo: Integer;
begin
  Result := 0;
  Descricao := '';

  try
    Localizador := CreateOleObject('WbemScripting.SWbemLocator');
    Servico := Localizador.ConnectServer('.', 'root\CIMV2');
    Conjunto := Servico.ExecQuery('SELECT ProcessId, ExecutablePath FROM Win32_Process WHERE ExecutablePath LIKE ''' +
                                  PadraoLikeWql(Pasta) + '''');

    for i := 0 to Conjunto.Count - 1 do
    begin
      Item := Conjunto.ItemIndex(i);
      Caminho := '';
      if not VarIsNull(Item.ExecutablePath) then
        Caminho := Item.ExecutablePath;

      if CaminhoNaPasta(Caminho, Pasta) and (not ProcessoPoupado(Caminho, Ignorar)) then
      begin
        Pid := IntToStr(Integer(Item.ProcessId));
        Result := Result + 1;
        Descricao := Descricao + ExtractFileName(Caminho) + ' (PID ' + Pid + ') ';

        if Encerrar then
        begin
          Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /pid ' + Pid, '', SW_HIDE, ewWaitUntilTerminated, Codigo);
          Log('[Totem] taskkill ' + Caminho + ' (PID ' + Pid + '): código ' + IntToStr(Codigo));
        end;
      end;
    end;
  except
    Log('[Totem] AVISO: WMI indisponível para listar os processos da pasta (' + GetExceptionMessage() + ').');
    Result := -1;
  end;
end;

{ Caminho reserva, sem WMI: fecha por NOME cada SisPedraCaida*.exe da pasta. Por nome alcança o
  mesmo executável fora da pasta, por isso só os do produto. Devolve quantos ainda rodam. }
function ProcessosDaPastaPorNome(Pasta: String; var Descricao: String): Integer;
var
  Busca: TFindRec;
begin
  Result := 0;
  Descricao := '';

  if not FindFirst(AddBackslash(Pasta) + '*.exe', Busca) then
    Exit;

  try
    repeat
      if Pos(PrefixoDosExecutaveis, AnsiUppercase(Busca.Name)) = 1 then
      begin
        EncerrarProcesso(Busca.Name);

        if ProcessoEmExecucao(Busca.Name) then
        begin
          Result := Result + 1;
          Descricao := Descricao + Busca.Name + ' ';
        end;
      end;
    until not FindNext(Busca);
  finally
    FindClose(Busca);
  end;
end;

{ Encerra à força TODO processo cujo executável esteja sob a pasta, em qualquer sessão, e CONFIRMA a
  saída. Repete o taskkill a cada 2 s, porque um Setup.exe aberto pelo atalho pode ter aberto outro
  processo no intervalo. Devolve True quando a pasta ficou livre; Restantes lista o que não saiu. }
function EncerrarProcessosDaPasta(Pasta, Ignorar: String; var Restantes: String): Boolean;
var
  i, Achados: Integer;
begin
  Result := False;
  Restantes := '';

  if (Pasta = '') or (not DirExists(Pasta)) then
  begin
    Result := True;
    Exit;
  end;

  for i := 0 to EsperaProcessoSegundos * 2 do
  begin
    Achados := ProcessosDaPastaPorWmi(Pasta, Ignorar, (i mod 4) = 0, Restantes);

    if Achados < 0 then
    begin
      Achados := ProcessosDaPastaPorNome(Pasta, Restantes);
      Result := (Achados = 0);
      Log('[Totem] Processos da pasta fechados por nome (reserva sem WMI); restantes: ' + IntToStr(Achados) + '.');
      Exit;
    end;

    if Achados = 0 then
    begin
      Result := True;
      Exit;
    end;

    if i = 0 then
      Log('[Totem] Processos rodando de ' + Pasta + ': ' + Restantes);

    Sleep(500);
  end;

  Log('[Totem] AVISO: processos que não saíram de ' + Pasta + ': ' + Restantes);
end;

{ ------------------------------------------------------------------------------------------
  Serviço.
  ------------------------------------------------------------------------------------------ }

{ Indica se o serviço está PARADO segundo o SCM. A saída do `sc query` não é localizada: o estado
  aparece como "1  STOPPED" em qualquer idioma do Windows. }
function ServicoParado(): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if Exec(ExpandConstant('{cmd}'), '/C ' + FerramentaDoSistema('sc.exe') + ' query "{#ServicoNome}" | ' +
          FerramentaDoSistema('find.exe') + ' /I "STOPPED" > nul',
          '', SW_HIDE, ewWaitUntilTerminated, Codigo) then
    Result := (Codigo = 0);
end;

{ Para o serviço e CONFIRMA a parada no SCM (#101d: "comando aceito" não é "parado").
  `net stop` porque ele ESPERA a parada; o laço confere o estado de qualquer forma — o `net stop`
  desiste depois de ~30 s com o serviço ainda em STOP_PENDING. Por fim, espera o processo do serviço
  sair: STOPPED no SCM com o .exe ainda vivo por um instante é normal, e é o .exe que trava arquivos.
  Serviço que NÃO para é derrubado, não recusado (decisão do PrintMonitor, PRD-PMTRAY-04). Antes, as
  ações de recuperação são zeradas: processo de serviço morto conta como falha, e o SCM o religaria
  no meio da cópia. O --all do provisionamento as reconfigura. }
function PararServicoEConfirmar(): Boolean;
var
  Codigo, i: Integer;
begin
  Result := True;

  if not ServicoJaRegistrado() then
    Exit;

  if not ServicoParado() then
  begin
    Exec(ExpandConstant('{sys}\net.exe'), 'stop "{#ServicoNome}"', '', SW_HIDE, ewWaitUntilTerminated, Codigo);
    Log('[Totem] net stop do serviço: código ' + IntToStr(Codigo));
  end;

  for i := 1 to EsperaParadaSegundos * 2 do
  begin
    if ServicoParado() then
      Break;

    Sleep(500);
  end;

  Result := ServicoParado();
  Log('[Totem] Serviço parado e confirmado no SCM: ' + IntToStr(Ord(Result)) + '.');

  if not Result then
  begin
    Exec(ExpandConstant('{sys}\sc.exe'), 'failure "{#ServicoNome}" reset= 0 actions= ""', '', SW_HIDE,
         ewWaitUntilTerminated, Codigo);
    Log('[Totem] AVISO: o serviço não parou em ' + IntToStr(EsperaParadaSegundos) + ' s; ações de ' +
        'recuperação zeradas (código ' + IntToStr(Codigo) + ') e processo derrubado à força.');
    EncerrarProcesso('{#AgenteExe}');
    Result := ServicoParado();
    Log('[Totem] Serviço parado depois de derrubado: ' + IntToStr(Ord(Result)) + '.');
  end
  else if not AguardarProcessoSumir('{#AgenteExe}', EsperaProcessoSegundos) then
    { O SCM já diz STOPPED: o que sobra é processo em encerramento, seguro de terminar. }
    Result := EncerrarProcesso('{#AgenteExe}');
end;

{ Indica se há instalação anterior: a entrada de desinstalação deste pacote ou o serviço registrado. }
function InstalacaoAnteriorPresente(): Boolean;
begin
  Result := RegKeyExists(HKLM, ChaveDesinstalacao) or ServicoJaRegistrado();
end;

{ Prepara a cópia: tira do caminho tudo o que pode travar um arquivo da pasta. Roda SEMPRE — com ou
  sem instalação anterior registrada — e NUNCA recusa: o que não sair fica no log e é substituído no
  próximo reinício pelo restartreplace do [Files]. Devolve sempre vazio (contrato do
  PrepareToInstall).
  ⚠️ Upgrade NO LUGAR, sem rodar o desinstalador anterior (ver Totem.iss): a identidade, a
  configuração e o estado das políticas em %PROGRAMDATA% ficam intocados, e o --all do fim para,
  re-registra e reinicia o serviço. }
function PrepararUpgrade(): String;
var
  Pasta, Restantes: String;
begin
  Result := '';
  Pasta := ExpandConstant('{app}');

  Log('[Totem] Preparação da cópia: instalação anterior=' + IntToStr(Ord(InstalacaoAnteriorPresente())) +
      ' (versão ' + VersaoJaInstalada() + '); pasta=' + Pasta + '.');

  if WizardForm <> nil then
  begin
    WizardForm.PreparingLabel.Caption :=
      'Parando o serviço do totem e fechando a tela do totem antes de copiar os arquivos...';
    WizardForm.Update();
  end;

  if not PararServicoEConfirmar() then
    Log('[Totem] AVISO: o serviço "{#ServicoNome}" não confirmou a parada no SCM; a cópia segue e o ' +
        'arquivo travado, se houver, é trocado no próximo reinício.');

  { A casca segura o próprio .exe e as DLLs compartilhadas do layout self-contained. }
  if not EncerrarProcesso('{#CascaExe}') then
    Log('[Totem] AVISO: a tela do totem não fechou.');

  { O que sobrou: Setup.exe aberto por um atalho, órfão de versão anterior, outra sessão... }
  if EncerrarProcessosDaPasta(Pasta, ExpandConstant('{srcexe}'), Restantes) then
    Log('[Totem] Cópia liberada: serviço parado e nenhum processo rodando de ' + Pasta + '.')
  else
    Log('[Totem] AVISO: ainda rodando de ' + Pasta + ': ' + Restantes + '. A instalação segue; arquivo ' +
        'travado é substituído no próximo reinício (restartreplace).');
end;

{ ------------------------------------------------------------------------------------------
  Setup.exe
  ------------------------------------------------------------------------------------------ }

{ Acrescenta um parâmetro de texto à linha do Setup.exe SÓ quando o valor mudou em relação ao
  gravado. ⚠️ Parâmetro AUSENTE preserva o que já está gravado (merge do TotemSettingsFile): é disso
  que depende "atualizar sem perder a configuração". Valor apagado vai como "--x=" (vazio), que o
  Setup.exe grava como vazio — é o caminho para limpar a URL do conteúdo e voltar à do servidor. }
function ParametroSeAlterado(Nome, Valor, Gravado: String): String;
begin
  Result := '';

  if Valor = Gravado then
    Exit;

  if Valor = '' then
    Result := ' ' + Nome + '='
  else
    Result := ' ' + Nome + ' "' + Valor + '"';
end;

{ Monta os argumentos do --all. }
function ArgumentosDoSetup(): String;
begin
  Result := '--all' +
            ParametroSeAlterado('--api-url', ValorApiUrl, GravadoApiUrl) +
            ParametroSeAlterado('--nome', ValorNome, GravadoNome) +
            ParametroSeAlterado('--local', ValorLocal, GravadoLocal) +
            ParametroSeAlterado('--conteudo-url', ValorConteudoUrl, GravadoConteudoUrl);
end;

{ Executa o Setup.exe da pasta de instalação com a saída redirecionada para o log (o wizard não
  mostra saída de processo). Anexar acrescenta ao log em vez de sobrescrever. Devolve False quando
  o processo nem chegou a rodar; Codigo recebe o código de saída. }
function ExecutarSetup(Argumentos, CaminhoDoLog: String; Anexar: Boolean; var Codigo: Integer): Boolean;
var
  Redirecao, Comando: String;
begin
  if Anexar then
    Redirecao := ' >> "'
  else
    Redirecao := ' > "';

  Comando := '/C ""' + ExpandConstant('{app}\{#SetupExe}') + '" ' + Argumentos +
             Redirecao + CaminhoDoLog + '" 2>&1"';

  Log('[Totem] Setup.exe ' + Argumentos);
  Result := Exec(ExpandConstant('{cmd}'), Comando, ExpandConstant('{app}'), SW_HIDE,
                 ewWaitUntilTerminated, Codigo);
end;

{ Desfaz o provisionamento após uma falha. O Inno não tem rollback transacional: quem compensa é
  este script, deixando a máquina sem serviço registrado, sem a casca no logon e com as políticas da
  sessão restauradas. ⚠️ O --uninstall preserva %PROGRAMDATA% de propósito (identidade e
  configuração ficam para a próxima tentativa). }
procedure DesprovisionarAposFalha();
var
  Codigo: Integer;
begin
  Status('Desfazendo o provisionamento...');
  ExecutarSetup('--uninstall', LogDoProvisionamento(), True, Codigo);
  Log('[Totem] Desprovisionamento após falha: código ' + IntToStr(Codigo));
end;

{ ------------------------------------------------------------------------------------------
  WebView2 Runtime
  ------------------------------------------------------------------------------------------ }

{ Instala o WebView2 Runtime pelo bootstrapper embutido, quando o pacote o traz e a máquina não tem
  o runtime. O bootstrapper é o instalador OFICIAL da Microsoft e BAIXA o runtime na hora — precisa
  de internet nesta máquina; o build não baixa nada.
  ⚠️ Falha aqui NÃO reprova a instalação: sem o runtime a casca mostra "fora de serviço" e o resto
  do totem funciona (serviço, identidade, sinal, liberação no painel). Fica no log e na tela final.
  O código de saída é conferido, mas quem decide o desfecho é a releitura do registro: código zero
  sem o runtime registrado não é sucesso. }
procedure InstalarWebView2SeNecessario();
var
  Bootstrapper: String;
  Codigo: Integer;
begin
  WebView2InstaladoAgora := False;
  WebView2FalhaAoInstalar := '';

  if VersaoWebView2DaMaquina() <> '' then
    Exit;

  if not PacoteTrazBootstrapperWebView2() then
  begin
    Log('[Totem] AVISO: WebView2 Runtime ausente e o pacote não traz o instalador; a tela do totem ' +
        'mostrará "fora de serviço" até o runtime ser instalado.');
    Exit;
  end;

  Bootstrapper := ExpandConstant('{tmp}\{#WebView2BootstrapperNome}');
  if not FileExists(Bootstrapper) then
  begin
    WebView2FalhaAoInstalar := 'o instalador do runtime não foi extraído (' + Bootstrapper + ').';
    Log('[Totem] AVISO: ' + WebView2FalhaAoInstalar);
    Exit;
  end;

  Status('Instalando o WebView2 Runtime (Microsoft) — pode levar alguns minutos...');

  if not Exec(Bootstrapper, '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, Codigo) then
  begin
    WebView2FalhaAoInstalar := 'não foi possível iniciar o instalador do runtime (' + SysErrorMessage(Codigo) + ').';
    Log('[Totem] AVISO: ' + WebView2FalhaAoInstalar);
    Exit;
  end;

  Log('[Totem] Bootstrapper do WebView2 encerrado com código ' + IntToStr(Codigo) + '.');

  if VersaoWebView2DaMaquina() <> '' then
  begin
    WebView2InstaladoAgora := True;
    Log('[Totem] WebView2 Runtime instalado: versão ' + VersaoWebView2DaMaquina() + '.');
  end
  else
  begin
    WebView2FalhaAoInstalar := 'o instalador do runtime terminou com código ' + IntToStr(Codigo) +
                               ' e o runtime não ficou registrado (sem internet nesta máquina?).';
    Log('[Totem] AVISO: ' + WebView2FalhaAoInstalar);
  end;
end;

{ ------------------------------------------------------------------------------------------
  Provisionamento (ssPostInstall)
  ------------------------------------------------------------------------------------------ }

{ Check do [Run]: a casca só é aberta ao fim de uma instalação que provisionou. }
function TotemProvisionado(): Boolean;
begin
  Result := ProvisionamentoConcluido;
end;

{ Executa a sequência de pós-instalação. Chamada em ssPostInstall — DEPOIS de os arquivos estarem
  no destino: registrar serviço apontando para executável ausente cria serviço quebrado que o SCM
  reinicia em laço. }
procedure ExecutarProvisionamento();
var
  Codigo: Integer;
  Mensagem: String;
begin
  ProvisionamentoConcluido := False;

  ForceDirectories(ExpandConstant('{#PastaDados}') + '\logs');
  ForceDirectories(ExpandConstant('{#PastaDados}') + '\config');
  ForceDirectories(ExpandConstant('{#PastaDados}') + '\web');

  { Antes do Setup.exe: o --all termina com o serviço no ar, e a casca que ele sobe precisa do runtime. }
  InstalarWebView2SeNecessario();

  Status('Provisionando o totem (configuração, identidade, serviço, tela no logon e sonda)...');

  if not ExecutarSetup(ArgumentosDoSetup(), LogDoProvisionamento(), False, Codigo) then
  begin
    DesprovisionarAposFalha();
    RaiseException('Não foi possível iniciar o provisionamento (' + '{#SetupExe}' + ').' + #13#10 +
                   'A instalação foi interrompida e o totem não ficou com serviço registrado.');
    Exit;
  end;

  Log('[Totem] Provisionamento encerrado com código ' + IntToStr(Codigo) + '; log em ' + LogDoProvisionamento());

  if Codigo <> 0 then
  begin
    { Espelha CodigosDeSaida do Setup.exe. Alterar um lado exige alterar o outro. }
    if Codigo = 2 then
      Mensagem := 'O provisionamento foi cancelado.'
    else if Codigo = 3 then
      Mensagem := 'O provisionamento recusou os parâmetros informados (endereço da API ausente ou inválido).'
    else
      Mensagem := 'O provisionamento falhou (código ' + IntToStr(Codigo) + ').';

    DesprovisionarAposFalha();

    { Falhar aqui é o comportamento correto e deliberado: instalador "concluído" com totem mudo é o
      pior desfecho possível. A mensagem aponta o log com o resumo por etapa. }
    RaiseException(Mensagem + #13#10#13#10 +
                   'O detalhe por etapa está em:' + #13#10 + LogDoProvisionamento() + #13#10#13#10 +
                   'O totem ficou SEM serviço registrado e com as políticas da sessão restauradas. A ' +
                   'identidade e a configuração foram preservadas. Corrija a causa e execute o ' +
                   'instalador novamente.');
    Exit;
  end;

  ProvisionamentoConcluido := True;
  Status('Totem provisionado. Detalhe por etapa em ' + LogDoProvisionamento());
end;

{ Texto acrescentado à tela final: o log e o que ficou pendente. }
function TextoFinalDoProvisionamento(): String;
begin
  Result := 'Resumo do provisionamento (etapa a etapa):' + #13#10 + LogDoProvisionamento();

  if WebView2InstaladoAgora then
    Result := Result + #13#10#13#10 + 'WebView2 Runtime instalado nesta execução (versão ' +
              VersaoWebView2DaMaquina() + ').'
  else if VersaoWebView2DaMaquina() = '' then
  begin
    Result := Result + #13#10#13#10 + 'ATENÇÃO: o WebView2 Runtime NÃO está instalado nesta máquina';
    if WebView2FalhaAoInstalar <> '' then
      Result := Result + ' — ' + WebView2FalhaAoInstalar
    else
      Result := Result + ' e este pacote não traz o instalador do runtime.';
    Result := Result + ' A tela do totem mostrará "fora de serviço" até ele ser instalado (Windows ' +
              'Update ou o instalador oficial da Microsoft); o serviço já está em execução.';
  end;
end;

{ ------------------------------------------------------------------------------------------
  Desinstalação (CurUninstallStepChanged, usUninstall)
  ------------------------------------------------------------------------------------------ }

{ Para o serviço (confirmando), fecha a casca e tudo o que roda da pasta e chama o
  Setup.exe --uninstall, que remove o serviço e a casca do logon e RESTAURA as políticas da sessão.
  Poupa o próprio desinstalador.
  ⚠️ O código é conferido e, na falha, o operador é AVISADO: um --uninstall que não restaurou as
  políticas deixa a conta do totem sem Gerenciador de Tarefas, sem Executar e sem tecla Windows —
  e, sem aviso, ninguém liga a conta "travada" a esta desinstalação. O aviso não impede a remoção
  dos arquivos (o Inno não volta atrás neste ponto); por isso ele diz como refazer. }
procedure DesprovisionarParaDesinstalar();
var
  Pasta, Restantes, CaminhoDoLog: String;
  Codigo: Integer;
begin
  Pasta := ExpandConstant('{app}');
  CaminhoDoLog := ExpandConstant('{#PastaDados}') + '\logs\uninstall-' +
    GetDateTimeString('yyyymmdd_hhnnss', #0, #0) + '.log';
  ForceDirectories(ExpandConstant('{#PastaDados}') + '\logs');

  Log('[Totem] Desinstalação: parando o serviço e fechando todo processo rodando de ' + Pasta + '.');

  if not PararServicoEConfirmar() then
    Log('[Totem] AVISO: o serviço "{#ServicoNome}" não confirmou a parada no SCM antes da desinstalação.');

  EncerrarProcesso('{#CascaExe}');

  if not EncerrarProcessosDaPasta(Pasta, ExpandConstant('{uninstallexe}'), Restantes) then
    Log('[Totem] AVISO: ainda rodando de ' + Pasta + ' na desinstalação: ' + Restantes +
        '. O arquivo travado é apagado no próximo reinício (uninsrestartdelete).');

  if not FileExists(ExpandConstant('{app}\{#SetupExe}')) then
  begin
    Log('[Totem] AVISO: ' + '{#SetupExe}' + ' ausente na pasta; o serviço e as políticas não foram desfeitos.');
    Exit;
  end;

  if ExecutarSetup('--uninstall', CaminhoDoLog, False, Codigo) and (Codigo = 0) then
  begin
    Log('[Totem] Desprovisionado: serviço removido, tela do totem fora do logon e políticas da sessão ' +
        'restauradas. Log em ' + CaminhoDoLog + '. %PROGRAMDATA% preservado.');
    Exit;
  end;

  Log('[Totem] AVISO: Setup.exe --uninstall terminou com código ' + IntToStr(Codigo) + '; log em ' + CaminhoDoLog);
  SuppressibleMsgBox(
    'Os arquivos do totem serão removidos, mas o desprovisionamento não terminou bem (código ' +
    IntToStr(Codigo) + ').' + #13#10#13#10 +
    'O serviço pode ter ficado registrado ou as políticas da sessão do totem podem não ter sido ' +
    'restauradas (conta do totem sem Gerenciador de Tarefas ou sem Executar).' + #13#10#13#10 +
    'Detalhe em:' + #13#10 + CaminhoDoLog + #13#10#13#10 +
    'Para refazer: reinstale o totem, saia da conta do totem (desconectar) e desinstale de novo por ' +
    'uma conta de administrador.',
    mbError, MB_OK, IDOK);
end;
