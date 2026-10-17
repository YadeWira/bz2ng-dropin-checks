#!/bin/bash
# Drop-in validation on Debian 13: bz2-ng installed over the distribution's libbz2 and bzip2 programs, and the unmodified
# test suites of seven dependants run before and after, nothing rebuilt in between.
# Runs inside a fresh debian:13 container with the bz2-ng source at /src (read-only) and an output directory at /out.
#   env: PKGS="file tar libarchive htslib samtools python bzip2"   (default: all)
#        HOSTUID, HOSTGID: owner to give the output files at the end
#        BZ2NG_COMMIT: the commit to report, when /src is not a git checkout the container can read
set -u
OUT=/out; mkdir -p "$OUT"
trap 'chown -R "${HOSTUID:-0}:${HOSTGID:-0}" "$OUT"' EXIT
exec > >(tee -a "$OUT/run.log") 2>&1
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
PKGS=${PKGS:-"file tar libarchive htslib samtools python bzip2"}
echo "== $(date -u +%FT%TZ) packages: $PKGS"
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq --no-install-recommends build-essential cmake ca-certificates dpkg-dev autoconf automake libtool pkg-config \
	devscripts fakeroot xz-utils bzip2 git > "$OUT/apt-base.log" 2>&1 || { echo "base install failed"; tail -5 "$OUT/apt-base.log"; exit 1; }
. /etc/os-release
echo "$PRETTY_NAME ($(cat /etc/debian_version)) | gcc $(gcc -dumpversion) | ld $(ld --version | head -1 | sed 's/.* //') | libbz2: $(dpkg -s libbz2-1.0 | grep ^Version | cut -d' ' -f2), $(ls /usr/lib/x86_64-linux-gnu/libbz2.so.1.0.* | tr '\n' ' ')"
echo "bz2-ng source: ${BZ2NG_COMMIT:-$(git -c safe.directory=/src -C /src rev-parse --short HEAD 2>/dev/null || echo 'commit not known')}"

# bz2-ng, built now and installed later
cmake -S /src/c -B /bz2ng -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
	-DBZ2NG_BUILD_TESTS=OFF -DBZ2NG_BUILD_BENCH=OFF > "$OUT/bz2ng-configure.log" 2>&1 && cmake --build /bz2ng -j"$(nproc)" > "$OUT/bz2ng-build.log" 2>&1 \
	|| { echo "bz2-ng build failed"; tail -5 "$OUT/bz2ng-build.log"; exit 1; }
echo "bz2-ng built: $(ls /bz2ng/libbz2.so.1.0* | tr '\n' ' ')"

mkdir -p /w
fetch_build() {   # package, then the build command string (run in the source directory)
	local p=$1; shift
	echo "-- [$p] build-dep + source"
	apt-get build-dep -y -qq "$p" > "$OUT/$p-builddep.log" 2>&1 || { echo "[$p] build-dep failed"; tail -3 "$OUT/$p-builddep.log"; return 1; }
	mkdir -p "/w/$p" && cd "/w/$p" && apt-get source -q "$p" > "$OUT/$p-source.log" 2>&1 || { echo "[$p] source failed"; return 1; }
	cd "/w/$p"/*/ 2>/dev/null || { echo "[$p] no source dir"; return 1; }
	echo "[$p] source $(basename "$PWD")"
	bash -c "$1" > "$OUT/$p-build.log" 2>&1 || { echo "[$p] BUILD FAILED"; tail -5 "$OUT/$p-build.log"; return 1; }
	echo "[$p] built"
}
run_tests() {     # phase, package, then the test command string (run in the source directory)
	local ph=$1 p=$2; shift 2
	( cd "/w/$p"/*/ 2>/dev/null && t0=$(date +%s) && bash -c "$1" > "$OUT/$ph-$p.log" 2>&1; rc=$?; echo "rc=$rc secs=$(( $(date +%s) - t0 ))" >> "$OUT/$ph-$p.log"; echo "[$ph] $p: exit $rc in $(( $(date +%s) - t0 )) s" )
}
declare -A BUILD TEST
# apt-get source leaves every file with the same time stamp, so make would try to regenerate the autotools files with a
# version that is not installed: touch them in dependency order so that it does not.
UNREGEN='find . -name aclocal.m4 -exec touch {} + ; sleep 1; find . \( -name configure -o -name config.h.in \) -exec touch {} + ; sleep 1; find . -name Makefile.in -exec touch {} + ;'
BUILD[file]="$UNREGEN ./configure && make -j16";                                   TEST[file]='make check'
BUILD[tar]="$UNREGEN FORCE_UNSAFE_CONFIGURE=1 ./configure && make -j16";           TEST[tar]='make check -j8'
# Debian's patches add test files that the shipped Makefile.in does not list, so libarchive_test does not link unless
# the autotools files are regenerated.
BUILD[libarchive]="autoreconf -fi && ./configure --prefix=/usr/local && make -j16"; TEST[libarchive]='make check -j8'
# Debian's htslib source has no htscodecs submodule; it builds against the packaged libhtscodecs.
# htslib's check adds CRAM steps when an earlier run's files exist, so start each pass from a clean tree.
BUILD[htslib]="(test -x ./configure || autoreconf -i) && $UNREGEN ./configure --with-external-htscodecs && make -j16"
TEST[htslib]='make testclean > /dev/null 2>&1; make check'
BUILD[samtools]="(test -x ./configure || autoreconf -i) && $UNREGEN ./configure --with-htslib=\$(ls -d /w/htslib/*/ | head -1) && make -j16"
TEST[samtools]='make test'

built=""
for p in $PKGS; do
	case $p in
	python)
		apt-get install -y -qq --no-install-recommends python3 libpython3.13-testsuite > "$OUT/python-install.log" 2>&1 && built="$built python" || echo "[python] install failed" ;;
	bzip2)
		built="$built bzip2" ;;
	*)
		fetch_build "$p" "${BUILD[$p]}" && built="$built $p" ;;
	esac
done
echo "== built:$built"

phase() {  # before | after
	local ph=$1
	for p in $built; do
		case $p in
		python) ( t0=$(date +%s); python3 -m test test_bz2 test_tarfile test_zipfile test_shutil > "$OUT/$ph-python.log" 2>&1; rc=$?; echo "rc=$rc secs=$(( $(date +%s) - t0 ))" >> "$OUT/$ph-python.log"; echo "[$ph] python: exit $rc in $(( $(date +%s) - t0 )) s" ) ;;
		bzip2) ( sh /src/c/test/make_test.sh "$(command -v bzip2)" /tmp/make_test > "$OUT/$ph-bzip2.log" 2>&1; rc=$?; echo "rc=$rc" >> "$OUT/$ph-bzip2.log"; echo "[$ph] bzip2 (its own make test, through $(command -v bzip2)): exit $rc" ) ;;
		*) run_tests "$ph" "$p" "${TEST[$p]}" ;;
		esac
	done
}
libs() {   # which libbz2 each dependant loads
	bz2mod=$(python3 -c 'import _bz2; print(_bz2.__file__)' 2>/dev/null)
	for b in /usr/bin/file "$bz2mod"; do
		echo "  $b -> $(ldd "$b" 2>/dev/null | grep libbz2 | sed 's/^\s*//; s/ (0x.*//')"
	done
	for p in $built; do
		case $p in libarchive) n=bsdtar ;; htslib) n=htsfile ;; samtools) n=samtools ;; *) continue ;; esac
		b=$(find /w/$p -type f -perm -u+x -name $n 2>/dev/null | head -1)
		[ -n "$b" ] && echo "  $p: $n -> $(ldd "$b" 2>/dev/null | grep libbz2 | sed 's/^\s*//; s/ (0x.*//')" || echo "  $p: $n not found"
	done
	echo "  tar runs the external program: $(command -v bzip2)"
}
echo "== BEFORE: Debian's own libbz2 and bzip2"
echo "bzip2 says: $(bzip2 --version 2>&1 | head -1)"
libs
phase before
echo "== INSTALL bz2-ng over the distribution's files"
cmake --install /bz2ng > "$OUT/install.log" 2>&1 || { echo "install failed"; tail -5 "$OUT/install.log"; exit 1; }
ldconfig
echo "bzip2 says: $(bzip2 --version 2>&1 | head -1)"
echo "libbz2.so.1.0 -> $(readlink -f /usr/lib/x86_64-linux-gnu/libbz2.so.1.0)"
libs
echo "== AFTER"
phase after

echo "== SUMMARY (before | after)"
sum() {   # a one-line result from a suite's log
	local f=$1 p=$2
	[ -f "$f" ] || { echo "-"; return; }
	case $p in
	file) printf '%s tests run, ' "$(grep -c '^Running test: ' "$f")" ;;
	libarchive) printf '%s' "$(grep -E '^# (TOTAL|PASS|FAIL|SKIP|XFAIL|ERROR):' "$f" | awk '{printf "%s%s ", $2, $3}')"; grep -E '^FAIL: ' "$f" | tr '\n' ' ' ;;
	tar) grep -E '^[0-9]+ tests? (were successful|failed|unexpectedly)|tests? were skipped|^ERROR: ' "$f" | tr '\n' ' ' ;;
	htslib|samtools) grep -A5 '^Number of tests' "$f" | grep -E '^\s+(total|passed|failed|expected failure|unexpected pass)' | sed 's/^\s*//; s/ *\.\. */ /' | tr '\n' ',' ; echo -n ' ' ;;
	python) grep -E '^(Total tests|Result):' "$f" | tr '\n' ' ' ;;
	esac
	tail -1 "$f"
}
for p in $built; do
	echo "$p:"
	echo "  before: $(sum "$OUT/before-$p.log" "$p")"
	echo "  after:  $(sum "$OUT/after-$p.log" "$p")"
done
echo "== done $(date -u +%FT%TZ)"
