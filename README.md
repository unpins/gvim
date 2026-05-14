# gvim

Standalone build of [gvim](https://www.vim.org/) — the GUI variant of Vim.

[![CI](https://github.com/unpins/gvim/actions/workflows/gvim.yml/badge.svg)](https://github.com/unpins/gvim/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

The Linux build is statically linked against GTK2 + X11 (~22 MB, no shared library dependencies). On Windows the Win32 GUI is used directly. macOS is not supported — on macOS, gvim is shipped as MacVim.app, not a CLI binary.

## Installation

Install with [unpin](https://github.com/unpins/unpin):

```bash
unpin gvim
```

## Build locally

```bash
nix build github:unpins/gvim
./result/bin/gvim
```

Or cross-build the Windows binary from Linux (no Windows host needed):

```bash
nix build github:unpins/gvim#"windows-x86_64"
# result/bin/gvim.exe — copy to Windows to run.
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/gvim/releases) page has standalone binaries and a `.tar.zst` data archive (Vim runtime files, syntax/spell) for manual download.
