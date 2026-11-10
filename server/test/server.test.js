'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { createServer } = require('../server');
const { RoomRegistry, generateCode, normalizeCode, CODE_LENGTH, CODE_ALPHABET } = require('../rooms');

test('codes use the unambiguous alphabet', () => {
  for (let i = 0; i < 500; i++) {
    const code = generateCode();
    assert.equal(code.length, CODE_LENGTH);
    for (const ch of code) assert.ok(CODE_ALPHABET.includes(ch));
  }
});

test('normalizeCode accepts friendly input', () => {
  assert.equal(normalizeCode('abc-def'), 'ABCDEF');
  assert.equal(normalizeCode(' k7m 2pq '), 'K7M2PQ');
  assert.equal(normalizeCode('ABCDE'), null);
  assert.equal(normalizeCode('ABCDEFG'), null);
  assert.equal(normalizeCode('ABCDE0'), null); // O and 0 are never in a code
  assert.equal(normalizeCode(42), null);
});

test('registry: rooms of exactly two', () => {
  const reg = new RoomRegistry({ codeGen: () => 'ABCDEF' });
  const host = {}, guest = {}, third = {};
  const { code } = reg.create(host);
  assert.equal(code, 'ABCDEF');
  assert.equal(reg.join('abcdef', guest).code, 'ABCDEF');
  assert.equal(reg.join('ABCDEF', third).error, 'room-full');
  assert.equal(reg.peerOf(code, host), guest);
  assert.equal(reg.peerOf(code, guest), host);
  // Guest leaving keeps the room open for a rejoin.
  assert.deepEqual(reg.leave(code, guest), { closed: false, notify: host });
  assert.equal(reg.join('ABCDEF', third).code, 'ABCDEF');
  // Host leaving closes it.
  assert.deepEqual(reg.leave(code, host), { closed: true, notify: third });
  assert.equal(reg.size, 0);
  assert.equal(reg.join('ABCDEF', guest).error, 'no-such-room');
});

test('registry: rooms expire', () => {
  let now = 0;
  const reg = new RoomRegistry({ roomTtlMs: 1000, now: () => now });
  reg.create({});
  now = 2000;
  assert.equal(reg.sweep().length, 1);
  assert.equal(reg.size, 0);
});

function client(url) {
  const ws = new WebSocket(url);
  const queue = [];
  const waiters = [];
  ws.on('message', (d) => {
    const msg = JSON.parse(d.toString());
    const w = waiters.shift();
    if (w) w(msg); else queue.push(msg);
  });
  return {
    ws,
    open: () => new Promise((r) => ws.once('open', r)),
    send: (m) => ws.send(JSON.stringify(m)),
    next: () => new Promise((r) => { const m = queue.shift(); if (m) r(m); else waiters.push(r); }),
    close: () => ws.close(),
  };
}

test('end to end: create, join, relay, leave', async () => {
  const server = createServer();
  const addr = await server.listen(0, '127.0.0.1');
  const url = `ws://127.0.0.1:${addr.port}`;
  try {
    const host = client(url); await host.open();
    host.send({ type: 'create' });
    const created = await host.next();
    assert.equal(created.type, 'created');

    const guest = client(url); await guest.open();
    guest.send({ type: 'join', code: created.code.toLowerCase() });
    assert.deepEqual(await guest.next(), { type: 'joined', code: created.code });
    assert.deepEqual(await host.next(), { type: 'peer-joined' });

    host.send({ type: 'signal', data: { sdp: 'offer' } });
    assert.deepEqual(await guest.next(), { type: 'signal', data: { sdp: 'offer' } });
    guest.send({ type: 'signal', data: { sdp: 'answer' } });
    assert.deepEqual(await host.next(), { type: 'signal', data: { sdp: 'answer' } });

    const intruder = client(url); await intruder.open();
    intruder.send({ type: 'join', code: created.code });
    assert.deepEqual(await intruder.next(), { type: 'error', error: 'room-full' });

    guest.close();
    assert.deepEqual(await host.next(), { type: 'peer-left' });

    intruder.send({ type: 'join', code: created.code });
    assert.equal((await intruder.next()).type, 'joined');
    await host.next(); // peer-joined
    host.close();
    assert.deepEqual(await intruder.next(), { type: 'room-closed' });
    intruder.close();
  } finally {
    await server.close();
  }
});

test('too many bad codes closes the connection', async () => {
  const server = createServer();
  const addr = await server.listen(0, '127.0.0.1');
  try {
    const c = client(`ws://127.0.0.1:${addr.port}`); await c.open();
    const closed = new Promise((r) => c.ws.once('close', (code) => r(code)));
    for (let i = 0; i < 10; i++) c.send({ type: 'join', code: 'ZZZZZZ' });
    assert.equal(await closed, 1008);
  } finally {
    await server.close();
  }
});
