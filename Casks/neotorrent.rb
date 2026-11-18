cask "neotorrent" do
  version "0.1.6"
  sha256 "1c0ad318c18a00bc9bd7709a755d0b89ca0d71cab13bc24a432fa91c9e9ddfae"

  url "https://github.com/lodev09/neotorrent/releases/download/v#{version}/NeoTorrent-#{version}.dmg"
  name "NeoTorrent"
  desc "Native BitTorrent client"
  homepage "https://github.com/lodev09/neotorrent"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "NeoTorrent.app"
end
