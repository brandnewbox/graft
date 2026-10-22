# graft

Build iPhone apps on Linux and install them on an iPhone over Tailscale, with no Mac in the loop.
Like a branch grafted onto another tree's rootstock, the toolchain for Apple's platforms grows on
Linux here.

A container image with the toolchain from [omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
(Swift 6.4, xtool, pymobiledevice3) on Ubuntu 24.04, and a command, `graft`, that starts it
with what it needs (the current directory, host networking, a TUN device for the tunnel to the
phone). The commands themselves (`launcher`) ship in the image; the `graft` file only pulls the
image and runs them, so the commands update with the image.

Nothing in the image is per project or per person. Two Docker volumes are per machine and shared by
every project: `graft-sdk`, the iOS SDK, which each machine makes once from its own Xcode
download (Apple's license keeps it out of the image), and `graft-state`, the phone's pairing
record and the development signing identities.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/brandnewbox/graft/main/graft -o ~/.local/bin/graft
chmod +x ~/.local/bin/graft
```

The file pins the image tag (`GRAFT_IMAGE` overrides it). A project can also keep a copy of it,
so a fresh clone has the command without installing anything; the project's README then says where.

## Setup, once per machine

You need:

- x86_64 Linux with Docker (your user in the `docker` group) and Tailscale, on the tailnet the
  phone is on;
- 30 GB free for Docker during setup; after, the image is 6.2 GB and the SDK 3.5 GB;
- an iPhone on iOS 27 with the Tailscale app;
- an App Store Connect API key for a paid team: App Store Connect → Users and Access →
  Integrations → App Store Connect API → Team Keys, App Manager role. Making one takes Admin or
  Account Holder, and the .p8 downloads once.

1. **The SDK.** Download the Xcode .xip from <https://developer.apple.com/download/all/?q=Xcode>
   (Xcode 27.1 for the `swift-6.4.1` image), then

   ```sh
   graft setup ~/Downloads/Xcode_27.1.xip
   ```

   It pulls the image and makes the SDK in the `graft-sdk` volume: about 7 minutes after the
   download. The .xip isn't needed after.

2. **Settings**, in `~/.config/graft/env`:

   ```sh
   IPHONE_TAILNET_IP=100.x.y.z           # `tailscale status`, the phone's line
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ASC_KEY_COMMAND='op read "op://VAULT/ITEM/AuthKey_XXXXXXXXXX.p8"'
   # IPHONE_RP_PORT=…                    # only if the tunnel can't find the phone; see "Find the port"
   ```

   The .p8 can manage the whole team's certificates, devices and profiles, so keep it encrypted.
   `ASC_KEY_COMMAND` is a command that prints it. The launcher runs it only when a deploy has to go
   to App Store Connect (the first for an app or a phone, then yearly), puts the key in a file in
   memory (`$XDG_RUNTIME_DIR`) for that run, and deletes it after.

   - 1Password: attach the .p8 to an item and read it as above (add `--account` for a second
     account). Without the desktop app's CLI integration, sign in first: `eval $(op signin)`.
   - gpg: `gpg -c AuthKey_XXXXXXXXXX.p8` (asks for a passphrase), delete the original, and use
     `ASC_KEY_COMMAND='gpg -d ~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8.gpg'`.
   - Or `ASC_KEY_PATH=` the plain .p8.

3. **The phone.** Developer Mode on (Settings → Privacy & Security; without Xcode it isn't listed
   until revealed, see "Pair on a Mac"), Wi-Fi on and the Tailscale VPN on. Wi-Fi is required even
   across the tailnet: on cellular only, the phone closes the port the tunnel uses.

4. **Pair it**, once, over USB, on a Mac (below) or on this machine. Here (needs `usbmuxd`:
   `sudo apt install usbmuxd`): plug the phone in, unlock it, run `graft pair` and
   accept on the phone. The Mac route is the one that has been run; this one hasn't yet. The record
   holds a private key: anyone with it and a route to the phone can drive the phone. It stays in
   `graft-state`.

### Pair on a Mac

With the phone on the Mac's USB:

```sh
python3.13 -m venv ~/pmd3 && ~/pmd3/bin/pip install pymobiledevice3
~/pmd3/bin/pymobiledevice3 amfi reveal-developer-mode                # if Developer Mode isn't listed
~/pmd3/bin/pymobiledevice3 lockdown remotepairing --pair             # accept on the phone
~/pmd3/bin/python - <<'PY'                                          # pin the host ID, see below
import glob, os, plistlib
from pymobiledevice3.pair_records import generate_host_id
for p in glob.glob(os.path.expanduser("~/.pymobiledevice3/remote_*.plist")):
    d = plistlib.load(open(p, "rb")); d.setdefault("host_identifier", generate_host_id())
    open(p, "wb").write(plistlib.dumps(d)); os.chmod(p, 0o600); print(p)
PY
```

Copy the printed `remote_<udid>.plist` to the Linux machine, import it with
`graft pair remote_<udid>.plist`, and delete both copies. The phone ties a pairing to
the paired machine's host ID, which pymobiledevice3 derives from the hostname; pinning it in the
record lets any machine use it.

### Find the port

The phone answers on one RemotePairing port, which the tunnel looks for in 49152-49167. It isn't
fixed: ours was 49152, and 51211 once while the phone was plugged into a Mac. If the phone is
unlocked and deploy still says "The phone didn't answer", find the port and set `IPHONE_RP_PORT`.
On a Mac on the same Wi-Fi: `~/pmd3/bin/pymobiledevice3 bonjour remotepairing` (the entry with the
phone's LAN address).

## Use

From the project's root:

```sh
graft                                    # a shell, the project at the same path
graft xtool dev build                    # or one command
graft deploy path/to/MyApp.app           # sign, install, launch on the phone
```

The app has to be under the current directory, which is what the container sees.

**Unlock the phone before you deploy.** An idle phone closes the port the tunnel uses (deploy
says "The phone didn't answer"), and a locked one can stall an install or refuse the launch.
Unlock it and deploy again.

`deploy` signs, opens the tunnel, installs and launches. Signing uses an iOS Development certificate
and a profile per bundle ID (the app's and its extensions') kept in `graft-state`. Only when one
is missing, expires within a day or doesn't list the phone (or with `deploy --provision`) does it go
to App Store Connect with the API key, to register the phone in the team and make them. The rest of
the time, building and deploying need neither the key nor the internet, only Tailscale to the phone.
Profiles it makes are named `omarchy-apple-dev development <bundle id>`, and it replaces only those.

A free Apple ID can't be used: xtool signs with one only inside `xtool dev run`, which needs the
phone on USB.

New images: `docker pull ghcr.io/brandnewbox/graft:swift-6.4.1`. The SDK stays; only a new
Xcode (and the image tag for its Swift) means `setup` again.

## An Xcode project

xtool builds a SwiftPM package, so an Xcode project needs an adapter: a package that builds the app
target. omarchy-apple-dev's converter writes one:

```sh
graft bash -c 'python3 ~/omarchy-apple-dev/tools/xcodeproj2xtool.py App.xcodeproj'
```

Read its `warning:` lines and check the resources in the `Package.swift` it writes; a project script
that regenerates the adapter and corrects what the converter misreads keeps it reproducible. Apps
that read resources through `Bundle.main` need them at the bundle root, as Xcode lays them out:
build with `CONFIGURATION=debug ~/omarchy-apple-dev/ship.sh --device` in the adapter instead of
`xtool dev build`.

Paths like `~/omarchy-apple-dev` are inside the container: quote them in `bash -c '...'`, or the
host's shell expands `~` first.

## Trademarks

Apple, iPhone, iOS, macOS and Xcode are trademarks of Apple Inc. graft is not affiliated with,
sponsored by or endorsed by Apple. It contains no Apple software: each user makes the SDK from their
own Xcode download, under Apple's license.

## Maintaining

The image holds the toolchain, the scripts in `bin/` (the entrypoint, `setup-sdk`, `iphone-pair`,
`iphone-deploy`) and `launcher`, the host side of the commands. It's open source only, one per
Swift version:

```sh
docker build -t ghcr.io/brandnewbox/graft:swift-6.4.1 --build-arg SWIFT_VERSION=6.4.1 .
docker push ghcr.io/brandnewbox/graft:swift-6.4.1
```

Pushing needs a token with `write:packages` (`gh auth refresh -s write:packages`, then
`gh auth token | docker login ghcr.io -u USER --password-stdin`). GitHub makes a new package
private; make it public once, in the package's settings. Never push anything with the SDK in it:
Apple's license doesn't allow redistributing it.

The entrypoint gives the image's user (UID 1000) the caller's UID and GID at start, so it works for
anyone; `bin/home-writable` opens up the few home directories that builds write to. `OMARCHY_REF` in
the Dockerfile pins omarchy-apple-dev, and its installer pins xtool. The `graft` file runs
whatever launcher the image has, so `launcher` can change freely; keep `graft` itself stable,
since people and projects keep copies of it.
