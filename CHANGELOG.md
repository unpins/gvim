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
  offered `ftplugin/` and `indent/` twice, and fourteen names in all were
  doubled across the tree.
