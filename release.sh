#!/bin/bash
TOP_DIR="$(cd "$(dirname "$(which "$0")")" ; pwd -P)"

releases_login=""
releases_password=""
gh_login=""
gh_password=""
out_dir=""
flavour=""

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
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
    esac
    shift 1
done

url_core="https://releases.interpretica.io/isabelle-core/branches/main/isabelle-core-main-latest-linux-x86_64.tar.xz"
url_gc="https://${gh_login}:${gh_password}@github.com/isabelle-platform/isabelle-gc.git"
url_datagen_equestrian="https://${gh_login}:${gh_password}@github.com/isabelle-platform/equestrian-data-gen.git"
url_ui_equestrian="https://releases.interpretica.io/isabelle-ui/branches/main/isabelle-ui-main-latest-wasm.tar.xz"
url_datagen_intranet="https://${gh_login}:${gh_password}@github.com/intranet-platform/intranet-data-gen.git"
url_ui_intranet="https://releases.interpretica.io/intranet/branches/main/intranet-main-latest-wasm.tar.xz"

url_scripts="https://${gh_login}:${gh_password}@github.com/isabelle-platform/isabelle-scripts.git"

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

function test_flavour() {
	case "$1" in
		equestrian|intranet)
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
}

function release_wget_creds() {
	rm $(pwd)/.wgetrc
}

function download_datagen() {
	local flavour="$1"
	local target_data_gen

	case "$flavour" in
	    equestrian)
	        target_data_gen="$url_datagen_equestrian"
	        ;;
	    intranet)
	        target_data_gen="$url_datagen_intranet"
	        ;;
	    *)
	        echo "Unknown flavour: $flavour" >&2
	        exit 1
	esac

	rm -rf datagen
	git clone "${target_data_gen}" datagen || fail "Failed to clone Data Generator"
	return 0
}

function load_core() {
	local login="$1"
	local password="$2"
	local flavour="$3"
	local wgetrc="$(pwd)/.wgetrc"

	mkdir -p core
    pushd core > /dev/null
        WGETRC="${wgetrc}" wget -O core.tar.xz "$url_core" || fail "Failed to get Core"
        tar xvf core.tar.xz
        rm core.tar.xz
        mv isabelle-core ${flavour}-core
    popd > /dev/null

	return 0
}

function load_gc() {
	local login="$1"
	local password="$2"
	local wgetrc="$(pwd)/.wgetrc"

	mkdir -p core
    pushd core > /dev/null
        git clone ${url_gc} isabelle-gc || fail "Failed to get isabelle-gc"
        rm -rf isabelle-gc/.git
    popd > /dev/null

	return 0
}

function load_ui() {
	local flavour="$1"
	local wgetrc="$(pwd)/.wgetrc"
	local target_ui

	case "$flavour" in
	    equestrian)
	        target_ui="$url_ui_equestrian"
	        ;;
	    intranet)
	        target_ui="$url_ui_intranet"
	        ;;
	    *)
	        echo "Unknown flavour: $flavour" >&2
	        exit 1
	esac

	mkdir -p ui
	pushd ui > /dev/null
		WGETRC="${wgetrc}" wget -O ui.tar.xz "${target_ui}" || fail "Failed to get UI"
		tar xvf ui.tar.xz
		rm ui.tar.xz
	popd > /dev/null

	return 0
}

function create_data() {
	mkdir -p data
	pushd data > /dev/null
	mkdir -p database
	popd > /dev/null
}

function create_scripts() {
	git clone "${url_scripts}" scripts || fail "Failed to get scripts"
	rm -rf scripts/.git
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

download_datagen "$flavour"

mkdir -p "${out_dir}"
pushd "${out_dir}" > /dev/null
	mkdir -p distr
	pushd distr > /dev/null
		put_wget_creds "$releases_login" "$releases_password"
		load_core "${gh_login}" "${gh_password}" "${flavour}"
		load_gc
		load_ui "${flavour}"
		release_wget_creds
	popd > /dev/null

	create_data
	generate_default "${flavour}"
	generate_raw

	create_scripts

	write_flavour "${flavour}"
	write_release
popd > /dev/null
