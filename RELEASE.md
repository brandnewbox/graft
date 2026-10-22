# Releasing graft

graft releases two things apart (README.md, Maintaining):

- **The toolchain images**, `ghcr.io/brandnewbox/graft-toolchain:xcode-<Xcode>`, one per Xcode, from
  `toolchain/`. `.github/workflows/toolchain.yml` publishes them.
- **The command**, `graft.tar.gz` and `install.sh` on a GitHub release, from a `vX.Y.Z` tag.
  `.github/workflows/cli.yml` makes the release.

Users get only what a command release pins: `toolchains` names each Xcode's image by digest. So a
published image changes nothing until a release of the command pins it.

## The workflows

`toolchain.yml` runs when `toolchain/` or the workflow changes:

- on a pull request, it builds each image in its matrix and checks the tools start;
- on main, and when run from the Actions tab, it also publishes `xcode-<Xcode>` and
  `xcode-<Xcode>-<short commit>`. The job's summary has the image's line for `toolchains`, pinned by
  digest:

  ```
  27.1     6.4.1  ghcr.io/brandnewbox/graft-toolchain@sha256:…
  ```

A build takes about 20 minutes.

`cli.yml` checks the command on every pull request and push to main: shellcheck, the converter's
self-test, and `toolchains`. On a `v*` tag it also releases. The release stops when an image in
`toolchains` isn't pinned by digest or isn't published.

## A change to the command only

A change to `graft`, `libexec/` or `vendor/`:

1. Merge the pull request.
2. Tag main and push the tag:

   ```sh
   git tag v0.3.1 && git push origin v0.3.1
   ```

## A change to a toolchain image

A change to `toolchain/` (a new `OMARCHY_REF`, say):

1. Merge the pull request. The toolchain workflow publishes the new images from main.
2. When it's done, copy each image's line from the job's summary into `toolchains`, in place of
   that Xcode's line, and merge that too. Test it first if you like: `./graft build` from a checkout
   runs the image `toolchains` names.
3. Tag the commit that pins them, as above.

## A new Xcode

1. Add the Xcode and the Swift it ships to the matrix in `toolchain.yml`:

   ```yaml
   - xcode: "27.2"
     swift: "6.4.2"
   ```

   and merge it. The workflow publishes its image.
2. Add the image's line from the job's summary to `toolchains`, and merge that.
3. Tag the commit, as above. `graft version` then lists the new Xcode, and projects that name it
   build with it. Each machine makes its SDK once, with `graft setup` and that Xcode's .xip.

An Xcode no project uses any longer can leave the matrix and `toolchains`; its published images
stay.

## Once

The first publish of the images makes the `graft-toolchain` package private: make it public, in
the package's settings on GitHub.

Never publish anything with the SDK in it: Apple's license doesn't allow redistributing it.
