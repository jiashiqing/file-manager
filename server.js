/* 文件管理系统 - 零依赖 Node 服务 */
const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const PORT = process.env.PORT || 8199;
const ROOT = __dirname;
const PUB = path.join(ROOT, 'public');
const CONFIG = path.join(ROOT, 'config.json');
const MAX_BODY = 2 * 1024 * 1024 * 1024; // 2GB

/* 存储目录可配置，持久化到 config.json */
let FILES = path.join(ROOT, 'files');
let META = path.join(FILES, '_meta.json');
const META_FILE = '_meta.json';

async function initConfig() {
  try {
    const c = JSON.parse(await fsp.readFile(CONFIG, 'utf8'));
    if (c.filesDir && path.isAbsolute(c.filesDir)) {
      FILES = path.resolve(c.filesDir);
      META = path.join(FILES, META_FILE);
    }
  } catch { /* 首次运行无配置 */ }
  await fsp.mkdir(FILES, { recursive: true });
}

/* 文件名清洗：禁 /\ : * ? " < > | 及控制字符 */
function sanitize(raw) {
  let name = '';
  try { name = decodeURIComponent(raw || ''); } catch { name = raw || ''; }
  name = path.basename(name).replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').trim();
  return name || 'unnamed';
}

/* 重名自动加序号 */
async function uniqueName(dir, name) {
  const ext = path.extname(name);
  const stem = ext ? name.slice(0, -ext.length) : name;
  let cand = name, i = 1;
  while (true) {
    try { await fsp.access(path.join(dir, cand)); } catch { return cand; }
    cand = `${stem}(${i})${ext}`;
    i++;
  }
}

function fmtSize(n) {
  if (n < 1024) return n + ' B';
  if (n < 1024 ** 2) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 ** 3) return (n / 1024 ** 2).toFixed(1) + ' MB';
  return (n / 1024 ** 3).toFixed(2) + ' GB';
}

/* 上传元数据（IP、时间）存 sidecar JSON，与文件同目录 */
async function readMeta() {
  try { return JSON.parse(await fsp.readFile(META, 'utf8')); } catch { return {}; }
}
async function writeMeta(m) {
  await fsp.writeFile(META, JSON.stringify(m, null, 2), 'utf8');
}
function getIP(req) {
  const xff = req.headers['x-forwarded-for'];
  if (xff) return String(xff).split(',')[0].trim();
  return (req.socket.remoteAddress || '').replace(/^::ffff:/, '').replace(/^::1$/, '127.0.0.1') || '-';
}

async function listFiles(q) {
  const names = (await fsp.readdir(FILES)).filter(n => n !== META_FILE);
  const meta = await readMeta();
  const out = [];
  for (const name of names) {
    try {
      const st = await fsp.stat(path.join(FILES, name));
      if (!st.isFile()) continue;
      if (q && !name.toLowerCase().includes(q.toLowerCase())) continue;
      const m = meta[name] || {};
      out.push({
        name,
        size: st.size,
        mtime: st.mtimeMs,
        ip: m.ip || '-',
        path: path.join(FILES, name),
      });
    } catch { /* skip */ }
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function sendJSON(res, code, obj) {
  const buf = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': buf.length });
  res.end(buf);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (c) => {
      total += c.length;
      if (total > MAX_BODY) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = url.pathname;

  try {
    /* ---- 静态页面 ---- */
    if (req.method === 'GET' && (p === '/' || p === '/index.html')) {
      const buf = await fsp.readFile(path.join(PUB, 'index.html'));
      res.writeHead(200, { 'Content-Type': MIME['.html'], 'Content-Length': buf.length });
      return res.end(buf);
    }

    /* ---- 健康探针 ---- */
    if (req.method === 'GET' && p === '/api/ping') {
      return sendJSON(res, 200, { ok: true, ts: Date.now() });
    }

    /* ---- 列表 / 搜索（分页：?q=&page=1&size=10） ---- */
    if (req.method === 'GET' && p === '/api/files') {
      const q = (url.searchParams.get('q') || '').trim();
      const size = Math.min(Math.max(parseInt(url.searchParams.get('size')) || 10, 1), 100);
      const all = await listFiles(q);
      const pages = Math.max(1, Math.ceil(all.length / size));
      const page = Math.min(Math.max(parseInt(url.searchParams.get('page')) || 1, 1), pages);
      const items = all.slice((page - 1) * size, page * size);
      return sendJSON(res, 200, { ok: true, items, total: all.length, page, pages, size, dir: FILES });
    }

    /* ---- 上传：原始字节流 + x-filename 头，记录 IP ---- */
    if (req.method === 'POST' && p === '/api/upload') {
      const name = await uniqueName(FILES, sanitize(req.headers['x-filename']));
      const body = await readBody(req);
      await fsp.writeFile(path.join(FILES, name), body);
      const meta = await readMeta();
      meta[name] = { ip: getIP(req), ts: Date.now() };
      await writeMeta(meta);
      return sendJSON(res, 200, { ok: true, name, size: body.length });
    }

    /* ---- 下载 ---- */
    if (req.method === 'GET' && p === '/api/download') {
      const name = sanitize(url.searchParams.get('name'));
      const fp = path.join(FILES, name);
      const st = await fsp.stat(fp).catch(() => null);
      if (!st || !st.isFile()) return sendJSON(res, 404, { ok: false, error: '文件不存在' });
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': st.size,
        'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
      });
      fs.createReadStream(fp).pipe(res);
      return;
    }

    /* ---- 存储路径：查 / 改 ---- */
    if (req.method === 'GET' && p === '/api/config') {
      return sendJSON(res, 200, { ok: true, dir: FILES });
    }
    if (req.method === 'POST' && p === '/api/config') {
      const body = await readBody(req);
      let dir = '';
      try { dir = String(JSON.parse(body.toString('utf8')).dir || '').trim(); } catch {}
      if (!dir) return sendJSON(res, 400, { ok: false, error: '路径不能为空' });
      if (!path.isAbsolute(dir)) return sendJSON(res, 400, { ok: false, error: '请输入绝对路径，例如 D:\\共享文件' });
      const abs = path.resolve(dir);
      try {
        await fsp.mkdir(abs, { recursive: true });
        await fsp.access(abs, fs.constants.W_OK);
      } catch {
        return sendJSON(res, 400, { ok: false, error: '无法创建或写入该目录' });
      }
      await fsp.writeFile(CONFIG, JSON.stringify({ filesDir: abs }, null, 2), 'utf8');
      FILES = abs;
      META = path.join(FILES, META_FILE);
      return sendJSON(res, 200, { ok: true, dir: abs });
    }

    /* ---- 删除 ---- */
    if (req.method === 'DELETE' && p === '/api/files') {
      const name = sanitize(url.searchParams.get('name'));
      await fsp.unlink(path.join(FILES, name)).catch(() => {});
      const meta = await readMeta();
      if (meta[name]) { delete meta[name]; await writeMeta(meta); }
      return sendJSON(res, 200, { ok: true });
    }

    sendJSON(res, 404, { ok: false, error: 'not found' });
  } catch (e) {
    sendJSON(res, 500, { ok: false, error: String(e.message || e) });
  }
});

initConfig().then(() => {
  /* 反代场景由 systemd 注入 BIND_HOST=127.0.0.1；本地直跑默认全接口 */
  const HOST = process.env.BIND_HOST || '0.0.0.0';
  server.listen(PORT, HOST, () => {
    console.log(`file-manager running at http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${PORT} (files: ${FILES})`);
  });
}).catch(e => { console.error('init failed:', e); process.exit(1); });
