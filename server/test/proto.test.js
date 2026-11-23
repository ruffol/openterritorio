'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const proto = require('../src/proto');

function positionPacket(overrides = {}) {
  return {
    packet_id: Buffer.from('0102030405060708', 'hex'),
    sender_id: 42,
    timestamp: 1764000000,
    hop_limit: 3,
    type: 0,
    position: {
      latitude_e7: 192433000,
      longitude_e7: -1037247000,
      altitude_m: 550,
      speed_cms: 4200,
      heading_deg: 275,
      battery_pct: 88,
    },
    ...overrides,
  };
}

test('codifica y decodifica POSITION_UPDATE', () => {
  const encoded = proto.encode(positionPacket());
  assert.ok(Buffer.isBuffer(encoded));
  assert.ok(encoded.length < 80, `paquete demasiado grande: ${encoded.length}`);

  const decoded = proto.validate(proto.decode(encoded));
  assert.equal(decoded.type, 0);
  assert.equal(decoded.sender_id, 42);
  assert.equal(decoded.packet_id.length, 8);
  assert.equal(decoded.position.latitude_e7, 192433000);
  assert.equal(decoded.position.longitude_e7, -1037247000);
  assert.equal(decoded.position.heading_deg, 275);
});

test('codifica y decodifica ACK_CONFIRMATION', () => {
  const ack = {
    packet_id: Buffer.from('1111111111111111', 'hex'),
    sender_id: 7,
    timestamp: 1764000100,
    hop_limit: 0,
    type: 3,
    ack: { acked_packet_id: Buffer.from('2222222222222222', 'hex') },
  };
  const decoded = proto.validate(proto.decode(proto.encode(ack)));
  assert.equal(decoded.type, 3);
  assert.equal(proto.packetIdToHex(decoded.ack.acked_packet_id), '2222222222222222');
});

test('serializa bytes a hexadecimal para JSON', () => {
  const decoded = proto.decode(proto.encode(positionPacket()));
  const json = proto.toWireJSON(decoded);
  assert.equal(json.packet_id, '0102030405060708');
  assert.equal(json.type_name, 'POSITION_UPDATE');
  assert.equal(json.position.latitude_e7, 192433000);
});

test('rechaza packet_id que no mide 8 bytes', () => {
  const bad = positionPacket({ packet_id: Buffer.from('0102', 'hex') });
  const decoded = proto.decode(proto.encode(bad));
  assert.throws(() => proto.validate(decoded), /packet_id must be exactly 8 bytes/);
});

test('rechaza payload que no corresponde al tipo', () => {
  const bad = {
    packet_id: Buffer.from('0102030405060709', 'hex'),
    sender_id: 1,
    timestamp: 1,
    hop_limit: 1,
    type: 1,
    position: { latitude_e7: 1, longitude_e7: 1 },
  };
  const decoded = proto.decode(proto.encode(bad));
  assert.throws(() => proto.validate(decoded), /payload mismatch/);
});

test('rechaza coordenadas fuera de rango', () => {
  const bad = positionPacket();
  bad.position = { ...bad.position, latitude_e7: 910000000 };
  const decoded = proto.decode(proto.encode(bad));
  assert.throws(() => proto.validate(decoded), /latitude_e7 out of range/);
});

test('un paquete de posición realista cabe en LoRa (~47 bytes)', () => {
  const encoded = proto.encode(positionPacket());
  assert.ok(encoded.length >= 25 && encoded.length <= 55, `tamaño inesperado: ${encoded.length}`);
});
