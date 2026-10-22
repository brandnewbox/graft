# ios-linux

Build iOS apps on Linux and install them on an iPhone over Tailscale, with no Mac in the loop. A
container image with the toolchain from [omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
(Swift 6.4, xtool, pymobiledevice3) on Ubuntu 24.04. Its commands come from a launcher, `ios-linux`,
that runs on the host and starts the container; the image carries it, and projects keep a stub that
runs it.

Nothing in the image is per project or per person. Two Docker volumes are per machine and shared by
every project: `ios-linux-sdk`, the iOS SDK, which each machine makes once from its own Xcode
download (Apple's license keeps it out of the image), and `ios-linux-state`, the phone's pairing
record and the development signing identities.

## Add it to a project

Add this stub to the project as `scripts/ios-linux` (executable), and point its README at the setup
below. It reads the launcher out of the image and runs it, so the commands update with the image
and the stub itself doesn't change; pin the image tag here.

```bash
#!/usr/bin/env bash
set -euo pipefail
image=${IOS_LINUX_IMAGE:-ghcr.io/brandnewbox/ios-linux:swift-6.4.1}
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
launcher=$(docker run --rm --entrypoint cat "$image" /usr/local/share/ios-linux/launcher)
IOS_LINUX_IMAGE=$image exec bash -c "$launcher" ios-linux "$@"
```
 An Xcode project also needs an xtool adapter: `python3 ~/omarchy-apple-dev/tools/xcodeproj2xtool.py
App.xcodeproj` in the container writes one; Curbsight's `scripts/generate-xtool` is an example that
corrects what the converter misreads. Apps that read resources through `Bundle.main` need them at the
bundle root, as Xcode lays them out: build with `CONFIGURATION=debug ~/omarchy-apple-dev/ship.sh --device`
instead of `xtool dev build`.

## Setup, once per machine

You need x86_64 Linux with Docker, on your tailnet; 30 GB free for Docker during setup (the image is
about 8 GB and the SDK 3.4 GB after); an iPhone on iOS 27 with the Tailscale app; and an App Store
Connect API key for a paid team: Users and Access → Integrations → App Store Connect API → Team
Keys, App Manager role (making one takes Admin or Account Holder; the .p8 downloads once).

1. **The SDK.** Download the Xcode .xip from <https://developer.apple.com/download/all/?q=Xcode>
   (27.1 for the `swift-6.4.1` image), then

   ```sh
   ios-linux setup ~/Downloads/Xcode_27.1.xip
   ```

   It pulls the image and makes the SDK in the `ios-linux-sdk` volume (about 10 minutes). The .xip
   isn't needed after. Later images are a `docker pull`; only a new Xcode means `setup` again.

2. **Settings**, in `~/.config/ios-linux/env`:

   ```sh
   IPHONE_TAILNET_IP=100.x.y.z           # `tailscale status`, the phone's line
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ASC_KEY_COMMAND='op document get "App Store Connect API key" --vault VAULT'
   # IPHONE_RP_PORT=…                    # only if the tunnel can't find the phone; see "Find the port"
   ```

   The .p8 can manage the whole team's certificates, devices and profiles, so keep it encrypted:
   `ASC_KEY_COMMAND` is a command that prints it, run on the host only when a deploy has to go to
   App Store Connect (the first per app or phone, then yearly). The key goes to a file in memory
   (`$XDG_RUNTIME_DIR`) for that one run and is deleted after. With 1Password, store the .p8 as a
   document and sign in first (`eval $(op signin)`); without, encrypt it with a passphrase,
   `gpg -c AuthKey_XXXXXXXXXX.p8`, delete the original, and use
   `ASC_KEY_COMMAND='gpg -d ~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8.gpg'`. `ASC_KEY_PATH=` the
   plain file also works.

3. **The phone.** Developer Mode on (Settings → Privacy & Security; if it isn't listed, pairing on a
   Mac below shows how to reveal it), Wi-Fi on and the Tailscale VPN on. Wi-Fi is required even across
   the tailnet: on cellular only, the phone closes its RemotePairing port.

4. **Pair it**, once, over USB. On this machine (needs `usbmuxd`: `sudo apt install usbmuxd`), plug
   the phone in, unlock it, run `ios-linux pair` and accept on the phone. The record holds a private
   key: anyone with it and a route to the phone can drive the phone. It stays in `ios-linux-state`.

### Pair on a Mac

```sh
python3.13 -m venv ~/pmd3 && ~/pmd3/bin/pip install pymobiledevice3
~/pmd3/bin/pymobiledevice3 lockdown remotepairing --pair             # phone on USB; accept on the phone
~/pmd3/bin/python - <<'PY'                                          # pin the host ID, see below
import glob, os, plistlib
from pymobiledevice3.pair_records import generate_host_id
for p in glob.glob(os.path.expanduser("~/.pymobiledevice3/remote_*.plist")):
    d = plistlib.load(open(p, "rb")); d.setdefault("host_identifier", generate_host_id())
    open(p, "wb").write(plistlib.dumps(d)); os.chmod(p, 0o600); print(p)
PY
~/pmd3/bin/pymobiledevice3 amfi reveal-developer-mode                # if Developer Mode isn't listed
```

Copy the printed `remote_<udid>.plist` to the Linux machine, `ios-linux pair` it, and delete the
copy. The phone ties a pairing to the paired machine's host ID, which pymobiledevice3 derives from
the hostname; pinning it in the record lets any machine use it.

### Find the port

The phone answers on one RemotePairing port, which the tunnel looks for in 49152-49167. It isn't
fixed: ours was 49152, and 51211 once while the phone was plugged into a Mac. If the tunnel reports
no RemotePairing service, find the port and set `IPHONE_RP_PORT`. On a Mac on the same Wi-Fi:
`~/pmd3/bin/pymobiledevice3 bonjour remotepairing` (the entry with the phone's LAN address).

## Use

```sh
ios-linux                                    # a shell, the current directory at the same path
ios-linux xtool dev build                    # or one command
ios-linux deploy xtool/MyApp.app             # sign, install, launch on the phone
```

**Unlock the phone before you deploy.** An idle phone closes the port the tunnel uses (deploy
says "The phone didn't answer"), and a locked one can stall an install or refuse the launch.
Unlock it and deploy again.

`deploy` signs, opens the tunnel, installs and launches. Signing uses an iOS Development certificate
and a profile per bundle ID (the app's and its extensions') kept in `ios-linux-state`. Only when one
is missing, expires within a day or doesn't list the phone (or with `deploy --provision`) does it go
to App Store Connect with the API key: registers the phone in the team and makes them. The rest of
the time, building and deploying need neither the key nor the internet, only Tailscale to the phone.
Profiles it makes are named `omarchy-apple-dev development <bundle id>`, and it replaces only those.

A free Apple ID can't be used: xtool signs with one only inside `xtool dev run`, which needs the
phone on USB.

## Maintaining

The image holds the toolchain, the scripts in `bin/` (the entrypoint, `setup-sdk`, `iphone-pair`,
`iphone-deploy`) and the launcher. It's open source only, safe to publish, one per Swift version:

```sh
docker build -t ghcr.io/brandnewbox/ios-linux:swift-6.4.1 --build-arg SWIFT_VERSION=6.4.1 .
docker push ghcr.io/brandnewbox/ios-linux:swift-6.4.1
```

Users pick up a new image with `docker pull`, keeping their SDK. A new Swift version needs a matching
Xcode, so a new tag and `setup` again. Never push anything with the SDK in it: Apple's license
doesn't allow redistributing it.

The entrypoint gives the image's user (UID 1000) the caller's UID and GID at start, so it works for
anyone; `bin/home-writable` opens up the few home directories that builds write to. `OMARCHY_REF` in
the Dockerfile pins omarchy-apple-dev, and its installer pins xtool. Projects' stubs run whatever
launcher the image has, so the launcher can change freely; its commands are the interface projects'
READMEs document.
