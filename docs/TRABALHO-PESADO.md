# Trabalho pesado: uma vaga por vez, com teto

`scripts\Invoke-TrabalhoPesado.ps1` é um runner **opt-in** para build, restore e
suítes de teste. Ele existe porque várias sessões de agentes rodam trabalho
pesado ao mesmo tempo e levam o commit da máquina acima de 80%.

Ele não altera o host: não precisa de `-Execute`, não encerra processo fora do
próprio job e nunca usa `Stop-Process` ou `taskkill`.

## Uso

```powershell
pwsh -NoProfile -File .\scripts\Invoke-TrabalhoPesado.ps1 -- dotnet build
pwsh -NoProfile -File .\scripts\Invoke-TrabalhoPesado.ps1 -CpuPorcento 50 -MemoriaGB 6 -- npm test
pwsh -NoProfile -File .\scripts\Invoke-TrabalhoPesado.ps1 -WhatIf -- dotnet test
```

Use sempre `--` antes do comando. Tudo que vem depois é o comando e seus
argumentos, inclusive os que parecem parâmetros do runner.

| Parâmetro | Padrão | Faixa | Efeito |
|---|---|---|---|
| `-CpuPorcento` | 50 | 1 a 100 | Teto rígido de CPU, em % do **total da máquina** (não de um núcleo). |
| `-MemoriaGB` | 40% da RAM física | 0,1 a 4096 | Teto de memória comprometida do job inteiro. Aceita fração. |
| `-Vagas` | 1 | 1 a 16 | Quantos trabalhos pesados podem rodar juntos na máquina. |
| `-EsperaMaxMinutos` | 60 | 0 a 1440 | Quanto esperar por uma vaga. `0` não espera. |
| `-WhatIf` | desligado | | Mostra limites, vaga e comando e não roda nada. |

## O que faz

1. **Fila.** A vaga é um mutex nomeado (`Local\GerenciadorComputador-TrabalhoPesado-<i>`).
   O processo pega o primeiro livre. Enquanto espera, imprime uma linha a cada
   ~30 s com o tempo esperado. Se o dono de uma vaga morrer, o Windows a marca
   como abandonada e o runner a assume com um aviso; um semáforo não faria isso.
   Como o nome é `Local\`, a fila vale por sessão de logon.
2. **Teto.** O comando roda num Job Object do Windows com teto de memória do job
   (`JOB_OBJECT_LIMIT_JOB_MEMORY`), teto de CPU rígido
   (`CPU_RATE_CONTROL_ENABLE | HARD_CAP`) e `KILL_ON_JOB_CLOSE`.
3. **Sem corrida.** O processo é criado suspenso, entra no job e só então é
   retomado. Nenhuma instrução do filho roda fora do teto.
4. **Saída ao vivo.** O filho herda stdin, stdout e stderr do runner.
5. **Resumo.** Ao fim: duração, pico de memória do job e se o teto de memória foi
   atingido. O código de saída do filho é o do runner.

Comandos `.cmd` e `.bat` (como `npm`) rodam via `cmd.exe /d /s /c`; `.ps1` via
`pwsh -NoProfile -File`. Alias e função de perfil não são encontrados: passe um
programa.

## Códigos de saída

| Código | Significado |
|---|---|
| o do filho | O comando terminou; o runner devolve o mesmo código. |
| 124 | A espera pela vaga passou de `-EsperaMaxMinutos`. |
| 125 | Erro do runner: argumento inválido, comando não encontrado, falha ao criar o job. |

Um filho que devolva 124 ou 125 é indistinguível desses.

## Limites conhecidos

- **Não há teto de I/O.** `SetIoRateControlInformationJobObject` não é suportado
  desde o Windows 10 1607. O runner limita CPU e memória, não disco nem rede.
- **O teto é de memória comprometida (commit)**, não de working set. Alocar além
  dele falha no filho; o que o filho faz com a falha é problema dele.
- **.NET.** O runtime lê o teto do job e recusa alocar sozinho perto de 75% dele.
  Nesse caso o Windows não notifica o estouro, e o resumo só avisa que o pico
  passou de 70% do teto. Alocação nativa que bate no teto aparece como `ATINGIDO`.
- **Teto de CPU rígido** deixa o trabalho mais lento mesmo com a máquina ociosa.
- **A fila é cooperativa.** Só vale para quem usa o runner; trabalho iniciado por
  fora dele não entra na fila nem sob teto.
- **Processos em segundo plano** que o filho deixar (por exemplo servidores de
  build) morrem junto ao fim do job.
- Windows 8 ou superior (limite de CPU por job) e PowerShell 7+.

## Como parar

- `Ctrl+C` no console do runner, ou fechar a janela: o job é fechado e
  `KILL_ON_JOB_CLOSE` encerra toda a árvore dele. A vaga volta para a fila.
- Se o runner morrer por qualquer motivo, o mesmo acontece e a vaga fica
  abandonada, sendo assumida pelo próximo da fila com um aviso.
- Não use `Stop-Process`, `taskkill` ou equivalentes sobre processos de fora do
  job; o contrato do repositório (`AGENTS.md`) exige autorização nominal.

## Teste

```powershell
pwsh -NoProfile -File .\tests\Test-TrabalhoPesado.ps1
```

O teste usa um prefixo de vaga próprio, dura alguns segundos e não disputa vaga
com trabalho real. Cobre propagação do código de saída, serialização com uma vaga,
desistência por espera máxima, teto de memória e `-WhatIf`.
