# PRD-PMSEL-INST-02 — Seleção das impressoras da estação no instalador do PrintMonitor

> **Status:** Concluído — **Última atualização:** 30/10/2026 17:58

## Contexto

Épico `printmonitor-instalador-impressoras`, continuação do `printmonitor-selecao-impressora`
([`PRD/DONE/printmonitor-selecao-impressora/`](../../DONE/printmonitor-selecao-impressora/)). Desde o PRD-PMSEL-AG-01 do
backend (PR #1348) o técnico escolhe **quais filas do spooler a estação usa e qual é a padrão** — e só a fila escolhida,
de qualquer modelo, é aceita pelo servidor. Hoje essa escolha só existe **depois** da instalação, no
`Setup.exe --config-ui` (atalho e bandeja "Configurar PrintMonitor…"). O técnico instala, a estação sobe sem impressora
habilitada e ele precisa lembrar de abrir o editor.

Pedido do usuário (30/10/2026): **o instalador deve selecionar as impressoras que vão estar disponíveis para o
PrintMonitor**, e a configuração da bandeja **continua** com a opção de configurar a impressora.

O contrato com o C# **já existe** (PRD-PMSEL-AG-01): o `Setup.exe` lê `ImpressorasHabilitadas` (filas separadas por `|`)
e `ImpressoraPadrao` do arquivo de resposta (`--config-file`) e grava as variáveis de máquina
`PrintMonitor__Enrollment__ImpressorasHabilitadas` / `__ImpressoraPadrao`, que o Helper relê a cada coleta. Esta etapa é
**só este repositório** — nenhuma mudança de código no backend.

## Decisões

| # | Decisão | Por quê |
|---|---|---|
| D1 | Página nova **"Impressoras desta estação"** depois da "Identificação pelo navegador": lista com caixa de marcar das filas do spooler + lista suspensa da **padrão**, restrita às marcadas | Mesma forma do `--config-ui` (`StationConfigurationForm`), que o técnico já conhece |
| D2 | Filas lidas por **WMI `Win32_Printer`** (`Name`), a mesma fonte do `WmiPrinterInventoryCollector` | O nome marcado precisa ser exatamente o `NomeSistema` que o inventário manda; outra fonte (registro do spooler) não traz as conexões de rede do usuário |
| D3 | Escolha já gravada na estação vem **marcada**; escolhida que o spooler não tem aparece marcada com "(não encontrada nesta máquina)" | Espelha `SelecaoImpressorasEstacao.MontarOpcoes`: num upgrade, a fila de uma impressora desligada não some em silêncio |
| D4 | Normalização espelha `SelecaoImpressorasEstacao.Criar`: apara, descarta vazio e repetição (sem diferenciar maiúsculas), a padrão entra nas habilitadas (na frente, se faltava) | A padrão fora da lista seria ignorada pelo servidor |
| D5 | A escolha vai ao `Setup.exe` **pelo arquivo de resposta** (`ImpressorasHabilitadas=`, `ImpressoraPadrao=`) e **só quando difere da gravada** | Mesma regra das origens: reenviar o igual não muda nada, e o arquivo já é o canal do instalador. Nome de fila com espaço não sofre com aspas na linha de comando |
| D6 | **Nenhuma marcada = mantém o que está gravado** (o `Setup.exe` preserva quando as duas chaves faltam). Com escolha gravada, o Avançar avisa que ela será mantida e aponta o "Configurar PrintMonitor" para retirá-la; sem escolha gravada, avisa que só os modelos homologados do servidor serão aceitos | O `Setup.exe` não tem como receber "nenhuma" (vazio = ausente). Mudar isso seria contrato novo nos dois repos para um caso que o editor da bandeja já resolve |
| D7 | Silencioso: `/IMPRESSORAS="A|B"` e `/IMPRESSORAPADRAO="A"`, ou as mesmas chaves no `/CONFIGFILE`. Precedência: arquivo → parâmetro → gravado. Fila informada que o spooler não tem **não bloqueia** (só log) | O driver pode ser instalado depois; o `--config-ui` também aceita e sinaliza |
| D8 | A bandeja **não muda**: "Configurar PrintMonitor…" segue abrindo o `--config-ui` com a seção de impressoras | Pedido do usuário. A tela final e o texto da página passam a citar o atalho para trocar as impressoras depois |

## Mudanças

1. `installer/printmonitor/pages.iss`: página `PaginaImpressoras` (`TNewCheckListBox` + `TNewComboBox`), leitura do
   spooler por WMI, normalização, valores iniciais (arquivo → parâmetro → gravado), validação do Avançar e o resumo.
2. `installer/printmonitor/provisioning.iss`: `GravarArquivoDeResposta` leva `ImpressorasHabilitadas`/`ImpressoraPadrao`
   quando a escolha difere da gravada.
3. `installer/printmonitor/PrintMonitor.iss`: cabeçalho com os parâmetros novos, bloco no "Pronto para instalar" e texto
   da tela final.
4. Guardas xUnit (`InstaladorInnoGuardTests`): chaves do arquivo de resposta lidas pelo `Setup.exe` e gravadas nas
   variáveis certas; nomes das variáveis de máquina e separador iguais aos do C#; precedência dos valores iniciais.
5. Docs: `CLAUDE.md` deste repo; no backend, `docs/PrintMonitorInstalador.md` (PR de docs à parte, sem código).

## Critérios de aceite

- [x] Pester (65/65) e guardas (96/96, contra a `dev` do backend) verdes.
- [x] O `.iss` compila (ISCC com layout de teste). A seção nova rodou num script de teste descartável em
  `/VERYSILENT` (WMI real, normalização, lista e padrão, parâmetros com a barra vertical, `/CONFIGFILE` UTF-8 com e
  sem BOM, precedência chave a chave).
- [x] PR para a `dev`.

## Não testado / pós-merge

- O wizard interativo (aparência da página, cliques, caixas do Avançar) **não** foi exercitado: conferir a lista e a
  padrão no primeiro pacote da `dev`.
- ⚠️ **Ordem de promoção (armadilha x):** a `prod` do backend ainda **não** tem o PRD-PMSEL-AG-01 (#1348) em
  30/10/2026 — as guardas novas não compilam contra ela e o `Setup.exe` de lá ignoraria as chaves. Promover este repo
  para a `prod` só **depois** da promoção do backend que leve o #1348.
- Backend: `docs/PrintMonitorInstalador.md` atualizado num PR de docs à parte (§5.2, §5.3, §5.5, §7.2, §7.3, §8.2).
