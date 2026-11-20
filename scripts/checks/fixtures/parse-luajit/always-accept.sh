#!/bin/sh
# Pretends to be a parser that accepts everything: it exits 0 for any input, on
# any file, with any flags. A gate that resolves its parser with `shutil.which`
# and trusts it would report `ok: 0 findings` for a tree that cannot load on
# Neovim stable. The capability probe must refuse this binary instead.
exit 0
