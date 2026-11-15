const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 5050;
const WEBSITE_DIR = path.join(__dirname, '..', 'website');
const DIST_DIR = path.join(__dirname, '..', 'dist');

const server = http.createServer((req, res) => {
  const cleanUrl = req.url.split('?')[0];

  // 1. Handle file downloads from /downloads/
  if (cleanUrl.startsWith('/downloads/')) {
    const filename = path.basename(cleanUrl);
    const filePath = path.join(DIST_DIR, filename);

    if (fs.existsSync(filePath)) {
      const stat = fs.statSync(filePath);
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': `attachment; filename="${filename}"`,
        'Content-Length': stat.size,
      });
      return fs.createReadStream(filePath).pipe(res);
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      return res.end(`File ${filename} not found in dist/. Please run build script first.`);
    }
  }

  // 2. Serve static website files
  const filePath = path.join(WEBSITE_DIR, cleanUrl === '/' ? 'index.html' : cleanUrl);

  fs.readFile(filePath, (err, data) => {
    if (err) {
      const indexPath = path.join(WEBSITE_DIR, 'index.html');
      fs.readFile(indexPath, (idxErr, idxData) => {
        if (idxErr) {
          res.writeHead(404, { 'Content-Type': 'text/plain' });
          return res.end('Not Found');
        }
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(idxData);
      });
      return;
    }

    const ext = path.extname(filePath);
    const mimeTypes = {
      '.html': 'text/html',
      '.css': 'text/css',
      '.js': 'application/javascript',
      '.svg': 'image/svg+xml',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.dmg': 'application/octet-stream',
      '.exe': 'application/octet-stream',
    };

    const contentType = mimeTypes[ext] || 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`🌐 Landing website running at http://localhost:${PORT}`);
});
