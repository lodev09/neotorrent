//! BitTorrent wire protocol (BEP 3) + length-prefixed message framing.
//!
//! WebRTC data channels are message-oriented but WebTorrent peers chunk wire
//! messages across SCTP segments (a 16 KiB block + 13 bytes header just barely
//! exceeds the 16 KiB SCTP max), so we need a stream-style decoder that buffers
//! incoming chunks and pops complete frames.

use bytes::{Buf, BytesMut};
use thiserror::Error;

use crate::magnet::InfoHash;
use crate::tracker::PeerId;

pub const PROTOCOL: &[u8; 19] = b"BitTorrent protocol";
pub const HANDSHAKE_LEN: usize = 1 + 19 + 8 + 20 + 20; // 68 bytes

const MSG_CHOKE: u8 = 0;
const MSG_UNCHOKE: u8 = 1;
const MSG_INTERESTED: u8 = 2;
const MSG_NOT_INTERESTED: u8 = 3;
const MSG_HAVE: u8 = 4;
const MSG_BITFIELD: u8 = 5;
const MSG_REQUEST: u8 = 6;
const MSG_PIECE: u8 = 7;
const MSG_CANCEL: u8 = 8;
const MSG_PORT: u8 = 9;
const MSG_EXTENDED: u8 = 20;

#[derive(Debug, Error)]
pub enum WireError {
    #[error("bad protocol identifier")]
    BadProto,
    #[error("invalid message id: {0}")]
    BadMsgId(u8),
    #[error("payload too small for {0}")]
    BadPayload(&'static str),
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Reserved(pub [u8; 8]);

impl Reserved {
    pub fn with_extension_protocol() -> Self {
        // BEP 10: bit 0x10 in byte 5
        let mut r = [0u8; 8];
        r[5] = 0x10;
        Self(r)
    }
    pub fn supports_extension_protocol(&self) -> bool {
        self.0[5] & 0x10 != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Handshake {
    pub reserved: Reserved,
    pub info_hash: InfoHash,
    pub peer_id: PeerId,
}

impl Handshake {
    pub fn encode(&self) -> [u8; HANDSHAKE_LEN] {
        let mut out = [0u8; HANDSHAKE_LEN];
        out[0] = PROTOCOL.len() as u8;
        out[1..20].copy_from_slice(PROTOCOL);
        out[20..28].copy_from_slice(&self.reserved.0);
        out[28..48].copy_from_slice(&self.info_hash);
        out[48..68].copy_from_slice(&self.peer_id);
        out
    }

    pub fn decode(buf: &[u8]) -> Result<Self, WireError> {
        if buf.len() < HANDSHAKE_LEN || buf[0] != PROTOCOL.len() as u8 || &buf[1..20] != PROTOCOL {
            return Err(WireError::BadProto);
        }
        let mut reserved = [0u8; 8];
        reserved.copy_from_slice(&buf[20..28]);
        let mut info_hash = [0u8; 20];
        info_hash.copy_from_slice(&buf[28..48]);
        let mut peer_id = [0u8; 20];
        peer_id.copy_from_slice(&buf[48..68]);
        Ok(Self { reserved: Reserved(reserved), info_hash, peer_id })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    KeepAlive,
    Choke,
    Unchoke,
    Interested,
    NotInterested,
    Have(u32),
    Bitfield(Vec<u8>),
    Request { index: u32, begin: u32, length: u32 },
    Piece { index: u32, begin: u32, block: Vec<u8> },
    Cancel { index: u32, begin: u32, length: u32 },
    Port(u16),
    /// BEP 10 extended message. `ext_id == 0` is the extended handshake;
    /// otherwise it's the ID we advertised for the named extension.
    Extended { ext_id: u8, payload: Vec<u8> },
}

impl Message {
    pub fn encode(&self, out: &mut Vec<u8>) {
        fn push_u32(o: &mut Vec<u8>, v: u32) { o.extend_from_slice(&v.to_be_bytes()); }

        match self {
            Message::KeepAlive => push_u32(out, 0),
            Message::Choke => { push_u32(out, 1); out.push(MSG_CHOKE); }
            Message::Unchoke => { push_u32(out, 1); out.push(MSG_UNCHOKE); }
            Message::Interested => { push_u32(out, 1); out.push(MSG_INTERESTED); }
            Message::NotInterested => { push_u32(out, 1); out.push(MSG_NOT_INTERESTED); }
            Message::Have(p) => {
                push_u32(out, 5);
                out.push(MSG_HAVE);
                push_u32(out, *p);
            }
            Message::Bitfield(b) => {
                push_u32(out, 1 + b.len() as u32);
                out.push(MSG_BITFIELD);
                out.extend_from_slice(b);
            }
            Message::Request { index, begin, length } => {
                push_u32(out, 13);
                out.push(MSG_REQUEST);
                push_u32(out, *index);
                push_u32(out, *begin);
                push_u32(out, *length);
            }
            Message::Piece { index, begin, block } => {
                push_u32(out, 9 + block.len() as u32);
                out.push(MSG_PIECE);
                push_u32(out, *index);
                push_u32(out, *begin);
                out.extend_from_slice(block);
            }
            Message::Cancel { index, begin, length } => {
                push_u32(out, 13);
                out.push(MSG_CANCEL);
                push_u32(out, *index);
                push_u32(out, *begin);
                push_u32(out, *length);
            }
            Message::Port(p) => {
                push_u32(out, 3);
                out.push(MSG_PORT);
                out.extend_from_slice(&p.to_be_bytes());
            }
            Message::Extended { ext_id, payload } => {
                push_u32(out, 2 + payload.len() as u32);
                out.push(MSG_EXTENDED);
                out.push(*ext_id);
                out.extend_from_slice(payload);
            }
        }
    }

    /// Decode a single frame's payload (i.e., bytes AFTER the 4-byte length prefix).
    /// Empty frame ⇒ KeepAlive.
    pub fn decode(frame: &[u8]) -> Result<Self, WireError> {
        if frame.is_empty() {
            return Ok(Message::KeepAlive);
        }
        let id = frame[0];
        let p = &frame[1..];
        match id {
            MSG_CHOKE => Ok(Message::Choke),
            MSG_UNCHOKE => Ok(Message::Unchoke),
            MSG_INTERESTED => Ok(Message::Interested),
            MSG_NOT_INTERESTED => Ok(Message::NotInterested),
            MSG_HAVE => {
                let p = p.get(..4).ok_or(WireError::BadPayload("have"))?;
                Ok(Message::Have(u32::from_be_bytes(p.try_into().unwrap())))
            }
            MSG_BITFIELD => Ok(Message::Bitfield(p.to_vec())),
            MSG_REQUEST => decode_triple(p, "request").map(|(i, b, l)| Message::Request {
                index: i, begin: b, length: l,
            }),
            MSG_PIECE => {
                if p.len() < 8 { return Err(WireError::BadPayload("piece")); }
                let index = u32::from_be_bytes(p[..4].try_into().unwrap());
                let begin = u32::from_be_bytes(p[4..8].try_into().unwrap());
                Ok(Message::Piece { index, begin, block: p[8..].to_vec() })
            }
            MSG_CANCEL => decode_triple(p, "cancel").map(|(i, b, l)| Message::Cancel {
                index: i, begin: b, length: l,
            }),
            MSG_PORT => {
                let p = p.get(..2).ok_or(WireError::BadPayload("port"))?;
                Ok(Message::Port(u16::from_be_bytes(p.try_into().unwrap())))
            }
            MSG_EXTENDED => {
                if p.is_empty() { return Err(WireError::BadPayload("extended")); }
                Ok(Message::Extended { ext_id: p[0], payload: p[1..].to_vec() })
            }
            other => Err(WireError::BadMsgId(other)),
        }
    }
}

fn decode_triple(p: &[u8], name: &'static str) -> Result<(u32, u32, u32), WireError> {
    if p.len() < 12 {
        return Err(WireError::BadPayload(name));
    }
    Ok((
        u32::from_be_bytes(p[..4].try_into().unwrap()),
        u32::from_be_bytes(p[4..8].try_into().unwrap()),
        u32::from_be_bytes(p[8..12].try_into().unwrap()),
    ))
}

/// Buffers incoming bytes (data-channel chunks) and yields complete frames.
#[derive(Default)]
pub struct MessageDecoder {
    buf: BytesMut,
}

impl MessageDecoder {
    pub fn push(&mut self, chunk: &[u8]) {
        self.buf.extend_from_slice(chunk);
    }

    /// Pop a complete frame if one is available. `Ok(None)` means "need more bytes".
    pub fn pop(&mut self) -> Result<Option<Message>, WireError> {
        if self.buf.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_be_bytes(self.buf[..4].try_into().unwrap()) as usize;
        if self.buf.len() < 4 + len {
            return Ok(None);
        }
        self.buf.advance(4);
        let frame = self.buf.split_to(len);
        Ok(Some(Message::decode(&frame)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rt(m: Message) {
        let mut enc = Vec::new();
        m.encode(&mut enc);
        // Encoded is 4-byte length prefix + frame body.
        let len = u32::from_be_bytes(enc[..4].try_into().unwrap()) as usize;
        assert_eq!(enc.len(), 4 + len);
        let frame = &enc[4..];
        let dec = Message::decode(frame).unwrap();
        assert_eq!(dec, m);
    }

    #[test]
    fn handshake_roundtrip() {
        let h = Handshake {
            reserved: Reserved::with_extension_protocol(),
            info_hash: [0x42; 20],
            peer_id: *b"-LR0001-abcdefghijkl",
        };
        let enc = h.encode();
        assert_eq!(enc.len(), HANDSHAKE_LEN);
        assert_eq!(&enc[1..20], PROTOCOL);
        let dec = Handshake::decode(&enc).unwrap();
        assert_eq!(dec, h);
        assert!(dec.reserved.supports_extension_protocol());
    }

    #[test]
    fn handshake_rejects_bad_protocol() {
        let mut bad = vec![0u8; HANDSHAKE_LEN];
        bad[0] = 19;
        bad[1..20].copy_from_slice(b"NotBitTorrent xxxxx");
        assert!(matches!(Handshake::decode(&bad), Err(WireError::BadProto)));
    }

    #[test]
    fn all_message_kinds_roundtrip() {
        rt(Message::KeepAlive);
        rt(Message::Choke);
        rt(Message::Unchoke);
        rt(Message::Interested);
        rt(Message::NotInterested);
        rt(Message::Have(42));
        rt(Message::Bitfield(vec![0xFF, 0xAA, 0x55]));
        rt(Message::Request { index: 1, begin: 0, length: 16384 });
        rt(Message::Piece { index: 1, begin: 0, block: vec![0x99; 100] });
        rt(Message::Cancel { index: 1, begin: 0, length: 16384 });
        rt(Message::Port(6881));
        rt(Message::Extended { ext_id: 3, payload: vec![1, 2, 3, 4] });
    }

    #[test]
    fn decoder_handles_split_chunks() {
        let mut all = Vec::new();
        Message::Have(7).encode(&mut all);
        Message::Interested.encode(&mut all);

        // Feed one byte at a time.
        let mut dec = MessageDecoder::default();
        let mut got = Vec::new();
        for b in &all {
            dec.push(&[*b]);
            while let Some(m) = dec.pop().unwrap() {
                got.push(m);
            }
        }
        assert_eq!(got, vec![Message::Have(7), Message::Interested]);
    }

    #[test]
    fn decoder_handles_concatenated_frames() {
        let mut all = Vec::new();
        Message::Have(1).encode(&mut all);
        Message::Have(2).encode(&mut all);
        Message::Have(3).encode(&mut all);

        let mut dec = MessageDecoder::default();
        dec.push(&all);
        let mut got = Vec::new();
        while let Some(m) = dec.pop().unwrap() {
            got.push(m);
        }
        assert_eq!(got, vec![Message::Have(1), Message::Have(2), Message::Have(3)]);
    }

    #[test]
    fn decoder_holds_partial_frame() {
        let mut all = Vec::new();
        Message::Piece { index: 0, begin: 0, block: vec![0x55; 100] }.encode(&mut all);
        let mut dec = MessageDecoder::default();
        // Feed everything except the last byte.
        dec.push(&all[..all.len() - 1]);
        assert!(dec.pop().unwrap().is_none());
        dec.push(&all[all.len() - 1..]);
        assert!(matches!(dec.pop().unwrap(), Some(Message::Piece { .. })));
    }
}
