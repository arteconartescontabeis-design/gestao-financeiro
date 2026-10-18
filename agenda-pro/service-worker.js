// Agenda Pro — Service Worker (acompanha a versão do app: APP_VERSAO no app.html)
// Suporta: cache offline + notificações com app fechado

const CACHE_NAME = 'agenda-pro-v2.8.1';   // trocar a cada versão nova
const SUPA_HOSTS = ['hwvguqfprbjfqtxkmgiz.supabase.co', 'vuwgxndahrzinfdlapxz.supabase.co'];

// Lembretes agendados: { key: { disparo, titulo, corpo, agId } }
let _lembretes = {};
let _timerHandle = null;

// ── Instalar ──────────────────────────────────────────────
self.addEventListener('install', e => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// ── Cache offline ─────────────────────────────────────────
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // Não interceptar Supabase, outros sites (fontes, bibliotecas) nem envios
  if (SUPA_HOSTS.some(h => url.hostname.includes(h))) return;
  if (url.origin !== self.location.origin || e.request.method !== 'GET') return;
  // version.json: sempre da internet (é o que avisa que saiu versão nova)
  if (url.pathname.endsWith('version.json')) return;
  // Áudios: direto da internet, sem guardar (são grandes e o player pede trechos; os do estudo vêm do Supabase desde a v2.6.0)
  if (url.pathname.endsWith('.mp3')) return;

  // Páginas: primeiro a internet (versão mais nova); a cópia guardada só sem conexão
  const ehPagina = e.request.mode === 'navigate' || url.pathname.endsWith('.html') || url.pathname.endsWith('/');
  if (ehPagina) {
    e.respondWith(
      fetch(e.request).then(res => {
        if (res && res.status === 200) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone));
        }
        return res;
      }).catch(() => caches.match(e.request))
    );
    return;
  }

  // Ícones e demais arquivos do próprio app: cópia guardada primeiro
  {
    e.respondWith(
      caches.match(e.request).then(cached => {
        if (cached) return cached;
        return fetch(e.request).then(res => {
          if (res && res.status === 200 && res.type !== 'opaque') {
            const clone = res.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone));
          }
          return res;
        }).catch(() => cached);
      })
    );
  }
});

// ── Receber mensagens do app ──────────────────────────────
self.addEventListener('message', e => {
  if (!e.data) return;

  if (e.data.type === 'AGENDAR_LEMBRETES') {
    _registrarLembretes(e.data.lembretes || []);
  }

  if (e.data.type === 'INIT_PUSH') {
    // App abriu — limpar timers (app vai gerenciar enquanto aberto)
    _limparTimers();
  }
});

function _registrarLembretes(lista) {
  _limparTimers();
  _lembretes = {};

  const agora = Date.now();
  lista.forEach(l => {
    const delay = l.disparo - agora;
    if (delay > 0 && delay < 24 * 60 * 60 * 1000) {
      _lembretes[l.key] = l;
    }
  });

  _agendarProximo();
}

function _agendarProximo() {
  const agora = Date.now();
  const pendentes = Object.values(_lembretes)
    .filter(l => l.disparo > agora)
    .sort((a, b) => a.disparo - b.disparo);

  if (pendentes.length === 0) return;

  const proximo = pendentes[0];
  const delay = proximo.disparo - agora;

  _timerHandle = setTimeout(async () => {
    // Verificar se há cliente aberto — se sim, deixa o app tratar
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const appAberto = clients.some(c => c.visibilityState === 'visible');

    if (!appAberto) {
      // App fechado ou em background — disparar notificação nativa
      try {
        await self.registration.showNotification(proximo.titulo, {
          body: proximo.corpo,
          icon: '/gestao-financeiro/agenda-pro/icons/icon-192.png',
          badge: '/gestao-financeiro/agenda-pro/icons/icon-192.png',
          tag: proximo.key,
          requireInteraction: true,
          vibrate: [200, 100, 200],
          data: { agId: proximo.agId },
          actions: [
            { action: 'concluir',   title: '✓ Concluído' },
            { action: 'reagendar',  title: '📅 Reagendar' },
          ]
        });
      } catch(err) {
        console.warn('[SW] showNotification falhou:', err);
      }
    }

    // Remover da fila e agendar próximo
    delete _lembretes[proximo.key];
    _agendarProximo();
  }, delay);
}

function _limparTimers() {
  if (_timerHandle) {
    clearTimeout(_timerHandle);
    _timerHandle = null;
  }
}

// ── Clique na notificação ─────────────────────────────────
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const agId = e.notification.data?.agId;
  const action = e.action;

  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clients => {
      // Tentar focar janela existente
      const existing = clients.find(c => c.url.includes('/gestao-financeiro/agenda-pro/'));
      const hash = action === 'concluir'  ? `#concluir-${agId}`
                 : action === 'reagendar' ? `#reagendar-${agId}`
                 : agId ? `#ag-${agId}` : '';

      if (existing) {
        existing.focus();
        if (hash) existing.navigate(existing.url.split('#')[0] + hash);
        return;
      }

      // Abrir nova janela
      return self.clients.openWindow('/gestao-financeiro/agenda-pro/app.html' + hash);
    })
  );
});
