#!/bin/sh
# Fails on characters that do not belong in the repository's text files: no-break and zero-width spaces, a BOM,
# typographic quotes and the ellipsis character. They break shell scripts and config values and do not show in a diff.
set -eu
cd "$(dirname "$0")/.."

git ls-files -z -- . ':!*.png' |
  xargs -0 perl -CSD -ne '
    if (/[\x{00A0}\x{200B}\x{202F}\x{2060}\x{FEFF}\x{2018}\x{2019}\x{201C}\x{201D}\x{2026}]/) {
      print "$ARGV:$.: $_"; $bad = 1;
    }
    close ARGV if eof;
    END { exit $bad }
  '
