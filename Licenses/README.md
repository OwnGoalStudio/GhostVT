# Vendored license notices

One folder per component whose license the build's package scan cannot
reach. `Scripts/collect-licenses.py` (the app's "Collect Licenses" build
phase) reads each folder's `LICENSE` and `notice.json` and ships them in
`Licenses.json` beside the repository's own `LICENSE` and the notices found
in every Swift package checkout. Settings ▸ About ▸ Licenses shows the result.

`notice.json`:

```json
{
  "name": "Ghostty",
  "url": "https://github.com/ghostty-org/ghostty",
  "version_file": "libghostty-spm/Ghostty.version",
  "version": "1.3.1"
}
```

`version_file` is a path under the package checkouts (`SourcePackages/
checkouts/`), read at build time so the version tracks the package that
bundles the component; `version` is a literal for a component no checkout
describes. Either or neither.

`ghostty/` is here because libghostty-spm ships Ghostty as a prebuilt
XCFramework, and a binary carries no license file. The text is
`ghostty-org/ghostty`'s `LICENSE` at the ref libghostty-spm builds from
(`Ghostty.ref` in that package).
