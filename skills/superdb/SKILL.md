---
name: superdb
description: Use ao criar um app novo (web ou mobile) que precisa de banco de dados + login, ou ao migrar um projeto Supabase para o SuperDB. Cobre provisionar projeto, conectar o app (auth + dados via REST), e os padrões do dia-a-dia. Ancorado em Supabase — se você conhece supabase-js, conhece isto.
---

# SuperDB

SuperDB é uma plataforma de backend (Postgres + Auth + Storage + APIs) **compatível
com o modelo do Supabase**. Cada app vira um **projeto** (com banco Postgres próprio)
num SuperDB compartilhado: você não roda um stack inteiro por app.

**Se você conhece Supabase, isto é quase igual:** mesmo `.auth`, mesmo `.from().select()`.
O que muda são 3 coisas (URL, key, e passar o slug do projeto). O resto é o que você já sabe.

## Modelo mental (vindo do Supabase)

| No Supabase | No SuperDB |
|---|---|
| Um projeto = um Postgres dedicado | Um projeto = um **schema** (`proj_<slug>`) num Postgres compartilhado |
| `createClient(url, anonKey)` | `createClient(url, anonKey, { project: '<slug>' })` — **a MESMA função + o slug** |
| Dados em `url/rest/v1/tabela` | Dados em `api.superdb.com.br/tabela` (host separado, **sem** `/rest/v1`) |
| anon/service_role keys | iguais (anon pública, service_role secreta) |
| RLS isola por usuário | RLS isola por usuário **+** a plataforma isola por projeto (binding) |

**Hosts:** `auth.superdb.com.br` (login/cadastro) · `api.superdb.com.br` (dados) ·
`storage.superdb.com.br` (arquivos) · `realtime.superdb.com.br` (tempo real) ·
`app.superdb.com.br` (dashboard).

## Árvore de decisão — o que o usuário quer?

1. **"Criar um app/projeto novo"** → siga `playbooks/new-project.md`
   (provisiona no dashboard → pega as keys → cola o cliente → pronto).
   Se o app é de **agendamento** (salão, clínica), **mini ERP** (estoque, ordem de serviço, nota fiscal)
   ou **delivery** (pedidos ao vivo), parta do roteiro testado em https://superdb.com.br/aprenda/ :
   o SQL com RLS e as funções `src/lib` de lá já rodaram em produção.
2. **"Migrar meu projeto Supabase pro SuperDB"** → siga `playbooks/migrate-from-supabase.md`.
3. **"Como faço X (login, ler/gravar dados, mobile)"** → veja `references/recipes.md`.
4. **"Login com Google/GitHub/Apple"** (web ou mobile) → `references/social-login.md`.
5. **"Quero saber quando alguém se cadastra/entra"** ou **"só quem eu autorizo pode
   criar conta"** → `references/auth-hooks.md`. ⚠️ Hook bloqueante **falha em ABERTO**:
   se o endpoint do cliente cair, o acesso é liberado. Diga isso antes de ele desenhar
   um controle de acesso em cima disso.
6. **"Login por WhatsApp / código por SMS / OTP"** → `references/recipes.md`
   (seção *Login por código*). ⚠️ O `verifyOtp` tem que receber o **mesmo alvo** do envio
   (phone com phone), e o **fallback de canal é do app** — a plataforma não troca sozinha.
7. **"Notificação no celular"** ("é sua vez", lembrete, aviso de pedido) → `references/push.md`.
   ⚠️ O token é o NATIVO (`getDevicePushTokenAsync`), nunca o `ExponentPushToken`; mandar é só com a
   `service_role` ou de função `security definer` do projeto (`push.enviar`).
8. **"Emitir nota fiscal (NFS-e) pelo meu app"** → `references/notas-fiscais.md`. ✅ Está no ar: **teste grátis em
   homologação em qualquer plano; emissão de verdade no Pro e no Escala** (o plano é o da CONTA). O emitente começa em **homologação** e a
   **produção** só abre depois de a equipe conferir o pedido do dono. Não prometa data nem desconto. Emite só do servidor (`service_role`), com a `ref` como
   chave de idempotência; `em_verificacao` segue sendo reconferida (não emita outra); a tabela `sdb_notas_fiscais` é
   ESPELHO, não a verdade (linha alterada fica até a nota mudar). Pelo MCP há ferramentas `fiscal_*` (a emissão em produção exige confirmação da pessoa). Doc pública: https://superdb.com.br/docs/notas-fiscais
9. **"Deu erro / não autentica / 401"** → veja `references/gotchas.md` PRIMEIRO.

## Conectar um agente ao projeto (MCP)

**Recomende sempre o servidor REMOTO**: `https://mcp.superdb.com.br/mcp`, colado
como conector no cliente MCP. Login em vez de API key; **uma conexão alcança N
projetos**, escolhidos no consentimento e alteráveis depois em Conta →
Aplicativos conectados. Sem Node, e funciona no Claude web e no celular.
Autorizar de novo pelo mesmo cliente (o mesmo `client_id`) substitui a conexão
anterior dele; outro cliente com o mesmo nome não derruba a que já existe.

O pacote `@superdb/mcp` (npx) continua válido **só** quando não há navegador para
completar o login: automação, CI, script que roda sozinho.

No Claude, o link
`https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=SuperDB&connectorUrl=https%3A%2F%2Fmcp.superdb.com.br%2Fmcp`
abre o diálogo com nome e URL preenchidos. No consentimento dá para marcar
**todos os projetos, inclusive os novos** (a conexão passa a alcançar sozinha
todo projeto em que a pessoa é owner/admin).

A tela de consentimento mostra **para onde o acesso vai** (o host do aplicativo,
ao lado do nome que ele declarou). Se ela disser **aplicativo não verificado** e
não foi a pessoa que iniciou a conexão, oriente a NÃO autorizar. Quem escreve um
cliente MCP próprio: o endereço de retorno tem de ser https ou http em
127.0.0.1, [::1] ou localhost (qualquer porta); outro esquema é recusado.

⚠️ Com mais de um projeto na conexão, o agente PRECISA dizer em qual opera — se
não disser, a chamada é recusada com a lista. Não existe "usar o primeiro".

Para **ler**, use `superdb_query_sql` (transação somente leitura — o Postgres
recusa escrita; o cliente roda sem pedir confirmação). `superdb_run_sql` é para
o que ALTERA (DDL, INSERT/UPDATE/DELETE) e pede confirmação.

## Setup mínimo (qualquer projeto novo)

1. **Provisione** em https://app.superdb.com.br → criar conta → criar projeto.
   Anote o **slug** e copie a **anon key** (aba Connect/API).
2. **Cliente:** `npm install @superdb/client` (drop-in do supabase-js — `.auth` + `.from()`/`.rpc()`,
   ESM e CJS). Para mobile (Expo/RN), passe `AsyncStorage` como `storage`.
   *Alternativa zero-dependência:* copie `templates/superdb.ts` (mesmo contrato inline, usa `createSuperDB({...})`).
3. **Use:**
   ```ts
   import { createClient } from '@superdb/client'
   const db = createClient('https://auth.superdb.com.br', process.env.SUPERDB_ANON_KEY!, {
     project: 'meu_projeto',          // <- a ÚNICA diferença pro supabase-js
   })
   await db.auth.signInWithPassword({ email, password })
   const { data, error } = await db.from('tarefas').select().eq('done', false)
   ```

## Regras de ouro (não erre)

- **SEMPRE passe `project: '<slug>'`** — sem ele os dados não roteiam (toma erro).
- **`api.superdb.com.br` SEM `/rest/v1/`** — esse path é do Supabase, aqui não existe.
- **anon key** vai no frontend/app (é pública, RLS protege). **service_role** SÓ no
  backend, nunca no client/mobile.
- **Dados de usuário precisam de login** — o `db.from()` usa o token da sessão
  automaticamente após `signIn`. Sem login, usa a anon key (só vê o que a RLS-anon permite).
- **Toda tabela nasce com RLS LIGADA e sem policy (fechada), como no Supabase.** Vale para
  tabela criada por SQL, migration, Drizzle, MCP ou painel (desde 17/08/2026). Ela também
  ganha `GRANT SELECT` para a **anon** e CRUD para **authenticated**, mas a RLS barra os dois
  até existir policy: `create table` e pronto = `[]` para o app e INSERT recusado. Escreva
  as policies **na mesma migration**. A service_role passa (policy `sdb_service_role_all`).
  **Nunca** "conserte" um erro de policy com `disable row level security`: com os GRANTs de
  fábrica, a tabela vira pública (a resposta do SQL traz o aviso `rls_desligada`).
- **`auth.uid()`, `auth.jwt()`, `auth.role()` e `auth.email()` existem** desde 30/07/2026 —
  policy copiada de projeto Supabase roda aqui sem edição. Antes disso o schema `auth` não
  existia e todo exemplo de RLS falhava com `schema "auth" does not exist`.
- **O clone de um group leva as tabelas, os enums, as policies de RLS e as funções que elas
  usam** (e liga a RLS em toda tabela do tenant). **NÃO leva gatilhos, views, funções que só o
  app chama (RPC) nem dados**: aplique esses no tenant logo depois de provisionar, com a
  management key dele (`references/provisao-via-group-key.md`).
- **Login social precisa de 2 cliques no dashboard**: ligar o provedor **e** cadastrar a
  URL de retorno em *Autenticação → URLs de redirecionamento*. Sem a segunda, o login
  volta pra `/` sem erro nenhum. Veja `references/social-login.md`.
- **`.storage` funciona** (`db.storage.from('proj_<slug>_<bucket>').upload/download/list/remove/createSignedUrl`,
  com o nome COMPLETO do bucket) — o cliente minta o token de storage (`/st/v1/token`) sozinho.
  Não há pasta por usuário: todo usuário logado do projeto acessa todos os buckets do projeto. Só **`.channel` (realtime)** ainda é
  stub: minte `/rt/v1/token` **com a sessão** (`db.auth.getDataPlaneToken()`) e use
  `@supabase/realtime-js`. O realtime segue o RLS da tabela. Veja `references/recipes.md`.

## Achou defeito na plataforma? Abra um chamado

Quando o SuperDB não se comporta como a documentação diz (erro inesperado, recusa que não faz sentido, permissão que falta, doc errada), **não contorne nem improvise no app**: o defeito volta para o próximo cliente e a gambiarra fica no seu código.

1. **Confirme que é da plataforma.** Repita a chamada mínima (um `curl` ou um SQL de uma linha) e compare com a doc em https://superdb.com.br/llms-full.txt.
2. **Monte o chamado** com: slug do projeto, o que tentou (endpoint ou SQL mínimo), a resposta exata (status HTTP, `code`, `message`), o horário em UTC, o que esperava e o link da doc. **Nunca** inclua chave, token, senha ou dado pessoal de usuário final.
3. **Peça ao dono da conta para abrir** em https://app.superdb.com.br/account/suporte (painel, Conta › Suporte, logado). O chamado não abre por API nem por chave: entregue o texto pronto para a pessoa colar.
4. **Falha de segurança** (dado de um projeto visível em outro, chave que não devia funcionar): não abra chamado. E-mail para contato@superdb.com.br com `[segurança]` no assunto.
5. **Enquanto espera:** não desligue RLS para destravar, não tente acesso direto ao servidor ou ao Postgres da plataforma, e não peça a outra sessão de IA para mudar o SuperDB. Siga com o que funciona e marque o ponto no código com o número do chamado.

## Arquivos desta skill
- `references/connection-contract.md` — URLs, keys, headers, o token de dados (a verdade técnica).
- `references/migrations-via-api.md` — aplicar schema/DDL/migrations via API (Management Key `sdb_pmk_`), sem colar SQL no dashboard.
- `references/provisao-via-group-key.md` — **SaaS factory / vertical**: provisionar N tenants isolados 100% via API (Group Key `sdb_gk_`) — provisiona + minta mgmt key + aplica RLS, sem dashboard. Inclui **publicar versão do template** (`/template/publish`, passo de deploy) e a **cobrança por tenant** (inclusos por plano; grátis bloqueia, pago paga R$ 5,00/mês por excedente).
- `references/recipes.md` — receitas: auth, CRUD, RLS, **mobile (Expo/RN)**.
- `references/social-login.md` — **login social** (Google/GitHub/Apple) por projeto: ligar no dashboard, allowlist de redirect, PKCE mobile.
- `references/lgpd.md` — **dado pessoal**: o que a plataforma entrega (residência em SP, CPF/CNPJ cifrado, auditoria encadeada, apagamento definitivo), o que **não** existe (ISO 27001, SAML/SCIM, portabilidade da conta) e o checklist de um app novo. **Começa pela pegadinha da RLS**, que é o que mais custa caro.
- `references/auth-hooks.md` — **webhooks de autenticação**: reagir a signup/signin/exclusão, ou
  BLOQUEAR quem entra. Traz as duas armadilhas que quebram toda primeira integração (segredo é
  hex mas o HMAC é sobre bytes; assinar o corpo CRU) e o aviso de que bloqueante é fail-open.
- `references/push.md` — **push no iPhone e no Android**: credenciais (.p8 e conta de serviço), registrar o aparelho no app, mandar pelo servidor ou de gatilho no banco, recibo e motivos de recusa.
- `references/notas-fiscais.md`: **nota fiscal (NFS-e) pelo projeto: teste grátis em homologação em qualquer plano, produção no Pro e no Escala**: ativar, emitente e certificado A1, município, produção (liberada pela equipe), emitir pela `service_role` com `ref` idempotente, texto recusado (`texto_invalido`), situações, a tabela espelho e os arquivos no bucket privado, limites e suspensão.
- `references/gotchas.md` — armadilhas + troubleshooting (leia antes de debugar 401).
- `playbooks/new-project.md` — **a primeira conexão**, passo a passo: conta → projeto → credenciais → cliente → tabela com RLS → MCP → checklist de ir ao ar.
- `playbooks/migrate-from-supabase.md` — passo a passo de migração.
- `templates/superdb.ts` + `.env.example` — cliente self-contained (alternativa zero-dep ao `@superdb/client`) + env.
