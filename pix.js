// Gera o código Pix "copia e cola" (BR Code estático, padrão do Banco Central) com valor.
// Usado na página de agendamento (sinal) e no painel (teste da chave).
(function () {
  'use strict';
  function semAcento(s) { return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^\x20-\x7E]/g, ''); }
  function tlv(id, v) { v = String(v); return id + String(v.length).padStart(2, '0') + v; }
  function crc16(str) {
    let crc = 0xFFFF;
    for (let i = 0; i < str.length; i++) {
      crc ^= str.charCodeAt(i) << 8;
      for (let j = 0; j < 8; j++) crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
    return crc.toString(16).toUpperCase().padStart(4, '0');
  }
  // tipo: cpf | cnpj | celular | email | aleatoria
  function normalizarChave(tipo, chave) {
    const c = String(chave || '').trim();
    if (tipo === 'cpf' || tipo === 'cnpj') return c.replace(/\D/g, '');
    if (tipo === 'celular') { let d = c.replace(/\D/g, ''); if (d.indexOf('55') !== 0 || d.length <= 11) d = '55' + d; return '+' + d; }
    if (tipo === 'email') return c.toLowerCase();
    return c.toLowerCase();
  }
  function validarChave(tipo, chave) {
    const n = normalizarChave(tipo, chave);
    if (tipo === 'cpf') return n.length === 11;
    if (tipo === 'cnpj') return n.length === 14;
    if (tipo === 'celular') return /^\+55\d{10,11}$/.test(n);
    if (tipo === 'email') return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(n) && n.length <= 77;
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(n);
  }
  function brcode(o) {
    const chave = normalizarChave(o.tipo, o.chave);
    const nome = semAcento(o.nome).toUpperCase().slice(0, 25) || 'RECEBEDOR';
    const cidade = semAcento(o.cidade).toUpperCase().slice(0, 15) || 'BRASIL';
    const txid = (String(o.txid || '***').replace(/[^A-Za-z0-9]/g, '').slice(0, 25)) || '***';
    let p = tlv('00', '01') + tlv('26', tlv('00', 'br.gov.bcb.pix') + tlv('01', chave));
    p += tlv('52', '0000') + tlv('53', '986');
    if (o.valor && Number(o.valor) > 0) p += tlv('54', Number(o.valor).toFixed(2));
    p += tlv('58', 'BR') + tlv('59', nome) + tlv('60', cidade) + tlv('62', tlv('05', txid)) + '6304';
    return p + crc16(p);
  }
  window.Pix = { brcode: brcode, normalizarChave: normalizarChave, validarChave: validarChave, crc16: crc16 };
})();
