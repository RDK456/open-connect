// Usage: node server.js [folder ...]   (default: your home folder)
// Phones/PCs open http://<this-pc-ip>:8080 in a browser, request access, you approve here.
const http = require('http'), fs = require('fs'), path = require('path'), os = require('os'), crypto = require('crypto');
const rl = require('readline').createInterface({ input: process.stdin, output: process.stdout });
const PORT = +process.env.PORT || 8080;

const roots = {};
for (const d of process.argv.length > 2 ? process.argv.slice(2) : [os.homedir()]) {
  const r = path.resolve(d); let n = path.basename(r) || r.replace(/[:\\]/g, '');
  while (roots[n]) n += '_';
  roots[n] = r;
}

// virtual path "name/sub/dir" -> real path; false if unknown or escapes the root
// ponytail: symlinks inside a shared folder can still point outside it
function real(p) {
  const [n, ...rest] = p.split('/').filter(Boolean);
  if (!roots[n]) return false;
  const f = path.resolve(roots[n], ...rest), rel = path.relative(roots[n], f);
  return rel === '..' || rel.startsWith('..' + path.sep) || path.isAbsolute(rel) ? false : f;
}

// ponytail: sessions in memory only, restart revokes everyone
const sessions = new Set(), pending = {};
let queue = Promise.resolve();
const ask = id => { queue = queue.then(() => new Promise(done => {
  const s = pending[id];
  rl.question(`\n>> ${s.ip} (${s.ua}) wants access. Allow? [y/N] `, a => {
    if (/^y/i.test(a)) { s.token = crypto.randomBytes(24).toString('hex'); sessions.add(s.token); s.ok = true; } else s.denied = true;
    done();
  });
})); };

const MIME = { html: 'text/html', txt: 'text/plain', jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif',
  webp: 'image/webp', mp4: 'video/mp4', webm: 'video/webm', mp3: 'audio/mpeg', pdf: 'application/pdf' };

// self-signed cert via openssl on first run; falls back to HTTP if openssl is missing
// ponytail: clients must accept the cert warning once (iOS: install + trust the profile)
const TLS = (() => {
  const k = path.join(__dirname, 'key.pem'), c = path.join(__dirname, 'cert.pem');
  if (!fs.existsSync(c)) require('child_process').spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', k, '-out', c, '-days', '825', '-subj', '/CN=localfiles'], { stdio: 'ignore' });
  return fs.existsSync(c) && fs.existsSync(k) ? { key: fs.readFileSync(k), cert: fs.readFileSync(c) } : null;
})();
const isRoot = f => Object.values(roots).includes(f);

// find other copies of this server: probe every host on each local /24 for /ping
// ponytail: probes only our own scheme+port, ~1s; mDNS if you need other ports/subnets
async function scan() {
  const mod = TLS ? require('https') : http, mine = new Set(), subs = new Set(), hits = [], jobs = [];
  for (const l of Object.values(os.networkInterfaces()).flat())
    if (l.family === 'IPv4' && !l.internal) { mine.add(l.address); subs.add(l.address.split('.').slice(0, 3).join('.')); }
  for (const s of subs) for (let i = 1; i < 255; i++) {
    const ip = `${s}.${i}`; if (mine.has(ip)) continue;
    jobs.push(new Promise(done => {
      const r = mod.get({ host: ip, port: PORT, path: '/ping', timeout: 800, rejectUnauthorized: false }, res => {
        let b = ''; res.on('data', d => b += d);
        res.on('end', () => { if (b.startsWith('localfiles:')) hits.push({ host: b.slice(11), url: `http${TLS ? 's' : ''}://${ip}:${PORT}` }); done(); });
      });
      r.on('timeout', () => r.destroy()); r.on('error', done);
    }));
  }
  await Promise.all(jobs); return hits;
}

const handler = async (req, res) => {
  const u =new URL(req.url, 'http://x'), q = u.searchParams, p = q.get('p') || '';
  const send = (c, b = '', h = {}) => { res.writeHead(c, h); res.end(b); };
  try {
    if (u.pathname === '/') return send(200, PAGE, { 'content-type': 'text/html' });
    if (u.pathname === '/ping') return send(200, 'localfiles:' + os.hostname());
    if (u.pathname === '/request' && req.method === 'POST') {
      if (Object.keys(pending).length > 20) return send(429);
      const id = crypto.randomBytes(8).toString('hex');
      pending[id] = { ip: req.socket.remoteAddress, ua: (req.headers['user-agent'] || '').slice(0, 60) };
      ask(id); return send(200, id);
    }
    if (u.pathname === '/status') {
      const s = pending[q.get('id')]; if (!s) return send(404);
      if (s.ok) { delete pending[q.get('id')]; return send(200, 'ok', { 'set-cookie': `t=${s.token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000${TLS ? '; Secure' : ''}` }); }
      return send(200, s.denied ? 'denied' : 'wait');
    }
    const tok = (req.headers.cookie || '').match(/(?:^|;\s*)t=([0-9a-f]+)/)?.[1];
    if (!sessions.has(tok)) return send(401);

    if (u.pathname === '/api/scan') return send(200, JSON.stringify(await scan()), { 'content-type': 'application/json' });
    if (u.pathname === '/api/ls') {
      if (!p) return send(200, JSON.stringify(Object.keys(roots).map(n => ({ n, d: true }))), { 'content-type': 'application/json' });
      const f = real(p); if (!f) return send(404);
      const out = fs.readdirSync(f, { withFileTypes: true }).map(e => {
        try { const s = fs.statSync(path.join(f, e.name)); return { n: e.name, d: s.isDirectory(), s: s.size }; } catch { return null; }
      }).filter(Boolean);
      return send(200, JSON.stringify(out), { 'content-type': 'application/json' });
    }
    if (u.pathname === '/api/file') {
      const f = real(p); if (!f) return send(404);
      const st = fs.statSync(f); if (st.isDirectory()) return send(400);
      const h = { 'content-type': MIME[path.extname(f).slice(1).toLowerCase()] || 'application/octet-stream', 'accept-ranges': 'bytes' };
      const m = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
      if (m) {
        const a = m[1] === '' ? Math.max(0, st.size - +m[2]) : +m[1], b = m[1] === '' || m[2] === '' ? st.size - 1 : Math.min(+m[2], st.size - 1);
        if (a > b || a >= st.size) return send(416, '', { 'content-range': `bytes */${st.size}` });
        res.writeHead(206, { ...h, 'content-range': `bytes ${a}-${b}/${st.size}`, 'content-length': b - a + 1 });
        return fs.createReadStream(f, { start: a, end: b }).pipe(res);
      }
      res.writeHead(200, { ...h, 'content-length': st.size });
      return fs.createReadStream(f).pipe(res);
    }
    if (u.pathname === '/api/up' && req.method === 'POST') {
      const d = real(p), name = path.basename(q.get('name') || '');
      if (!d || !name) return send(400);
      const w = fs.createWriteStream(path.join(d, name));
      req.pipe(w); w.on('finish', () => send(200)); w.on('error', () => send(500));
      return;
    }
    if (u.pathname === '/api/rm' && req.method === 'POST') {
      const f = real(p); if (!f || isRoot(f)) return send(400);
      fs.rmSync(f, { recursive: true }); return send(200);
    }
    if (u.pathname === '/api/mv' && req.method === 'POST') {
      const f = real(p), n = path.basename(q.get('to') || ''); if (!f || !n || isRoot(f)) return send(400);
      fs.renameSync(f, path.join(path.dirname(f), n)); return send(200);
    }
    send(404);
  } catch { if (!res.headersSent) send(500); }
};
(TLS ? require('https').createServer(TLS, handler) : http.createServer(handler)).listen(PORT, '0.0.0.0', () => {
  console.log('Sharing:', roots);
  for (const l of Object.values(os.networkInterfaces()).flat()) if (l.family === 'IPv4' && !l.internal) console.log(`Open on your devices: http${TLS ? 's' : ''}://${l.address}:${PORT}`);
});

const PAGE = `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>Files</title>
<style>body{font:16px system-ui;margin:0;padding:12px}a,button{display:block;padding:10px;border-bottom:1px solid #8884;text-decoration:none;color:inherit}.r{display:flex}.r a{flex:1}.r button{width:auto}button{font:inherit;width:100%;background:none;border:0;text-align:left}</style>
<div id=b></div><script>
const B=document.getElementById('b');
const el=(t,x,f)=>{const e=document.createElement(t);e.textContent=x;if(f)f(e);return e};
function gate(){B.replaceChildren(el('h3','Access needed'),el('button','Request access',e=>e.onclick=async()=>{
  B.replaceChildren(el('p','Waiting for approval on the host PC...'));
  const id=await (await fetch('/request',{method:'POST'})).text();
  const t=setInterval(async()=>{const s=await (await fetch('/status?id='+id)).text();
    if(s==='wait')return;clearInterval(t);s==='ok'?go(''):B.replaceChildren(el('p','Denied.'))},1500)}))}
async function go(p){const r=await fetch('/api/ls?p='+encodeURIComponent(p));
  if(r.status===401)return gate();if(!r.ok)return B.replaceChildren(el('p','Error '+r.status));
  const L=await r.json();B.replaceChildren(el('b','/'+p));
  if(!p)B.append(el('button','🔍 Scan network',e=>e.onclick=async()=>{e.textContent='Scanning...';const D=await (await fetch('/api/scan')).json();
    e.textContent=D.length?'Found:':'No other devices found';for(const d of D.reverse())e.after(el('a',d.host+'  '+d.url,a=>{a.href=d.url;a.target='_blank'}))}));
  if(p)B.append(el('a','.. up',e=>{e.href='#';e.onclick=ev=>{ev.preventDefault();go(p.split('/').slice(0,-1).join('/'))}}));
  if(p){const i=el('input','');i.type='file';i.multiple=true;i.onchange=async()=>{for(const f of i.files)await fetch('/api/up?p='+encodeURIComponent(p)+'&name='+encodeURIComponent(f.name),{method:'POST',body:f});go(p)};B.append(i)}
  for(const f of L.sort((a,b)=>b.d-a.d||a.n.localeCompare(b.n))){const q=p?p+'/'+f.n:f.n;
    const row=el('div','',e=>e.className='r');
    row.append(el('a',(f.d?'📁 ':'')+f.n+(f.d?'':'  ('+(f.s/1024|0)+' KB)'),e=>{e.href=f.d?'#':'/api/file?p='+encodeURIComponent(q);if(f.d)e.onclick=ev=>{ev.preventDefault();go(q)}}));
    if(p)row.append(el('button','✏️',e=>e.onclick=async()=>{const n=prompt('Rename to',f.n);if(n&&n!==f.n){await fetch('/api/mv?p='+encodeURIComponent(q)+'&to='+encodeURIComponent(n),{method:'POST'});go(p)}}),
      el('button','🗑',e=>e.onclick=async()=>{if(confirm('Permanently delete '+f.n+'?')){await fetch('/api/rm?p='+encodeURIComponent(q),{method:'POST'});go(p)}}));
    B.append(row)}}
go('');
</script>`;
