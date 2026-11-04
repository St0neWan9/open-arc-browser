import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../dist/', import.meta.url));
const types = {'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.png':'image/png','.svg':'image/svg+xml','.txt':'text/plain; charset=utf-8'};
createServer(async (req,res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    let file = path.resolve(root, '.' + decodeURIComponent(url.pathname));
    if (path.relative(root, file).startsWith('..')) throw new Error('Invalid path');
    if ((await stat(file)).isDirectory()) file = path.join(file, 'index.html');
    const data = await readFile(file);
    res.writeHead(200, {'Content-Type': types[path.extname(file)] || 'application/octet-stream','Cache-Control':'no-store'});res.end(data);
  } catch { res.writeHead(404, {'Content-Type':'text/html; charset=utf-8'});res.end(await readFile(path.join(root,'404.html'))); }
}).listen(4180,'127.0.0.1',()=>console.log('Local: http://127.0.0.1:4180'));
