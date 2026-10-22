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
unlocked and deploy still says "The device didn't answer", find the port and set `IPHONE_RP_PORT`
(or the device's PORT in `~/.config/graft/devices`, see Devices).
On a Mac on the same Wi-Fi: `~/pmd3/bin/pymobiledevice3 bonjour remotepairing` (the entry with the
phone's LAN address).

## Use

At the project's root:

```sh
graft build                              # a Debug build of the app
graft build --release                    # a Release build
graft build --configuration Beta         # a build of another configuration
graft deploy                             # build, then sign, install and launch it on the phone
graft deploy --release                   # the same with a Release build
graft deploy path/to/MyApp.app           # an app already built: sign, install and launch it
graft deploy --device ipad               # on another device (see Devices)
```

The container sees the current directory at the same path, so run graft at the project's root, and
an app you deploy has to be under it.

An xtool package (`xtool.yml` at the root) builds as it is, into `xtool/<App>.app`. An Xcode project
builds through an adapter (below), and `build` and `deploy` take the app target there:
`graft build MyApp`. The configuration is `Debug` unless you give one; `Debug` is a SwiftPM debug
build and every other configuration a release build. graft builds with omarchy-apple-dev's
`ship.sh --device`, not `xtool dev build`: it also copies the app's resources to the bundle root,
where Xcode puts them and `Bundle.main` finds them.

**Unlock the device before you deploy.** An idle device closes the port the tunnel uses (deploy
says "The device didn't answer"), and a locked one can stall an install or refuse the launch.
Unlock it and deploy again.

After the build, `deploy` signs, opens the tunnel, installs and launches. Signing uses an iOS Development certificate
and a profile per bundle ID (the app's and its extensions') kept in `graft-state`. Only when one
is missing, expires within a day or doesn't list the device (or with `deploy --provision`) does it
go to App Store Connect with the API key, to register the devices in the team and make them. The
rest of the time, building and deploying need neither the key nor the internet, only Tailscale to
the device.
Profiles it makes are named `omarchy-apple-dev development <bundle id>`, and it replaces only those.

A free Apple ID can't be used: xtool signs with one only inside `xtool dev run`, which needs the
phone on USB.

New images: `docker pull ghcr.io/brandnewbox/graft:swift-6.4.1`. The SDK stays; only a new
Xcode (and the image tag for its Swift) means `setup` again.

### Devices

With one device, `IPHONE_TAILNET_IP` and its pairing record are all graft needs. With more, an
iPhone and an iPad for example, list them in `~/.config/graft/devices`, a line each; the first is
the default:

```
# NAME    TAILNET_IP     UDID                        [PORT]
iphone    100.64.0.5     00008150-001A2B3C4D5E001C
ipad      100.64.0.9     00008112-0011223344556677   51211
```

Pair each one (Setup, step 4). `graft pair` prints the UDID, and the record's file name has it:
`remote_<udid>.plist`. `graft devices` lists the devices, with whether each is paired, and any
pairing record not listed. `deploy --device NAME` deploys to NAME. The profiles list every device
in the file, so changing devices doesn't make new ones; a device added to the file goes to App
Store Connect once, on its first deploy. The app has to support the device: an iPad needs
`TARGETED_DEVICE_FAMILY` to include 2.

## An Xcode project

xtool builds a SwiftPM package, so an Xcode project needs an adapter: a package that builds one app
target in one configuration. graft makes it with its converter on every build, in
`.graft/<Target>/<Configuration>/`, so it follows the project; that takes a fraction of a second.
Only the files that changed are copied over the last adapter, and its build tree stays, so the build
is incremental. The app is at `.graft/<Target>/<Configuration>/xtool/<App>.app`. `.graft/` ignores
itself in git.

The converter reads the configuration's settings, as Xcode does: its Info.plist, bundle ID,
xcconfig files and compilation conditions. A Debug build can have its own bundle ID or App
Transport Security settings in the Xcode project, and the adapter follows. The package versions
are the ones in the project's `Package.resolved`, as in Xcode. Read the converter's `warning:`
lines; when it gets a project wrong, fix the converter (graft's copy, in `vendor/`; see Maintaining).

Settings go in `graft.yml` at the project's root. Both keys are optional:

```yaml
project: ios/MyApp.xcodeproj    # the Xcode project; default: the only one found
target: MyApp                   # the app target when none is given; default: the only one
```

With a `graft.yml`, graft builds the project as an Xcode project even when there is an `xtool.yml`.
Each key is one line, `key: value`; graft doesn't read more of YAML than that.

## Trademarks

Apple, iPhone, iOS, macOS and Xcode are trademarks of Apple Inc. graft is not affiliated with,
sponsored by or endorsed by Apple. It contains no Apple software: each user makes the SDK from their
own Xcode download, under Apple's license.

## Maintaining

The image holds the toolchain, the scripts in `bin/` (the entrypoint, `setup-sdk`, `iphone-pair`,
`graft-build`, `graft-deploy`, `graft-devices`, `iphone-deploy`), graft's copies of some of
omarchy-apple-dev's tools and `launcher`, the host side of the commands. It's open source only, one
per Swift version.

`vendor/omarchy-apple-dev/tools/` holds copies of omarchy-apple-dev's tools, under its MIT license
(`vendor/omarchy-apple-dev/LICENSE`), changed for graft; the image puts them over upstream's, beside
the tools they call:

- `xcodeproj2xtool.py`, the converter: it reads a configuration given with `--configuration`
  (upstream reads only Release), and it skips resources that are in the project but not on disk.
  CI runs its `--self-test`.
- `provision-dev.py`: `--device UDID NAME`, repeatable, so the profiles list every device.

Each one's header names the upstream commit it came from. When `OMARCHY_REF` moves, diff
upstream's file from that commit to the new one, apply what's useful, and update the header.

GitHub Actions builds it (`.github/workflows/image.yml`): every pull request builds it and checks
the tools start. To release, tag the commit:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

That publishes `ghcr.io/brandnewbox/graft:swift-6.4.1`, the tag the `graft` command pulls, and
`swift-6.4.1-0.2.0`, which stays fixed, to go back to. Users get a release with
`docker pull ghcr.io/brandnewbox/graft:swift-6.4.1`. To try a branch first, run the workflow from
the Actions tab with "publish" ticked: it publishes `swift-6.4.1-<short commit>`, which
`GRAFT_IMAGE` selects. A new Swift version is a new entry in the workflow's `swift` list, with the
matching Xcode in this README.

The first publish makes the package private; make it public once, in the package's settings on
GitHub. Never publish anything with the SDK in it: Apple's license doesn't allow redistributing it.

To build one locally, for working on the Dockerfile:
`docker build -t ghcr.io/brandnewbox/graft:swift-6.4.1 --build-arg SWIFT_VERSION=6.4.1 .`

The entrypoint gives the image's user (UID 1000) the caller's UID and GID at start, so it works for
anyone; `bin/home-writable` opens up the few home directories that builds write to. `OMARCHY_REF` in
the Dockerfile pins omarchy-apple-dev, and its installer pins xtool. The `graft` file runs
whatever launcher the image has, so `launcher` can change freely; keep `graft` itself stable,
since people and projects keep copies of it.
