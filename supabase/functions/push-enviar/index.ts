// Manda o aviso pro celular do dono e do barbeiro (Web Push), mesmo com o app fechado.
//
// O banco chama esta função quando chega agendamento pelo link ou quando o sinal é pago online.
// Ela pede ao banco o texto do aviso (que só sai uma vez por evento) e envia pra cada celular inscrito.
// Não precisa de segredo extra: as chaves do aviso (VAPID) ficam numa tabela que só o servidor lê.
//
// Deixe "Verify JWT" DESLIGADO nesta função: quem chama é o próprio banco.

const SB_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

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

// ---------- Web Push (RFC 8291 + VAPID RFC 8292), só com WebCrypto ----------

const enc = new TextEncoder();
const b64u = (buf: ArrayBuffer | Uint8Array) => {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const deb64u = (s: string) => {
  const t = s.replace(/-/g, '+').replace(/_/g, '/'); const p = t + '='.repeat((4 - (t.length % 4)) % 4);
  const bin = atob(p); const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};
const junta = (...partes: Uint8Array[]) => {
  const out = new Uint8Array(partes.reduce((n, p) => n + p.length, 0)); let o = 0;
  for (const p of partes) { out.set(p, o); o += p.length; }
  return out;
};
async function hmac(chave: Uint8Array, dados: Uint8Array) {
  const k = await crypto.subtle.importKey('raw', chave, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, dados));
}

// Assinatura VAPID: prova pro serviço de push que o aviso vem deste app.
async function vapid(endpoint: string, publica: string, privada: string, contato: string) {
  const pub = deb64u(publica);
  const jwk = { kty: 'EC', crv: 'P-256', x: b64u(pub.slice(1, 33)), y: b64u(pub.slice(33, 65)), d: privada, ext: true };
  const k = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const cab = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const corpo = b64u(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: contato })));
  const ass = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, k, enc.encode(cab + '.' + corpo));
  return 'vapid t=' + cab + '.' + corpo + '.' + b64u(ass) + ', k=' + publica;
}

// Criptografa a mensagem pra só aquele celular conseguir ler (aes128gcm).
export async function cifrar(texto: string, p256dh: string, authSecret: string) {
  const uaPub = deb64u(p256dh); const auth = deb64u(authSecret);
  const par = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', par.publicKey));
  const ua = await crypto.subtle.importKey('raw', uaPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const segredo = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: ua }, par.privateKey, 256));
  const prkKey = await hmac(auth, segredo);
  const ikm = await hmac(prkKey, junta(enc.encode('WebPush: info\0'), uaPub, asPub, new Uint8Array([1])));
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, junta(enc.encode('Content-Encoding: aes128gcm\0'), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, junta(enc.encode('Content-Encoding: nonce\0'), new Uint8Array([1])))).slice(0, 12);
  const k = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cifra = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, k, junta(enc.encode(texto), new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]); // 4096
  return junta(salt, rs, new Uint8Array([asPub.length]), asPub, cifra);
}

type Inscricao = { endpoint: string; p256dh: string; auth: string };
type Vapid = { publica: string; privada: string; contato: string };

async function enviar(s: Inscricao, msg: string, v: Vapid) {
  const corpo = await cifrar(msg, s.p256dh, s.auth);
  const r = await fetch(s.endpoint, {
    method: 'POST',
    headers: {
      Authorization: await vapid(s.endpoint, v.publica, v.privada, v.contato),
      'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '86400', Urgency: 'high',
    },
    body: corpo,
  });
  return r.status;
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('ok');
  try {
    const body = await req.json().catch(() => ({}));
    const b = String(body.b || ''); const id = String(body.id || ''); const evento = String(body.evento || '');
    if (!/^[0-9a-f-]{36}$/i.test(b) || id.length < 2 || !/^(novo|pago)$/.test(evento)) return new Response('ok');
    const a = await rpc('push_pendente', { p_b: b, p_id: id, p_evento: evento });
    if (!a || !a.vapid || !a.vapid.publica || !a.vapid.privada || !(a.inscricoes || []).length) return new Response('ok');
    const msg = JSON.stringify({ titulo: a.titulo, corpo: a.corpo, tag: a.tag, url: a.url });
    const mortos: string[] = [];
    await Promise.all(a.inscricoes.map(async (s: Inscricao) => {
      try {
        const st = await enviar(s, msg, a.vapid);
        if (st === 404 || st === 410) mortos.push(s.endpoint); // celular desinstalou ou desligou o aviso
        else if (st >= 400) console.error('push', st, new URL(s.endpoint).host);
      } catch (e) { console.error('push', e); }
    }));
    if (mortos.length) await rpc('push_remover', { p_endpoints: mortos });
    return new Response('ok');
  } catch (e) {
    console.error('push-enviar', e);
    return new Response('ok');
  }
});
