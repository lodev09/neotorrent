//! Engine: orchestrates trackers + peers + wire protocol to drive a magnet URI
//! through to an assembled info dict (metadata).
//!
//! Flow:
//!   1. Connect to all WS trackers (magnet's + WebTorrent defaults) in parallel.
//!   2. Generate N WebRTC offers once. The same offer pool is shared across all
//!      trackers — any tracker can deliver an answer for any of our offers,
//!      first answer wins per offer.
//!   3. Announce our offers to every tracker.
//!   4. As trackers report peer answers, complete the matching offers → peers.
//!   5. As trackers report incoming peer offers, answer them, send the answer
//!      back through the same tracker, await data-channel open → peers.
//!   6. Per peer: BT handshake → extended handshake → request ut_metadata
//!      pieces → assemble + verify info dict.
//!   7. First peer to deliver complete + valid metadata wins.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use bytes::BytesMut;
use thiserror::Error;
use tokio::sync::{mpsc, oneshot, Mutex};

use crate::extension::{
    ExtendedHandshake, ExtensionError, InfoDict, MetadataAssembler, UtMetadataMessage,
    OUR_UT_METADATA_ID,
};
use crate::magnet::{InfoHash, MagnetLink};
use crate::peer::{answer_offer, create_offer, OfferingPeer, Peer, PeerConfig, PeerError};
use crate::tracker::{
    generate_offer_id, generate_peer_id, AnnounceEvent, AnnounceParams, OfferId, OutgoingOffer,
    PeerId, TrackerClient, TrackerError, TrackerEvent,
};
use crate::wire::{Handshake, Message, MessageDecoder, Reserved, WireError, HANDSHAKE_LEN};

/// Default WebSocket trackers WebTorrent JS uses. We always announce to these
/// in addition to whatever's in the magnet so peer discovery actually works
/// for magnets that ship with one (or zero) WS trackers.
pub const DEFAULT_WS_TRACKERS: &[&str] = &[
    "wss://tracker.openwebtorrent.com",
    "wss://tracker.btorrent.xyz",
];

/// How many WebRTC offers we generate (shared across all trackers).
const NUM_OFFERS: usize = 5;

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("no WebSocket tracker available (magnet has none and defaults failed)")]
    NoTracker,
    #[error("tracker: {0}")]
    Tracker(#[from] TrackerError),
    #[error("peer: {0}")]
    Peer(#[from] PeerError),
    #[error("wire: {0}")]
    Wire(#[from] WireError),
    #[error("extension: {0}")]
    Extension(#[from] ExtensionError),
    #[error("info_hash mismatch")]
    InfoHashMismatch,
    #[error("peer does not support extension protocol")]
    NoExtensionProtocol,
    #[error("peer closed before metadata was complete")]
    PeerClosed,
    #[error("no peer delivered metadata in time")]
    Timeout,
}

/// Merge magnet's WS trackers with WebTorrent defaults, deduplicated, preserving
/// magnet order first.
fn resolve_trackers(magnet: &MagnetLink) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for t in magnet.ws_trackers() {
        if seen.insert(t.to_string()) {
            out.push(t.to_string());
        }
    }
    for t in DEFAULT_WS_TRACKERS {
        if seen.insert(t.to_string()) {
            out.push(t.to_string());
        }
    }
    out
}

/// Fetch the info dict for a magnet URI by talking to WebRTC peers via all
/// available WS trackers in parallel.
pub async fn fetch_metadata(
    magnet: &MagnetLink,
    overall_timeout: Duration,
) -> Result<InfoDict, EngineError> {
    let tracker_urls = resolve_trackers(magnet);
    if tracker_urls.is_empty() {
        return Err(EngineError::NoTracker);
    }

    let info_hash = magnet.info_hash;
    let our_peer_id = generate_peer_id();
    let peer_config = PeerConfig::default();

    // Generate N offers once; share across trackers.
    let offer_futs = (0..NUM_OFFERS).map(|_| create_offer(peer_config.clone()));
    let offerings = futures_util::future::try_join_all(offer_futs).await?;
    let offer_pool: Arc<Mutex<HashMap<OfferId, OfferingPeer>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let mut outgoing_offers = Vec::with_capacity(NUM_OFFERS);
    {
        let mut pool = offer_pool.lock().await;
        for (sdp, offering) in offerings {
            let offer_id = generate_offer_id();
            pool.insert(offer_id, offering);
            outgoing_offers.push(OutgoingOffer { offer_id, sdp });
        }
    }

    let (meta_tx, meta_rx) = mpsc::channel::<InfoDict>(1);
    let (cancel_tx, _cancel_rx_drop) = oneshot::channel::<()>();
    let cancel = Arc::new(tokio::sync::Notify::new());

    // Spin up each tracker concurrently. Each that connects gets its own task
    // that drives its event loop and feeds into the shared offer pool.
    for url in tracker_urls {
        let cancel = Arc::clone(&cancel);
        let offer_pool = Arc::clone(&offer_pool);
        let outgoing_offers = outgoing_offers.clone();
        let peer_config = peer_config.clone();
        let meta_tx = meta_tx.clone();
        tokio::spawn(async move {
            let Ok((tracker, mut events)) = TrackerClient::connect(&url).await else { return };
            let tracker = Arc::new(tracker);
            if tracker
                .announce(AnnounceParams {
                    info_hash,
                    peer_id: our_peer_id,
                    uploaded: 0,
                    downloaded: 0,
                    left: 0,
                    event: AnnounceEvent::Started,
                    offers: outgoing_offers,
                    numwant: (NUM_OFFERS as u32) * 2,
                })
                .await
                .is_err()
            {
                return;
            }

            loop {
                tokio::select! {
                    _ = cancel.notified() => break,
                    evt = events.recv() => {
                        let Some(evt) = evt else { break };
                        match evt {
                            TrackerEvent::PeerAnswer { offer_id, sdp, .. } => {
                                let offering = offer_pool.lock().await.remove(&offer_id);
                                if let Some(offering) = offering {
                                    let meta_tx = meta_tx.clone();
                                    tokio::spawn(async move {
                                        if let Ok(peer) = offering.complete(sdp).await {
                                            let _ = run_peer(peer, info_hash, our_peer_id, meta_tx).await;
                                        }
                                    });
                                }
                            }
                            TrackerEvent::PeerOffer { peer_id: their_id, offer_id, sdp } => {
                                let tracker = Arc::clone(&tracker);
                                let meta_tx = meta_tx.clone();
                                let cfg = peer_config.clone();
                                tokio::spawn(async move {
                                    let Ok((answer_sdp, answering)) = answer_offer(sdp, cfg).await else { return };
                                    let _ = tracker
                                        .send_answer(info_hash, our_peer_id, their_id, offer_id, answer_sdp)
                                        .await;
                                    let Ok(peer) = answering.wait_open().await else { return };
                                    let _ = run_peer(peer, info_hash, our_peer_id, meta_tx).await;
                                });
                            }
                            TrackerEvent::Closed => break,
                            TrackerEvent::Stats { .. } => {}
                        }
                    }
                }
            }
        });
    }

    let mut meta_rx = meta_rx;
    let result = tokio::time::timeout(overall_timeout, meta_rx.recv()).await;
    cancel.notify_waiters();
    let _ = cancel_tx.send(());
    match result {
        Ok(Some(info)) => Ok(info),
        Ok(None) => Err(EngineError::PeerClosed),
        Err(_) => Err(EngineError::Timeout),
    }
}

/// Per-peer protocol: BT handshake → extended handshake → ut_metadata.
async fn run_peer(
    peer: Peer,
    info_hash: InfoHash,
    our_peer_id: PeerId,
    meta_tx: mpsc::Sender<InfoDict>,
) -> Result<(), EngineError> {
    let hs = Handshake {
        reserved: Reserved::with_extension_protocol(),
        info_hash,
        peer_id: our_peer_id,
    };
    peer.send(&hs.encode()).await?;

    let mut prelude = BytesMut::new();
    let their_hs = loop {
        let chunk = peer.recv().await.ok_or(EngineError::PeerClosed)?;
        prelude.extend_from_slice(&chunk);
        if prelude.len() >= HANDSHAKE_LEN {
            break Handshake::decode(&prelude[..HANDSHAKE_LEN])?;
        }
    };
    if their_hs.info_hash != info_hash {
        return Err(EngineError::InfoHashMismatch);
    }
    if !their_hs.reserved.supports_extension_protocol() {
        return Err(EngineError::NoExtensionProtocol);
    }

    let mut decoder = MessageDecoder::default();
    decoder.push(&prelude[HANDSHAKE_LEN..]);

    let our_ext = ExtendedHandshake::ours().encode()?;
    send_message(&peer, Message::Extended { ext_id: 0, payload: our_ext }).await?;

    let mut assembler: Option<MetadataAssembler> = None;

    loop {
        while let Some(msg) = decoder.pop()? {
            match msg {
                Message::Extended { ext_id: 0, payload } => {
                    let their_ext = ExtendedHandshake::decode(&payload)?;
                    if let (Some(ut_id), Some(size)) =
                        (their_ext.ut_metadata_id(), their_ext.metadata_size)
                    {
                        if size == 0 {
                            return Ok(());
                        }
                        let asm = MetadataAssembler::new(size, info_hash);
                        let missing: Vec<u32> = asm.missing_pieces().collect();
                        assembler = Some(asm);
                        for piece in missing {
                            let req = UtMetadataMessage::Request { piece };
                            send_message(
                                &peer,
                                Message::Extended { ext_id: ut_id, payload: req.encode()? },
                            )
                            .await?;
                        }
                    } else {
                        return Ok(());
                    }
                }
                Message::Extended { ext_id, payload } if ext_id == OUR_UT_METADATA_ID => {
                    let ut = UtMetadataMessage::decode(&payload)?;
                    if let UtMetadataMessage::Data { piece, data, .. } = ut {
                        if let Some(asm) = assembler.as_mut() {
                            if let Some(info_bytes) = asm.record(piece, data)? {
                                let info = InfoDict::parse(&info_bytes)?;
                                let _ = meta_tx.try_send(info);
                                return Ok(());
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        let chunk = peer.recv().await.ok_or(EngineError::PeerClosed)?;
        decoder.push(&chunk);
    }
}

async fn send_message(peer: &Peer, msg: Message) -> Result<(), EngineError> {
    let mut buf = Vec::new();
    msg.encode(&mut buf);
    peer.send(&buf).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::magnet::MagnetLink;

    #[test]
    fn resolve_trackers_dedupes_and_includes_defaults() {
        let m = MagnetLink::parse(
            "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&tr=wss%3A%2F%2Ftracker.openwebtorrent.com",
        )
        .unwrap();
        let trackers = resolve_trackers(&m);
        // The duplicate openwebtorrent (from magnet) and default isn't repeated.
        assert_eq!(trackers.len(), 2);
        assert_eq!(trackers[0], "wss://tracker.openwebtorrent.com");
        assert!(trackers.contains(&"wss://tracker.btorrent.xyz".to_string()));
    }

    #[test]
    fn resolve_trackers_falls_back_to_defaults() {
        let m = MagnetLink::parse(
            "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10",
        )
        .unwrap();
        let trackers = resolve_trackers(&m);
        assert_eq!(
            trackers,
            DEFAULT_WS_TRACKERS.iter().map(|s| s.to_string()).collect::<Vec<_>>()
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore]
    async fn smoke_fetch_sintel_metadata() {
        let m = MagnetLink::parse(
            "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=wss%3A%2F%2Ftracker.openwebtorrent.com&tr=wss%3A%2F%2Ftracker.btorrent.xyz",
        )
        .unwrap();
        match fetch_metadata(&m, Duration::from_secs(45)).await {
            Ok(info) => eprintln!(
                "name: {}, size: {} bytes, {} pieces ({} KiB each)",
                info.name,
                info.total_size(),
                info.num_pieces(),
                info.piece_length / 1024
            ),
            Err(e) => eprintln!("fetch failed: {e}"),
        }
    }
}
