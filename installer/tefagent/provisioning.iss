{ ============================================================================================
   provisioning.iss — chamada do Setup.exe e tratamento do código de saída (PRD-TEFINST-06 §5)

   ⚠️ ARMADILHA Nº 1 DESTE INSTALADOR: [Run] IGNORA o código de saída do processo. O Setup.exe
   pode falhar inteiro e o wizard exibir "Concluído" — terminal instalado e mudo é o pior desfecho
   possível (o caixa descobre no primeiro cartão do dia). Por isso o provisionamento é chamado por
   Exec(), com o ResultCode conferido, e nunca por uma entrada de [Run].

   Ordem obrigatória:
     1. copiar o layout do agente   → [Files], já feito quando chegamos aqui (ssPostInstall)
     2. criar as pastas de dados    → o agente cria o SQLite no primeiro startup e precisa delas
     3. Setup.exe --all ...         → código de saída conferido; em falha, --uninstall e reprova
                                      (o código 4 NÃO é falha — ver ExecutarProvisionamento)
   ============================================================================================ }

const
  { Espelha ExitCodes.ProvisionadoAguardandoLiberacao do Setup.exe (PRD-TEFZERA-01). Alterar um
    lado exige alterar o outro. }
  CodigoAguardandoLiberacao = 4;

var
  CaminhoLogProvisionamento: String;
  ProvisionamentoAdiado: Boolean;
  ConfiguracaoInicialGravada: Boolean;
  AguardandoLiberacao: Boolean;

{ Indica que esta instalação vai parar na cópia dos arquivos, por falta de identificação.

  Avaliada ANTES do provisionamento, porque é ela que decide o atalho "Concluir a instalação" na
  seção [Icons] — e os ícones são criados na etapa de instalação, antes do ssPostInstall. }
function ProvisionamentoSeraAdiado(): Boolean;
begin
  Result := not IdentificacaoInformada();
end;

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
  segundos (registro do serviço, primeiro start, sonda de conexão) e conclui que travou. }
procedure Status(Texto: String);
begin
  if WizardForm <> nil then
  begin
    WizardForm.StatusLabel.Caption := Texto;
    WizardForm.Update();
  end;

  Log('[TefAgent] ' + Texto);
end;

{ Monta os argumentos do Setup.exe.

  ⚠️ Parâmetro AUSENTE preserva o que já está gravado (comportamento deliberado de
  SetupParameters/StationConfiguration). É disso que depende "reinstalar sem perder a configuração
  que o operador editou" — por isso o nome só entra quando foi efetivamente informado. }
function ArgumentosDoSetup(Modo: String): String;
var
  ArquivoDeResposta: String;
begin
  Result := Modo +
            ' --api-url "' + ValorApiUrl + '"' +
            ' --tefweb-url "' + ValorTefWebUrl + '"' +
            ' --environment "' + ValorAmbiente + '"';

  { Identificação em branco fica FORA da linha, como o nome: no adiamento ela pode estar meio
    preenchida (só o terminal, só a loja), e o que veio tem de ser gravado; o que não veio preserva
    o valor de uma instalação anterior. }
  if Trim(ValorTerminalId) <> '' then
    Result := Result + ' --terminal-id "' + ValorTerminalId + '"';

  if Trim(ValorStoreId) <> '' then
    Result := Result + ' --store-id "' + ValorStoreId + '"';

  if Trim(ValorName) <> '' then
    Result := Result + ' --name "' + ValorName + '"';

  { PIX sempre ligado: não há opção no wizard, e o Setup.exe grava true de qualquer forma. O
    parâmetro vai explícito só para o log de provisionamento dizer o que foi gravado. }
  Result := Result + ' --pix-enabled s';

  { ⚠️ O arquivo de resposta é REPASSADO ao Setup.exe, e não lido só aqui: a CREDENCIAL do terminal
    (ApiKey=) existe apenas nele, de propósito — este log registra a linha de comando completa, e
    chave em claro aqui seria vazamento com data e hora. Sem o repasse, um rollout silencioso com
    /CONFIGFILE= instalaria o terminal sem credencial e ninguém notaria até o primeiro cartão.
    O Setup.exe dá precedência ao arquivo sobre os parâmetros soltos, então repassá-lo é seguro. }
  ArquivoDeResposta := Parametro('CONFIGFILE', '');

  if Trim(ArquivoDeResposta) <> '' then
    Result := Result + ' --config-file "' + ArquivoDeResposta + '"';
end;

{ ------------------------------------------------------------------------------------------
  Remoção da instalação anterior (17/10/2026).

  Se o serviço do agente já está registrado — ou há uma instalação anterior deste pacote —, o
  instalador PARA o serviço e REMOVE a instalação antes de copiar um único arquivo. Antes, o pacote
  novo era copiado por cima do antigo com o serviço no ar: binário em uso não é sobrescrito, e o
  terminal podia ficar com metade de cada versão.

  ⚠️ A configuração e o banco local SOBREVIVEM: o desinstalador não toca em %PROGRAMDATA% (não há
  seção UninstallDelete para lá, ver TefAgent.iss), e o --uninstall do Setup.exe também os
  preserva. É isso que permite ao wizard reabrir com a identificação e os endereços já gravados.
  (Linha de comentário começando com colchete reprova a compilação: o Inno a lê como seção.)
  ------------------------------------------------------------------------------------------ }

{ Indica se há algo a remover: o serviço registrado ou a entrada de desinstalação deste pacote. }
function InstalacaoAnteriorPresente(): Boolean;
begin
  Result := RegKeyExists(HKLM, ChaveDesinstalacao) or ServicoJaRegistrado();
end;

{ Caminho do desinstalador da instalação anterior (vazio quando não há). }
function DesinstaladorAnterior(): String;
var
  Valor: String;
begin
  Result := '';

  if RegQueryStringValue(HKLM, ChaveDesinstalacao, 'UninstallString', Valor) then
    Result := RemoveQuotes(Valor);
end;

{ Aguarda o desinstalador anterior terminar.

  ⚠️ Esperar o Exec não basta: o desinstalador do Inno se copia para a pasta temporária, relança a
  cópia e o processo original termina na hora. O sinal confiável de que acabou é a entrada de
  desinstalação sumir do registro e o unins000.exe sumir do disco. }
procedure AguardarDesinstalador(Desinstalador: String);
var
  i: Integer;
begin
  for i := 1 to 240 do
  begin
    if (not RegKeyExists(HKLM, ChaveDesinstalacao)) and (not FileExists(Desinstalador)) then
      Exit;

    Sleep(500);
  end;

  Log('[TefAgent] O desinstalador anterior não terminou em 120 s; seguindo para a remoção direta do serviço.');
end;

{ Para e remove o serviço sem o desinstalador — rede de segurança para serviço registrado sem
  entrada de desinstalação (instalação manual, ou desinstalação anterior interrompida).

  `net stop` em vez de `sc stop`: ele ESPERA o serviço parar; o `sc stop` só enfileira o pedido, e o
  `sc delete` seguinte deixaria o serviço marcado para exclusão com o processo ainda vivo. }
procedure PararERemoverServico();
var
  Codigo, i: Integer;
begin
  Exec(ExpandConstant('{sys}\net.exe'), 'stop "{#ServicoNome}"', '', SW_HIDE, ewWaitUntilTerminated, Codigo);
  Log('[TefAgent] net stop do serviço: código ' + IntToStr(Codigo));

  Exec(ExpandConstant('{sys}\sc.exe'), 'delete "{#ServicoNome}"', '', SW_HIDE, ewWaitUntilTerminated, Codigo);
  Log('[TefAgent] sc delete do serviço: código ' + IntToStr(Codigo));

  { O SCM só apaga de fato quando o último handle fecha (o services.msc aberto segura um). }
  for i := 1 to 60 do
  begin
    if not ServicoJaRegistrado() then
      Exit;

    Sleep(500);
  end;
end;

{ Para o serviço e remove a instalação anterior. Devolve vazio no sucesso, ou a mensagem que
  INTERROMPE a instalação (contrato do PrepareToInstall).

  ⚠️ Recusar é o certo quando o serviço não sai: instalar por cima de um serviço vivo é exatamente o
  layout misturado que esta etapa existe para evitar. }
function RemoverInstalacaoAnterior(): String;
var
  Codigo: Integer;
  Desinstalador: String;
begin
  Result := '';

  if not InstalacaoAnteriorPresente() then
    Exit;

  Log('[TefAgent] Instalação anterior encontrada: parando o serviço e removendo antes de continuar.');

  if WizardForm <> nil then
  begin
    WizardForm.PreparingLabel.Caption :=
      'Parando o serviço do agente TEF e removendo a instalação anterior...';
    WizardForm.Update();
  end;

  { A bandeja segura o próprio executável; fechada aqui, a remoção dos binários não esbarra nela. }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im {#BandejaExe}', '', SW_HIDE,
       ewWaitUntilTerminated, Codigo);

  Desinstalador := DesinstaladorAnterior();
  if (Desinstalador <> '') and FileExists(Desinstalador) then
  begin
    { O [UninstallRun] da versão anterior roda o `Setup.exe --uninstall`, que para o serviço,
      confirma a parada e o remove do SCM. }
    if Exec(Desinstalador, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_HIDE,
            ewWaitUntilTerminated, Codigo) then
    begin
      Log('[TefAgent] Desinstalador anterior iniciado (código ' + IntToStr(Codigo) + ').');
      AguardarDesinstalador(Desinstalador);
    end
    else
      Log('[TefAgent] Não foi possível iniciar o desinstalador anterior: ' + Desinstalador);
  end;

  if ServicoJaRegistrado() then
    PararERemoverServico();

  if ServicoJaRegistrado() then
  begin
    { ⚠️ Linha de continuação NUNCA começa com #13#10: o pré-processador do Inno lê o `#` no início
      da linha como diretiva e reprova a compilação ("Unknown preprocessor directive"). }
    Result := 'Não foi possível parar e remover o serviço "{#ServicoNome}" da instalação anterior.' + #13#10#13#10 +
              'Feche o "Serviços" do Windows se estiver aberto, pare o serviço manualmente e ' +
              'execute o instalador novamente.';
    Log('[TefAgent] BLOQUEIO: ' + Result);
    Exit;
  end;

  Log('[TefAgent] Instalação anterior removida; a configuração e o banco local foram preservados.');
end;

{ Desfaz o provisionamento após uma falha. O Inno não tem rollback transacional: quem compensa é
  este script, deixando a máquina sem serviço registrado. ⚠️ O --uninstall preserva o banco local e
  a configuração de propósito — o que ele desfaz é o registro no SCM. }
procedure DesprovisionarAposFalha();
var
  Codigo: Integer;
begin
  Status('Desfazendo o provisionamento...');
  Exec(ExpandConstant('{app}\{#SetupExe}'), '--uninstall', '', SW_HIDE, ewWaitUntilTerminated, Codigo);
  Log('[TefAgent] Desprovisionamento após falha: código ' + IntToStr(Codigo));
end;

{ Grava o que o operador informou no wizard como configuração INICIAL do terminal, quando o
  provisionamento é adiado.

  Antes, o adiamento não chamava o Setup.exe e nada chegava ao disco: o editor ("Configurar o
  agente TEF") abria em branco, e o técnico redigitava API, Elgin, nome e PIX — o que ele não
  lembrava ficava no default. `--configure` sozinho grava a configuração incompleta com AVISO
  (código 0) e não registra serviço; quem conclui continua sendo o atalho "Concluir a instalação".

  ⚠️ Falhar aqui NÃO reprova a instalação nem chama --uninstall: não há serviço a desfazer, e os
  arquivos já estão no lugar. O operador ainda tem o editor para informar tudo — por isso a falha
  só vai para o log e para a tela final (ConfiguracaoInicialGravada = False). }
procedure GravarConfiguracaoInicial();
var
  Codigo: Integer;
  Comando: String;
begin
  Status('Gravando a configuração inicial do terminal...');

  Comando := '/C ""' + ExpandConstant('{app}\{#SetupExe}') + '" ' + ArgumentosDoSetup('--configure') +
             ' > "' + LogDoProvisionamento() + '" 2>&1"';

  ConfiguracaoInicialGravada :=
    Exec(ExpandConstant('{cmd}'), Comando, ExpandConstant('{app}'), SW_HIDE,
         ewWaitUntilTerminated, Codigo) and (Codigo = 0);

  Log('[TefAgent] Configuração inicial (provisionamento adiado): código ' + IntToStr(Codigo) +
      '; log em ' + LogDoProvisionamento());
end;

{ Executa a sequência de pós-instalação. Chamada em ssPostInstall — DEPOIS de os arquivos estarem
  no destino: registrar serviço apontando para executável ausente cria serviço quebrado que o SCM
  reinicia em laço. }
procedure ExecutarProvisionamento();
var
  Codigo: Integer;
  Comando, Mensagem: String;
begin
  ForceDirectories(ExpandConstant('{#PastaDados}') + '\logs');
  ForceDirectories(ExpandConstant('{#PastaDados}') + '\config');
  ForceDirectories(ExpandConstant('{#PastaDados}') + '\data');

  { Sem identificação o Setup.exe recusaria a etapa de configuração (código 3), e o tratamento de
    falha abaixo desfaria o provisionamento e REPROVARIA a instalação inteira — que é justamente o
    que não pode acontecer por um dado que o operador decide depois. Então nem chamamos: as pastas
    de dados acima já ficaram criadas (o editor precisa delas para gravar), e o terminal fica
    aguardando a conclusão.

    ⚠️ Pular aqui é o que mantém a promessa de "instalou": o Inno não tem rollback transacional, e
    tentar-e-falhar deixaria a máquina com arquivos copiados e a tela dizendo que falhou. }
  if ProvisionamentoSeraAdiado() then
  begin
    ProvisionamentoAdiado := True;
    GravarConfiguracaoInicial();
    Status('Instalação concluída sem provisionar: falta a identificação do terminal.');
    Log('[TefAgent] Provisionamento ADIADO: sem identificação (terminal e/ou loja). Arquivos ' +
        'instalados; serviço NÃO registrado. Concluir por "Configurar o agente TEF" + ' +
        '"Concluir a instalação do agente TEF".');
    Exit;
  end;

  Status('Provisionando o terminal (configuração, serviço, início e validação)...');

  { A saída do Setup.exe vai para arquivo: o wizard não mostra saída de processo, e o resumo por
    etapa é o que responde "por que esse terminal não aparece no painel". }
  Comando := '/C ""' + ExpandConstant('{app}\{#SetupExe}') + '" ' + ArgumentosDoSetup('--all') +
             ' > "' + LogDoProvisionamento() + '" 2>&1"';

  if not Exec(ExpandConstant('{cmd}'), Comando, ExpandConstant('{app}'), SW_HIDE,
              ewWaitUntilTerminated, Codigo) then
  begin
    DesprovisionarAposFalha();
    RaiseException('Não foi possível iniciar o provisionamento (' + '{#SetupExe}' + ').' + #13#10 +
                   'A instalação foi interrompida e o terminal não ficou com serviço registrado.');
    Exit;
  end;

  Log('[TefAgent] Provisionamento encerrado com código ' + IntToStr(Codigo) +
      '; log em ' + LogDoProvisionamento());

  { Código 4: serviço registrado e em execução, mas a API recusou a credencial de uma estação já
    enrolada — o terminal espera a liberação no painel (PRD-TEFZERA-01).

    ⚠️ NÃO desfazer. A chave nova que a liberação emite só é retirada pelo agente em execução; o
    --uninstall aqui era o beco sem saída do caixa-01 em 18/10/2026 (terminal bloqueado pela
    migration da liberação, reinstalar falhava sempre). E também não é "Concluído": a tela final
    própria (CurPageChanged) diz que o caixa ainda não opera. }
  if Codigo = CodigoAguardandoLiberacao then
  begin
    AguardandoLiberacao := True;
    Status('Terminal provisionado, aguardando liberação no painel. Detalhe em ' + LogDoProvisionamento());
    Log('[TefAgent] Provisionado AGUARDANDO LIBERAÇÃO: serviço em execução, credencial recusada; ' +
        'liberar o terminal em Terminais TEF.');
    Exit;
  end;

  if Codigo <> 0 then
  begin
    if Codigo = 2 then
      Mensagem := 'O provisionamento foi cancelado.'
    else if Codigo = 3 then
      Mensagem := 'O provisionamento recusou os parâmetros informados.'
    else
      Mensagem := 'O provisionamento falhou (código ' + IntToStr(Codigo) + ').';

    DesprovisionarAposFalha();

    { Falhar aqui é o comportamento correto e deliberado: instalador "concluído" com terminal mudo
      é o pior desfecho possível. A mensagem aponta o log com o resumo por etapa. }
    RaiseException(Mensagem + #13#10#13#10 +
                   'O detalhe por etapa está em:' + #13#10 + LogDoProvisionamento() + #13#10#13#10 +
                   'O terminal ficou SEM serviço registrado. O banco local e a configuração foram ' +
                   'preservados. Corrija a causa e execute o instalador novamente.');
    Exit;
  end;

  Status('Terminal provisionado. Detalhe por etapa em ' + LogDoProvisionamento());
end;
