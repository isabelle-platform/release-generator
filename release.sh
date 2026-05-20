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
args="$@"

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
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift 1
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
    echo $@ >&2
    exit 1
}

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
        intranet|cloudcpe|midair|proteos)
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

    echo "Put git credentials to ${cred_file} (global config: ${GIT_CONFIG_GLOBAL})"
}

function release_git_creds() {
    rm -f "$(pwd)/.git-credentials" "$(pwd)/.gitconfig-run"
    unset GIT_CONFIG_GLOBAL
    unset CARGO_NET_GIT_FETCH_WITH_CLI
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
        tar xvf core.tar.xz
        rm core.tar.xz
        mv isabelle-core ${flavour}-core
    popd > /dev/null

    return 0
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

    local build_root
    build_root="$(pwd)/build-shell"
    rm -rf "${build_root}"
    mkdir -p "${build_root}"

    git clone --depth 1 --branch "${core_branch}" "${url_core_src}" \
        "${build_root}/isabelle-core" \
        || fail "Failed to clone isabelle-core (branch ${core_branch})"

    # Generate the shell crate (Cargo.toml + src/main.rs) next to the core
    # clone. `../isabelle-core` is the path from the shell dir back to core.
    python3 "${build_root}/isabelle-core/tools/gen_shell.py" \
        "${flavour}" \
        "../isabelle-core" \
        "${build_root}/shell" \
        "${flavour_json}" \
        || fail "Failed to generate shell crate for ${flavour}"

    pushd "${build_root}/shell" > /dev/null
        cargo build --release \
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

    rm -rf "${build_root}"
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
            tar xvf ui.tar.xz
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

    ./extras/extras.sh "$@"

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
        tar xvf plugin.tar.xz
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
        intranet|cloudcpe|midair|proteos)
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
        load_plugins "${flavour}"
    popd > /dev/null

    create_data
    generate_default "${flavour}"
    generate_raw

    create_scripts

    write_flavour "${flavour}"
popd > /dev/null

load_extras $args
install_extras
release_wget_creds
release_git_creds

pushd "${out_dir}"
write_release
popd
