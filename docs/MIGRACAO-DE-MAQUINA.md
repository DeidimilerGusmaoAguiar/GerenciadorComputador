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

## 15. Sequência que funcionou

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
- [ ] Apagar o pacote da origem e rotacionar o que for token de servidor
