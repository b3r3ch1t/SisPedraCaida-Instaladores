using System.Text.Json;
using System.Text.RegularExpressions;
using Xunit;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Guarda do manifesto de instaladores do CI de prod (<c>installer/instaladores-ci.json</c>,
/// PRD-INSTPROD-02).
/// </summary>
/// <remarks>
/// <para>
/// O pipeline de prod empacota um instalador por linha do manifesto. Sem esta guarda, um Windows
/// Service novo (como foi o Totem) nasceria compilando, testado e com Dockerfile nenhum — e
/// <b>nenhum instalador sairia da release</b>, sem nada ficar vermelho: a matriz só conhece o que
/// alguém lembrou de escrever nela. É o mesmo furo que deixou o <c>Scheduler.Worker</c> fora da
/// matriz de imagens (<see cref="DockerPublishMatrixArchitectureTests"/>).
/// </para>
/// <para>
/// O serviço é reconhecido pela <b>chamada</b> <c>UseWindowsService(</c>/<c>AddWindowsService(</c>
/// no código de <c>src/</c>, e o vínculo com o manifesto é pelo <b>nome do projeto</b> (a pasta sob
/// <c>src/</c>), não pelo caminho do arquivo — que muda numa refatoração e deixaria a guarda cega
/// justamente ali (lição da armadilha #104).
/// </para>
/// </remarks>
[Trait("Category", "Architecture")]
public partial class InstaladoresCiArchitectureTests
{
    /// <summary>Chamada que registra o host como Windows Service.</summary>
    [GeneratedRegex(@"\.(UseWindowsService|AddWindowsService)\s*\(")]
    private static partial Regex RegistroWindowsServiceRegex();

    /// <summary>Identificador de serviço aceito na matriz (vira nome de job e de artifact).</summary>
    [GeneratedRegex("^[a-z0-9-]+$")]
    private static partial Regex ServicoRegex();

    /// <summary>
    /// Canais que o <c>instaladores-windows.yml</c> aceita no input <c>canal</c> (PRD-INSTDEV-01/02).
    /// </summary>
    /// <remarks>
    /// Conjunto fechado de propósito: canal escrito de outra forma (<c>"PROD"</c>, <c>"produção"</c>,
    /// <c>"main"</c>) não casaria com o filtro do job <c>matriz</c> e tiraria a linha da matriz **em
    /// silêncio**. <c>staging</c> está aqui para o dia em que alguém a ligar, sem que isso signifique
    /// que ela empacota hoje — nenhuma linha a declara.
    /// </remarks>
    private static readonly string[] CanaisValidos = ["dev", "staging", "prod"];

    /// <summary>
    /// Canais que **têm pipeline de empacotamento** e, por isso, precisam de ao menos um instalador.
    /// </summary>
    /// <remarks>
    /// <para>
    /// É o que distingue "canal que o manifesto aceita" de "canal que alguém empacota": a <c>prod</c>
    /// pelo job <c>instaladores</c> do <c>release-please-prod.yml</c>, a <c>dev</c> pelo
    /// <c>instaladores-dev.yml</c> (PRD-INSTDEV-02). <c>staging</c> fica fora **de propósito** — não há
    /// workflow que a chame, e cobrá-la deixaria a guarda vermelha por motivo errado (#74).
    /// </para>
    /// <para>
    /// ⚠️ Derivar isso dos canais que o manifesto **declara** (a primeira versão desta guarda) a deixa
    /// **cega**: tirar o último instalador da <c>dev</c> some com o canal da lista e o teste passa,
    /// enquanto o <c>instaladores-dev.yml</c> reprovaria em todo push por matriz vazia. Achado pela
    /// prova por mutação, não pela leitura — e é o caso que a mutação <c>dev-sem-nenhum</c> fixa.
    /// </para>
    /// </remarks>
    private static readonly string[] CanaisQueEmpacotam = ["dev", "prod"];

    /// <summary>Canal cujo pacote vai a campo, obrigatório em toda linha da matriz.</summary>
    private const string CanalDeCampo = "prod";

    /// <summary>Todo Windows Service de <c>src/</c> tem instalador no manifesto ou pendência com PRD.</summary>
    [Fact]
    public void TodoWindowsService_EstaNoManifesto()
    {
        var servicos = ProjetosWindowsService();
        var manifesto = Manifesto.Carregar(Raizes.Instaladores);

        // Sem isto a guarda passaria vazia no dia em que a varredura deixasse de achar os serviços.
        Assert.True(
            servicos.Count >= 3,
            $"Esperava ao menos Tef.Agent, PrintMonitor.Service e Totem.Agent; achei {servicos.Count}: {string.Join(", ", servicos)}.");

        var cobertos = manifesto.Instaladores.SelectMany(i => i.Projetos)
            .Concat(manifesto.Pendentes.Select(p => p.Projeto))
            .ToHashSet(StringComparer.Ordinal);

        var foraDoManifesto = servicos.Where(s => !cobertos.Contains(s)).ToList();

        Assert.True(
            foraDoManifesto.Count == 0,
            $"Windows Service fora de installer/instaladores-ci.json: {string.Join(", ", foraDoManifesto)}. " +
            "Sem a linha, o CI de prod não gera o instalador e a release sai sem ele. Acrescente-o em " +
            "'instaladores' (com o build-installer.ps1) ou, enquanto o instalador não existe, em 'pendentes' com o PRD.");
    }

    /// <summary>Linha do manifesto aponta para script existente e projeto que ainda é Windows Service.</summary>
    [Fact]
    public void TodaLinhaDoManifesto_EstaViva()
    {
        var raiz = Raizes.Instaladores;
        var servicos = ProjetosWindowsService();
        var manifesto = Manifesto.Carregar(raiz);

        Assert.NotEmpty(manifesto.Instaladores);

        var problemas = new List<string>();

        foreach (var instalador in manifesto.Instaladores)
        {
            if (!ServicoRegex().IsMatch(instalador.Servico))
                problemas.Add($"'{instalador.Servico}': identificador fora de ^[a-z0-9-]+$ (vira nome de job/artifact).");

            if (string.IsNullOrWhiteSpace(instalador.Nome))
                problemas.Add($"'{instalador.Servico}': 'nome' vazio (prefixo do .exe, ex.: TefAgentSetup).");

            if (!File.Exists(Path.Combine(raiz, instalador.Script.Replace('/', Path.DirectorySeparatorChar))))
                problemas.Add($"'{instalador.Servico}': script inexistente {instalador.Script}.");

            if (instalador.Projetos.Count == 0)
                problemas.Add($"'{instalador.Servico}': nenhum projeto declarado.");

            problemas.AddRange(ProblemasDosProjetos(instalador, servicos));

            // Canais (PRD-INSTDEV-01): a linha sem canal não é empacotada por pipeline nenhum, e o
            // instalador desapareceria dos dois sem nada ficar vermelho — a mesma classe de furo que
            // esta guarda existe para cobrir.
            if (instalador.Canais.Count == 0)
            {
                problemas.Add($"'{instalador.Servico}': 'canais' vazio — nenhum pipeline empacotaria este instalador.");
            }

            problemas.AddRange(instalador.Canais
                .Where(c => !CanaisValidos.Contains(c))
                .Select(c => $"'{instalador.Servico}': canal '{c}' fora de {{{string.Join(", ", CanaisValidos)}}} — " +
                             "não casa com o input do workflow e a linha sairia da matriz em silêncio."));

            problemas.AddRange(instalador.Canais
                .GroupBy(c => c, StringComparer.Ordinal)
                .Where(g => g.Count() > 1)
                .Select(g => $"'{instalador.Servico}': canal '{g.Key}' repetido em 'canais'."));

            // A prod é o canal de campo: instalador que sai dela é regressão, não configuração.
            if (instalador.Canais.Count > 0 && !instalador.Canais.Contains(CanalDeCampo))
            {
                problemas.Add($"'{instalador.Servico}': sem o canal '{CanalDeCampo}' — a release de produção sairia " +
                              "sem este instalador. Instalador só de desenvolvimento precisa mudar esta guarda.");
            }

            problemas.AddRange(ProblemasDosPayloads(raiz, instalador));
        }

        problemas.AddRange(manifesto.Instaladores
            .SelectMany(i => i.Payloads)
            .GroupBy(p => p.Variavel, StringComparer.Ordinal)
            .Where(g => g.Count() > 1)
            .Select(g => $"variável de payload '{g.Key}' repetida no manifesto: dois componentes no mesmo cache."));

        foreach (var pendente in manifesto.Pendentes)
        {
            if (string.IsNullOrWhiteSpace(pendente.Prd))
                problemas.Add($"pendente {pendente.Projeto} sem o PRD que entrega o instalador.");

            if (!servicos.Contains(pendente.Projeto))
                problemas.Add($"pendente {pendente.Projeto} não é (mais) um Windows Service em src/ — remova a linha.");

            if (manifesto.Instaladores.Any(i => i.Projetos.Contains(pendente.Projeto)))
                problemas.Add($"{pendente.Projeto} já tem instalador e continua em 'pendentes' — remova a pendência.");
        }

        problemas.AddRange(manifesto.Instaladores
            .GroupBy(i => i.Servico, StringComparer.Ordinal)
            .Where(g => g.Count() > 1)
            .Select(g => $"serviço duplicado: {g.Key}."));

        Assert.True(problemas.Count == 0, string.Join(Environment.NewLine, problemas));
    }

    /// <summary>
    /// Todo canal com pipeline de empacotamento tem ao menos um instalador na matriz (PRD-INSTDEV-01).
    /// </summary>
    /// <remarks>
    /// O job <c>matriz</c> reprova em runtime com matriz vazia; esta guarda antecipa isso para o
    /// <c>dotnet test</c>, onde o custo é um teste vermelho em vez de um pipeline quebrado em todo push.
    /// A lista cobrada é a dos canais que **têm workflow** (<see cref="CanaisQueEmpacotam"/>), nunca a
    /// dos canais que o manifesto declara — ver a armadilha registrada lá.
    /// </remarks>
    [Fact]
    public void TodoCanalQueEmpacota_TemAoMenosUmInstalador()
    {
        var manifesto = Manifesto.Carregar(Raizes.Instaladores);

        var vazios = CanaisQueEmpacotam
            .Where(canal => !manifesto.Instaladores.Any(i => i.Canais.Contains(canal)))
            .ToList();

        Assert.True(
            vazios.Count == 0,
            $"Canal com pipeline e sem nenhum instalador no manifesto: {string.Join(", ", vazios)}. " +
            "O job 'matriz' do instaladores-windows.yml reprovaria o run com matriz vazia — na dev, em " +
            "todo push que tocasse os agentes. Acrescente o canal em 'canais' de alguma linha, ou " +
            "remova o workflow do canal e esta entrada de CanaisQueEmpacotam.");
    }

    /// <summary>
    /// Toda variável de payload do manifesto está no <c>env:</c> do job <c>empacotar</c> e no do diagnóstico do
    /// runner (PRD-TOTEMINST-02).
    /// </summary>
    /// <remarks>
    /// O contexto <c>vars</c> do Actions não é enumerável em runtime: o workflow só enxerga a variável que
    /// declara. Payload novo no manifesto sem a linha no <c>env:</c> faz o job reprovar com "payload ausente"
    /// mesmo com a variável criada no repositório — e o diagnóstico, que é o que deveria avisar antes, fica cego.
    /// </remarks>
    [Fact]
    public void TodaVariavelDePayload_EstaNosDoisWorkflows()
    {
        var manifesto = Manifesto.Carregar(Raizes.Instaladores);
        var workflows = new[] { "instaladores-windows.yml", "runner-windows-diagnostico.yml" };

        var faltando = (
            from payload in manifesto.Instaladores.SelectMany(i => i.Payloads)
            from workflow in workflows
            let texto = File.ReadAllText(Path.Combine(Raizes.Instaladores, ".github", "workflows", workflow))
            where !Regex.IsMatch(texto, $@"(?m)^\s*{payload.Variavel}:\s*\$\{{\{{\s*vars\.{payload.Variavel}\s*\}}\}}\s*$")
            select $"{payload.Variavel} ausente do env: de {workflow}").ToList();

        Assert.True(faltando.Count == 0, string.Join(Environment.NewLine, faltando));
    }

    /// <summary>
    /// O job <c>empacotar</c> itera os payloads da linha da matriz em vez de conhecer variáveis de serviço por nome.
    /// </summary>
    /// <remarks>
    /// Até o PRD-TOTEMINST-02 o YAML lia <c>matrix.payload</c> (booleano) e, quando verdadeiro, as duas variáveis
    /// do PrintMonitor por nome: um segundo serviço com payload viraria um <c>if</c> por serviço no YAML, a segunda
    /// fonte de verdade que o manifesto existe para evitar (armadilha h).
    /// </remarks>
    [Fact]
    public void Empacotar_IteraOsPayloadsDoManifesto()
    {
        var yml = File.ReadAllText(Path.Combine(Raizes.Instaladores, ".github", "workflows", "instaladores-windows.yml"));

        Assert.Contains("PAYLOADS: ${{ toJson(matrix.payloads) }}", yml, StringComparison.Ordinal);
        Assert.Contains("$env:PAYLOADS | ConvertFrom-Json", yml, StringComparison.Ordinal);
        Assert.DoesNotContain("matrix.payload }}", yml, StringComparison.Ordinal);
        Assert.DoesNotMatch(@"\$parametros\.(PayloadDir|DriversPayloadDir|WebView2BootstrapperPath)\s*=", yml);
    }

    /// <summary>
    /// A linha do totem declara o bootstrapper do WebView2 com o parâmetro e o arquivo de hash que o
    /// <c>build-installer.ps1</c> do totem usa — sem ele, o pacote de campo sai sem o runtime (PRD-TOTEMINST-02).
    /// </summary>
    [Fact]
    public void Totem_DeclaraOBootstrapperDoWebView2()
    {
        var totem = Manifesto.Carregar(Raizes.Instaladores).Instaladores.SingleOrDefault(i => i.Servico == "totem");
        Assert.NotNull(totem);

        var webView2 = Assert.Single(totem!.Payloads);
        Assert.Equal("WebView2BootstrapperPath", webView2.Parametro);
        Assert.Equal("webview2.sha256", webView2.Hash);

        var build = File.ReadAllText(Path.Combine(Raizes.Instaladores, totem.Script.Replace('/', Path.DirectorySeparatorChar)));
        Assert.Contains($"-ArquivoHash '{webView2.Hash}'", build, StringComparison.Ordinal);
    }

    /// <summary>
    /// Linha com <c>aguardaBackend</c> sai da matriz no job <c>matriz</c>, com aviso, quando o projeto ainda não existe
    /// no commit empacotado do backend (PRD-MGGINST-01) — e só ela.
    /// </summary>
    /// <remarks>
    /// Sem o filtro, o instalador que chega aqui antes do código chegar à <c>dev</c>/<c>prod</c> do backend derrubaria
    /// o <c>empacotar</c> em todo dispatch. Com um filtro que ignorasse o campo, qualquer projeto sumido sairia da
    /// matriz em silêncio (armadilha h): por isso o <c>::warning::</c> e o <c>select(.aguardaBackend)</c>.
    /// </remarks>
    [Fact]
    public void Matriz_TiraComAvisoSoALinhaQueAguardaOBackend()
    {
        var yml = File.ReadAllText(Path.Combine(Raizes.Instaladores, ".github", "workflows", "instaladores-windows.yml"));

        Assert.Contains("select(.aguardaBackend) | .servico", yml, StringComparison.Ordinal);
        Assert.Contains("git -C backend cat-file -e \"$sha:src/$projeto/$projeto.csproj\"", yml, StringComparison.Ordinal);
        Assert.Matches(@"echo ""::warning::'\$servico' fora da matriz", yml);
    }

    /// <summary>Problemas dos projetos de uma linha, conforme o <c>tipo</c> (PRD-MGGINST-01).</summary>
    /// <param name="instalador">Linha do manifesto.</param>
    /// <param name="servicos">Windows Services de <c>src/</c>.</param>
    /// <returns>Uma mensagem por problema.</returns>
    /// <remarks>
    /// <c>servico</c> (padrão): todo projeto é Windows Service. <c>aplicativo</c> (app de desktop, como o Migrador
    /// Galileu): o <c>.csproj</c> existe em <c>src/</c> e o projeto <b>não</b> é Windows Service — um serviço
    /// declarado como aplicativo escaparia das regras de serviço. Com <c>aguardaBackend</c>, projeto ausente de
    /// <c>src/</c> é esperado: o código ainda não chegou à branch do backend contra a qual a guarda roda.
    /// </remarks>
    private static IEnumerable<string> ProblemasDosProjetos(Instalador instalador, HashSet<string> servicos)
    {
        if (!TiposValidos.Contains(instalador.Tipo))
        {
            yield return $"'{instalador.Servico}': tipo '{instalador.Tipo}' fora de {{{string.Join(", ", TiposValidos)}}}.";
            yield break;
        }

        if (instalador.AguardaBackend is not null && string.IsNullOrWhiteSpace(instalador.AguardaBackend))
            yield return $"'{instalador.Servico}': 'aguardaBackend' vazio — informe o PR do backend ou remova o campo.";

        foreach (var projeto in instalador.Projetos)
        {
            var existe = File.Exists(Path.Combine(Raizes.Backend, "src", projeto, projeto + ".csproj"));

            if (!existe && !string.IsNullOrWhiteSpace(instalador.AguardaBackend))
                continue;

            if (instalador.Tipo == TipoServico && !servicos.Contains(projeto))
                yield return $"'{instalador.Servico}': {projeto} não é (mais) um Windows Service em src/.";

            if (instalador.Tipo == TipoAplicativo && !existe)
                yield return $"'{instalador.Servico}': src/{projeto}/{projeto}.csproj não existe no backend " +
                             "(se o código ainda não chegou à dev/prod de lá, declare 'aguardaBackend' com o PR).";

            if (instalador.Tipo == TipoAplicativo && servicos.Contains(projeto))
                yield return $"'{instalador.Servico}': {projeto} é Windows Service — declare a linha com tipo '{TipoServico}'.";
        }
    }

    /// <summary>Tipo padrão de linha: instalador de Windows Service.</summary>
    private const string TipoServico = "servico";

    /// <summary>Linha de app de desktop, sem serviço (PRD-MGGINST-01).</summary>
    private const string TipoAplicativo = "aplicativo";

    /// <summary>Valores aceitos em <c>tipo</c>.</summary>
    private static readonly string[] TiposValidos = [TipoServico, TipoAplicativo];

    /// <summary>Problemas de forma dos payloads de uma linha do manifesto.</summary>
    /// <param name="raiz">Raiz deste repositório.</param>
    /// <param name="instalador">Linha do manifesto.</param>
    /// <returns>Uma mensagem por problema.</returns>
    private static IEnumerable<string> ProblemasDosPayloads(string raiz, Instalador instalador)
    {
        var caminhoDoScript = Path.Combine(raiz, instalador.Script.Replace('/', Path.DirectorySeparatorChar));
        var script = File.Exists(caminhoDoScript) ? File.ReadAllText(caminhoDoScript) : string.Empty;

        foreach (var payload in instalador.Payloads)
        {
            if (!VariavelDePayloadRegex().IsMatch(payload.Variavel ?? string.Empty))
                yield return $"'{instalador.Servico}': variável de payload '{payload.Variavel}' fora de ^[A-Z][A-Z0-9_]*_PAYLOAD_DIR$.";

            if (payload.Hash is null || !payload.Hash.EndsWith(".sha256", StringComparison.Ordinal))
                yield return $"'{instalador.Servico}': payload '{payload.Variavel}' sem arquivo .sha256 em 'hash'.";

            if (string.IsNullOrWhiteSpace(payload.Descricao) || string.IsNullOrWhiteSpace(payload.SeAusente))
                yield return $"'{instalador.Servico}': payload '{payload.Variavel}' sem 'descricao' ou 'seAusente' (o diagnóstico fica mudo).";

            // O job passa a pasta por splatting (`$parametros[<parametro>]`): parâmetro que o script não declara
            // derruba o empacotamento com "A parameter cannot be found", só no runner.
            if (string.IsNullOrWhiteSpace(payload.Parametro) ||
                !Regex.IsMatch(script, $@"\[string\]\s*\${Regex.Escape(payload.Parametro)}\b", RegexOptions.IgnoreCase))
                yield return $"'{instalador.Servico}': '{instalador.Script}' não declara o parâmetro [string] ${payload.Parametro}.";
        }
    }

    /// <summary>Nome aceito para a variável de repositório de um cache de payload.</summary>
    [GeneratedRegex("^[A-Z][A-Z0-9_]*_PAYLOAD_DIR$")]
    private static partial Regex VariavelDePayloadRegex();


    /// <summary>Projetos de <c>src/</c> cujo código registra o host como Windows Service.</summary>
    /// <returns>Nomes dos projetos (pasta sob <c>src/</c>).</returns>
    private static HashSet<string> ProjetosWindowsService()
    {
        var src = Path.Combine(Raizes.Backend, "src");

        return Directory.GetDirectories(src)
            .Where(projeto => File.Exists(Path.Combine(projeto, Path.GetFileName(projeto) + ".csproj")))
            .Where(projeto => Directory
                .EnumerateFiles(projeto, "*.cs", SearchOption.AllDirectories)
                .Where(NaoEhSaidaDeBuild)
                .Any(arquivo => RegistroWindowsServiceRegex().IsMatch(File.ReadAllText(arquivo))))
            .Select(projeto => Path.GetFileName(projeto)!)
            .ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>Descarta <c>bin/</c> e <c>obj/</c> (código gerado não decide nada aqui).</summary>
    /// <param name="arquivo">Caminho do arquivo.</param>
    /// <returns><c>true</c> quando o arquivo é fonte.</returns>
    private static bool NaoEhSaidaDeBuild(string arquivo)
    {
        var separador = Path.DirectorySeparatorChar;
        return !arquivo.Contains($"{separador}bin{separador}", StringComparison.Ordinal)
               && !arquivo.Contains($"{separador}obj{separador}", StringComparison.Ordinal);
    }


    /// <summary>Conteúdo de <c>installer/instaladores-ci.json</c>.</summary>
    /// <param name="Instaladores">Instaladores que o CI empacota.</param>
    /// <param name="Pendentes">Windows Services ainda sem instalador, com o PRD que o entrega.</param>
    private sealed record Manifesto(List<Instalador> Instaladores, List<Pendente> Pendentes)
    {
        /// <summary>Lê o manifesto do repositório.</summary>
        /// <param name="raiz">Raiz do repositório.</param>
        /// <returns>Manifesto desserializado.</returns>
        public static Manifesto Carregar(string raiz)
        {
            var caminho = Path.Combine(raiz, "installer", "instaladores-ci.json");
            Assert.True(File.Exists(caminho), $"Manifesto ausente: {caminho}.");

            var manifesto = JsonSerializer.Deserialize<Manifesto>(
                File.ReadAllText(caminho),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

            Assert.NotNull(manifesto);

            // `Canais` ausente no JSON desserializa como null; normalizar aqui faz a guarda reprovar com
            // a mensagem útil em vez de estourar NullReferenceException na primeira regra que o lê.
            return manifesto! with
            {
                Instaladores = (manifesto!.Instaladores ?? [])
                    .Select(i => i with
                    {
                        Projetos = i.Projetos ?? [],
                        Payloads = i.Payloads ?? [],
                        Canais = i.Canais ?? [],
                        Tipo = i.Tipo ?? TipoServico
                    })
                    .ToList(),
                Pendentes = manifesto.Pendentes ?? []
            };
        }
    }

    /// <summary>Linha de <c>instaladores</c>.</summary>
    /// <param name="Servico">Identificador na matriz do CI.</param>
    /// <param name="Nome">Prefixo do executável gerado.</param>
    /// <param name="Script">Caminho do <c>build-installer.ps1</c>, relativo à raiz.</param>
    /// <param name="Projetos">Windows Services empacotados por este instalador.</param>
    /// <param name="Payloads">Binários de terceiro que o pacote embute a partir de um cache do runner (PRD-TOTEMINST-02).</param>
    /// <param name="Canais">Canais em que o CI empacota esta linha (<c>dev</c>, <c>prod</c>).</param>
    /// <param name="Tipo"><c>servico</c> (padrão) ou <c>aplicativo</c> (PRD-MGGINST-01).</param>
    /// <param name="AguardaBackend">PR do backend que ainda não chegou à dev/prod de lá, ou <c>null</c> (PRD-MGGINST-01).</param>
    private sealed record Instalador(
        string Servico,
        string Nome,
        string Script,
        List<string> Projetos,
        List<Payload> Payloads,
        List<string> Canais,
        string Tipo,
        string? AguardaBackend);

    /// <summary>Item de <c>payloads</c>: um binário de terceiro vindo do cache do runner.</summary>
    /// <param name="Parametro">Parâmetro do <c>build-installer.ps1</c> que recebe a pasta do cache.</param>
    /// <param name="Variavel">Variável de repositório com o caminho do cache (no <c>env:</c> dos workflows).</param>
    /// <param name="Hash">Arquivo <c>.sha256</c> que pina o binário dentro da pasta.</param>
    /// <param name="Descricao">Nome legível do componente, usado nas mensagens.</param>
    /// <param name="SeAusente">Efeito de o cache faltar, para o diagnóstico do runner.</param>
    private sealed record Payload(string Parametro, string Variavel, string Hash, string Descricao, string SeAusente);

    /// <summary>Linha de <c>pendentes</c>.</summary>
    /// <param name="Projeto">Windows Service sem instalador.</param>
    /// <param name="Prd">PRD que entrega o instalador.</param>
    private sealed record Pendente(string Projeto, string Prd);
}
