import http from 'node:http';
import https from 'node:https';
import { constants, createWriteStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes, scrypt as derive, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';

const scrypt = promisify(derive);
const configFlag = process.argv.indexOf('--config-dir');
const configDir = (configFlag >= 0 && process.argv[configFlag + 1]) || process.env.NAS_CONFIG ||
  path.join(process.env.LOCALAPPDATA, 'PrivateNAS');
const accountFile = path.join(configDir, 'account.json');
const storage = process.env.NAS_ROOT || 'E:\\PrivateNAS';
const port = Number(process.env.NAS_PORT || 8787);
const uploadLimit = 20 * 1024 ** 3;
const internalPrefix = '.nas-upload-';
const fail = (status, message) => Object.assign(new Error(message), { status });

async function saveOwner(username) {
  if (!/^[\p{L}\p{Nd}_-]+$/u.test(username || '') || username.length > 32) throw new Error('Invalid username');
  process.stdin.setEncoding('utf8');
  let password = '';
  for await (const chunk of process.stdin) password += chunk;
  if (password.length < 8 || password.length > 12) throw new Error('Use 8–12 password characters');
  const salt = randomBytes(16).toString('hex');
  const hash = (await scrypt(password, salt, 64)).toString('hex');
  await fs.mkdir(configDir, { recursive: true });
  const temporary = path.join(configDir, randomBytes(16).toString('hex'));
  try {
    await fs.writeFile(temporary, JSON.stringify({ username, salt, hash }), { flag: 'wx' });
    await fs.rename(temporary, accountFile);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

function parts(value) {
  return value ? value.split('/').map(name => {
    if (!name || name.length > 255 || /[<>:"\\|?*\x00-\x1f]/.test(name) ||
        /[. ]$/.test(name) || /^(con|conin\$|conout\$|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³]) *(?:\.|$)/i.test(name) ||
        name.toLowerCase().startsWith(internalPrefix)) throw fail(400, '文件名无效');
    return name;
  }) : [];
}

async function serve() {
  await fs.mkdir(storage, { recursive: true });
  const root = await fs.realpath(storage);
  const sessions = new Map();
  const sessionLifetime = 12 * 60 * 60 * 1000;
  let failures = [];
  let loginInProgress = false;

  // Resolve each existing component and reject links, including Windows junctions.
  async function resolve(names) {
    let current = root;
    for (const name of names) {
      current = path.join(current, name);
      const info = await fs.lstat(current);
      if (info.isSymbolicLink()) throw fail(403, '无法访问链接');
      const canonical = await fs.realpath(current);
      const relative = path.relative(root, canonical);
      if (!relative || relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) {
        throw fail(403, '无法访问该位置');
      }
      current = canonical;
    }
    return current;
  }

  async function transfer(route, names, targetNames) {
    if (!targetNames.length) throw fail(400, '请选择目标位置');
    const source = await resolve(names);
    const info = await fs.lstat(source);
    if (!info.isFile() && !info.isDirectory()) throw fail(403, '无法操作此项目');
    const parent = await resolve(targetNames.slice(0, -1));
    const destination = path.join(parent, targetNames.at(-1));
    const relative = path.relative(source, parent);
    if (info.isDirectory() && (!relative || (!path.isAbsolute(relative) &&
        relative !== '..' && !relative.startsWith('..' + path.sep)))) {
      throw fail(400, '不能将文件夹放进自身或其子文件夹');
    }
    const existing = await fs.lstat(destination).catch(error => {
      if (error.code !== 'ENOENT') throw error;
    });
    if (existing) throw fail(409, '目标位置已有同名项目');

    if (route === 'POST /api/move') {
      if (info.isDirectory()) {
        // On Windows a directory rename cannot replace an existing directory.
        await fs.rename(source, destination);
      } else {
        await fs.link(source, destination);
        try { await fs.unlink(source); }
        catch (error) {
          await fs.unlink(destination).catch(rollback => console.error(rollback));
          throw error;
        }
      }
      return;
    }

    const staging = await fs.mkdtemp(path.join(parent, internalPrefix));
    const copy = path.join(staging, 'item');
    try {
      if (info.isDirectory()) {
        await fs.cp(source, copy, {
          recursive: true,
          errorOnExist: true,
          force: false,
          filter: async file => {
            if (path.basename(file).toLowerCase().startsWith(internalPrefix)) return false;
            const item = await fs.lstat(file);
            if (!item.isFile() && !item.isDirectory()) throw fail(403, '文件夹包含无法复制的链接');
            return true;
          },
        });
        await fs.rename(copy, destination);
      } else {
        await fs.copyFile(source, copy, constants.COPYFILE_EXCL);
        await fs.link(copy, destination);
      }
    } finally {
      await fs.rm(staging, { recursive: true, force: true });
    }
  }

  function json(res, status, body) {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(body));
  }

  async function login(req, res) {
    const now = Date.now();
    failures = failures.filter(time => now - time < 60_000);
    if (failures.length >= 8 || loginInProgress) throw fail(429, '请稍后再试');
    loginInProgress = true;
    try {
      const chunks = [];
      let bytes = 0;
      for await (const chunk of req.iterator({ destroyOnReturn: false })) {
        bytes += chunk.length;
        if (bytes > 4096) throw fail(413, '登录请求过大');
        chunks.push(chunk);
      }
      let data;
      try { data = JSON.parse(Buffer.concat(chunks)); }
      catch { throw fail(400, '登录请求无效'); }
      if (typeof data?.username !== 'string' || typeof data?.password !== 'string' || data.password.length > 256) {
        throw fail(400, '登录请求无效');
      }
      const account = await fs.readFile(accountFile, 'utf8').catch(error => {
        if (error.code === 'ENOENT') throw fail(503, '请先在 Windows 上设置网盘账号');
        throw error;
      });
      const owner = JSON.parse(account);
      const hash = await scrypt(data.password, owner.salt, 64);
      if (!timingSafeEqual(hash, Buffer.from(owner.hash, 'hex')) || data.username !== owner.username) {
        failures.push(now);
        throw fail(401, '账号或密码错误');
      }
      for (const [key, session] of sessions) if (session.expires <= now) sessions.delete(key);
      if (sessions.size >= 32) sessions.delete(sessions.keys().next().value);
      const token = randomBytes(32).toString('hex');
      sessions.set(token, { account, expires: now + sessionLifetime });
      json(res, 200, { token });
    } finally {
      loginInProgress = false;
    }
  }

  async function handle(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const url = new URL(req.url, 'http://localhost');
    const route = req.method + ' ' + url.pathname;
    if (route === 'GET /health') return json(res, 200, { ok: true });
    if (route === 'POST /api/login') return login(req, res);
    const token = req.headers.authorization?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
    const session = sessions.get(token);
    if (!session || session.expires <= Date.now() || session.account !== await fs.readFile(accountFile, 'utf8').catch(() => null)) {
      sessions.delete(token);
      throw fail(401, '请重新登录');
    }
    if (route === 'POST /api/logout') {
      sessions.delete(token);
      return json(res, 200, { ok: true });
    }
    const names = parts(url.searchParams.get('path'));
    if (route === 'GET /api/files') {
      const folder = await resolve(names);
      const files = [];
      for (const item of await fs.readdir(folder, { withFileTypes: true })) {
        if (!item.isFile() && !item.isDirectory()) continue;
        try { parts(item.name); } catch { continue; }
        const info = await fs.lstat(path.join(folder, item.name)).catch(error => {
          if (error.code !== 'ENOENT') throw error;
        });
        if (info && (info.isFile() || info.isDirectory())) {
          files.push({ name: item.name, directory: info.isDirectory(), size: info.size, modified: info.mtimeMs });
        }
      }
      return json(res, 200, files);
    }
    if (!names.length) throw fail(400, '请选择文件或文件夹');
    if (route === 'POST /api/copy' || route === 'POST /api/move') {
      await transfer(route, names, parts(url.searchParams.get('destination')));
      return json(res, 200, { ok: true });
    }
    if (route === 'GET /api/file') {
      const destination = await resolve(names);
      const info = await fs.stat(destination);
      if (!info.isFile()) throw fail(400, '请选择文件');
      const file = await fs.open(destination, 'r');
      res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': info.size });
      return pipeline(file.createReadStream(), res);
    }
    if (route === 'DELETE /api/file') {
      const destination = await resolve(names);
      const info = await fs.lstat(destination);
      if (url.searchParams.get('recursive') === 'true') {
        if (!info.isDirectory()) throw fail(409, '此项目已不再是文件夹，请刷新后重试');
        await fs.rm(destination, { recursive: true });
      } else if (info.isDirectory()) await fs.rmdir(destination);
      else if (info.isFile()) await fs.unlink(destination);
      else throw fail(403, '无法删除此项目');
      return json(res, 200, { ok: true });
    }
    const parent = await resolve(names.slice(0, -1));
    const destination = path.join(parent, names.at(-1));
    if (route === 'POST /api/folder') {
      await fs.mkdir(destination);
      return json(res, 201, { ok: true });
    }
    if (route === 'PUT /api/file') {
      if (Number(req.headers['content-length']) > uploadLimit) throw fail(413, '文件超过 20 GiB');
      const temporary = path.join(parent, internalPrefix + randomBytes(16).toString('hex'));
      let bytes = 0;
      const meter = new Transform({
        transform(chunk, encoding, done) {
          bytes += chunk.length;
          done(bytes > uploadLimit ? fail(413, '文件超过 20 GiB') : null, chunk);
        },
      });
      try {
        await pipeline(req.iterator({ destroyOnReturn: false }), meter, createWriteStream(temporary, { flags: 'wx' }));
        await fs.link(temporary, destination);
      } finally {
        await fs.rm(temporary, { force: true });
      }
      return json(res, 201, { ok: true });
    }
    throw fail(404, '接口不存在');
  }

  const errors = {
    ENOENT: [404, '文件或文件夹不存在'], EEXIST: [409, '同名项目已存在'],
    ENOTEMPTY: [409, '只能删除空文件夹'], ENOTDIR: [400, '请选择文件夹'],
    ENOSPC: [507, '磁盘空间不足'], EACCES: [403, 'Windows 拒绝访问'],
  };
  const options = { requestTimeout: 60 * 60 * 1000 };
  const cert = process.env.NAS_TLS_CERT || (process.argv.includes('--tls') && path.join(configDir, 'server-cert.pem'));
  const key = process.env.NAS_TLS_KEY || (process.argv.includes('--tls') && path.join(configDir, 'server-key.pem'));
  if (Boolean(cert) !== Boolean(key)) throw new Error('Set both NAS_TLS_CERT and NAS_TLS_KEY');
  const host = cert ? (process.env.NAS_BIND || '0.0.0.0') : '127.0.0.1';
  const server = cert
    ? https.createServer({ ...options, cert: await fs.readFile(cert), key: await fs.readFile(key), minVersion: 'TLSv1.2' })
    : http.createServer(options);
  server.on('request', (req, res) => {
    handle(req, res).catch(error => {
      if (res.headersSent || res.destroyed) return res.destroy();
      const [status, message] = error.status ? [error.status, error.message] :
        errors[error.code] || [500, '服务器操作失败'];
      if (status === 500) console.error(error);
      if (!req.complete) res.setHeader('Connection', 'close');
      json(res, status, { error: message });
    });
  });
  server.listen(port, host, () => console.log(`PrivateNAS ${cert ? 'HTTPS' : 'HTTP'} port ${port} on ${host} → ${root}`));
}

if (process.argv[2] === 'owner') await saveOwner(process.argv[3]);
else await serve();
