{ ============================================================================================
   provisioning.iss — chamada do Setup.exe e tratamento do código de saída (etapa 02 §5)

   ⚠️ ARMADILHA Nº 1 DESTE INSTALADOR: [Run] IGNORA o código de saída do processo. O Setup.exe
   pode falhar inteiro e o wizard exibir "Concluído" — estação instalada e muda é o pior desfecho
   possível. Por isso o provisionamento é chamado por Exec(), com o ResultCode conferido, e nunca
   por uma entrada de [Run].

   Ordem obrigatória (etapa 04 §3):
     1. copiar o layout do agente        → [Files], já feito quando chegamos aqui (ssPostInstall)
     2. instalar o QZ Tray do payload     → antes do provisionamento; a etapa 3 do Setup.exe só
                                            reporta "Ignorado" se encontrar o executável no lugar
     3. regra de firewall para a 8181/8182 → idempotente
     4. Setup.exe --all ...               → código de saída conferido
   ============================================================================================ }

const
  PastaDadosPrintMonitor = '{commonappdata}\SisPedraCaida\PrintMonitor';

var
  CaminhoLogProvisionamento: String;

{ Caminho do log do provisionamento desta execução. O resumo por etapa do Setup.exe é o primeiro
  artefato de diagnóstico em campo — e o wizard, sozinho, o engoliria. }
function LogDoProvisionamento(): String;
begin
  if CaminhoLogProvisionamento = '' then
    CaminhoLogProvisionamento := ExpandConstant(PastaDadosPrintMonitor) + '\logs\install-' +
      GetDateTimeString('yyyymmdd_hhnnss', #0, #0) + '.log';

  Result := CaminhoLogProvisionamento;
end;

{ Atualiza a linha de status do wizard. Sem isso, o operador vê a barra parada por dezenas de
  segundos (instalação do QZ Tray, download do certificado) e conclui que travou. }
procedure Status(Texto: String);
begin
  if WizardForm <> nil then
  begin
    WizardForm.StatusLabel.Caption := Texto;
    WizardForm.Update();
  end;

  Log('[PrintMonitor] ' + Texto);
end;

{ Instala o QZ Tray a partir do payload local, quando ausente.

  ⚠️ Tem de vir ANTES do Setup.exe --all: QzTrayInstaller recusa InstallerUrl que não comece com
  https://, e a API do piloto está em HTTP puro. Com o QZ Tray já instalado, a etapa 3 do
  provisionamento encontra o executável e devolve "Ignorado" sem tocar em URL nem em SHA-256. }
procedure InstalarQzTray();
#if QzInstallerFile != ""
var
  Instalador: String;
  Codigo: Integer;
#endif
begin
#if QzInstallerFile != ""
  if QzTrayJaInstalado() then
  begin
    Status('QZ Tray já instalado; pulando a instalação do payload.');
    Exit;
  end;

  Instalador := ExpandConstant('{tmp}\{#QzInstallerFile}');
  if not FileExists(Instalador) then
  begin
    Status('Payload do QZ Tray não encontrado em ' + Instalador + '; seguindo sem instalá-lo.');
    Exit;
  end;

  Status('Instalando o QZ Tray (pode levar alguns minutos)...');

  { ⚠️ O argumento silencioso NÃO é universal entre versões do QZ Tray: argumento errado abre a UI
    do instalador ATRÁS da janela do wizard e a instalação "trava" sem explicação. O payload
    homologado (qz-tray-2.3.0-x86_64.exe, release oficial) é um instalador NSIS: o silencioso é /S
    — o mesmo default de QzTrayInstallOptions.SilentInstallArguments. Os argumentos install4j usados
    até 21/10/2026 (-q -splash ...) seriam ignorados pelo NSIS, que abriria a UI. Confirmar a cada
    bump de versão do payload (etapa 04 §5); InstaladorInnoGuardTests cobra a igualdade com o C#. }
  if not Exec(Instalador, '/S', '', SW_SHOW, ewWaitUntilTerminated, Codigo) then
    Status('Não foi possível iniciar o instalador do QZ Tray; a etapa 3 do provisionamento dirá o estado real.')
  else if Codigo <> 0 then
    Status('O instalador do QZ Tray terminou com código ' + IntToStr(Codigo) + '.')
  else
    Status('QZ Tray instalado.');
#else
  Status('Pacote sem payload do QZ Tray; a instalação do QZ Tray fica a cargo do operador.');
#endif
end;

{ Regra de firewall para as portas do QZ Tray: 8181 (wss, a do navegador e do monitor) e 8182 (ws).
  Idempotente por construção: remove antes de criar, para não acumular uma regra homônima a cada
  reinstalação. Remove também a regra antiga "(8182)", de quando as portas estavam invertidas. }
procedure AplicarRegraDeFirewall();
var
  Codigo: Integer;
  Nome: String;
begin
  Nome := 'SisPedraCaida PrintMonitor - QZ Tray (8181-8182)';
  Status('Aplicando a regra de firewall das portas 8181/8182...');

  Exec(ExpandConstant('{sys}\netsh.exe'),
       'advfirewall firewall delete rule name="SisPedraCaida PrintMonitor - QZ Tray (8182)"',
       '', SW_HIDE, ewWaitUntilTerminated, Codigo);

  Exec(ExpandConstant('{sys}\netsh.exe'),
       'advfirewall firewall delete rule name="' + Nome + '"',
       '', SW_HIDE, ewWaitUntilTerminated, Codigo);

  Exec(ExpandConstant('{sys}\netsh.exe'),
       'advfirewall firewall add rule name="' + Nome + '" dir=in action=allow protocol=TCP ' +
       'localport=8181,8182 profile=any',
       '', SW_HIDE, ewWaitUntilTerminated, Codigo);

  if Codigo <> 0 then
    Status('A regra de firewall não pôde ser aplicada (código ' + IntToStr(Codigo) + '); a impressão ' +
           'pode exigir liberação manual das portas 8181/8182.');
end;

{ Monta os argumentos do Setup.exe.

  ⚠️ Parâmetro AUSENTE preserva o que já está gravado (comportamento deliberado de SetupParameters).
  É disso que depende "reinstalar sem perder a configuração que o operador editou" — por isso a
  chave e a URL só entram quando foram efetivamente informadas.

  ⚠️ A CHAVE e os segredos do loopback NÃO entram aqui: vão pelo arquivo de resposta temporário
  (--config-file, ver GravarArquivoDeResposta). Linha de comando de processo é legível por qualquer
  usuário da máquina enquanto o Setup.exe roda, e acaba em log de auditoria (#78b). }
function ArgumentosDoProvisionamento(ArquivoDeResposta: String): String;
begin
  Result := '--all --environment "' + ValorAmbiente + '"';

  if ValorUrl <> '' then
    Result := Result + ' --dashboard-url "' + ValorUrl + '"';

  if ArquivoDeResposta <> '' then
    Result := Result + ' --config-file "' + ArquivoDeResposta + '"';

  if ValorManifestUrl <> '' then
    Result := Result + ' --manifest-url "' + ValorManifestUrl + '"';

  if ValorOtlp <> '' then
    Result := Result + ' --otlp-endpoint "' + ValorOtlp + '"';
end;

{ Grava o arquivo de resposta temporário (pares Chave=valor, o formato de SetupParameters.Parse) com o
  que não pode ir na linha de comando: a chave do agente e o loopback do Helper. Só entra o que foi
  informado — ausente preserva o gravado na estação. As origens só voltam ao Setup.exe se mudaram:
  reenviá-las ligaria o loopback de uma estação em que o suporte o desligou de propósito. Numa estação
  sem origens gravadas, as do pacote (OrigensPadrao) contam como mudança: vão ao Setup.exe, que liga o
  loopback (LoopbackPrint:Enabled=true) e gera o RouteSecret que faltar — a identificação pelo navegador
  sai funcionando da instalação padrão. A escolha de impressoras (PRD-PMSEL-INST-02) segue a mesma regra:
  só vai quando difere da gravada; e a padrão vazia não precisa de linha — informadas as habilitadas, o
  Setup.exe grava a padrão como vazia (nenhuma).

  Vive na pasta temporária do Inno (privada desta execução, removida no fim) e é apagado logo depois da
  chamada pelo ExecutarProvisionamento. Devolve o caminho, ou '' quando não há nada a levar. }
function GravarArquivoDeResposta(): String;
var
  Linhas: TArrayOfString;
  N: Integer;
begin
  Result := '';
  N := 0;
  SetArrayLength(Linhas, 7);

  if ValorChave <> '' then
  begin
    Linhas[N] := 'ApiKey=' + ValorChave;
    N := N + 1;
  end;

  if ValorLoopbackEnabled <> '' then
  begin
    Linhas[N] := 'LoopbackPrintEnabled=' + ValorLoopbackEnabled;
    N := N + 1;
  end;

  if ValorRouteSecret <> '' then
  begin
    Linhas[N] := 'LoopbackPrintRouteSecret=' + ValorRouteSecret;
    N := N + 1;
  end;

  if ValorSegredoIdentidade <> '' then
  begin
    Linhas[N] := 'LoopbackPrintSegredoIdentidade=' + ValorSegredoIdentidade;
    N := N + 1;
  end;

  if (ValorOrigens <> '') and (ValorOrigens <> OrigensJaGravadas) then
  begin
    Linhas[N] := 'LoopbackPrintOrigensPermitidas=' + ValorOrigens;
    N := N + 1;
  end;

  if SelecaoDeImpressorasMudou() then
  begin
    Linhas[N] := 'ImpressorasHabilitadas=' + ValorImpressoras;
    N := N + 1;

    if ValorImpressoraPadrao <> '' then
    begin
      Linhas[N] := 'ImpressoraPadrao=' + ValorImpressoraPadrao;
      N := N + 1;
    end;
  end;

  if N = 0 then
    Exit;

  SetArrayLength(Linhas, N);
  Result := ExpandConstant('{tmp}\printmonitor-provisionamento.txt');

  if not SaveStringsToUTF8File(Result, Linhas, False) then
    RaiseException('Não foi possível gravar o arquivo de resposta do provisionamento em ' + Result + '.' + #13#10 +
                   'Sem ele a estação ficaria sem a chave do agente; a instalação foi interrompida.');
end;

{ ------------------------------------------------------------------------------------------
  Sucesso COM AVISO (PRD-PMCERT-01, 21/10/2026): o Setup.exe sai com 4 quando a estação ficou
  operante, mas uma etapa NÃO essencial ficou pendente - hoje, o certificado do QZ Tray (sem ele o
  QZ pede confirmação ao imprimir; não deixa a estação muda). Em campo, essa etapa reprovava e este
  script desfazia TUDO. Código 4 NÃO desprovisiona: vai para o log e para a tela final.
  Espelha CodigosDeSaida.SucessoComAviso (guarda: CodigosDeSaidaTests).
  ------------------------------------------------------------------------------------------ }

const
  CodigoSucessoComAviso = 4;

var
  ProvisionamentoComAviso: Boolean;

{ Linha do aviso do provisionamento para a tela final ('' quando terminou sem aviso). }
function ResumoAvisoProvisionamento(): String;
begin
  Result := '';

  if ProvisionamentoComAviso then
    Result := #13#10#13#10 + 'ATENÇÃO — instalação concluída COM AVISO: o agente está instalado e operante, ' +
              'mas uma etapa ficou pendente (tipicamente o certificado do QZ Tray, que não pôde ser obtido do ' +
              'servidor; até lá o QZ Tray pede confirmação ao imprimir). A causa e o que fazer estão nas ' +
              'linhas [Aviso] do log acima. Resolvida a causa, rode como administrador ' +
              '"' + '{#SetupExe}' + ' --install-cert" na pasta do PrintMonitor — não é preciso reinstalar.';
end;

{ Desfaz o provisionamento após uma falha. O Inno não tem rollback transacional: quem compensa é
  este script, deixando a máquina sem serviço, sem Run key e sem variáveis de máquina.

  Bandeja (achado de campo de 21/10/2026, 3.2.0 contra o dev): depois da reversão ela ficava ABERTA
  mostrando "Serviço não registrado", "Helper não está em execução"... numa estação sem agente — o
  operador lia defeito onde havia uma instalação reprovada. A reversão faz o mesmo que a desinstalação:
  fecha a bandeja, apaga o valor dela na Run key da máquina (o [Registry] já o gravou nesta execução) e
  marca a falha, para a caixa "Mostrar o status..." da tela final não a abrir de novo. }
var
  ProvisionamentoReprovado: Boolean;

{ Check do [Run] da bandeja: só sobe numa estação que ficou provisionada. }
function EstacaoProvisionada(): Boolean;
begin
  Result := not ProvisionamentoReprovado;
end;

procedure DesprovisionarAposFalha();
var
  Codigo: Integer;
  Restantes: String;
begin
  ProvisionamentoReprovado := True;

  Status('Desfazendo o provisionamento...');

  if not EncerrarProcesso('{#BandejaExe}') then
    Log('[PrintMonitor] AVISO: a bandeja não fechou durante a reversão.');

  if RegValueExists(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Run', '{#BandejaValorRun}') and
     (not RegDeleteValue(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Run', '{#BandejaValorRun}')) then
    Log('[PrintMonitor] AVISO: o valor da bandeja na Run key não pôde ser removido.');

  Exec(ExpandConstant('{app}\{#SetupExe}'), '--uninstall', '', SW_HIDE, ewWaitUntilTerminated, Codigo);
  Log('[PrintMonitor] Desprovisionamento após falha: código ' + IntToStr(Codigo) +
      '; bandeja fechada e fora da Run key.');

  { PRD-PMTRAY-04 (campo, 21/10/2026): depois de uma 3.2.0 desfeita, a bandeja seguiu viva na pasta e
    travou a cópia da versão seguinte. O --uninstall já parou e removeu o serviço; aqui se CONFIRMA que
    nenhum processo — Helper, bandeja reaberta, Bootstrapper, Setup.exe — continua rodando da pasta
    da instalação. }
  if EncerrarProcessosDaPasta(ExpandConstant('{app}'), ExpandConstant('{srcexe}'), Restantes) then
    Log('[PrintMonitor] Reversão: nenhum processo do PrintMonitor rodando de ' + ExpandConstant('{app}') + '.')
  else
    Log('[PrintMonitor] AVISO: reversão com processos ainda rodando de ' + ExpandConstant('{app}') + ': ' + Restantes);
end;

{ Executa a sequência de pós-instalação. Chamada em ssPostInstall — DEPOIS de os arquivos estarem
  no destino: registrar serviço apontando para executável ausente cria serviço quebrado que o SCM
  reinicia em laço. }
procedure ExecutarProvisionamento();
var
  Codigo: Integer;
  Comando, Mensagem, ArquivoDeResposta: String;
  Iniciou: Boolean;
begin
  ForceDirectories(ExpandConstant(PastaDadosPrintMonitor) + '\logs');

  InstalarQzTray();
  AplicarRegraDeFirewall();

  Status('Provisionando a estação (serviço, identidade, certificado e validação)...');

  { A saída do Setup.exe vai para arquivo: o wizard não mostra saída de processo, e o resumo por
    etapa é o que responde "por que essa estação não aparece no painel". A chave NÃO é escrita no
    log pelo Setup.exe (ele grava a configuração em variável de máquina, não em texto) e NÃO está
    na linha de comando: ela e os segredos do loopback vão no arquivo de resposta temporário, que é
    apagado logo depois da chamada, com sucesso ou falha. }
  ArquivoDeResposta := GravarArquivoDeResposta();
  Comando := '/C ""' + ExpandConstant('{app}\{#SetupExe}') + '" ' +
             ArgumentosDoProvisionamento(ArquivoDeResposta) + ' > "' + LogDoProvisionamento() + '" 2>&1"';

  Iniciou := Exec(ExpandConstant('{cmd}'), Comando, ExpandConstant('{app}'), SW_HIDE,
                  ewWaitUntilTerminated, Codigo);

  if (ArquivoDeResposta <> '') and (not DeleteFile(ArquivoDeResposta)) then
    Log('[PrintMonitor] AVISO: o arquivo de resposta temporário não pôde ser apagado agora; o Inno ' +
        'remove a pasta temporária ao final da instalação.');

  if not Iniciou then
  begin
    DesprovisionarAposFalha();
    RaiseException('Não foi possível iniciar o provisionamento (' + '{#SetupExe}' + ').' + #13#10 +
                   'A instalação foi interrompida e a estação não ficou com serviço registrado.');
    Exit;
  end;

  Log('[PrintMonitor] Provisionamento encerrado com código ' + IntToStr(Codigo) +
      '; log em ' + LogDoProvisionamento());

  ProvisionamentoComAviso := Codigo = CodigoSucessoComAviso;
  if ProvisionamentoComAviso then
    Log('[PrintMonitor] AVISO: provisionamento concluído com aviso (código ' + IntToStr(Codigo) +
        '); a instalação segue. Detalhe nas linhas [Aviso] de ' + LogDoProvisionamento());

  if (Codigo <> 0) and (Codigo <> CodigoSucessoComAviso) then
  begin
    if Codigo = 2 then
      Mensagem := 'O provisionamento foi cancelado.'
    else if Codigo = 3 then
      Mensagem := 'O provisionamento recusou os parâmetros (código 3): arquivo de resposta ilegível ou ' +
                  'valor inválido (origens/segredos do loopback). Nada foi gravado pela configuração.'
    else
      Mensagem := 'O provisionamento falhou (código ' + IntToStr(Codigo) + ').';

    DesprovisionarAposFalha();

    { Falhar aqui é o comportamento correto e deliberado: instalador "concluído" com estação muda
      é o pior desfecho possível. A mensagem aponta o log com o resumo por etapa. }
    RaiseException(Mensagem + #13#10#13#10 +
                   'O detalhe por etapa está em:' + #13#10 + LogDoProvisionamento() + #13#10#13#10 +
                   'A estação ficou SEM serviço, sem autostart do Helper e sem as variáveis de ' +
                   'máquina. Corrija a causa e execute o instalador novamente.');
    Exit;
  end;

  if ProvisionamentoComAviso then
    Status('Estação provisionada COM AVISO. Detalhe por etapa em ' + LogDoProvisionamento())
  else
    Status('Estação provisionada. Detalhe por etapa em ' + LogDoProvisionamento());

  { PRD-PMTRAY-05: o serviço já está rodando pelo --all (código 0 ou 4; as falhas saíram acima pelo
    RaiseException). SEMPRE — instalação nova ou upgrade, interativo ou silencioso — sobem agora, como o
    usuário original: QZ Tray → Helper (com o ambiente da máquina) → bandeja (no silencioso). Como
    LocalSystem, nada: tudo sobe no próximo logon. Confere o Helper e o loopback só como aviso. }
  IniciarProcessosDaSessao();
end;
