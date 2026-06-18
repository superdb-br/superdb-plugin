# Playbook: projeto novo no SuperDB (web ou mobile)

Objetivo: do zero a um app que faz login e lê/grava dados, em minutos.

## 1. Provisionar (uma vez, no navegador)
1. Abra https://app.superdb.com.br → criar conta (ou logar).
2. "Novo projeto" → dê um nome. Anote o **slug** gerado (ex: `meu_app`).
3. Abra o projeto → **Connect** (ou aba **API**). Copie a **anon key**.
   (A `service_role` fica oculta — só revele se for usar no backend.)

> Não dá pra provisionar via CLI/MCP hoje (não estão prontos) — o dashboard é o caminho.

## 2. Configurar o projeto
1. Instale o cliente: `npm install @superdb/client` (drop-in supabase-js).
   *Zero-dep:* em vez disso, copie `templates/superdb.ts` pro projeto (ex: `src/lib/superdb.ts`).
2. Copie `templates/.env.example` para `.env` e preencha:
   - `SUPERDB_AUTH_URL=https://auth.superdb.com.br`
   - `SUPERDB_PROJECT=<slug>`
   - `SUPERDB_ANON_KEY=<a anon key copiada>`
3. Inicialize (veja `references/recipes.md` → Inicializar). **Mobile**: passe `AsyncStorage`.

## 3. Criar as tabelas + RLS (no SQL Editor do dashboard)
```sql
create table tarefas (
  id bigint generated always as identity primary key,
  user_id text not null,
  titulo text not null,
  done boolean not null default false,
  created_at timestamptz not null default now()
);
alter table tarefas enable row level security;
create policy "minhas tarefas" on tarefas
  for all to authenticated
  using (user_id = (current_setting('request.jwt.claims', true)::json->>'sub'))
  with check (user_id = (current_setting('request.jwt.claims', true)::json->>'sub'));
```
> O `user_id` deve ser o `sub` do usuário logado. No insert, preencha
> `user_id` com `(await db.auth.getSession())?.user.id`.

## 4. Usar
```ts
await db.auth.signUp({ email, password })   // ou signInWithPassword
const uid = (await db.auth.getSession())?.user.id
await db.from('tarefas').insert({ user_id: uid, titulo: 'primeira tarefa' })
const { data } = await db.from('tarefas').select()
```

## 5. Checklist de "tá pronto"
- [ ] anon key é ES256 (começa com `eyJhbGciOiJFUzI1NiI`)
- [ ] `project` setado no createSuperDB
- [ ] tabelas com RLS ligada + política
- [ ] login funciona e o `.from()` retorna dados (não 401/403)

Se travar → `references/gotchas.md`.
