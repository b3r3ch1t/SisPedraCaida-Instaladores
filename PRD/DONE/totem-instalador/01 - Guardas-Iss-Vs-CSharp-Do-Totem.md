# PRD-TOTEMINST-01 — Guardas `.iss` × C# do totem

> **Status:** Concluído — **Última atualização:** 27/10/2026 17:35

## Objetivo

Cada regra que `installer/totem/*.iss` espelha do C# do totem ganha um teste em
`tests/SisPedraCaida.Instaladores.Tests/Totem/`, no padrão das guardas do PrintMonitor: ler o `.iss` por regex e
comparar com a constante **compilada** do backend. O totem também entra na política de upgrade comum. Fecha as
lacunas L1 e L2 do master.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | Duas classes: `TotemInnoGuardTests` (contrato `.iss` × C#) e `TotemUpgradeGuardTests` (upgrade e desinstalação) | Mesmo recorte de `PrintMonitor/InstaladorInnoGuardTests` e `PrintMonitor/InstaladorUpgradeGuardTests` |
| D2 | A normalização da URL é travada por **vetores** aplicados ao C# mais **âncoras** no Pascal | Não dá para executar Pascal Script no teste. O que se garante é que o C# ainda produz o que o `.iss` promete e que a função Pascal ainda tem as mesmas regras-chave |
| D3 | Os parâmetros do Inno (`/APIURL=`, `/NOME=`, `/LOCAL=`, `/CONTEUDOURL=`) são conferidos contra o runbook do backend | Não têm constante C#; o runbook é o contrato público com a TI e está em `Raizes.Backend` |
| D4 | Se o restore ou a compilação recusarem a referência ao `Totem.Setup`, cair para leitura por regex de `ModoDoSetup.cs` | Plano B já usado pela guarda da balança (`InstaladorDaBalanca_UsaONomeDeServicoDoAgente`) |

## Pré-requisito no backend

O runbook `docs/TotemInstalacaoWindows.md` documenta só `/APIURL=`, `/NOME=` e `/LOCAL=` (§2, linha "Silencioso").
O `pages.iss` também lê `/CONTEUDOURL=`. **Antes deste PR**, um PR só de doc no backend acrescenta `/CONTEUDOURL=`
ao §2 (sem build nem testes, regra do `CLAUDE.md`). Sem ele, o teste
`ParametrosDoInno_NoIss_SaoOsDocumentadosNoBackend` nasce vermelho no `ci.yml`, que roda contra a `dev` do backend.

## Mudanças

### 1. `tests/SisPedraCaida.Instaladores.Tests/SisPedraCaida.Instaladores.Tests.csproj`

No `ItemGroup` dos `ProjectReference`, ao lado dos do PrintMonitor:

```xml
<ProjectReference Include="$(BackendDir)src\SisPedraCaida.Totem.Agent\SisPedraCaida.Totem.Agent.csproj" />
<ProjectReference Include="$(BackendDir)src\SisPedraCaida.Totem.Setup\SisPedraCaida.Totem.Setup.csproj" />
```

Comentário XML explicando D1 e D2 do master. O comentário **não pode conter `--`**: o MSBuild recusa o arquivo.

### 2. `tests/SisPedraCaida.Instaladores.Tests/Totem/TotemInnoGuardTests.cs`

Pasta do instalador: `installer/totem`. Helper `Ler(arquivo)` igual ao das outras guardas.

| Teste | Lê do `.iss` | Compara com (backend) |
|---|---|---|
| `NomeDoServico_NoIss_EhOMesmoDoTotemPaths_EDoAddWindowsService` | `#define\s+ServicoNome\s+"([^"]+)"` em `Totem.iss` | `TotemPaths.NomeServico`; e, por regex no `src/SisPedraCaida.Totem.Agent/Program.cs`, `options.ServiceName = TotemPaths.NomeServico` (o host usa a constante, não um literal) |
| `Executaveis_NoIss_SaoOsMesmosDoTotemPaths` | `#define SetupExe`, `#define AgenteExe`, `#define CascaExe` em `Totem.iss` | `TotemPaths.ExecutavelDoSetup`, `ExecutavelDoServico`, `ExecutavelDaCasca`; os três também em `$essenciais` do `build-installer.ps1` |
| `PastaDeDados_NoIss_EhAMesmaDoTotemPaths` | `#define PastaDados "{commonappdata}\…"`; nomes `identidade.json`, `estado-bloqueio.json`, `totem.settings.json` nos includes; subpastas `logs`, `config`, `web` | Sufixo de `TotemPaths.PastaDados` relativo a `CommonApplicationData`; `TotemPaths.NomeArquivo*`; `PastaLogs`, `PastaConfiguracao`, `PastaWeb` |
| `CodigosDeSaida_NoIss_SaoOsDoSetup` | `provisioning.iss`: `if Codigo <> 0 then`, `if Codigo = 2`, `else if Codigo = 3`; `(Codigo = 0)` na desinstalação | `CodigosDeSaida.Sucesso == 0`, `Cancelado == 2`, `ArgumentoInvalido == 3`. `Falha == 1` não tem ramo próprio: assert de que só existem esses dois `Codigo =` com valor diferente de zero no tratamento do provisionamento |
| `ParametrosDoSetup_NoIss_SaoOsParametrosComValor` | `ParametroSeAlterado\('(--[a-z-]+)'` (4 ocorrências em `provisioning.iss`), `'--all'`, `'--uninstall'` | Conjunto igual a `LinhaDeComando.ParametrosComValor`; `LinhaDeComando.Modo(["--all"]) == ModoDoSetup.Tudo`; `Modo(["--uninstall"]) == ModoDoSetup.Desinstalar` |
| `RotaDaSonda_NoIss_EhATotensEnrollment` | `Requisicao.Open('POST', Url + '…'` em `pages.iss` | `SuperficieForaDoNavegador.TotensEnrollment` (`/api/v1/Totens/enrollment`); e regex de `SuperficieForaDoNavegador.TotensEnrollment` em `Provisionamento/ImplementacoesWindows.cs` (a sonda do Setup usa a constante) |
| `NormalizacaoDaApiUrl_NoIss_EspelhaATotemSettingsFile` | Âncoras em `pages.iss`: `function NormalizarApiUrl(`, a busca de `/api` só no caminho, a retirada da barra final | Vetores em `TotemSettingsFile.NormalizarOrigem`: `https://api.exemplo/` → `https://api.exemplo`; `https://host/api/v1/` → `https://host`; `https://api.exemplo` inalterado (host que começa por `api.`); `"  https://h  "` → `https://h`; `""` → `null` |
| `CamposGravados_NoIss_SaoAsSecoesEChavesDoTotemSettings` | `ValorGravado\('(\w+)', '(\w+)'\)` (4 pares em `pages.iss`) | `(TotemSettings.SecaoApi, nameof(ApiOptions.BaseUrl))`, `(SecaoTerminal, nameof(TerminalOptions.Nome))`, `(SecaoTerminal, nameof(TerminalOptions.Local))`, `(SecaoConteudo, nameof(ConteudoOptions.Url))` |
| `ParametrosDoInno_NoIss_SaoOsDocumentadosNoBackend` | `Parametro\('([A-Z]+)'\)` em `pages.iss` (`APIURL`, `NOME`, `LOCAL`, `CONTEUDOURL`) | Cada `/<NOME>=` aparece em `docs/TotemInstalacaoWindows.md` do backend (ver pré-requisito) |
| `Provisionamento_PorExec_NaoPorRun_EComRollback` | `[Run]` do `Totem.iss` sem `{#SetupExe}`; em `provisioning.iss`, `ExecutarSetup(ArgumentosDoSetup()`, `DesprovisionarAposFalha()` no ramo `Codigo <> 0` e `RaiseException` | Decisão travada, sem lado C# (armadilha #101a: o `[Run]` do Inno ignora o código de saída) |
| `WebView2_EhAvisoNaoBloqueio_EBootstrapperEOpcionalNoBuild` | `#ifndef WebView2Bootstrapper` e `#define WebView2Bootstrapper ""` em `Totem.iss`; `Check: WebView2DaMaquinaAusente`; o corpo de `InstalarWebView2SeNecessario` sem `RaiseException` nem `DesprovisionarAposFalha`; `'/silent /install'`; no `build-installer.ps1`, `-ArquivoHash 'webview2.sha256'` | Decisão travada; o PRD-02 depende dela |
| `ComentariosPascal_NoIss_NaoTemChaveAninhada` (`[Theory]` com `checks.iss`, `pages.iss`, `provisioning.iss`) | Regex `\{(?!#)[^}]*\{` | Mesma regra do PrintMonitor. O `Totem.iss` principal fica fora por causa de `AppId={{…}`, como lá |

### 3. `tests/SisPedraCaida.Instaladores.Tests/Totem/TotemUpgradeGuardTests.cs`

| Teste | O que trava |
|---|---|
| `AppId_EhEstavel_EProprio_ELidoPelaChaveDeDesinstalacao` | `AppId={{C9D9108B-9DB0-450D-986B-7470728B6123}` em `Totem.iss`; o mesmo GUID com `_is1` em `checks.iss`; GUID ausente de `TefAgent.iss` e `PrintMonitor.iss` |
| `PrepareToInstall_TiraOServicoDoCaminho_SemDesinstaladorAnterior` | `Result := PrepararUpgrade();` em `Totem.iss`; o corpo de `PrepararUpgrade` chama `PararServicoEConfirmar()`, `EncerrarProcesso('{#CascaExe}')` e `EncerrarProcessosDaPasta(…, ExpandConstant('{srcexe}'), …)`, e **não** contém `'--uninstall'`, `UninstallString` nem condição sobre instalação anterior |
| `Desinstalacao_ParaServico_FechaCasca_EChamaUninstallPorExec` | `CurUninstallStepChanged` chama `DesprovisionarParaDesinstalar();`; no corpo, `PararServicoEConfirmar()` antes de `EncerrarProcesso('{#CascaExe}')` antes de `ExecutarSetup('--uninstall'` (índices crescentes); `Totem.iss` sem `[UninstallRun]` e sem `[Registry]` ativos (a Run key da casca é do `Setup.exe --all`) |
| `FechamentoPorCaminho_CsvEWmi_ERestartreplace` | Em `provisioning.iss`: `FROM Win32_Process WHERE ExecutablePath LIKE`, `/FO CSV /NH`, `PrefixoDosExecutaveis = 'SISPEDRACAIDA.'`; em `Totem.iss`: `Flags: recursesubdirs createallsubdirs ignoreversion restartreplace uninsrestartdelete` |

### 4. `tests/SisPedraCaida.Instaladores.Tests/Ci/InstaladoresUpgradeArchitectureTests.cs`

- `{ "totem", "Totem.iss" }` entra na `TheoryData Instaladores`. Os três `[Theory]` passam sem mudança (conferido
  por regex em 27/10/2026).
- `<summary>` e `<remarks>` passam a citar o totem: ele segue a política do PrintMonitor (upgrade no lugar, sem o
  desinstalador anterior).

### 5. `CLAUDE.md` deste repositório

- Linha do totem na tabela de instaladores cita as guardas em `tests/…/Totem/`.
- Seção "Duas procedências": a lista de projetos do backend referenciados pelo projeto de testes inclui
  `Totem.Agent` e `Totem.Setup`, nunca `Totem.Shell`.

## Critérios de aceite

1. `dotnet test tests/SisPedraCaida.Instaladores.Tests -p:BackendDir=<backend na origin/dev>/` verde, com as duas
   classes novas e o totem na theory de upgrade. Usar um worktree do backend na `origin/dev`
   (`C:\repos\SisPedraCaida\.worktrees\…`), não o clone local, que está atrasado.
2. Prova por mutação, feita à mão e revertida. Cada mutação deixa vermelho exatamente o teste indicado:

   | Mutação | Teste que reprova |
   |---|---|
   | `#define ServicoNome` com outro valor | `NomeDoServico_…` |
   | `if Codigo = 2` trocado por `= 4` | `CodigosDeSaida_…` |
   | Rota da sonda trocada | `RotaDaSonda_…` |
   | `restartreplace` removido | `FechamentoPorCaminho_…` |
   | `'--conteudo-url'` renomeado | `ParametrosDoSetup_…` |

3. `pwsh installer/common/Invoke-TestesEmpacotamento.ps1` sem regressão (o módulo não muda).
4. `ci.yml` verde no PR: o `windows-latest` compila `Totem.Agent` e `Totem.Setup` a partir da `dev` do backend.

## Entregue (27/10/2026)

- Pré-requisito no backend: PR [b3r3ch1t/SisPedraCaida-Backend#1272](https://github.com/b3r3ch1t/SisPedraCaida-Backend/pull/1272)
  (`docs/totem-conteudourl`), com a tabela dos quatro parâmetros do silencioso no runbook. **Mesclada** em 27/10/2026.
- `ProjectReference` a `Totem.Agent` e `Totem.Setup`. O plano B (D4) não foi necessário: compila e roda.
- `Totem/TotemInnoGuardTests.cs`: 14 métodos, 21 casos com os vetores da normalização. Além do previsto, o teste
  dos parâmetros do Setup simula a linha que o `.iss` monta (`--nome "AUTO-02"`, `--conteudo-url=`) e confere que o
  `LinhaDeComando` a lê sem argumento desconhecido; o dos parâmetros do Inno confere o par
  `/APIURL=` → `--api-url` (e os outros três) pela variável que liga os dois.
- `Totem/TotemUpgradeGuardTests.cs`: 4 testes. O AppId também não pode aparecer no `BalancaAgent.iss`.
- `{ "totem", "Totem.iss" }` na `TheoryData` de `InstaladoresUpgradeArchitectureTests` (+3 casos).
- Resultado: guardas **85/85** (eram 57) contra o backend `origin/dev` + #1272; Pester **60/60**.

### Prova por mutação (revertida)

| Mutação | Reprovou |
|---|---|
| `#define ServicoNome` com outro valor | `NomeDoServico_…` |
| `if Codigo = 2` → `= 4` | `CodigosDeSaida_…` |
| Rota da sonda `enrolment` | `RotaDaSonda_…` |
| `restartreplace` removido | `FechamentoPorCaminho_…` |
| `'--conteudo-url'` → `'--conteudourl'` | `ParametrosDoSetup_…` e `ParametrosDoInno_…` (os dois leem o parâmetro) |
| Runbook do backend sem `/CONTEUDOURL=` | `ParametrosDoInno_…` |
| AppId trocado no `Totem.iss` | `AppId_…` |
| `PrepararUpgrade` chamando `--uninstall` | `PrepareToInstall_…` |

Critério 4 fechado: o `ci.yml` da [#8](https://github.com/b3r3ch1t/SisPedraCaida-Instaladores/pull/8)
(`windows-latest`, guardas contra a `dev` do backend já com o #1272) passou em 3m12s, com commitlint, título e
GitGuardian verdes.
