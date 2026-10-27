using System.Text.RegularExpressions;
using SisPedraCaida.Domain.Constants;
using SisPedraCaida.Totem.Agent.Configuration;
using SisPedraCaida.Totem.Setup;
using CodigosDoSetup = SisPedraCaida.Totem.Setup.CodigosDeSaida;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Guardas do instalador Inno do totem (<c>installer/totem/*.iss</c>) contra o C# do totem que ele espelha
/// (PRD-TOTEMINST-01).
/// </summary>
/// <remarks>
/// <para>
/// O <c>.iss</c> repete, com o aviso "alterar um lado exige alterar o outro", o nome do serviço, os executáveis,
/// a pasta de dados, os códigos de saída e os parâmetros do <c>Setup.exe</c>, a rota da sonda e a normalização do
/// endereço da API. Ele só roda numa estação real: sem estas guardas, a divergência apareceria como totem mudo
/// depois de uma instalação "concluída".
/// </para>
/// <para>
/// As constantes vêm compiladas (<c>Totem.Agent</c> e <c>Totem.Setup</c>, por <c>ProjectReference</c>): um rename
/// no backend quebra aqui na compilação ou na comparação. A casca (<c>Totem.Shell</c>) não é referenciada (#104a).
/// </para>
/// </remarks>
public class TotemInnoGuardTests
{
    private static readonly string PastaDoInstalador = Path.Combine(Raizes.Instaladores, "installer", "totem");

    /// <summary>Lê um arquivo do instalador do totem.</summary>
    /// <param name="arquivo">Nome do arquivo sob <c>installer/totem</c>.</param>
    /// <returns>Conteúdo.</returns>
    private static string Ler(string arquivo) => File.ReadAllText(Path.Combine(PastaDoInstalador, arquivo));

    /// <summary>Lê um arquivo do checkout do backend.</summary>
    /// <param name="partes">Caminho relativo à raiz do backend.</param>
    /// <returns>Conteúdo.</returns>
    private static string LerDoBackend(params string[] partes) =>
        File.ReadAllText(Path.Combine(new[] { Raizes.Backend }.Concat(partes).ToArray()));

    /// <summary>Corpo de uma função ou procedimento Pascal (até o <c>end;</c> na coluna 0).</summary>
    /// <param name="fonte">Texto do <c>.iss</c>.</param>
    /// <param name="assinatura">Assinatura exata.</param>
    /// <returns>O corpo, assinatura incluída.</returns>
    private static string Corpo(string fonte, string assinatura)
    {
        var achado = Regex.Match(fonte, Regex.Escape(assinatura) + @"[\s\S]*?\nend;");
        Assert.True(achado.Success, $"'{assinatura}' não encontrado.");
        return achado.Value;
    }

    /// <summary>Valor de um <c>#define Nome "valor"</c> do <c>Totem.iss</c>.</summary>
    /// <param name="nome">Nome da constante do pré-processador.</param>
    /// <returns>O valor.</returns>
    private static string Define(string nome)
    {
        var achado = Regex.Match(Ler("Totem.iss"), $@"(?m)^#define\s+{Regex.Escape(nome)}\s+""(?<valor>[^""]*)""");
        Assert.True(achado.Success, $"#define {nome} não encontrado em Totem.iss.");
        return achado.Groups["valor"].Value;
    }

    /// <summary>
    /// O <c>sc</c> do <c>Setup.exe</c> e as paradas do instalador usam o mesmo nome que o host declara no
    /// <c>AddWindowsService</c>. Divergir deixa o instalador parando um serviço que não existe enquanto o real copia
    /// por cima de si mesmo.
    /// </summary>
    [Fact]
    public void NomeDoServico_NoIss_EhOMesmoDoTotemPaths_EDoAddWindowsService()
    {
        Assert.Equal(TotemPaths.NomeServico, Define("ServicoNome"));

        // O host precisa usar a CONSTANTE, não um literal igual a ela: literal igual hoje é serviço órfão no próximo rename.
        var programa = LerDoBackend("src", "SisPedraCaida.Totem.Agent", "Program.cs");
        Assert.Matches(@"ServiceName\s*=\s*TotemPaths\.NomeServico", programa);
    }

    /// <summary>
    /// Os três executáveis do <c>.iss</c> (provisionar, parar, fechar a casca) são os que o C# publica e chama, e
    /// os que o <c>build-installer.ps1</c> exige no layout antes de compilar.
    /// </summary>
    [Fact]
    public void Executaveis_NoIss_SaoOsMesmosDoTotemPaths()
    {
        Assert.Equal(TotemPaths.ExecutavelDoSetup, Define("SetupExe"));
        Assert.Equal(TotemPaths.ExecutavelDoServico, Define("AgenteExe"));
        Assert.Equal(TotemPaths.ExecutavelDaCasca, Define("CascaExe"));

        var build = Ler("build-installer.ps1");
        foreach (var exe in new[] { TotemPaths.ExecutavelDoSetup, TotemPaths.ExecutavelDoServico, TotemPaths.ExecutavelDaCasca })
        {
            Assert.Contains($"'{exe}'", build, StringComparison.Ordinal);
        }
    }

    /// <summary>
    /// A pasta de dados, os arquivos de <c>config</c> que o instalador lê (identidade, estado do bloqueio,
    /// configuração gravada) e as subpastas que ele cria são os do <c>TotemPaths</c>. Ler outro caminho faz o
    /// upgrade pedir tudo de novo e a tela final mentir sobre a identidade.
    /// </summary>
    [Fact]
    public void PastaDeDados_NoIss_EhAMesmaDoTotemPaths()
    {
        var raiz = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        var relativa = Path.GetRelativePath(raiz, TotemPaths.PastaDados);
        Assert.Equal(@"{commonappdata}\" + relativa, Define("PastaDados"));

        var config = Path.GetFileName(TotemPaths.PastaConfiguracao);
        var includes = Ler("checks.iss") + Ler("pages.iss");
        foreach (var arquivo in new[] { TotemPaths.NomeArquivoIdentidade, TotemPaths.NomeArquivoEstadoBloqueio, TotemPaths.NomeArquivoConfiguracao })
        {
            Assert.Contains($@"{{#PastaDados}}\{config}\{arquivo}", includes, StringComparison.Ordinal);
        }

        var provisionamento = Corpo(Ler("provisioning.iss"), "procedure ExecutarProvisionamento();");
        foreach (var pasta in new[] { TotemPaths.PastaLogs, TotemPaths.PastaConfiguracao, TotemPaths.PastaWeb })
        {
            Assert.Contains($@"ForceDirectories(ExpandConstant('{{#PastaDados}}') + '\{Path.GetFileName(pasta)}');",
                provisionamento, StringComparison.Ordinal);
        }
    }

    /// <summary>
    /// O instalador confere o código de saída do <c>Setup.exe --all</c> por <c>Exec()</c> e traduz cancelado e
    /// argumento inválido; qualquer outro diferente de sucesso é falha. Um código renumerado no C# viraria mensagem
    /// errada ou, pior, sucesso tratado como falha.
    /// </summary>
    [Fact]
    public void CodigosDeSaida_NoIss_SaoOsDoSetup()
    {
        var provisionamento = Corpo(Ler("provisioning.iss"), "procedure ExecutarProvisionamento();");

        Assert.Contains($"if Codigo <> {CodigosDoSetup.Sucesso} then", provisionamento, StringComparison.Ordinal);

        var tratados = Regex.Matches(provisionamento, @"Codigo = (?<codigo>\d+)")
            .Select(m => int.Parse(m.Groups["codigo"].Value))
            .ToArray();

        // Só cancelado e argumento inválido têm mensagem própria; Falha cai no ramo genérico, de propósito.
        Assert.Equal(new[] { CodigosDoSetup.Cancelado, CodigosDoSetup.ArgumentoInvalido }, tratados);
        Assert.DoesNotContain(CodigosDoSetup.Falha, tratados);

        var desinstalacao = Corpo(Ler("provisioning.iss"), "procedure DesprovisionarParaDesinstalar();");
        Assert.Contains($"(Codigo = {CodigosDoSetup.Sucesso})", desinstalacao, StringComparison.Ordinal);
    }

    /// <summary>
    /// Os parâmetros que o <c>.iss</c> repassa ao <c>Setup.exe</c> são exatamente os que ele aceita com valor, e a
    /// linha montada pelo instalador (valor entre aspas, ou <c>--x=</c> para apagar) é lida sem sobrar argumento
    /// desconhecido. Parâmetro com uma letra fora do lugar seria rejeitado e a instalação reprovaria em campo.
    /// </summary>
    [Fact]
    public void ParametrosDoSetup_NoIss_SaoOsParametrosComValor()
    {
        var provisionamento = Ler("provisioning.iss");

        var repassados = Regex.Matches(provisionamento, @"ParametroSeAlterado\('(?<nome>--[a-z-]+)'")
            .Select(m => m.Groups["nome"].Value)
            .ToArray();
        Assert.Equal(LinhaDeComando.ParametrosComValor.OrderBy(p => p), repassados.OrderBy(p => p));

        Assert.Contains("Result := '--all' +", provisionamento, StringComparison.Ordinal);
        Assert.Equal(ModoDoSetup.Tudo, LinhaDeComando.Modo(["--all"]));
        Assert.Contains("ExecutarSetup('--uninstall'", provisionamento, StringComparison.Ordinal);
        Assert.Equal(ModoDoSetup.Desinstalar, LinhaDeComando.Modo(["--uninstall"]));

        // As duas formas que ParametroSeAlterado escreve, na linha que o cmd entrega ao Setup.exe.
        var montagem = Corpo(provisionamento, "function ParametroSeAlterado(Nome, Valor, Gravado: String): String;");
        Assert.Contains("Result := ' ' + Nome + '='", montagem, StringComparison.Ordinal);
        Assert.Contains("Result := ' ' + Nome + ' \"' + Valor + '\"'", montagem, StringComparison.Ordinal);

        string[] linha = ["--all", "--api-url", "https://api.exemplo", "--nome", "AUTO-02", "--local", "Loja", "--conteudo-url="];
        Assert.Empty(LinhaDeComando.Desconhecidos(linha));
        Assert.Equal(ModoDoSetup.Tudo, LinhaDeComando.Modo(linha));
        Assert.Equal("https://api.exemplo", LinhaDeComando.Valor(linha, "--api-url"));
        Assert.Equal("AUTO-02", LinhaDeComando.Valor(linha, "--nome"));
        Assert.Equal(string.Empty, LinhaDeComando.Valor(linha, "--conteudo-url"));
    }

    /// <summary>
    /// O botão "Testar conexão" faz a mesma requisição da sonda do <c>Setup.exe</c>: a rota anônima de enrolamento,
    /// que só existe no Cadastro.Interno. Rota divergente aprovaria um totem apontado para o Externo.
    /// </summary>
    [Fact]
    public void RotaDaSonda_NoIss_EhATotensEnrollment()
    {
        var achado = Regex.Match(Ler("pages.iss"), @"Requisicao\.Open\('POST', Url \+ '(?<rota>[^']+)'");

        Assert.True(achado.Success, "Requisicao.Open('POST', Url + '<rota>' …) não encontrado em pages.iss.");
        Assert.Equal(SuperficieForaDoNavegador.TotensEnrollment, achado.Groups["rota"].Value);

        var sonda = LerDoBackend("src", "SisPedraCaida.Totem.Setup", "Provisionamento", "ImplementacoesWindows.cs");
        Assert.Contains("SuperficieForaDoNavegador.TotensEnrollment", sonda, StringComparison.Ordinal);
    }

    /// <summary>
    /// O Pascal normaliza o endereço da API com as mesmas regras do <c>TotemSettingsFile.NormalizarOrigem</c>, para
    /// comparar o digitado com o gravado na mesma forma. As âncoras travam as regras do lado Pascal.
    /// </summary>
    [Fact]
    public void NormalizacaoDaApiUrl_NoIss_TemAsRegrasDaTotemSettingsFile()
    {
        var funcao = Corpo(Ler("pages.iss"), "function NormalizarApiUrl(Entrada: String; var Normalizada: String; var Erro: String): Boolean;");

        Assert.Contains("TotemSettingsFile.NormalizarOrigem", Ler("pages.iss"), StringComparison.Ordinal);
        Assert.Contains("Valor := Trim(Entrada);", funcao, StringComparison.Ordinal);
        Assert.Contains("Resto[Length(Resto)] = '/'", funcao, StringComparison.Ordinal);
        Assert.Contains("InicioDoCaminho := Pos('/', Resto);", funcao, StringComparison.Ordinal);
        Assert.Contains("Pos('/api', Lowercase(Copy(Resto, InicioDoCaminho, Length(Resto))))", funcao, StringComparison.Ordinal);
    }

    /// <summary>
    /// Vetores que o Pascal produz para endereços com esquema (o instalador recusa sem esquema). Se o C# passar a
    /// produzir outra forma, o upgrade compara formas diferentes e repassa o endereço como "alterado" sempre.
    /// </summary>
    /// <param name="entrada">O que o técnico digita.</param>
    /// <param name="esperado">A origem que o <c>.iss</c> calcula.</param>
    [Theory]
    [InlineData("https://api.exemplo/", "https://api.exemplo")]
    [InlineData("https://api.exemplo", "https://api.exemplo")]
    [InlineData("https://host/api/v1/", "https://host")]
    [InlineData("https://host/sub/API/v1", "https://host/sub")]
    [InlineData("  https://h  ", "https://h")]
    [InlineData("http://10.0.0.5:5121//", "http://10.0.0.5:5121")]
    public void NormalizarOrigem_ProduzAOrigemQueOIssCalcula(string entrada, string esperado)
    {
        Assert.Equal(esperado, TotemSettingsFile.NormalizarOrigem(entrada));
    }

    /// <summary>Valor vazio vira ausência nos dois lados: o <c>.iss</c> recusa e o C# devolve <c>null</c>.</summary>
    [Fact]
    public void NormalizarOrigem_Vazio_EhNulo()
    {
        Assert.Null(TotemSettingsFile.NormalizarOrigem("   "));
        Assert.Contains("if Valor = '' then", Ler("pages.iss"), StringComparison.Ordinal);
    }

    /// <summary>
    /// Os campos que o instalador relê do <c>totem.settings.json</c> gravado são as seções e chaves que o
    /// <c>TotemSettingsFile</c> escreve. Chave errada faz o upgrade não achar o valor e repassar tudo como novo.
    /// </summary>
    [Fact]
    public void CamposGravados_NoIss_SaoAsSecoesEChavesDoTotemSettings()
    {
        var lidos = Regex.Matches(Ler("pages.iss"), @"ValorGravado\('(?<secao>\w+)', '(?<chave>\w+)'\)")
            .Select(m => (m.Groups["secao"].Value, m.Groups["chave"].Value))
            .ToArray();

        Assert.Equal(
            new[]
            {
                (TotemSettings.SecaoApi, nameof(ApiOptions.BaseUrl)),
                (TotemSettings.SecaoTerminal, nameof(TerminalOptions.Nome)),
                (TotemSettings.SecaoTerminal, nameof(TerminalOptions.Local)),
                (TotemSettings.SecaoConteudo, nameof(ConteudoOptions.Url)),
            },
            lidos);
    }

    /// <summary>
    /// Cada parâmetro do Inno alimenta exatamente um parâmetro do <c>Setup.exe</c>, e os quatro estão no runbook da
    /// estação (<c>docs/TotemInstalacaoWindows.md</c> do backend), que é o contrato público com a TI.
    /// </summary>
    [Fact]
    public void ParametrosDoInno_NoIss_SaoOsDocumentadosNoBackend()
    {
        var pages = Ler("pages.iss");
        var provisionamento = Ler("provisioning.iss");

        var inno = Regex.Matches(pages, @"(?<variavel>Valor\w+) := TextoOuPadrao\(Parametro\('(?<parametro>[A-Z]+)'\)")
            .ToDictionary(m => m.Groups["variavel"].Value, m => m.Groups["parametro"].Value);
        var setup = Regex.Matches(provisionamento, @"ParametroSeAlterado\('(?<parametro>--[a-z-]+)', (?<variavel>Valor\w+),")
            .ToDictionary(m => m.Groups["variavel"].Value, m => m.Groups["parametro"].Value);

        var pares = inno
            .Select(p => $"{p.Value}={setup.GetValueOrDefault(p.Key) ?? "(sem parâmetro do Setup.exe)"}")
            .OrderBy(p => p, StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(
            new[] { "APIURL=--api-url", "CONTEUDOURL=--conteudo-url", "LOCAL=--local", "NOME=--nome" },
            pares);

        var runbook = LerDoBackend("docs", "TotemInstalacaoWindows.md");
        foreach (var parametro in inno.Values)
        {
            Assert.True(runbook.Contains($"/{parametro}=", StringComparison.Ordinal),
                $"/{parametro}= não está em docs/TotemInstalacaoWindows.md do backend.");
        }
    }

    /// <summary>
    /// O provisionamento é por <c>Exec()</c> com o código conferido, e a falha desfaz o que foi feito e reprova. O
    /// <c>[Run]</c> do Inno ignora o código de saída (#101a): mover o <c>Setup.exe</c> para lá dá "Concluído" com
    /// o totem mudo.
    /// </summary>
    [Fact]
    public void Provisionamento_PorExec_NaoPorRun_EComRollback()
    {
        var secaoRun = Regex.Match(Ler("Totem.iss"), @"(?ms)^\[Run\]\s*$(?<corpo>.*?)^\[");
        Assert.True(secaoRun.Success, "Seção [Run] não encontrada em Totem.iss.");
        Assert.DoesNotContain("{#SetupExe}", secaoRun.Groups["corpo"].Value, StringComparison.Ordinal);

        var provisionamento = Corpo(Ler("provisioning.iss"), "procedure ExecutarProvisionamento();");
        Assert.Contains("ExecutarSetup(ArgumentosDoSetup()", provisionamento, StringComparison.Ordinal);

        var ramoDeFalha = provisionamento[provisionamento.IndexOf("if Codigo <> ", StringComparison.Ordinal)..];
        Assert.Contains("DesprovisionarAposFalha();", ramoDeFalha, StringComparison.Ordinal);
        Assert.Contains("RaiseException(", ramoDeFalha, StringComparison.Ordinal);
    }

    /// <summary>
    /// O WebView2 Runtime é aviso, não bloqueio: sem ele a casca mostra "fora de serviço" e o resto do totem funciona.
    /// O bootstrapper é opcional no build e conferido por hash quando vem (o PRD-TOTEMINST-02 o torna obrigatório
    /// só no CI, pelo mesmo parâmetro).
    /// </summary>
    [Fact]
    public void WebView2_EhAvisoNaoBloqueio_EBootstrapperEOpcionalNoBuild()
    {
        var iss = Ler("Totem.iss");
        Assert.Contains("#ifndef WebView2Bootstrapper", iss, StringComparison.Ordinal);
        Assert.Contains("#define WebView2Bootstrapper \"\"", iss, StringComparison.Ordinal);
        Assert.Contains("Check: WebView2DaMaquinaAusente", iss, StringComparison.Ordinal);

        var instalar = Corpo(Ler("provisioning.iss"), "procedure InstalarWebView2SeNecessario();");
        Assert.Contains("'/silent /install'", instalar, StringComparison.Ordinal);
        Assert.DoesNotContain("RaiseException", instalar, StringComparison.Ordinal);
        Assert.DoesNotContain("DesprovisionarAposFalha", instalar, StringComparison.Ordinal);

        var build = Ler("build-installer.ps1");
        Assert.Contains("-ArquivoHash 'webview2.sha256'", build, StringComparison.Ordinal);
        Assert.Contains("/DWebView2Bootstrapper=", build, StringComparison.Ordinal);
    }

    /// <summary>
    /// Em Pascal o comentário <c>{ ... }</c> termina na PRIMEIRA <c>}</c>: uma chave aninhada fecha o comentário no
    /// meio e o ISCC aborta, só no build do instalador. O <c>Totem.iss</c> fica fora por causa do
    /// <c>AppId={{…}</c>, como no PrintMonitor.
    /// </summary>
    /// <param name="arquivo">Include do instalador.</param>
    [Theory]
    [InlineData("checks.iss")]
    [InlineData("pages.iss")]
    [InlineData("provisioning.iss")]
    public void ComentariosPascal_NoIss_NaoTemChaveAninhada(string arquivo)
    {
        var aninhada = Regex.Match(Ler(arquivo), @"\{(?!#)[^}]*\{");

        Assert.False(aninhada.Success, $"Chave aninhada em comentário de {arquivo}: '{aninhada.Value}'");
    }
}
