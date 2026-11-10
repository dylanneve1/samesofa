'use strict';

// SameSofa signalling server: pairs two people by a short room code and
// relays WebRTC offer/answer/ICE messages between them. Stateless apart from
// an in-memory map of open rooms; nothing is logged about message contents.

const http = require('http');
const { WebSocketServer } = require('ws');
const { RoomRegistry } = require('./rooms');

const MAX_MESSAGE_BYTES = 64 * 1024;
const MAX_BAD_JOINS = 10;
const HEARTBEAT_MS = 25_000;

function createServer({ registry = new RoomRegistry(), log = () => {} } = {}) {
  const httpServer = http.createServer((req, res) => {
    // Plain HTTP GET is only used as a health check.
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('samesofa signalling ok\n');
  });

  const wss = new WebSocketServer({ server: httpServer, maxPayload: MAX_MESSAGE_BYTES });

  function send(ws, msg) {
    if (ws && ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
  }

  wss.on('connection', (ws) => {
    ws.isAlive = true;
    ws.room = null;
    ws.badJoins = 0;
    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', (data, isBinary) => {
      if (isBinary) return ws.close(1003, 'text only');
      let msg;
      try { msg = JSON.parse(data.toString('utf8')); } catch { return send(ws, { type: 'error', error: 'bad-json' }); }
      if (!msg || typeof msg.type !== 'string') return send(ws, { type: 'error', error: 'bad-message' });

      switch (msg.type) {
        case 'create': {
          if (ws.room) return send(ws, { type: 'error', error: 'already-in-room' });
          const result = registry.create(ws);
          if (result.error) return send(ws, { type: 'error', error: result.error });
          ws.room = result.code;
          log('room created');
          return send(ws, { type: 'created', code: result.code });
        }
        case 'join': {
          if (ws.room) return send(ws, { type: 'error', error: 'already-in-room' });
          const result = registry.join(msg.code, ws);
          if (result.error) {
            ws.badJoins += 1;
            send(ws, { type: 'error', error: result.error });
            if (ws.badJoins >= MAX_BAD_JOINS) ws.close(1008, 'too many attempts');
            return;
          }
          ws.room = result.code;
          log('room joined');
          send(ws, { type: 'joined', code: result.code });
          return send(result.room.host, { type: 'peer-joined' });
        }
        case 'signal': {
          if (!ws.room) return send(ws, { type: 'error', error: 'not-in-room' });
          const peer = registry.peerOf(ws.room, ws);
          if (!peer) return send(ws, { type: 'error', error: 'no-peer' });
          return send(peer, { type: 'signal', data: msg.data });
        }
        case 'leave': {
          leave(ws);
          return;
        }
        case 'ping':
          return send(ws, { type: 'pong' });
        default:
          return send(ws, { type: 'error', error: 'unknown-type' });
      }
    });

    ws.on('close', () => leave(ws));
    ws.on('error', () => {});
  });

  function leave(ws) {
    if (!ws.room) return;
    const { closed, notify } = registry.leave(ws.room, ws);
    ws.room = null;
    if (notify) {
      send(notify, { type: closed ? 'room-closed' : 'peer-left' });
      if (closed) notify.room = null;
    }
  }

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) { ws.terminate(); continue; }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* ignore */ }
    }
    for (const room of registry.sweep()) {
      for (const member of [room.host, room.guest]) {
        if (member) { send(member, { type: 'room-closed' }); member.room = null; }
      }
    }
  }, HEARTBEAT_MS);
  wss.on('close', () => clearInterval(heartbeat));

  return {
    httpServer,
    wss,
    registry,
    listen(port, host) {
      return new Promise((resolve) => httpServer.listen(port, host, () => resolve(httpServer.address())));
    },
    close() {
      clearInterval(heartbeat);
      for (const ws of wss.clients) ws.terminate();
      return new Promise((resolve) => wss.close(() => httpServer.close(() => resolve())));
    },
  };
}

module.exports = { createServer };

if (require.main === module) {
  const port = Number(process.env.PORT || 8787);
  const host = process.env.HOST || '127.0.0.1';
  const server = createServer({ log: (m) => console.log(new Date().toISOString(), m) });
  server.listen(port, host).then((addr) => {
    console.log(`samesofa signalling listening on ${addr.address}:${addr.port}`);
  });
  const shutdown = () => server.close().then(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
