# Katana User Repository

Katana UR builds community package recipes, publishes `.kat` archives as GitHub
Release assets, and updates the package index in Cloudflare R2.

## Recipe format

A recipe contains metadata followed by `build()` and `package()` shell
functions:

```sh
name=my-app
version=1.0.0
description=My application
arch=x86_64
dependencies=
source=https://github.com/example/my-app.git

build() {
    make
}

package() {
    install -Dm755 my-app "$pkgdir/usr/bin/my-app"
}
```

The builder clones the HTTPS Git source before running `build()`. The
`package()` function installs files under `$pkgdir`; the builder scans that
directory, generates `metadata.json`, and creates the `.kat` archive and build
manifest. See [`TEMPLATE/`](./TEMPLATE/) for a working example.

To build locally, install Bash, Git, GNU tar, and `jq`, then run:

```sh
./build.sh path/to/my-app.recipe output-directory
```

The recipe filename must match its package name, for example
`my-app.recipe` for `name=my-app`.

## Web submissions and queue builds

The `worker/` directory contains the Cloudflare Worker that validates
submissions and writes complete recipes to the R2 `queue/` prefix. It does not
execute submitted code. Deploy it from that directory with Wrangler after
configuring the `KATPKGS` R2 binding to the `katpkgs-storage` bucket:

```sh
cd worker
npx wrangler deploy
```

The `poll-build.yml` workflow runs every 30 minutes or by manual dispatch. It
requires the repository secrets `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`R2_ENDPOINT`, and `R2_BUCKET`. Repository Actions permissions must allow the
workflow to create and update releases.

Recipe functions are untrusted shell code. The workflow runs them in a
credential-free build job. A separate publishing job receives the R2 and
release credentials and handles build artifacts as data; it does not source or
execute recipe content.

The web form accepts public HTTPS Git sources only. It does not upload local
source files or precompiled binaries.
