# Changelog

## [Unreleased]

### Fixed

- On Windows, the bundled runtime is discoverable again, not merely readable.
  `:packadd matchit` (and the other 15 packages Vim ships) did nothing,
  `:colorscheme <Tab>` offered no names, `:syntax <Tab>` offered no names and
  `readdir()` returned an empty list — every one of those searches a directory,
  and the embedded tree answered only exact file names. Linux was never
  affected. All four now report exactly what the Linux build reports.
- Runtime directory listings no longer repeat a name. `:e $VIMRUNTIME/<Tab>`
  offered `ftplugin/` and `indent/` twice, and sixteen names in all were
  doubled across the tree.
- `vimtutor.1` is no longer shipped: it documents a shell script this binary
  does not contain. The `vim`, `gvim`, `vimdiff` and `evim` pages stay — the
  last two are the manuals for `gvim -d` and `gvim -y`.

### Changed

- `nix build github:unpins/gvim` now downloads 33 MB instead of 776 MB. The
  binary is self-contained; it was still pinning the whole GTK2/X11 build
  closure through data paths baked in at link time that no one running the
  artifact can reach. Downloads of the release binary are unaffected.
