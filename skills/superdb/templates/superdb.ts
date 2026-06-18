// superdb.ts — cliente SuperDB self-contained (web). Zero dependências.
// Copie este arquivo no seu projeto. Cobre auth + dados (REST/PostgREST).
//
// O mesmo contrato está publicado no npm (drop-in supabase-js):
//   npm install @superdb/client
//   import { createClient } from '@superdb/client'   // createClient(url, anonKey, { project })
// Este arquivo é a alternativa ZERO-DEPENDÊNCIA (bom pra entender o contrato ou
// pra ambientes sem build/npm). A API aqui é createSuperDB({ authUrl, anonKey, project }).
//
// SuperDB tem DOIS hosts: auth.* (login/cadastro) e api.* (dados). O login
// devolve um `data_plane_token` (ES256) que vai como Bearer pro api.*, junto do
// header Accept-Profile = proj_<slug> (roteia + isola o seu projeto).

export interface SuperDBSession {
  access_token: string;
  data_plane_token: string | null;
  refresh_token: string;
  user: { id: string; email?: string };
}

interface SessionStore {
  getItem(k: string): string | null | Promise<string | null>;
  setItem(k: string, v: string): void | Promise<void>;
  removeItem(k: string): void | Promise<void>;
}

export interface SuperDBOptions {
  /** URL de auth (ex: https://auth.superdb.com.br) */
  authUrl: string;
  /** anon key do projeto (do dashboard) */
  anonKey: string;
  /** slug do projeto (vira o schema proj_<slug> e o Accept-Profile) */
  project: string;
  /** URL de dados; default: authUrl com auth.* -> api.* */
  apiUrl?: string;
  /** onde guardar a sessão. web: localStorage; mobile: AsyncStorage */
  storage?: SessionStore;
}

const SESSION_KEY = 'superdb.session';

export function createSuperDB(opts: SuperDBOptions) {
  const authUrl = opts.authUrl.replace(/\/+$/, '');
  const apiUrl = (opts.apiUrl ?? (authUrl.includes('://auth.') ? authUrl.replace('://auth.', '://api.') : authUrl)).replace(/\/+$/, '');
  const profile = `proj_${opts.project}`;
  const store: SessionStore = opts.storage ?? globalThis.localStorage;
  let session: SuperDBSession | null = null;

  async function load(): Promise<SuperDBSession | null> {
    if (session) return session;
    const raw = await store.getItem(SESSION_KEY);
    if (raw) try { session = JSON.parse(raw); } catch { /* ignore */ }
    return session;
  }
  async function persist(s: SuperDBSession | null) {
    session = s;
    if (s) await store.setItem(SESSION_KEY, JSON.stringify(s));
    else await store.removeItem(SESSION_KEY);
  }

  async function authFetch(path: string, body: unknown) {
    const r = await fetch(`${authUrl}/auth/v1${path}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-SuperDB-Project': opts.project,
        apikey: opts.anonKey,
      },
      body: JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j?.error?.message ?? j?.error ?? `auth ${r.status}`);
    return j;
  }

  const auth = {
    async signUp(input: { email: string; password: string; full_name?: string }) {
      const j = await authFetch('/signup', input);
      if (j.access_token) await persist(j as SuperDBSession);
      return j;
    },
    async signInWithPassword(input: { email: string; password: string }) {
      const j = await authFetch('/signin', input);
      await persist(j as SuperDBSession);
      return j;
    },
    async signOut() {
      await persist(null);
    },
    async getSession() {
      return load();
    },
  };

  // ---- builder PostgREST minimal (select/insert/update/delete + filtros) ----
  function from(table: string) {
    const params = new URLSearchParams();
    let method = 'GET';
    let payload: unknown;

    const builder = {
      select(cols = '*') { params.set('select', cols); return builder; },
      insert(rows: unknown) { method = 'POST'; payload = rows; return builder; },
      update(values: unknown) { method = 'PATCH'; payload = values; return builder; },
      delete() { method = 'DELETE'; return builder; },
      eq(c: string, v: unknown) { params.append(c, `eq.${v}`); return builder; },
      gt(c: string, v: unknown) { params.append(c, `gt.${v}`); return builder; },
      lt(c: string, v: unknown) { params.append(c, `lt.${v}`); return builder; },
      like(c: string, v: string) { params.append(c, `like.${v}`); return builder; },
      order(c: string, asc = true) { params.append('order', `${c}.${asc ? 'asc' : 'desc'}`); return builder; },
      limit(n: number) { params.set('limit', String(n)); return builder; },
      async then(res: (r: { data: unknown; error: { message: string } | null }) => unknown) {
        const s = await load();
        const token = s?.data_plane_token ?? opts.anonKey; // logado usa a sessão; senão anon
        const profHeader = method === 'GET' ? 'Accept-Profile' : 'Content-Profile';
        const headers: Record<string, string> = {
          Authorization: `Bearer ${token}`,
          apikey: opts.anonKey,
          [profHeader]: profile,
          Accept: 'application/json',
        };
        if (payload !== undefined) {
          headers['Content-Type'] = 'application/json';
          headers['Prefer'] = 'return=representation';
        }
        const qs = params.toString();
        const r = await fetch(`${apiUrl}/${table}${qs ? `?${qs}` : ''}`, {
          method,
          headers,
          body: payload !== undefined ? JSON.stringify(payload) : undefined,
        });
        const text = await r.text();
        const data = text ? JSON.parse(text) : null;
        if (!r.ok) return res({ data: null, error: { message: data?.message ?? `HTTP ${r.status}` } });
        return res({ data, error: null });
      },
    };
    return builder;
  }

  return { auth, from };
}
