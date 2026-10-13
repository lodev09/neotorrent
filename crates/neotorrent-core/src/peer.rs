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
//!
//! Every type here owns its `RTCPeerConnection` and closes it on drop.

use std::ops::Deref;
use std::sync::Arc;
use std::time::Duration;

use thiserror::Error;
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio::time::timeout;
use webrtc::api::setting_engine::SettingEngine;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice::mdns::MulticastDnsMode;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;

pub const DEFAULT_ICE_SERVERS: &[&str] = &[
    "stun:stun.l.google.com:19302",
    "stun:global.stun.twilio.com:3478",
];

/// How long to wait for the data channel to open once signaling is done.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Error)]
pub enum PeerError {
    #[error("webrtc: {0}")]
    WebRtc(String),
    #[error("peer closed before data channel opened")]
    Closed,
    #[error("timed out waiting for data channel to open")]
    Timeout,
}

impl From<webrtc::Error> for PeerError {
    fn from(e: webrtc::Error) -> Self {
        Self::WebRtc(e.to_string())
    }
}

#[derive(Clone, Debug)]
pub struct PeerConfig {
    pub ice_servers: Vec<String>,
    /// Advertise host candidates as random `.local` names so LAN IPs never
    /// reach public trackers. Needs working mDNS to connect over the LAN.
    pub hide_local_ips: bool,
}

impl Default for PeerConfig {
    fn default() -> Self {
        Self {
            ice_servers: DEFAULT_ICE_SERVERS.iter().map(|s| s.to_string()).collect(),
            hide_local_ips: true,
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

/// `RTCPeerConnection` has no `Drop`; without an explicit `close()` its ICE,
/// DTLS and SCTP tasks keep running.
struct PcHandle(Arc<RTCPeerConnection>);

impl Deref for PcHandle {
    type Target = RTCPeerConnection;
    fn deref(&self) -> &RTCPeerConnection {
        &self.0
    }
}

impl Drop for PcHandle {
    fn drop(&mut self) {
        let pc = Arc::clone(&self.0);
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            rt.spawn(async move {
                let _ = pc.close().await;
            });
        }
    }
}

/// A connected peer with an open data channel.
pub struct Peer {
    pc: PcHandle,
    dc: Arc<RTCDataChannel>,
    rx: Mutex<mpsc::Receiver<Vec<u8>>>,
}

impl Peer {
    pub async fn send(&self, bytes: &[u8]) -> Result<(), PeerError> {
        self.dc.send(&bytes::Bytes::copy_from_slice(bytes)).await?;
        Ok(())
    }

    /// `None` once the data channel has closed.
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
    pc: PcHandle,
    open_rx: oneshot::Receiver<Arc<RTCDataChannel>>,
    msg_rx: mpsc::Receiver<Vec<u8>>,
}

impl OfferingPeer {
    pub async fn complete(self, answer_sdp: String) -> Result<Peer, PeerError> {
        let desc = RTCSessionDescription::answer(answer_sdp)?;
        self.pc.set_remote_description(desc).await?;
        let dc = await_open(self.open_rx).await?;
        Ok(Peer {
            pc: self.pc,
            dc,
            rx: Mutex::new(self.msg_rx),
        })
    }
}

/// Sent our answer SDP; waiting for the remote side to drive the data channel open.
pub struct AnsweringPeer {
    pc: PcHandle,
    open_rx: oneshot::Receiver<Arc<RTCDataChannel>>,
    msg_rx: mpsc::Receiver<Vec<u8>>,
}

impl AnsweringPeer {
    pub async fn wait_open(self) -> Result<Peer, PeerError> {
        let dc = await_open(self.open_rx).await?;
        Ok(Peer {
            pc: self.pc,
            dc,
            rx: Mutex::new(self.msg_rx),
        })
    }
}

async fn await_open(
    open_rx: oneshot::Receiver<Arc<RTCDataChannel>>,
) -> Result<Arc<RTCDataChannel>, PeerError> {
    timeout(CONNECT_TIMEOUT, open_rx)
        .await
        .map_err(|_| PeerError::Timeout)?
        .map_err(|_| PeerError::Closed)
}

fn new_peer_connection(
    config: &PeerConfig,
) -> impl std::future::Future<Output = Result<PcHandle, PeerError>> + use<> {
    let cfg = rtc_config(config);
    let hide_local_ips = config.hide_local_ips;
    async move {
        let mut settings = SettingEngine::default();
        if hide_local_ips {
            settings.set_ice_multicast_dns_mode(MulticastDnsMode::QueryAndGather);
        }
        let api = APIBuilder::new().with_setting_engine(settings).build();
        let pc = api.new_peer_connection(cfg).await?;
        Ok(PcHandle(Arc::new(pc)))
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
    // Dropping the sender on close is what lets `Peer::recv` return `None`.
    let msg_tx = Arc::new(std::sync::Mutex::new(Some(msg_tx)));
    let msg_tx_on_close = Arc::clone(&msg_tx);
    dc.on_message(Box::new(move |msg| {
        let tx = msg_tx.lock().unwrap().clone();
        Box::pin(async move {
            if let Some(tx) = tx {
                let _ = tx.send(msg.data.to_vec()).await;
            }
        })
    }));
    dc.on_close(Box::new(move || {
        msg_tx_on_close.lock().unwrap().take();
        Box::pin(async {})
    }));
}

/// Build an outgoing peer: create a data channel, generate an offer SDP, return
/// the SDP and an [OfferingPeer] that will complete the connection once the
/// remote answer SDP comes back via the tracker.
pub async fn create_offer(config: PeerConfig) -> Result<(String, OfferingPeer), PeerError> {
    let pc = new_peer_connection(&config).await?;

    let dc = pc
        .create_data_channel(
            "neotorrent",
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

    Ok((
        sdp,
        OfferingPeer {
            pc,
            open_rx,
            msg_rx,
        },
    ))
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

    // Only the first data channel feeds `msg_rx`; extra ones would interleave
    // frames into the same stream, so they're closed. webrtc-rs fires this
    // callback before the channel is attached, so close on open instead.
    let slot = Arc::new(Mutex::new(Some((open_tx, msg_tx))));
    pc.on_data_channel(Box::new(move |dc| {
        let slot = Arc::clone(&slot);
        Box::pin(async move {
            match slot.lock().await.take() {
                Some((open_tx, msg_tx)) => wire_data_channel(&dc, open_tx, msg_tx),
                None => {
                    let extra = Arc::clone(&dc);
                    dc.on_open(Box::new(move || {
                        Box::pin(async move {
                            let _ = extra.close().await;
                        })
                    }));
                }
            }
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

    Ok((
        sdp,
        AnsweringPeer {
            pc,
            open_rx,
            msg_rx,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Loopback connections can't rely on mDNS (unavailable on CI runners).
    fn loopback_config() -> PeerConfig {
        PeerConfig {
            hide_local_ips: false,
            ..PeerConfig::default()
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn default_config_hides_host_ips() {
        let (offer_sdp, _offering) = create_offer(PeerConfig::default()).await.expect("offer");
        for line in offer_sdp.lines().filter(|l| l.contains("typ host")) {
            assert!(line.contains(".local"), "host candidate leaks IP: {line}");
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn local_offer_answer_roundtrip() {
        let config = loopback_config();

        let (offer_sdp, offering) = create_offer(config.clone()).await.expect("offer");
        let (answer_sdp, answering) = answer_offer(offer_sdp, config.clone())
            .await
            .expect("answer");

        let (peer_a, peer_b) =
            tokio::try_join!(offering.complete(answer_sdp), answering.wait_open(),)
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
        let after_close = timeout(Duration::from_secs(5), peer_b.recv())
            .await
            .expect("b should see close");
        assert_eq!(after_close, None);
        peer_b.close().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn answering_side_closes_extra_data_channels() {
        let config = loopback_config();
        let pc = new_peer_connection(&config).await.expect("pc");
        let init = || {
            Some(RTCDataChannelInit {
                ordered: Some(true),
                ..Default::default()
            })
        };
        let main = pc
            .create_data_channel("main", init())
            .await
            .expect("main dc");
        let extra = pc
            .create_data_channel("extra", init())
            .await
            .expect("extra dc");

        let (open_tx, open_rx) = oneshot::channel();
        let (msg_tx, msg_rx) = mpsc::channel(256);
        wire_data_channel(&main, open_tx, msg_tx);
        let (extra_open_tx, _extra_open_rx) = oneshot::channel();
        let (extra_msg_tx, mut extra_msg_rx) = mpsc::channel(1);
        wire_data_channel(&extra, extra_open_tx, extra_msg_tx);

        let offer = pc.create_offer(None).await.expect("offer");
        pc.set_local_description(offer).await.expect("local desc");
        let _ = pc.gathering_complete_promise().await.recv().await;
        let offer_sdp = pc.local_description().await.expect("sdp").sdp;
        let offering = OfferingPeer {
            pc,
            open_rx,
            msg_rx,
        };

        let (answer_sdp, answering) = answer_offer(offer_sdp, config).await.expect("answer");
        let (peer_a, peer_b) =
            tokio::try_join!(offering.complete(answer_sdp), answering.wait_open(),)
                .expect("connect");

        let extra_closed = timeout(Duration::from_secs(5), extra_msg_rx.recv())
            .await
            .expect("extra channel should be closed by answerer");
        assert_eq!(extra_closed, None);

        peer_a.send(b"main").await.expect("send");
        let got = timeout(Duration::from_secs(5), peer_b.recv())
            .await
            .expect("recv timeout")
            .expect("recv closed");
        assert_eq!(got, b"main");

        peer_a.close().await;
        peer_b.close().await;
    }
}
