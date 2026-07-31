---
name: custo-varredura
description: Descobre o que o antimalware está varrendo e quanto isso custa, usando a contabilidade do próprio motor. Use quando a máquina estiver lenta, quando MsMpEng aparecer no topo de CPU, ou antes de pedir exclusão à área de segurança. Somente leitura.
---

# Custo de varredura do antimalware

Responde **o que está sendo varrido** e **quanto tempo isso custa**, com a
medição que o próprio motor registra — não com inferência.

## Quando usar

- a máquina está lenta e `MsMpEng.exe` aparece entre os maiores consumidores;
- há varredura em andamento e você quer saber onde ela está gastando tempo;
- antes de abrir chamado pedindo exclusão, para levar número em vez de opinião;
- depois de uma exclusão ser aplicada, para confirmar que o custo caiu.

Não use como monitoramento contínuo. A leitura custa mais que uma amostra comum
do painel e a resposta muda devagar: minutos de trabalho acumulado não mudam de
forma útil a cada segundo. O painel já faz isso sozinho, com trava de condição e
cache — veja "No painel", abaixo.

## Pré-requisitos

- Windows com Microsoft Defender ativo.
- **Privilégio administrativo**: o log fica em
  `%ProgramData%\Microsoft\Windows Defender\Support` e a leitura exige elevação.
  Sem isso, a skill não falha — apenas informa que a fonte está indisponível.

## Como rodar

```powershell
pwsh -NoProfile -Command {
  . .\scripts\lib\pressure-core.ps1
  $log = Get-PressureMpLogPath
  $registros = ConvertFrom-PressureMpLog -LogPath $log -Since (Get-Date).AddHours(-2)
  $pref = Get-CimInstance -Namespace root/Microsoft/Windows/Defender `
    -ClassName MSFT_MpPreference | Select-Object -First 1 ExclusionPath, ExclusionProcess
  Get-PressureScanCost -Record $registros `
    -ExclusionPath @($pref.ExclusionPath) `
    -ExclusionProcess @($pref.ExclusionProcess) |
    ConvertTo-Json -Depth 5
}
```

Ajuste `-Since` para a janela de interesse. Janela larga demais só acrescenta
ruído: o log é reescrito continuamente e a cauda já cobre o episódio recente.

## Como ler o resultado

`Processes` — quem gerou o trabalho, em segundos de varredura e arquivos
tocados. `ExcludedProcess` diz se aquele binário já está em `ExclusionProcess`.
Custo alto em processo já excluído significa que a causa é outra.

`Paths` — onde estão os arquivos, com `Covered` indicando se o diretório já está
protegido por `ExclusionPath`, e `Suggestion` trazendo o **padrão genérico**
correspondente.

## Regras ao recomendar

1. **Sempre por padrão, nunca por caminho literal.** Recomende
   `C:\Users\*\.claude*`, não o diretório de um usuário específico. Exclusão
   literal morre no próximo perfil, na próxima estação e no próximo colaborador;
   política se define por classe de conteúdo.
2. **Declare a categoria e o motivo.** Estado de ferramenta, cache restaurável e
   artefato de build têm perfis de risco diferentes, e quem avalia precisa disso
   para decidir.
3. **Nunca recomende exclusão de caminho do sistema operacional.** Custo alto em
   `C:\Windows` indica atividade de build ou de runtime, não conteúdo a isentar.
4. **Declare a troca.** Excluir caminho que executa código de terceiros reduz a
   cobertura real do antivírus. É troca de risco, não ganho sem custo.
5. **A decisão não é sua nem do usuário.** Em máquina gerenciada, exclusão,
   agenda e política são da área de segurança. A skill produz evidência para um
   chamado; ela não altera configuração de antimalware.
6. **Contorno não é recomendação.** Ela não deve sugerir contornos: desativar
   proteção em tempo real, adiar ou cancelar varredura e encerrar o processo do
   antimalware estão fora de escopo, por mais tentador que o alívio imediato
   pareça.

## Limites da medição

Os números são amostrados pelo próprio antimalware em intervalos que ele decide.
Valem como **ordem de grandeza e ranking**, não como auditoria de arquivos. O
provedor não expõe a lista de arquivos da varredura agendada; o que existe é o
custo por processo, com o arquivo mais caro de cada um.

## No painel

`scripts\start-pressure-dashboard.ps1` já mostra esse ranking na área
Diagnóstico, recalculando apenas quando há varredura em andamento ou o motor
passa do limiar de CPU, e reaproveitando a última leitura entre recálculos. Para
acompanhamento contínuo, prefira o painel; use esta skill para investigação
pontual e para montar o material de um chamado.

## Saída sensível

O resultado nomeia diretórios reais da máquina. Relatório formal vai para
`reports\`, que o Git ignora. Não versione, não publique fora da organização e
não cole caminho completo em canal público — o padrão genérico basta para a
conversa com a área de segurança.
