# Playbook: migrar um projeto Supabase → SuperDB

Pra quem já tem um app rodando em Supabase (inclusive Supabase self-hosted no Coolify).
Bônus: se era self-hosted, você desliga um stack inteiro (~10 containers) e ganha o VPS de volta.

## Visão geral (3 mudanças no app + mover os dados)
A migração mínima no CÓDIGO é: (1) trocar o `createClient`, (2) passar o `project` slug,
(3) apontar a anon key/URL novas. Schema + RLS você reaproveita quase igual.

## 1. Provisionar o projeto no SuperDB
Siga `playbooks/new-project.md` passo 1 (criar projeto no dashboard, pegar slug + anon key).

## 2. Mover o schema (estrutura)
1. Exporte o schema do Supabase (sem os dados de sistema):
   ```bash
   pg_dump "<DATABASE_URL_do_supabase>" \
     --schema=public --no-owner --no-privileges --schema-only > schema.sql
   ```
2. **Ajuste**: as suas tabelas vão pro schema `proj_<slug>` (não `public`). A forma mais
   simples: no SQL Editor do dashboard do SuperDB, cole os `CREATE TABLE` / `CREATE POLICY`
   das SUAS tabelas (o editor já roda dentro do schema do projeto). Pule extensões/roles do
   Supabase (auth.users, storage.*, etc. — o SuperDB tem os próprios).
3. **RLS**: recrie as políticas. Atenção ao identificador do usuário: no Supabase é
   `auth.uid()`; no SuperDB use `(current_setting('request.jwt.claims', true)::json->>'sub')`.
   (Crie um helper SQL `app.uid()` se quiser deixar igual.)

## 3. Mover os dados (linhas)
```bash
# exporta só os dados das suas tabelas
pg_dump "<DATABASE_URL_do_supabase>" --data-only \
  --table=tarefas --table=projetos > dados.sql
```
Importe via SQL Editor (ou peça pro Claude rodar os INSERTs). Para volumes grandes, use
`COPY`/`\copy`. Confira contagens antes/depois.

## 4. Mover os usuários (auth)
Os usuários do Supabase (`auth.users`) não vêm com a senha em claro. Opções:
- **Mais simples**: peça aos usuários para "redefinir senha" no primeiro acesso (signup/
  magic-link no SuperDB). Migre só o e-mail/perfil.
- Se precisar manter as senhas, é um trabalho à parte (hashes diferentes) — avalie se vale.

## 5. Trocar o cliente no app
Antes (Supabase):
```ts
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
```
Depois (SuperDB) — `npm install @superdb/client`, e o `createClient` quase igual (só o 3º arg `{ project }`):
```ts
import { createClient } from '@superdb/client'
const db = createClient('https://auth.superdb.com.br', process.env.SUPERDB_ANON_KEY!, {
  project: '<slug>',
})
```
> Zero-dep: dá pra usar o `templates/superdb.ts` (`createSuperDB({...})`) no lugar — mesmo contrato.
As chamadas `.auth.signInWithPassword` / `.from().select().eq()` / `.storage.from().upload()`
ficam **iguais** (o `.storage` é real). O que quebra: `.channel` (realtime — ainda stub, minte
`/rt/v1/token` com a sessão + `@supabase/realtime-js`; o RLS vale como no Supabase, mas regra que
consulta outra tabela precisa de função `security definer` — veja `references/recipes.md`) e alguns métodos de auth
que o SuperDB ainda não tem (`onAuthStateChange`, `resetPasswordForEmail`, etc.).

## 6. Validar + desligar o Supabase
- [ ] Login funciona no app contra o SuperDB
- [ ] Leitura/escrita das tabelas migradas OK (RLS respeitada)
- [ ] Contagem de linhas bate
Só então: desligue o projeto Supabase (no Coolify, pare o stack → libera CPU/RAM).

Se travar → `references/gotchas.md`.
