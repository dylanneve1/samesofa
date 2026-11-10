'use strict';

// Room bookkeeping for the SameSofa signalling server.
//
// A room holds exactly two people: the host who created it and one guest who
// joined with the code. The server only relays small JSON "signal" messages
// (WebRTC session descriptions and ICE candidates) between them. It never
// sees audio, video or the film, and it keeps nothing on disk.

const crypto = require('crypto');

// No 0/O, 1/I/L, so a code read out loud is hard to mishear.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 6;

function generateCode(randomBytes = crypto.randomBytes) {
  const bytes = randomBytes(CODE_LENGTH);
  let code = '';
  for (let i = 0; i < CODE_LENGTH; i++) {
    code += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return code;
}

// Accepts what a person might type: lower case, spaces, dashes.
function normalizeCode(input) {
  if (typeof input !== 'string') return null;
  const cleaned = input.toUpperCase().replace(/[\s-]/g, '')
    .replace(/O/g, '0').replace(/[IL]/g, '1');
  // After the replacements above, 0 and 1 cannot be valid characters.
  if (cleaned.length !== CODE_LENGTH) return null;
  for (const ch of cleaned) {
    if (!CODE_ALPHABET.includes(ch)) return null;
  }
  return cleaned;
}

class RoomRegistry {
  constructor({ maxRooms = 1000, roomTtlMs = 12 * 60 * 60 * 1000, now = Date.now, codeGen = generateCode } = {}) {
    this.rooms = new Map(); // code -> { host, guest, createdAt }
    this.maxRooms = maxRooms;
    this.roomTtlMs = roomTtlMs;
    this.now = now;
    this.codeGen = codeGen;
  }

  get size() { return this.rooms.size; }

  create(host) {
    this.sweep();
    if (this.rooms.size >= this.maxRooms) return { error: 'server-full' };
    let code;
    for (let tries = 0; tries < 50; tries++) {
      const candidate = this.codeGen();
      if (!this.rooms.has(candidate)) { code = candidate; break; }
    }
    if (!code) return { error: 'server-full' };
    this.rooms.set(code, { host, guest: null, createdAt: this.now() });
    return { code };
  }

  join(rawCode, guest) {
    const code = normalizeCode(rawCode);
    if (!code) return { error: 'bad-code' };
    const room = this.rooms.get(code);
    if (!room) return { error: 'no-such-room' };
    if (room.guest && room.guest !== guest) return { error: 'room-full' };
    if (room.host === guest) return { error: 'own-room' };
    room.guest = guest;
    return { code, room };
  }

  // Returns the other member of the room, or null.
  peerOf(code, member) {
    const room = this.rooms.get(code);
    if (!room) return null;
    if (room.host === member) return room.guest;
    if (room.guest === member) return room.host;
    return null;
  }

  // Removes a member. If the host leaves, the room is closed and the guest
  // (if any) is returned so the caller can tell them. If the guest leaves,
  // the room stays open so they can come back with the same code.
  leave(code, member) {
    const room = this.rooms.get(code);
    if (!room) return { closed: false, notify: null };
    if (room.host === member) {
      this.rooms.delete(code);
      return { closed: true, notify: room.guest };
    }
    if (room.guest === member) {
      room.guest = null;
      return { closed: false, notify: room.host };
    }
    return { closed: false, notify: null };
  }

  sweep() {
    const cutoff = this.now() - this.roomTtlMs;
    const expired = [];
    for (const [code, room] of this.rooms) {
      if (room.createdAt < cutoff) {
        this.rooms.delete(code);
        expired.push(room);
      }
    }
    return expired;
  }
}

module.exports = { RoomRegistry, generateCode, normalizeCode, CODE_ALPHABET, CODE_LENGTH };
