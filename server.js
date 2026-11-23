const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { pipeline } = require('node:stream/promises');

const APP_ROOT = __dirname;
const RENDER_ROOT = path.join(APP_ROOT, 'renders');
const HOST = '127.0.0.1';
const PORT = 4173;
const MAX_UPLOAD_BYTES = 5 * 1024 * 1024 * 1024;
const FFMPEG = process.env.FFMPEG_PATH || 'ffmpeg';
fs.mkdirSync(RENDER_ROOT, { recursive: true });

function safeTitle(value) {
  const title = String(value || '')
    .replace(/[^\p{L}\p{N}\-_ ]/gu, '')
    .trim()
    .slice(0, 70);
  return title || 'sona-visualizer';
}

function sendText(res, status, text, type = 'text/plain; charset=utf-8') {
  const data = Buffer.from(text, 'utf8');
  res.writeHead(status, { 'Content-Type': type, 'Content-Length': data.length, 'Cache-Control': 'no-store' });
  res.end(data);
}

function sendFile(req, res, filePath) {
  const stat = fs.statSync(filePath);
  const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };
  res.writeHead(200, {
    'Content-Type': types[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
    'Content-Length': stat.size,
    'Cache-Control': 'no-store'
  });
  if (req.method === 'HEAD') return res.end();
  pipeline(fs.createReadStream(filePath), res).catch(() => {});
}

function convertToMp4(inputPath, outputPath) {
  return new Promise((resolve, reject) => {
    const args = [
      '-hide_banner', '-loglevel', 'error', '-y', '-i', inputPath,
      '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', outputPath
    ];
    const child = spawn(FFMPEG, args, { windowsHide: true });
    let errorOutput = '';
    child.stderr.on('data', chunk => { errorOutput = (errorOutput + chunk.toString()).slice(-5000); });
    child.once('error', reject);
    child.once('close', code => code === 0 ? resolve() : reject(new Error(errorOutput || 'FFmpeg conversion failed.')));
  });
}

async function handleRender(req, res, url) {
  const length = Number(req.headers['content-length'] || 0);
  if (length > MAX_UPLOAD_BYTES) {
    sendText(res, 413, '録画データが大きすぎます。720p にしてもう一度お試しください。');
    return;
  }
  const title = safeTitle(url.searchParams.get('name'));
  const stamp = new Date().toISOString().replace(/[-:TZ.]/g, '').slice(0, 14);
  const base = title + '-' + stamp;
  const tempPath = path.join(RENDER_ROOT, 'upload-' + require('node:crypto').randomUUID() + '.webm');
  const mp4Path = path.join(RENDER_ROOT, base + '.mp4');
  try {
    await pipeline(req, fs.createWriteStream(tempPath, { flags: 'wx' }));
    await convertToMp4(tempPath, mp4Path);
    const stat = fs.statSync(mp4Path);
    const encoded = encodeURIComponent(base + '.mp4').replace(/[!'()*]/g, ch => '%' + ch.charCodeAt(0).toString(16).toUpperCase());
    res.writeHead(200, {
      'Content-Type': 'video/mp4',
      'Content-Length': stat.size,
      'Content-Disposition': "attachment; filename=sona-visualizer.mp4; filename*=UTF-8''" + encoded,
      'Cache-Control': 'no-store'
    });
    await pipeline(fs.createReadStream(mp4Path), res);
    console.log('Saved ' + mp4Path);
  } catch (error) {
    console.error('Render failed:', error.message);
    if (!res.headersSent) sendText(res, 500, 'MP4 変換に失敗しました。FFmpeg と音源を確認してもう一度お試しください。');
    else res.destroy(error);
  } finally {
    fs.promises.rm(tempPath, { force: true }).catch(() => {});
  }
}

const server = http.createServer((req, res) => {
  let url;
  try { url = new URL(req.url, 'http://' + HOST + ':' + PORT); }
  catch { sendText(res, 400, 'Bad request'); return; }

  if (url.pathname === '/api/status' && req.method === 'GET') {
    sendText(res, 200, JSON.stringify({ ready: true }), 'application/json; charset=utf-8');
    return;
  }
  if (url.pathname === '/api/render' && req.method === 'POST') {
    handleRender(req, res, url);
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendText(res, 405, 'Method not allowed');
    return;
  }

  let requested;
  try { requested = decodeURIComponent(url.pathname); }
  catch { sendText(res, 400, 'Bad request'); return; }
  const relative = requested.replace(/^[/\\]+/, '') || 'index.html';
  const filePath = path.resolve(APP_ROOT, relative);
  if (!filePath.startsWith(APP_ROOT + path.sep) || filePath.startsWith(RENDER_ROOT + path.sep) || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    sendText(res, 404, 'Not found');
    return;
  }
  sendFile(req, res, filePath);
});

server.on('error', error => {
  console.error('Sona Visualizer could not start:', error.message);
  if (error.code === 'EADDRINUSE') console.error('ポート 4173 が使用中です。すでに起動している Sona Visualizer を閉じてください。');
  process.exitCode = 1;
});

server.listen(PORT, HOST, () => {
  console.log('Sona Visualizer is running at http://' + HOST + ':' + PORT + '/');
  console.log('このウィンドウを閉じるとアプリが停止します。');
  if (process.platform === 'win32') {
    const opener = spawn('cmd.exe', ['/d', '/s', '/c', 'start \"\" \"http://' + HOST + ':' + PORT + '/\"'], { detached: true, stdio: 'ignore', windowsHide: true });
    opener.unref();
  }
});
