//! WebRTC peer transport (webrtc-rs).
//!
//! Two-phase API mirroring the SDP offer/answer dance:
//!
//! Outgoing peer (we initiate):
//!   1. `create_offer` → (offer SDP, [OfferingPeer])
//!   2. Send offer SDP to tracker, receive answer SDP from a remote peer
//!   3. `OfferingPeer::complete(answer_sdp)` → connected [Peer]
//!
//! Incoming peer (remote initiates):
//!   1. Receive offer SDP from tracker
//!   2. `answer_offer(offer_sdp)` → (answer SDP, [AnsweringPeer])
//!   3. Send answer SDP to tracker
//!   4. `AnsweringPeer::wait_open()` → connected [Peer]

use std::sync::Arc;

use thiserror::Error;
use tokio::sync::{mpsc, oneshot, Mutex};
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;

pub const DEFAULT_ICE_SERVERS: &[&str] = &[
    "stun:stun.l.google.com:19302",
    "stun:global.stun.twilio.com:3478",
];

#[derive(Debug, Error)]
pub enum PeerError {
    #[error("webrtc: {0}")]
    WebRtc(String),
    #[error("peer closed before data channel opened")]
    Closed,
}

impl From<webrtc::Error> for PeerError {
    fn from(e: webrtc::Error) -> Self {
        Self::WebRtc(e.to_string())
    }
}

#[derive(Clone, Debug)]
pub struct PeerConfig {
    pub ice_servers: Vec<String>,
}

impl Default for PeerConfig {
    fn default() -> Self {
        Self {
            ice_servers: DEFAULT_ICE_SERVERS.iter().map(|s| s.to_string()).collect(),
        }
    }
}

fn rtc_config(c: &PeerConfig) -> RTCConfiguration {
    RTCConfiguration {
        ice_servers: vec![RTCIceServer {
            urls: c.ice_servers.clone(),
            ..Default::default()
        }],
        ..Default::default()
    }
}

/// A connected peer with an open data channel.
pub struct Peer {
    pc: Arc<RTCPeerConnection>,
    dc: Arc<RTCDataChannel>,
    rx: Mutex<mpsc::Receiver<Vec<u8>>>,
}

impl Peer {
    pub async fn send(&self, bytes: &[u8]) -> Result<(), PeerError> {
        self.dc
            .send(&bytes::Bytes::copy_from_slice(bytes))
            .await?;
        Ok(())
    }

    pub async fn recv(&self) -> Option<Vec<u8>> {
        self.rx.lock().await.recv().await
    }

    pub async fn close(self) {
        let _ = self.dc.close().await;
        let _ = self.pc.close().await;
    }
}

/// Created an offer SDP; waiting for the remote answer SDP.
pub struct OfferingPeer {
    pc: Arc<RTCPeerConnection>,
    open_rx: oneshot::Receiver<Arc<RTCDataChannel>>,
    msg_rx: mpsc::Receiver<Vec<u8>>,
}

impl OfferingPeer {
    pub async fn complete(self, answer_sdp: String) -> Result<Peer, PeerError> {
        let desc = RTCSessionDescription::answer(answer_sdp)?;
        self.pc.set_remote_description(desc).await?;
        let dc = self.open_rx.await.map_err(|_| PeerError::Closed)?;
        Ok(Peer {
            pc: self.pc,
            dc,
            rx: Mutex::new(self.msg_rx),
        })
    }
}

/// Sent our answer SDP; waiting for the remote side to drive the data channel open.
pub struct AnsweringPeer {
    pc: Arc<RTCPeerConnection>,
    open_rx: oneshot::Receiver<Arc<RTCDataChannel>>,
    msg_rx: mpsc::Receiver<Vec<u8>>,
}

impl AnsweringPeer {
    pub async fn wait_open(self) -> Result<Peer, PeerError> {
        let dc = self.open_rx.await.map_err(|_| PeerError::Closed)?;
        Ok(Peer {
            pc: self.pc,
            dc,
            rx: Mutex::new(self.msg_rx),
        })
    }
}

fn new_peer_connection(config: &PeerConfig) -> impl std::future::Future<
    Output = Result<Arc<RTCPeerConnection>, PeerError>,
> + use<> {
    let cfg = rtc_config(config);
    async move {
        let api = APIBuilder::new().build();
        let pc = api.new_peer_connection(cfg).await?;
        Ok(Arc::new(pc))
    }
}

fn wire_data_channel(
    dc: &Arc<RTCDataChannel>,
    open_tx: oneshot::Sender<Arc<RTCDataChannel>>,
    msg_tx: mpsc::Sender<Vec<u8>>,
) {
    let dc_for_open = Arc::clone(dc);
    let open_tx = Arc::new(Mutex::new(Some(open_tx)));
    dc.on_open(Box::new(move || {
        let dc = Arc::clone(&dc_for_open);
        let open_tx = Arc::clone(&open_tx);
        Box::pin(async move {
            if let Some(tx) = open_tx.lock().await.take() {
                let _ = tx.send(dc);
            }
        })
    }));
    dc.on_message(Box::new(move |msg| {
        let tx = msg_tx.clone();
        Box::pin(async move {
            let _ = tx.send(msg.data.to_vec()).await;
        })
    }));
}

/// Build an outgoing peer: create a data channel, generate an offer SDP, return
/// the SDP and an [OfferingPeer] that will complete the connection once the
/// remote answer SDP comes back via the tracker.
pub async fn create_offer(config: PeerConfig) -> Result<(String, OfferingPeer), PeerError> {
    let pc = new_peer_connection(&config).await?;

    let dc = pc
        .create_data_channel(
            "lorrent",
            Some(RTCDataChannelInit {
                ordered: Some(true),
                ..Default::default()
            }),
        )
        .await?;

    let (open_tx, open_rx) = oneshot::channel();
    let (msg_tx, msg_rx) = mpsc::channel(256);
    wire_data_channel(&dc, open_tx, msg_tx);

    let offer = pc.create_offer(None).await?;
    pc.set_local_description(offer).await?;

    // Block until ICE candidates are gathered so the SDP we hand out is complete.
    let mut gather_complete = pc.gathering_complete_promise().await;
    let _ = gather_complete.recv().await;

    let sdp = pc
        .local_description()
        .await
        .ok_or_else(|| PeerError::WebRtc("no local description".into()))?
        .sdp;

    Ok((sdp, OfferingPeer { pc, open_rx, msg_rx }))
}

/// Accept an incoming offer SDP: generate an answer SDP and return an
/// [AnsweringPeer] that will resolve to a connected [Peer] once the remote
/// drives the data channel open.
pub async fn answer_offer(
    offer_sdp: String,
    config: PeerConfig,
) -> Result<(String, AnsweringPeer), PeerError> {
    let pc = new_peer_connection(&config).await?;

    let (open_tx, open_rx) = oneshot::channel();
    let (msg_tx, msg_rx) = mpsc::channel(256);

    let open_tx = Arc::new(Mutex::new(Some(open_tx)));
    let msg_tx_for_cb = msg_tx.clone();
    pc.on_data_channel(Box::new(move |dc| {
        let open_tx = Arc::clone(&open_tx);
        let msg_tx = msg_tx_for_cb.clone();
        Box::pin(async move {
            wire_data_channel(
                &dc,
                {
                    let mut guard = open_tx.lock().await;
                    let (tx, _rx) = oneshot::channel();
                    guard.take().unwrap_or(tx)
                },
                msg_tx,
            );
        })
    }));

    let offer = RTCSessionDescription::offer(offer_sdp)?;
    pc.set_remote_description(offer).await?;
    let answer = pc.create_answer(None).await?;
    pc.set_local_description(answer).await?;

    let mut gather_complete = pc.gathering_complete_promise().await;
    let _ = gather_complete.recv().await;

    let sdp = pc
        .local_description()
        .await
        .ok_or_else(|| PeerError::WebRtc("no local description".into()))?
        .sdp;

    Ok((sdp, AnsweringPeer { pc, open_rx, msg_rx }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::time::timeout;

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn local_offer_answer_roundtrip() {
        let config = PeerConfig::default();

        let (offer_sdp, offering) = create_offer(config.clone()).await.expect("offer");
        let (answer_sdp, answering) =
            answer_offer(offer_sdp, config.clone()).await.expect("answer");

        let (peer_a, peer_b) = tokio::try_join!(
            offering.complete(answer_sdp),
            answering.wait_open(),
        )
        .expect("connect");

        peer_a.send(b"hello from a").await.expect("send a→b");
        peer_b.send(b"hi back from b").await.expect("send b→a");

        let got_b = timeout(Duration::from_secs(5), peer_b.recv())
            .await
            .expect("b recv timeout")
            .expect("b recv channel closed");
        let got_a = timeout(Duration::from_secs(5), peer_a.recv())
            .await
            .expect("a recv timeout")
            .expect("a recv channel closed");

        assert_eq!(got_b, b"hello from a");
        assert_eq!(got_a, b"hi back from b");

        peer_a.close().await;
        peer_b.close().await;
    }
}
