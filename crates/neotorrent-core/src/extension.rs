//! BEP 10 extension protocol negotiation + BEP 9 `ut_metadata`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_bytes::ByteBuf;
use thiserror::Error;

use crate::bencode;
use crate::magnet::InfoHash;

/// Per-peer extension IDs we choose (sent in our extended handshake `m` dict).
pub const OUR_UT_METADATA_ID: u8 = 1;

/// 16 KiB per metadata piece (BEP 9).
pub const METADATA_PIECE_SIZE: usize = 16384;

/// Largest peer-advertised `metadata_size` we accept.
pub const MAX_METADATA_SIZE: u64 = 10 * 1024 * 1024;

/// Largest bencoded extension message dict (handshake, ut_metadata header) we parse.
const MAX_MESSAGE_SIZE: usize = 64 * 1024;

/// `ut_metadata` message types.
pub const UT_METADATA_REQUEST: u8 = 0;
pub const UT_METADATA_DATA: u8 = 1;
pub const UT_METADATA_REJECT: u8 = 2;

#[derive(Debug, Error)]
pub enum ExtensionError {
    #[error("bencode: {0}")]
    Bencode(String),
    #[error("bencode value malformed, too large or too deeply nested")]
    BadBencode,
    #[error("malformed ut_metadata data: missing piece bytes")]
    BadUtMetadataData,
    #[error("invalid metadata_size: {0}")]
    BadMetadataSize(u64),
    #[error("ut_metadata piece {piece} is {got} bytes, expected {expected}")]
    BadPieceLength {
        piece: u32,
        got: usize,
        expected: usize,
    },
    #[error("info dict hash mismatch")]
    InfoHashMismatch,
    #[error("unsafe path in info dict: {0:?}")]
    UnsafePath(String),
}

impl From<serde_bencode::Error> for ExtensionError {
    fn from(e: serde_bencode::Error) -> Self {
        Self::Bencode(e.to_string())
    }
}

/// Parse peer-supplied bencode only after checking it is a single value within
/// `max_len` bytes and [bencode::MAX_DEPTH] nesting, so serde_bencode can't be
/// driven into deep recursion.
fn decode_bounded<'de, T: Deserialize<'de>>(
    bytes: &'de [u8],
    max_len: usize,
) -> Result<T, ExtensionError> {
    if bytes.len() > max_len || bencode::value_end(bytes) != Some(bytes.len()) {
        return Err(ExtensionError::BadBencode);
    }
    Ok(serde_bencode::from_bytes(bytes)?)
}

// -- Extended handshake (BEP 10, ext_id = 0) ------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExtendedHandshake {
    /// Map of extension name → the ID *this peer* will accept for that extension.
    #[serde(default)]
    pub m: BTreeMap<String, u8>,
    /// Client version string (e.g., "neotorrent 0.1").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub v: Option<String>,
    /// Total .torrent metadata size in bytes (advertised by peers that have it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata_size: Option<u64>,
}

impl ExtendedHandshake {
    /// Build our outgoing handshake — we support `ut_metadata`.
    pub fn ours() -> Self {
        let mut m = BTreeMap::new();
        m.insert("ut_metadata".to_string(), OUR_UT_METADATA_ID);
        Self {
            m,
            v: Some(format!("neotorrent {}", env!("CARGO_PKG_VERSION"))),
            metadata_size: None,
        }
    }

    pub fn encode(&self) -> Result<Vec<u8>, ExtensionError> {
        Ok(serde_bencode::to_bytes(self)?)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ExtensionError> {
        decode_bounded(bytes, MAX_MESSAGE_SIZE)
    }

    /// The peer's ID for ut_metadata, if they support it (BEP 10: 0 = disabled).
    pub fn ut_metadata_id(&self) -> Option<u8> {
        self.m.get("ut_metadata").copied().filter(|&id| id != 0)
    }
}

// -- ut_metadata messages -------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UtMetadataHeader {
    msg_type: u8,
    piece: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    total_size: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UtMetadataMessage {
    Request {
        piece: u32,
    },
    Data {
        piece: u32,
        total_size: u64,
        data: Vec<u8>,
    },
    Reject {
        piece: u32,
    },
}

impl UtMetadataMessage {
    pub fn encode(&self) -> Result<Vec<u8>, ExtensionError> {
        match self {
            Self::Request { piece } => {
                let h = UtMetadataHeader {
                    msg_type: UT_METADATA_REQUEST,
                    piece: *piece,
                    total_size: None,
                };
                Ok(serde_bencode::to_bytes(&h)?)
            }
            Self::Reject { piece } => {
                let h = UtMetadataHeader {
                    msg_type: UT_METADATA_REJECT,
                    piece: *piece,
                    total_size: None,
                };
                Ok(serde_bencode::to_bytes(&h)?)
            }
            Self::Data {
                piece,
                total_size,
                data,
            } => {
                let h = UtMetadataHeader {
                    msg_type: UT_METADATA_DATA,
                    piece: *piece,
                    total_size: Some(*total_size),
                };
                let mut buf = serde_bencode::to_bytes(&h)?;
                buf.extend_from_slice(data);
                Ok(buf)
            }
        }
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ExtensionError> {
        let end = bencode::value_end(bytes).ok_or(ExtensionError::BadUtMetadataData)?;
        let h: UtMetadataHeader = decode_bounded(&bytes[..end], MAX_MESSAGE_SIZE)?;
        match h.msg_type {
            UT_METADATA_REQUEST => Ok(Self::Request { piece: h.piece }),
            UT_METADATA_REJECT => Ok(Self::Reject { piece: h.piece }),
            UT_METADATA_DATA => Ok(Self::Data {
                piece: h.piece,
                total_size: h.total_size.unwrap_or(0),
                data: bytes[end..].to_vec(),
            }),
            _ => Err(ExtensionError::Bencode(format!(
                "unknown msg_type {}",
                h.msg_type
            ))),
        }
    }
}

// -- Metadata reassembly --------------------------------------------------

/// Tracks incoming `ut_metadata` Data messages and concatenates them into the
/// full info-dict bytes, verifying the SHA-1 matches the magnet's info hash.
pub struct MetadataAssembler {
    pieces: Vec<Option<Vec<u8>>>,
    total_size: usize,
    info_hash: InfoHash,
}

impl MetadataAssembler {
    pub fn new(total_size: u64, info_hash: InfoHash) -> Result<Self, ExtensionError> {
        if total_size == 0 || total_size > MAX_METADATA_SIZE {
            return Err(ExtensionError::BadMetadataSize(total_size));
        }
        let total_size = total_size as usize;
        Ok(Self {
            pieces: vec![None; total_size.div_ceil(METADATA_PIECE_SIZE)],
            total_size,
            info_hash,
        })
    }

    pub fn num_pieces(&self) -> usize {
        self.pieces.len()
    }

    pub fn total_size(&self) -> u64 {
        self.total_size as u64
    }

    pub fn missing_pieces(&self) -> impl Iterator<Item = u32> + '_ {
        self.pieces
            .iter()
            .enumerate()
            .filter_map(|(i, p)| p.is_none().then_some(i as u32))
    }

    /// Returns `Ok(Some(info_bytes))` when complete and SHA-1 matches.
    /// `Ok(None)` if we're still waiting on more pieces.
    pub fn record(&mut self, piece: u32, data: Vec<u8>) -> Result<Option<Vec<u8>>, ExtensionError> {
        let idx = piece as usize;
        if idx >= self.pieces.len() {
            return Ok(None);
        }
        let expected = METADATA_PIECE_SIZE.min(self.total_size - idx * METADATA_PIECE_SIZE);
        if data.len() != expected {
            return Err(ExtensionError::BadPieceLength {
                piece,
                got: data.len(),
                expected,
            });
        }
        self.pieces[idx] = Some(data);
        if self.pieces.iter().any(Option::is_none) {
            return Ok(None);
        }
        let mut assembled = Vec::with_capacity(self.total_size);
        for p in &self.pieces {
            assembled.extend_from_slice(p.as_ref().unwrap());
        }
        assembled.truncate(self.total_size);

        use sha1::{Digest, Sha1};
        let mut h = Sha1::new();
        h.update(&assembled);
        let got: [u8; 20] = h.finalize().into();
        if got != self.info_hash {
            return Err(ExtensionError::InfoHashMismatch);
        }
        Ok(Some(assembled))
    }
}

// -- Info dict (BEP 3) ----------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    pub length: u64,
    pub path: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InfoDict {
    pub name: String,
    #[serde(rename = "piece length")]
    pub piece_length: u64,
    pub pieces: ByteBuf,
    #[serde(default)]
    pub length: Option<u64>,
    #[serde(default)]
    pub files: Option<Vec<FileEntry>>,
}

impl InfoDict {
    /// Parses and rejects any `name` / file `path` that could escape the
    /// download directory, so callers can join them onto a base dir as-is.
    pub fn parse(bytes: &[u8]) -> Result<Self, ExtensionError> {
        let info: Self = decode_bounded(bytes, MAX_METADATA_SIZE as usize)?;
        info.validate_paths()?;
        Ok(info)
    }

    fn validate_paths(&self) -> Result<(), ExtensionError> {
        if !is_safe_path_component(&self.name) {
            return Err(ExtensionError::UnsafePath(self.name.clone()));
        }
        for f in self.files.iter().flatten() {
            if f.path.is_empty() || !f.path.iter().all(|c| is_safe_path_component(c)) {
                return Err(ExtensionError::UnsafePath(f.path.join("/")));
            }
        }
        Ok(())
    }

    pub fn piece_hashes(&self) -> impl Iterator<Item = &[u8]> {
        self.pieces.chunks(20)
    }

    pub fn num_pieces(&self) -> usize {
        self.pieces.len() / 20
    }

    pub fn total_size(&self) -> u64 {
        if let Some(l) = self.length {
            return l;
        }
        self.files
            .as_ref()
            .map(|fs| fs.iter().map(|f| f.length).sum())
            .unwrap_or(0)
    }

    pub fn is_multi_file(&self) -> bool {
        self.files.is_some()
    }
}

/// A single relative path component: not empty, `.`, `..`, and no separators
/// (which also rules out absolute paths).
pub fn is_safe_path_component(c: &str) -> bool {
    !matches!(c, "" | "." | "..") && !c.contains(['/', '\\'])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extended_handshake_roundtrip() {
        let h = ExtendedHandshake::ours();
        let enc = h.encode().unwrap();
        let dec = ExtendedHandshake::decode(&enc).unwrap();
        assert_eq!(dec.ut_metadata_id(), Some(OUR_UT_METADATA_ID));
        assert!(dec.v.as_ref().unwrap().starts_with("neotorrent "));
    }

    #[test]
    fn extended_handshake_decodes_peer_metadata_size() {
        // d1:md11:ut_metadatai2ee13:metadata_sizei12345ee
        let enc = b"d1:md11:ut_metadatai2ee13:metadata_sizei12345ee";
        let dec = ExtendedHandshake::decode(enc).unwrap();
        assert_eq!(dec.ut_metadata_id(), Some(2));
        assert_eq!(dec.metadata_size, Some(12345));
    }

    #[test]
    fn ut_metadata_request_roundtrip() {
        let m = UtMetadataMessage::Request { piece: 3 };
        let enc = m.encode().unwrap();
        assert_eq!(UtMetadataMessage::decode(&enc).unwrap(), m);
    }

    #[test]
    fn ut_metadata_reject_roundtrip() {
        let m = UtMetadataMessage::Reject { piece: 5 };
        assert_eq!(UtMetadataMessage::decode(&m.encode().unwrap()).unwrap(), m);
    }

    #[test]
    fn ut_metadata_data_roundtrip() {
        let m = UtMetadataMessage::Data {
            piece: 0,
            total_size: 16384,
            data: (0..1024).map(|i| i as u8).collect(),
        };
        let enc = m.encode().unwrap();
        // The bencoded header must come first, with raw bytes appended.
        assert!(enc.starts_with(b"d"));
        let dec = UtMetadataMessage::decode(&enc).unwrap();
        assert_eq!(dec, m);
    }

    #[test]
    fn metadata_assembler_completes_and_verifies() {
        let info = b"d4:name4:test12:piece lengthi16384e6:pieces20:01234567890123456789e";
        use sha1::{Digest, Sha1};
        let mut h = Sha1::new();
        h.update(info);
        let info_hash: [u8; 20] = h.finalize().into();

        let mut asm = MetadataAssembler::new(info.len() as u64, info_hash).unwrap();
        assert_eq!(asm.num_pieces(), 1);
        let done = asm.record(0, info.to_vec()).unwrap().unwrap();
        assert_eq!(&done, info);
    }

    #[test]
    fn metadata_assembler_rejects_bad_hash() {
        let info = b"d4:name4:test12:piece lengthi16384e6:pieces20:01234567890123456789e";
        let wrong_hash = [0u8; 20];
        let mut asm = MetadataAssembler::new(info.len() as u64, wrong_hash).unwrap();
        assert!(matches!(
            asm.record(0, info.to_vec()),
            Err(ExtensionError::InfoHashMismatch)
        ));
    }

    #[test]
    fn metadata_assembler_multi_piece() {
        let mut info = Vec::new();
        // Build a fake info dict large enough for 2 pieces.
        info.extend_from_slice(b"d4:name4:test12:piece lengthi16384e6:pieces20:");
        info.extend_from_slice(&[0u8; 20]);
        info.push(b'e');
        // Pad to ~20KB so it spans two metadata pieces.
        let pad_size = 18000 - info.len();
        info.extend(std::iter::repeat_n(b'x', pad_size));

        use sha1::{Digest, Sha1};
        let mut h = Sha1::new();
        h.update(&info);
        let info_hash: [u8; 20] = h.finalize().into();

        let mut asm = MetadataAssembler::new(info.len() as u64, info_hash).unwrap();
        assert_eq!(asm.num_pieces(), 2);
        let missing: Vec<u32> = asm.missing_pieces().collect();
        assert_eq!(missing, vec![0, 1]);

        let p0 = info[..METADATA_PIECE_SIZE].to_vec();
        let p1 = info[METADATA_PIECE_SIZE..].to_vec();
        assert!(asm.record(0, p0).unwrap().is_none());
        let done = asm.record(1, p1).unwrap().unwrap();
        assert_eq!(done, info);
    }

    #[test]
    fn info_dict_parses_single_file() {
        let bytes =
            b"d6:lengthi100e4:name8:file.txt12:piece lengthi16384e6:pieces20:01234567890123456789e";
        let info = InfoDict::parse(bytes).unwrap();
        assert_eq!(info.name, "file.txt");
        assert_eq!(info.piece_length, 16384);
        assert_eq!(info.num_pieces(), 1);
        assert_eq!(info.length, Some(100));
        assert_eq!(info.total_size(), 100);
        assert!(!info.is_multi_file());
    }

    #[test]
    fn info_dict_parses_multi_file() {
        let bytes = b"d5:filesld6:lengthi10e4:pathl1:a5:f.txteed6:lengthi20e4:pathl1:b5:g.txteee4:name3:dir12:piece lengthi16384e6:pieces20:01234567890123456789e";
        let info = InfoDict::parse(bytes).unwrap();
        assert!(info.is_multi_file());
        assert_eq!(info.total_size(), 30);
        let files = info.files.unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path, vec!["a", "f.txt"]);
        assert_eq!(files[1].path, vec!["b", "g.txt"]);
    }

    #[test]
    fn extended_handshake_zero_id_means_disabled() {
        let dec = ExtendedHandshake::decode(b"d1:md11:ut_metadatai0eee").unwrap();
        assert_eq!(dec.ut_metadata_id(), None);
    }

    #[test]
    fn extended_handshake_rejects_deep_nesting() {
        let mut enc = b"d1:x".to_vec();
        enc.extend(std::iter::repeat_n(b'l', 10_000));
        enc.extend(std::iter::repeat_n(b'e', 10_000));
        enc.push(b'e');
        assert!(matches!(
            ExtendedHandshake::decode(&enc),
            Err(ExtensionError::BadBencode)
        ));
    }

    #[test]
    fn extended_handshake_rejects_oversized() {
        let pad = "x".repeat(MAX_MESSAGE_SIZE);
        let enc = format!("d1:x{}:{pad}e", pad.len());
        assert!(matches!(
            ExtendedHandshake::decode(enc.as_bytes()),
            Err(ExtensionError::BadBencode)
        ));
    }

    #[test]
    fn ut_metadata_rejects_deep_header() {
        let mut enc = b"d1:x".to_vec();
        enc.extend(std::iter::repeat_n(b'l', 10_000));
        enc.extend(std::iter::repeat_n(b'e', 10_000));
        enc.push(b'e');
        assert!(UtMetadataMessage::decode(&enc).is_err());
    }

    #[test]
    fn metadata_assembler_rejects_bad_size() {
        assert!(matches!(
            MetadataAssembler::new(0, [0; 20]),
            Err(ExtensionError::BadMetadataSize(0))
        ));
        assert!(matches!(
            MetadataAssembler::new(MAX_METADATA_SIZE + 1, [0; 20]),
            Err(ExtensionError::BadMetadataSize(_))
        ));
        assert!(MetadataAssembler::new(MAX_METADATA_SIZE, [0; 20]).is_ok());
    }

    #[test]
    fn metadata_assembler_rejects_bad_piece_length() {
        let mut asm = MetadataAssembler::new(20_000, [0; 20]).unwrap();
        assert!(matches!(
            asm.record(0, vec![0; 100]),
            Err(ExtensionError::BadPieceLength {
                piece: 0,
                got: 100,
                expected: METADATA_PIECE_SIZE
            })
        ));
        assert!(matches!(
            asm.record(1, vec![0; METADATA_PIECE_SIZE]),
            Err(ExtensionError::BadPieceLength {
                piece: 1,
                expected: 3616,
                ..
            })
        ));
        assert!(asm.record(1, vec![0; 3616]).unwrap().is_none());
        assert_eq!(asm.missing_pieces().collect::<Vec<_>>(), vec![0]);
    }

    fn multi_file_info(name: &str, path: &[&str]) -> Vec<u8> {
        let mut b = b"d5:filesld6:lengthi1e4:pathl".to_vec();
        for c in path {
            b.extend(format!("{}:{c}", c.len()).bytes());
        }
        b.extend(
            format!(
                "eee4:name{}:{name}12:piece lengthi16384e6:pieces20:01234567890123456789e",
                name.len()
            )
            .bytes(),
        );
        b
    }

    #[test]
    fn info_dict_accepts_safe_paths() {
        assert!(InfoDict::parse(&multi_file_info("dir", &["a", "b.txt"])).is_ok());
        assert!(InfoDict::parse(&multi_file_info("dir", &["..a", "b..txt"])).is_ok());
    }

    #[test]
    fn info_dict_rejects_unsafe_paths() {
        let paths: [&[&str]; 8] = [
            &[],
            &[""],
            &["."],
            &[".."],
            &["a", "..", "b"],
            &["/etc", "passwd"],
            &["a/b"],
            &["a\\b"],
        ];
        for path in paths {
            assert!(
                matches!(
                    InfoDict::parse(&multi_file_info("dir", path)),
                    Err(ExtensionError::UnsafePath(_))
                ),
                "{path:?}"
            );
        }
        for name in ["", ".", "..", "/abs", "a/b"] {
            assert!(
                matches!(
                    InfoDict::parse(&multi_file_info(name, &["f"])),
                    Err(ExtensionError::UnsafePath(_))
                ),
                "{name:?}"
            );
        }
    }
}
