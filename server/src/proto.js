'use strict';

const path = require('node:path');
const protobuf = require('protobufjs');

const PROTO_PATH =
  process.env.PROTO_PATH ||
  path.join(__dirname, '..', '..', 'proto', 'tactical_packet.proto');

const PACKET_TYPE = Object.freeze({
  POSITION_UPDATE: 0,
  USER_EVENT: 1,
  SERVER_ALERT: 2,
  ACK_CONFIRMATION: 3,
});

const PACKET_TYPE_NAME = Object.freeze({
  0: 'POSITION_UPDATE',
  1: 'USER_EVENT',
  2: 'SERVER_ALERT',
  3: 'ACK_CONFIRMATION',
});

const KIND_BY_TYPE = Object.freeze({
  0: 'position',
  1: 'event',
  2: 'alert',
  3: 'ack',
});

let packetType = null;

function load() {
  if (packetType) return packetType;
  // Evita dependencia de la librería "long": los timestamps caben en Number.
  protobuf.util.Long = undefined;
  protobuf.configure();
  // keepCase: conserva packet_id, latitude_e7, etc. (el parser, por defecto,
  // los convierte a camelCase y las claves snake_case se ignoran al codificar).
  const root = new protobuf.Root();
  root.loadSync(PROTO_PATH, { keepCase: true });
  packetType = root.lookupType('openterritorio.TacticalPacket');
  return packetType;
}

function decode(buffer) {
  return load().decode(buffer);
}

function encode(object) {
  const type = load();
  const error = type.verify(object);
  if (error) throw new Error(`protobuf verify: ${error}`);
  return Buffer.from(type.encode(type.create(object)).finish());
}

function toNumber(value) {
  if (value == null) return 0;
  if (typeof value === 'number') return value;
  if (typeof value === 'bigint') return Number(value);
  if (typeof value.toNumber === 'function') return value.toNumber();
  return Number(value);
}

function payloadKind(msg) {
  if (msg.position) return 'position';
  if (msg.event) return 'event';
  if (msg.alert) return 'alert';
  if (msg.ack) return 'ack';
  return null;
}

function packetIdToHex(bytes) {
  if (!bytes) return null;
  return Buffer.from(bytes).toString('hex');
}

/**
 * Valida el paquete y lanza Error con un mensaje claro si no es aceptable.
 */
function validate(msg) {
  if (!msg || msg.type == null) throw new Error('missing packet type');
  if (![0, 1, 2, 3].includes(msg.type)) throw new Error(`invalid packet type: ${msg.type}`);
  if (!msg.packet_id || msg.packet_id.length !== 8) {
    throw new Error('packet_id must be exactly 8 bytes');
  }
  if (msg.sender_id == null) throw new Error('missing sender_id');

  const kind = payloadKind(msg);
  const expected = KIND_BY_TYPE[msg.type];
  if (kind !== expected) {
    throw new Error(`payload mismatch: type=${PACKET_TYPE_NAME[msg.type]} payload=${kind}`);
  }

  const checkLat = (value) => {
    if (!Number.isInteger(value) || value < -900000000 || value > 900000000) {
      throw new Error(`latitude_e7 out of range: ${value}`);
    }
  };
  const checkLon = (value) => {
    if (!Number.isInteger(value) || value < -1800000000 || value > 1800000000) {
      throw new Error(`longitude_e7 out of range: ${value}`);
    }
  };
  const checkNote = (value, field) => {
    if (Buffer.byteLength(value || '', 'utf8') > 64) {
      throw new Error(`${field} exceeds 64 bytes`);
    }
  };

  switch (msg.type) {
    case 0: {
      checkLat(msg.position.latitude_e7);
      checkLon(msg.position.longitude_e7);
      if (msg.position.battery_pct > 100) throw new Error('battery_pct > 100');
      if (msg.position.heading_deg > 359) throw new Error('heading_deg > 359');
      break;
    }
    case 1: {
      checkLat(msg.event.latitude_e7);
      checkLon(msg.event.longitude_e7);
      checkNote(msg.event.short_note, 'short_note');
      break;
    }
    case 2: {
      checkLat(msg.alert.latitude_e7);
      checkLon(msg.alert.longitude_e7);
      if (![1, 2, 3].includes(msg.alert.severity)) {
        throw new Error(`invalid severity: ${msg.alert.severity}`);
      }
      checkNote(msg.alert.title, 'title');
      break;
    }
    case 3: {
      if (!msg.ack.acked_packet_id || msg.ack.acked_packet_id.length !== 8) {
        throw new Error('acked_packet_id must be exactly 8 bytes');
      }
      break;
    }
    default:
      break;
  }

  return msg;
}

/**
 * Representación JSON segura para logs y REST (bytes en hexadecimal).
 */
function toWireJSON(msg) {
  const type = load();
  const object = type.toObject(msg, {
    longs: Number,
    enums: String,
    defaults: false,
  });
  if (object.packet_id) {
    object.packet_id = Buffer.from(object.packet_id, 'base64').toString('hex');
  }
  if (object.ack && object.ack.acked_packet_id) {
    object.ack.acked_packet_id = Buffer.from(object.ack.acked_packet_id, 'base64').toString('hex');
  }
  object.type_name = PACKET_TYPE_NAME[msg.type];
  return object;
}

module.exports = {
  PROTO_PATH,
  PACKET_TYPE,
  PACKET_TYPE_NAME,
  load,
  decode,
  encode,
  validate,
  toNumber,
  toWireJSON,
  packetIdToHex,
  payloadKind,
};
