# gvim

Standalone build of [gvim](https://www.vim.org/) — the GUI variant of Vim.

[![CI](https://github.com/unpins/gvim/actions/workflows/gvim.yml/badge.svg)](https://github.com/unpins/gvim/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

The Linux build is statically linked against GTK2 + X11 (~22 MB, no shared library dependencies). On Windows the Win32 GUI is used directly. macOS is not supported — on macOS, gvim is shipped as MacVim.app, not a CLI binary.

Built with Vim's `normal` feature set. The scripting interpreters (Lua, Python, Ruby, Perl, Tcl) and Wayland/XIM input are not compiled in, so the binary stays self-contained. The Vim runtime tree (syntax, indent, spell, help) is embedded inside the executable and served from memory — there is no companion `share/vim` directory.

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

## Man pages

The Vim man pages (`vim`, `vimdiff`, `evim`, `vimtutor`) are embedded in the binary; `gvim` is documented inside `vim.1`, so `unpin man gvim` resolves there.

## Manual download

The [Releases](https://github.com/unpins/gvim/releases) page has standalone binaries for manual download. The Vim runtime is embedded in each binary, so no separate data archive is needed.
