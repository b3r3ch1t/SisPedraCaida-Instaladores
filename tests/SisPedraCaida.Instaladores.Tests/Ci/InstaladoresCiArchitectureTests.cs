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
/// Service novo (o Totem, por exemplo) nasceria compilando, testado e com Dockerfile nenhum — e
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
            $"Esperava ao menos Tef.Agent, PrintMonitor.Service e Balanca.Agent; achei {servicos.Count}: {string.Join(", ", servicos)}.");

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

            problemas.AddRange(instalador.Projetos
                .Where(p => !servicos.Contains(p))
                .Select(p => $"'{instalador.Servico}': {p} não é (mais) um Windows Service em src/."));

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
        }

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
    /// O instalador da balança registra o serviço com o MESMO nome que o agente declara em
    /// <c>UseWindowsService</c>.
    /// </summary>
    /// <remarks>
    /// Sem <c>Setup.exe</c>, o nome vive em dois lugares: o <c>.iss</c> (que registra, para e remove
    /// o serviço) e o <c>Program.cs</c> (que o host usa para se reconhecer). Divergir registra um
    /// serviço que o host não reconhece, e o instalador seguinte para/remove um serviço que não
    /// existe — deixando o antigo órfão (armadilha #101c).
    /// </remarks>
    [Fact]
    public void InstaladorDaBalanca_UsaONomeDeServicoDoAgente()
    {
        var raiz = Raizes.Instaladores;
        var programa = File.ReadAllText(Path.Combine(Raizes.Backend, "src", "SisPedraCaida.Balanca.Agent", "Program.cs"));
        var iss = File.ReadAllText(Path.Combine(raiz, "installer", "balanca", "BalancaAgent.iss"));

        var noAgente = NomeServicoAgenteRegex().Match(programa);
        var noInstalador = NomeServicoIssRegex().Match(iss);

        Assert.True(noAgente.Success, "ServiceName não encontrado no Program.cs do Balanca.Agent.");
        Assert.True(noInstalador.Success, "#define ServicoNome não encontrado no BalancaAgent.iss.");
        Assert.Equal(noAgente.Groups[1].Value, noInstalador.Groups[1].Value);
    }

    /// <summary><c>ServiceName = "..."</c> do <c>UseWindowsService</c>.</summary>
    [GeneratedRegex("""ServiceName\s*=\s*"([^"]+)"\s*\)""")]
    private static partial Regex NomeServicoAgenteRegex();

    /// <summary><c>#define ServicoNome "..."</c> do <c>.iss</c>.</summary>
    [GeneratedRegex("""#define\s+ServicoNome\s+"([^"]+)"\s*""")]
    private static partial Regex NomeServicoIssRegex();

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
                    .Select(i => i with { Projetos = i.Projetos ?? [], Canais = i.Canais ?? [] })
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
    /// <param name="Payload">Se o instalador embute payload de terceiro vindo do cache do runner.</param>
    /// <param name="Canais">Canais em que o CI empacota esta linha (<c>dev</c>, <c>prod</c>).</param>
    private sealed record Instalador(
        string Servico,
        string Nome,
        string Script,
        List<string> Projetos,
        bool Payload,
        List<string> Canais);

    /// <summary>Linha de <c>pendentes</c>.</summary>
    /// <param name="Projeto">Windows Service sem instalador.</param>
    /// <param name="Prd">PRD que entrega o instalador.</param>
    private sealed record Pendente(string Projeto, string Prd);
}
