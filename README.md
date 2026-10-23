# graft

Build iPhone and iPad apps on Linux and install them on the devices over Tailscale, with no Mac in
the loop.
Like a branch grafted onto another tree's rootstock, the toolchain for Apple's platforms grows on
Linux here.

A command, `graft`, and a container image for each Xcode with the toolchain from
[omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev) (Swift, xtool,
pymobiledevice3) on Ubuntu 24.04. The project names its Xcode, and that picks the image. graft
starts it with what it needs (the current directory, host networking, a TUN device for the tunnel
to the device) and with graft's own commands, which aren't in the image.

Nothing in the images is per project or per person. Docker volumes are per machine and shared by
every project: `graft-sdk-<Xcode>` (`graft-sdk-27.1`), the iOS SDK, which each machine makes once
per Xcode from its own Xcode download (Apple's license keeps it out of the image), and
`graft-state`, the devices' pairing records and the development signing identities. The list of
devices is in `~/.config/graft/devices`.

## Install

```sh
curl -fsSL https://github.com/brandnewbox/graft/releases/latest/download/install.sh | sh
```

It installs the latest release in `~/.local/share/graft`, with the command at `~/.local/bin/graft`.
Run it again to update; `GRAFT_VERSION=0.3.0` before `sh` installs that release instead.

Or by hand: download `graft.tar.gz` from a release on
<https://github.com/brandnewbox/graft/releases>, then

```sh
rm -rf ~/.local/share/graft && tar -xzf graft.tar.gz -C ~/.local/share
ln -sfn ~/.local/share/graft/graft ~/.local/bin/graft
```
`graft version` says which graft it is and which Xcodes it has toolchains for. Each graft release
runs the same toolchain images, pinned by digest.

## Setup, once per machine

You need:

- x86_64 Linux with Docker (your user in the `docker` group) and Tailscale, on the tailnet the
  devices are on;
- 30 GB free for Docker during setup; after, each Xcode's image is 6.2 GB and its SDK 3.5 GB;
- an iPhone or iPad on iOS 27 with the Tailscale app;
- an App Store Connect API key for a paid team: App Store Connect → Users and Access →
  Integrations → App Store Connect API → Team Keys, App Manager role. Making one takes Admin or
  Account Holder, and the .p8 downloads once.

1. **The SDK.** Download the .xip of the Xcode your projects build with (see The Xcode, below)
   from <https://developer.apple.com/download/all/?q=Xcode>, then

   ```sh
   graft setup ~/Downloads/Xcode_27.1.xip
   ```

   It pulls that Xcode's toolchain image, checks the .xip is that Xcode (a minute), and makes the
   SDK in its volume, `graft-sdk-27.1`: about 7 minutes more. The .xip isn't needed after. The
   Xcode is in the file's name; for a file named otherwise, `graft setup --xcode 27.1 FILE`.
   Another Xcode is another setup.

2. **Settings**, in `~/.config/graft/env`:

   ```sh
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ASC_KEY_COMMAND='op read "op://VAULT/ITEM/AuthKey_XXXXXXXXXX.p8"'
   ```

   The .p8 can manage the whole team's certificates, devices and profiles, so keep it encrypted.
   `ASC_KEY_COMMAND` is a command that prints it. graft runs it only when a deploy has to go
   to App Store Connect (the first for an app or a device, then yearly), puts the key in a file in
   memory (`$XDG_RUNTIME_DIR`) for that run, and deletes it after.

   - 1Password: attach the .p8 to an item and read it as above (add `--account` for a second
     account). Without the desktop app's CLI integration, sign in first: `eval $(op signin)`.
   - gpg: `gpg -c AuthKey_XXXXXXXXXX.p8` (asks for a passphrase), delete the original, and use
     `ASC_KEY_COMMAND='gpg -d ~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8.gpg'`.
   - Or `ASC_KEY_PATH=` the plain .p8.

3. **The devices**, below.

## Devices

graft deploys to the devices in `~/.config/graft/devices`, which `graft pair` and `graft devices`
manage. Set up each device once per machine:

1. **On the device:** Developer Mode on (Settings → Privacy & Security; without Xcode it isn't
   listed until revealed, see "Pair on a Mac"), Wi-Fi on and the Tailscale VPN on. Wi-Fi is required
   even across the tailnet: on cellular only, the device closes the port the tunnel uses.
2. **Its Tailscale address:** its line in `tailscale status`.
3. **Pair it** on a Mac, over USB, and import the record here with a name: `iphone`, `ipad`
   (below). graft adds it to the devices. The pairing record holds a private key: anyone with it
   and a route to the device can drive the device. graft keeps it in `graft-state`.

`graft pair` alone prints these steps.

### Pair on a Mac

With the device on the Mac's USB, unlocked:

```sh
python3.13 -m venv ~/pmd3 && ~/pmd3/bin/pip install pymobiledevice3
~/pmd3/bin/pymobiledevice3 amfi reveal-developer-mode                # if Developer Mode isn't listed
~/pmd3/bin/pymobiledevice3 lockdown remotepairing --pair             # accept on the device
~/pmd3/bin/python - <<'PY'                                          # pin the host ID, see below
import glob, os, plistlib
from pymobiledevice3.pair_records import generate_host_id
for p in glob.glob(os.path.expanduser("~/.pymobiledevice3/remote_*.plist")):
    d = plistlib.load(open(p, "rb")); d.setdefault("host_identifier", generate_host_id())
    open(p, "wb").write(plistlib.dumps(d)); os.chmod(p, 0o600); print(p)
PY
```

It prints the path of each record, `~/.pymobiledevice3/remote_<udid>.plist`. Copy the device's
record to the Linux machine, then, there:

```sh
graft pair ipad 100.64.0.9 remote_<udid>.plist    # NAME TAILNET_IP FILE
```

and delete both copies of the record, the one on the Mac too; graft keeps its own. The device ties
a pairing to the paired machine's host ID, which pymobiledevice3 derives from the hostname; pinning
it in the record lets any machine use it.

### Manage them

```sh
graft devices                            # list them, with whether each is paired
graft devices default ipad               # the default for deploy (at first, the first paired)
graft devices add ipad 100.64.0.10       # change its address, or name a record already paired
graft devices remove ipad                # remove it and its pairing record
graft deploy --device ipad               # deploy to it
```

Deploy finds a device's RemotePairing port itself and remembers it. If it ever can't, it says so;
give the port with `graft devices add ipad 100.64.0.9 --port 52299` (a Mac on the same Wi-Fi lists it:
`~/pmd3/bin/pymobiledevice3 bonjour remotepairing`). graft then tries only that port.

The profiles list every device, so changing devices doesn't make new ones; a new device goes to App
Store Connect once, on its first deploy. The app has to support the device: an iPad needs
`TARGETED_DEVICE_FAMILY` to include 2.

## Use

At the project's root:

```sh
graft build                              # a Debug build of the app
graft build --release                    # a Release build
graft build --configuration Beta         # a build of another configuration
graft deploy                             # build, then sign, install and launch it on the device
graft deploy --release                   # the same with a Release build
graft deploy path/to/MyApp.app           # an app already built: sign, install and launch it
graft deploy --device ipad               # on another device than the default (see Devices)
```

The container sees the current directory at the same path, so run graft at the project's root, and
an app you deploy has to be under it.

### The Xcode

A project builds with one Xcode's SDK and that Xcode's Swift. graft takes the version from
`xcode:` in `graft.yml` (see An Xcode project), else from `.xcode-version` (the file xcodes and
fastlane read), else it uses the newest Xcode it has a toolchain for. Name it, so a graft update
doesn't move the project to a new Xcode:

```yaml
xcode: 27.1
```

The version has to be one in `graft version`; for one that isn't, update graft. `GRAFT_XCODE=27.1`
before a command overrides the project's. A build with no SDK for the Xcode says which .xip to
download for `graft setup`.

An xtool package (`xtool.yml` at the root) builds as it is, into `xtool/<App>.app`. An Xcode project
builds through an adapter (below), and `build` and `deploy` take the app target there:
`graft build MyApp`. The configuration is `Debug` unless you give one; `Debug` is a SwiftPM debug
build and every other configuration a release build. graft builds with omarchy-apple-dev's
`ship.sh --device`, not `xtool dev build`: it also copies the app's resources to the bundle root,
where Xcode puts them and `Bundle.main` finds them.

**Unlock the device before you deploy, and keep it unlocked until the app launches.** An idle
device closes the port the tunnel uses (deploy says "The device didn't answer"), and a locked one
can stall an install or refuse the launch. When only the launch is refused, deploy says the app is
installed and the device is locked, with the command that installs and launches it again without
building: `graft deploy path/to/MyApp.app`.

After the build, `deploy` signs, opens the tunnel, installs and launches. Signing uses an iOS Development certificate
and a profile per bundle ID (the app's and its extensions') kept in `graft-state`. Only when one
is missing, expires within a day or doesn't list the device (or with `deploy --provision`) does it
go to App Store Connect with the API key, to register the devices in the team and make them. The
rest of the time, building and deploying need neither the key nor the internet, only Tailscale to
the device.
Profiles it makes are named `omarchy-apple-dev development <bundle id>`, and it replaces only those.

A free Apple ID can't be used: xtool signs with one only inside `xtool dev run`, which needs the
device on USB.

A graft update can bring new toolchain images, which graft pulls when it first needs them. The SDK
stays: the first run with a new image puts that image's build tools in the SDK, in seconds. Only a
new Xcode means `setup` again.

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

Settings go in `graft.yml` at the project's root. Every key is optional:

```yaml
xcode: 27.1                     # the Xcode to build with (The Xcode, above)
project: ios/MyApp.xcodeproj    # the Xcode project; default: the only one found
target: MyApp                   # the app target when none is given; default: the only one
```

With `project:` or `target:`, graft builds the project as an Xcode project even when there is an
`xtool.yml`. Each key is one line, `key: value`; graft doesn't read more of YAML than that.

## Trademarks

Apple, iPhone, iOS, macOS and Xcode are trademarks of Apple Inc. graft is not affiliated with,
sponsored by or endorsed by Apple. It contains no Apple software: each user makes the SDK from their
own Xcode download, under Apple's license.

## Maintaining

graft is two things, versioned apart:

- **The command**: `graft`, which runs on the host; `libexec/`, the commands it runs in the container
  (`graft-build`, `graft-deploy`, `graft-devices`, `iphone-deploy`, `iphone-pair`); graft's copies
  of some of omarchy-apple-dev's tools (`vendor/`); and `toolchains`, the image for each Xcode.
  Releases are `vX.Y.Z` tags.
- **The toolchain images** (`toolchain/`): the toolchain, built for one Xcode and its Swift, with
  only the scripts that make and run it (the entrypoint, `home-writable`, `installer-steps`,
  `setup-sdk`). They're open source only.

graft mounts `libexec/` at `/opt/graft/bin`, which the image puts on `PATH`, and the vendored tools
over upstream's in `/home/dev/omarchy-apple-dev/tools/`. So a change to the commands is a graft
release alone, and the commands can use anything in an image that `toolchains` pins; the image
workflow checks the files they use are there.

`vendor/omarchy-apple-dev/tools/` holds copies of omarchy-apple-dev's tools, under its MIT license
(`vendor/omarchy-apple-dev/LICENSE`), changed for graft; graft mounts them over upstream's, beside
the tools they call:

- `xcodeproj2xtool.py`, the converter: it reads a configuration given with `--configuration`
  (upstream reads only Release), and it skips resources that are in the project but not on disk.
  CI runs its `--self-test`.
- `provision-dev.py`: `--device UDID NAME`, repeatable, so the profiles list every device.
- `tailnet-tunnel.py`: without `--port`, it finds the RemotePairing port in 49152-65535 (upstream:
  49152-49167), first on the port in `--port-file` that worked last, and its exit status tells
  "nothing answered" (3) from "ports answered, but none was RemotePairing" (4).

Each one's header names the upstream commit it came from. When `OMARCHY_REF` moves, diff
upstream's file from that commit to the new one, apply what's useful, and update the header.

Releasing the images and the command: [RELEASE.md](RELEASE.md).

### Toolchain images

The entrypoint gives the image's user (UID 1000) the caller's UID and GID at start, so it works for
anyone; `home-writable` opens up the few home directories that builds write to. `OMARCHY_REF` in
the Dockerfile pins omarchy-apple-dev, and its installer pins xtool. `setup-sdk` copies build tools
the image built (actool, the macro server) into the SDK and records which (`/sdk/sdk-tools`); when
an SDK has another image's, the entrypoint installs the running image's.

To build one locally, for working on the Dockerfile, and run graft with it:

```sh
docker build -t graft-toolchain:dev --build-arg XCODE_VERSION=27.1 --build-arg SWIFT_VERSION=6.4.1 toolchain
GRAFT_IMAGE=graft-toolchain:dev graft build
```

`GRAFT_IMAGE` runs any toolchain image, with the SDK of the Xcode in its label.

### The command

To work on the command, run `./graft` from a checkout: it finds `libexec/`, `vendor/` and
`toolchains` beside itself.
