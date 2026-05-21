//! WebTorrent-style tracker over WebSocket.
//!
//! Protocol notes:
//! - 20-byte fields (`info_hash`, `peer_id`, `offer_id`) are sent as 20-char
//!   strings where each char's Unicode codepoint equals the byte value. JSON
//!   serializes those as valid UTF-8; the trackers (Node.js) reverse it via
//!   `String.fromCharCode` / `charCodeAt`.
//! - `offer`/`answer` are objects `{ type: "offer"|"answer", sdp: "..." }`.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Message};

use crate::magnet::InfoHash;

pub type PeerId = [u8; 20];
pub type OfferId = [u8; 20];

pub fn generate_peer_id() -> PeerId {
    use rand::RngCore;
    let mut id = [0u8; 20];
    let prefix = b"-LR0001-";
    id[..prefix.len()].copy_from_slice(prefix);
    rand::thread_rng().fill_bytes(&mut id[prefix.len()..]);
    id
}

pub fn generate_offer_id() -> OfferId {
    use rand::RngCore;
    let mut id = [0u8; 20];
    rand::thread_rng().fill_bytes(&mut id);
    id
}

#[derive(Debug, Error)]
pub enum TrackerError {
    #[error("websocket: {0}")]
    WebSocket(String),
    #[error("invalid url: {0}")]
    Url(String),
    #[error("json: {0}")]
    Json(String),
    #[error("tracker closed connection")]
    Closed,
}

impl From<tokio_tungstenite::tungstenite::Error> for TrackerError {
    fn from(e: tokio_tungstenite::tungstenite::Error) -> Self {
        Self::WebSocket(e.to_string())
    }
}

impl From<serde_json::Error> for TrackerError {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnounceEvent {
    Started,
    Stopped,
    Completed,
    Update,
}

impl AnnounceEvent {
    fn as_str(self) -> Option<&'static str> {
        match self {
            Self::Started => Some("started"),
            Self::Stopped => Some("stopped"),
            Self::Completed => Some("completed"),
            Self::Update => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct OutgoingOffer {
    pub offer_id: OfferId,
    pub sdp: String,
}

#[derive(Debug, Clone)]
pub struct AnnounceParams {
    pub info_hash: InfoHash,
    pub peer_id: PeerId,
    pub uploaded: u64,
    pub downloaded: u64,
    pub left: u64,
    pub event: AnnounceEvent,
    pub offers: Vec<OutgoingOffer>,
    pub numwant: u32,
}

#[derive(Debug, Clone)]
pub enum TrackerEvent {
    Stats {
        complete: u64,
        incomplete: u64,
        interval: Duration,
    },
    PeerOffer {
        peer_id: PeerId,
        offer_id: OfferId,
        sdp: String,
    },
    PeerAnswer {
        peer_id: PeerId,
        offer_id: OfferId,
        sdp: String,
    },
    Closed,
}

// -- Wire format ----------------------------------------------------------

#[derive(Serialize)]
struct AnnounceWire {
    action: &'static str,
    #[serde(with = "binary_hash")]
    info_hash: [u8; 20],
    #[serde(with = "binary_hash")]
    peer_id: [u8; 20],
    uploaded: u64,
    downloaded: u64,
    left: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    event: Option<&'static str>,
    numwant: u32,
    offers: Vec<OfferWire>,
}

#[derive(Serialize)]
struct OfferWire {
    #[serde(with = "binary_hash")]
    offer_id: [u8; 20],
    offer: SdpWire,
}

#[derive(Serialize, Deserialize)]
struct SdpWire {
    #[serde(rename = "type")]
    kind: String,
    sdp: String,
}

#[derive(Serialize)]
struct AnswerWire {
    action: &'static str,
    #[serde(with = "binary_hash")]
    info_hash: [u8; 20],
    #[serde(with = "binary_hash")]
    peer_id: [u8; 20],
    #[serde(with = "binary_hash")]
    to_peer_id: [u8; 20],
    #[serde(with = "binary_hash")]
    offer_id: [u8; 20],
    answer: SdpWire,
}

#[derive(Deserialize)]
struct ServerMessage {
    #[serde(default)]
    peer_id: Option<String>,
    #[serde(default)]
    offer_id: Option<String>,
    #[serde(default)]
    interval: Option<u64>,
    #[serde(default)]
    complete: Option<u64>,
    #[serde(default)]
    incomplete: Option<u64>,
    #[serde(default)]
    offer: Option<SdpWire>,
    #[serde(default)]
    answer: Option<SdpWire>,
}

fn parse_event(msg: &str) -> Option<TrackerEvent> {
    let sm: ServerMessage = serde_json::from_str(msg).ok()?;
    if let Some(sdp) = sm.offer {
        let peer_id = sm.peer_id.as_deref().and_then(decode_binary_20)?;
        let offer_id = sm.offer_id.as_deref().and_then(decode_binary_20)?;
        return Some(TrackerEvent::PeerOffer { peer_id, offer_id, sdp: sdp.sdp });
    }
    if let Some(sdp) = sm.answer {
        let peer_id = sm.peer_id.as_deref().and_then(decode_binary_20)?;
        let offer_id = sm.offer_id.as_deref().and_then(decode_binary_20)?;
        return Some(TrackerEvent::PeerAnswer { peer_id, offer_id, sdp: sdp.sdp });
    }
    if sm.complete.is_some() || sm.incomplete.is_some() || sm.interval.is_some() {
        return Some(TrackerEvent::Stats {
            complete: sm.complete.unwrap_or(0),
            incomplete: sm.incomplete.unwrap_or(0),
            interval: Duration::from_secs(sm.interval.unwrap_or(120)),
        });
    }
    None
}

#[cfg(test)]
fn encode_binary(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| b as char).collect()
}

fn decode_binary_20(s: &str) -> Option<[u8; 20]> {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() != 20 {
        return None;
    }
    let mut out = [0u8; 20];
    for (i, c) in chars.into_iter().enumerate() {
        let cp = c as u32;
        if cp > 0xFF {
            return None;
        }
        out[i] = cp as u8;
    }
    Some(out)
}

mod binary_hash {
    use serde::Serializer;

    pub fn serialize<S: Serializer>(bytes: &[u8; 20], s: S) -> Result<S::Ok, S::Error> {
        let str: String = bytes.iter().map(|&b| b as char).collect();
        s.serialize_str(&str)
    }
}

// -- Client ----------------------------------------------------------------

enum Cmd {
    Announce(AnnounceParams),
    SendAnswer {
        info_hash: InfoHash,
        peer_id: PeerId,
        to_peer_id: PeerId,
        offer_id: OfferId,
        sdp: String,
    },
    Shutdown,
}

pub struct TrackerClient {
    cmd_tx: mpsc::Sender<Cmd>,
}

impl TrackerClient {
    pub async fn connect(
        url: &str,
    ) -> Result<(Self, mpsc::Receiver<TrackerEvent>), TrackerError> {
        let url = url::Url::parse(url).map_err(|e| TrackerError::Url(e.to_string()))?;
        let (ws, _) = connect_async(url.as_str()).await?;
        let (mut sink, mut stream) = ws.split();

        let (cmd_tx, mut cmd_rx) = mpsc::channel::<Cmd>(32);
        let (evt_tx, evt_rx) = mpsc::channel::<TrackerEvent>(64);

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    cmd = cmd_rx.recv() => {
                        let Some(cmd) = cmd else { break };
                        let text = match cmd {
                            Cmd::Announce(p) => {
                                let wire = AnnounceWire {
                                    action: "announce",
                                    info_hash: p.info_hash,
                                    peer_id: p.peer_id,
                                    uploaded: p.uploaded,
                                    downloaded: p.downloaded,
                                    left: p.left,
                                    event: p.event.as_str(),
                                    numwant: p.numwant,
                                    offers: p.offers.iter().map(|o| OfferWire {
                                        offer_id: o.offer_id,
                                        offer: SdpWire { kind: "offer".into(), sdp: o.sdp.clone() },
                                    }).collect(),
                                };
                                serde_json::to_string(&wire).ok()
                            }
                            Cmd::SendAnswer { info_hash, peer_id, to_peer_id, offer_id, sdp } => {
                                let wire = AnswerWire {
                                    action: "announce",
                                    info_hash,
                                    peer_id,
                                    to_peer_id,
                                    offer_id,
                                    answer: SdpWire { kind: "answer".into(), sdp },
                                };
                                serde_json::to_string(&wire).ok()
                            }
                            Cmd::Shutdown => {
                                let _ = sink.send(Message::Close(None)).await;
                                break;
                            }
                        };
                        let Some(text) = text else { continue };
                        if sink.send(Message::Text(text.into())).await.is_err() {
                            break;
                        }
                    }
                    msg = stream.next() => {
                        match msg {
                            Some(Ok(Message::Text(text))) => {
                                if let Some(evt) = parse_event(text.as_str()) {
                                    if evt_tx.send(evt).await.is_err() { break; }
                                }
                            }
                            Some(Ok(Message::Ping(p))) => {
                                let _ = sink.send(Message::Pong(p)).await;
                            }
                            Some(Ok(Message::Close(_))) | Some(Err(_)) | None => {
                                let _ = evt_tx.send(TrackerEvent::Closed).await;
                                break;
                            }
                            _ => {}
                        }
                    }
                }
            }
        });

        Ok((Self { cmd_tx }, evt_rx))
    }

    pub async fn announce(&self, params: AnnounceParams) -> Result<(), TrackerError> {
        self.cmd_tx
            .send(Cmd::Announce(params))
            .await
            .map_err(|_| TrackerError::Closed)
    }

    pub async fn send_answer(
        &self,
        info_hash: InfoHash,
        peer_id: PeerId,
        to_peer_id: PeerId,
        offer_id: OfferId,
        sdp: String,
    ) -> Result<(), TrackerError> {
        self.cmd_tx
            .send(Cmd::SendAnswer {
                info_hash,
                peer_id,
                to_peer_id,
                offer_id,
                sdp,
            })
            .await
            .map_err(|_| TrackerError::Closed)
    }

    pub async fn shutdown(self) {
        let _ = self.cmd_tx.send(Cmd::Shutdown).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const INFO_HASH: [u8; 20] = [
        0x08, 0xad, 0xa5, 0xa7, 0xa6, 0x18, 0x3a, 0xae, 0x1e, 0x09, 0xd8, 0x31, 0xdf, 0x67, 0x48,
        0xd5, 0x66, 0x09, 0x5a, 0x10,
    ];

    #[test]
    fn announce_round_trips_binary_fields() {
        let peer_id = *b"-LR0001-abcdefghijkl";
        let offer_id = [0xFFu8; 20];
        let wire = AnnounceWire {
            action: "announce",
            info_hash: INFO_HASH,
            peer_id,
            uploaded: 0,
            downloaded: 0,
            left: 1024,
            event: Some("started"),
            numwant: 50,
            offers: vec![OfferWire {
                offer_id,
                offer: SdpWire {
                    kind: "offer".into(),
                    sdp: "v=0\r\n".into(),
                },
            }],
        };
        let s = serde_json::to_string(&wire).unwrap();
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["action"], "announce");
        assert_eq!(v["event"], "started");
        assert_eq!(v["numwant"], 50);
        assert_eq!(decode_binary_20(v["info_hash"].as_str().unwrap()).unwrap(), INFO_HASH);
        assert_eq!(decode_binary_20(v["peer_id"].as_str().unwrap()).unwrap(), peer_id);
        assert_eq!(
            decode_binary_20(v["offers"][0]["offer_id"].as_str().unwrap()).unwrap(),
            offer_id
        );
        assert_eq!(v["offers"][0]["offer"]["type"], "offer");
    }

    #[test]
    fn parses_stats() {
        let msg = json!({
            "action": "announce",
            "info_hash": encode_binary(&[0u8; 20]),
            "complete": 7,
            "incomplete": 3,
            "interval": 120
        })
        .to_string();
        match parse_event(&msg).unwrap() {
            TrackerEvent::Stats {
                complete,
                incomplete,
                interval,
            } => {
                assert_eq!(complete, 7);
                assert_eq!(incomplete, 3);
                assert_eq!(interval, Duration::from_secs(120));
            }
            _ => panic!("expected Stats"),
        }
    }

    #[test]
    fn parses_peer_offer() {
        let other = [0xCAu8; 20];
        let oid = [0xABu8; 20];
        let msg = json!({
            "action": "announce",
            "info_hash": encode_binary(&[0u8; 20]),
            "peer_id": encode_binary(&other),
            "offer_id": encode_binary(&oid),
            "offer": { "type": "offer", "sdp": "v=0\r\n" }
        })
        .to_string();
        match parse_event(&msg).unwrap() {
            TrackerEvent::PeerOffer { peer_id, offer_id, sdp } => {
                assert_eq!(peer_id, other);
                assert_eq!(offer_id, oid);
                assert_eq!(sdp, "v=0\r\n");
            }
            _ => panic!("expected PeerOffer"),
        }
    }

    #[test]
    fn parses_peer_answer() {
        let other = [0x42u8; 20];
        let oid = [0x99u8; 20];
        let msg = json!({
            "action": "announce",
            "info_hash": encode_binary(&[0u8; 20]),
            "peer_id": encode_binary(&other),
            "offer_id": encode_binary(&oid),
            "answer": { "type": "answer", "sdp": "v=0\r\nm=app\r\n" }
        })
        .to_string();
        match parse_event(&msg).unwrap() {
            TrackerEvent::PeerAnswer { peer_id, offer_id, sdp } => {
                assert_eq!(peer_id, other);
                assert_eq!(offer_id, oid);
                assert_eq!(sdp, "v=0\r\nm=app\r\n");
            }
            _ => panic!("expected PeerAnswer"),
        }
    }

    #[test]
    fn peer_id_has_lr_prefix() {
        let id = generate_peer_id();
        assert_eq!(&id[..8], b"-LR0001-");
    }

    // Live network smoke test. Run with: cargo test --release -- --ignored
    #[tokio::test(flavor = "current_thread")]
    #[ignore]
    async fn smoke_announce_to_openwebtorrent() {
        let (client, mut events) = TrackerClient::connect("wss://tracker.openwebtorrent.com")
            .await
            .expect("connect");
        client
            .announce(AnnounceParams {
                info_hash: INFO_HASH,
                peer_id: generate_peer_id(),
                uploaded: 0,
                downloaded: 0,
                left: 0,
                event: AnnounceEvent::Started,
                offers: vec![OutgoingOffer {
                    offer_id: generate_offer_id(),
                    sdp: "v=0\r\n".into(),
                }],
                numwant: 5,
            })
            .await
            .expect("announce");
        let evt = tokio::time::timeout(Duration::from_secs(10), events.recv())
            .await
            .expect("timeout")
            .expect("event");
        eprintln!("first event: {evt:?}");
        client.shutdown().await;
    }
}
