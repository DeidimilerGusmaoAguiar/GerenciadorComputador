---
name: pressao-docker
description: Mede o que o Docker e a VM do WSL2 estão custando à máquina — estado do motor (inclusive AFOGADO), consumo por container, containers sem teto, vazamento de Testcontainers, tetos do .wslconfig e espaço morto no VHDX. Use quando o Docker parecer pesado, quando vmmemWSL subir no Gerenciador de Tarefas, quando docker ps não responder, ou antes e depois de rodar suítes de teste com containers. Somente leitura.
---

# Pressão do Docker e da VM do WSL2

Responde **quanto o Docker está custando** e **em que estado o motor está**, com
a semântica que importa: motor que não responde é **AFOGADO** — nunca "zero
containers". Em 03/08/2026 o silêncio do `docker ps` era o próprio sintoma do
travamento da máquina.

## Quando usar

- a máquina está lenta e `vmmemWSL` aparece alto no Gerenciador de Tarefas;
- `docker ps` pendura ou o Docker Desktop parece travado;
- antes de rodar uma suíte de integração com containers, e depois dela, para
  conferir que nada ficou vazado;
- para saber se os tetos combinados (`.wslconfig` e `cpus`/`mem_limit` dos
  compose) estão de fato em vigor.

## Como rodar

```powershell
pwsh -NoProfile -File .\scripts\report-docker-pressure.ps1
```

Com `-AsJson` a saída vira o mesmo objeto que o painel consome. O script faz
duas sondagens espaçadas por `-SampleSeconds` (padrão 6) para medir os núcleos
da VM por delta de CPU — uma leitura única não tem delta, e essa ausência é
informada como "sem delta", não como zero.

## Como ler o resultado

- **Estado do motor** — `DESLIGADO` (sem processos, nenhuma CLI é chamada),
  `OCIOSO`, `ATIVO` (containers rodando, consumo listado por container),
  `LENTO` (o `ps` responde mas o `stats` estoura o orçamento — daemon sob
  carga: os containers aparecem com consumo "sem leitura", que é ausência, não
  zero; remédio é paciência e menos carga) ou `AFOGADO` (nem o `ps` respondeu
  no prazo). Afogado pede socorro, não paciência: o caminho é `wsl --shutdown`,
  que exige aprovação nominal do dono da máquina.
- **Containers `[SEM TETO de memoria]`** — o limite impresso pelo docker é a
  memória inteira da VM: é candidato a ganhar `cpus`/`mem_limit` no compose do
  projeto. Teto novo só vale após `docker compose up -d` (recriar).
- **Testcontainers com semântica de reaper** — `SUITE EM ANDAMENTO` (ryuk vivo:
  a sessão de teste tem dono e limpa ao final) versus `VAZAMENTO CONFIRMADO`
  (ryuk ausente com efêmeros rodando: a sessão morreu, como os 15 SQL Servers
  que ficaram 2h+ vivos em 03/08/2026). Efêmero velho com ryuk vivo é suíte
  longa ou runner pendurado — o limiar de idade sai de
  `scripts\report-testcontainers-leak.ps1`.
- **`.wslconfig`** — mostra memória, CPUs e swap declarados e se o
  `autoMemoryReclaim` está numa seção que o WSL desta versão aceita. Chave na
  seção errada é ignorada com aviso: teto declarado não é teto vigente.
- **VHDX** — tamanho do arquivo no host. Ele nunca encolhe sozinho: recuperar
  espaço morto exige parar o Docker e compactar, uma operação aprovada à parte.

## Regras

1. A skill **não executa correção nenhuma**: não para containers, não remove
   volumes, não derruba a VM, não compacta VHDX. Ela produz o diagnóstico; cada
   correção tem seu fluxo com aprovação explícita (`AGENTS.md`).
2. Motor afogado **bloqueia** recomendações de "rodar mais coisas para ver" —
   empilhar carga sobre um motor afogado foi exatamente o mecanismo do
   travamento de 03/08/2026.
3. Nomes de containers revelam projetos reais da máquina. Relatório formal vai
   para `reports\`, ignorado pelo Git; não versione nem publique.

## No painel

`scripts\start-pressure-dashboard.ps1` mostra o mesmo coletor na área
**Diagnóstico**, painel "O que o Docker está custando", com cadência própria
(padrão 30 s, dobrada quando o motor está afogado) e prazo curto por sondagem
para não custar ao painel. Para acompanhamento contínuo, prefira o painel; use
esta skill para investigação pontual no terminal.
