// Recebe o aviso do Mercado Pago quando um pagamento muda (principalmente o Pix caindo).
//
// O aviso só diz "o pagamento X mudou". A função consulta o pagamento direto no Mercado Pago,
// com a conta da própria barbearia, e só confirma o horário se ele estiver mesmo aprovado.
// Assim um aviso falso não confirma nada.
//
// Deixe "Verify JWT" DESLIGADO nesta função: o Mercado Pago chama sem login.

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

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const b = url.searchParams.get('b') || '';
  const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};
  const tipo = String(body.type || body.topic || url.searchParams.get('type') || url.searchParams.get('topic') || '');
  const pid = String((body.data && body.data.id) || url.searchParams.get('data.id') || (tipo === 'payment' ? url.searchParams.get('id') || '' : ''));

  // Avisos que não são de pagamento (ou testes) só recebem "ok".
  if (!/^[0-9a-f-]{36}$/i.test(b) || tipo.indexOf('payment') < 0 || !/^\d+$/.test(pid)) return new Response('ok');

  try {
    const conta = await rpc('mp_conta', { p_b: b });
    if (!conta || !conta.access_token) return new Response('ok');
    const r = await fetch('https://api.mercadopago.com/v1/payments/' + pid, { headers: { Authorization: 'Bearer ' + conta.access_token } });
    if (r.status === 404) return new Response('ok');
    if (!r.ok) return new Response('tente de novo', { status: 500 }); // o Mercado Pago reenvia depois
    const p = await r.json();
    if (p.status === 'approved' && p.external_reference) {
      const res = await rpc('mp_confirmar', {
        p_b: b, p_id: String(p.external_reference), p_valor: Number(p.transaction_amount),
        p_pagamento: String(p.id), p_metodo: p.payment_method_id || 'mp',
      });
      console.log('pagamento', p.id, res);
    }
    return new Response('ok');
  } catch (e) {
    console.error('mp-webhook', e);
    return new Response('tente de novo', { status: 500 });
  }
});
