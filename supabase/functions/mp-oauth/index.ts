// Conecta a conta Mercado Pago de cada barbearia (OAuth).
//
// 1) O painel chama esta função (POST) com o login do dono e recebe o link do Mercado Pago.
// 2) O dono autoriza lá, e o Mercado Pago volta aqui (GET ?code=...&state=...).
// 3) A função troca o código pelas chaves da conta, guarda no banco e manda o dono de volta pro painel.
//
// Segredos (Supabase → Edge Functions → Secrets): MP_CLIENT_ID, MP_CLIENT_SECRET, APP_URL.
// Deixe "Verify JWT" DESLIGADO nesta função: a volta do Mercado Pago chega sem login.

const SB_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const CLIENT_ID = Deno.env.get('MP_CLIENT_ID') ?? '';
const CLIENT_SECRET = Deno.env.get('MP_CLIENT_SECRET') ?? '';
const APP_URL = (Deno.env.get('APP_URL') ?? '').replace(/\/+$/, '');
const REDIRECT = SB_URL.replace(/\/+$/, '') + '/functions/v1/mp-oauth';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const voltar = (q: string) => Response.redirect((APP_URL || 'https://www.mercadopago.com.br') + '/?' + q + '#gestao', 302);

async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(SB_URL + '/rest/v1/rpc/' + fn, {
    method: 'POST',
    headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  const d = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error((d && d.message) || t || 'Erro no banco');
  return d;
}

async function usuario(auth: string | null) {
  if (!auth) return null;
  const r = await fetch(SB_URL + '/auth/v1/user', { headers: { apikey: SERVICE, Authorization: auth } });
  if (!r.ok) return null;
  const u = await r.json();
  return u && u.id ? String(u.id) : null;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (!SB_URL || !SERVICE || !CLIENT_ID || !CLIENT_SECRET) {
    return req.method === 'GET' ? voltar('mp=erro&motivo=config') : json({ ok: false, erro: 'Mercado Pago ainda não configurado no servidor.' });
  }
  const url = new URL(req.url);

  // Passo 1: o painel pede o link pra conectar.
  if (req.method === 'POST') {
    try {
      const user = await usuario(req.headers.get('Authorization'));
      if (!user) return json({ ok: false, erro: 'Entre de novo no app e tente outra vez.' });
      const body = await req.json().catch(() => ({}));
      const b = String(body.barbearia_id || '');
      if (!/^[0-9a-f-]{36}$/i.test(b)) return json({ ok: false, erro: 'Barbearia inválida.' });
      const estado = await rpc('mp_criar_estado', { p_b: b, p_user: user });
      const link = 'https://auth.mercadopago.com/authorization?client_id=' + encodeURIComponent(CLIENT_ID) +
        '&response_type=code&platform_id=mp&state=' + encodeURIComponent(estado) +
        '&redirect_uri=' + encodeURIComponent(REDIRECT);
      return json({ ok: true, url: link });
    } catch (e) {
      return json({ ok: false, erro: e instanceof Error ? e.message : 'Não deu pra começar a conexão.' });
    }
  }

  // Passo 2: o Mercado Pago volta com o código.
  const code = url.searchParams.get('code');
  const estado = url.searchParams.get('state');
  if (!code || !estado) return voltar('mp=erro&motivo=cancelado');
  try {
    const b = await rpc('mp_usar_estado', { p_estado: estado });
    if (!b) return voltar('mp=erro&motivo=expirou');
    const r = await fetch('https://api.mercadopago.com/oauth/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, grant_type: 'authorization_code', code, redirect_uri: REDIRECT }),
    });
    const t = await r.json().catch(() => ({}));
    if (!r.ok || !t.access_token) {
      console.error('oauth/token', r.status, JSON.stringify(t));
      return voltar('mp=erro&motivo=token');
    }
    const expira = new Date(Date.now() + (Number(t.expires_in) || 15552000) * 1000).toISOString();
    await rpc('mp_salvar_conta', {
      p_b: b, p_user: t.user_id != null ? String(t.user_id) : null, p_access: t.access_token,
      p_refresh: t.refresh_token || null, p_public: t.public_key || null, p_expira: expira,
      p_live: typeof t.live_mode === 'boolean' ? t.live_mode : null,
    });
    return voltar('mp=ok');
  } catch (e) {
    console.error('mp-oauth', e);
    return voltar('mp=erro&motivo=servidor');
  }
});
