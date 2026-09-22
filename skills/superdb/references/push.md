# Push (notificação no iPhone e no Android)

Doc pública: https://superdb.com.br/docs/push — este arquivo é o resumo operacional.

## Como funciona

1. **Credenciais, uma vez por projeto** (painel → Push, ou API de gestão):
   - Apple: arquivo `.p8` (Apple Developer → Keys → APNs) + Key ID + Team ID + Bundle ID.
   - Android: JSON da **conta de serviço** do Firebase (Configurações do projeto → Contas de
     serviço → Gerar nova chave privada). **Não** é o `google-services.json` (esse vai no app).
   - O painel confere com a Apple e com o Google antes de guardar. Por API:
     `PUT /platform/v1/projects/<id>/push/credenciais/apns` `{key_id, team_id, bundle_id, p8}` e
     `.../credenciais/fcm` `{conta_de_servico}` com a management key (`sdb_pmk_`).
2. **O app registra o aparelho** a cada abertura (e depois do login).
3. **Você manda** pelo servidor (`service_role`) ou de dentro do banco (`push.enviar`).
4. **O recibo** diz, por aparelho, se a Apple/o Google aceitou e por quê recusou. Token morto
   sai dos ativos sozinho.

## Registrar o aparelho (Expo)

```ts
const { data: token } = await Notifications.getDevicePushTokenAsync() // token NATIVO
await fetch('https://auth.superdb.com.br/push/v1/aparelhos', {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${(await superdb.auth.getDataPlaneToken()) ?? ANON_KEY}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({ token, plataforma: Platform.OS === 'ios' ? 'ios' : 'android' }),
})
```

- ⚠️ **Nunca `getExpoPushTokenAsync()`**: o `ExponentPushToken[...]` é recusado (`token_do_expo`).
- ⚠️ **Expo Go não serve** para testar: o token nativo é do app Expo Go → `DeviceTokenNotForTopic`.
  Use development build (EAS).
- Quem é o dono: sessão → o usuário logado (verificado, o `dono` do corpo é ignorado);
  `service_role` → o `dono` do corpo (verificado); anon → o `dono` do corpo (**não** verificado —
  qualquer um pode se declarar dono de qualquer id; não mande no push o que não pode vazar).
- Proteções de quem tem login: a anon NÃO pode declarar como dono um usuário do Auth do projeto
  (`403 dono_e_usuario`); dono com aparelho verificado não recebe nos só declarados; o teto de 10
  conta cada classe à parte. App com identidade própria: registre pelo servidor (service_role).
- `ambiente` (`producao`|`sandbox`) é opcional: se errar, o SuperDB tenta o outro e grava o certo.
- Logout: `DELETE /push/v1/aparelhos` com `{ token }` — senão o próximo usuário do celular recebe.
- Até 10 aparelhos ativos por dono (o menos recente sai).

## Mandar

Servidor (SÓ `service_role`; anon/sessão → `403 chave_de_servidor`):

```bash
curl -X POST https://auth.superdb.com.br/push/v1/enviar \
  -H "Authorization: Bearer $SUPERDB_SERVICE_ROLE_KEY" -H "Content-Type: application/json" \
  -d '{"destinatarios":["id-do-dono"],"titulo":"É sua vez","corpo":"A mesa espera","dados":{"sala":"4"}}'
# 202 {"id": "...", "status": "pendente"}
```

Banco — precisa rodar como o **dono do projeto**, então de uma função `security definer` criada
pelo SQL Editor ou pela API de SQL (ex.: gatilho `after insert`):

```sql
create or replace function avisa_proximo() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  -- freio: no máximo um aviso por destinatário a cada 30 s (push.envios mostra só o projeto)
  if exists (select 1 from push.envios where destinatarios = array[new.proximo_jogador::text]
              and criado_em > now() - interval '30 seconds') then
    return new;
  end if;
  perform push.enviar(array[new.proximo_jogador::text], 'É sua vez', 'A mesa está esperando você',
                      jsonb_build_object('sala', new.sala));
  return new;
end $$;
```

- ⚠️ **A policy da tabela decide para quem se pode mandar** (ex.: só para quem está na mesma sala,
  via função `security definer` como `na_sala`). Sem ela e sem o freio, qualquer usuário logado
  manda push para qualquer outro e esgota o limite do mês. Receita completa e testada em /docs/push.

- Chamado direto como anon/authenticated/service_role → `42501` (esses papéis são compartilhados
  entre projetos e não dizem de onde o push sairia).
- Função dessas exposta por RPC: conferir dentro dela quem pode avisar quem.
- Limites: 500 destinatários, título ≤ 200, corpo ≤ 1.000, `dados` objeto ≤ 3 KB, fila ≤ 1.000
  pendentes por projeto (`429 fila_cheia`). `opcoes`: `ttl`, `agrupar`, `som` (null = silencioso),
  `badge`, `prioridade` (`alta`|`normal`), `canal_android`.

## Recibo e diagnóstico

- `GET /push/v1/envios/<id>` (service_role) → `entregas[]` com `resultado`, `motivo`, `explicacao`.
- No SQL Editor: `select * from push.envios` / `push.entregas` (RLS: só os do projeto).
- Motivos comuns: `apns:Unregistered`/`fcm:UNREGISTERED` (app desinstalado — normal),
  `apns:InvalidProviderToken` (Key ID/Team ID/.p8 errados), `fcm:SENDER_ID_MISMATCH` (conta de
  serviço de outro projeto Firebase), `sem_credencial_apns|fcm`, `cota_mensal_esgotada`.
- "aceito" e nada apareceu → quase sempre permissão de notificação desligada no aparelho.

## Limite do plano

`push_envios_mes` em `packages/billing-plans`: Grátis e Site são para **testar** (1.000/mês);
Pro 250 mil; Escala 2 milhões. Conta cada aparelho que foi à Apple/ao Google. Passou:
`429 cota_mensal_esgotada` com `Retry-After` até a virada (meia-noite de Brasília).

## Não existe (ainda)

Push na web, token do Expo, agendamento, tópicos/segmentos, método no SDK (use `fetch`).
