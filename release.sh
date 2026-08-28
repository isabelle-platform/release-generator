#!/bin/bash
TOP_DIR="$(cd "$(dirname "$(which "$0")")" ; pwd -P)"

releases_login=""
releases_password=""
gh_login=""
gh_password=""
out_dir=""
flavour=""
# Branch of isabelle-core to build from. Defaults to main; override with
# --core-branch to release-test a feature branch.
core_branch="main"
# OpenPGP private key used to sign the release tarball. Empty means "don't
# sign" so local runs work without a key; CI always passes one. The
# passphrase, if the key has one, comes from ${GPG_PASSPHRASE} rather than
# the command line — argv is world-readable via /proc on the build agent.
gpg_key=""
# Fingerprint of the imported signing key; set by put_gpg_key.
gpg_key_id=""
# Keep the original command line for extras.sh, which re-parses it. An array,
# not a string: `args="$@"` flattens every argument into one space-separated
# scalar, and expanding it unquoted then re-splits on whitespace and globs the
# result — so a password containing a space or a `*` reached extras.sh as
# something other than what Jenkins passed in.
declare -a orig_args=("$@")
# Options extras.sh must not see. It lives in a separate repo (per flavour),
# re-parses our command line and hard-fails on anything it doesn't recognise,
# so every option we add here would otherwise have to be added to each extras
# repo in lockstep. Signing is done by release.sh on the finished tarball —
# extras has no use for the key. Value-taking options only; the value is
# dropped along with the flag.
declare -a extras_skip_args=("--gpg-key")

while test -n "$1" ; do
    case "$1" in
        --releases-login)
            releases_login="$2"
            shift 1
            ;;
        --releases-password)
            releases_password="$2"
            shift 1
            ;;
        --gh-login)
            gh_login="$2"
            shift 1
            ;;
        --gh-password)
            gh_password="$2"
            shift 1
            ;;
        --out)
            out_dir="$2"
            shift 1
            ;;
        --flavour)
            flavour="$2"
            shift 1
            ;;
        --core-branch)
            core_branch="$2"
            shift 1
            ;;
        --gpg-key)
            gpg_key="$2"
            shift 1
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift 1
done

# Filter extras_skip_args (and their values) out of the command line handed
# to extras.sh.
declare -a extras_args=()
declare -i skip_next=0
for arg in "${orig_args[@]}" ; do
    if [ ${skip_next} -eq 1 ] ; then
        skip_next=0
        continue
    fi
    for skip in "${extras_skip_args[@]}" ; do
        if [ "${arg}" == "${skip}" ] ; then
            skip_next=1
            break
        fi
    done
    [ ${skip_next} -eq 1 ] || extras_args+=("${arg}")
done

url_core="https://releases.interpretica.io/isabelle-core/branches/main/isabelle-core-main-latest-linux-x86_64.tar.xz"
url_gc="https://${gh_login}:${gh_password}@github.com/isabelle-platform/isabelle-gc.git"
# GitHub URLs are kept "clean" (no embedded creds) — auth is handled by
# git's credential helper that `put_git_creds` configures at runtime. This
# avoids leaking the PAT into local `.git/config` of each clone, build logs,
# and `git ls-remote` output.
url_datagen_equestrian="https://github.com/isabelle-platform/equestrian-data-gen.git"
url_ui_equestrian="https://releases.interpretica.io/isabelle-ui/branches/main/isabelle-ui-main-latest-wasm.tar.xz"
url_datagen_sample="https://github.com/isabelle-platform/sample-data-gen.git"
url_ui_sample="https://releases.interpretica.io/sample-ui/branches/main/sample-ui-main-latest-wasm.tar.xz"
url_datagen_intranet="https://github.com/intranet-platform/intranet-data-gen.git"
url_ui_intranet="https://releases.interpretica.io/intranet/branches/main/intranet-main-latest-wasm.tar.xz"
url_datagen_cloudcpe="https://github.com/cloudcpe/cloudcpe-data-gen.git"
url_ui_cloudcpe=""
url_extras_cloudcpe="https://github.com/cloudcpe/cloudcpe-extras.git"
url_extras_midair="https://github.com/interpretica-io/midair-extras.git"
url_extras_proteos="https://github.com/interpretica-io/proteos-extras.git"
url_datagen_didactist="https://github.com/isabelle-platform/didactist-data-gen.git"
url_ui_didactist=""

url_datagen_midair="https://github.com/interpretica-io/midair-data-gen.git"
url_ui_midair="https://releases.interpretica.io/midair/branches/main/midair-main-latest-wasm.tar.xz"

url_datagen_proteos="https://github.com/interpretica-io/proteos-data-gen.git"
url_ui_proteos="https://releases.interpretica.io/proteos/branches/main/proteos-main-latest-wasm.tar.xz"

# Droplet-provisioning CLI the proteos plugin shells out to (PROTOSTAR_BIN).
# Shipped only for the proteos flavour; extracted next to the core binary so
# run.sh can point PROTOSTAR_BIN at it (see load_protostar).
url_protostar="https://releases.interpretica.io/protostar/branches/main/protostar-main-latest-linux-x86_64.tar.xz"

# protostar config (droplet templates + bootstrap script) for the proteos
# flavour. Private repo — auth handled by put_git_creds. Only tracked files
# are cloned; .env, SSH private keys and state.json are gitignored, so no
# secrets land in the archive (see load_protostar_cfgs).
url_protostar_cfgs="https://github.com/interpretica-io/protostar-cfgs.git"

# Webhook runner shipped next to the core binary for the midair flavour.
# Horizon lives in a private repo and publishes prebuilt static musl binaries
# as GitHub release assets, so it is fetched via the GitHub API with the same
# PAT the git credential helper uses (see load_horizon).
url_horizon_release="https://api.github.com/repos/interpretica-io/horizon/releases/latest"

url_datagen_zine="https://github.com/interpretica-io/zine-data-gen.git"
url_ui_zine="https://releases.interpretica.io/zine-ui/branches/main/zine-ui-main-latest-wasm.tar.xz"

url_scripts="https://github.com/isabelle-platform/isabelle-scripts.git"

# Source repo for the core crate. Plugin crates are no longer cloned here:
# core's Cargo.toml lists them as `git = "..."` deps with pinned tags, so
# `cargo build` fetches them automatically (using the git credential
# helper set up by `put_git_creds` for the private ones).
url_core_src="https://github.com/isabelle-platform/isabelle-core.git"

function test_empty_fail() {
    local var="$1"

    if [ "$var" == "" ] ; then
        echo "Input variable is empty"
        exit 1
    fi
    return 0
}

function fail() {
    # Quoted: unquoted $@ re-splits the message on whitespace, which flattens
    # any multi-line diagnostic into one line.
    echo "$@" >&2
    exit 1
}

# Child scripts we hand control to (extras/extras.sh) guard their downloads
# with `|| fail "..."` on the assumption that fail is in scope. It is not:
# they run as separate processes, so the call used to hit `fail: command not
# found`, the script carried on past a failed download and the release was
# published with an empty component. Exporting the function makes those
# guards do what they were written to do.
export -f fail

# Record the git commit (or other identifying string) of a release
# component into distr/hashes/<name>. One file per component — mirrors
# the legacy `core/hash` file but covers every source project.
# Relies on the global ${out_dir} being an absolute path.
function write_hash() {
    local name="$1"
    local value="$2"

    [ -n "${value}" ] || value="unknown"
    mkdir -p "${out_dir}/distr/hashes"
    echo "${value}" > "${out_dir}/distr/hashes/${name}"
    echo "Recorded hash for ${name}: ${value}"
}

# Extract git-sourced crates from a Cargo.lock and record each one's
# pinned commit. crates.io deps carry `registry+...` sources and are
# skipped, so this captures exactly the platform's own plugin projects.
function write_cargo_lock_hashes() {
    local lock="$1"

    [ -f "${lock}" ] || return 0
    awk '
        /^name = "/ { n=$0; sub(/^name = "/,"",n); sub(/".*/,"",n); name=n }
        /^source = "git\+/ {
            s=$0; sub(/^source = "git\+/,"",s); sub(/".*/,"",s)
            h=index(s,"#"); commit=(h>0)?substr(s,h+1):""
            if (name!="" && commit!="") print name" "commit
        }
    ' "${lock}" | while read -r pkg commit ; do
        write_hash "${pkg}" "${commit}"
    done
}

function test_flavour() {
    case "$1" in
        intranet|cloudcpe|midair|proteos|zine)
            ;;
        *)
            echo "Unknown flavour: $1" >&2
            exit 1
    esac
    return 0
}

function put_wget_creds() {
    local releases_login="$1"
    local releases_password="$2"

    touch $(pwd)/.wgetrc
    chmod 600 $(pwd)/.wgetrc
    echo "user=$releases_login" > $(pwd)/.wgetrc
    echo "password=$releases_password" >> $(pwd)/.wgetrc
    export WGETRC_PATH="$(pwd)/.wgetrc"
    echo "Put credentials to ${WGETRC_PATH}"
}

function release_wget_creds() {
    rm $(pwd)/.wgetrc
}

# Import the release signing key into a throwaway GNUPGHOME, so we never
# touch the build agent's real keyring and the whole thing can be wiped in
# one rm. Called early on purpose: a bad or missing key should fail the run
# before the half-hour build, not after it.
function put_gpg_key() {
    local key_file="$1"

    if [ -z "${key_file}" ] ; then
        echo "WARNING: no --gpg-key given, release will NOT be signed" >&2
        return 0
    fi
    [ -f "${key_file}" ] || fail "GPG key file not found: ${key_file}"

    # Deliberately NOT under the workspace: gpg-agent puts its socket inside
    # GNUPGHOME, and a unix socket path is capped at ~104 chars — a deep
    # Jenkins workspace path blows that limit and the agent refuses to start.
    GNUPGHOME="$(mktemp -d "${TMPDIR:-/tmp}/relgen-gnupg.XXXXXX")" \
        || fail "Failed to create temporary GNUPGHOME"
    export GNUPGHOME
    chmod 700 "${GNUPGHOME}"

    # Wipe the key material even if a later stage dies. release_gpg_key is
    # idempotent, so the explicit call at the end of the run is harmless.
    trap release_gpg_key EXIT

    gpg --batch --quiet --import "${key_file}" \
        || fail "Failed to import GPG signing key"

    # Sign by fingerprint rather than by uid: unambiguous if the key file
    # ever carries more than one secret key.
    gpg_key_id="$(gpg --batch --with-colons --list-secret-keys \
                  | awk -F: '/^fpr:/ { print $10 ; exit }')"
    [ -n "${gpg_key_id}" ] || fail "No secret key found in ${key_file}"
    echo "Imported GPG signing key ${gpg_key_id}"
}

function release_gpg_key() {
    [ -n "${GNUPGHOME}" ] || return 0

    # The agent holds the unlocked key in memory and keeps a socket in
    # GNUPGHOME; kill it before removing the directory.
    gpgconf --kill gpg-agent > /dev/null 2>&1 || true
    rm -rf "${GNUPGHOME}"
    unset GNUPGHOME
}

# Detached OpenPGP signature written next to the artifact as <file>.asc.
# Detached rather than attached so the published tarball stays a plain
# tarball: existing consumers keep fetching it unchanged, and the signature
# is simply an extra file they may ignore until they're taught to check it.
function sign_file() {
    local file="$1"

    [ -n "${gpg_key_id}" ] || return 0

    rm -f "${file}.asc"
    # --passphrase-fd over a pipe, not --passphrase: keeps the secret out of
    # argv. An unprotected key just ignores the empty input.
    printf '%s' "${GPG_PASSPHRASE:-}" \
        | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
              --local-user "${gpg_key_id}" \
              --armor --detach-sign --output "${file}.asc" "${file}" \
        || fail "Failed to sign ${file}"
    echo "Signed ${file} -> ${file}.asc"
}

# Re-check the signature we just produced against the public key that ships
# to the hosts in scripts/. Catches the one mistake that would brick every
# installation at once: a CI signing key that no longer matches the key
# clients trust. Cheap here, unfixable once the release is out.
function verify_signature() {
    local file="$1"
    local pubkey="$2"

    [ -n "${gpg_key_id}" ] || return 0
    [ -f "${pubkey}" ] \
        || fail "Public key missing: ${pubkey} — clients would not be able to verify this release"

    local vhome
    vhome="$(mktemp -d "${TMPDIR:-/tmp}/relgen-verify.XXXXXX")" \
        || fail "Failed to create a temporary keyring"
    chmod 700 "${vhome}"

    local rc=0
    GNUPGHOME="${vhome}" gpg --batch --quiet --import "${pubkey}" || rc=1
    if [ ${rc} -eq 0 ] ; then
        GNUPGHOME="${vhome}" gpg --batch --verify "${file}.asc" "${file}" || rc=2
    fi
    GNUPGHOME="${vhome}" gpgconf --kill gpg-agent > /dev/null 2>&1 || true
    rm -rf "${vhome}"

    [ ${rc} -eq 0 ] \
        || fail "Signature does not verify against ${pubkey} — the CI signing key and the key shipped to clients disagree"
    echo "Signature verified against ${pubkey}"
}

# Configure git's `store` credential helper backed by a per-run file. Once
# this is set up, plain `https://github.com/...` URLs work for both git
# clone and Cargo (via CARGO_NET_GIT_FETCH_WITH_CLI=true) — no need to bake
# the PAT into URLs. The helper is scoped to this run via --file=<path>;
# we tear it down at the end via `release_git_creds`.
function put_git_creds() {
    local login="$1"
    local password="$2"

    local cred_file
    cred_file="$(pwd)/.git-credentials"
    : > "$cred_file"
    chmod 600 "$cred_file"

    # Encode user/pw per RFC 3986 in case they contain `@`, `:`, `/` etc.
    local enc_login enc_password
    enc_login=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$login")
    enc_password=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$password")
    echo "https://${enc_login}:${enc_password}@github.com" >> "$cred_file"

    # Older `git config --global` writes go to ~/.gitconfig — but in CI we
    # want this isolated to the run. Use GIT_CONFIG_GLOBAL to point at a
    # per-run file. (git >= 2.32.) For tighter compat, also set it via
    # repo-local config when present.
    export GIT_CONFIG_GLOBAL="$(pwd)/.gitconfig-run"
    : > "$GIT_CONFIG_GLOBAL"
    git config --file "$GIT_CONFIG_GLOBAL" credential.helper "store --file=$cred_file"

    # Cargo uses libgit2 by default, which does NOT honour credential
    # helpers. Switch it to system git so private deps resolve via the
    # same .git-credentials we just wrote.
    export CARGO_NET_GIT_FETCH_WITH_CLI=true

    # Keep Cargo's git/registry cache inside the (writable) workspace.
    # The CI Docker image bakes `HOME=/home/root` owned by root, but the
    # Jenkins agent runs under a different uid, so the default
    # `$HOME/.cargo` is not writable. A workspace-local CARGO_HOME avoids
    # the `Permission denied` failure.
    export CARGO_HOME="$(pwd)/.cargo-home"
    mkdir -p "$CARGO_HOME"

    # Same reason for the Docker CLI: it insists on a config dir under $HOME
    # and fails with `mkdir /home/root/.docker: permission denied` otherwise.
    export DOCKER_CONFIG="$(pwd)/.docker"
    mkdir -p "$DOCKER_CONFIG"

    echo "Put git credentials to ${cred_file} (global config: ${GIT_CONFIG_GLOBAL})"
}

function release_git_creds() {
    rm -f "$(pwd)/.git-credentials" "$(pwd)/.gitconfig-run"
    unset GIT_CONFIG_GLOBAL
    unset CARGO_NET_GIT_FETCH_WITH_CLI
    unset DOCKER_CONFIG
    # CARGO_HOME (.cargo-home) is intentionally left in place — it's just a
    # cache and speeds up subsequent runs in a reused workspace.
    unset CARGO_HOME
}

function download_datagen() {
    local flavour="$1"
    local target_data_gen

    case "$flavour" in
        equestrian)
            target_data_gen="$url_datagen_equestrian"
            ;;
        sample)
            target_data_gen="$url_datagen_sample"
            ;;
        intranet)
            target_data_gen="$url_datagen_intranet"
            ;;
        cloudcpe)
            target_data_gen="$url_datagen_cloudcpe"
            ;;
        didactist)
            target_data_gen="$url_datagen_didactist"
            ;;
        midair)
            target_data_gen="$url_datagen_midair"
            ;;
        proteos)
            target_data_gen="$url_datagen_proteos"
            ;;
        zine)
            target_data_gen="$url_datagen_zine"
            ;;
        *)
            echo "Unknown flavour: $flavour" >&2
            exit 1
    esac

    rm -rf datagen
    git clone --depth 1 --recurse-submodules --shallow-submodules "${target_data_gen}" datagen || fail "Failed to clone Data Generator"
    write_hash "datagen" "$(git -C datagen rev-parse HEAD 2>/dev/null)"
    return 0
}

function load_core() {
    local login="$1"
    local password="$2"
    local flavour="$3"
    local wgetrc="${WGETRC_PATH}"

    mkdir -p core
    pushd core > /dev/null
        WGETRC="${wgetrc}" wget -O core.tar.xz "$url_core" || fail "Failed to get Core"
        tar xvf core.tar.xz || fail "Core tarball is corrupt"
        rm core.tar.xz
        mv isabelle-core ${flavour}-core
    popd > /dev/null

    return 0
}

function cargo_jobs() {
    local cpus

    cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
    [ -n "${cpus}" ] || cpus=1
    [ "${cpus}" -gt 2 ] || { echo 1 ; return 0 ; }

    echo $(( cpus / 2 ))
}

# Build the core binary from source for the given flavour.
#
# The plugin set for each flavour is defined by `flavours/<flavour>.json`
# in THIS repo. We clone isabelle-core (which carries the shell templates
# + generator under tools/gen_shell.py), generate a shell crate from the
# templates + our flavour json, and cargo-build it. The shell crate
# depends on the cloned core via a relative path and on the plugin crates
# via git (resolved by cargo; private deps authenticate through the git
# credential helper `put_git_creds` configured).
#
# Resulting binary lands at `core/<flavour>-core` and the run.sh wrapper
# at `core/run.sh` (flat layout, matching the legacy tarball structure).
function build_core() {
    local flavour="$1"

    local flavour_json="${TOP_DIR}/flavours/${flavour}.json"
    [ -f "${flavour_json}" ] || fail "No flavour definition: ${flavour_json}"

    # Keep build-shell at the repo root (outside out/) so `rm -rf out` in the
    # Jenkins clean-up stage doesn't wipe Cargo's incremental artifacts between
    # builds. This makes subsequent builds significantly faster.
    local build_root="${TOP_DIR}/build-shell"
    mkdir -p "${build_root}"

    # Reuse an existing isabelle-core clone if present so we avoid a full
    # re-clone on every run. Falls back to a fresh clone on first run or if
    # the clone is corrupt.
    if [ -d "${build_root}/isabelle-core/.git" ]; then
        git -C "${build_root}/isabelle-core" fetch --depth 1 origin "${core_branch}" \
            || fail "Failed to fetch isabelle-core (branch ${core_branch})"
        git -C "${build_root}/isabelle-core" reset --hard FETCH_HEAD \
            || fail "Failed to reset isabelle-core to ${core_branch}"
    else
        git clone --depth 1 --branch "${core_branch}" "${url_core_src}" \
            "${build_root}/isabelle-core" \
            || fail "Failed to clone isabelle-core (branch ${core_branch})"
    fi

    # Enable sccache if it is available. SCCACHE_DIR lives in the workspace
    # next to build-shell so it persists across builds without a Docker volume
    # mount. sccache caches at the rustc level, so even a forced full rebuild
    # (e.g. after gen_shell regenerates src/main.rs) is fast on cache hit.
    if command -v sccache > /dev/null 2>&1; then
        export RUSTC_WRAPPER=sccache
        export SCCACHE_DIR="${TOP_DIR}/.sccache"
    fi

    # Generate the shell crate (Cargo.toml + src/main.rs) next to the core
    # clone. `../isabelle-core` is the path from the shell dir back to core.
    python3 "${build_root}/isabelle-core/tools/gen_shell.py" \
        "${flavour}" \
        "../isabelle-core" \
        "${build_root}/shell" \
        "${flavour_json}" \
        || fail "Failed to generate shell crate for ${flavour}"

    # The shell crate is regenerated on every run, but its Cargo.lock survives
    # in build-shell, which is kept between builds for speed. A lock that
    # outlives the crate pins commits the tags may no longer point at: when a
    # tag is re-cut upstream, the stale pin and the fresh resolution both end
    # up in the graph and the build fails with two versions of one crate. The
    # tags in the flavour json and the plugins' manifests are the real pin, so
    # resolve from them every time.
    rm -f "${build_root}/shell/Cargo.lock"

    local jobs="${CARGO_BUILD_JOBS:-$(cargo_jobs)}"
    echo "Building core shell with ${jobs} parallel job(s)"

    pushd "${build_root}/shell" > /dev/null
        cargo build --release --jobs "${jobs}" \
            || fail "Failed to build core shell for ${flavour}"
    popd > /dev/null

    mkdir -p core
    cp "${build_root}/shell/target/release/isabelle-core-${flavour}" \
        "core/${flavour}-core" \
        || fail "Built binary missing"
    chmod +x "core/${flavour}-core"

    # run.sh wrapper lives in the core repo we just cloned.
    if [ -f "${build_root}/isabelle-core/run.sh" ] ; then
        cp "${build_root}/isabelle-core/run.sh" "core/run.sh"
        chmod +x "core/run.sh"
    fi

    # Record source hashes: core itself plus every git-pinned plugin
    # crate resolved into the shell crate's Cargo.lock.
    write_hash "core" "$(git -C "${build_root}/isabelle-core" rev-parse HEAD 2>/dev/null)"
    write_cargo_lock_hashes "${build_root}/shell/Cargo.lock"

    # build-shell is intentionally kept for incremental Cargo recompilation
    # on the next run. .sccache is similarly kept as the compiler cache.
    return 0
}

function load_gc() {
    local login="$1"
    local password="$2"
    local wgetrc="${WGETRC_PATH}"

    mkdir -p core
    pushd core > /dev/null
        if [ ! -d isabelle-gc ] ; then
            git clone --depth 1 --recurse-submodules --shallow-submodules ${url_gc} isabelle-gc || fail "Failed to get isabelle-gc"
            write_hash "isabelle-gc" "$(git -C isabelle-gc rev-parse HEAD 2>/dev/null)"
            rm -rf isabelle-gc/.git
        fi
    popd > /dev/null

    return 0
}

# Ship the protostar CLI next to the core binary so the proteos plugin can
# spawn it (PROTOSTAR_BIN). Only the proteos flavour needs it; every other
# flavour gets an empty target and this is a no-op. The binary lands at
# core/protostar — the same dir as core/run.sh — so run.sh resolves it via
# $TOP_DIR/protostar.
function load_protostar() {
    local flavour="$1"
    local wgetrc="${WGETRC_PATH}"
    local target_protostar
    local protostar_hash=""

    case "$flavour" in
        proteos)
            target_protostar="$url_protostar"
            ;;
        *)
            target_protostar=""
            ;;
    esac

    [ -n "${target_protostar}" ] || return 0

    mkdir -p core
    pushd core > /dev/null
        WGETRC="${wgetrc}" wget -O protostar.tar.xz "${target_protostar}" \
            || fail "Failed to get protostar"
        tar xvf protostar.tar.xz || fail "Protostar tarball is corrupt"
        rm protostar.tar.xz
        # The protostar tarball ships its own short git hash in `hash`;
        # record it under hashes/ then drop the stray file from the release
        # root so it doesn't sit next to the binary.
        if [ -f hash ] ; then
            protostar_hash="$(cat hash 2>/dev/null)"
            rm -f hash
        fi
        chmod +x protostar 2>/dev/null || true
    popd > /dev/null
    write_hash "protostar" "${protostar_hash}"

    return 0
}

# Ship the protostar config for the proteos flavour, next to the binary at
# core/protostar-cfgs. The git clone carries only tracked files — .env, the
# SSH private keys under keys/ and the live state.json are all gitignored,
# so the archive stays secret-free. protostar.yaml is refreshed on every
# update; state.json is created at runtime in this same dir and, being absent
# from the tarball, survives in-place updates (tar never overwrites it).
function load_protostar_cfgs() {
    local flavour="$1"
    local target_cfgs

    case "$flavour" in
        proteos)
            target_cfgs="$url_protostar_cfgs"
            ;;
        *)
            target_cfgs=""
            ;;
    esac

    [ -n "${target_cfgs}" ] || return 0

    mkdir -p core
    pushd core > /dev/null
        if [ ! -d protostar-cfgs ] ; then
            git clone --depth 1 --recurse-submodules --shallow-submodules \
                "${target_cfgs}" protostar-cfgs \
                || fail "Failed to get protostar-cfgs"
            write_hash "protostar-cfgs" "$(git -C protostar-cfgs rev-parse HEAD 2>/dev/null)"
            rm -rf protostar-cfgs/.git
        fi
    popd > /dev/null

    return 0
}

# Ship the horizon webhook runner next to the core binary. Only the midair
# flavour carries it; every other flavour gets an empty target and this is a
# no-op. Release assets of a private repo can't be fetched by plain URL, so
# we resolve the latest release through the GitHub API (Authorization: token)
# and download the static x86_64 musl binary asset. The binary lands at
# core/horizon — the same dir as core/run.sh.
function load_horizon() {
    local flavour="$1"

    case "$flavour" in
        midair)
            ;;
        *)
            return 0
            ;;
    esac

    local release_json tag asset_url
    release_json="$(curl -sfL -H "Authorization: token ${gh_password}" \
        "${url_horizon_release}")" \
        || fail "Failed to query horizon latest release"
    tag="$(echo "${release_json}" | python3 -c \
        'import sys, json; print(json.load(sys.stdin)["tag_name"])')" \
        || fail "Failed to parse horizon release tag"
    asset_url="$(echo "${release_json}" | python3 -c 'import sys, json
r = json.load(sys.stdin)
print(next(a["url"] for a in r["assets"]
           if a["name"] == "horizon-x86_64-unknown-linux-musl"))')" \
        || fail "No horizon linux x86_64 binary in release ${tag}"

    mkdir -p core
    pushd core > /dev/null
        curl -sfL -H "Authorization: token ${gh_password}" \
            -H "Accept: application/octet-stream" \
            -o horizon "${asset_url}" \
            || fail "Failed to download horizon ${tag}"
        chmod +x horizon
    popd > /dev/null
    write_hash "horizon" "${tag}"

    return 0
}

function load_ui() {
    local flavour="$1"
    local wgetrc="${WGETRC_PATH}"
    local target_ui
    local ui_hash=""

    case "$flavour" in
        equestrian)
            target_ui="$url_ui_equestrian"
            ;;
        sample)
            target_ui="$url_ui_sample"
            ;;
        intranet)
            target_ui="$url_ui_intranet"
            ;;
        cloudcpe)
            target_ui="$url_ui_cloudcpe"
            ;;
        didactist)
            target_ui="$url_ui_didactist"
            ;;
        midair)
            target_ui="$url_ui_midair"
            ;;
        proteos)
            target_ui="$url_ui_proteos"
            ;;
        zine)
            target_ui="$url_ui_zine"
            ;;
        *)
            echo "Unknown flavour: $flavour" >&2
            exit 1
    esac

    mkdir -p ui
    if [ "${target_ui}" != "" ] ; then
        pushd ui > /dev/null
            WGETRC="${wgetrc}" wget -O ui.tar.xz "${target_ui}" || fail "Failed to get UI"
            # UI ships as a prebuilt wasm tarball — there is no git
            # checkout to hash, so record the artifact's sha256 instead.
            ui_hash="$(sha256sum ui.tar.xz 2>/dev/null | awk '{print $1}')"
            tar xvf ui.tar.xz || fail "UI tarball is corrupt"
            rm ui.tar.xz
        popd > /dev/null
        write_hash "ui" "${ui_hash}"
    fi

    return 0
}

function load_extras() {
    local target_extras

    case "$flavour" in
        equestrian)
            target_extras=""
            ;;
        sample)
            target_extras=""
            ;;
        intranet)
            target_extras=""
            ;;
        cloudcpe)
            target_extras="$url_extras_cloudcpe"
            ;;
        didactist)
            target_extras=""
            ;;
        midair)
            target_extras="$url_extras_midair"
            ;;
        proteos)
            target_extras="$url_extras_proteos"
            ;;
        zine)
            target_extras=""
            ;;
        *)
            echo "Unknown flavour: $flavour" >&2
            exit 1
    esac

    if [ "$target_extras" == "" ] ; then
        return 0
    fi

    if [ ! -d extras ] ; then
        git clone --depth 1 --recurse-submodules --shallow-submodules ${target_extras} extras || fail "Failed to get extras"
        write_hash "extras" "$(git -C extras rev-parse HEAD 2>/dev/null)"
        rm -rf extras/.git
    fi

    ./extras/extras.sh "$@" || fail "Failed to run extras"

    # extras.sh downloads with `wget -O <file>`, which truncates the target
    # before it knows whether the transfer will succeed: a 401 leaves a
    # zero-byte tarball behind, and `tar` failing on it is just as invisible
    # as the download was. Refuse to publish a release with an empty artifact
    # rather than ship a component that silently kept its previous version on
    # the target host.
    local empty
    empty="$(find "${out_dir}" -type f -empty -name '*.tar.xz' -print 2>/dev/null)"
    if [ -n "${empty}" ] ; then
        fail "Extras produced empty artifacts (failed download?):"$'\n'"${empty}"
    fi

    return 0
}

function install_extras() {
    mkdir -p "${out_dir}/scripts/extras"
    if [ -d extras/deploy ] ; then
        cp -R extras/deploy ${out_dir}/scripts/extras
    fi
    if [ -d extras/service ] ; then
        cp -R extras/service ${out_dir}/scripts/extras/
    fi
    if [ -d extras/nginx ] ; then
        cp -R extras/nginx ${out_dir}/scripts/extras/
    fi
    if [ -d extras/systemd ] ; then
        cp -R extras/systemd ${out_dir}/scripts/extras/
    fi
    for helper in extras/*.sh ; do
        [ -f "${helper}" ] || continue
        case "$(basename "${helper}")" in
            extras.sh) ;;
            *) cp "${helper}" "${out_dir}/scripts/extras/" ;;
        esac
    done
}

function load_plugin() {
    local wgetrc="$1"
    local url="$2"

    mkdir -p core
    pushd core > /dev/null
        WGETRC="${wgetrc}" wget -O plugin.tar.xz "${url}" || fail "Failed to get plugin"
        tar xvf plugin.tar.xz || fail "Plugin tarball is corrupt"
        rm plugin.tar.xz
    popd > /dev/null

    return 0
}

function load_plugins() {
    local flavour="$1"

    # All actor-mode flavours: plugins are statically linked into the core
    # binary via `cargo build --features <flavour>` (see `build_core`). No
    # separate plugin tarballs anymore. Kept as a no-op so the rest of the
    # pipeline doesn't need a conditional.
    case "$flavour" in
        intranet|cloudcpe|midair|proteos|zine)
            return 0
            ;;
        *)
            echo "Unknown flavour: $flavour" >&2
            exit 1
            ;;
    esac
}

function create_data() {
    mkdir -p data
    pushd data > /dev/null
    mkdir -p database
    popd > /dev/null
}

function create_scripts() {
    if [ ! -d scripts ] ; then
        git clone --depth 1 --recurse-submodules --shallow-submodules "${url_scripts}" scripts || fail "Failed to get scripts"
        write_hash "scripts" "$(git -C scripts rev-parse HEAD 2>/dev/null)"
        rm -rf scripts/.git
    fi
    echo > scripts/.in_release
}

function generate_default() {
    mkdir -p data/default
    pushd data/default > /dev/null
        ${TOP_DIR}/datagen/generate.sh "$(pwd)"
    popd > /dev/null
    return 0
}

function generate_raw() {
    local default_dir="$(pwd)/data/default"
    cp -r "${default_dir}" "$(pwd)/data/raw"
    return 0
}

function write_flavour() {
    echo "$1" > .flavour
    return 0
}

function write_release() {
    tar cJvf release.tar.xz .flavour *
    sign_file "$(pwd)/release.tar.xz"
    verify_signature "$(pwd)/release.tar.xz" "$(pwd)/scripts/isabelle-release-pubkey.asc"
    return 0
}

test_empty_fail "$gh_login"
test_empty_fail "$gh_password"
test_empty_fail "$releases_login"
test_empty_fail "$releases_password"
test_empty_fail "$out_dir"
test_empty_fail "$flavour"
test_flavour "$flavour"

# Set git credentials BEFORE the first clone — datagen/extras live in
# private GitHub orgs and the URLs no longer carry inline creds.
put_git_creds "$gh_login" "$gh_password"

put_gpg_key "$gpg_key"

# Create the output dir up front and make its path absolute, so helpers
# that run from varying working directories (write_hash) can reliably
# write into ${out_dir}/distr/hashes regardless of the current cwd.
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"

download_datagen "$flavour"

put_wget_creds "$releases_login" "$releases_password"
pushd "${out_dir}" > /dev/null
    mkdir -p distr
    pushd distr > /dev/null
        # Every flavour now builds core from source — plugins are
        # statically linked via `--features <flavour>`. No more separate
        # plugin tarballs; `load_plugins` is a no-op for everyone.
        build_core "${flavour}"
        load_gc
        load_ui "${flavour}"
        load_protostar "${flavour}"
        load_protostar_cfgs "${flavour}"
        load_horizon "${flavour}"
        load_plugins "${flavour}"
    popd > /dev/null

    create_data
    generate_default "${flavour}"
    generate_raw

    create_scripts

    write_flavour "${flavour}"
popd > /dev/null

load_extras "${extras_args[@]}"
install_extras
release_wget_creds
release_git_creds

pushd "${out_dir}"
write_release
popd

# Signing is the last thing that needs the key — drop it immediately.
release_gpg_key
