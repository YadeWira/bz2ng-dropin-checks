# bz2ng-dropin-checks

Two checks that [bz2-ng](https://github.com/tfenne/bz2-ng) can replace a distribution's libbz2 without rebuilding anything, with the scripts and the complete output of the runs reported in tfenne/bz2-ng issues [#13](https://github.com/tfenne/bz2-ng/issues/13) and [#14](https://github.com/tfenne/bz2-ng/issues/14).

It is an independent repository, not part of bz2-ng. Its companion is [bz2ng-damaged-streams](https://github.com/YadeWira/bz2ng-damaged-streams).

| Directory | What it checks |
|---|---|
| `alpine/` | that no Alpine package references a libbz2 symbol bz2-ng does not export (bz2-ng exports the 24 public functions only; libbz2's shared library also leaks internals such as `BZ2_blockSort`) |
| `debian13/` | that the unmodified test suites of seven dependants give the same results on Debian 13 before and after bz2-ng is installed over Debian's libbz2 and `bzip2` |

Each directory has the script, which runs inside a fresh container, and `results/`, the complete output of one run.

## Alpine 3.23: private-symbol scan

`alpine/scan.sh` builds bz2-ng to read its export list, lists every package that depends on `so:libbz2.so.1` (`apk list --depends`), fetches and unpacks each, and for every ELF file in it records which `BZ2_` symbols it references (`nm -D --undefined-only`), whether it links libbz2, and whether it carries the name of one of libbz2's internals in its bytes (which would mean a bundled copy rather than a reference).

```sh
git clone https://github.com/tfenne/bz2-ng
mkdir -p out-alpine
docker run --rm --platform linux/amd64 -e HOSTUID=$(id -u) -e HOSTGID=$(id -g) \
    -v "$PWD/bz2-ng:/src:ro" -v "$PWD/out-alpine:/out" -v "$PWD/alpine/scan.sh:/scan.sh:ro" \
    alpine:3.23 sh /scan.sh
```

The result is in `out-alpine/run.log` (with a summary at the end) and `out-alpine/scan.jsonl` (one line per package).

The run in `alpine/results/` (17 October 2026, Alpine 3.23.6, bz2-ng `63987e0`):

| | |
|---|---|
| Packages that depend on `so:libbz2.so.1` | 108, all fetched and unpacked |
| ELF files in them | 2,621, of which 144 link libbz2 |
| Distinct `BZ2_` symbols referenced | 23, all among bz2-ng's 24 exports (`BZ2_bzWriteClose64` is the one nobody uses) |
| Packages referencing a symbol bz2-ng does not export | none |
| Packages carrying a bundled copy of libbz2's internals | none |

Alpine's own `libbz2.so.1.0.8` exports 37 dynamic symbols: the 24 public functions, 11 of libbz2's internals, and `_init` and `_fini`; and its SONAME is `libbz2.so.1` (`alpine-libbz2-exports.txt`, `run.log`). One package, `ruby-mathematical`, links libbz2 but references none of its symbols.

## Debian 13: drop-in validation

`debian13/validate.sh` builds bz2-ng and the seven dependants from Debian's own source packages (`apt-get build-dep`, `apt-get source`), against Debian's libbz2. It runs their test suites, installs bz2-ng with `cmake --install` over Debian's files, and runs the same suites again in the same built trees.

```sh
git clone https://github.com/tfenne/bz2-ng
mkdir -p out-debian13
docker run --rm --platform linux/amd64 -e HOSTUID=$(id -u) -e HOSTGID=$(id -g) \
    -v "$PWD/bz2-ng:/src:ro" -v "$PWD/out-debian13:/out" -v "$PWD/debian13/validate.sh:/validate.sh:ro" \
    debian:13 bash /validate.sh
```

It takes about 15 minutes on a 64-thread Xeon. `PKGS="htslib samtools"` runs a subset. `run.log` has the summary; every suite's full output is in `before-<package>.log` and `after-<package>.log`.

The run in `debian13/results/` (17 October 2026, Debian 13.7 in the `debian:stable-slim` image, gcc 14.2, binutils 2.44, Debian's libbz2 1.0.8-6, bz2-ng `63987e0`):

| Dependant | Suite | Before | After |
|---|---|---|---|
| file 5.46 | `make check` | 82 tests, exit 0 | the same |
| GNU tar 1.35 | `make check` | 209 successful, 35 skipped | the same |
| libarchive 3.7.4 | `make check` | 4 of 5 test programs pass; `bsdunzip_test` fails | the same |
| htslib 1.21 | `make check` | 339 of 339 | the same |
| samtools 1.21 | `make test` | 990 tests: 946 passed, 0 failed, 44 expected failures | the same |
| CPython 3.13.5 | `test_bz2`, `test_tarfile`, `test_zipfile`, `test_shutil` | 1,294 run, 65 skipped, success | the same |
| bzip2 1.0.8-6 | the six comparisons of its `make test` (bz2-ng's `c/test/make_test.sh`), through the installed `bzip2` | pass | the same |

After the install `libbz2.so.1.0` resolves to bz2-ng's `libbz2.so.1.0.8` and `bzip2 --version` reports bz2-ng. libarchive's `bsdunzip_test` fails in the same way with Debian's own libbz2, so it is not caused by bz2-ng; I did not look into why it fails.

Things the script handles that are worth knowing if you adapt it:

- `apt-get source` gives every file the same time stamp, so `make` tries to regenerate the autotools files with versions that are not installed; the script touches them in dependency order first.
- Debian's patches to libarchive add tests that the shipped `Makefile.in` does not list, so `libarchive_test` does not link unless the autotools files are regenerated (`autoreconf -fi`).
- Debian's htslib source has no htscodecs submodule; it builds with `--with-external-htscodecs`.
- htslib's `make check` adds CRAM steps when an earlier run's files exist (339 tests become 340), so each pass starts with `make testclean`.
- GNU tar runs `bzip2` as an external program, so its suite exercises the installed `bzip2`, not the library. `run.log` shows which `libbz2` the other dependants load before and after the install.

## Limits

- x86-64 only, in containers, one release of each distribution.
- The Alpine scan covers the `main` and `community` repositories as the container sees them on the day it runs; it reads symbol tables, it does not start the programs.
- A suite giving the same result says the dependant behaves the same with bz2-ng; it does not say how much of bz2-ng the suite exercises.
- Each suite ran once per pass; I did not repeat them to look for flaky tests.

## Licence

MIT, see `LICENSE`. The scripts download and build other projects' source packages inside the container; none of their code is in this repository. The logs in `results/` are the output of their test suites.

Written with Claude Code.
