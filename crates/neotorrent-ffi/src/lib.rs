uniffi::setup_scaffolding!();

use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};

use neotorrent_core::magnet::{self, MagnetError, MagnetLink};
use neotorrent_core::session::{
    self as core, snapshot, AddedTorrent as CoreAddedTorrent, FileEntry as CoreFileEntry,
    NeoTorrentSession as CoreSession, SessionError, TorrentSnapshot as CoreSnapshot,
    TorrentState as CoreTorrentState,
};
use tokio::runtime::Runtime;
use tokio::task::AbortHandle;

/// All engine work runs here, off the caller's thread. librqbit spawns its
/// peer, hashing and disk tasks onto whatever runtime it's started from.
static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("neotorrent")
        .build()
        .expect("failed to start tokio runtime")
});

async fn run<T: Send + 'static>(
    fut: impl Future<Output = Result<T, NeoTorrentError>> + Send + 'static,
) -> Result<T, NeoTorrentError> {
    RUNTIME
        .spawn(fut)
        .await
        .map_err(|e| NeoTorrentError::Session(e.to_string()))?
}

#[derive(uniffi::Record)]
pub struct ParsedMagnet {
    pub info_hash: String,
    pub display_name: Option<String>,
}

#[derive(uniffi::Enum)]
pub enum TorrentState {
    Initializing,
    Live,
    Paused,
    Error,
}

#[derive(uniffi::Record)]
pub struct TorrentSnapshot {
    pub id: u64,
    pub info_hash: String,
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
    pub state: TorrentState,
    pub error: Option<String>,
}

#[derive(uniffi::Record)]
pub struct TorrentFile {
    pub index: u32,
    pub path: String,
    pub length: u64,
    pub downloaded: u64,
    pub selected: bool,
}

#[derive(uniffi::Record)]
pub struct AddedTorrent {
    pub id: u64,
    /// The torrent was already in the session; nothing new was added.
    pub already_managed: bool,
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

impl From<CoreTorrentState> for TorrentState {
    fn from(s: CoreTorrentState) -> Self {
        match s {
            CoreTorrentState::Initializing => Self::Initializing,
            CoreTorrentState::Live => Self::Live,
            CoreTorrentState::Paused => Self::Paused,
            CoreTorrentState::Error => Self::Error,
        }
    }
}

impl From<CoreSnapshot> for TorrentSnapshot {
    fn from(s: CoreSnapshot) -> Self {
        Self {
            id: s.id,
            info_hash: s.info_hash,
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
            state: s.state.into(),
            error: s.error,
        }
    }
}

impl From<CoreAddedTorrent> for AddedTorrent {
    fn from(a: CoreAddedTorrent) -> Self {
        Self {
            id: a.id,
            already_managed: a.already_managed,
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum NeoTorrentError {
    #[error("invalid magnet: {0}")]
    InvalidMagnet(String),
    #[error("session: {0}")]
    Session(String),
    #[error("cancelled")]
    Cancelled,
}

impl From<MagnetError> for NeoTorrentError {
    fn from(e: MagnetError) -> Self {
        Self::InvalidMagnet(e.to_string())
    }
}

impl From<SessionError> for NeoTorrentError {
    fn from(e: SessionError) -> Self {
        Self::Session(e.to_string())
    }
}

#[uniffi::export]
pub fn parse_magnet(uri: String) -> Result<ParsedMagnet, NeoTorrentError> {
    let link = MagnetLink::parse(&uri)?;
    Ok(ParsedMagnet {
        info_hash: magnet::hex(&link.info_hash),
        display_name: link.display_name,
    })
}

/// Long-lived torrent session backed by librqbit. Singleton held by the app.
#[derive(uniffi::Object)]
pub struct NeoTorrentSession {
    inner: Arc<CoreSession>,
    adds: Mutex<HashMap<String, AbortHandle>>,
}

impl NeoTorrentSession {
    fn adds(&self) -> MutexGuard<'_, HashMap<String, AbortHandle>> {
        self.adds.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[uniffi::export]
impl NeoTorrentSession {
    /// Create a session that downloads into `download_dir` by default and
    /// persists session state (torrent list, DHT, fastresume) into
    /// `state_dir`. Previously-added torrents resume automatically.
    #[uniffi::constructor]
    pub async fn new(
        download_dir: String,
        state_dir: String,
        log_file: String,
    ) -> Result<Arc<Self>, NeoTorrentError> {
        run(async move {
            core::init_logging(Path::new(&log_file));
            let inner = CoreSession::new(download_dir.into(), state_dir.into()).await?;
            Ok(Arc::new(Self {
                inner: Arc::new(inner),
                adds: Mutex::default(),
            }))
        })
        .await
    }

    /// Add a magnet link, http(s) .torrent URL, or local .torrent file (path
    /// or file URL). Magnets resolve metadata before returning. `token`
    /// identifies the add for `cancel_add`; `output_folder` overrides the
    /// session's default download folder.
    pub async fn add_torrent(
        &self,
        uri: String,
        output_folder: Option<String>,
        token: String,
    ) -> Result<AddedTorrent, NeoTorrentError> {
        let inner = self.inner.clone();
        let task =
            RUNTIME.spawn(async move { inner.add(&uri, output_folder.map(PathBuf::from)).await });
        self.adds().insert(token.clone(), task.abort_handle());
        let result = task.await;
        self.adds().remove(&token);
        match result {
            Ok(added) => Ok(added?.into()),
            Err(e) if e.is_cancelled() => Err(NeoTorrentError::Cancelled),
            Err(e) => Err(NeoTorrentError::Session(e.to_string())),
        }
    }

    /// Abort an in-flight `add_torrent`. No-op if it already finished.
    pub fn cancel_add(&self, token: String) {
        if let Some(handle) = self.adds().remove(&token) {
            handle.abort();
        }
    }

    pub async fn pause(&self, id: u64) -> Result<(), NeoTorrentError> {
        let inner = self.inner.clone();
        run(async move { Ok(inner.pause(id).await?) }).await
    }

    pub async fn resume(&self, id: u64) -> Result<(), NeoTorrentError> {
        let inner = self.inner.clone();
        run(async move { Ok(inner.resume(id).await?) }).await
    }

    pub async fn remove(&self, id: u64, delete_files: bool) -> Result<(), NeoTorrentError> {
        let inner = self.inner.clone();
        run(async move { Ok(inner.remove(id, delete_files).await?) }).await
    }

    /// Restrict the torrent to downloading only the given file indices.
    /// Pass all indices (0..n) to undo a selection.
    pub async fn set_only_files(&self, id: u64, indices: Vec<u32>) -> Result<(), NeoTorrentError> {
        let inner = self.inner.clone();
        run(async move { Ok(inner.set_only_files(id, indices).await?) }).await
    }

    /// Stop all torrents and background tasks. Call before the app exits.
    pub async fn shutdown(&self) {
        let inner = self.inner.clone();
        let _ = RUNTIME.spawn(async move { inner.shutdown().await }).await;
    }

    /// Current snapshot of all managed torrents (cheap; safe to poll).
    pub fn list(&self) -> Vec<TorrentSnapshot> {
        self.inner
            .handles()
            .iter()
            .map(|h| snapshot(h).into())
            .collect()
    }

    /// Per-file progress for the torrent. Empty if metadata isn't resolved yet.
    pub fn files(&self, id: u64) -> Result<Vec<TorrentFile>, NeoTorrentError> {
        let files = self.inner.files(id)?;
        Ok(files.into_iter().map(Into::into).collect())
    }

    /// Folder the torrent's files are written into; `TorrentFile.path` is
    /// relative to it.
    pub fn output_folder(&self, id: u64) -> Result<String, NeoTorrentError> {
        let p = self.inner.output_folder(id)?;
        Ok(p.to_string_lossy().into_owned())
    }

    /// HTTP streaming URL for a file. Pieces are fetched on demand by HTTP
    /// byte-range and the server blocks on unavailable bytes.
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
