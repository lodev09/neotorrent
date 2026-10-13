//! Thin wrapper around `librqbit::Session` exposing only what the Swift UI
//! needs.

use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use librqbit::api::{Api, TorrentIdOrHash};
use librqbit::dht::PersistentDhtConfig;
use librqbit::http_api::{HttpApi, HttpApiOptions};
use librqbit::tracing_subscriber_config_utils::InitLoggingOptions;
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, Magnet, ManagedTorrent, Session,
    SessionOptions, SessionPersistenceConfig, TorrentStatsState,
};
use thiserror::Error;
use tokio::task::JoinHandle;

const MAX_TORRENT_FILE_BYTES: u64 = 10 * 1024 * 1024;
const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;
// librqbit's rate limiter refills in 16 KiB chunks; anything below that
// starves every peer connection.
const MIN_RATE_LIMIT: NonZeroU32 = NonZeroU32::new(64 * 1024).unwrap();
const LISTEN_PORTS: std::ops::Range<u16> = 4240..4260;

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
        Self::Session(format!("{e:#}"))
    }
}

pub struct NeoTorrentSession {
    inner: Arc<Session>,
    api: Api,
    download_dir: PathBuf,
    streaming_port: u16,
    http_task: JoinHandle<()>,
    next_id: AtomicUsize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AddedTorrent {
    pub id: u64,
    pub already_managed: bool,
}

impl NeoTorrentSession {
    /// Build a session that:
    /// - Downloads into `download_dir` by default.
    /// - Persists session state (torrent list, fastresume, DHT) under
    ///   `state_dir`, so torrents resume automatically on next launch.
    /// - Accepts incoming peer connections (UPnP-forwarded when possible).
    pub async fn new(download_dir: PathBuf, state_dir: PathBuf) -> Result<Self, SessionError> {
        Self::start(download_dir, state_dir, true).await
    }

    async fn start(
        download_dir: PathBuf,
        state_dir: PathBuf,
        network: bool,
    ) -> Result<Self, SessionError> {
        std::fs::create_dir_all(&state_dir)
            .map_err(|e| SessionError::Session(format!("create {state_dir:?}: {e}")))?;
        quarantine_corrupt_session_file(&state_dir);

        let options = |persist_dht: bool| SessionOptions {
            fastresume: true,
            persistence: Some(SessionPersistenceConfig::Json {
                folder: Some(state_dir.clone()),
            }),
            disable_dht: !network,
            disable_dht_persistence: !persist_dht,
            dht_config: Some(PersistentDhtConfig {
                config_filename: Some(state_dir.join("dht.json")),
                ..Default::default()
            }),
            listen_port_range: network.then_some(LISTEN_PORTS),
            enable_upnp_port_forwarding: network,
            ..Default::default()
        };
        // The persisted DHT state pins a UDP port; if something else grabbed it
        // since the last run, start with a fresh DHT instead of failing.
        let inner = match Session::new_with_opts(download_dir.clone(), options(true)).await {
            Ok(s) => s,
            Err(_) if network => {
                Session::new_with_opts(download_dir.clone(), options(false)).await?
            }
            Err(e) => return Err(e.into()),
        };

        // librqbit's HTTP API serves byte-range streams of torrent files and
        // blocks on not-yet-downloaded pieces. Read-only: anything that can
        // reach the port must not be able to add or delete torrents.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|e| SessionError::Session(format!("bind streaming socket: {e}")))?;
        let streaming_port = listener
            .local_addr()
            .map_err(|e| SessionError::Session(format!("local_addr: {e}")))?
            .port();
        let api = Api::new(inner.clone(), None, None);
        let http_api = HttpApi::new(
            api.clone(),
            Some(HttpApiOptions {
                read_only: true,
                basic_auth: None,
            }),
        );
        let http_task = tokio::spawn(async move {
            if let Err(e) = http_api.make_http_api_and_run(listener, None).await {
                tracing::error!("streaming server stopped: {e:#}");
            }
        });

        // librqbit derives new ids from the persisted max id, which races when
        // several adds are in flight. Hand out ids ourselves instead.
        let next_id = inner.with_torrents(|it| it.map(|(id, _)| id + 1).max().unwrap_or(0));

        Ok(Self {
            inner,
            api,
            download_dir,
            streaming_port,
            http_task,
            next_id: AtomicUsize::new(next_id),
        })
    }

    pub fn streaming_port(&self) -> u16 {
        self.streaming_port
    }

    pub fn download_dir(&self) -> &PathBuf {
        &self.download_dir
    }

    /// Add a magnet link, http(s) .torrent URL, or local .torrent file
    /// (path or `file://` URL). `output_folder` overrides the session's
    /// default download folder; multi-file torrents still get their own
    /// subfolder inside it.
    pub async fn add(
        &self,
        uri: &str,
        output_folder: Option<PathBuf>,
    ) -> Result<AddedTorrent, SessionError> {
        let add = if uri.starts_with("magnet:") {
            // librqbit only detects duplicates after resolving metadata, which
            // can take minutes. Check up front.
            let existing = Magnet::parse(uri)
                .ok()
                .and_then(|m| m.as_id20())
                .and_then(|h| self.inner.get(TorrentIdOrHash::Hash(h)));
            if let Some(h) = existing {
                return Ok(AddedTorrent {
                    id: h.id() as u64,
                    already_managed: true,
                });
            }
            AddTorrent::from_url(uri)
        } else if uri.starts_with("http://") || uri.starts_with("https://") {
            AddTorrent::from_url(uri)
        } else {
            AddTorrent::from_bytes(read_torrent_file(uri)?)
        };

        let mut opts = AddTorrentOptions {
            overwrite: true,
            ..Default::default()
        };
        let add = match output_folder.filter(|f| f != &self.download_dir) {
            None => add,
            Some(folder) => {
                // An explicit output_folder disables librqbit's per-torrent
                // subfolder, so resolve metadata first and recreate it.
                let resp = self
                    .inner
                    .add_torrent(
                        add,
                        Some(AddTorrentOptions {
                            list_only: true,
                            ..Default::default()
                        }),
                    )
                    .await?;
                let AddTorrentResponse::ListOnly(r) = resp else {
                    return Err(SessionError::Torrent("expected list-only response".into()));
                };
                let sub = r
                    .output_folder
                    .strip_prefix(&self.download_dir)
                    .unwrap_or(Path::new(""));
                opts.output_folder = Some(folder.join(sub).to_string_lossy().into_owned());
                opts.only_files = r.only_files;
                opts.initial_peers = Some(r.seen_peers);
                AddTorrent::TorrentFileBytes(r.torrent_bytes)
            }
        };
        opts.preferred_id = Some(self.next_id.fetch_add(1, Ordering::Relaxed));

        match self.inner.add_torrent(add, Some(opts)).await? {
            AddTorrentResponse::Added(id, _) => Ok(AddedTorrent {
                id: id as u64,
                already_managed: false,
            }),
            AddTorrentResponse::AlreadyManaged(id, _) => Ok(AddedTorrent {
                id: id as u64,
                already_managed: true,
            }),
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

    /// Folder librqbit writes this torrent's files into. File paths from
    /// `files()` are relative to it.
    pub fn output_folder(&self, id: u64) -> Result<PathBuf, SessionError> {
        let details = self
            .api
            .api_torrent_details(TorrentIdOrHash::Id(id as usize))
            .map_err(|_| SessionError::NotFound(id))?;
        Ok(PathBuf::from(details.output_folder))
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
                    selected: only.as_ref().is_none_or(|s| s.contains(&i)),
                })
                .collect::<Vec<_>>()
        });
        match result {
            Ok(files) => Ok(files),
            // Metadata not yet resolved — return empty list rather than erroring.
            Err(_) => Ok(Vec::new()),
        }
    }

    pub async fn set_only_files(&self, id: u64, indices: Vec<u32>) -> Result<(), SessionError> {
        let h = self.handle(id)?;
        let set: std::collections::HashSet<usize> =
            indices.into_iter().map(|i| i as usize).collect();
        self.inner.update_only_files(&h, &set).await?;
        Ok(())
    }

    /// Set session-wide rate limits in bytes per second. Pass 0 for "unlimited".
    pub fn set_rate_limits(&self, download_bps: u32, upload_bps: u32) {
        let limit = |bps: u32| NonZeroU32::new(bps).map(|b| b.max(MIN_RATE_LIMIT));
        self.inner.ratelimits.set_download_bps(limit(download_bps));
        self.inner.ratelimits.set_upload_bps(limit(upload_bps));
    }

    /// Pause every torrent (without persisting the pause) and stop background
    /// tasks. Call before the process exits.
    pub async fn shutdown(&self) {
        self.http_task.abort();
        self.inner.stop().await;
    }
}

/// Send librqbit's logs to `log_file`, rotating it once it passes 10 MiB.
/// Must run inside a tokio runtime; only the first call has an effect.
pub fn init_logging(log_file: &Path) {
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        if let Some(dir) = log_file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if std::fs::metadata(log_file).is_ok_and(|m| m.len() > MAX_LOG_BYTES) {
            let _ = std::fs::rename(log_file, log_file.with_extension("old.log"));
        }
        let Some(path) = log_file.to_str() else {
            return;
        };
        let opts = InitLoggingOptions {
            default_rust_log_value: Some("warn"),
            log_file: Some(path),
            log_file_rust_log: Some("info"),
        };
        if let Err(e) = librqbit::tracing_subscriber_config_utils::init_logging(opts) {
            eprintln!("neotorrent: logging disabled: {e:#}");
        }
    });
}

fn read_torrent_file(uri: &str) -> Result<Vec<u8>, SessionError> {
    let path = if uri.starts_with("file:") {
        url::Url::parse(uri)
            .ok()
            .and_then(|u| u.to_file_path().ok())
            .ok_or_else(|| SessionError::Torrent(format!("invalid file URL: {uri}")))?
    } else {
        PathBuf::from(uri)
    };
    let is_torrent = path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("torrent"));
    if !is_torrent {
        return Err(SessionError::Torrent(format!(
            "not a .torrent file: {}",
            path.display()
        )));
    }
    let len = std::fs::metadata(&path)
        .map_err(|e| SessionError::Torrent(format!("error reading local file {path:?}: {e}")))?
        .len();
    if len > MAX_TORRENT_FILE_BYTES {
        return Err(SessionError::Torrent(format!(
            "invalid torrent: {} is too large",
            path.display()
        )));
    }
    std::fs::read(&path)
        .map_err(|e| SessionError::Torrent(format!("error reading local file {path:?}: {e}")))
}

/// librqbit refuses to start when `session.json` doesn't parse. Move a
/// corrupt file aside so the app can start (with an empty torrent list)
/// instead of failing on every launch.
fn quarantine_corrupt_session_file(state_dir: &Path) {
    let path = state_dir.join("session.json");
    let Ok(bytes) = std::fs::read(&path) else {
        return;
    };
    if serde_json::from_slice::<serde_json::Value>(&bytes).is_err() {
        let aside = state_dir.join("session.json.corrupt");
        tracing::error!("session.json is corrupt, moving it to {aside:?}");
        let _ = std::fs::rename(&path, aside);
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TorrentState {
    Initializing,
    Live,
    Paused,
    Error,
}

impl From<TorrentStatsState> for TorrentState {
    fn from(s: TorrentStatsState) -> Self {
        match s {
            TorrentStatsState::Initializing => Self::Initializing,
            TorrentStatsState::Live => Self::Live,
            TorrentStatsState::Paused => Self::Paused,
            TorrentStatsState::Error => Self::Error,
        }
    }
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
    pub state: TorrentState,
    pub error: Option<String>,
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
        state: stats.state.into(),
        error: stats.error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use librqbit::{create_torrent, CreateTorrentOptions};
    use std::time::Duration;

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!("neotorrent-test-{name}-{nanos}"));
            std::fs::create_dir_all(root.join("src")).unwrap();
            std::fs::create_dir_all(root.join("downloads")).unwrap();
            Self { root }
        }

        fn downloads(&self) -> PathBuf {
            self.root.join("downloads")
        }

        fn state(&self) -> PathBuf {
            self.root.join("state")
        }

        /// Write `files` under src/<name>/ (or src/<name> for a single file)
        /// and return the path of a .torrent describing it.
        async fn torrent(&self, name: &str, files: &[(&str, usize)]) -> PathBuf {
            let content = if files.len() == 1 && files[0].0 == name {
                let p = self.root.join("src").join(name);
                std::fs::write(&p, vec![7u8; files[0].1]).unwrap();
                p
            } else {
                let dir = self.root.join("src").join(name);
                std::fs::create_dir_all(&dir).unwrap();
                for (f, len) in files {
                    std::fs::write(dir.join(f), vec![7u8; *len]).unwrap();
                }
                dir
            };
            let t = create_torrent(&content, CreateTorrentOptions::default())
                .await
                .unwrap();
            let out = self.root.join(format!("{name}.torrent"));
            std::fs::write(&out, t.as_bytes().unwrap()).unwrap();
            out
        }

        async fn session(&self) -> NeoTorrentSession {
            NeoTorrentSession::start(self.downloads(), self.state(), false)
                .await
                .unwrap()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    async fn wait_for_state(s: &NeoTorrentSession, id: u64, state: TorrentState) {
        for _ in 0..100 {
            if snapshot(&s.handle(id).unwrap()).state == state {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("torrent {id} never reached {state:?}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn adding_same_torrent_twice_reports_already_managed() {
        let fx = Fixture::new("dup");
        let t = fx.torrent("a.bin", &[("a.bin", 1000)]).await;
        let s = fx.session().await;
        let first = s.add(t.to_str().unwrap(), None).await.unwrap();
        let second = s.add(t.to_str().unwrap(), None).await.unwrap();
        assert!(!first.already_managed);
        assert_eq!(
            second,
            AddedTorrent {
                id: first.id,
                already_managed: true
            }
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn concurrent_adds_get_unique_ids() {
        let fx = Fixture::new("concurrent");
        let mut paths = Vec::new();
        for i in 0..5 {
            let name = format!("f{i}.bin");
            paths.push(fx.torrent(&name, &[(&name, 1000 + i)]).await);
        }
        let s = Arc::new(fx.session().await);
        let tasks: Vec<_> = paths
            .into_iter()
            .map(|p| {
                let s = s.clone();
                tokio::spawn(async move { s.add(p.to_str().unwrap(), None).await.unwrap() })
            })
            .collect();
        let mut ids = Vec::new();
        for t in tasks {
            let added = t.await.unwrap();
            assert!(!added.already_managed);
            ids.push(added.id);
        }
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), 5);
        assert_eq!(s.handles().len(), 5);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn output_folder_matches_librqbit_layout() {
        let fx = Fixture::new("layout");
        let single = fx.torrent("one.bin", &[("one.bin", 1000)]).await;
        let multi = fx.torrent("pack", &[("x.bin", 10), ("y.bin", 20)]).await;
        let s = fx.session().await;

        let a = s.add(single.to_str().unwrap(), None).await.unwrap();
        assert_eq!(s.output_folder(a.id).unwrap(), fx.downloads());

        let b = s.add(multi.to_str().unwrap(), None).await.unwrap();
        assert_eq!(s.output_folder(b.id).unwrap(), fx.downloads().join("pack"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn custom_output_folder_keeps_subfolder() {
        let fx = Fixture::new("custom");
        let multi = fx.torrent("pack", &[("x.bin", 10), ("y.bin", 20)]).await;
        let other = fx.root.join("elsewhere");
        let s = fx.session().await;
        let added = s
            .add(multi.to_str().unwrap(), Some(other.clone()))
            .await
            .unwrap();
        assert_eq!(s.output_folder(added.id).unwrap(), other.join("pack"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn file_urls_and_non_torrent_paths() {
        let fx = Fixture::new("paths");
        let t = fx.torrent("a.bin", &[("a.bin", 1000)]).await;
        let s = fx.session().await;
        let url = url::Url::from_file_path(&t).unwrap();
        assert!(s.add(url.as_str(), None).await.is_ok());

        let not_torrent = fx.root.join("notes.txt");
        std::fs::write(&not_torrent, "hello").unwrap();
        assert!(s.add(not_torrent.to_str().unwrap(), None).await.is_err());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn restart_restores_paused_state_and_file_selection() {
        let fx = Fixture::new("restore");
        let multi = fx.torrent("pack", &[("x.bin", 10), ("y.bin", 20)]).await;
        let id = {
            let s = fx.session().await;
            let id = s.add(multi.to_str().unwrap(), None).await.unwrap().id;
            wait_for_state(&s, id, TorrentState::Live).await;
            s.set_only_files(id, vec![1]).await.unwrap();
            s.pause(id).await.unwrap();
            s.shutdown().await;
            id
        };
        let s = fx.session().await;
        wait_for_state(&s, id, TorrentState::Paused).await;
        let selected: Vec<_> = s.files(id).unwrap().iter().map(|f| f.selected).collect();
        assert_eq!(selected, vec![false, true]);

        let next = fx.torrent("later.bin", &[("later.bin", 5)]).await;
        let added = s.add(next.to_str().unwrap(), None).await.unwrap();
        assert!(added.id > id);
    }

    #[test]
    fn corrupt_session_file_is_moved_aside() {
        let fx = Fixture::new("corrupt");
        std::fs::create_dir_all(fx.state()).unwrap();
        std::fs::write(fx.state().join("session.json"), "{not json").unwrap();
        quarantine_corrupt_session_file(&fx.state());
        assert!(!fx.state().join("session.json").exists());
        assert!(fx.state().join("session.json.corrupt").exists());
    }
}
