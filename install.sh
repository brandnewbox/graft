#!/bin/sh
# Installs graft (https://github.com/brandnewbox/graft), the latest release or GRAFT_VERSION
# (0.3.0, say), in ~/.local/share/graft, with the command at ~/.local/bin/graft. Run it again to
# update.
#
#   curl -fsSL https://github.com/brandnewbox/graft/releases/latest/download/install.sh | sh
set -eu
releases=https://github.com/brandnewbox/graft/releases
if [ -n "${GRAFT_VERSION:-}" ]; then
  url=$releases/download/v${GRAFT_VERSION#v}/graft.tar.gz
else
  url=$releases/latest/download/graft.tar.gz
fi
data=${XDG_DATA_HOME:-$HOME/.local/share}
bin=$HOME/.local/bin
mkdir -p "$data" "$bin"
tmp=$(mktemp -d "$data/.graft.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" | tar -xz -C "$tmp"
rm -rf "$data/graft"
mv "$tmp/graft" "$data/graft"
ln -sfn "$data/graft/graft" "$bin/graft"
"$bin/graft" version
case ":$PATH:" in
*":$bin:"*) ;;
*) echo "Add $bin to your PATH." ;;
esac
