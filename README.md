# gvim

[gvim](https://www.vim.org/) — the graphical version of the Vim text editor. A single self-contained binary, built natively for Linux and Windows.

[![CI](https://github.com/unpins/gvim/actions/workflows/gvim.yml/badge.svg)](https://github.com/unpins/gvim/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install gvim`.

## Usage

Run the `gvim` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin gvim file.txt
```

To install it onto your PATH:

```bash
unpin install gvim
```

## Man pages

`gvim.1` is embedded in the binary — read it with `unpin man gvim`. Upstream
documents gvim inside `vim.1`, so that is the page you get, along with `vim`,
`vimdiff` and `evim` (the manuals for `gvim -d` and `gvim -y`).

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

The [Releases](https://github.com/unpins/gvim/releases) page has standalone binaries for manual download.

## Build notes

- **Runtime tree embedded.** Vim's runtime files (syntax, indent, spell, help, menus) are packed into a ZIP and served from memory inside the binary by the shared [unpin-vfs](https://github.com/unpins/unpin-vfs) core — no companion `share/vim` directory.
- **Graphical toolkit.** The Linux build uses GTK2 + X11, linked statically into one binary with no shared-library dependencies (~32 MB). The Windows build uses the native Win32 GUI (cross-built with mingw; no companion DLLs).
- **Feature set.** Built with Vim's **Normal** feature set. The scripting interpreters (Lua, Python, Ruby, Perl, Tcl) and Wayland/XIM input are not compiled in, which keeps the binary self-contained.
- **macOS.** The graphical Vim for macOS is [MacVim](https://github.com/macvim-dev/macvim), a separate application, so gvim ships for Linux and Windows.
