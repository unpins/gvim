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

- Updated to Vim 9.2.0541.
- CI now runs `gvim.exe`. It never had: the Windows binary is GUI-subsystem
  and writes no stdout, so it was built, unpacked and inspected without being
  executed — which is why the runtime tree above could be broken for months
  with every check green. It now runs a script that writes what it can read
  and what it can find to a file, and CI reads that back.
- `nix build github:unpins/gvim` now downloads 33 MB instead of 776 MB. The
  binary is self-contained; it was still pinning the whole GTK2/X11 build
  closure through data paths baked in at link time that no one running the
  artifact can reach. Downloads of the release binary are unaffected.
- The Linux binaries are now built by the unpin-llvm engine (clang with full
  LTO) instead of nixpkgs' gcc.
- The Windows binary is now built by the same compiler as the Linux ones. Its
  size barely moves (15.8 MB to 15.7 MB). Under Wine it opens its window at
  the same size, reads and searches the embedded runtime, loads `:packadd`
  plugins and keeps going after an error, exactly as the previous binary does.
  The XPM library behind `:sign` icons is now built from source instead of
  the prebuilt copy Vim's sources carry.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.
