// TLS terminator for iPhone-over-WireGuard: wss://gw.goncloud.cc:18790 -> ws://127.0.0.1:18789
// Leaves the gateway listener untouched (Mac/ControlUI keep ws:// as-is).
const tls = require('node:tls');
const net = require('node:net');
const fs = require('node:fs');
const CERT = 'C:/Users/ehven/.openclaw/tls/gw.goncloud.cc.crt';
const KEY = 'C:/Users/ehven/.openclaw/tls/gw.goncloud.cc.key';
const LISTEN_HOST = '10.13.13.4';
const LISTEN_PORT = 18790;
const TARGET_HOST = '127.0.0.1';
const TARGET_PORT = 18789;
const server = tls.createServer(
  { cert: fs.readFileSync(CERT), key: fs.readFileSync(KEY) },
  (tlsSock) => {
    const upstream = net.connect(TARGET_PORT, TARGET_HOST, () => {
      tlsSock.pipe(upstream).pipe(tlsSock);
    });
    const onErr = () => { try { tlsSock.destroy(); } catch {} try { upstream.destroy(); } catch {} };
    tlsSock.on('error', onErr);
    upstream.on('error', onErr);
  }
);
server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`TLS proxy UP ${LISTEN_HOST}:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT}`);
});
server.on('error', (e) => { console.error('PROXY_ERROR', e.message); process.exit(1); });
