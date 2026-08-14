# Release generator for Isabelle project

It is supposed to be run from Jenkins, but you can also invoke it from a live system.

## Release signing

`release.tar.xz` is signed with a detached OpenPGP signature, published next
to it as `release.tar.xz.asc`. The tarball itself is unchanged — consumers
that don't verify keep working as before.

The signing key is

	Isabelle Release Signing <signing@interpretica.io>
	66C2 5C72 A855 C4AF CD68  1735 C161 003C B406 0BF4

and its public half is committed to `isabelle-scripts`, where `update.sh`
uses it to verify releases before installing them.

The private key lives in the Jenkins credential store:

* `relgen_gpg_key` — *Secret file*, the exported private key
  (`gpg --export-secret-keys --armor <key-id>`)
* `relgen_gpg_passphrase` — *Secret text*, the key's passphrase (create it
  empty if the key has none)

Locally, pass the key with `--gpg-key <file>` and the passphrase via the
`GPG_PASSPHRASE` environment variable. Without `--gpg-key` the run still
succeeds but produces an unsigned release.

To verify a downloaded release:

```sh
gpg --import isabelle-release-pubkey.asc   # once
gpg --verify release.tar.xz.asc release.tar.xz
```