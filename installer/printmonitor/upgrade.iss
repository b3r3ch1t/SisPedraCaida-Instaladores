{ ============================================================================================
   upgrade.iss — upgrade NO LUGAR por um instalador novo, na política do agente TEF (PRD-PMTRAY-03)

   Decisão de 21/10/2026: a versão nova chega por um instalador executado POR CIMA do antigo. O
   auto-update do Bootstrapper continua ligado (PRD-PMTRAY-02); este arquivo cobre o outro caminho.

   O que é IGUAL ao TEF (TefAgent.iss, armadilha #101):
     • AppId estável e a mesma pasta de instalação (UsePreviousAppDir);
     • antes de copiar um único arquivo, o serviço é PARADO e a parada CONFIRMADA no SCM;
     • a bandeja é fechada (ela trava o próprio .exe e as DLLs compartilhadas do layout);
     • [Files] com ignoreversion; configuração e estado em %PROGRAMDATA% preservados;
     • re-provisionamento idempotente (Setup.exe --all, parâmetro ausente preserva o gravado);
     • downgrade bloqueado em InitializeSetup com a mesma mensagem; a mesma versão reinstala.

   O que é DIFERENTE, de propósito:
     • NÃO roda o desinstalador anterior. O TEF roda (o --uninstall dele preserva a configuração em
       agent.settings.json); o --uninstall do PrintMonitor APAGA as variáveis de máquina (chave de
       API, endereço, feed, ambiente) e a Run key do Helper — rodá-lo num upgrade era perder a chave
       da estação. Aqui o serviço só é parado; o --all depois atualiza o registro no lugar.
     • Fecha também o HELPER (processo da sessão do usuário, na mesma pasta). Ele é quem imprime pelo
       QZ Tray: fechado e não reaberto, o balcão fica mudo até o próximo logon. Desde o PRD-PMTRAY-05
       QZ Tray, Helper e bandeja são INICIADOS no fim, sempre (não só o que estava aberto), como o
       usuário original e inclusive no silencioso; o estado anotado antes de fechar só informa o log.
     • Fecha um Bootstrapper em andamento ANTES de parar o serviço: ele para e parte o serviço por
       conta própria e o religaria no meio da cópia. Interromper um auto-update no meio é inofensivo
       aqui, porque o [Files] sobrescreve todos os arquivos da pasta logo depois.

   PRD-PMTRAY-04 (campo, 21/10/2026; decisão do usuário: parar o serviço e permitir a instalação
   sobrescrevendo todos os arquivos):
     • a limpeza roda SEMPRE, sem depender de instalação anterior registrada: depois de uma versão
       reprovada e desfeita não há registro, mas um órfão pode seguir vivo e travando DLL;
     • além de bandeja e Helper por nome, fecha à força TODO processo cujo executável esteja na
       pasta da instalação, em qualquer sessão (processos.iss, WMI por caminho), e confirma a saída;
     • NÃO recusa a instalação por processo ou arquivo em uso. Serviço que não para é derrubado
       (sem as ações de recuperação do SCM, que o religariam em 1 min; o --all as reconfigura); o
       que ainda travar é trocado no próximo reinício pelo restartreplace do [Files], sem a caixa
       Tentar novamente / Ignorar / Cancelar. Tudo vai para o log; nada de MsgBox.

   ⚠️ Comentário aqui é de chaves e não aninha; linha de comentário começando com colchete reprova a
   compilação (o Inno a lê como seção). Nada de chave de abertura dentro deste texto.
   ⚠️ ProcessoEmExecucao, AguardarProcessoSumir, EncerrarProcesso e EncerrarProcessosDaPasta moram
   no processos.iss, incluído antes deste.
   ============================================================================================ }

const
  EsperaParadaSegundos = 60;

var
  InstalacaoAnteriorDetectada: Boolean;
  HelperEstavaAberto: Boolean;
  BandejaEstavaAberta: Boolean;
  QzEstavaAberto: Boolean;

{ Indica se há uma instalação anterior deste pacote: a entrada de desinstalação do AppId ou o serviço
  registrado (instalação manual, ou desinstalação anterior interrompida). }
function InstalacaoAnteriorPresente(): Boolean;
begin
  Result := RegKeyExists(HKLM, ChaveDesinstalacao) or ServicoJaRegistrado();
end;

{ Indica se o QZ Tray está no ar: o lançador qz-tray.exe (versões antigas) OU qualquer processo cujo executável
  esteja sob a pasta do QZ Tray. Campo, 21/10/2026, PC_ANDERSON: no QZ Tray 2.2+ o lançador SAI depois de criar
  runtime\bin\javaw.exe na pasta do QZ, e só o nome do lançador dava "QZ parado" com ele escutando na 8181/8182 — o
  instalador abria outro QZ por cima. Pelo caminho, e não por "qualquer javaw": outro programa Java da estação
  não é o QZ. Sem WMI (-1), fica só o nome do lançador, como antes. }
function QzTrayEmExecucao(): Boolean;
var
  Executavel, Descricao: String;
begin
  Result := ProcessoEmExecucao(QzTrayImagem);
  if Result then
    Exit;

  Executavel := CaminhoDoQzTray();
  if Executavel = '' then
    Exit;

  Result := ProcessosDaPastaPorWmi(ExtractFileDir(Executavel), '', False, Descricao) > 0;
  if Result then
    Log('[PrintMonitor] QZ Tray em execução pela pasta (sem o lançador): ' + Descricao);
end;

{ Indica se o serviço está PARADO segundo o SCM. A saída do `sc query` não é localizada: o estado
  aparece como "1  STOPPED" em qualquer idioma do Windows. }
function ServicoParado(): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if Exec(ExpandConstant('{cmd}'), '/C sc query "{#ServicoNome}" | find /I "STOPPED" > nul',
          '', SW_HIDE, ewWaitUntilTerminated, Codigo) then
    Result := (Codigo = 0);
end;

{ Para o serviço e CONFIRMA a parada no SCM (#101d: "comando aceito" não é "parado").
  `net stop` porque ele ESPERA a parada; o laço confere o estado de qualquer forma — o `net stop`
  desiste depois de ~30 s e devolve erro com o serviço ainda em STOP_PENDING. Por fim, espera o
  processo do serviço sair: STOPPED no SCM com o .exe ainda vivo por um instante é normal, e é o
  .exe que trava os arquivos.
  PRD-PMTRAY-04: serviço que NÃO para é derrubado, não recusado. Antes, as ações de recuperação são
  zeradas: processo de serviço morto conta como falha e o SCM o religaria em 1 min, no meio da cópia.
  O --all do provisionamento as reconfigura (WindowsServiceInstaller.ConfigureFailureActionsAsync). }
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
    Log('[PrintMonitor] net stop do serviço: código ' + IntToStr(Codigo));
  end;

  for i := 1 to EsperaParadaSegundos * 2 do
  begin
    if ServicoParado() then
      Break;

    Sleep(500);
  end;

  Result := ServicoParado();
  Log('[PrintMonitor] Serviço parado e confirmado no SCM: ' + IntToStr(Ord(Result)) + '.');

  if not Result then
  begin
    Exec(ExpandConstant('{sys}\sc.exe'), 'failure "{#ServicoNome}" reset= 0 actions= ""', '', SW_HIDE,
         ewWaitUntilTerminated, Codigo);
    Log('[PrintMonitor] AVISO: o serviço não parou em ' + IntToStr(EsperaParadaSegundos) + ' s; ações de ' +
        'recuperação zeradas (código ' + IntToStr(Codigo) + ') e processo derrubado à força.');
    EncerrarProcesso('{#ServicoExe}');
    Result := ServicoParado();
    Log('[PrintMonitor] Serviço parado depois de derrubado: ' + IntToStr(Ord(Result)) + '.');
  end
  else if not AguardarProcessoSumir('{#ServicoExe}', EsperaProcessoSegundos) then
    { O SCM já diz STOPPED: o que sobra é processo em encerramento, seguro de terminar. }
    Result := EncerrarProcesso('{#ServicoExe}');
end;

{ Prepara a cópia: tira do caminho TUDO o que pode travar um arquivo da pasta. Roda SEMPRE — com
  ou sem instalação anterior registrada (PRD-PMTRAY-04) — e, por decisão do usuário, NUNCA recusa: o
  que não sair fica no log e é substituído no próximo reinício pelo restartreplace do [Files]. Devolve
  sempre vazio (contrato do PrepareToInstall). Ordem: Bootstrapper (para não religar o serviço) →
  serviço parado e confirmado no SCM → bandeja → Helper → qualquer outro processo rodando da pasta. }
function PrepararUpgrade(): String;
var
  Pasta, Restantes: String;
begin
  Result := '';
  InstalacaoAnteriorDetectada := InstalacaoAnteriorPresente();
  Pasta := ExpandConstant('{app}');

  { Anotado ANTES de fechar qualquer coisa, só para o log: desde o PRD-PMTRAY-05 tudo é iniciado no fim. }
  HelperEstavaAberto := ProcessoEmExecucao('{#HelperExe}');
  BandejaEstavaAberta := ProcessoEmExecucao('{#BandejaExe}');
  QzEstavaAberto := QzTrayEmExecucao();

  Log('[PrintMonitor] Upgrade: instalação anterior=' + IntToStr(Ord(InstalacaoAnteriorDetectada)) +
      ' (versão ' + VersaoJaInstalada() + '); Helper aberto=' + IntToStr(Ord(HelperEstavaAberto)) +
      '; bandeja aberta=' + IntToStr(Ord(BandejaEstavaAberta)) + '; QZ Tray aberto=' + IntToStr(Ord(QzEstavaAberto)) +
      '; pasta=' + Pasta + '.');

  if WizardForm <> nil then
  begin
    WizardForm.PreparingLabel.Caption :=
      'Parando o serviço do PrintMonitor e fechando a bandeja, o Helper e os demais processos da pasta ' +
      'antes de copiar os arquivos...';
    WizardForm.Update();
  end;

  if not EncerrarProcesso('{#BootstrapperExe}') then
    Log('[PrintMonitor] AVISO: o Bootstrapper não fechou; segue para o serviço.');

  if not PararServicoEConfirmar() then
    Log('[PrintMonitor] AVISO: o serviço "{#ServicoNome}" não confirmou a parada no SCM; a cópia segue e o ' +
        'arquivo travado, se houver, é trocado no próximo reinício.');

  { A bandeja e o Helper seguram o próprio .exe e as DLLs compartilhadas do layout self-contained. }
  if not EncerrarProcesso('{#BandejaExe}') then
    Log('[PrintMonitor] AVISO: a bandeja não fechou.');

  if not EncerrarProcesso('{#HelperExe}') then
    Log('[PrintMonitor] AVISO: o Helper não fechou.');

  { O que sobrou: órfão de versão desfeita, Setup.exe aberto pela bandeja, outra sessão... }
  if EncerrarProcessosDaPasta(Pasta, ExpandConstant('{srcexe}'), Restantes) then
    Log('[PrintMonitor] Cópia liberada: serviço parado e nenhum processo rodando de ' + Pasta + '; ' +
        '%PROGRAMDATA% e variáveis de máquina intocados.')
  else
    Log('[PrintMonitor] AVISO: ainda rodando de ' + Pasta + ': ' + Restantes + '. A instalação segue; ' +
        'arquivo travado é substituído no próximo reinício (restartreplace) e o Windows pede o reinício no fim.');
end;

{ Desinstalação (PRD-PMTRAY-04): a mesma limpeza do PrepararUpgrade, chamada no
  CurUninstallStepChanged(usUninstall) — antes do [UninstallRun] e da remoção dos arquivos. Poupa o
  próprio desinstalador. Nunca abre caixa: o que não sair vai para o log e o arquivo travado é
  apagado no próximo reinício (uninsrestartdelete). }
procedure LimparProcessosParaDesinstalar();
var
  Pasta, Restantes: String;
begin
  Pasta := ExpandConstant('{app}');
  Log('[PrintMonitor] Desinstalação: parando o serviço e fechando todo processo rodando de ' + Pasta + '.');

  EncerrarProcesso('{#BootstrapperExe}');

  if not PararServicoEConfirmar() then
    Log('[PrintMonitor] AVISO: o serviço "{#ServicoNome}" não confirmou a parada no SCM antes da desinstalação.');

  EncerrarProcesso('{#BandejaExe}');
  EncerrarProcesso('{#HelperExe}');

  if not EncerrarProcessosDaPasta(Pasta, ExpandConstant('{uninstallexe}'), Restantes) then
    Log('[PrintMonitor] AVISO: ainda rodando de ' + Pasta + ' na desinstalação: ' + Restantes +
        '. O arquivo travado é apagado no próximo reinício (uninsrestartdelete).');
end;

{ Indica se o instalador roda como LocalSystem (ferramenta de distribuição). Aí "o usuário original"
  é o próprio sistema, na sessão 0: abrir bandeja ou Helper ali os poria onde ninguém vê, e o Helper
  disputaria a porta do loopback com o da sessão do balcão. Nesse caso eles voltam no próximo logon. }
function RodandoComoSistema(): Boolean;
var
  Usuario: String;
begin
  Usuario := Uppercase(GetUserNameString());
  Result := (Usuario = 'SYSTEM') or (Usuario = 'SISTEMA') or
            ((Length(Usuario) > 0) and (Usuario[Length(Usuario)] = '$'));
end;

{ ------------------------------------------------------------------------------------------
  Início na sessão do usuário (PRD-PMTRAY-05). Campo, 21/10/2026, 3.4.0: o serviço ficou em execução,
  mas o Helper e o QZ Tray não — a reabertura só valia para o que JÁ estava aberto antes, e o Helper
  só subia no próximo logon, pela Run key. A bandeja mostrou "Helper não está em execução",
  "loopback não respondeu" e "QZ Tray não está em execução", e o admin não identificava a estação.

  Agora, depois do provisionamento com sucesso ou com aviso (código 0 ou 4), SEMPRE: QZ Tray (se não
  roda) → Helper (se não roda) → bandeja (no silencioso por código; no interativo pela caixa da tela
  final, o [Run] com runasoriginaluser). Tudo como o usuário original, sem elevação.

  ⚠️ AMBIENTE: o processo original do Inno nasceu ANTES do --all, e o ExecAsOriginalUser cria o filho
  com o ambiente dele — sem as variáveis de máquina recém-gravadas (PrintMonitor__*, DOTNET_ENVIRONMENT).
  O Helper subiria sem LoopbackPrint:OrigensPermitidas e o loopback não responderia. Por isso ele é
  iniciado com ArgumentoAmbienteDaMaquina: antes de criar o host, o próprio Helper relê do registro as
  variáveis do PrintMonitor (máquina, sobreposta pela do usuário) e corrige o ambiente do processo
  (AmbienteDaMaquina, guarda AmbienteDaMaquinaTests). Não depende de WM_SETTINGCHANGE, do explorer.exe
  nem do Agendador de Tarefas, e nenhum segredo passa pela linha de comando. A bandeja NÃO precisa:
  ela lê a configuração direto das variáveis de máquina (LeitorDaConfiguracaoDaEstacao). O QZ Tray não
  lê variável nenhuma do PrintMonitor.

  Ao fim, confere que o Helper ficou rodando e, com o loopback ligado, que GET /identidade respondeu
  com a primeira origem gravada. Só aviso no log e na tela final, NUNCA reprovação: a estação já está
  provisionada, e no próximo logon a Run key sobe o Helper de qualquer forma.
  ------------------------------------------------------------------------------------------ }

const
  { Espelha AmbienteDaMaquina.Argumento (guarda: AmbienteDaMaquinaTests). }
  ArgumentoAmbienteDaMaquina = '--ambiente-da-maquina';
  { Espelham StationEnvironmentVariables.LoopbackEnabled / LoopbackPort e LoopbackPrintOptions.Port. }
  VarLoopbackLigado = 'PrintMonitor__LoopbackPrint__Enabled';
  VarLoopbackPorta = 'PrintMonitor__LoopbackPrint__Port';
  PortaLoopbackPadrao = '8183';
  { Porta fechada no Windows recusa só depois de ~1-2 s (o TCP repete o SYN), então o teto é por tentativa:
    12 x (~2 s até a recusa + 1 s de pausa) = no máximo ~40 s (medido); o Helper responde em 2-3 s. }
  TentativasLoopback = 12;
  EsperaHelperSegundos = 3;

var
  ResumoDaSessao: String;

{ Acrescenta uma linha ao resumo da tela final e ao log. }
procedure AnotarSessao(Linha: String);
begin
  Log('[PrintMonitor] ' + Linha);
  ResumoDaSessao := ResumoDaSessao + #13#10 + '- ' + Linha;
end;

{ Abre um executável como o usuário original, sem esperar (ele fica residente). }
function AbrirComoUsuarioOriginal(Executavel, Parametros, Descricao: String; Janela: Integer): Boolean;
var
  Codigo: Integer;
begin
  Result := False;

  if (Executavel = '') or (not FileExists(Executavel)) then
  begin
    AnotarSessao('AVISO: ' + Descricao + ' não encontrado em "' + Executavel + '"; não iniciado.');
    Exit;
  end;

  Result := ExecAsOriginalUser(Executavel, Parametros, ExtractFileDir(Executavel), Janela, ewNoWait, Codigo);
  if Result then
    Log('[PrintMonitor] ' + Descricao + ' iniciado como o usuário original.')
  else
    AnotarSessao('AVISO: não foi possível iniciar ' + Descricao + ' (' + SysErrorMessage(Codigo) +
                 '); ele sobe no próximo logon.');
end;

{ Primeira origem gravada (as origens vêm separadas por vírgula), ou ''. }
function PrimeiraOrigemGravada(): String;
var
  Lista: String;
  Virgula: Integer;
begin
  Lista := OrigensGravadas();
  Virgula := Pos(',', Lista);
  if Virgula > 0 then
    Result := Copy(Lista, 1, Virgula - 1)
  else
    Result := Lista;
end;

{ GET http://127.0.0.1:<porta>/identidade com o Origin informado, pelo WinHTTP do Windows (COM, sem
  proxy). Devolve o status HTTP, ou 0 sem resposta (Helper ainda subindo, ou loopback fora). }
function ConsultarLoopback(Porta, Origem: String): Integer;
var
  Http: Variant;
begin
  Result := 0;

  try
    Http := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Http.Open('GET', 'http://127.0.0.1:' + Porta + '/identidade', False);
    Http.SetProxy(1);
    Http.SetTimeouts(1000, 1000, 2000, 2000);
    Http.SetRequestHeader('Origin', Origem);
    Http.Send('');
    Result := Http.Status;
  except
    Result := 0;
  end;
end;

{ Confere, sem reprovar, que o Helper ficou rodando e que o loopback respondeu. }
procedure ConferirHelperELoopback();
var
  Porta, Origem: String;
  i, Status: Integer;
begin
  Status := -1;
  Origem := PrimeiraOrigemGravada();
  Porta := VariavelDeMaquina(VarLoopbackPorta);
  if Porta = '' then
    Porta := PortaLoopbackPadrao;

  if (CompareText(VariavelDeMaquina(VarLoopbackLigado), 'true') = 0) and (Origem <> '') then
  begin
    Status := 0;
    for i := 1 to TentativasLoopback do
    begin
      Status := ConsultarLoopback(Porta, Origem);
      if Status <> 0 then
        Break;

      Sleep(1000);
    end;
  end
  else
    Sleep(EsperaHelperSegundos * 1000);

  if ProcessoEmExecucao('{#HelperExe}') then
    AnotarSessao('Helper em execução na sessão do usuário.')
  else
    AnotarSessao('AVISO: o Helper não ficou em execução; ele sobe no próximo logon. Veja o log do Helper em ' +
                 '%PROGRAMDATA%\SisPedraCaida\PrintMonitor\logs.');

  if Status = 200 then
    AnotarSessao('Identificação pelo navegador: o loopback respondeu 200 em http://127.0.0.1:' + Porta +
                 '/identidade (origem ' + Origem + ').')
  else if Status = 404 then
    AnotarSessao('AVISO: o loopback respondeu 404 para a origem ' + Origem + ' (o Helper não a reconhece). ' +
                 'Faça logoff/logon do operador e confira as origens gravadas.')
  else if Status = 503 then
    AnotarSessao('AVISO: o loopback respondeu 503 (a identidade da estação, agent-id, ainda não foi gravada).')
  else if Status = 0 then
    AnotarSessao('AVISO: o loopback não respondeu em http://127.0.0.1:' + Porta + '/identidade em ' +
                 IntToStr(TentativasLoopback) + ' tentativas (~40 s).')
  else if Status > 0 then
    AnotarSessao('AVISO: o loopback respondeu ' + IntToStr(Status) + ' em http://127.0.0.1:' + Porta + '/identidade.')
  else
    AnotarSessao('Identificação pelo navegador não conferida: loopback desligado ou sem origens gravadas.');
end;

{ Inicia, no fim de um provisionamento aprovado (código 0 ou 4), o que roda na sessão do usuário —
  SEMPRE, não só o que estava aberto antes da cópia. Ordem: QZ Tray (assim o serviço, ao achar o
  Helper, já encontra o QZ no ar e não pede um segundo) → Helper, com o ambiente da máquina → bandeja,
  por código só no silencioso (no interativo ela vem pela caixa da tela final). Como LocalSystem não
  inicia nada: tudo sobe no próximo logon, pelas Run keys. }
procedure IniciarProcessosDaSessao();
begin
  ResumoDaSessao := '';

  if RodandoComoSistema() then
  begin
    AnotarSessao('Instalador rodando como LocalSystem (sem usuário na sessão): QZ Tray, Helper e bandeja ' +
                 'sobem no próximo logon (Run keys), não nesta execução.');
    Exit;
  end;

  if WizardForm <> nil then
  begin
    WizardForm.StatusLabel.Caption := 'Iniciando o QZ Tray, o Helper e a bandeja na sessão do usuário...';
    WizardForm.Update();
  end;

  if QzTrayEmExecucao() then
    AnotarSessao('QZ Tray já estava em execução.')
  else if AbrirComoUsuarioOriginal(CaminhoDoQzTray(), '', 'o QZ Tray', SW_SHOWNORMAL) then
    AnotarSessao('QZ Tray iniciado.');

  if ProcessoEmExecucao('{#HelperExe}') then
    AnotarSessao('Helper já estava em execução (mantém o ambiente com que foi criado).')
  else
  begin
    AbrirComoUsuarioOriginal(ExpandConstant('{app}\{#HelperExe}'), ArgumentoAmbienteDaMaquina, 'o Helper', SW_HIDE);
    ConferirHelperELoopback();
  end;

  if WizardSilent() then
  begin
    if ProcessoEmExecucao('{#BandejaExe}') then
      AnotarSessao('Bandeja já estava em execução.')
    else if AbrirComoUsuarioOriginal(ExpandConstant('{app}\{#BandejaExe}'), '', 'a bandeja', SW_SHOWNORMAL) then
      AnotarSessao('Bandeja iniciada.');
  end;
end;

{ Bloco da tela final: o que subiu na sessão e o resultado da conferência do loopback. }
function ResumoProcessosDaSessao(): String;
begin
  Result := '';
  if ResumoDaSessao <> '' then
    Result := #13#10#13#10 + 'Sessão do usuário:' + ResumoDaSessao;
end;
