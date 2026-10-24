using System.Text.RegularExpressions;
using Moq;
using SisPedraCaida.Domain.Interfaces;
using SisPedraCaida.PrintMonitor.Core.Abstractions;
using SisPedraCaida.PrintMonitor.Core.Constants;
using SisPedraCaida.PrintMonitor.Core.Options;
using SisPedraCaida.PrintMonitor.Core.Provisioning;
using SisPedraCaida.PrintMonitor.Infrastructure.Provisioning;
using SisPedraCaida.PrintMonitor.Setup;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Guardas do instalador Inno do PrintMonitor (<c>installer/printmonitor/*.iss</c>) contra o código C# que ele
/// espelha. O <c>.iss</c> não tem suíte própria e só é exercitado numa estação real — divergência entre os dois
/// lados só apareceria em campo.
/// </summary>
public class InstaladorInnoGuardTests
{
    private static readonly string PastaDoInstalador =
        Path.Combine(Raizes.Instaladores, "installer", "printmonitor");

    private static string Ler(string arquivo) => File.ReadAllText(Path.Combine(PastaDoInstalador, arquivo));

    [Fact]
    public void ArgumentoSilenciosoDoQzTray_NoIss_EhOMesmoDoQzTrayInstaller()
    {
        // O payload homologado (QZ Tray 2.3.0) é NSIS: argumento install4j abriria a UI atrás do wizard.
        var achado = Regex.Match(Ler("provisioning.iss"), @"Exec\(Instalador,\s*'(?<args>[^']*)'");

        Assert.True(achado.Success, "Chamada Exec(Instalador, '<args>' …) do QZ Tray não encontrada.");
        Assert.Equal(new QzTrayInstallOptions().SilentInstallArguments, achado.Groups["args"].Value);
    }

    [Fact]
    public void CaminhoDoQzTrayInstalado_NoIss_EhOMesmoDoAgente()
    {
        var esperado = $@"\{QzTrayConstants.DefaultInstallFolderName}\{QzTrayConstants.ExecutableFileName}";

        Assert.Contains("{commonpf}" + esperado, Ler("checks.iss"), StringComparison.Ordinal);
    }

    [Fact]
    public void PortaSeguraDoQzTray_NoIss_EhAMesmaDoAgente()
    {
        // A checagem de pré-requisito avisa quando a porta wss já está ocupada; se divergisse do agente, avisaria
        // sobre a porta errada (já aconteceu: os dois lados estavam com a 8182, que é a ws).
        var achado = Regex.Match(Ler("checks.iss"), @"PortaSeguraQz\s*=\s*(?<porta>\d+);");

        Assert.True(achado.Success, "Constante PortaSeguraQz não encontrada em checks.iss.");
        Assert.Equal(QzTrayConstants.SecurePort.ToString(), achado.Groups["porta"].Value);
        Assert.Contains($"localport={QzTrayConstants.SecurePort},{QzTrayConstants.InsecurePort}",
            Ler("provisioning.iss"), StringComparison.Ordinal);
    }

    [Fact]
    public void ChavesDoArquivoDeRespostaGravadoPeloIss_SaoLidasPeloSetup()
    {
        // GravarArquivoDeResposta (provisioning.iss) escreve Chave=valor; uma chave com uma letra fora do lugar
        // chegaria ao Setup.exe e seria ignorada em silêncio — a estação ficaria sem a chave ou sem o loopback.
        var chaves = Regex.Matches(Ler("provisioning.iss"), @"Linhas\[N\] := '(?<chave>\w+)='")
            .Select(m => m.Groups["chave"].Value)
            .ToArray();

        Assert.Equal(
            ["ApiKey", "LoopbackPrintEnabled", "LoopbackPrintRouteSecret", "LoopbackPrintSegredoIdentidade",
             "LoopbackPrintOrigensPermitidas"],
            chaves);

        var arquivo = Path.Combine(Path.GetTempPath(), $"pm-guard-{Guid.NewGuid():N}.txt");
        try
        {
            File.WriteAllLines(arquivo,
            [
                "ApiKey=chave", "LoopbackPrintEnabled=true", "LoopbackPrintRouteSecret=impressao-0123456789",
                "LoopbackPrintSegredoIdentidade=identidade-0123456789", "LoopbackPrintOrigensPermitidas=https://a.exemplo.com",
            ]);

            var p = SetupParameters.Parse(["--config-file", arquivo]);

            Assert.Equal("chave", p.ApiKey);
            Assert.True(p.LoopbackEnabled);
            Assert.Equal("impressao-0123456789", p.LoopbackRouteSecret);
            Assert.Equal("identidade-0123456789", p.LoopbackSegredoIdentidade);
            Assert.Equal(["https://a.exemplo.com"], p.LoopbackOrigensPermitidas);
        }
        finally
        {
            File.Delete(arquivo);
        }
    }

    [Fact]
    public void ArgumentosDoSetup_NoIss_NaoLevamSegredoNaLinhaDeComando()
    {
        Assert.DoesNotContain("--api-key", Ler("provisioning.iss"), StringComparison.Ordinal);
        Assert.Contains($"' {SetupParameters.FlagArquivoDeResposta} \"'", Ler("provisioning.iss"), StringComparison.Ordinal);
    }

    [Fact]
    public void ConstantesDoLoopback_NoIss_SaoAsMesmasDoSetup()
    {
        var pages = Ler("pages.iss");

        Assert.Contains($"VarLoopbackOrigemPrefixo = '{StationEnvironmentVariables.LoopbackOrigensPermitidasPrefixo}';", pages,
            StringComparison.Ordinal);
        Assert.Contains($"TamanhoMinimoSegredoLoopback = {SetupParameters.TamanhoMinimoSegredo};", pages,
            StringComparison.Ordinal);
    }

    /// <summary>Origem padrão do admin que o instalador traz (decisão de 21/10/2026).</summary>
    private const string OrigemPadraoDoAdmin = "https://interno-dev.berechit.com.br";

    [Fact]
    public void OrigensPadrao_NoIss_EhOAdminDeDev_SobrescrevivelPeloBuild_EJaNormalizada()
    {
        var principal = Ler("PrintMonitor.iss");

        // #ifndef: o /DOrigensPadrao= do build-installer.ps1 vence o default.
        var achado = Regex.Match(principal, @"#ifndef OrigensPadrao\s*\r?\n\s*#define OrigensPadrao ""(?<valor>[^""]*)""");
        Assert.True(achado.Success, "Default '#ifndef OrigensPadrao / #define OrigensPadrao \"...\"' não encontrado.");
        Assert.Equal(OrigemPadraoDoAdmin, achado.Groups["valor"].Value);

        // O .iss valida as origens no InitializeSetup: um default fora da forma do cabeçalho Origin bloquearia toda estação.
        Assert.Equal(OrigemPadraoDoAdmin, SetupParameters.NormalizarOrigem(achado.Groups["valor"].Value));

        var build = Ler("build-installer.ps1");
        Assert.Contains("\"/DOrigensPadrao=$origensNormalizadas\"", build, StringComparison.Ordinal);
        Assert.Contains("ConvertTo-ListaDeOrigens -Origens $OrigensPadrao", build, StringComparison.Ordinal);
    }

    [Fact]
    public void OrigensIniciais_NoIss_SeguemArquivoParametroGravadasEPorUltimoODefault()
    {
        var pages = Ler("pages.iss");

        Assert.Contains("OrigensPadraoDoPacote = '{#OrigensPadrao}';", pages, StringComparison.Ordinal);

        // Precedência: /CONFIGFILE → /LOOPBACKORIGINS= → gravadas na estação → OrigensPadrao. O default não passa pelo
        // {param:...|default} (lista com vírgula exigiria %-encoding ali).
        var ordem = Regex.Match(
            pages,
            @"ValorOrigens := LerDoArquivoDeConfiguracao\(Arquivo, 'LoopbackPrintOrigensPermitidas'\);\s*" +
            @"if ValorOrigens = '' then\s*ValorOrigens := Parametro\('LOOPBACKORIGINS', ''\);\s*" +
            @"if ValorOrigens = '' then\s*ValorOrigens := OrigensJaGravadas;\s*" +
            @"if ValorOrigens = '' then\s*ValorOrigens := OrigensPadraoDoPacote;");
        Assert.True(ordem.Success, "Precedência das origens iniciais divergente em ValoresIniciais (pages.iss).");
    }

    [Theory]
    [InlineData("checks.iss")]
    [InlineData("pages.iss")]
    [InlineData("provisioning.iss")]
    [InlineData("upgrade.iss")]
    [InlineData("processos.iss")]
    public void ComentariosPascal_NoIss_NaoTemChaveAninhada(string arquivo)
    {
        // Em Pascal o comentário { ... } termina na PRIMEIRA '}': um "/{segredo}/identidade" dentro dele fecha o
        // comentário no meio e o ISCC aborta com "Identifier expected" — só no build do instalador, longe dos testes.
        var aninhada = Regex.Match(Ler(arquivo), @"\{(?!#)[^}]*\{");

        Assert.False(aninhada.Success, $"Chave aninhada em comentário de {arquivo}: '{aninhada.Value}'");
    }

    [Fact]
    public void PaginaDeIdentificacao_NoIss_PedeSoAsOrigens_SemSegredo()
    {
        // Decisão de 21/10/2026: a identidade não tem segredo; a proteção é a lista de origens.
        var pages = Ler("pages.iss");
        var campos = Regex.Matches(pages, @"PaginaIdentidade\.Add\('(?<rotulo>[^']*)'");

        var campo = Assert.Single(campos);
        Assert.Contains("Origens", campo.Groups["rotulo"].Value, StringComparison.Ordinal);
        Assert.DoesNotContain("PaginaIdentidade.Values[1]", pages, StringComparison.Ordinal);
        Assert.DoesNotContain("Segredo de identidade:", Ler("PrintMonitor.iss"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task OrigemPadraoGravadaPeloIss_LigaOLoopback_EGeraORouteSecretNaEstacao()
    {
        // Estação nova + instalação padrão: o .iss leva só LoopbackPrintOrigensPermitidas=<default> no arquivo de
        // resposta; o Setup.exe precisa ligar o loopback e o provisionador gerar o RouteSecret — senão o Helper não
        // sobe /print e a identificação depende de sorte na configuração.
        var arquivo = Path.Combine(Path.GetTempPath(), $"pm-guard-{Guid.NewGuid():N}.txt");
        try
        {
            File.WriteAllLines(arquivo, ["ApiKey=chave", $"LoopbackPrintOrigensPermitidas={OrigemPadraoDoAdmin}"]);

            var parametros = SetupParameters.Parse(["--all", "--config-file", arquivo]);
            Assert.Empty(parametros.Validar());

            var gravadas = new Dictionary<string, string>(StringComparer.Ordinal);
            var escritor = new Mock<IEnvironmentVariableWriter>();
            escritor.Setup(w => w.GetMachineScoped(It.IsAny<string>()))
                .Returns((string nome) => gravadas.TryGetValue(nome, out var v) ? v : null);
            escritor.Setup(w => w.SetMachineScoped(It.IsAny<string>(), It.IsAny<string>()))
                .Callback((string nome, string valor) => gravadas[nome] = valor);

            await new AgentConfigurationProvisioner(
                    escritor.Object, parametros.ToEnvironmentVariables(), () => "segredo-gerado-na-estacao-0001",
                    Mock.Of<ILogFramework<AgentConfigurationProvisioner>>())
                .EnsureConfiguredAsync(CancellationToken.None);

            Assert.Equal("true", gravadas[StationEnvironmentVariables.LoopbackEnabled]);
            Assert.Equal(OrigemPadraoDoAdmin, gravadas[StationEnvironmentVariables.LoopbackOrigem(0)]);
            Assert.Equal("segredo-gerado-na-estacao-0001", gravadas[StationEnvironmentVariables.LoopbackRouteSecret]);
            Assert.False(gravadas.ContainsKey(StationEnvironmentVariables.LoopbackSegredoIdentidade));
        }
        finally
        {
            File.Delete(arquivo);
        }
    }

    [Fact]
    public void DriverBematech_EhObrigatorio_InstaladoPorExecENuncaDesinstalado()
    {
        // PRD-PMTRAY-02: sem [Tasks], sem Check no [Files], #error sem o payload e o build exige o driver.
        var principal = Ler("PrintMonitor.iss");
        var provisionamento = Ler("provisioning.iss");

        Assert.DoesNotMatch(@"(?m)^\[Tasks\]", principal);
        Assert.DoesNotMatch(@"Name: ""driverbematech""", principal);
        Assert.DoesNotContain("WizardIsTaskSelected", provisionamento, StringComparison.Ordinal);
        Assert.DoesNotContain("DriverBematechSelecionado", provisionamento, StringComparison.Ordinal);
        Assert.Matches(@"#if BematechDriverFile == """"\s*\r?\n(\s*;[^\r\n]*\r?\n)*\s*#error", principal);
        Assert.Matches(@"(?m)^Source: ""payload-drivers\\\{#BematechDriverFile\}""; DestDir: ""\{tmp\}""; Flags: deleteafterinstall\s*$", principal);
        Assert.Contains("-Descricao 'o driver da Bematech MP-4200 TH' -Obrigatorio", Ler("build-installer.ps1"), StringComparison.Ordinal);
        Assert.Contains("'/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-", provisionamento, StringComparison.Ordinal);

        // Política de falha: o driver roda depois do provisionamento e a falha dele não reprova o agente.
        var instalarDriver = Regex.Match(provisionamento, @"procedure InstalarDriverBematech\(\);[\s\S]*?\nend;").Value;
        Assert.DoesNotContain("RaiseException", instalarDriver, StringComparison.Ordinal);
        Assert.DoesNotContain("DesprovisionarAposFalha", instalarDriver, StringComparison.Ordinal);

        // [Run] ignora o código de saída (#101a); e o desinstalador do PrintMonitor não remove o driver.
        var secaoRun = Regex.Match(principal, @"^\[Run\][\s\S]*?(?=^\[)", RegexOptions.Multiline);
        Assert.False(secaoRun.Success && secaoRun.Value.Contains("Bematech", StringComparison.OrdinalIgnoreCase));
        var desinstalacao = Regex.Match(principal, @"^\[UninstallRun\][\s\S]*?(?=^\[)", RegexOptions.Multiline).Value;
        var entradas = desinstalacao.Split('\n').Where(l => !l.TrimStart().StartsWith(';'));
        Assert.DoesNotContain(entradas, l => l.Contains("Bematech", StringComparison.OrdinalIgnoreCase)
                                             || l.Contains("driver", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void AtualizacaoAutomatica_SemOpcaoNaTela_ESempreLigada()
    {
        // PRD-PMTRAY-02: a página "Opções da estação — Ambiente e atualização" saiu com o checkbox.
        var pages = Ler("pages.iss");

        Assert.DoesNotContain("PaginaOpcoes", pages, StringComparison.Ordinal);
        Assert.DoesNotContain("Manter a atualização automática", pages, StringComparison.Ordinal);
        Assert.DoesNotContain("nasce DESLIGADA", pages, StringComparison.Ordinal);
        Assert.DoesNotContain("desligada (canal único", pages, StringComparison.Ordinal);

        // O feed vem do /CONFIGFILE (chave que o Setup lê) e, na falta, do /MANIFESTURL=.
        Assert.Matches(
            @"ValorManifestUrl := LerDoArquivoDeConfiguracao\(Arquivo, 'ManifestUrl'\);\s*if ValorManifestUrl = '' then\s*ValorManifestUrl := Parametro\('MANIFESTURL', ''\);",
            pages);

        // Quem liga é o Setup.exe, sempre: o .iss não tem parâmetro para desligar.
        Assert.Equal("true", SetupParameters.Parse(["--all"]).ToEnvironmentVariables()[SetupParameters.VarUpdateEnabled]);
    }

    [Fact]
    public void Instalador_TemOIconeDaMarca_CompartilhadoComOTef()
    {
        const string icone = @"SetupIconFile=..\assets\sispedracaida.ico";

        Assert.Contains(icone, Ler("PrintMonitor.iss"), StringComparison.Ordinal);
        Assert.Contains(icone, File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", "tefagent", "TefAgent.iss")), StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(Raizes.Instaladores, "installer", "assets", "sispedracaida.ico")));
    }

    [Fact]
    public void Bandeja_ChaveRunDaMaquina_RunComoUsuarioOriginal_ETaskkill()
    {
        // PRD-PMTRAY-01 D7 / armadilha #104d.
        var principal = Ler("PrintMonitor.iss");
        var bandeja = new InstallOptions().TrayExecutableName;

        Assert.Contains($"#define BandejaExe \"{bandeja}\"", principal, StringComparison.Ordinal);
        Assert.Matches(
            @"Root: HKLM; Subkey: ""Software\\Microsoft\\Windows\\CurrentVersion\\Run""; \\\s*\r?\n\s*ValueType: string; ValueName: ""\{#BandejaValorRun\}""; \\\s*\r?\n\s*ValueData: """"""\{app\}\\\{#BandejaExe\}""""""; Flags: uninsdeletevalue",
            principal);
        Assert.DoesNotMatch(@"(?m)^[^;\r\n]*uninsdeletekey", principal);

        var secaoRun = Regex.Match(principal, @"^\[Run\][\s\S]*?(?=^\[)", RegexOptions.Multiline).Value;
        Assert.Contains("Flags: runasoriginaluser nowait postinstall skipifsilent", secaoRun, StringComparison.Ordinal);

        var desinstalacao = Regex.Match(principal, @"^\[UninstallRun\][\s\S]*?(?=^\[)", RegexOptions.Multiline).Value;
        var taskkill = desinstalacao.IndexOf("taskkill.exe", StringComparison.Ordinal);
        var desprovisionar = desinstalacao.IndexOf("--uninstall", StringComparison.Ordinal);
        Assert.True(taskkill >= 0 && taskkill < desprovisionar, "A bandeja precisa ser fechada ANTES do --uninstall.");

        // Upgrade: o PrepareToInstall fecha a bandeja antes de copiar (executável e DLLs travados) — desde
        // PRD-PMTRAY-03 pelo PrepararUpgrade do upgrade.iss (InstaladorUpgradeGuardTests cobre a ordem).
        Assert.Contains("EncerrarProcesso('{#BandejaExe}')", Ler("upgrade.iss"), StringComparison.Ordinal);
    }

    [Fact]
    public void Bandeja_EntraNaPublicacao_ENaFonteDoPacote()
    {
        var publicacao = File.ReadAllText(Path.Combine(Raizes.Backend, "scripts", "printmonitor-publish.ps1"));

        Assert.Contains("'SisPedraCaida.PrintMonitor.Tray'", publicacao, StringComparison.Ordinal);
        Assert.Contains(new InstallOptions().TrayExecutableName, publicacao, StringComparison.Ordinal);
        Assert.Contains("'src/SisPedraCaida.PrintMonitor.Tray/SisPedraCaida.PrintMonitor.Tray.csproj'", Ler("build-installer.ps1"),
            StringComparison.Ordinal);
    }

}
