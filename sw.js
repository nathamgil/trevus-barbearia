// Trevus — service worker mínimo: permite instalar o site como app.
// Não guarda cópia de nada (sempre busca a versão nova na internet),
// para a agenda e os preços nunca ficarem desatualizados.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function () { /* rede direto */ });
