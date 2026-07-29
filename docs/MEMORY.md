# Diagnóstico de memória no Windows

O objetivo deste projeto é identificar pressão real de memória sem encerrar
processos, limpar RAM, alterar o page file ou instalar ferramentas no
computador.

## Coleta recomendada

Uma janela de um minuto é o mínimo usado pelo coletor padrão:

```powershell
pwsh -NoProfile -File .\scripts\collect-memory.ps1
```

Para observar crescimento por cinco minutos:

```powershell
pwsh -NoProfile -File .\scripts\collect-memory.ps1 `
  -SampleCount 61 `
  -SampleIntervalSeconds 5
```

O script grava um JSON completo e um resumo Markdown em `reports\`. Os
relatórios são locais e podem conter nomes de processos, caminhos e mensagens
de eventos; não devem ser versionados.

Os contadores do sistema são coletados em todos os intervalos. Para reduzir o
próprio impacto da medição, os processos são enumerados no início e no fim da
janela. A coleta usa classes CIM com nomes estáveis, sem depender da tradução
dos nomes exibidos pelo Performance Monitor.

## O que cada métrica significa

| Métrica | Interpretação |
|---|---|
| Memória disponível | RAM que o Windows pode entregar imediatamente sem paginação significativa |
| Working Set | Páginas de um processo que estão residentes na RAM naquele instante; parte pode ser compartilhada |
| Private Bytes | Memória comprometida exclusivamente pelo processo; é mais útil que o Working Set para acompanhar crescimento |
| Committed Bytes | Carga de commit de todo o sistema, garantida por RAM ou page file |
| Commit Limit | Limite atual de commit, normalmente relacionado à RAM e aos page files |
| Pages Output/sec | Páginas gravadas para liberar RAM; crescimento sustentado ajuda a distinguir pressão real de um cache saudável |
| Pools paged/nonpaged | Memória do kernel e de drivers; crescimento contínuo pode exigir análise por tag |
| Standby/cache | Conteúdo reaproveitável pelo Windows; não é, por si só, memória “presa” |

Commit acima da RAM física não comprova falta de memória. O contexto importa:
memória disponível, proximidade do limite de commit e paginação sustentada
devem ser avaliados juntos.

## Classificação do projeto

O resumo usa os limites de referência da Microsoft e o gate conservador deste
repositório:

- `CRITICO`: menos de 500 MB ou 1% disponível, ou commit em 80% ou mais;
- `ALERTA`: commit entre 60% e 80%, ou menos de 10% e menos de 4 GB
  disponíveis;
- `OBSERVAR`: commit acima de 50%, sem atingir os limites de alerta;
- `SAUDAVEL`: nenhuma das condições anteriores.

Uma mudança no host continua bloqueada quando houver menos de 4 GB
disponíveis, commit em 80% ou mais, Windows Terminal acima dos limites do
`AGENTS.md`, ou qualquer outro gate de segurança aplicável. O resultado
`MemoryOnlyHostChangeGatePassed` verifica apenas a parte de memória; ele não
substitui as validações de disco, terminal, escopo e aprovação.

## Crescimento não é automaticamente vazamento

O coletor compara o primeiro e o último valor de Private Bytes por PID e lista
“candidatos de crescimento”. Uma janela curta pode capturar inicialização,
cache, compilação ou carga legítima. Para tratar como suspeita de vazamento,
procure crescimento contínuo durante uma carga repetível e uma janela maior.

O evento `2004` do `Resource-Exhaustion-Detector`, quando presente no log
System, é incluído porque registra os maiores consumidores no momento de
exaustão. A ausência do evento não prova que o sistema esteve saudável.

## Investigação avançada, sempre manual

O relatório apenas informa se estas ferramentas já estão disponíveis; nunca
as instala nem as executa:

- **VMMap**: composição da memória virtual e física de um processo;
- **RAMMap**: distribuição da RAM física, cache, standby, kernel e processos;
- **WPR/WPA**: rastreamento temporal para aplicações e drivers;
- **PoolMon**: crescimento de pools do kernel por tag;
- **System Informer**: árvore, gráficos e estatísticas de processos em tempo real;
- **PerfView/dotnet-trace**: ETW ou EventPipe para alocações e heaps .NET.

Heap tracing com WPR pode exigir elevação e alterar configuração de
instrumentação do executável. Por isso ele é uma etapa avançada, nominal e
fora da coleta padrão.

## O que não fazer

- Não encerrar Terminal ou CLIs para “liberar memória”.
- Não esvaziar working sets ou standby cache automaticamente.
- Não alterar o page file com base em uma única amostra.
- Não chamar crescimento de vazamento sem tendência sustentada.
- Não usar um “RAM cleaner” como correção de causa raiz.

## Fontes oficiais

- [Troubleshoot performance problems in Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-performance-problems-in-windows)
- [Memory Performance Information](https://learn.microsoft.com/en-us/windows/win32/memory/memory-performance-information)
- [Troubleshoot application or service memory leaks](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-application-service-memory-leaks)
- [Introduction to the page file](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/ram-virtual-memory-pagefile-management)
- [VMMap](https://learn.microsoft.com/en-us/sysinternals/downloads/vmmap)
- [RAMMap](https://learn.microsoft.com/en-us/sysinternals/downloads/rammap)
- [PoolMon](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/poolmon)
- [Recording for heap analysis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/recording-for-heap-analysis)
- [System Informer](https://github.com/winsiderss/systeminformer)
- [PerfView](https://github.com/microsoft/perfview)
