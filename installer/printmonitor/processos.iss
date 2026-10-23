{ ============================================================================================
   processos.iss — achar, fechar e confirmar a saída dos processos do PrintMonitor (PRD-PMTRAY-04)

   Achado de campo de 21/10/2026: depois de uma 3.2.0 reprovada e desfeita, a bandeja seguiu viva
   em Program Files; o 3.3.0 por cima parou na cópia com "DeleteFile falhou; código 5" na
   Accessibility.dll. Duas causas, as duas corrigidas aqui:
     1. tasklist em TABELA trunca o nome da imagem em 25 caracteres. Todos os executáveis do
        PrintMonitor passam disso, e o find nunca os achava: ProcessoEmExecucao devolvia falso,
        EncerrarProcesso nem chamava o taskkill. Em CSV o nome sai inteiro.
     2. Fechar por NOME só alcança o que se conhece. O que trava arquivo é qualquer processo cujo
        executável esteja na pasta da instalação, inclusive um órfão de versão desfeita e em
        outra sessão. Por isso o fechamento é por CAMINHO: WMI Win32_Process, ExecutablePath
        sob a pasta, via COM do próprio Inno. Não depende de binário já instalado, nem de
        PowerShell, nem do Setup.exe da versão anterior, que pode não existir.

   Se o WMI falhar (serviço Winmgmt parado, repositório corrompido), o caminho reserva fecha por
   NOME os executáveis SisPedraCaida que estão na pasta. O que sobrar ainda assim não reprova a
   instalação: o [Files] tem restartreplace e troca o arquivo travado no próximo reinício.

   Usado no PrepareToInstall (upgrade.iss), na reversão (provisioning.iss) e na desinstalação
   (CurUninstallStepChanged). Sem dependência de outro include: o harness de teste o inclui só.

   ⚠️ Comentário aqui é de chaves e não aninha; linha de comentário começando com colchete reprova a
   compilação. Nada de chave de abertura dentro deste texto.
   ============================================================================================ }

const
  EsperaProcessoSegundos = 15;
  PrefixoDosExecutaveis = 'SISPEDRACAIDA.';

{ Indica se há processo com a imagem informada, em QUALQUER sessão. CSV, nunca tabela: a tabela do
  tasklist corta o nome em 25 caracteres e o find não acharia SisPedraCaida.PrintMonitor.*.exe.
  Sem processo, o tasklist imprime só a linha INFO, que não contém o nome. }
function ProcessoEmExecucao(Imagem: String): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if Exec(ExpandConstant('{cmd}'),
          '/C tasklist /FI "IMAGENAME eq ' + Imagem + '" /FO CSV /NH | find /I "' + Imagem + '" > nul',
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

{ Encerra à força todas as instâncias da imagem, em todas as sessões, e CONFIRMA que saíram.
  ⚠️ Sem /T: derrubar a árvore levaria junto o QZ Tray aberto pelo Helper, que não mora na pasta e
  não trava arquivo nenhum dela. O que mora na pasta sai pelo EncerrarProcessosDaPasta. }
function EncerrarProcesso(Imagem: String): Boolean;
var
  Codigo: Integer;
begin
  Result := True;

  if not ProcessoEmExecucao(Imagem) then
    Exit;

  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im ' + Imagem, '', SW_HIDE, ewWaitUntilTerminated, Codigo);
  Log('[PrintMonitor] taskkill ' + Imagem + ': código ' + IntToStr(Codigo));

  Result := AguardarProcessoSumir(Imagem, EsperaProcessoSegundos);
end;

{ Indica se o caminho do executável está dentro da pasta (comparação sem caixa, com a barra final:
  C:\X\PrintMonitorAntigo não casa com C:\X\PrintMonitor). }
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

{ Pasta como padrão LIKE do WQL: barra e aspa escapadas pela regra de literal do WQL; colchete,
  sublinhado e porcentagem viram classe de um caractere só, para casar literalmente. }
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
  "nome (PID n)" de cada um, para o log.
  O filtro LIKE vai no WQL: iterar no Pascal os ~250 processos de uma estação custa segundos por
  volta (ItemIndex por late binding), e o laço de confirmação faz dezenas de voltas. O prefixo é
  conferido de novo aqui, por garantia. ExecQuery sem flags devolve um conjunto não forward-only:
  Count e ItemIndex funcionam. }
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
          Log('[PrintMonitor] taskkill ' + Caminho + ' (PID ' + Pid + '): código ' + IntToStr(Codigo));
        end;
      end;
    end;
  except
    Log('[PrintMonitor] AVISO: WMI indisponível para listar os processos da pasta (' + GetExceptionMessage() + ').');
    Result := -1;
  end;
end;

{ Caminho reserva, sem WMI: fecha por NOME cada SisPedraCaida*.exe da pasta. Por nome alcança o
  mesmo executável fora da pasta, por isso só os do produto. Devolve quantos ainda rodam. }
function ProcessosDaPastaPorNome(Pasta: String; Encerrar: Boolean; var Descricao: String): Integer;
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
        if Encerrar then
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
  saída — independentemente de haver instalação anterior registrada. Repete o taskkill a cada 2 s,
  porque um Bootstrapper ou Setup.exe pode abrir outro processo no intervalo. Devolve True quando a
  pasta ficou livre; Restantes lista o que não saiu. Ignorar é o executável do próprio instalador. }
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
      Achados := ProcessosDaPastaPorNome(Pasta, True, Restantes);
      Result := (Achados = 0);
      Log('[PrintMonitor] Processos da pasta fechados por nome (reserva sem WMI); restantes: ' + IntToStr(Achados) + '.');
      Exit;
    end;

    if Achados = 0 then
    begin
      Result := True;
      Log('[PrintMonitor] Nenhum processo rodando de ' + Pasta + '.');
      Exit;
    end;

    if i = 0 then
      Log('[PrintMonitor] Processos rodando de ' + Pasta + ': ' + Restantes);

    Sleep(500);
  end;

  Log('[PrintMonitor] AVISO: processos que não saíram de ' + Pasta + ': ' + Restantes);
end;
