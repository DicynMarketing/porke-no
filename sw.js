var C='porkeno-v46';
self.addEventListener('install',function(e){e.waitUntil(caches.open(C).then(function(c){return c.addAll(['./','index.html','manifest.json','icon-192.png','icon-512.png'].map(function(u){return new Request(u,{cache:'reload'})}))}))});
self.addEventListener('message',function(e){if(e.data=='skip')self.skipWaiting()});
self.addEventListener('activate',function(e){e.waitUntil(caches.keys().then(function(k){return Promise.all(k.filter(function(x){return x!=C}).map(function(x){return caches.delete(x)}))}).then(function(){return self.clients.claim()}))});
self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(e.request.method!='GET'||u.origin!=location.origin||/version\.json$/.test(u.pathname))return;e.respondWith(caches.match(e.request).then(function(m){return m||fetch(e.request).then(function(r){if(r.ok){var cp=r.clone();caches.open(C).then(function(c){c.put(e.request,cp)})}return r})}).catch(function(){return caches.match('index.html')}))});
function isEq(u){return /[?&]app=(admin|driver|staff|equipo)/.test(u)}
// Aviso push del servidor. Si esa misma app está abierta en pantalla, ella ya lo muestra por dentro.
self.addEventListener('push',function(e){var d={};try{d=e.data?e.data.json():{}}catch(x){d={body:e.data?e.data.text():''}}var eq=d.app=='equipo';
 e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(function(cs){if(d.tag!='version'&&cs.some(function(c){return c.visibilityState=='visible'&&isEq(c.url)==eq}))return;
  return self.registration.showNotification(d.title||'Porké No?',{body:d.body||'',icon:eq?'icon-admin-192.png':'icon-192.png',badge:'icon-192.png',tag:d.tag||'pk',renotify:true,vibrate:[80,40,80],data:{url:d.url||'./'}})}))});
self.addEventListener('notificationclick',function(e){e.notification.close();var u=new URL((e.notification.data&&e.notification.data.url)||'./',self.registration.scope).href,eq=isEq(u);
 e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(function(cs){var c=cs.filter(function(x){return isEq(x.url)==eq})[0];if(c){c.postMessage({pk:'open'});return c.focus()}return self.clients.openWindow(u)}))});
