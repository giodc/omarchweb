# OmarchWeb — reviewed artifact pins.
#
# Sourced by unprivileged scripts. The privileged helper (root.sh) duplicates
# the mailpit digests so a user-writable checkout cannot change what root
# accepts. test/security.sh fails if those copies drift.
#
# shellcheck shell=bash

OMARCHWEB_HELPER_DEST="/usr/local/libexec/omarchweb/root.sh"
# Filled after root.sh is hashed; test/security.sh checks it matches.
# After editing scripts/root.sh, run: sha256sum scripts/root.sh
OMARCHWEB_HELPER_SHA256="659a6316c2ef518a4944847edb08082097e6bef2bf815f1e7f1dea8994231228"

OMARCHWEB_WP_VERSION="7.1"
OMARCHWEB_WP_URL="https://wordpress.org/wordpress-7.1.tar.gz"
OMARCHWEB_WP_SHA256="05a5f89138f632b7329f1202f2a0553c5f7fe4daf8e4b9ca7ebae9b9466b9e86"
OMARCHWEB_WP_SHA1="e0ca593bc062f7a8c5a956ca44aff7375b0841e0"
OMARCHWEB_WP_MAX_BYTES=52428800

OMARCHWEB_LARAVEL_INSTALLER_VERSION="5.32.0"

OMARCHWEB_MAILPIT_VERSION="1.31.0"
OMARCHWEB_MAILPIT_SHA256_AMD64="076b5ded9a2182842b93e761b9586a1a251445bffe2666f9f22a6dc14470237d"
OMARCHWEB_MAILPIT_SHA256_ARM64="db3e685ed59d58354a29a4e7bfd0497f050af771a41e122aabdb0bd4fb915952"
OMARCHWEB_MAILPIT_MAX_BYTES=16777216
OMARCHWEB_MAILPIT_BIN="/usr/local/bin/mailpit"
OMARCHWEB_MAILPIT_UNIT="/etc/systemd/system/mailpit.service"
