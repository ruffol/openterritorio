'use strict';

const proto = require('./proto');

/**
 * Pipeline de ingesta:
 *   decodificar -> validar -> deduplicar -> persistir -> difundir -> (ACK en cliente).
 */
function createIngest({ repo, hub, log }) {
  function handle(buffer, client) {
    let msg;
    try {
      msg = proto.decode(buffer);
      proto.validate(msg);
    } catch (err) {
      return { ok: false, error: err.message };
    }

    if (client && msg.sender_id !== 0) client.senderId = msg.sender_id;

    const nowMs = Date.now();
    const packetId = Buffer.from(msg.packet_id);
    const timestamp = proto.toNumber(msg.timestamp);

    const inserted = repo.markSeen(packetId, msg.sender_id, timestamp, nowMs);
    if (!inserted) {
      log.debug('duplicate packet ignored', {
        packet: proto.packetIdToHex(packetId),
        sender: msg.sender_id,
      });
      return { ok: true, duplicate: true };
    }

    switch (msg.type) {
      case proto.PACKET_TYPE.POSITION_UPDATE:
        repo.upsertPeer(msg, nowMs, client ? client.transport : 'server');
        repo.insertTrack(msg, nowMs);
        break;
      case proto.PACKET_TYPE.USER_EVENT:
        repo.insertEvent(msg, nowMs);
        break;
      case proto.PACKET_TYPE.SERVER_ALERT:
        repo.insertAlert(msg, nowMs);
        break;
      case proto.PACKET_TYPE.ACK_CONFIRMATION:
        repo.insertAck(msg, nowMs);
        break;
      default:
        break;
    }

    // Las confirmaciones no se reenvían; el resto sí (menos al emisor).
    if (msg.type !== proto.PACKET_TYPE.ACK_CONFIRMATION) {
      hub.broadcast(buffer, client || null);
    }

    log.info('packet accepted', {
      type: proto.PACKET_TYPE_NAME[msg.type],
      sender: msg.sender_id,
      packet: proto.packetIdToHex(packetId),
    });

    return { ok: true };
  }

  return { handle };
}

module.exports = { createIngest };
