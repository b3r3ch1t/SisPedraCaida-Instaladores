{ ============================================================================================
   tefhub.iss — Elgin TEF HUB e E1_Connect como pré-requisitos BLOQUEANTES: detecta e, quando
   falta algum, mostra onde baixar e NÃO instala o agente até que o requisito seja atendido.

   ⚠️ Isto DESFAZ a D7-bis do PRD-TEFHUB-01 ("ausente → baixa e instala", 15/10/2026) e volta à D7
   original — pré-requisito verificado, NUNCA instalado por nós (PRD-ELGPRE-01, 30/10/2026). Em campo
   o wizard TRAVAVA na instalação do TEF HUB e do E1_Connect: o pacote da Elgin encadeia os
   instaladores dos componentes (E1_Connect, E1_ETH_Service, providers), e o `/VERYSILENT` que
   passávamos ao instalador externo não governa o que cada componente faz com a janela dele. Com
   `ewWaitUntilTerminated` o nosso Setup esperava para sempre. Não reintroduza download nem `Exec` de
   instalador de terceiro aqui: a guarda TefAgentPreRequisitosElginGuardTests reprova.

   Por que BLOQUEAR e não só avisar: agente sem TEF HUB/E1_Connect é caixa que não processa cartão,
   e o "Concluído" do wizard esconderia isso (é o caixa mudo da #101a). Decisão do usuário: parar a
   instalação até o técnico instalar o produto da Elgin.

   ⚠️ Roda no InitializeSetup — antes de qualquer página e de copiar um arquivo — e por isso vale
   também no silencioso, onde página customizada não roda.
   ============================================================================================ }

{ A PASTA de instaladores do repositório oficial, não o `.exe`: os `.exe` dali são ponteiros de Git
  LFS (134 bytes pelo `raw`), e a pasta mostra as versões x64/x86 e as notas. O E1_Connect vem dentro
  do pacote do TEF HUB — um link só para os dois. }
#define ElginDownloadUrl "https://github.com/ElginDeveloperCommunity/ElginTEFHUB/tree/master/ELGIN%20TEF%20HUB/Instaladores%20Windows"

{ Lista, um por linha, os produtos da Elgin que faltam neste terminal; vazia quando estão todos. }
function PreRequisitosElginAusentes(): String;
var
  Nome, Versao: String;
begin
  Result := '';

  if TefHubInstalado(Nome, Versao) then
    Log('[TefAgent] Elgin TEF HUB instalado: ' + Nome)
  else
    Result := Result + '   • Elgin TEF HUB' + #13#10;

  if E1ConnectInstalado(Nome, Versao) then
    Log('[TefAgent] Elgin E1_Connect instalado: ' + Nome)
  else
    Result := Result + '   • Elgin E1_Connect (instalado junto com o TEF HUB)' + #13#10;
end;

{ Abre a página de download no navegador do operador. `AsOriginalUser`: o Setup roda elevado, e o
  navegador aberto como administrador nem sempre é o do operador (nem tem a sessão dele). }
procedure AbrirPaginaDownloadElgin();
var
  Codigo: Integer;
begin
  if not ShellExecAsOriginalUser('open', '{#ElginDownloadUrl}', '', '', SW_SHOWNORMAL, ewNoWait, Codigo) then
    Log('[TefAgent] Não foi possível abrir o navegador (' + SysErrorMessage(Codigo) + ').');
end;

{ Garante os pré-requisitos da Elgin. Devolve False para o InitializeSetup encerrar o instalador
  (código de saída 1) — no silencioso, na primeira ausência; no interativo, quando o operador cancela.
  No interativo o diálogo fica em laço: o técnico instala o TEF HUB com ele aberto e clica em
  "Verificar novamente", sem reabrir o nosso instalador. }
function GarantirPreRequisitosElgin(): Boolean;
var
  Ausentes, Texto: String;
  Escolha: Integer;
begin
  Result := True;

  { Significava "não baixar o TEF HUB"; nada é baixado agora. Aceito para não quebrar script de
    rollout, mas NÃO pula a checagem — pular é exatamente o caixa mudo que o bloqueio evita. }
  if Parametro('SEMTEFHUB', '0') = '1' then
    Log('[TefAgent] /SEMTEFHUB=1 ignorado: o instalador não baixa mais o TEF HUB, e a checagem ' +
        'dos pré-requisitos da Elgin não é opcional.');

  Ausentes := PreRequisitosElginAusentes();

  while Ausentes <> '' do
  begin
    Log('[TefAgent] BLOQUEIO: pré-requisito da Elgin ausente:' + #13#10 + Ausentes);

    Texto := 'Este terminal ainda não tem:' + #13#10 + Ausentes
             + #13#10 + 'Baixe e instale o Elgin TEF HUB (ele instala o E1_Connect junto) pela página '
             + 'oficial da Elgin:' + #13#10 + '{#ElginDownloadUrl}'
             + #13#10#13#10 + 'O agente TEF só é instalado com os dois presentes neste terminal.';

    { Em /SUPPRESSMSGBOXES a caixa não aparece; o log e o código de saída levam a razão. }
    if WizardSilent() then
    begin
      SuppressibleMsgBox('Instalação interrompida.' + #13#10#13#10 + Texto, mbCriticalError, MB_OK, IDOK);
      Result := False;
      Exit;
    end;

    { ⚠️ O array dos rótulos não pode abrir linha: o compilador lê toda linha iniciada por colchete
      como cabeçalho de seção ("Invalid section tag"), mesmo dentro do código. }
    Escolha := TaskDialogMsgBox('Pré-requisito da Elgin ausente',
      Texto + #13#10#13#10 + 'Depois de instalar, clique em "Verificar novamente".',
      mbError, MB_YESNOCANCEL, ['&Abrir a página de download'#13#10'Abre o endereço acima no navegador.',
      '&Verificar novamente'#13#10'Use depois de instalar o Elgin TEF HUB.'], 0);

    if Escolha = IDYES then
      AbrirPaginaDownloadElgin()
    else if Escolha <> IDNO then
    begin
      Log('[TefAgent] Instalação cancelada pelo operador com o pré-requisito da Elgin ausente.');
      Result := False;
      Exit;
    end;

    Ausentes := PreRequisitosElginAusentes();
  end;
end;
