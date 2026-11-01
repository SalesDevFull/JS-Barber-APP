// Service worker do app: mostra os avisos que chegam com o app fechado.
// Não guarda nada em cache, então o app sempre abre a versão mais nova.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (er) { d = { corpo: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'Agendamento novo', {
    body: d.corpo || 'Abra o app pra ver.',
    icon: 'icon-192.png?v=3',
    badge: 'favicon-32.png?v=3',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    vibrate: [120, 80, 120],
    data: { url: d.url || '/#agenda' }
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const alvo = new URL((e.notification.data && e.notification.data.url) || '/#agenda', self.location.origin).href;
  e.waitUntil((async () => {
    const abas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of abas) {
      if (new URL(c.url).origin === self.location.origin) { await c.focus(); try { await c.navigate(alvo); } catch (er) { /* ok */ } return; }
    }
    await self.clients.openWindow(alvo);
  })());
});
