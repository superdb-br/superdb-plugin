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
> Após o login, o `db.from(...)` usa o token da sessão sozinho → as queries respeitam a
> RLS por-usuário. Antes do login, usa a anon key (acesso público).

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

## Arquivos (storage) e tempo real (realtime) — por enquanto
O cliente ainda não tem `.storage`/`.channel`. Use os SDKs do Supabase apontados:
```ts
import { createClient } from '@supabase/storage-js'
const storage = createClient('https://storage.superdb.com.br', { apikey: anonKey, Authorization: `Bearer ${anonKey}` })
```
(Realtime: `@supabase/realtime-js` em `realtime.superdb.com.br`.) Itens em evolução.
