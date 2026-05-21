//! Thin wrapper around `librqbit::Session` exposing only what the Swift UI
//! needs.

use std::path::PathBuf;
use std::sync::Arc;

use librqbit::api::{Api, TorrentIdOrHash};
use librqbit::http_api::HttpApi;
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, ManagedTorrent, Session, SessionOptions,
    SessionPersistenceConfig,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SessionError {
    #[error("session: {0}")]
    Session(String),
    #[error("torrent: {0}")]
    Torrent(String),
    #[error("torrent {0} not found")]
    NotFound(u64),
}

impl From<anyhow::Error> for SessionError {
    fn from(e: anyhow::Error) -> Self {
        Self::Session(e.to_string())
    }
}

pub struct NeoTorrentSession {
    inner: Arc<Session>,
    download_dir: PathBuf,
    streaming_port: u16,
}

impl NeoTorrentSession {
    /// Build a session that:
    /// - Downloads into `download_dir`.
    /// - Persists session state (torrent list, fastresume, DHT) under
    ///   `state_dir`, so torrents resume automatically on next launch.
    pub async fn new(download_dir: PathBuf, state_dir: PathBuf) -> Result<Self, SessionError> {
        std::fs::create_dir_all(&state_dir).ok();
        let opts = SessionOptions {
            fastresume: true,
            persistence: Some(SessionPersistenceConfig::Json {
                folder: Some(state_dir),
            }),
            ..Default::default()
        };
        let inner = Session::new_with_opts(download_dir.clone(), opts).await?;

        // Start librqbit's HTTP streaming API on a random local port. AVPlayer
        // will pull video/audio bytes from `http://127.0.0.1:<port>/torrents/<id>/stream/<file_id>`,
        // which serves HTTP byte-ranges and blocks on not-yet-downloaded pieces.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| SessionError::Session(format!("bind streaming socket: {e}")))?;
        let streaming_port = listener
            .local_addr()
            .map_err(|e| SessionError::Session(format!("local_addr: {e}")))?
            .port();
        let api = Api::new(inner.clone(), None, None);
        let http_api = HttpApi::new(api, None);
        tokio::spawn(http_api.make_http_api_and_run(listener, None));

        Ok(Self {
            inner,
            download_dir,
            streaming_port,
        })
    }

    pub fn streaming_port(&self) -> u16 {
        self.streaming_port
    }

    pub fn download_dir(&self) -> &PathBuf {
        &self.download_dir
    }

    pub async fn add_magnet(&self, uri: &str) -> Result<Arc<ManagedTorrent>, SessionError> {
        let resp = self
            .inner
            .add_torrent(
                AddTorrent::from_url(uri),
                Some(AddTorrentOptions {
                    overwrite: true,
                    ..Default::default()
                }),
            )
            .await?;
        match resp {
            AddTorrentResponse::Added(_, handle)
            | AddTorrentResponse::AlreadyManaged(_, handle) => Ok(handle),
            AddTorrentResponse::ListOnly(_) => {
                Err(SessionError::Torrent("list-only response".into()))
            }
        }
    }

    pub fn handle(&self, id: u64) -> Result<Arc<ManagedTorrent>, SessionError> {
        self.inner
            .get(TorrentIdOrHash::Id(id as usize))
            .ok_or(SessionError::NotFound(id))
    }

    pub fn handles(&self) -> Vec<Arc<ManagedTorrent>> {
        self.inner
            .with_torrents(|iter| iter.map(|(_, h)| h.clone()).collect())
    }

    pub async fn pause(&self, id: u64) -> Result<(), SessionError> {
        let h = self.handle(id)?;
        self.inner.pause(&h).await?;
        Ok(())
    }

    pub async fn resume(&self, id: u64) -> Result<(), SessionError> {
        let h = self.handle(id)?;
        self.inner.unpause(&h).await?;
        Ok(())
    }

    pub async fn remove(&self, id: u64, delete_files: bool) -> Result<(), SessionError> {
        self.inner
            .delete(TorrentIdOrHash::Id(id as usize), delete_files)
            .await?;
        Ok(())
    }

    /// Per-torrent output folder (`<download_dir>/<torrent_name>`). The torrent
    /// name is only known after metadata resolves; before that, we return the
    /// session-wide download directory.
    pub fn output_folder(&self, id: u64) -> Result<PathBuf, SessionError> {
        let h = self.handle(id)?;
        Ok(match h.name() {
            Some(name) => self.download_dir.join(name),
            None => self.download_dir.clone(),
        })
    }

    pub fn files(&self, id: u64) -> Result<Vec<FileEntry>, SessionError> {
        let h = self.handle(id)?;
        let progress = h.stats().file_progress;
        // None ⇒ all files selected; Some(set) ⇒ only those.
        let only: Option<std::collections::HashSet<usize>> =
            h.only_files().map(|v| v.into_iter().collect());
        let result = h.with_metadata(|m| {
            m.file_infos
                .iter()
                .enumerate()
                .map(|(i, fi)| FileEntry {
                    index: i as u32,
                    path: fi.relative_filename.to_string_lossy().into_owned(),
                    length: fi.len,
                    downloaded: progress.get(i).copied().unwrap_or(0),
                    selected: only.as_ref().map_or(true, |s| s.contains(&i)),
                })
                .collect::<Vec<_>>()
        });
        match result {
            Ok(files) => Ok(files),
            // Metadata not yet resolved — return empty list rather than erroring.
            Err(_) => Ok(Vec::new()),
        }
    }

    pub async fn set_only_files(
        &self,
        id: u64,
        indices: Vec<u32>,
    ) -> Result<(), SessionError> {
        let h = self.handle(id)?;
        let set: std::collections::HashSet<usize> =
            indices.into_iter().map(|i| i as usize).collect();
        self.inner.update_only_files(&h, &set).await?;
        Ok(())
    }

    /// Set session-wide rate limits in bytes per second. Pass 0 for "unlimited".
    pub fn set_rate_limits(&self, download_bps: u32, upload_bps: u32) {
        use std::num::NonZeroU32;
        self.inner
            .ratelimits
            .set_download_bps(NonZeroU32::new(download_bps));
        self.inner
            .ratelimits
            .set_upload_bps(NonZeroU32::new(upload_bps));
    }
}

#[derive(Debug, Clone)]
pub struct FileEntry {
    pub index: u32,
    pub path: String,
    pub length: u64,
    pub downloaded: u64,
    pub selected: bool,
}

/// Snapshot of a torrent's progress for the UI.
#[derive(Debug, Clone)]
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
    pub state: String,
}

pub fn snapshot(handle: &Arc<ManagedTorrent>) -> TorrentSnapshot {
    let stats = handle.stats();
    let live = stats.live.as_ref();
    TorrentSnapshot {
        id: handle.id() as u64,
        info_hash: handle.info_hash().as_string(),
        name: handle.name(),
        total_bytes: stats.total_bytes,
        downloaded_bytes: stats.progress_bytes,
        uploaded_bytes: stats.uploaded_bytes,
        progress: if stats.total_bytes == 0 {
            0.0
        } else {
            stats.progress_bytes as f64 / stats.total_bytes as f64
        },
        // Speed.mbps is actually MiB/s (per Display impl). Convert to B/s.
        download_bps: live
            .map(|l| (l.download_speed.mbps * 1024.0 * 1024.0) as u64)
            .unwrap_or(0),
        upload_bps: live
            .map(|l| (l.upload_speed.mbps * 1024.0 * 1024.0) as u64)
            .unwrap_or(0),
        peers_live: live.map(|l| l.snapshot.peer_stats.live as u32).unwrap_or(0),
        peers_seen: live.map(|l| l.snapshot.peer_stats.seen as u32).unwrap_or(0),
        is_finished: stats.finished,
        state: stats.state.to_string(),
    }
}
