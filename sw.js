var C='porkeno-v50';
self.addEventListener('install',function(e){e.waitUntil(caches.open(C).then(function(c){return c.addAll(['./','index.html','manifest.json','manifest-admin.json','icons/icono-notificacion-192.png','icons/icono-notificacion-512.png','icons/insignia-barra-96.png','icons/notificacion-grande.jpg','icons/notif/recibido.png','icons/notif/preparando.png','icons/notif/en_camino.png','icons/notif/listo.png','icons/notif/entregado.png','icons/notif/cancelado.png','icons/notif/recibido-icono.png','icons/notif/preparando-icono.png','icons/notif/en_camino-icono.png','icons/icono-192.png','icons/icono-512.png','icons/equipo-192.png'].map(function(u){return new Request(u,{cache:'reload'})}))}))});
self.addEventListener('message',function(e){if(e.data=='skip')self.skipWaiting()});
self.addEventListener('activate',function(e){e.waitUntil(caches.keys().then(function(k){return Promise.all(k.filter(function(x){return x!=C}).map(function(x){return caches.delete(x)}))}).then(function(){return self.clients.claim()}))});
self.addEventListener('fetch',function(e){var u=new URL(e.request.url);if(e.request.method!='GET'||u.origin!=location.origin||/version\.json$/.test(u.pathname))return;e.respondWith(caches.match(e.request).then(function(m){return m||fetch(e.request).then(function(r){if(r.ok){var cp=r.clone();caches.open(C).then(function(c){c.put(e.request,cp)})}return r})}).catch(function(){return caches.match('index.html')}))});
function isEq(u){return /[?&]app=(admin|driver|staff|equipo)/.test(u)}
// Aviso push del servidor: siempre en la bandeja del sistema (emergente y luego minimizado).
// Logo a color como icono, cerdito grande al expandir y silueta blanca en la barra de estado.
var NOTI={icon:'/icons/icono-notificacion-192.png',image:'/icons/notificacion-grande.jpg',badge:'/icons/insignia-barra-96.png',vibrate:[200,100,200],renotify:true,requireInteraction:false,silent:false};
// Cerdito de cada etapa: lo decide el teléfono por el título, aunque el servidor no mande imagen.
var ETAPAS=[[/cancelad/i,'cancelado'],[/entregado/i,'entregado'],[/listo/i,'listo'],[/camino|nueva entrega/i,'en_camino'],[/preparando/i,'preparando'],[/recibido|verific|pago|pedido nuevo/i,'recibido']];
function etapa(d){if(/^\/icons\/notif\/([a-z_]+)\.png$/.test(d.image||''))return RegExp.$1;var t=(d.title||'')+' '+(d.tag||'');for(var i=0;i<ETAPAS.length;i++)if(ETAPAS[i][0].test(t))return ETAPAS[i][1];return ''}
self.addEventListener('push',function(e){var d={};try{d=e.data?e.data.json():{}}catch(x){d={body:e.data?e.data.text():''}}
 var et=etapa(d),tag=d.tag||'porkeno';if(et&&/^pedido-[^-]+$/.test(tag))tag+='-'+et;  // etiqueta distinta por etapa = ventana emergente en cada cambio
 var o=Object.assign({},NOTI,{body:d.body||'',tag:tag,data:{url:d.url||'./'},timestamp:Date.now()});if(et&&d.tag!='version'){o.image='/icons/notif/'+et+'.png';if(/^(recibido|preparando|en_camino)$/.test(et))o.icon='/icons/notif/'+et+'-icono.png'}  // icon = lo que se ve en la ventana emergente; image = al expandir
 e.waitUntil(self.registration.showNotification(d.title||'Porké No?',o))});
self.addEventListener('notificationclick',function(e){e.notification.close();var u=new URL((e.notification.data&&e.notification.data.url)||'./',self.registration.scope).href,eq=isEq(u);
 e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(function(cs){var c=cs.filter(function(x){return isEq(x.url)==eq})[0];if(c){c.postMessage({pk:'open'});return c.focus()}return self.clients.openWindow(u)}))});
