# Receitas SuperDB (copie e adapte)

Pressupõe `templates/superdb.ts` copiado no projeto. Tudo ancorado no que você já
faz no Supabase.

## Inicializar o cliente
Com o pacote npm (recomendado — drop-in supabase-js):
```ts
import { createClient } from '@superdb/client'   // npm install @superdb/client
export const db = createClient('https://auth.superdb.com.br', process.env.SUPERDB_ANON_KEY!, {
  project: 'meu_projeto',
})
```
Ou com o template zero-dependência (`templates/superdb.ts` copiado no projeto):
```ts
import { createSuperDB } from './superdb'
export const db = createSuperDB({
  authUrl: 'https://auth.superdb.com.br',
  anonKey: process.env.SUPERDB_ANON_KEY!,
  project: 'meu_projeto',
})
```
> Daqui pra baixo, `.auth` e `.from()` são **idênticos** nos dois (`db` é a mesma coisa).

## Auth
```ts
// cadastro
await db.auth.signUp({ email, password, full_name: 'Fulano' })
// login (guarda a sessão + o token de dados automaticamente)
await db.auth.signInWithPassword({ email, password })
// sessão atual
const s = await db.auth.getSession()   // { user, access_token, data_plane_token, ... }
// sair
await db.auth.signOut()
```

### Login social (Google / GitHub / Apple)
```ts
// 1) ligue o provedor E cadastre a URL de retorno no dashboard (Autenticação)
// 2) inicia — o SDK cuida do PKCE sozinho
const { data } = await db.auth.signInWithOAuth({
  provider: 'google',
  redirectTo: 'https://meuapp.com.br/auth/callback',  // mobile: 'meuapp://auth'
})
// 3) leve o usuário pra data.url; na volta chega ?code=XXX
await db.auth.exchangeCodeForSession(code)   // → sessão pronta
```
> Detalhes (BYO vs gerenciado, allowlist, Expo/RN, erros): `social-login.md`.
> Requer `@superdb/client` ≥ 0.2.0.
> Após o login, o `db.from(...)` usa o token da sessão sozinho → as queries respeitam a
> RLS por-usuário. Antes do login, usa a anon key (acesso público).

### Login por código (OTP) — e-mail ou WhatsApp

```ts
// 1) manda o código. channel: 'email' (padrão) | 'whatsapp' | 'sms'
await db.auth.signInWithOtp({ phone: '+5531999998888', options: { channel: 'whatsapp' } })

// 2) confirma. Mande o MESMO alvo do passo 1 — phone com phone, email com email.
await db.auth.verifyOtp({ phone: '+5531999998888', code: '123456' })   // → sessão pronta
```

**O telefone precisa ir igual nas duas chamadas.** O WhatsApp normaliza números
brasileiros na entrega (chega a remover o nono dígito no destinatário), mas o que casa
o código é o que **você** mandou, não o que o WhatsApp fez com ele.

`verifyOtp` aceitava só `email` até 31/08/2026 — dava para enviar por WhatsApp e não
havia como validar. Se o seu `@superdb/auth-js` for anterior, atualize.

**Erros que você precisa tratar** (a plataforma NÃO troca de canal sozinha — o fallback
é do seu app):

| código | quer dizer | o que fazer |
|---|---|---|
| `whatsapp_send_failed` | o envio não saiu (número sem WhatsApp, gateway fora, ou o número compartilhado do SuperDB no teto) | caia para `email` |
| `whatsapp_not_configured` | o canal não está disponível na plataforma | caia para `email` |
| `sms_not_configured` | não há provedor de SMS configurado | use `email` ou `whatsapp` |
| `invalid_otp` | código errado ou expirado | peça de novo |

**Número próprio (recomendado se você tem usuários finais).** Sem configurar, o código sai
do WhatsApp do SuperDB — de um número que o seu usuário não reconhece, assinado
"SuperDB". Em *Dashboard → Auth → WhatsApp do projeto* você pareia o seu número e o
código passa a chegar com o nome do seu projeto. Se ele cair, o envio volta ao da
plataforma sozinho (o login não para) e a tela mostra "Desconectado". Parear também é só
no Pro e no Escala. Use um chip dedicado, nunca o WhatsApp pessoal de alguém: banimento
derruba a conta inteira.

- O número compartilhado do SuperDB tem teto SOMANDO todos os projetos: 60/hora e
  300/dia. Acima dele: `503 whatsapp_send_failed`, sem gerar código. Volume → número próprio.
- O texto é fixo, de propósito (anti-banimento: sem link, sem propaganda):
  `Marca: seu código de acesso é *123456*. Não compartilhe com ninguém. Vale por 10 minutos.`

### Excluir a conta (obrigatório em app iOS/Android)
A Apple **exige** exclusão de conta dentro do app em qualquer app que permita criar conta
(App Store Review Guideline **5.1.1(v)**) — sem isso a submissão é rejeitada. Também é o
direito ao esquecimento da LGPD no nível do titular.

```ts
// o usuário logado apaga a PRÓPRIA conta (o id vem do token, nunca de param)
await fetch(`${SUPERDB_URL}/auth/v1/user`, {
  method: 'DELETE',
  headers: { Authorization: `Bearer ${accessToken}` },
})
// → 200 { deleted: true, sessions_revoked, identities_deleted }
```
É **hard delete imediato**: revoga as sessions, apaga identities/MFA/OTP/consents/memberships
e remove o usuário. O login para de funcionar na hora. Fica registrado um evento
`user.account_deleted` na trilha de auditoria (append-only), já anonimizado.

> ⚠️ **As tabelas do SEU app não são tocadas.** A plataforma não conhece o schema do app.
> Use FK com `ON DELETE CASCADE` pra `auth_users` nas suas tabelas, ou apague os dados do
> usuário antes de chamar o endpoint — senão sobram linhas órfãs com dado pessoal (e a
> Apple/LGPD esperam que sumam também).

## CRUD (igual supabase-js)
```ts
// ler
const { data, error } = await db.from('tarefas').select('id, titulo, done').eq('done', false)
// ler com ordem + limite
await db.from('tarefas').select().order('created_at', false).limit(20)
// inserir (retorna a linha criada)
await db.from('tarefas').insert({ titulo: 'comprar pão' })
// atualizar
await db.from('tarefas').update({ done: true }).eq('id', 42)
// deletar
await db.from('tarefas').delete().eq('id', 42)
```

## Mobile (Expo / React Native)
A única diferença é o **storage** (RN não tem localStorage). Passe AsyncStorage:
```ts
import AsyncStorage from '@react-native-async-storage/async-storage'
import { createClient } from '@superdb/client'

export const db = createClient('https://auth.superdb.com.br', process.env.EXPO_PUBLIC_SUPERDB_ANON_KEY!, {
  project: 'meu_app',
  storage: AsyncStorage,   // <- guarda a sessão no device
})
// (template zero-dep equivalente: createSuperDB({ ..., storage: AsyncStorage }))
```
O resto (`.auth`, `.from()`) é idêntico. `fetch` é nativo no RN, então o cliente funciona
sem mudança.

**Login social no mobile** usa PKCE + deep link (`meuapp://auth`) — precisa cadastrar o
deep link no dashboard e ter WebCrypto (`expo-crypto`). Receita completa em
`social-login.md` → seção 3.

## RLS — isolar dados por usuário (faça isso!)
No SQL Editor do dashboard (ou via migration), em CADA tabela de dados:
```sql
alter table tarefas enable row level security;

-- cada usuário só vê/edita as próprias linhas (user_id = quem está logado)
create policy "minhas tarefas" on tarefas
  for all to authenticated
  using (user_id = (current_setting('request.jwt.claims', true)::json->>'sub'))
  with check (user_id = (current_setting('request.jwt.claims', true)::json->>'sub'));

-- leitura pública (opcional) — para a anon key ver:
create policy "leitura publica" on cidades for select to anon using (true);
```
Sem política, a tabela com RLS **nega tudo** (deny-by-default). É o esperado/seguro.

## Perfil do usuário (profiles) — NÃO leia `auth_users` via REST
`auth_users` é **bloqueada no data-plane** (tem hash de senha/chaves). Dados de auth (id,
email) vêm de `db.auth.getUser()/getSession()`. Pra guardar perfil do app, crie uma tabela
de negócio sua ligada ao id do usuário:
```sql
create table profiles (
  user_id text primary key,   -- = o sub do usuário logado
  nome text,
  avatar_url text,
  updated_at timestamptz not null default now()
);
alter table profiles enable row level security;
create policy "meu perfil" on profiles for all to authenticated
  using (user_id = (current_setting('request.jwt.claims', true)::json->>'sub'))
  with check (user_id = (current_setting('request.jwt.claims', true)::json->>'sub'));
```
```ts
const s = await db.auth.getSession()
const uid = s?.user.id
await db.from('profiles').insert({ user_id: uid, nome: 'Fulano' })   // cria
await db.from('profiles').update({ nome: 'Novo' }).eq('user_id', uid) // atualiza
const { data } = await db.from('profiles').select().eq('user_id', uid) // lê (RLS garante)
```

## Arquivos (storage) — funciona pelo próprio cliente

> **Duas armadilhas medidas em 31/08/2026:**
>
> 1. **O que o token de storage pode fazer depende da chave que o gerou.** A `anon`
>    (pública) dá **só leitura de bucket público**; enviar/apagar/criar bucket exige a
>    `service_role` (no servidor) ou a sessão de um usuário logado. A `service_role` NUNCA
>    vai para o navegador.
> 2. **O status HTTP do storage não é confiável — leia o corpo.** Ele responde `400` para
>    erros que não são 400; o código real vem em `statusCode` no JSON. Upload num caminho
>    existente devolve `HTTP 400` com `{"statusCode":"409","error":"Duplicate"}`. É
>    comportamento do storage-api upstream, não da nossa camada.
`db.storage` é real: o cliente troca a data-plane key (ES256) por um token de storage
(`POST /st/v1/token`) sozinho e cacheia. **Não** aponte `@supabase/storage-js` com a anon key
direto — o storage-api valida HS256 e a anon key é ES256 → toma 401.
```ts
// O bucket se chama proj_<slug>_<nome> — o nome COMPLETO, como aparece no painel.
// `from('avatars')` não acha o bucket (a URL pública dá 400). Criado no painel ou via mgmt key.
const BUCKET = 'proj_meuapp_avatars'
const file = new Blob(['oi'], { type: 'text/plain' })
const { error } = await db.storage.from(BUCKET).upload(`u/${uid}.txt`, file, { upsert: true })
// download / URL assinada / listar / remover
const { data: blob } = await db.storage.from(BUCKET).download(`u/${uid}.txt`)
const { data: signed } = await db.storage.from(BUCKET).createSignedUrl(`u/${uid}.txt`, 3600)
await db.storage.from(BUCKET).remove([`u/${uid}.txt`])
// miniatura de imagem (bucket público): outro caminho, não query na URL do arquivo
const { data: { publicUrl } } = db.storage.from(BUCKET).getPublicUrl('foto.jpg')
const thumb = publicUrl.replace('/object/', '/render/image/') + '?width=200&height=200&resize=cover'
```
> ⚠️ **Não há pasta por usuário no Storage**: todo usuário logado do projeto lê, grava e apaga
> em todos os buckets do projeto, inclusive os privados. Bucket privado protege de quem só tem a
> URL ou a anon key. Não prometa ao usuário final que "só ele vê" um arquivo.

## Tempo real (realtime) — mint + realtime-js
`db.channel` ainda é stub. Minte um token dedicado e use o SDK do Supabase.

⚠️ **Qual token vai no `Authorization` do mint** (isto derruba quem erra): a **anon
key** (ES256, pública) ou o **`data_plane_token`** do usuário (ES256, o mesmo que
você usa nas chamadas REST). **NUNCA o `access_token` da sessão** — esse é PASETO
(só identidade) e o mint responde **401 invalid token**. Só ES256/JWKS passa aqui.

O mint devolve um HS256 curto com `role: rt_<schema>` — uma role Postgres exclusiva
do projeto — e `sdb_role`, o papel da credencial que pediu. **O realtime segue o RLS
da tabela com esse papel**: com o `data_plane_token` da sessão, o usuário recebe as
linhas que leria pela API; com a anon key, só o que um visitante sem login leria. O
mint é client-side nos dois casos (o `data_plane_token` é do próprio usuário).

```ts
// 1) minta o token de realtime com a SESSÃO (sem login: a anon key)
const credencial = (await db.auth.getDataPlaneToken()) ?? anonKey
const r = await fetch('https://auth.superdb.com.br/rt/v1/token', {
  method: 'POST', headers: { Authorization: `Bearer ${credencial}` },
}).then((x) => x.json())   // { token, url, role, papel_de_origem, expires_in } — 401? refreshSession() e repita
// 2) conecta com @supabase/realtime-js — r.token vai no apikey
import { RealtimeClient } from '@supabase/realtime-js'
const rt = new RealtimeClient(r.url, { params: { apikey: r.token } })
rt.channel('proj_<slug>:mensagens', { config: { private: true } })
  .on('postgres_changes', { event: '*', schema: 'proj_<slug>', table: 'mensagens' }, console.log).subscribe()
// 3) o token expira em 1h: minte de novo e rt.setAuth(novoToken) antes de expirar — e ao entrar/sair da conta.
```

**Regra que consulta outra tabela** precisa de função `security definer` para valer no
realtime (ele confere a regra com o papel `rt_<schema>`, que não lê as outras tabelas; sem
isso a regra vale `false` lá e o painel avisa ao ativar):
```sql
create or replace function e_membro(sala uuid) returns boolean
language sql stable security definer set search_path from current as $$
  select exists (select 1 from membros where sala_id = sala and user_id = auth.uid())
$$;
create policy mensagens_ler on mensagens for select to authenticated using (e_membro(sala_id));
```
Não crie policy `TO rt_<schema>`: a plataforma mantém o espelho da RLS sozinha.

**Filtro em coluna** (`filter: 'tenant_id=eq.x'`): a tabela precisa estar publicada
pelo painel (aba Realtime) — isso concede à role `rt_<schema>` o acesso à coluna. Sem
publicar, o subscribe falha com `invalid column for filter` (a role não enxerga a
coluna). Publicar já resolve; a plataforma cuida do grant e do espelho da RLS. Publicar
exige RLS ligada na tabela.
