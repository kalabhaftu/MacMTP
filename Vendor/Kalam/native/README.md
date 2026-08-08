# Vendored Kalam Adapter

This is the macMTP-owned native adapter derived from the MIT-licensed Kalam
source. It is built by `scripts/build.sh` from the macMTP repository root.

The Go module versions are pinned in `go.mod`, `go.sum`, and `vendor/`. Use
`go test -mod=vendor ./...` for a native source check. Do not run `go get -u`
or modify the vendor tree as part of a normal build.

When reviewing upstream manually, run:

```bash
scripts/check-upstream-kalam.sh
```

That command compares source into a temporary directory and never updates this
tree automatically. See `../MAINTENANCE.md` and `../LICENSES.md` for the
baseline and license records.
