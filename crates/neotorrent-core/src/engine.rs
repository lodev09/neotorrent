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
//!
//! Every tracker task (and through it, every peer task) is owned by the
//! `fetch_metadata` future, so they are all aborted when it returns or is dropped.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use bytes::BytesMut;
use thiserror::Error;
use tokio::sync::{mpsc, watch, Mutex, Semaphore};
use tokio::task::JoinSet;

use crate::extension::{
    ExtendedHandshake, ExtensionError, InfoDict, MetadataAssembler, UtMetadataMessage,
    OUR_UT_METADATA_ID,
};
use crate::magnet::{InfoHash, MagnetLink, DEFAULT_WS_TRACKERS};
use crate::peer::{answer_offer, create_offer, OfferingPeer, Peer, PeerConfig, PeerError};
use crate::tracker::{
    generate_offer_id, generate_peer_id, AnnounceEvent, AnnounceParams, OfferId, OutgoingOffer,
    PeerId, TrackerClient, TrackerError, TrackerEvent,
};
use crate::wire::{Handshake, Message, MessageDecoder, Reserved, WireError, HANDSHAKE_LEN};

/// How many WebRTC offers we generate (shared across all trackers).
const NUM_OFFERS: usize = 5;

/// Max incoming offers we answer concurrently, across all trackers.
const MAX_ANSWERING_PEERS: usize = 20;

/// How long tracker tasks get to send `stopped` before being aborted.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);

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
    #[error("every tracker and peer gave up before metadata arrived")]
    Exhausted,
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

/// State shared by every tracker task of one fetch.
struct Swarm {
    info_hash: InfoHash,
    our_peer_id: PeerId,
    peer_config: PeerConfig,
    outgoing_offers: Vec<OutgoingOffer>,
    offer_pool: Mutex<HashMap<OfferId, OfferingPeer>>,
    answer_slots: Arc<Semaphore>,
}

/// Fetch the info dict for a magnet URI by talking to WebRTC peers via all
/// available WS trackers in parallel.
pub async fn fetch_metadata(
    magnet: &MagnetLink,
    overall_timeout: Duration,
) -> Result<InfoDict, EngineError> {
    fetch_from(resolve_trackers(magnet), magnet.info_hash, overall_timeout).await
}

async fn fetch_from(
    tracker_urls: Vec<String>,
    info_hash: InfoHash,
    overall_timeout: Duration,
) -> Result<InfoDict, EngineError> {
    if tracker_urls.is_empty() {
        return Err(EngineError::NoTracker);
    }

    let peer_config = PeerConfig::default();

    // Generate N offers once; share across trackers.
    let offer_futs = (0..NUM_OFFERS).map(|_| create_offer(peer_config.clone()));
    let offerings = futures_util::future::try_join_all(offer_futs).await?;
    let mut offer_pool = HashMap::with_capacity(NUM_OFFERS);
    let mut outgoing_offers = Vec::with_capacity(NUM_OFFERS);
    for (sdp, offering) in offerings {
        let offer_id = generate_offer_id();
        offer_pool.insert(offer_id, offering);
        outgoing_offers.push(OutgoingOffer { offer_id, sdp });
    }

    let swarm = Arc::new(Swarm {
        info_hash,
        our_peer_id: generate_peer_id(),
        peer_config,
        outgoing_offers,
        offer_pool: Mutex::new(offer_pool),
        answer_slots: Arc::new(Semaphore::new(MAX_ANSWERING_PEERS)),
    });

    let (meta_tx, mut meta_rx) = mpsc::channel::<InfoDict>(1);
    let (cancel_tx, cancel_rx) = watch::channel(false);

    let mut trackers = JoinSet::new();
    for url in tracker_urls {
        trackers.spawn(run_tracker(
            url,
            Arc::clone(&swarm),
            meta_tx.clone(),
            cancel_rx.clone(),
        ));
    }
    // Only tasks hold senders now, so `recv` yields `None` once they all give up.
    drop(meta_tx);

    let result = tokio::time::timeout(overall_timeout, meta_rx.recv()).await;
    let _ = cancel_tx.send(true);
    let _ = tokio::time::timeout(SHUTDOWN_GRACE, async {
        while trackers.join_next().await.is_some() {}
    })
    .await;

    match result {
        Ok(Some(info)) => Ok(info),
        Ok(None) => Err(EngineError::Exhausted),
        Err(_) => Err(EngineError::Timeout),
    }
}

async fn wait_cancel(cancel: &mut watch::Receiver<bool>) {
    let _ = cancel.wait_for(|c| *c).await;
}

/// Drives one tracker connection and owns the peer tasks it spawns.
async fn run_tracker(
    url: String,
    swarm: Arc<Swarm>,
    meta_tx: mpsc::Sender<InfoDict>,
    mut cancel: watch::Receiver<bool>,
) {
    let connected = tokio::select! {
        _ = wait_cancel(&mut cancel) => return,
        r = TrackerClient::connect(&url) => r,
    };
    let Ok((tracker, mut events)) = connected else {
        return;
    };
    let tracker = Arc::new(tracker);

    let mut announce = AnnounceParams {
        info_hash: swarm.info_hash,
        peer_id: swarm.our_peer_id,
        uploaded: 0,
        downloaded: 0,
        left: None,
        event: AnnounceEvent::Started,
        offers: swarm.outgoing_offers.clone(),
        numwant: (NUM_OFFERS as u32) * 2,
    };
    if tracker.announce(announce.clone()).await.is_err() {
        return;
    }

    let mut peers = JoinSet::new();
    let cancelled = loop {
        tokio::select! {
            _ = wait_cancel(&mut cancel) => break true,
            Some(_) = peers.join_next() => {}
            evt = events.recv() => match evt {
                Some(TrackerEvent::PeerAnswer { offer_id, sdp, .. }) => {
                    let Some(offering) = swarm.offer_pool.lock().await.remove(&offer_id) else {
                        continue;
                    };
                    let swarm = Arc::clone(&swarm);
                    let meta_tx = meta_tx.clone();
                    peers.spawn(async move {
                        if let Ok(peer) = offering.complete(sdp).await {
                            let _ = run_peer(peer, swarm.info_hash, swarm.our_peer_id, meta_tx).await;
                        }
                    });
                }
                Some(TrackerEvent::PeerOffer { peer_id: their_id, offer_id, sdp }) => {
                    let Ok(permit) = Arc::clone(&swarm.answer_slots).try_acquire_owned() else {
                        continue;
                    };
                    let tracker = Arc::clone(&tracker);
                    let swarm = Arc::clone(&swarm);
                    let meta_tx = meta_tx.clone();
                    peers.spawn(async move {
                        let _permit = permit;
                        let Ok((answer_sdp, answering)) =
                            answer_offer(sdp, swarm.peer_config.clone()).await
                        else {
                            return;
                        };
                        if tracker
                            .send_answer(swarm.info_hash, swarm.our_peer_id, their_id, offer_id, answer_sdp)
                            .await
                            .is_err()
                        {
                            return;
                        }
                        let Ok(peer) = answering.wait_open().await else { return };
                        let _ = run_peer(peer, swarm.info_hash, swarm.our_peer_id, meta_tx).await;
                    });
                }
                Some(TrackerEvent::Stats { .. }) => {}
                Some(TrackerEvent::Closed) | None => break false,
            },
        }
    };

    if cancelled {
        announce.event = AnnounceEvent::Stopped;
        announce.offers.clear();
        let _ = tracker.announce(announce).await;
        tracker.shutdown().await;
    } else {
        // Tracker is gone; let already-connected peers finish.
        tokio::select! {
            _ = wait_cancel(&mut cancel) => {}
            _ = async { while peers.join_next().await.is_some() {} } => {}
        }
    }
}

/// Pieces to request after an extended handshake. A repeat handshake with the
/// same `metadata_size` keeps the in-progress assembly and requests nothing.
fn start_assembly(
    assembler: &mut Option<MetadataAssembler>,
    size: u64,
    info_hash: InfoHash,
) -> Result<Vec<u32>, ExtensionError> {
    if assembler.as_ref().is_some_and(|a| a.total_size() == size) {
        return Ok(Vec::new());
    }
    let asm = MetadataAssembler::new(size, info_hash)?;
    let missing = asm.missing_pieces().collect();
    *assembler = Some(asm);
    Ok(missing)
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
    send_message(
        &peer,
        Message::Extended {
            ext_id: 0,
            payload: our_ext,
        },
    )
    .await?;

    let mut assembler: Option<MetadataAssembler> = None;

    loop {
        while let Some(msg) = decoder.pop()? {
            match msg {
                Message::Extended { ext_id: 0, payload } => {
                    let their_ext = ExtendedHandshake::decode(&payload)?;
                    match (their_ext.ut_metadata_id(), their_ext.metadata_size) {
                        (Some(ut_id), Some(size)) => {
                            for piece in start_assembly(&mut assembler, size, info_hash)? {
                                let req = UtMetadataMessage::Request { piece };
                                send_message(
                                    &peer,
                                    Message::Extended {
                                        ext_id: ut_id,
                                        payload: req.encode()?,
                                    },
                                )
                                .await?;
                            }
                        }
                        _ if assembler.is_some() => {}
                        _ => return Ok(()),
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
    use crate::extension::METADATA_PIECE_SIZE;
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
        let m = MagnetLink::parse("magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10")
            .unwrap();
        let trackers = resolve_trackers(&m);
        assert_eq!(
            trackers,
            DEFAULT_WS_TRACKERS
                .iter()
                .map(|s| s.to_string())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn repeat_handshake_keeps_assembly_unless_size_changes() {
        let mut asm = None;
        assert_eq!(
            start_assembly(&mut asm, 20_000, [0; 20]).unwrap(),
            vec![0, 1]
        );
        asm.as_mut()
            .unwrap()
            .record(0, vec![0; METADATA_PIECE_SIZE])
            .unwrap();

        assert!(start_assembly(&mut asm, 20_000, [0; 20])
            .unwrap()
            .is_empty());
        assert_eq!(
            asm.as_ref().unwrap().missing_pieces().collect::<Vec<_>>(),
            vec![1]
        );

        assert_eq!(
            start_assembly(&mut asm, 40_000, [0; 20]).unwrap(),
            vec![0, 1, 2]
        );
        assert_eq!(asm.as_ref().unwrap().total_size(), 40_000);
    }

    #[test]
    fn start_assembly_rejects_bad_size() {
        let mut asm = None;
        assert!(start_assembly(&mut asm, 0, [0; 20]).is_err());
        assert!(start_assembly(&mut asm, u64::MAX, [0; 20]).is_err());
        assert!(asm.is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn fails_fast_when_every_tracker_fails() {
        let started = std::time::Instant::now();
        let result = fetch_from(
            vec!["ws://127.0.0.1:1".into(), "not a url".into()],
            [0; 20],
            Duration::from_secs(120),
        )
        .await;
        assert!(matches!(result, Err(EngineError::Exhausted)), "{result:?}");
        assert!(started.elapsed() < Duration::from_secs(60));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore]
    async fn smoke_fetch_sintel_metadata() {
        let m = MagnetLink::parse(
            "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=wss%3A%2F%2Ftracker.openwebtorrent.com&tr=wss%3A%2F%2Ftracker.btorrent.xyz",
        )
        .unwrap();
        let info = fetch_metadata(&m, Duration::from_secs(45))
            .await
            .expect("fetch Sintel metadata");
        assert_eq!(info.name, "Sintel");
        assert!(info.is_multi_file());
        assert!(info.num_pieces() > 0);
        assert!(info.total_size() > 0);
    }
}
