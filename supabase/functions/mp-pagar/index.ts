// Cobra o sinal de uma reserva na conta Mercado Pago da barbearia.
//
// A página de agendamento manda: { slug, id, metodo: 'pix' | 'cartao', email, cartao? }.
// O valor SEMPRE vem do banco (nunca do navegador), e o dinheiro cai na conta da barbearia.
// Cartão aprovado confirma o horário na hora. Pix confirma quando o Mercado Pago avisar (mp-webhook).
//
// Segredos: MP_CLIENT_ID e MP_CLIENT_SECRET (pra renovar a conexão quando estiver perto de vencer).

const SB_URL = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '');
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const CLIENT_ID = Deno.env.get('MP_CLIENT_ID') ?? '';
const CLIENT_SECRET = Deno.env.get('MP_CLIENT_SECRET') ?? '';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { ...CORS, 'Content-Type': 'application/json' } });
const falha = (erro: string) => json({ ok: false, erro });

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

// Renova a conexão se faltar menos de 15 dias pra vencer.
async function tokenValido(b: string, conta: { access_token: string; refresh_token?: string; expira_em?: string }) {
  const vence = conta.expira_em ? new Date(conta.expira_em).getTime() : Infinity;
  if (!conta.refresh_token || !CLIENT_ID || !CLIENT_SECRET || vence - Date.now() > 15 * 864e5) return conta.access_token;
  const r = await fetch('https://api.mercadopago.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, grant_type: 'refresh_token', refresh_token: conta.refresh_token }),
  });
  const t = await r.json().catch(() => ({}));
  if (!r.ok || !t.access_token) { console.error('refresh', r.status, JSON.stringify(t)); return conta.access_token; }
  await rpc('mp_salvar_conta', {
    p_b: b, p_user: t.user_id != null ? String(t.user_id) : null, p_access: t.access_token, p_refresh: t.refresh_token || null,
    p_public: t.public_key || null, p_expira: new Date(Date.now() + (Number(t.expires_in) || 15552000) * 1000).toISOString(),
    p_live: typeof t.live_mode === 'boolean' ? t.live_mode : null,
  });
  return t.access_token as string;
}

// Data no formato que o Mercado Pago pede, no horário de Brasília.
function dataMP(ms: number) {
  return new Date(ms - 3 * 3600e3).toISOString().replace('Z', '-03:00');
}

const RECUSA: Record<string, string> = {
  cc_rejected_bad_filled_card_number: 'Confira o número do cartão.',
  cc_rejected_bad_filled_date: 'Confira a validade do cartão.',
  cc_rejected_bad_filled_security_code: 'Confira o código de segurança (CVV).',
  cc_rejected_bad_filled_other: 'Confira os dados do cartão.',
  cc_rejected_insufficient_amount: 'Cartão sem limite suficiente. Tente outro cartão ou o Pix.',
  cc_rejected_call_for_authorize: 'O banco pediu pra você autorizar esse pagamento. Ligue pro banco ou use outro cartão.',
  cc_rejected_card_disabled: 'Cartão bloqueado. Fale com o banco ou use outro cartão.',
  cc_rejected_duplicated_payment: 'Esse pagamento já foi feito. Confira seu extrato.',
  cc_rejected_high_risk: 'O pagamento foi recusado por segurança. Tente outro cartão ou o Pix.',
  cc_rejected_max_attempts: 'Muitas tentativas. Use outro cartão ou o Pix.',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return falha('Use POST.');
  try {
    const body = await req.json().catch(() => ({}));
    const slug = String(body.slug || ''); const id = String(body.id || '');
    const metodo = body.metodo === 'cartao' ? 'cartao' : 'pix';
    const email = String(body.email || '').trim().toLowerCase();
    if (!slug || id.length < 20) return falha('Reserva inválida.');

    const c = await rpc('mp_cobranca', { p_slug: slug, p_id: id });
    if (!c) return falha('Reserva não encontrada.');
    if (c.status !== 'aguardando_sinal') {
      return c.status === 'agendado' ? json({ ok: true, status: 'approved', confirmado: true }) : falha('Essa reserva não está mais esperando pagamento.');
    }
    if (c.expira && new Date(c.expira).getTime() <= Date.now()) return falha('O prazo da reserva acabou. Escolha o horário de novo.');
    if (!c.conta || !c.online) return falha('Esta barbearia não está recebendo pagamento online agora.');
    if (metodo === 'cartao' && !c.online.cartao) return falha('Esta barbearia não aceita cartão online.');
    if (metodo === 'pix' && !c.online.pix) return falha('Esta barbearia não aceita Pix online.');

    const valor = Number(c.valor);
    if (!(valor > 0)) return falha('Valor do sinal inválido.');
    const token = await tokenValido(c.b, c.conta);
    const descricao = ('Sinal · ' + (c.servico || 'Horário') + ' · ' + c.barbearia).slice(0, 120);
    const aviso = SB_URL + '/functions/v1/mp-webhook?b=' + c.b;

    if (metodo === 'pix') {
      // Já gerou um Pix que ainda vale? Devolve o mesmo, sem criar outro.
      const ant = c.mp && c.mp.pix;
      if (ant && ant.qr && ant.vence && new Date(ant.vence).getTime() > Date.now() + 60e3) {
        return json({ ok: true, status: 'pending', qr: ant.qr, qr64: ant.qr64 || null, vence: ant.vence });
      }
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return falha('Informe um e-mail válido pro Pix.');
      // O Pix do Mercado Pago precisa valer pelo menos 30 minutos. A reserva estica junto.
      const vence = Math.max(new Date(c.expira).getTime(), Date.now() + 31 * 60e3);
      const r = await fetch('https://api.mercadopago.com/v1/payments', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-Idempotency-Key': 'pix-' + id + '-' + Math.floor(vence / 300e3) },
        body: JSON.stringify({
          transaction_amount: valor, description: descricao, payment_method_id: 'pix',
          payer: { email }, external_reference: id, notification_url: aviso,
          date_of_expiration: dataMP(vence), metadata: { barbearia_id: c.b, agendamento_id: id },
        }),
      });
      const p = await r.json().catch(() => ({}));
      const td = p && p.point_of_interaction && p.point_of_interaction.transaction_data;
      if (!r.ok || !td || !td.qr_code) { console.error('pix', r.status, JSON.stringify(p)); return falha('Não deu pra gerar o Pix agora. Tente de novo em instantes.'); }
      const venceIso = new Date(vence).toISOString();
      await rpc('mp_registrar', { p_b: c.b, p_id: id, p_mp: { pix: { id: String(p.id), qr: td.qr_code, qr64: td.qr_code_base64 || null, vence: venceIso } }, p_expira: venceIso });
      return json({ ok: true, status: 'pending', qr: td.qr_code, qr64: td.qr_code_base64 || null, vence: venceIso });
    }

    // Cartão de crédito (os dados do cartão vêm como token do formulário do Mercado Pago).
    const k = body.cartao || {};
    if (!k.token || !k.payment_method_id) return falha('Preencha os dados do cartão.');
    const parcelas = Math.max(1, Math.min(Number(c.online.parcelas) || 1, Number(k.installments) || 1));
    const pagador = k.payer || {};
    const r = await fetch('https://api.mercadopago.com/v1/payments', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-Idempotency-Key': crypto.randomUUID() },
      body: JSON.stringify({
        transaction_amount: valor, token: k.token, description: descricao, installments: parcelas,
        payment_method_id: k.payment_method_id, issuer_id: k.issuer_id || undefined,
        payer: { email: pagador.email || email, identification: pagador.identification || undefined },
        external_reference: id, notification_url: aviso, binary_mode: true,
        metadata: { barbearia_id: c.b, agendamento_id: id },
      }),
    });
    const p = await r.json().catch(() => ({}));
    if (!r.ok) { console.error('cartao', r.status, JSON.stringify(p)); return falha('Não deu pra pagar com esse cartão. Confira os dados ou use o Pix.'); }
    if (p.status === 'approved') {
      const res = await rpc('mp_confirmar', { p_b: c.b, p_id: id, p_valor: Number(p.transaction_amount), p_pagamento: String(p.id), p_metodo: p.payment_method_id || 'cartao' });
      if (res === 'devolver') return falha('O pagamento passou, mas o horário não estava mais livre. A barbearia vai devolver o valor. Fale com ela pelo WhatsApp.');
      return json({ ok: true, status: 'approved', confirmado: true });
    }
    return falha(RECUSA[p.status_detail] || 'Pagamento recusado. Tente outro cartão ou o Pix.');
  } catch (e) {
    console.error('mp-pagar', e);
    return falha('Não deu pra falar com o Mercado Pago agora. Tente de novo.');
  }
});
