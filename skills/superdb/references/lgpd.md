# LGPD no SuperDB — o que a plataforma faz por você e o que continua sendo seu

Escrito para quem está construindo um app que trata dado pessoal. Cada
afirmação aqui foi medida contra o cluster de produção em 04/08/2026. O que não
existe está marcado como não existindo — num assunto de conformidade, uma
promessa errada vale menos que zero.

Vocabulário da lei, rápido: quem decide o que fazer com o dado é o
**controlador**; quem trata em nome dele é o **operador**. **Você é o
controlador** dos dados dos seus usuários. O SuperDB é operador. Isso significa
que a maior parte das obrigações é sua — a plataforma dá as ferramentas.

---

## ⚠️ Leia isto antes de qualquer outra coisa: RLS vem ligada, e é a policy que abre

Quando você cria uma tabela, por SQL (`/db/exec`, Editor SQL, migration, MCP) ou
pelo painel, um event trigger da plataforma roda e faz o seguinte (desde
17/08/2026; medido de novo em produção em 19/10/2026):

```sql
GRANT SELECT                        ON <tabela> TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON <tabela> TO authenticated, service_role;
ALTER TABLE <tabela> ENABLE ROW LEVEL SECURITY;
CREATE POLICY sdb_service_role_all ON <tabela> TO service_role USING (true) WITH CHECK (true);
```

Ou seja: **a tabela nasce fechada**, como no Supabase. A anon key e os usuários
logados recebem `[]` e têm o INSERT recusado até você escrever as policies.

O risco está em DESLIGAR a RLS. Com os GRANTs acima, `disable row level
security` deixa a tabela legível pela anon key, que é pública e vai no bundle do
seu app, no navegador de qualquer visitante. É o "conserto" clássico de quem
tomou erro de policy num insert, e a plataforma avisa na resposta do comando
(`rls_desligada`).

**Então, em toda tabela que você criar, escreva as policies na mesma migration:**

```sql
CREATE TABLE pacientes ( ... );

-- já vem ligada; repetir deixa a migration explícita e serve para outro Postgres
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "dono lê o próprio" ON pacientes
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "dono grava o próprio" ON pacientes
  FOR INSERT WITH CHECK (user_id = auth.uid());
```

Confira o resultado em **Saúde** (Advisors) no painel: ele lista, com o nome da
tabela, toda tabela sem RLS que a anon key alcança, e já entrega o `ALTER TABLE`
pronto. Ou pelo MCP: `superdb_list_policies` sem argumento mostra o projeto
inteiro. Trate achado ali como bloqueio de lançamento.

As funções de contexto (`auth.uid()`, `auth.role()`, `auth.email()`,
`auth.jwt()`) existem no cluster desde 30/07/2026 e funcionam dentro de policy.

---

## O que a plataforma entrega

**Residência no Brasil.** O Postgres, o storage e os backups ficam em São Paulo
(backups cifrados no servidor do SuperDB e guardados na AWS S3, região de São
Paulo). Isso sustenta responder "banco, arquivos e backups ficam no Brasil" numa
due diligence. Não diga "nada sai do país": e-mails transacionais (Resend, EUA),
SMS (Twilio, EUA) e login social (Google, GitHub, Apple, Microsoft) saem, quando
o cliente os ativa.

**Isolamento por projeto, no banco.** Cada projeto é um schema `proj_<slug>` com
role própria (`proj_<slug>_owner`), confinada: ela não enxerga schema de outro
projeto nem as tabelas globais da plataforma. O binding entre o token e o
`Accept-Profile` é validado no `pre_request` do PostgREST — não é convenção de
código de aplicação, é o Postgres recusando.

**CPF/CNPJ cifrado em repouso.** Guardados como par `*_enc` (AES-256-GCM com
chave derivada por tenant) + `*_hash` determinístico só para busca. O texto
claro não fica em lugar nenhum.

**Trilha de auditoria encadeada.** `auth_audit` guarda cada evento com
`prev_hash`/`curr_hash` (SHA-256): adulterar um registro quebra a corrente a
partir dele. Retenção por plano: 7 dias no Grátis e no Site, 30 no Pro, 90 no
Escala.

**Log de acesso ao banco.** O Postgres registra conexões, desconexões e **DDL** —
`log_statement=ddl`, deliberadamente **não** `all`. Com `all`, o log viraria a
maior cópia de PII do sistema, porque todo `WHERE cpf = '...'` iria para lá em
texto puro. Se você precisa de trilha de leitura por registro, ela tem que
nascer na sua aplicação, não no log do banco.

**Apagamento definitivo, de verdade.** Dois níveis:

```bash
# Um cliente inteiro de um group (schema, roles, storage, tudo)
curl -X DELETE "$SUPERDB_URL/groups/v1/$GROUP_ID/tenants/$SLUG/purge" \
  -H "Authorization: Bearer $GROUP_KEY"

# A sua própria conta de plataforma (cadastro, sessões, CPF/CNPJ, cartões).
# Exige o e-mail da conta e o aceite do termo de exclusão.
curl -X DELETE "$SUPERDB_URL/platform/v1/me" \
  -H "Authorization: Bearer $SESSAO" \
  -H "Content-Type: application/json" \
  -d '{"confirmacao": "voce@empresa.com.br", "aceito_termo": true}'
```

O `purge` é hard-delete atômico, não soft delete com flag. Quando a remoção não termina
na hora, a resposta vem **202** com `pendente: true`: o acesso já fechou, e os dados saem
sozinhos em alguns minutos. O slug purgado não volta a ser usado (`409 slug_taken`). O projeto
avulso (fora de group) tem o mesmo caminho no painel: Excluir projeto e, depois, "Liberar
espaço" em Projetos apagados. O `DELETE /me`
recusa com **409** enquanto você tiver projeto ativo, e diz quais: apagar a sua
conta não pode arrastar junto o dado dos usuários finais dos seus clientes. Sem
o e-mail certo e o `aceito_termo: true` no corpo, a resposta é **400**
`confirmacao_necessaria` e nada acontece. Assinatura ativa é cancelada no
provedor de pagamento na hora, sem reembolso proporcional; se o provedor não
responder, a resposta é **502** `provider_cancel_failed` e nada é apagado, e
tentar de novo é seguro. Também dá para fazer pelo painel, em **Minha conta →
Seus dados**, que mostra o termo antes.

O que **não** sai no apagamento, de propósito, porque é obrigação legal
concorrente (art. 16, I):

- As faturas pagas (e as estornadas), guardadas por 5 anos pela lei fiscal (CTN
  art. 173 e 195), só com valor, datas, plano, status e o código do pagamento e
  do cliente no provedor. Sem nome, CPF/CNPJ ou e-mail: o cadastro fiscal do
  pagador fica com o provedor de pagamento.
- Os registros de auditoria, que guardam identificador, não documento.

**Acesso e portabilidade (art. 18, II e V).** O par do apagamento — um responde
"o que vocês têm de mim", o outro "tirem tudo":

```bash
curl -OJ "$SUPERDB_URL/platform/v1/me/export" -H "Authorization: Bearer $SESSAO"
```

JSON com cadastro, **CPF/CNPJ decifrado**, sessões, identidades sociais,
projetos, groups, assinaturas, cartões mascarados, consultas salvas, histórico
de SQL e a trilha de auditoria. Não entra nada que seja credencial (senha,
segredo do MFA, hash de token) — isso não é dado sobre você, é a chave da porta.
Nem o conteúdo das tabelas dos seus projetos, que é dado dos seus usuários
finais e sai pelo Editor SQL.

No painel: *Minha conta → Seus dados → Baixar arquivo*.

---

## O que **não** existe — não prometa ao seu cliente

| Item | Situação hoje |
|---|---|
| Certificação ISO 27001 / SOC 2 | **Não existe**, e não há auditoria contratada |
| SAML SSO / SCIM 2.0 | **Respondem 402.** Não estão no ar em nenhum plano |
| Anonimização automática | Não existe. Se você precisa pseudonimizar, é a sua migration |
| Antivírus em upload de arquivo | Não existe scanner nenhum no storage |
| DPO nomeado / ROPA / contrato de operador assinado | Fora do código — é papelada da empresa, e ela não está pronta |

Essa última linha importa mais do que parece: **a conformidade da sua operação
não fica pronta só porque a infraestrutura ajuda.** Registro de operações
(ROPA), base legal declarada, encarregado nomeado e o contrato com o operador
são obrigações suas, e nenhuma delas é técnica.

---

## Um checklist honesto para um app novo com dado pessoal

1. **Colete menos.** O dado que você não guarda não vaza, não precisa de base
   legal e não aparece num pedido de eliminação.
2. **Ligue RLS em toda tabela** e confirme em Saúde/Advisors que a lista está
   vazia. Isto é o passo 1 de verdade.
3. **Separe o dado sensível.** Saúde, biometria, origem racial, opinião política
   e religião são categoria especial na LGPD e pedem base legal mais estreita.
   Tabela separada com policy própria facilita o dia do pedido de eliminação.
4. **Decida a retenção antes de escrever a primeira linha.** "Guardar para
   sempre" não é uma decisão, é a falta de uma.
5. **Tenha o caminho do apagamento pronto** antes do primeiro pedido chegar: uma
   query ou uma rota que você já testou, não uma que você vai escrever com o
   prazo correndo.
6. **Não mande PII para log nem para serviço de terceiro** (analytics, erro,
   IA) sem pensar. É o vazamento mais comum e o mais bobo.
7. **2FA na sua conta do SuperDB.** Todo o resto depende de ninguém entrar nela.

## Para responder ao seu cliente

Quando um cliente seu perguntar "onde ficam os dados e quem acessa": os dados
ficam em São Paulo (backups inclusive), num banco de dados próprio do projeto, com role de banco
confinada a ele; CPF e CNPJ ficam cifrados; existe trilha de auditoria encadeada com
retenção pelo plano; e o apagamento é definitivo, com endpoint próprio. O que a
plataforma **não** tem é certificação formal — e dizer isso na hora certa vale
mais do que a certificação valeria.
