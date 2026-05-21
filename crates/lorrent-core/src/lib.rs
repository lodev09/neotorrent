pub mod bencode;
pub mod engine;
pub mod extension;
pub mod magnet;
pub mod peer;
pub mod session;
pub mod tracker;
pub mod wire;

pub fn greet() -> String {
    format!("Hello from lorrent-core v{}", env!("CARGO_PKG_VERSION"))
}
