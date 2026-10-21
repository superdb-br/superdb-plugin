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
3. **RLS**: recrie as políticas. `auth.uid()`, `auth.jwt()` e `auth.role()` existem e se
   comportam como no Supabase, então a policy copiada roda sem edição. O que muda: não existe
   `auth.users` (a FK aponta para `proj_<slug>.auth_users`), e o token não carrega
   `app_metadata`/`user_metadata` (papel e permissão saem de uma tabela sua).
4. **Sem `pg_net` e sem `pg_cron`**: os **Database Webhooks** (gatilho que chama
   `net.http_post`) não migram, nem função que chame `net.http_*`. Passe a chamada para a
   aplicação (depois de gravar) ou para um worker que lê uma tabela de eventos preenchida por
   um gatilho. Agendamento fica fora do banco, chamando uma função via RPC.

## 3. Mover os dados (linhas)
```bash
# exporta só os dados das suas tabelas
pg_dump "<DATABASE_URL_do_supabase>" --data-only \
  --table=tarefas --table=projetos > dados.sql
```
Importe via SQL Editor (ou peça pro Claude rodar os INSERTs). Para volumes grandes, use
`COPY`/`\copy`. Confira contagens antes/depois.

## 4. Mover os usuários (auth)
**As senhas migram.** O Supabase guarda bcrypt, o SuperDB guarda Argon2id, e o login do
SuperDB confere o bcrypt de uma conta importada e troca a impressão no primeiro acesso —
ninguém precisa redefinir nada.

No painel do projeto, em **Autenticação → Users**, o próprio dono importa. Exporte assim:

```bash
psql "<DATABASE_URL_do_supabase>" -tA -c \
  "select json_agg(json_build_object('id', id, 'email', email,
   'encrypted_password', encrypted_password, 'email_confirmed_at', email_confirmed_at,
   'created_at', created_at, 'raw_user_meta_data', raw_user_meta_data)) from auth.users" \
  > usuarios.json
```

Cada conta entra com o **mesmo UUID**, então as FKs do seu schema continuam valendo.
Repetir o mesmo arquivo não duplica ninguém. Quem entrava só por link mágico ou login
social vem sem senha e continua entrando do mesmo jeito. O que **não** migra: fatores
TOTP (quem usava MFA cadastra o autenticador de novo).

> O arquivo tem o hash das senhas. Ele vai do seu computador direto para o seu projeto.
> Não mande esse arquivo para o suporte: chamado não aceita anexo. Apague a sua cópia depois.

**Onde os usuários ficam:** na tabela `auth_users` do schema do projeto
(`proj_<slug>.auth_users`). É para ela que apontam as FKs que no Supabase apontavam para
`auth.users(id)` — você pode recriar a FK, não precisa abrir mão dela.

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
consulta outra tabela precisa de função `security definer` — veja `references/recipes.md`), a API
`auth.admin` e `updateUser({ email })`, que o SDK ainda não tem. Desde o `@superdb/client` 0.3 existem
`onAuthStateChange`, `updateUser({ data })`, `resetPasswordForEmail`, `upsert`, `or`, `not`, `count` e a
renovação sozinha da sessão. Diferenças: `updateUser({ password })` de conta com senha pede
`current_password`; o link de redefinição volta com `#token=` e fecha com `resetPassword({ token, password })`;
`insert`/`update`/`delete` sem `.select()` devolvem `data: null` (como o supabase-js v2).

## 6. Validar + desligar o Supabase
- [ ] Login funciona no app contra o SuperDB
- [ ] Leitura/escrita das tabelas migradas OK (RLS respeitada)
- [ ] Contagem de linhas bate
Só então: desligue o projeto Supabase (no Coolify, pare o stack → libera CPU/RAM).

Se travar → `references/gotchas.md`.
