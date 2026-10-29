using System.Text.RegularExpressions;
using SisPedraCaida.PrintMonitor.Core.Constants;
using SisPedraCaida.PrintMonitor.Core.Options;
using SisPedraCaida.PrintMonitor.Core.Provisioning;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Guardas do <b>upgrade por instalador</b> do PrintMonitor, na política do agente TEF (PRD-PMTRAY-03,
/// <c>installer/printmonitor/upgrade.iss</c>).
/// </summary>
/// <remarks>
/// O <c>.iss</c> só roda numa estação real. Estas guardas amarram ao C# o que ele precisa espelhar (nomes de
/// executável e de variável de máquina) e travam as decisões que, revertidas, só apareceriam em campo: serviço
/// copiado por cima ainda vivo, bandeja/Helper travando as DLLs, chave da estação apagada no upgrade, downgrade
/// silencioso.
/// </remarks>
public class InstaladorUpgradeGuardTests
{
    private static readonly string PastaDoInstalador =
        Path.Combine(Raizes.Instaladores, "installer", "printmonitor");

    private static string Ler(string arquivo) => File.ReadAllText(Path.Combine(PastaDoInstalador, arquivo));

    /// <summary>Corpo de uma função/procedimento Pascal do <c>.iss</c> (até o <c>end;</c> na coluna 0).</summary>
    private static string Corpo(string fonte, string assinatura)
    {
        var achado = Regex.Match(fonte, Regex.Escape(assinatura) + @"[\s\S]*?\nend;");
        Assert.True(achado.Success, $"'{assinatura}' não encontrado.");
        return achado.Value;
    }

    [Fact]
    public void AppId_EhEstavel_EProprio_ELidoPelaChaveDeDesinstalacao()
    {
        const string appId = "8B6F2C41-77F3-4B2E-9E5A-1D0C4A9E7B31";

        // Trocar o AppId faz o pacote novo não reconhecer o antigo: duas entradas e dois layouts brigando pelo serviço.
        Assert.Contains("AppId={{" + appId + "}", Ler("PrintMonitor.iss"), StringComparison.Ordinal);
        Assert.Contains(@"Uninstall\{" + appId + "}_is1", Ler("checks.iss"), StringComparison.Ordinal);

        var tef = File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", "tefagent", "TefAgent.iss"));
        Assert.DoesNotContain(appId, tef, StringComparison.Ordinal);
    }

    [Fact]
    public void MesmaPasta_EhReutilizada_ESemPaginaDeDiretorioNoUpgrade()
    {
        var principal = Ler("PrintMonitor.iss");

        Assert.Matches(@"(?m)^UsePreviousAppDir=yes\s*$", principal);
        Assert.Matches(@"(?m)^DisableDirPage=auto\s*$", principal);
        Assert.Contains(@"DefaultDirName={autopf}\SisPedraCaida\PrintMonitor", principal, StringComparison.Ordinal);
    }

    [Fact]
    public void Files_TemIgnoreversion_ECloseApplicationsDesligado()
    {
        var principal = Ler("PrintMonitor.iss");

        Assert.Matches(@"Source: ""\{#PublishDir\}\\\*""; DestDir: ""\{app\}""; \\\s*\r?\n\s*Flags: recursesubdirs createallsubdirs ignoreversion", principal);

        // Quem para o serviço é o PrepararUpgrade, na ordem certa; o Inno fechando processos por conta própria atropelaria.
        Assert.Matches(@"(?m)^CloseApplications=no\s*$", principal);
    }

    [Fact]
    public void ExecutaveisDoUpgrade_SaoOsMesmosDoInstallOptions()
    {
        var principal = Ler("PrintMonitor.iss");
        var opcoes = new InstallOptions();

        Assert.Contains($"#define ServicoNome \"{opcoes.ServiceName}\"", principal, StringComparison.Ordinal);
        Assert.Contains($"#define ServicoExe \"{opcoes.ServiceExecutableName}\"", principal, StringComparison.Ordinal);
        Assert.Contains($"#define HelperExe \"{opcoes.HelperExecutableName}\"", principal, StringComparison.Ordinal);
        Assert.Contains($"#define BootstrapperExe \"{opcoes.BootstrapperExecutableName}\"", principal, StringComparison.Ordinal);
        Assert.Contains($"#define BandejaExe \"{opcoes.TrayExecutableName}\"", principal, StringComparison.Ordinal);
        Assert.Contains($"QzTrayImagem = '{QzTrayConstants.ProcessName}.exe';", Ler("checks.iss"), StringComparison.Ordinal);
    }

    [Fact]
    public void PrepareToInstall_PrepararUpgrade_AntesDeCopiar()
    {
        var principal = Ler("PrintMonitor.iss");
        var preparar = Corpo(principal, "function PrepareToInstall(var NeedsRestart: Boolean): String;");

        Assert.Contains("Result := PrepararUpgrade();", preparar, StringComparison.Ordinal);

        // upgrade.iss antes do provisioning.iss: o provisionamento chama IniciarProcessosDaSessao.
        var upgrade = principal.IndexOf("#include \"upgrade.iss\"", StringComparison.Ordinal);
        var provisionamento = principal.IndexOf("#include \"provisioning.iss\"", StringComparison.Ordinal);
        Assert.True(upgrade > 0 && upgrade < provisionamento, "upgrade.iss precisa ser incluído antes do provisioning.iss.");

        // processos.iss (PRD-PMTRAY-04) antes dos dois: ambos fecham processos por imagem e por caminho.
        var processos = principal.IndexOf("#include \"processos.iss\"", StringComparison.Ordinal);
        Assert.True(processos > 0 && processos < upgrade, "processos.iss precisa ser incluído antes do upgrade.iss.");
    }

    [Fact]
    public void ParadaDoServico_EhConfirmadaNoSCM_EServicoPresoEhDerrubadoSemRecusar()
    {
        var upgrade = Ler("upgrade.iss");
        var parar = Corpo(upgrade, "function PararServicoEConfirmar(): Boolean;");

        // net stop espera; o laço confere STOPPED no SCM (#101d: comando aceito não é parado) e o processo sai.
        Assert.Contains("'stop \"{#ServicoNome}\"'", parar, StringComparison.Ordinal);
        Assert.Contains("ServicoParado()", parar, StringComparison.Ordinal);
        Assert.Contains("AguardarProcessoSumir('{#ServicoExe}'", parar, StringComparison.Ordinal);
        Assert.Contains("sc query \"{#ServicoNome}\" | find /I \"STOPPED\"", upgrade, StringComparison.Ordinal);

        // PRD-PMTRAY-04 (decisão do usuário: parar o serviço e sobrescrever tudo): serviço preso é DERRUBADO, com as
        // ações de recuperação zeradas antes — senão o SCM o religa em 1 min, no meio da cópia.
        var zera = parar.IndexOf("'failure \"{#ServicoNome}\" reset= 0 actions= \"\"'", StringComparison.Ordinal);
        var derruba = parar.IndexOf("EncerrarProcesso('{#ServicoExe}');", zera < 0 ? 0 : zera, StringComparison.Ordinal);
        Assert.True(zera >= 0 && derruba > zera, "Serviço preso: zerar as ações de recuperação e só então derrubar o processo.");

        // Nada de recusa: o PrepararUpgrade só devolve vazio.
        var preparar = Corpo(upgrade, "function PrepararUpgrade(): String;");
        Assert.Single(Regex.Matches(preparar, @"Result :="));
        Assert.Contains("Result := '';", preparar, StringComparison.Ordinal);
    }

    [Fact]
    public void Upgrade_FechaTudoDaPasta_SemDependerDeInstalacaoAnterior_NaOrdemCerta()
    {
        // Campo, 21/10/2026: 3.2.0 reprovada e desfeita (sem registro), bandeja órfã viva em Program Files, e o 3.3.0
        // parou em "DeleteFile falhou; código 5" na Accessibility.dll.
        var upgrade = Ler("upgrade.iss");
        var preparar = Corpo(upgrade, "function PrepararUpgrade(): String;");

        var anotaHelper = preparar.IndexOf("HelperEstavaAberto := ProcessoEmExecucao('{#HelperExe}');", StringComparison.Ordinal);
        var anotaBandeja = preparar.IndexOf("BandejaEstavaAberta := ProcessoEmExecucao('{#BandejaExe}');", StringComparison.Ordinal);
        var anotaQz = preparar.IndexOf("QzEstavaAberto := QzTrayEmExecucao();", StringComparison.Ordinal);
        var bootstrapper = preparar.IndexOf("EncerrarProcesso('{#BootstrapperExe}')", StringComparison.Ordinal);
        var servico = preparar.IndexOf("PararServicoEConfirmar()", StringComparison.Ordinal);
        var bandeja = preparar.IndexOf("EncerrarProcesso('{#BandejaExe}')", StringComparison.Ordinal);
        var helper = preparar.IndexOf("EncerrarProcesso('{#HelperExe}')", StringComparison.Ordinal);
        var pasta = preparar.IndexOf("EncerrarProcessosDaPasta(Pasta, ExpandConstant('{srcexe}'), Restantes)", StringComparison.Ordinal);

        Assert.All(new[] { anotaHelper, anotaBandeja, anotaQz, bootstrapper, servico, bandeja, helper, pasta }, i => Assert.True(i >= 0));
        Assert.True(anotaHelper < bootstrapper && anotaBandeja < bootstrapper && anotaQz < bootstrapper,
            "O estado de Helper, bandeja e QZ Tray é anotado ANTES de fechar qualquer coisa.");
        Assert.True(bootstrapper < servico && servico < bandeja && bandeja < helper && helper < pasta,
            "Ordem: Bootstrapper → serviço parado e confirmado → bandeja → Helper → todo processo rodando de {app}.");
        Assert.Contains("Pasta := ExpandConstant('{app}');", preparar, StringComparison.Ordinal);

        // A detecção de instalação anterior só informa o log: nada do fechamento fica atrás dela.
        Assert.DoesNotMatch(@"if\s+(not\s+)?InstalacaoAnteriorDetectada", preparar);
        Assert.DoesNotMatch(@"if\s+(not\s+)?InstalacaoAnteriorPresente\(\)", preparar);
        Assert.DoesNotContain("ServicoJaRegistrado()", preparar, StringComparison.Ordinal);

        var principal = Ler("PrintMonitor.iss");
        var prepareToInstall = Corpo(principal, "function PrepareToInstall(var NeedsRestart: Boolean): String;");
        Assert.DoesNotContain("InstalacaoAnterior", prepareToInstall, StringComparison.Ordinal);
    }

    [Fact]
    public void Processos_SaoAchadosPorCaminhoViaWmi_EEncerradosPorPid_ComConfirmacao()
    {
        var processos = Ler("processos.iss");
        var wmi = Corpo(processos, "function ProcessosDaPastaPorWmi(");

        // Por CAMINHO, não por nome: alcança órfão de versão desfeita e processo de outra sessão. Via COM do próprio
        // Inno — sem PowerShell e sem binário já instalado (o Setup.exe anterior pode não existir).
        Assert.Contains("CreateOleObject('WbemScripting.SWbemLocator')", wmi, StringComparison.Ordinal);
        Assert.Contains("FROM Win32_Process WHERE ExecutablePath LIKE", wmi, StringComparison.Ordinal);
        Assert.Contains("CaminhoNaPasta(Caminho, Pasta)", wmi, StringComparison.Ordinal);
        Assert.Contains("'/f /pid ' + Pid", wmi, StringComparison.Ordinal);
        Assert.DoesNotContain("powershell", Regex.Replace(processos, @"\{(?!#)[^}]*\}", string.Empty), StringComparison.OrdinalIgnoreCase);

        // Confirma a saída num laço e tem reserva sem WMI; poupa o próprio instalador/desinstalador.
        var encerrar = Corpo(processos, "function EncerrarProcessosDaPasta(Pasta, Ignorar: String; var Restantes: String): Boolean;");
        Assert.Contains("ProcessosDaPastaPorWmi(Pasta, Ignorar,", encerrar, StringComparison.Ordinal);
        Assert.Contains("ProcessosDaPastaPorNome(Pasta, True, Restantes)", encerrar, StringComparison.Ordinal);
        Assert.Contains("Sleep(500);", encerrar, StringComparison.Ordinal);
        Assert.Contains("(Pos('UNINS', Nome) = 1)", Corpo(processos, "function ProcessoPoupado(Caminho, Ignorar: String): Boolean;"),
            StringComparison.Ordinal);

        // Prefixo com a barra final: C:\X\PrintMonitorAntigo não casa com C:\X\PrintMonitor.
        Assert.Contains("AnsiUppercase(AddBackslash(Pasta))", Corpo(processos, "function CaminhoNaPasta(Caminho, Pasta: String): Boolean;"),
            StringComparison.Ordinal);
    }

    [Fact]
    public void ProcessoEmExecucao_UsaCsv_PorqueATabelaDoTasklistTruncaONome()
    {
        // A tabela do tasklist corta a imagem em 25 caracteres: "SisPedraCaida.PrintMonito" nunca casava com o find, e o
        // EncerrarProcesso nem chamava o taskkill — a bandeja órfã do campo sobreviveu assim.
        var opcoes = new InstallOptions();
        Assert.All(
            new[] { opcoes.TrayExecutableName, opcoes.HelperExecutableName, opcoes.ServiceExecutableName, opcoes.BootstrapperExecutableName },
            nome => Assert.True(nome.Length > 25, $"{nome} cabe na tabela; a guarda perdeu o sentido."));

        var em = Corpo(Ler("processos.iss"), "function ProcessoEmExecucao(Imagem: String): Boolean;");
        Assert.Contains("'\" /FO CSV /NH | find /I \"' + Imagem", em, StringComparison.Ordinal);
        Assert.DoesNotContain("function ProcessoEmExecucao", Ler("upgrade.iss"), StringComparison.Ordinal);
    }

    [Fact]
    public void Files_DaPastaDoApp_TemRestartreplace_ENaoHaRecusaPorArquivoEmUso()
    {
        // Decisão do usuário (21/10/2026): sobrescrever TODOS os arquivos. Arquivo ainda travado depois do fechamento é
        // trocado no próximo reinício, sem a caixa Tentar novamente / Ignorar / Cancelar.
        var principal = Ler("PrintMonitor.iss");
        var secaoFiles = Regex.Match(principal, @"^\[Files\][\s\S]*?(?=^\[)", RegexOptions.Multiline).Value;
        var entradas = Regex.Matches(secaoFiles, @"(?m)^Source:(?:[^\r\n]*\\\r?\n)*[^\r\n]*")
            .Select(m => m.Value)
            .Where(e => e.Contains("DestDir: \"{app}", StringComparison.Ordinal))
            .ToArray();

        Assert.NotEmpty(entradas);
        Assert.All(entradas, e =>
        {
            Assert.Contains("ignoreversion", e, StringComparison.Ordinal);
            Assert.Contains("restartreplace", e, StringComparison.Ordinal);
            Assert.Contains("uninsrestartdelete", e, StringComparison.Ordinal);
        });
    }

    [Fact]
    public void Reversao_EDesinstalacao_TambemFecham_TudoDaPasta()
    {
        var provisionamento = Ler("provisioning.iss");
        var reverter = Corpo(provisionamento, "procedure DesprovisionarAposFalha();");
        var desinstala = reverter.IndexOf("'--uninstall'", StringComparison.Ordinal);
        var varre = reverter.IndexOf("EncerrarProcessosDaPasta(ExpandConstant('{app}')", StringComparison.Ordinal);
        Assert.True(desinstala >= 0 && varre > desinstala, "Reversão: depois do --uninstall, confirmar que nada roda de {app}.");

        // Desinstalação: usUninstall vem antes do [UninstallRun] e da remoção dos arquivos.
        var principal = Ler("PrintMonitor.iss");
        var passo = Corpo(principal, "procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);");
        Assert.Matches(@"if CurUninstallStep = usUninstall then\s*LimparProcessosParaDesinstalar\(\);", passo);

        var limpar = Corpo(Ler("upgrade.iss"), "procedure LimparProcessosParaDesinstalar();");
        var servico = limpar.IndexOf("PararServicoEConfirmar()", StringComparison.Ordinal);
        var bandeja = limpar.IndexOf("EncerrarProcesso('{#BandejaExe}')", StringComparison.Ordinal);
        var helper = limpar.IndexOf("EncerrarProcesso('{#HelperExe}')", StringComparison.Ordinal);
        var pasta = limpar.IndexOf("EncerrarProcessosDaPasta(Pasta, ExpandConstant('{uninstallexe}'), Restantes)", StringComparison.Ordinal);
        Assert.True(servico >= 0 && servico < bandeja && bandeja < helper && helper < pasta,
            "Desinstalação: serviço → bandeja → Helper → todo processo da pasta, poupando o próprio desinstalador.");
    }

    [Fact]
    public void FluxoDeFechamento_NuncaAbreMsgBox()
    {
        // MsgBox aparece mesmo em /VERYSILENT e travaria invisível uma distribuição como LocalSystem. O fluxo de
        // fechamento (upgrade, reversão, desinstalação) não abre caixa nenhuma: tudo vai para o log.
        static string SemComentarios(string fonte) => Regex.Replace(fonte, @"\{(?!#)[^}]*\}", string.Empty);

        foreach (var arquivo in new[] { "processos.iss", "upgrade.iss", "provisioning.iss" })
        {
            Assert.DoesNotContain("MsgBox(", SemComentarios(Ler(arquivo)), StringComparison.Ordinal);
        }

        var principal = Ler("PrintMonitor.iss");
        foreach (var assinatura in new[]
                 {
                     "function PrepareToInstall(var NeedsRestart: Boolean): String;",
                     "procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);",
                 })
        {
            Assert.DoesNotContain("MsgBox(", SemComentarios(Corpo(principal, assinatura)), StringComparison.Ordinal);
        }
    }

    [Fact]
    public void Upgrade_NaoRodaODesinstaladorAnterior_NemOUninstallDoSetup()
    {
        // O --uninstall do PrintMonitor APAGA as variáveis de máquina (chave, endereço, feed): rodá-lo num upgrade
        // — como o TEF faz com o dele, que preserva a configuração — deixaria a estação sem a chave.
        var upgrade = Ler("upgrade.iss");
        var codigo = string.Join('\n', upgrade.Split('\n').Where(l => !l.TrimStart().StartsWith('{') && !l.TrimStart().StartsWith('•')));

        Assert.DoesNotContain("UninstallString", upgrade, StringComparison.Ordinal);
        Assert.DoesNotContain("'--uninstall'", upgrade, StringComparison.Ordinal);
        Assert.DoesNotContain("sc.exe'), 'delete", upgrade, StringComparison.Ordinal);
        Assert.DoesNotContain("RemoverInstalacaoAnterior", codigo, StringComparison.Ordinal);

        var preparar = Corpo(Ler("PrintMonitor.iss"), "function PrepareToInstall(var NeedsRestart: Boolean): String;");
        Assert.DoesNotContain("--uninstall", preparar, StringComparison.Ordinal);
    }

    [Fact]
    public void ProgramData_EVariaveisDeMaquina_SaoPreservados()
    {
        var principal = Ler("PrintMonitor.iss");
        var linhas = principal.Split('\n').Where(l => !l.TrimStart().StartsWith(';')).ToArray();

        // Nada de [InstallDelete]/[UninstallDelete]/[Dirs] — e nenhuma entrada ativa apontando para {commonappdata}.
        Assert.DoesNotContain(linhas, l => Regex.IsMatch(l, @"^\[(InstallDelete|UninstallDelete|Dirs)\]"));
        Assert.DoesNotContain(linhas, l => l.Contains("{commonappdata}", StringComparison.OrdinalIgnoreCase)
                                          && (l.Contains("Type: filesandordirs", StringComparison.OrdinalIgnoreCase)
                                              || l.Contains("Type: files", StringComparison.OrdinalIgnoreCase)));

        foreach (var arquivo in new[] { "checks.iss", "pages.iss", "provisioning.iss", "upgrade.iss", "processos.iss" })
        {
            var fonte = Ler(arquivo);
            Assert.DoesNotContain("DelTree(", fonte, StringComparison.Ordinal);
            Assert.DoesNotContain("RegDeleteValue(HKLM, ChaveAmbienteMaquina", fonte, StringComparison.Ordinal);
            Assert.DoesNotContain(fonte.Split('\n'), l => l.Contains("DeleteFile", StringComparison.Ordinal)
                                                          && l.Contains("PastaDados", StringComparison.Ordinal));
        }
    }

    [Fact]
    public void ValoresIniciais_ReleemOGravadoNaEstacao_AntesDoPadraoDoPacote()
    {
        var pages = Ler("pages.iss");

        // Antes, o padrão do pacote vencia o gravado e o --dashboard-url (sempre presente) sobrescrevia, num upgrade
        // silencioso, o endereço que o operador editou no "Configurar PrintMonitor".
        Assert.Matches(
            @"ValorUrl := LerDoArquivoDeConfiguracao\(Arquivo, 'DashboardUrl'\);\s*" +
            @"if ValorUrl = '' then\s*ValorUrl := Parametro\('DASHBOARDURL', ''\);\s*" +
            @"if ValorUrl = '' then\s*ValorUrl := UrlGravada\(\);\s*" +
            @"if ValorUrl = '' then\s*ValorUrl := '\{#DashboardUrlPadrao\}';",
            pages);
        Assert.Matches(
            @"ValorAmbiente := Parametro\('ENVIRONMENTNAME', ''\);\s*" +
            @"if ValorAmbiente = '' then\s*ValorAmbiente := VariavelDeMaquina\(VarAmbiente\);\s*" +
            @"if ValorAmbiente = '' then\s*ValorAmbiente := '\{#AmbientePadrao\}';",
            pages);

        // Os nomes relidos são os que o Setup.exe grava.
        Assert.Contains($"VarDashboardUrl = '{StationEnvironmentVariables.DashboardUrl}';", pages, StringComparison.Ordinal);
        Assert.Contains($"VarChaveApi = '{StationEnvironmentVariables.ApiKey}';", pages, StringComparison.Ordinal);
        Assert.Contains($"VarAmbiente = '{StationEnvironmentVariables.Environment}';", pages, StringComparison.Ordinal);

        // A chave não é relida nem posta na linha de comando: ausente, o Setup.exe preserva a gravada.
        Assert.DoesNotContain("ValorChave := VariavelDeMaquina", pages, StringComparison.Ordinal);
        Assert.Contains("(mantida — a já gravada nesta estação)", pages, StringComparison.Ordinal);
    }

    [Fact]
    public void Downgrade_EhBloqueado_ComAMensagemDoTef_EAMesmaVersaoPassa()
    {
        var principal = Ler("PrintMonitor.iss");
        var tef = File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", "tefagent", "TefAgent.iss"));
        var inicio = Corpo(principal, "function InitializeSetup(): Boolean;");

        // Só versão instalada MAIOR bloqueia (> 0): a mesma versão reinstala.
        const string comparacao = "(VersaoInstalada <> '') and (CompareVersaoInstalada(VersaoInstalada, '{#AppVersion}') > 0)";
        Assert.Contains(comparacao, inicio, StringComparison.Ordinal);
        Assert.Contains(comparacao, tef, StringComparison.Ordinal);

        // Mesma mensagem do TEF, trocando "terminal" por "estação".
        foreach (var trecho in new[]
                 {
                     "'Uma versão mais recente do ' + '{#AppNome}' + ' já está instalada nest",
                     "Instalar a versão {#AppVersion} por cima faria ",
                     "'Desinstale a versão atual antes, se a regressão for intencional.'",
                 })
        {
            Assert.Contains(trecho, inicio, StringComparison.Ordinal);
            Assert.Contains(trecho, tef, StringComparison.Ordinal);
        }

        // Recusa antes do wizard e falha no silencioso em vez de travar numa caixa invisível.
        Assert.Contains("SuppressibleMsgBox(Mensagem, mbError, MB_OK, IDOK);", inicio, StringComparison.Ordinal);
        Assert.Contains("Log('[PrintMonitor] BLOQUEIO (downgrade): ' + Mensagem);", inicio, StringComparison.Ordinal);
        Assert.Matches(@"SuppressibleMsgBox\(Mensagem, mbError, MB_OK, IDOK\);\s*Result := False;", inicio);
    }

    [Fact]
    public void Inicio_DepoisDoProvisionamento_SempreQzHelperEBandeja_ComoUsuarioOriginal()
    {
        // Campo, 21/10/2026 (3.4.0): serviço rodando, mas Helper e QZ Tray não — a reabertura só valia para o que já
        // estava aberto, e o Helper só subia no próximo logon. PRD-PMTRAY-05: sobem SEMPRE.
        var upgrade = Ler("upgrade.iss");
        var provisionamento = Ler("provisioning.iss");
        var executar = Corpo(provisionamento, "procedure ExecutarProvisionamento();");

        // Depois do serviço (--all) provisionado com sucesso — a última mensagem de status do provisionamento.
        var provisionada = executar.IndexOf("Status('Estação provisionada. Detalhe por etapa em '", StringComparison.Ordinal);
        var iniciar = executar.IndexOf("IniciarProcessosDaSessao();", StringComparison.Ordinal);
        Assert.True(provisionada >= 0 && iniciar > provisionada, "IniciarProcessosDaSessao vem depois do provisionamento, no fim dele.");
        Assert.DoesNotContain("ReabrirProcessosDaSessao", upgrade + provisionamento, StringComparison.Ordinal);

        var corpo = Corpo(upgrade, "procedure IniciarProcessosDaSessao();");
        var sistema = corpo.IndexOf("if RodandoComoSistema() then", StringComparison.Ordinal);
        var qz = corpo.IndexOf("AbrirComoUsuarioOriginal(CaminhoDoQzTray()", StringComparison.Ordinal);
        var helper = corpo.IndexOf("AbrirComoUsuarioOriginal(ExpandConstant('{app}\\{#HelperExe}'), ArgumentoAmbienteDaMaquina",
            StringComparison.Ordinal);
        var bandeja = corpo.IndexOf("AbrirComoUsuarioOriginal(ExpandConstant('{app}\\{#BandejaExe}')", StringComparison.Ordinal);
        Assert.True(sistema >= 0 && sistema < qz && qz < helper && helper < bandeja,
            "LocalSystem sai antes de tudo; ordem de início: QZ Tray → Helper (com o ambiente da máquina) → bandeja.");

        // SEMPRE: a decisão não depende mais do que estava aberto antes da cópia — só de já estar rodando.
        Assert.DoesNotContain("EstavaAbert", corpo, StringComparison.Ordinal);
        Assert.Contains("if QzTrayEmExecucao() then", corpo, StringComparison.Ordinal);
        Assert.DoesNotContain("ProcessoEmExecucao(QzTrayImagem)", corpo, StringComparison.Ordinal);
        Assert.Contains("ProcessoEmExecucao('{#HelperExe}')", corpo, StringComparison.Ordinal);
        Assert.Contains("ProcessoEmExecucao('{#BandejaExe}')", corpo, StringComparison.Ordinal);

        // Bandeja: por código no silencioso; no interativo pela caixa da tela final (runasoriginaluser), que vem depois.
        Assert.Contains("if WizardSilent() then", corpo, StringComparison.Ordinal);
        var secaoRun = Regex.Match(Ler("PrintMonitor.iss"), @"^\[Run\][\s\S]*?(?=^\[)", RegexOptions.Multiline).Value;
        Assert.Contains("Flags: runasoriginaluser nowait postinstall skipifsilent", secaoRun, StringComparison.Ordinal);

        // Sem elevação: só ExecAsOriginalUser, nunca Exec direto do instalador elevado.
        Assert.Contains("ExecAsOriginalUser(Executavel, Parametros", upgrade, StringComparison.Ordinal);
        Assert.DoesNotMatch(@"(?<!AsOriginalUser\()\bExec\(Executavel", upgrade);
    }

    [Fact]
    public void Helper_SobeComOAmbienteDaMaquina_ENaoComOHerdadoDoInstalador()
    {
        // O processo original do Inno nasceu antes do --all: o filho herdaria o ambiente SEM as variáveis novas e o
        // loopback subiria sem as origens. O Helper relê do registro quando recebe o argumento.
        var upgrade = Ler("upgrade.iss");

        Assert.Contains("ArgumentoAmbienteDaMaquina = '--ambiente-da-maquina';", upgrade, StringComparison.Ordinal);
        Assert.Single(Regex.Matches(upgrade, @"\{#HelperExe\}'\), ArgumentoAmbienteDaMaquina"));

        // Nenhum segredo nem variável pela linha de comando, nem atalhos frágeis.
        // (o comentário explica por que não; o que não pode é um literal Pascal chamando um deles).
        Assert.DoesNotMatch(@"(?i)'[^'\r\n]*(explorer\.exe|schtasks)", upgrade);
        Assert.DoesNotMatch(@"ExecAsOriginalUser\([^;]*set\s", upgrade);

        // A bandeja não precisa: lê a configuração direto das variáveis de máquina, não do ambiente do processo.
        var leitor = File.ReadAllText(Path.Combine(Raizes.Backend, "src", "SisPedraCaida.PrintMonitor.Setup",
            "Diagnostics", "ConfiguracaoDaEstacao.cs"));
        Assert.Contains("GetMachineScoped(", leitor, StringComparison.Ordinal);

        // Os nomes que a conferência do loopback lê espelham o C#.
        Assert.Contains("VarLoopbackLigado = '" + StationEnvironmentVariables.LoopbackEnabled + "';", upgrade, StringComparison.Ordinal);
        Assert.Contains("VarLoopbackPorta = '" + StationEnvironmentVariables.LoopbackPort + "';", upgrade, StringComparison.Ordinal);
        Assert.Contains("PortaLoopbackPadrao = '" + new LoopbackPrintOptions().Port + "';", upgrade, StringComparison.Ordinal);
    }

    [Fact]
    public void Conferencia_DoHelperEDoLoopback_SoAvisa_NuncaReprova()
    {
        var upgrade = Ler("upgrade.iss");
        var conferir = Corpo(upgrade, "procedure ConferirHelperELoopback();");

        Assert.Contains("ProcessoEmExecucao('{#HelperExe}')", conferir, StringComparison.Ordinal);
        Assert.Contains("ConsultarLoopback(Porta, Origem)", conferir, StringComparison.Ordinal);
        Assert.Contains("'/identidade'", Corpo(upgrade, "function ConsultarLoopback(Porta, Origem: String): Integer;"),
            StringComparison.Ordinal);

        // Aviso, nunca falha: nada de RaiseException, MsgBox ou desprovisionamento no início da sessão.
        var sessao = upgrade[upgrade.IndexOf("Início na sessão do usuário (PRD-PMTRAY-05)", StringComparison.Ordinal)..];
        Assert.DoesNotContain("RaiseException", sessao, StringComparison.Ordinal);
        Assert.DoesNotContain("MsgBox", sessao, StringComparison.Ordinal);
        Assert.DoesNotContain("DesprovisionarAposFalha", sessao, StringComparison.Ordinal);

        // A tela final mostra o resultado, e a orientação de "próximo logon" saiu dela.
        var final = Corpo(Ler("PrintMonitor.iss"), "procedure CurPageChanged(CurPageID: Integer);");
        Assert.Contains("ResumoProcessosDaSessao()", final, StringComparison.Ordinal);
        Assert.DoesNotContain("próximo logon", final, StringComparison.Ordinal);
    }

    [Fact]
    public void QzTrayEmExecucao_ReconheceAJvmPelaPastaDoQz_NaoSoOLancador()
    {
        // Campo, 21/10/2026 (PC_ANDERSON): QZ Tray 2.3.0 no ar como runtime\bin\javaw.exe, sem processo qz-tray — o
        // instalador o via parado e abria outro por cima.
        var upgrade = Ler("upgrade.iss");
        var corpo = Corpo(upgrade, "function QzTrayEmExecucao(): Boolean;");

        Assert.Contains("ProcessoEmExecucao(QzTrayImagem)", corpo, StringComparison.Ordinal);
        Assert.Contains("ProcessosDaPastaPorWmi(ExtractFileDir(Executavel), '', False, Descricao) > 0", corpo, StringComparison.Ordinal);
        Assert.Contains("CaminhoDoQzTray()", corpo, StringComparison.Ordinal);

        // Nunca "qualquer javaw": outro programa Java da estação não é o QZ.
        Assert.DoesNotContain("javaw.exe'", corpo, StringComparison.OrdinalIgnoreCase);

        // Ninguém mais decide "QZ no ar" só pelo nome do lançador.
        Assert.Single(Regex.Matches(upgrade, @"ProcessoEmExecucao\(QzTrayImagem\)"));
    }

    [Fact]
    public void Reversao_DeInstalacaoReprovada_FechaABandeja_TiraDaRunKey_ENaoAReabre()
    {
        // Campo, 21/10/2026: 3.2.0 contra o dev reprovou (código 1), o .iss desprovisionou e a bandeja ficou ABERTA
        // mostrando "Serviço não registrado", "Helper não está em execução"... numa estação sem agente.
        var provisionamento = Ler("provisioning.iss");
        var reverter = Corpo(provisionamento, "procedure DesprovisionarAposFalha();");

        var marca = reverter.IndexOf("ProvisionamentoReprovado := True;", StringComparison.Ordinal);
        var fecha = reverter.IndexOf("EncerrarProcesso('{#BandejaExe}')", StringComparison.Ordinal);
        var runKey = reverter.IndexOf(
            @"RegDeleteValue(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Run', '{#BandejaValorRun}')", StringComparison.Ordinal);
        var desinstala = reverter.IndexOf("'--uninstall'", StringComparison.Ordinal);

        Assert.True(marca >= 0 && fecha > marca && runKey > fecha && desinstala > runKey,
            "Reversão: marcar a falha → fechar a bandeja → tirar o valor da Run key → --uninstall.");

        // A caixa da tela final não a sobe de novo numa instalação reprovada.
        Assert.Contains("Result := not ProvisionamentoReprovado;",
            Corpo(provisionamento, "function EstacaoProvisionada(): Boolean;"), StringComparison.Ordinal);
        var secaoRun = Regex.Match(Ler("PrintMonitor.iss"), @"^\[Run\][\s\S]*?(?=^\[)", RegexOptions.Multiline).Value;
        Assert.Contains("Flags: runasoriginaluser nowait postinstall skipifsilent; Check: EstacaoProvisionada", secaoRun,
            StringComparison.Ordinal);

        // Toda falha do provisionamento passa pela reversão antes do RaiseException, e nada é reaberto depois dela.
        var executar = Corpo(provisionamento, "procedure ExecutarProvisionamento();");
        Assert.Equal(
            Regex.Matches(executar, @"RaiseException\(").Count,
            Regex.Matches(executar, @"DesprovisionarAposFalha\(\);\s*(\{[^}]*\}\s*)*RaiseException\(").Count);
        Assert.True(executar.LastIndexOf("RaiseException(", StringComparison.Ordinal)
                    < executar.IndexOf("IniciarProcessosDaSessao();", StringComparison.Ordinal));
    }

}
