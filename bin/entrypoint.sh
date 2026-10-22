#!/usr/bin/env bash
# Runs as root. Gives the dev user the caller's UID and GID (HOST_UID and HOST_GID, which the
# launcher passes) so files written to the mounted project keep their owner, readies the two volumes,
# then runs the command as dev.
set -euo pipefail
uid=${HOST_UID:-$(id -u dev)}
gid=${HOST_GID:-$(id -g dev)}
# In place rather than usermod, which would chown the whole home directory.
sed -i "s/^dev:x:[0-9]*:[0-9]*:/dev:x:$uid:$gid:/" /etc/passwd
sed -i "s/^dev:x:[0-9]*:/dev:x:$gid:/" /etc/group

mkdir -p /state/xtool /state/pymobiledevice3 /state/development
chown -R dev:dev /state
chmod 700 /state/pymobiledevice3 /state/development
# Only the top of /sdk: setup-sdk writes under it, everything else only reads.
mkdir -p /sdk/swift-sdks /sdk/xtool
chown dev:dev /sdk /sdk/swift-sdks /sdk/xtool
# ship.sh reads the Xcode version (and App Shortcuts phrase lists) next to the SDK cache.
for f in /sdk/xtool/darwin-*.xtoolsdk.*; do
  if [ -e "$f" ]; then ln -sfn "$f" "/home/dev/.cache/xtool/$(basename "$f")"; fi
done

ulimit -n 65536 2>/dev/null || true
exec setpriv --reuid=dev --regid=dev --init-groups env HOME=/home/dev USER=dev LOGNAME=dev "$@"
