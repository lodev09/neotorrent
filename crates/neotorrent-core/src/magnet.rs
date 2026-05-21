use std::fmt;
use std::str::FromStr;

use thiserror::Error;

pub type InfoHash = [u8; 20];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MagnetLink {
    pub info_hash: InfoHash,
    pub display_name: Option<String>,
    pub trackers: Vec<String>,
}

#[derive(Debug, Error)]
pub enum MagnetError {
    #[error("not a magnet URI (missing 'magnet:?' prefix)")]
    NotMagnet,
    #[error("missing info hash (xt=urn:btih:...)")]
    MissingInfoHash,
    #[error("invalid info hash: {0}")]
    InvalidInfoHash(String),
}

impl MagnetLink {
    pub fn parse(uri: &str) -> Result<Self, MagnetError> {
        let query = uri.strip_prefix("magnet:?").ok_or(MagnetError::NotMagnet)?;

        let mut info_hash = None;
        let mut display_name = None;
        let mut trackers = Vec::new();

        for (key, value) in form_urlencoded::parse(query.as_bytes()) {
            match key.as_ref() {
                "xt" => {
                    if let Some(hex) = value.strip_prefix("urn:btih:") {
                        info_hash = Some(decode_info_hash(hex)?);
                    }
                }
                "dn" => display_name = Some(value.into_owned()),
                "tr" => trackers.push(value.into_owned()),
                _ => {}
            }
        }

        Ok(Self {
            info_hash: info_hash.ok_or(MagnetError::MissingInfoHash)?,
            display_name,
            trackers,
        })
    }

    /// Trackers usable by neotorrent. We're WebRTC-only, so non-WS trackers are dropped.
    pub fn ws_trackers(&self) -> impl Iterator<Item = &str> {
        self.trackers
            .iter()
            .map(String::as_str)
            .filter(|t| t.starts_with("ws://") || t.starts_with("wss://"))
    }
}

impl FromStr for MagnetLink {
    type Err = MagnetError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

impl fmt::Display for MagnetLink {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "magnet:?xt=urn:btih:{}", hex(&self.info_hash))?;
        if let Some(name) = &self.display_name {
            let encoded: String =
                form_urlencoded::byte_serialize(name.as_bytes()).collect();
            write!(f, "&dn={encoded}")?;
        }
        for tr in &self.trackers {
            let encoded: String =
                form_urlencoded::byte_serialize(tr.as_bytes()).collect();
            write!(f, "&tr={encoded}")?;
        }
        Ok(())
    }
}

fn decode_info_hash(s: &str) -> Result<InfoHash, MagnetError> {
    match s.len() {
        40 => decode_hex(s),
        32 => decode_base32(s),
        n => Err(MagnetError::InvalidInfoHash(format!(
            "expected 32 (base32) or 40 (hex) chars, got {n}"
        ))),
    }
}

fn decode_hex(s: &str) -> Result<InfoHash, MagnetError> {
    let mut out = [0u8; 20];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16)
            .map_err(|_| MagnetError::InvalidInfoHash(s.to_string()))?;
    }
    Ok(out)
}

/// RFC 4648 base32 decoding (case-insensitive, no padding). 32 chars → 20 bytes.
fn decode_base32(s: &str) -> Result<InfoHash, MagnetError> {
    let mut out = [0u8; 20];
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    let mut pos = 0;
    for c in s.chars() {
        let v: u32 = match c {
            'A'..='Z' => c as u32 - 'A' as u32,
            'a'..='z' => c as u32 - 'a' as u32,
            '2'..='7' => c as u32 - '2' as u32 + 26,
            _ => return Err(MagnetError::InvalidInfoHash(format!("base32 char: {c}"))),
        };
        buf = (buf << 5) | v;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            if pos >= 20 {
                return Err(MagnetError::InvalidInfoHash("too long".into()));
            }
            out[pos] = (buf >> bits) as u8;
            pos += 1;
            buf &= (1 << bits) - 1;
        }
    }
    if pos != 20 {
        return Err(MagnetError::InvalidInfoHash(format!(
            "decoded {pos} bytes, expected 20"
        )));
    }
    Ok(out)
}

pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    const SINTEL: &str = "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=wss%3A%2F%2Ftracker.openwebtorrent.com&tr=wss%3A%2F%2Ftracker.btorrent.xyz";

    #[test]
    fn parses_sintel() {
        let m = MagnetLink::parse(SINTEL).unwrap();
        assert_eq!(hex(&m.info_hash), "08ada5a7a6183aae1e09d831df6748d566095a10");
        assert_eq!(m.display_name.as_deref(), Some("Sintel"));
        assert_eq!(
            m.trackers,
            vec![
                "wss://tracker.openwebtorrent.com",
                "wss://tracker.btorrent.xyz",
            ]
        );
    }

    #[test]
    fn ws_trackers_filters_non_ws() {
        let uri = "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&tr=udp%3A%2F%2Fbad&tr=wss%3A%2F%2Fgood&tr=http%3A%2F%2Fbad";
        let m = MagnetLink::parse(uri).unwrap();
        assert_eq!(m.ws_trackers().collect::<Vec<_>>(), vec!["wss://good"]);
    }

    #[test]
    fn decodes_plus_as_space_in_dn() {
        let uri = "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Big+Buck+Bunny";
        let m = MagnetLink::parse(uri).unwrap();
        assert_eq!(m.display_name.as_deref(), Some("Big Buck Bunny"));
    }

    #[test]
    fn rejects_non_magnet() {
        assert!(matches!(
            MagnetLink::parse("http://example.com"),
            Err(MagnetError::NotMagnet)
        ));
    }

    #[test]
    fn rejects_missing_xt() {
        assert!(matches!(
            MagnetLink::parse("magnet:?dn=foo"),
            Err(MagnetError::MissingInfoHash)
        ));
    }

    #[test]
    fn rejects_bad_hash_length() {
        let uri = "magnet:?xt=urn:btih:tooshort";
        assert!(matches!(
            MagnetLink::parse(uri),
            Err(MagnetError::InvalidInfoHash(_))
        ));
    }

    #[test]
    fn roundtrip_display() {
        let m = MagnetLink::parse(SINTEL).unwrap();
        let again = MagnetLink::parse(&m.to_string()).unwrap();
        assert_eq!(m, again);
    }

    #[test]
    fn parses_base32_info_hash() {
        // Same info hash as SINTEL, base32-encoded:
        //   hex:    08ada5a7a6183aae1e09d831df6748d566095a10
        //   base32: BCW2LJ5GDA5K4HQJ3AY56Z2I2VTASWQQ
        let uri = "magnet:?xt=urn:btih:BCW2LJ5GDA5K4HQJ3AY56Z2I2VTASWQQ&dn=Sintel";
        let m = MagnetLink::parse(uri).unwrap();
        assert_eq!(
            hex(&m.info_hash),
            "08ada5a7a6183aae1e09d831df6748d566095a10"
        );
    }

    #[test]
    fn parses_real_world_base32_magnet() {
        let uri = "magnet:?xt=urn:btih:W3EFOTSV4WCSCBKLX5NWRZSUJQ3VHUEG&dn=Test&tr=wss%3A%2F%2Ftracker.openwebtorrent.com";
        let m = MagnetLink::parse(uri).unwrap();
        assert_eq!(m.info_hash.len(), 20);
        assert_eq!(m.ws_trackers().count(), 1);
    }

    #[test]
    fn base32_is_case_insensitive() {
        let upper = "magnet:?xt=urn:btih:BCW2LJ5GDA5K4HQJ3AY56Z2I2VTASWQQ";
        let lower = "magnet:?xt=urn:btih:bcw2lj5gda5k4hqj3ay56z2i2vtaswqq";
        assert_eq!(
            MagnetLink::parse(upper).unwrap().info_hash,
            MagnetLink::parse(lower).unwrap().info_hash
        );
    }
}
