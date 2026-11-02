using System.Text.RegularExpressions;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Pré-requisitos da Elgin no instalador do agente TEF (PRD-ELGPRE-01): o Elgin TEF HUB e o E1_Connect são
/// conferidos e a ausência BLOQUEIA a instalação — o instalador nunca baixa nem executa o instalador da Elgin.
/// </summary>
/// <remarks>
/// O download + instalação silenciosa (D7-bis do PRD-TEFHUB-01) travava o wizard em campo: o pacote da Elgin
/// encadeia os instaladores dos componentes, e o <c>Exec(..., ewWaitUntilTerminated)</c> esperava para sempre.
/// Regra só do <c>.iss</c>, sem par no C# do backend — por isso a guarda lê só este repositório.
/// </remarks>
public class TefAgentPreRequisitosElginGuardTests
{
    private static string PastaDoTef => Path.Combine(Raizes.Instaladores, "installer", "tefagent");

    /// <summary>Todo o Pascal do instalador do TEF, de todos os <c>.iss</c> da pasta.</summary>
    private static string TodoOIss() => string.Join(
        Environment.NewLine,
        Directory.GetFiles(PastaDoTef, "*.iss").Order(StringComparer.Ordinal).Select(File.ReadAllText));

    /// <summary>Nada de download nem de página de download no instalador do TEF.</summary>
    [Theory]
    [InlineData("CreateDownloadPage")]
    [InlineData("DownloadTemporaryFile")]
    [InlineData("media.githubusercontent.com")]
    public void InstaladorDoTef_NaoBaixaNadaDaElgin(string trecho)
    {
        Assert.DoesNotContain(trecho, TodoOIss(), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Os dois produtos são procurados pelo AppId que o instalador da Elgin registra.</summary>
    [Theory]
    [InlineData("ChaveTefHub", "{404E58AC-6853-41C7-B076-0E2036F9E04B}_is1")]
    [InlineData("ChaveE1Connect", "{28910153-EEED-4710-BBD3-7B6BADF2E103}_is1")]
    public void ProdutosDaElgin_SaoDetectadosPeloAppId(string constante, string appId)
    {
        var checks = File.ReadAllText(Path.Combine(PastaDoTef, "checks.iss"));

        var declaracao = Regex.Match(checks, constante + @"\s*=\s*BaseDesinstalacao\s*\+\s*'\\(?<appid>[^']+)'\s*;");
        Assert.True(declaracao.Success, $"const {constante} não encontrada no checks.iss.");
        Assert.Equal(appId, declaracao.Groups["appid"].Value);
    }

    /// <summary>
    /// A checagem roda no <c>InitializeSetup</c> e o reprova: antes de qualquer página (vale no silencioso) e
    /// antes de copiar um arquivo.
    /// </summary>
    [Fact]
    public void Checagem_BloqueiaNoInitializeSetup()
    {
        var principal = File.ReadAllText(Path.Combine(PastaDoTef, "TefAgent.iss"));

        var initializeSetup = Regex.Match(principal, @"function InitializeSetup\(\): Boolean;(?<corpo>.*?)\nend;", RegexOptions.Singleline);
        Assert.True(initializeSetup.Success, "function InitializeSetup não encontrada no TefAgent.iss.");
        Assert.Matches(@"if not GarantirPreRequisitosElgin\(\) then\s*begin\s*Result := False;",
            initializeSetup.Groups["corpo"].Value);
    }
}
