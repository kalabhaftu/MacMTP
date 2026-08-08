# Kalam Maintenance

macMTP owns the native Kalam adapter and its vendored Go dependencies. This
document records the imported adapter baseline and the dependency versions that
must be reviewed before a manual native-source update.

- Adapter baseline: `4ecf6a1ac0104c8edd49cb99b0c2213522f9488e`
- Baseline date: 2026-07-02
- Adapter change: replace callback function pointers with direct C calls to
  prevent embedded-Go callback crashes

The native protocol dependencies are pinned to:

- `github.com/ganeshrvel/go-mtpx`
  `v0.0.0-20240426092756-18f12db021cc`
- `github.com/ganeshrvel/go-mtpfs`
  `v1.0.4-0.20240426083057-1c3302b3c476`

Normal builds use only `Vendor/Kalam/native` and its checked-in vendor tree.
They do not fetch or update native source. Run
`scripts/check-upstream-kalam.sh` manually when reviewing a possible update;
the command compares into a temporary directory and never changes vendored
files automatically.
