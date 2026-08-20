# Migração de máquina de desenvolvimento — lições de campo

Este guia nasceu de uma migração real de estação Windows, executada em dois dias
com as duas máquinas ligadas ao mesmo tempo. Cada item aqui custou uma descoberta
tardia, um susto ou um retrabalho. Os exemplos usam dados sintéticos.

O princípio que organiza tudo: **não se faz backup do que já está num remoto.
Faz-se backup do que só existe naquela máquina.** A dificuldade é que a segunda
categoria é sempre maior do que parece.

---

## 1. Inventário: varra, não liste

Uma lista escrita descreve o passado. A máquina descreve o presente.

Num único dia, um inventário com uma semana de idade perdeu três itens, todos
achados por varredura automática:

- um repositório inteiro, criado depois do levantamento, com **177 commits**
  nunca enviados;
- o perfil **ativo** de uma CLI, que o inventário registrava como "vazio, nada a
  salvar" — quatro dias depois tinha configuração, skills e três bancos SQLite;
- um diretório de perfil referenciado **pelo próprio arquivo de perfil do shell
  do usuário**, que nenhum inventário adivinharia.

**Como fazer:** para repositórios, varra as raízes procurando `.git`. Para perfis
de ferramenta, varra os diretórios ocultos de `$HOME` e das raízes de projeto.
Depois **compare com a lista e relate a diferença** — a diferença é o achado.

E leia o perfil do PowerShell do usuário: ele referencia caminhos que só existem
na cabeça de quem o escreveu.

---

## 2. O que o `git clone` não traz

O furo mais caro. Esses arquivos moram **dentro** de repositórios versionados,
o `.gitignore` os exclui de propósito, e o clone na máquina nova não os traz.
Sem eles o ambiente não sobe — e o erro aparece longe da causa.

Uma varredura por allowlist de nome, em 22 repositórios, achou **224 arquivos**:

| Tipo | Por que importa |
|---|---|
| `SysDataBase.config`, `*.config` de conexão | **68 arquivos**, um por projeto, todos com string de conexão |
| `.env`, `.env.*` | credenciais de API e banco |
| `*.local.json`, `*.local.md` | **acesso de produção** documentado fora do Git |
| `settings.local.json` | configuração local de CLIs e editores |
| `*.keystore`, `*.pfx`, `*.p12`, `*.pem` | **assinatura de app** e certificado de VPN |
| `*.db`, `*.sqlite` | bancos locais e backups de estado |
| tokens soltos em `reports/`, `deploy/` | gerados por ferramenta, nunca commitados |

**Como fazer:** `git ls-files --others --ignored --exclude-standard` em cada
repositório, filtrado por **allowlist de nome** — nunca por exclusão. Filtrar por
exclusão deixa passar o que você não previu.

Descarte por construção: `node_modules`, `bin`, `obj`, `dist`, `build`, `.venv`,
cache, log, imagem, vídeo. E **perfis de navegador automatizado** (Playwright,
Puppeteer): eles têm `config.json` e `.db` de sobra, e nada ali é seu.

> Cuidado com o falso positivo: uma biblioteca de força de senha carrega um
> `passwords.txt` que é dicionário público, não credencial.

---

## 3. Prefixo `.tmp-` não quer dizer descartável

Um diretório chamado `.tmp-<identificador-da-tarefa>` continha **162 arquivos** —
scripts SQL de baseline, comparações e planos de execução — modificados dois dias
antes da migração, referentes à tarefa **em andamento**.

O nome era temporário; o conteúdo era o método reexecutável do trabalho.

Mesma lição vale para diretórios com nomes como `_tmp-*`, `scratch`, `rascunho`.
**Olhe a data de modificação antes de decidir pelo nome.**

---

## 4. Perfis de ferramenta: allowlist, não denylist

Perfis de CLI acumulam gigabytes de cache, transcript e plugin reinstalável, e
escondem poucos megabytes do que realmente importa.

Uma tentativa de "copiar tudo menos o lixo" produziu **4,2 GB**. A mesma seleção,
feita por allowlist do que interessa, produziu **277 MB** — sem perder nada.

**Leve:** configuração, `skills/`, `agents/`, memórias e o histórico por projeto.
**Descarte:** `cache`, `sessions`, `shell-snapshots`, `file-history`,
`paste-cache`, `plugins/` (menos o manifesto), `extensions/`.

Nos três perfis maiores, os transcripts `.jsonl` sozinhos eram **1,76 GB** contra
**271 MB** de memórias e configuração.

> **Credencial não viaja.** Token de sessão se refaz com login na chegada. O que
> precisa viajar é o **mapa de qual conta usa qual perfil** — e essa informação
> costuma não estar em lugar nenhum.

### Materialize esse mapa em perfis do terminal

Se o usuário mantém várias sessões da mesma CLI em contas diferentes, o mapa não
deve viver só num documento: vire **um perfil de terminal por identidade**, cada
um com diretório inicial e cor de aba próprios. O atalho passa a escolher a conta,
e some a chance de abrir a conta errada no repositório errado — que é o mesmo erro
que carimba e-mail corporativo em repositório pessoal.

Duas cautelas ao criar esses perfis:

- **Não restaure o arquivo de perfis da máquina antiga por cima.** Ele carrega
  perfis de software que a máquina nova não tem; eles aparecem no menu e não abrem
  nada. Confirme que cada diretório inicial existe **antes** de escrever.
- **O perfil herda o que o atalho já fazia.** Se a função invocada acrescenta uma
  flag que desliga confirmação de permissão, agora são N atalhos nascendo assim.
  Ganhar conveniência é fácil; o que se multiplica junto costuma passar batido.

---

## 5. Descubra a rota antes de precisar dela

Transferir entre duas máquinas parece trivial e não é. O que apareceu:

- **Resolução de nome mentindo:** o DNS corporativo passou a resolver o nome da
  máquina nova para o IP da **antiga**. Sempre confirme a identidade do destino
  (procure uma pasta que só existe de um dos lados) antes de escrever.
- **Kerberos falha onde NTLM funciona:** acessar por nome deu erro **1396**
  ("nome da conta de destino incorreto") porque a máquina estava fora do caminho
  do controlador de domínio. **Por IP funcionou.**
- **Elevação isola sessão SMB:** uma sessão autenticada num terminal comum é
  invisível para um processo elevado, e vice-versa — tokens de UAC separados. Se
  a ferramenta que vai copiar roda elevada, autentique elevado, ou grave a
  credencial no cofre do usuário.
- **`robocopy` retorna 1 em caso de sucesso.** Só `>= 8` é erro. Automação que
  trata "exit != 0" como falha vai reportar erro em toda cópia bem-sucedida.
- **Sem `/XO`, o robocopy sobrescreve o mais novo.** Numa sincronização
  repetida, isso apaga o que a outra máquina escreveu.
- **Caminho longo quebra em silêncio.** Perfis de ferramenta geram caminhos
  perto do limite do Windows; o Explorer falha sem avisar e a enumeração fica
  instável. Mantenha o pacote numa raiz curta e use `robocopy`.

---

## 6. Divisão de arquivos entre as duas máquinas

Se as duas máquinas escrevem no mesmo pacote, defina **quem é dono de quê**:

- documento de **plano** pertence à máquina de origem;
- documento de **execução** pertence à de destino, e **não deve existir na
  origem** — assim nenhuma sincronização o sobrescreve.

Sem essa separação, a origem apaga o registro de execução do destino a cada
passada, e ninguém percebe até faltar a informação.

---

## 7. A máquina se move enquanto você a inventaria

Duas conclusões da varredura remota nasceram erradas por serem uma foto:

- um componente reportado como ausente **já estava instalado** — a leitura
  aconteceu antes de um instalador terminar;
- um caminho fixo (`C:\Program Files\...`) deu falso negativo porque a
  ferramenta fora instalada por usuário ou pela loja.

**Pergunte ao sistema, não ao caminho:** use `Get-Command` em vez de `Test-Path`
em diretório fixo. E, ao concluir que falta algo na máquina remota, **confirme
antes de agir**.

O mesmo vale para saber se um processo subiu. Uma CLI instalada por gerenciador
de pacotes de runtime pode rodar como **executável próprio**, não como o runtime:
procurar o nome do interpretador na lista de processos dá **falso negativo**, e a
conclusão "não iniciou" nasce errada. Procure o **filho do shell** que a lançou.

---

## 8. Hooks de governança existem para barrar exatamente isto

Dois repositórios recusaram commit por um hook que exige cobertura de evidência
antes da alteração. A trava era do próprio dono, documentada como decisão.

**Não contorne com `--no-verify` por conta própria.** O caminho é:

1. preservar o trabalho de forma que ele não se perca (**patch** resolve, e cabe
   em poucos MB mesmo para centenas de arquivos);
2. levar a decisão a quem criou a trava.

Quando a autorização vier, **registre no corpo do commit** por que o gate não
cobriu. Um `--no-verify` silencioso é uma dívida invisível; um documentado é uma
pendência rastreável.

> Detalhe que só aparece na hora: dois repositórios podem ter **versões
> diferentes** do mesmo hook, com capacidades diferentes. Um aceitava declarar
> cobertura de trabalho já escrito; o outro, mais antigo, não.

---

## 9. Verifique a premissa antes de instalar

Duas instalações foram evitadas por checar o que o código realmente pede:

- um componente legado de framework que o repositório corporativo **não usava em
  nenhum dos 794 projetos** — estava habilitado na máquina antiga por herança da
  imagem, não por necessidade. Evitou um chamado à TI e horas de tentativa
  contra um servidor de atualização que recusava o pacote;
- o motor de banco de dados **não estava instalado** na máquina de origem: o que
  existia era a edição local, um container e um servidor remoto. Instalar o
  motor teria repetido um erro que a máquina antiga nunca cometeu.

**Como fazer:** antes de instalar por "estava lá", procure quem depende. Uma
varredura de `TargetFramework` em todos os projetos leva um minuto.

---

## 10. Ambiente web: descubra onde ele realmente roda

O plano dizia para levar a configuração do servidor de desenvolvimento leve. A
verificação mostrou que esse arquivo era **de fábrica nos dois lados** — e que o
ambiente real vivia no **servidor web completo**, com **38 aplicações e 22 pools**
apontando para as pastas do repositório.

Isso não estava em backup nenhum. Exportar a configuração do servidor e o mapa de
diretórios virtuais (com caminho físico) é obrigatório.

> Não substitua a configuração do servidor na máquina nova pela da antiga: ela
> carrega estado de máquina. Use o mapa e recrie aplicação por aplicação.

---

## 11. Conte destinos, não arquivos

Uma leitura apressada sugeria "duas gerações de configuração convivendo": 142
arquivos apontando para um servidor e 65 para outro.

Eram **os mesmos 65 arquivos**, cada um com várias conexões — banco principal,
fila de jobs, cache e um servidor de conversão. Nenhum obsoleto: papéis
diferentes.

**Como fazer:** agrupe por arquivo, não por ocorrência, e leia uma amostra antes
de concluir que existe ambiente morto.

---

## 12. A rede interna pode ser um túnel

A interface que parecia rede corporativa cabeada era um **adaptador TAP de VPN**.
Só a tabela de rotas revelou: todas as faixas internas passavam pelo túnel.

Consequências: sem VPN, metade dos destinos de banco não existe; e o tráfego de
internet **não** passa pelo túnel, então serviços em nuvem com liberação por IP
enxergam o endereço da rede local, não o corporativo — o que muda quando a
máquina troca de lugar.

**Teste a VPN cedo.** É pré-requisito de metade dos testes seguintes.

---

## 13. Volumes de container somem sem aviso

O levantamento inicial registrava **8,32 GB** em volumes. Duas semanas depois
eram **139,5 MB**: o volume maior e dois outros haviam sido removidos numa
limpeza anterior.

**Como fazer:** confirme `docker volume ls` **no dia**, não no plano. E prefira
**dump lógico** a cópia de volume — sobrevive à diferença de versão do motor
entre as máquinas.

> Detalhe que trava a restauração: o usuário do banco no container pode não ser o
> padrão. Anote-o junto com o dump.

---

## 14. Cifragem: decida cedo, e assuma a consequência

Se o pacote viaja **sem cifragem**, apagar o material da máquina antiga deixa de
ser higiene e vira **obrigação** — ali existem chaves privadas, tokens e códigos
de recuperação em texto puro, numa máquina que muda de mãos.

E lembre: **token de servidor não morre com a máquina**. Enquanto não for
revogado no portal, continua valendo. Rotacione **depois** que a validação
fechar — trocar credencial no meio de um teste mistura duas causas de erro.

---

## 15. O clone na máquina nova nasce velho

Com as duas máquinas trabalhando no mesmo dia, um repositório clonado de manhã já
não representa o remoto à tarde. Um guia publicado pela máquina de origem **depois**
do clone simplesmente não existe no destino — e a leitura natural é "não foi
enviado", quando o que faltou foi atualizar.

Vale para qualquer repositório de apoio que as duas máquinas editam durante a
migração: **antes de concluir que algo não subiu, olhe `HEAD..origin/main`.**

> **Armadilha do diagnóstico:** `git fetch --dry-run` mostra o que viria e **não
> move as referências locais**. O `merge --ff-only` seguinte responde *"Already up
> to date"* mesmo havendo commit novo, porque o `origin/<branch>` local continua
> onde estava. Quem usa o `--dry-run` para investigar e o merge para corrigir
> conclui que não há nada — e há. Faça o `fetch` de verdade.

---

## 16. O mapa da máquina tem prazo de validade

Uma migração que vale a pena documentar produz um arquivo que diz **onde se está**:
papel de cada máquina, o que já foi feito nela, o que é proibido ali. Ele é lido no
começo de toda sessão — por pessoas e por agentes — e por isso é o documento cujo
envelhecimento custa mais caro.

O mapa escrito no dia da chegada descrevia o destino como *"nada de desenvolvimento
está instalado"*, e trazia a regra derivada *"nunca restaure configuração de um
programa que ainda não foi instalado"*. **Um dia depois o ambiente inteiro estava
instalado e validado.** A regra, antes prudente, passou a barrar trabalho legítimo:
quem a lê recusa restaurar configuração de software que está bem ali.

Um mapa errado é pior que mapa nenhum: ausência de informação faz perguntar, e
informação desatualizada faz agir com confiança na direção errada.

**Como fazer:** escreva o estado como afirmação verificável, não como narrativa
("recebida ontem", "em transformação"). E defina o gatilho de reescrita pelo
**evento, não pelo calendário** — a primeira fase concluída já invalida o mapa de
chegada. Se o arquivo tem campo de data, trate divergência entre a data e o estado
real como defeito.

---

## 17. O runbook envelhece mais rápido que a máquina

Um runbook escrito para a migração anterior foi reaproveitado dez dias depois.
**Seis afirmações dele já eram falsas**: mandava instalar uma versão de IDE que
não estava mais em uso, esperava uma distro de WSL que não existia, mandava
restaurar um volume de container já removido, falava em quatro imagens locais
quando restara uma, e errava a contagem de credenciais e de extensões do editor.

Nenhuma quebrou nada sozinha. Cada uma custou tempo — e uma delas só apareceu
porque o dono desconfiou de uma frase.

**O erro de método:** tratar o documento como fonte e a máquina como
confirmação. É o contrário. O documento é hipótese datada; a máquina é a fonte.

**O conserto:** um verificador que pergunta à máquina e imprime lado a lado o
que o documento afirma e o que a máquina responde, antes de qualquer execução.
Divergência vira item de correção do documento, não contorno silencioso.

### O caso mais instrutivo: existir não é estar em uso

O runbook mandava levar um arquivo de configuração de servidor web local,
prometendo que ele "traz os sites de dev". O arquivo existia. Só que era o
template de fábrica, intocado por **dois anos e meio**, declarando um único site
de exemplo. O servidor em questão estava instalado apenas como dependência de
outra ferramenta, e o trabalho real acontecia no servidor completo, com dezenas
de pools.

Ao inventariar, não pergunte "existe?". Pergunte **"foi modificado?"** e
**"tem conteúdo próprio?"**. Data de modificação e contagem de itens não-padrão
separam estado real de ruído.

## 18. Automação remota sem sessão interativa tem limites duros

Administrar uma máquina remota por WMI/DCOM funciona bem para instalar, copiar e
medir. Mas o processo nasce de um **logon de rede**, que não tem sessão de logon
— e três classes de coisa quebram ali, sempre em silêncio:

| Sintoma | Causa real | Contorno |
|---|---|---|
| Comando sai sem saída **e sem código de erro** | o alias do pacote MSIX é um arquivo de 0 byte, e a ativação não acontece fora de sessão interativa | chame o executável real dentro do diretório do pacote, por caminho completo |
| `Win32_Process.Create` devolve `9`, *Path Not Found* | o PATH herdado na sessão 0 não é o da sessão do dono | chame tudo por caminho absoluto, nunca pelo nome do comando |
| `A specified logon session does not exist` | DPAPI / Gerenciador de Credenciais | evite o helper; use credencial explícita, ou adie para a sessão do dono |
| Instalador ignora argumentos | array passado a `Start-Process` não cita caminho com espaço | passe **uma** string, com o caminho entre aspas |

Duas armadilhas de linguagem que custaram execuções inteiras:

- **Função com nome de executável se chama a si mesma.** Uma função `Winget`
  que executa `& winget` recursa até estourar: o PowerShell resolve função antes
  de comando externo. Use o nome completo (`winget.exe`).
Sobre o MSIX, medido em 20/08/2026 e **corrigido no mesmo dia**: o
interpretador instalado pela loja aparece no PATH apenas como um alias de 0
byte, um ponto de reanálise que não ativa fora de sessão interativa. O
executável real, dentro do diretório do pacote, chegou a rodar por caminho
completo — e **parou de rodar uma hora depois**, sem que nada fosse instalado
ou desinstalado: passou a devolver *"O sistema não pode executar o programa
especificado"*, e a criação direta por WMI passou a negar acesso. O que mudou
no meio foi o estado da sessão interativa da máquina.

A lição não é "chame o executável real": é que **aplicativo em pacote não é
base confiável para automação sem sessão**. Se um runtime precisa ser chamado
por processo remoto, instale o pacote clássico. Vale conferir na chegada:
runtime que só existe como alias da loja é dívida esperando a primeira
automação.

O mesmo vale para o que depende dele. Um hook que procura o interpretador no
PATH encontra o alias e falha em silêncio — descarte candidato de 0 byte
explicitamente e prefira o caminho da instalação real.

- **`$args` é variável automática.** Usá-la como array próprio para *splatting*
  faz o comando rodar sem parâmetro nenhum, e o erro aparece longe da causa.

E uma de leitura: **não decida sucesso pelo texto da saída.** Mensagem
localizada chega com codificação trocada e a comparação nunca casa — sucessos
viram "falha" no log. Decida por **código de saída** e confirme **em disco**.

## 19. Pasta criada não é dado copiado

O pacote de migração tinha uma pasta `05-navegador` com duas subpastas de nome
correto. Dentro delas, **dois arquivos, somando 100 KB** — enquanto o perfil de
origem tinha 579 MB no Chrome e 411 MB no Edge. O histórico, que é o que alguém
realmente sente falta, nunca foi capturado.

Ninguém errou o passo: o passo rodou, criou a estrutura, e não falhou. O que
faltou foi **a medida que teria falhado se ele não tivesse funcionado**.

É o mesmo defeito de "existir não é estar em uso", visto do outro lado: ali um
arquivo existia e não valia nada; aqui uma pasta existe e não contém nada. Nos
dois casos, presença foi confundida com conteúdo.

A auditoria do pacote inteiro — contar arquivos e bytes por pasta e comparar com
a origem — levou menos de um minuto e apontou o único passo vazio entre cinco.
Faça isso **antes** de formatar a origem, não depois.

| Passo | Arquivos | Tamanho | Veredito |
|---|---|---|---|
| dados | 492 | 304 MB | consistente |
| sensível | 154 | 251 MB | consistente |
| perfis de CLI | 3.560 | 202 MB | consistente |
| configuração | 17 | 0,2 MB | consistente: são arquivos pequenos por natureza |
| **navegador** | **2** | **0,1 MB** | **vazio — origem tinha ~1 GB** |

Tamanho pequeno não é sintoma por si só: a pasta de configuração tem 17 arquivos
e 200 KB, e está completa. O sintoma é **a razão entre origem e pacote**.

### O que de navegador não atravessa, faça o que fizer

Histórico, favoritos, autofill, atalhos e ícones são arquivos comuns: copiam bem.
**Senhas salvas e sessões logadas não.** A chave que as decifra fica no
`Local State`, protegida pela API de proteção de dados do Windows, amarrada ao
par usuário + máquina. Copiada para outro computador, a chave não decifra.

Não insista no arquivo: contas voltam entrando na conta do navegador e deixando
a sincronização trazer de volta. Prometer "leva tudo do navegador" é promessa
que o sistema operacional não deixa cumprir.

## 20. A cópia fiel leva o defeito junto

O perfil do shell foi para a máquina nova byte a byte: mesmo tamanho, mesmo
hash, mesma data de modificação. Fidelidade perfeita — e foi ali que um defeito
antigo apareceu pela primeira vez.

O perfil define um atalho que injeta uma opção obrigatória na chamada de uma
ferramenta. Quem digitasse a opção junto, ainda mais errado, recebia
`unknown option` e a sessão morria antes de começar. O defeito existia na origem
havia meses. Ninguém tinha notado, porque na origem ninguém digitava a opção — o
hábito já estava formado. Na máquina nova, o hábito ainda não existia.

**Máquina nova é o melhor detector de defeito antigo que você vai ter.** O que
aparecer nos primeiros dias lá quase nunca é regressão da migração: é dívida que
estava escondida atrás do costume. Trate como achado, não como estrago.

E corrija nos dois lados mais o pacote. Um atalho que injeta uma opção deve
tolerar que a opção venha digitada — inclusive digitada errado — em vez de
repassar e deixar o programa recusar. Injeção que não é idempotente é armadilha
esperando a primeira digitação.

## 21. Compare o destino com a origem, não com o ideal

Ao testar a máquina nova, oito de setenta e quatro verificações falharam. A
reação natural é caçar oito defeitos de migração. Antes disso, rodei os **mesmos
testes na máquina de origem**, que ainda estava de pé.

Sete das oito falhavam exatamente igual lá.

Eram condições preexistentes — credencial vencida em pool de aplicação, uma API
que já respondia com erro havia semanas — que ninguém notava porque ninguém
exercitava aqueles caminhos. A migração não as causou; ela apenas as tornou
visíveis, porque pela primeira vez alguém testou tudo de uma vez.

**Enquanto a origem existe, ela é o gabarito.** Depois que ela for formatada,
você perde a única forma barata de distinguir "quebrou na mudança" de "já estava
assim". Guarde a saída dos testes da origem **antes** de desligá-la: vale mais
que qualquer documento.

E cuidado com o inverso: sete falhas iguais não significam sete problemas
resolvidos. Significam sete problemas que continuam existindo, agora com dono
conhecido.

## 22. O endereço de saída faz parte do ambiente

Uma API subia na origem e falhava no destino com erro de banco. Mesma versão,
mesma configuração, mesmos arquivos — conferidos byte a byte. A diferença estava
fora da máquina: o firewall do banco libera por **endereço de origem**, e as duas
máquinas saíam por endereços diferentes.

A causa era a VPN, que na máquina nova tinha a interface aberta e o túnel
derrubado. O processo da interface gráfica estava lá; o processo do túnel, não.
Presença de programa não é presença de conexão.

Ao migrar, trate o caminho de saída como item de inventário: endereço público,
túnel ativo, rota. Um `500` de banco de dados pode não ter nada a ver com o
banco, com a aplicação, nem com a migração — e você vai passar horas dentro do
código antes de olhar para fora dele.

## 23. Sequência que funcionou

1. **Monitorar sem congelar.** O dono continua trabalhando; o inventário roda
   quantas vezes for preciso e mostra o delta entre execuções.
2. **Dados fora do Git primeiro.** É a parte lenta e a única irreversível.
3. **Instalar a máquina nova em paralelo.** Não depende do corte.
4. **Corte do Git no fim**, quando o dono decide parar de alterar.
5. **Validar de verdade** — compilar, subir site, abrir banco, conectar VPN —
   **enquanto a máquina antiga ainda existe**. Descoberta tardia com a origem
   viva é ajuste; sem ela, é perda.
6. **Higiene por último:** apagar o pacote da origem, os arquivos com token em
   claro, conferir a sincronização da nuvem.

---

## Checklist mínimo

- [ ] Varrer repositórios por `.git`, não usar lista pronta
- [ ] Varrer arquivos ignorados por allowlist de nome, em todos os repositórios
- [ ] Perfis de ferramenta por allowlist; mapear qual conta usa qual perfil
- [ ] Ler o perfil do shell do usuário atrás de caminhos não inventariados
- [ ] Exportar configuração do servidor web, com mapa de caminhos físicos
- [ ] Confirmar volumes de container no dia; dump lógico e usuário anotado
- [ ] Testar a VPN cedo — ela é pré-requisito
- [ ] Verificar quem depende antes de instalar "porque estava lá"
- [ ] Definir dono de cada documento entre as duas máquinas
- [ ] Validar compilando e subindo, não conferindo se instalou
- [ ] Atualizar o repositório de apoio no destino (`HEAD..origin/<branch>`) antes
      de concluir que algo não foi enviado
- [ ] Reescrever o mapa das máquinas quando a primeira fase fechar, não quando a
      migração acabar
- [ ] Apagar o pacote da origem e rotacionar o que for token de servidor
