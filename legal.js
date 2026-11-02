// Contato de suporte nas páginas de termos e privacidade.
// Para mostrar um e-mail ou WhatsApp de suporte, preencha "suporte" no config.js (ex.: suporte: 'suporte@degrade.app.br').
(function () {
  function aplicar() {
    var c = (window.APP_CONFIG || {}).suporte;
    if (!c) return;
    var link = /@/.test(c) ? 'mailto:' + c : 'https://wa.me/' + String(c).replace(/\D/g, '');
    document.querySelectorAll('[data-contato]').forEach(function (el) {
      el.innerHTML = 'Contato: <a href="' + link + '">' + c.replace(/[<>&"]/g, '') + '</a>.';
    });
  }
  var s = document.createElement('script'); s.src = 'config.js'; s.onload = aplicar; s.onerror = function () {}; document.head.appendChild(s);
})();
