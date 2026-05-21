uniffi::setup_scaffolding!();

use std::sync::Arc;

use lorrent_core::engine::DEFAULT_WS_TRACKERS;
use lorrent_core::magnet::{self, MagnetError, MagnetLink};
use lorrent_core::session::{
    snapshot, FileEntry as CoreFileEntry, LorrentSession as CoreSession, SessionError,
    TorrentSnapshot as CoreSnapshot,
};

#[derive(uniffi::Record)]
pub struct ParsedMagnet {
    pub info_hash: String,
    pub display_name: Option<String>,
    pub ws_trackers: Vec<String>,
}

#[derive(uniffi::Record)]
pub struct TorrentSnapshot {
    pub id: u64,
    pub name: Option<String>,
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub uploaded_bytes: u64,
    pub progress: f64,
    pub download_bps: u64,
    pub upload_bps: u64,
    pub peers_live: u32,
    pub peers_seen: u32,
    pub is_finished: bool,
    pub state: String,
}

#[derive(uniffi::Record)]
pub struct TorrentFile {
    pub index: u32,
    pub path: String,
    pub length: u64,
    pub downloaded: u64,
    pub selected: bool,
}

impl From<CoreFileEntry> for TorrentFile {
    fn from(f: CoreFileEntry) -> Self {
        Self {
            index: f.index,
            path: f.path,
            length: f.length,
            downloaded: f.downloaded,
            selected: f.selected,
        }
    }
}

impl From<CoreSnapshot> for TorrentSnapshot {
    fn from(s: CoreSnapshot) -> Self {
        Self {
            id: s.id,
            name: s.name,
            total_bytes: s.total_bytes,
            downloaded_bytes: s.downloaded_bytes,
            uploaded_bytes: s.uploaded_bytes,
            progress: s.progress,
            download_bps: s.download_bps,
            upload_bps: s.upload_bps,
            peers_live: s.peers_live,
            peers_seen: s.peers_seen,
            is_finished: s.is_finished,
            state: s.state,
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum LorrentError {
    #[error("invalid magnet: {0}")]
    InvalidMagnet(String),
    #[error("session: {0}")]
    Session(String),
}

impl From<MagnetError> for LorrentError {
    fn from(e: MagnetError) -> Self {
        Self::InvalidMagnet(e.to_string())
    }
}

impl From<SessionError> for LorrentError {
    fn from(e: SessionError) -> Self {
        Self::Session(e.to_string())
    }
}

#[uniffi::export]
pub fn hello_from_rust() -> String {
    lorrent_core::greet()
}

/// Client-side parse + tracker preview (includes WebTorrent defaults).
#[uniffi::export]
pub fn parse_magnet(uri: String) -> Result<ParsedMagnet, LorrentError> {
    let link = MagnetLink::parse(&uri)?;
    let mut seen = std::collections::HashSet::new();
    let mut ws_trackers = Vec::new();
    for t in link.ws_trackers() {
        if seen.insert(t.to_string()) {
            ws_trackers.push(t.to_string());
        }
    }
    for t in DEFAULT_WS_TRACKERS {
        if seen.insert(t.to_string()) {
            ws_trackers.push(t.to_string());
        }
    }
    Ok(ParsedMagnet {
        info_hash: magnet::hex(&link.info_hash),
        display_name: link.display_name,
        ws_trackers,
    })
}

/// Long-lived torrent session backed by librqbit. Singleton held by the app.
#[derive(uniffi::Object)]
pub struct LorrentSession {
    inner: Arc<CoreSession>,
}

#[uniffi::export(async_runtime = "tokio")]
impl LorrentSession {
    /// Create a session that downloads into `download_dir` and persists
    /// session state (torrent list, DHT, fastresume) into `state_dir`.
    /// Previously-added torrents resume automatically on next launch.
    #[uniffi::constructor]
    pub async fn new(download_dir: String, state_dir: String) -> Result<Arc<Self>, LorrentError> {
        let inner = CoreSession::new(download_dir.into(), state_dir.into()).await?;
        Ok(Arc::new(Self { inner: Arc::new(inner) }))
    }

    /// Add a magnet URI. Returns the torrent's session-local ID. librqbit
    /// handles metadata fetch and starts downloading in the background.
    pub async fn add_magnet(&self, uri: String) -> Result<u64, LorrentError> {
        let h = self.inner.add_magnet(&uri).await?;
        Ok(h.id() as u64)
    }

    pub async fn pause(&self, id: u64) -> Result<(), LorrentError> {
        self.inner.pause(id).await?;
        Ok(())
    }

    pub async fn resume(&self, id: u64) -> Result<(), LorrentError> {
        self.inner.resume(id).await?;
        Ok(())
    }

    pub async fn remove(&self, id: u64, delete_files: bool) -> Result<(), LorrentError> {
        self.inner.remove(id, delete_files).await?;
        Ok(())
    }

    /// Restrict the torrent to downloading only the given file indices.
    /// Pass all indices (0..n) to undo a selection.
    pub async fn set_only_files(&self, id: u64, indices: Vec<u32>) -> Result<(), LorrentError> {
        self.inner.set_only_files(id, indices).await?;
        Ok(())
    }
}

#[uniffi::export]
impl LorrentSession {
    /// Current snapshot of all managed torrents (cheap; safe to poll).
    pub fn list(&self) -> Vec<TorrentSnapshot> {
        self.inner
            .handles()
            .iter()
            .map(|h| snapshot(h).into())
            .collect()
    }

    pub fn get(&self, id: u64) -> Result<TorrentSnapshot, LorrentError> {
        let h = self.inner.handle(id)?;
        Ok(snapshot(&h).into())
    }

    /// Per-file progress for the torrent. Empty if metadata isn't resolved yet.
    pub fn files(&self, id: u64) -> Result<Vec<TorrentFile>, LorrentError> {
        let files = self.inner.files(id)?;
        Ok(files.into_iter().map(Into::into).collect())
    }

    /// Filesystem path where the torrent is being written. Use for Reveal in Finder.
    pub fn output_folder(&self, id: u64) -> Result<String, LorrentError> {
        let p = self.inner.output_folder(id)?;
        Ok(p.to_string_lossy().into_owned())
    }

    /// HTTP streaming URL for a file. Point AVPlayer at it; pieces are fetched
    /// on-demand by HTTP byte-range and the server blocks on unavailable bytes.
    pub fn stream_url(&self, id: u64, file_index: u32) -> String {
        format!(
            "http://127.0.0.1:{}/torrents/{}/stream/{}",
            self.inner.streaming_port(),
            id,
            file_index
        )
    }

    /// Session-wide rate limits in bytes/sec. 0 = unlimited.
    pub fn set_rate_limits(&self, download_bps: u32, upload_bps: u32) {
        self.inner.set_rate_limits(download_bps, upload_bps);
    }
}
