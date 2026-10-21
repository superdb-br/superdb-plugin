# Nota fiscal (SuperDB Fiscal, NFS-e pelo projeto)

Doc pública: https://superdb.com.br/docs/notas-fiscais. Este arquivo é o resumo operacional.

✅ **Está no ar, em self-service: teste grátis em homologação em qualquer plano; emissão de verdade no Pro e no
Escala.** No Grátis e no Site o usuário ativa, cadastra 1 CNPJ e emite até 50 notas de teste por mês em
homologação (sem valor fiscal). O Pro emite até 100 NFS-e por mês em 1 CNPJ, e o Escala, até 1.000 por mês em 5
CNPJs, também em produção. Pedir produção (ou emitir por um emitente em produção) num plano sem produção dá
`403 fiscal_fora_do_plano` com `"ambiente": "producao"` e `upgrade_url`: o usuário muda o plano da CONTA no
painel. No painel, a tela Notas fiscais tem um guia de instalação em 7 passos, com um botão de nota de teste
(dados de exemplo, tomador PJ pública). Não há cobrança por nota nem de
excedente: acima da cota do mês a emissão é recusada até o dia 1º. Todo emitente nasce em **homologação**
(sem valor fiscal) e só passa a **produção** depois de a equipe do SuperDB conferir o pedido que o dono faz no
painel (o dono recebe um e-mail quando é liberada). Emite **NFS-e do padrão nacional** (nota de serviço),
nunca NF-e de produto nem NFC-e, e só para município que emite pelo padrão nacional. Não prometa data nem
desconto que não estejam aqui. Página do produto: https://superdb.com.br/notas-fiscais

## O caminho

1. **Ativar** (no painel, em Notas fiscais, ou pela API de gestão com a chave `sdb_pmk_`): `POST /platform/v1/projects/<id>/fiscal/ativacao`. Cria a
   conta fiscal, o bucket `proj_<slug>_fiscal` (privado, só servidor) e a tabela `sdb_notas_fiscais`.
2. **Emitente**: `POST .../fiscal/emitentes` com `{ cnpj, razao_social, crt, uf, logradouro, numero, bairro,
   municipio, codigo_municipio, cep }` (`somente_homologacao: true` para testar com um CNPJ que já emite em
   outra conta; esse emitente nunca sai em produção). Nasce em **homologação**.
3. **Certificado A1**: `POST .../emitentes/<emitente>/certificado` com `{ pfx, senha }` (.pfx em base64, até 64 KB).
   Vão direto ao motor; o SuperDB não guarda nenhum dos dois. 10 envios por hora por projeto.
4. **Serviço padrão**: `PUT .../emitentes/<emitente>/servico-padrao` com `codigo_tributacao_nacional` (6
   dígitos, desdobro nunca `00`), `codigo_tributacao_municipal` (3), `nbs` (9), `descricao`, `iss`,
   `tributos_aproximados`. Sem `valor`: o valor vem em cada nota.
5. **Prontidão e parâmetros**: `GET .../emitentes/<emitente>/prontidao` (o que falta) e
   `GET .../emitentes/<emitente>/parametros?codigos=010302,040101` (1 a 5 códigos; precisa do A1 já enviado). Use o código COMPLETO
   (9 dígitos, `010302001`, com o cTribMun): com 6 dígitos a consulta usa o complemento `000`, e um município com código próprio
   responde que não administra um serviço que administra.
6. **Produção**: o dono do projeto pede no painel (Notas fiscais, no emitente); a equipe do SuperDB confere e libera. Até lá, tudo sai em homologação, sem valor fiscal. A homologação prova o pedido e o certificado, não o município (o ambiente nacional
   de teste pode recusar códigos que a produção aceita; um E0312 em homologação é esperado e não prova nada sobre a produção): o município só se confirma na primeira nota em produção, então acompanhe essa nota.
7. **Emitir**, do servidor do cliente: `POST https://auth.superdb.com.br/fiscal/v1/nfse`.

Há tela no painel (a tela Notas fiscais do projeto, em `/projects/<slug>/fiscal`): ativar, emitente, certificado A1, serviço padrão, prontidão, prévia, notas com PDF e XML, pedido de produção e desativação. A mesma gestão existe pela API (`fetch`/`curl`); pelo MCP o agente lista, consulta, faz a prévia, vê a prontidão, emite e cancela. O pedido de produção e a desativação são só pelo painel. Para emitir, o `@superdb/client` (a partir da 0.4.0) tem
`sdb.fiscal.nfse.emitir | consultar | cancelar | previa` (`createClient(url, SERVICE_ROLE_KEY,
{ project })`, devolve `{ data, error }`, e sem a service_role o SDK nem faz o pedido). Erro de rede em `emitir`: chame de
novo com a MESMA `ref`, que devolve a mesma nota. Até a publicação, use `fetch`.

## O município

Ao salvar o serviço padrão o SuperDB consulta o cadastro nacional. Se o município **não emite pelo padrão
nacional**, o serviço padrão **não é salvo** (`422 municipio_fora_do_padrao_nacional`), o emitente fica
marcado, e a emissão e o pedido de produção recusam com a mesma explicação. A marca só se desfaz salvando de
novo o serviço padrão. Qualquer outra resposta da conferência (cadastro nacional ocupado, A1 ainda não
enviado, motor fora) não impede de salvar, e a resposta traz um `aviso`: consulte os parâmetros antes de emitir.

## Emitir

```bash
curl -X POST https://auth.superdb.com.br/fiscal/v1/nfse \
  -H "Authorization: Bearer $SUPERDB_SERVICE_ROLE_KEY" -H "Content-Type: application/json" \
  -d '{ "ref": "pedido-1042",
        "tomador": { "cnpj": "11222333000181", "nome": "Cliente Exemplo LTDA", "email": "financeiro@cliente.example" },
        "servico": { "valor": 150.00 } }'
# 202 { "id": "...", "situacao": "pendente", "ref_repetida": false }
```

- ⚠️ **SÓ a `service_role`** (anon e sessão: `403 chave_de_servidor`). Quem extrair a anon do app emitiria nota
  no CNPJ do cliente. Nunca emita do app.
- `ref` (obrigatória, 1 a 100 caracteres, letras, números e `. _ : / -`) é a **chave de idempotência**: repetir
  o mesmo pedido devolve a mesma nota (`200`, `ref_repetida: true`); a mesma `ref` com outro pedido dá
  `409 ref_reusada`. Para refazer uma nota recusada, **outra `ref`**.
- `emitente` (CNPJ, 14 dígitos) é opcional com um só emitente. `competencia` (`AAAA-MM-DD`) padrão: hoje; depois de hoje dá `422 competencia_futura`. Projeto sem ativação dá `403 fiscal_inativo`.
- `tomador`: `cpf` ou `cnpj` (um só), `nome`, `email`, `endereco`. `servico.valor` em reais (mínimo 1 centavo, até
  2 casas, abaixo de R$ 10 milhões); qualquer campo do serviço padrão pode ser trocado na nota.
- Campo que o SuperDB Fiscal ainda não aceita (desconto, retenções, local de prestação) é **recusado com o
  nome**, não ignorado.
- Prévia (sem emitir, sem gravar, sem contar): `POST /fiscal/v1/nfse/previa`. Consulta:
  `GET /fiscal/v1/nfse/<id>`. Cancelamento: `POST /fiscal/v1/nfse/<id>/cancelamento` com
  `{ "motivo": "1"|"2"|"9", "justificativa": "..." }` (só nota emitida; 202).

## Pelo MCP (o agente emite, consulta e cancela)

Com o MCP conectado ao projeto, as ferramentas fiscais vêm ligadas: `fiscal_listar_notas`,
`fiscal_consultar_nota`, `fiscal_previa_nfse`, `fiscal_prontidao`, `fiscal_emitir_nfse` e `fiscal_cancelar_nfse`.
Sem elas na lista, elas foram desligadas (`SUPERDB_FISCAL_TOOLS=0` no MCP local) ou o pacote local `@superdb/mcp`
é de uma versão anterior à que as traz: use o MCP remoto ou atualize o pacote, e não prometa o que a lista não mostra.
O projeto precisa ter o SuperDB Fiscal ativo (homologação em qualquer plano; produção no Pro e no Escala).

- **Teste antes**: `fiscal_previa_nfse` confere o pedido sem emitir e sem contar na cota.
- **Emitir é idempotente pela `ref`**: a mesma `ref` com o mesmo pedido devolve a MESMA nota (`ref_repetida: true`).
  Erro de rede: repita com a mesma `ref`, nunca com outra (poderia sair duas notas).
- **Homologação não tem valor fiscal**: o emitente nasce em homologação. Em **produção a nota TEM valor fiscal** e o
  MCP só emite com `confirmar_producao: true`: pergunte à pessoa antes e diga o valor e o tomador.
- **Pedir a produção é do dono, pelo painel** (sessão do painel); o MCP nunca pede nem libera.
- **Cancelar não se desfaz**: confirme com a pessoa; só nota `emitida` cancela; motivo `1`, `2` ou `9` e justificativa
  de 15 a 255 caracteres em uma linha.

## Texto recusado (`400 texto_invalido`)

A resposta traz o caminho do campo. Recusa: caractere de controle, Unicode mal formado, **`\r` em qualquer
campo**, e `\n` e tabulação em tudo, **exceto** `servico.descricao` e `servico.informacoes_complementares`. A
**justificativa do cancelamento não aceita quebra de linha** (15 a 255 caracteres, uma linha). Corpo aninhado
em mais de **32 níveis** também dá `texto_invalido`, com a mesma mensagem do caractere de controle: se o
usuário jura que não há caractere nenhum, olhe o aninhamento.

## Situações

`pendente` (ainda não aceita pelo motor), `processando`, `emitida` (tem `numero` e `chave_acesso`; PDF e XML no
bucket), `rejeitada` (veja `codigo_recusa`, `motivo`, `dica`), `erro`, `em_verificacao` (**segue sendo reconferida
automaticamente; não emita outra nota no lugar**, podem sair duas; há casos que só a equipe resolve, e então o usuário fala com o suporte), `cancelamento_pendente`, `cancelada`. `rejeitada`,
`erro` e `cancelada` não voltam atrás.

Recusas comuns: `E0312` (código de tributação não aceito pelo município, ou falta o municipal de 3 dígitos: corrija o cTribMun no serviço padrão; depois da correção, a próxima nota com o código corrigido não é mais barrada pelo motor; quem decide é a prefeitura no Sistema Nacional. Repetir o mesmo código continua barrado até o motor confirmar no ADN que o município o administra ou o suporte liberar),
`E0014` (número da DPS repetido; o usuário fala com o suporte do SuperDB, que ajusta o próximo número da DPS), `E0018` (competência antes da abertura do CNPJ ou da opção pelo Simples),
`E0116`/`E0120` (inscrição municipal exigida ou não aceita), `E0625` (ME/EPP do Simples sem retenção não leva
alíquota de ISS), `producao_nao_liberada`, `tenant_suspenso`.

## A tabela e os arquivos

- `sdb_notas_fiscais` (no schema do projeto): `id, ref, tipo, emitente_cnpj, tomador_documento, tomador_nome,
  valor, competencia, situacao, numero, chave_acesso, codigo_recusa, motivo, ambiente, pdf_path, xml_path,
  criada_em, emitida_em, cancelada_em, atualizada_em`.
- Lê o servidor (`service_role`). **anon e authenticated não veem nada** até o dono criar uma policy (a
  tabela tem CPF e nome de tomador). Só o SuperDB escreve: nem a chave de servidor escreve nela.
- ⚠️ **É um espelho, não a fonte da verdade.** Apagou a tabela, a coluna ou a linha: o SuperDB recria. **Alterou
  uma linha: a alteração fica até a nota mudar de situação**, e então é regravada. Para decidir qualquer coisa
  que valha dinheiro, use `GET /fiscal/v1/nfse/<id>`.
- PDF e XML no bucket `proj_<slug>_fiscal`, **privado e só para o servidor**; os caminhos vêm em
  `arquivos.pdf` e `arquivos.xml`. Baixe pelo servidor, com o nome COMPLETO do bucket. Não abra o bucket.
  Um bucket `fiscal` aberto que já exista no projeto recusa a ativação: renomeie ou apague e ative de novo.

## Limites e erros

- Notas por mês e CNPJs: os do plano da conta do projeto. Pro: 100 por mês e 1 CNPJ. Escala: 1.000 por mês e 5
  CNPJs. Grátis e Site: o teste em homologação, 50 notas por mês e 1 CNPJ, sem produção. Passou da cota do mês: `429 cota_fiscal_esgotada` com `Retry-After` até a virada
  do mês (dia 1º, horário de Brasília); não há excedente a pagar. Passou do número de CNPJs:
  `403 limite_de_cnpjs`.
- 600 requisições por minuto por projeto (`429 rate_limited`, `Retry-After`).
- Prontidão (6 por minuto) e parâmetros (5 por minuto): `429 motor_limite` e `503 adn_ocupado`, os dois com
  `Retry-After` (no máximo 1 hora). Espere e repita; a primeira consulta de um município frio pode dar `502`
  por demora, e a segunda costuma passar.
- `403 fiscal_fora_do_plano` (produção num plano sem produção: ao pedir produção e ao emitir nota nova por um emitente em produção; vem com `"ambiente": "producao"` e `upgrade_url`; a `ref` que já existia segue devolvendo a mesma nota, e consulta, arquivos, cancelamento e homologação continuam), `409 fiscal_suspenso`, `409 ativacao_em_andamento`, `409 cnpj_repetido`,
  `409 cnpj_ja_cadastrado` (o CNPJ já emite com valor fiscal em outra conta: cadastre com
  `somente_homologacao: true` para testar).

## Desativar, reativar, falta de pagamento

- **Desativar** (só pelo painel, em Notas fiscais): notas novas recusadas (`403
  fiscal_desativado`); consulta, PDF e cancelamento continuam; tabela e arquivos ficam com o cliente.
- **Reativar** é ativar de novo: o mesmo cadastro volta, com as notas antigas.
- **Falta de pagamento**: projeto pausado ou suspenso suspende o SuperDB Fiscal junto (`403 fiscal_suspenso`
  para notas novas; consulta e cancelamento continuam) e ele volta sozinho quando o projeto volta ao ar.
  Reativar com o projeto ainda fora do ar **não reativa nada**: a conta fica suspensa até o projeto voltar.
  A nota que bateu na suspensão vira `erro` (`tenant_suspenso`): emita de novo, com outra `ref`.

## Não existe (ainda)

NF-e de produto e NFC-e; município fora do padrão nacional; desconto, retenções e local de prestação no pedido; cobrança de excedente (acima da cota a nota é recusada até o dia 1º).
