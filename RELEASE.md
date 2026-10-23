# Releasing graft

graft has two parts, and each is released on its own:

| Part | What it is | Where it comes from | How it's published |
| --- | --- | --- | --- |
| **Toolchain images** | One Docker image per Xcode, with Swift, xtool and the other build tools | `toolchain/`, for each Xcode in `toolchains` | Automatically, when a change to `toolchain/` or a new Xcode merges to main |
| **The command** | The `graft` command and its scripts | everything else | When you push a `vX.Y.Z` tag |

The file `toolchains` connects them. It lists each Xcode, the Swift version that Xcode ships, and
the exact image graft uses:

```
# XCODE  SWIFT  IMAGE
27.1     6.4.1  ghcr.io/brandnewbox/graft-toolchain@sha256:b86c…
```

The Toolchain workflow reads the same file to know which images to build.

Users only get what a release of the command lists in `toolchains`. A new image does nothing until
you put it in `toolchains` and release the command.

## Release a change to the command

For changes to `graft`, `libexec/`, `vendor/` or `toolchains`.

1. Merge the pull request.
2. Tag main and push the tag:

   ```sh
   git switch main && git pull
   git tag v0.3.1 && git push origin v0.3.1
   ```

The CLI workflow makes a GitHub release with `graft.tar.gz` and `install.sh`. Users update by
running the install command again.

## Release a change to a toolchain image

For changes to `toolchain/`.

1. Merge the pull request. The Toolchain workflow builds and publishes an image for every Xcode in
   `toolchains` (about 20 minutes).
2. Open the finished workflow run in the Actions tab. Its summary has a line like this:

   ```
   27.1     6.4.1  ghcr.io/brandnewbox/graft-toolchain@sha256:…
   ```

3. In `toolchains`, replace that Xcode's line with the new one. Merge the change.
4. Release the command, as above.

## Add a new Xcode

1. Add a line to `toolchains` with the Xcode, the Swift version it ships, and the image's tag (it
   has no digest yet):

   ```
   27.2     6.4.2  ghcr.io/brandnewbox/graft-toolchain:xcode-27.2
   ```

2. Merge it. The Toolchain workflow builds and publishes only the new Xcode's image.
3. Follow steps 2–4 of the toolchain release: replace the line with the pinned one from the
   workflow's summary, merge, and release the command.

Each machine then runs `graft setup` once with that Xcode's .xip.

To remove an old Xcode, delete its line from `toolchains`. Its published images stay.

A change to `toolchains` that only pins digests doesn't build anything.

## If a release fails

The release stops if a line in `toolchains` is not pinned by `@sha256:` digest, or if the image
does not exist. Fix `toolchains` and merge the fix. Then move the tag to the new main:

```sh
git push origin :v0.3.1 && git tag -d v0.3.1
git switch main && git pull
git tag v0.3.1 && git push origin v0.3.1
```

## One-time setup

After the first image is published, open the `graft-toolchain` package on GitHub and make it
public. Without this, users can't pull it.

## Never

Never publish an image with the iOS SDK in it. Apple's license does not allow it. Each user makes
the SDK on their own machine with `graft setup`.
