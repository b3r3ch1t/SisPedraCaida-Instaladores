{ ============================================================================================
   tefhub.iss — Elgin TEF HUB como pré-requisito: detecta e, quando ausente, BAIXA E INSTALA.

   ⚠️ Isto INVERTE a decisão D7 do épico `tefagent-installer-windows` ("Elgin TEF Web —
   pré-requisito verificado, NUNCA instalado"), por decisão expressa de quem publica o produto
   (15/10/2026). O que a D7 protegia e **continua valendo**: o repositório da Elgin não declara
   licença, então o `.exe` é baixado do endereço oficial do fornecedor **na máquina do cliente** —
   nunca embutido no nosso pacote (que ganharia ~396 MB de software de terceiro).

   ⚠️ A URL NÃO é a do GitHub "normal". Os `.exe` daquele repositório são **ponteiros de Git LFS
   de 134 bytes**: `raw.githubusercontent.com` devolve o ponteiro, o download "tem sucesso", grava
   134 bytes com nome de executável, e a falha só aparece na execução — com uma mensagem do Windows
   que não menciona LFS em lugar nenhum. Quem entrega o binário é `media.githubusercontent.com`.

   ⚠️ O SHA-256 abaixo é o publicado pelo PRÓPRIO ponteiro LFS do fornecedor, e o Inno o confere
   antes de a gente executar qualquer coisa: é executável de terceiro, elevado, vindo da rede.
   Divergiu, o download falha e nada é executado.

   Exige **Inno Setup 6.1+** (é de onde vêm `CreateDownloadPage`/`DownloadTemporaryFile`).
   ============================================================================================ }

#define TefHubVersao     "06.02.00"
#define TefHubArquivo    "64Elgin-TEFHUB-v06.02.00.exe"
#define TefHubUrl        "https://media.githubusercontent.com/media/ElginDeveloperCommunity/ElginTEFHUB/master/ELGIN%20TEF%20HUB/Instaladores%20Windows/64Elgin%20TEFHUB-v06.02.00.exe"
#define TefHubSha256     "306bef7a193a6b1d7d4e771da1ba7acb3c1fa43e50c42280d717f670a54ca977"
#define TefHubTamanhoMB  "396"

var
  PaginaDownloadTefHub: TDownloadWizardPage;

{ Callback de progresso do download. Devolver False cancelaria — o botão Cancelar da página já
  faz isso por conta própria. }
function AoProgredirDownloadTefHub(const Url, NomeArquivo: String;
  const Progresso, TotalProgresso: Int64): Boolean;
begin
  if TotalProgresso > 0 then
    PaginaDownloadTefHub.SetProgress(Progresso, TotalProgresso);

  Result := True;
end;

procedure CriarPaginaDownloadTefHub();
begin
  PaginaDownloadTefHub := CreateDownloadPage(
    'Pré-requisito: Elgin TEF HUB',
    'Baixando o instalador oficial da Elgin (cerca de {#TefHubTamanhoMB} MB). ' +
    'É ele que conversa com o pinpad deste terminal.',
    @AoProgredirDownloadTefHub);
end;

{ Rollout silencioso em vários terminais puxando ~396 MB cada um satura o link do cliente. O
  parâmetro é a válvula de escape de quem conhece a rede do balcão — e a ausência dele mantém o
  comportamento pedido: baixar e instalar quando faltar. }
function PularTefHub(): Boolean;
begin
  Result := Parametro('SEMTEFHUB', '0') = '1';
end;

{ Executa o instalador da Elgin.
  ⚠️ `Exec` + `ResultCode` conferido, NUNCA `[Run]`: o `[Run]` do Inno **ignora** o código de saída
  e o wizard diria "Concluído" com o pré-requisito ausente — é a armadilha #101a, já paga neste
  mesmo instalador.
  Os comutadores são os do Inno porque o produto da Elgin registra a desinstalação com o sufixo
  `_is1`, que é assinatura do próprio Inno. Se um release futuro trocar de empacotador, quem
  denuncia na hora é o `ResultCode` — e é por isso que ele é conferido em vez de presumido. }
function InstalarTefHub(const Caminho: String; var Codigo: Integer): Boolean;
begin
  Result := Exec(Caminho, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_SHOW,
                 ewWaitUntilTerminated, Codigo) and (Codigo = 0);
end;

{ Baixa o instalador para a pasta temporária do Setup. Devolve string vazia no sucesso, ou a razão
  da falha.
  ⚠️ Comentário de chaves NÃO aninha: escrever a constante tmp entre chaves aqui encerraria o
  comentário na chave de fechamento dela, e o resto da linha viraria código. }
function BaixarTefHub(var Caminho: String): String;
begin
  Result := '';
  Caminho := '';

  PaginaDownloadTefHub.Clear;
  PaginaDownloadTefHub.Add('{#TefHubUrl}', '{#TefHubArquivo}', '{#TefHubSha256}');
  PaginaDownloadTefHub.Show;

  try
    try
      PaginaDownloadTefHub.Download;
      Caminho := ExpandConstant('{tmp}\{#TefHubArquivo}');
    except
      Result := GetExceptionMessage;
    end;
  finally
    PaginaDownloadTefHub.Hide;
  end;
end;

{ Garante o pré-requisito. Devolve False só para SEGURAR o wizard na tela anterior quando o
  operador decide não seguir — falhar aqui não derruba a instalação do agente por conta própria:
  um terminal com o agente instalado e o TEF HUB pendente é recuperável (o técnico da Elgin passa
  depois); um wizard que aborta no meio deixa o balcão sem nada. }
function GarantirTefHub(): Boolean;
var
  Nome, Versao, Caminho, Falha, Mensagem: String;
  Codigo: Integer;
begin
  Result := True;

  if TefHubInstalado(Nome, Versao) then
  begin
    Log('[TefAgent] Elgin TEF HUB já instalado (' + Nome + ') — nada a baixar.');
    Exit;
  end;

  if PularTefHub() then
  begin
    Log('[TefAgent] Elgin TEF HUB ausente, mas /SEMTEFHUB=1 pediu para não baixar.');
    Exit;
  end;

  Log('[TefAgent] Elgin TEF HUB ausente: baixando {#TefHubArquivo} (~{#TefHubTamanhoMB} MB).');
  Falha := BaixarTefHub(Caminho);

  if Falha <> '' then
  begin
    Log('[TefAgent] Falha ao baixar o Elgin TEF HUB: ' + Falha);

    Mensagem := 'Não foi possível baixar o Elgin TEF HUB:' + #13#10 + Falha + #13#10#13#10 +
                'Causas comuns: o terminal está sem internet, ou a cota de banda do repositório ' +
                'do fornecedor se esgotou (o arquivo é servido por Git LFS).' + #13#10#13#10 +
                'A instalação do agente pode continuar — instale o TEF HUB depois por:' + #13#10 +
                '{#TefHubUrl}' + #13#10#13#10 +
                'Continuar a instalação do agente mesmo assim?';

    { Em modo silencioso o default (IDYES) vale: o rollout segue e a razão fica no log. }
    Result := SuppressibleMsgBox(Mensagem, mbError, MB_YESNO, IDYES) = IDYES;
    Exit;
  end;

  Log('[TefAgent] Download conferido (SHA-256 bateu). Executando o instalador da Elgin.');

  if InstalarTefHub(Caminho, Codigo) then
  begin
    { "Saiu com 0" não é "está instalado" — a mesma distinção que a #101d faz entre o `sc start`
      aceitar o comando e o serviço estar RUNNING. Quem confirma é o registro. }
    if TefHubInstalado(Nome, Versao) then
      Log('[TefAgent] Elgin TEF HUB instalado: ' + Nome)
    else
      Log('[TefAgent] ATENÇÃO: o instalador do TEF HUB saiu com 0 e o produto não aparece no ' +
          'registro — tratar como ausente no diagnóstico.');

    Exit;
  end;

  Log('[TefAgent] Instalador do Elgin TEF HUB terminou com o código ' + IntToStr(Codigo) + '.');

  { ⚠️ O `+` abre as linhas de continuação de propósito. O pré-processador do Inno trata como
    DIRETIVA toda linha cujo primeiro caractere não-branco é `#` — e `#13#10` no início de uma
    quebra de string reprova a compilação inteira com "Unknown preprocessor directive", sem
    nenhuma pista de que o problema é a indentação. }
  Mensagem := 'O instalador do Elgin TEF HUB terminou com o código ' + IntToStr(Codigo) + '.'
              + #13#10#13#10 + 'O arquivo baixado está em:' + #13#10 + Caminho
              + #13#10#13#10 + 'Você pode executá-lo à mão depois.'
              + #13#10#13#10 + 'Continuar a instalação do agente mesmo assim?';

  Result := SuppressibleMsgBox(Mensagem, mbError, MB_YESNO, IDYES) = IDYES;
end;
