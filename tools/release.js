// node tools/release.js keygen
// node tools/release.js publish <build:int> <name> [--win <Release dir>] [--apk <file>]
// Writes a signed manifest + content-addressed blobs to %APPDATA%\OpenConnect\updates,
// which every running LocalFiles app serves at /update/*. Clients download only blobs they lack (delta).
const fs = require('fs'), path = require('path'), crypto = require('crypto'), os = require('os');
const keyFile = path.join(os.homedir(), '.localfiles', 'release.key'); // private key: keep out of the project
const out = path.join(process.env.APPDATA, 'OpenConnect', 'updates');
const [cmd, ...a] = process.argv.slice(2);
const opt = k => { const i = a.indexOf(k); return i < 0 ? null : a[i + 1]; };

if (cmd === 'keygen') {
  if (fs.existsSync(keyFile)) throw new Error('key already exists, refusing to overwrite: ' + keyFile);
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  fs.mkdirSync(path.dirname(keyFile), { recursive: true });
  fs.writeFileSync(keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  console.log('PUBLIC_KEY_HEX', publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex'));
} else if (cmd === 'publish') {
  const m = { build: +a[0], name: a[1] };
  if (!m.build || !m.name) throw new Error('usage: publish <build> <name> [--win dir] [--apk file]');
  fs.mkdirSync(path.join(out, 'blobs'), { recursive: true });
  const put = f => { const h = crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex'); fs.copyFileSync(f, path.join(out, 'blobs', h)); return h; };

  const win = opt('--win');
  if (win) {
    m.windows = { files: [] };
    const walk = d => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) walk(f);
      else m.windows.files.push({ p: path.relative(win, f).replace(/\\/g, '/'), sha: put(f), size: fs.statSync(f).size });
    } };
    walk(win);
  }
  if (opt('--apk')) { const f = opt('--apk'); m.android = { apk: { sha: put(f), size: fs.statSync(f).size } }; }

  // publishing one platform of the same build keeps the other platform already published
  const mf = path.join(out, 'manifest.json');
  if (fs.existsSync(mf)) { const old = JSON.parse(fs.readFileSync(mf, 'utf8')); if (old.build === m.build) { m.windows ??= old.windows; m.android ??= old.android; } }

  const s = JSON.stringify(m);
  const sig = crypto.sign(null, Buffer.from(s), crypto.createPrivateKey(fs.readFileSync(keyFile)));
  fs.writeFileSync(mf, s);
  fs.writeFileSync(path.join(out, 'manifest.sig'), sig.toString('hex'));
  console.log('published build', m.build, m.name, '->', out);
} else console.log('usage: keygen | publish <build> <name> [--win dir] [--apk file]');
