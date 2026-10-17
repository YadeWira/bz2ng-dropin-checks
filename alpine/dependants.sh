#!/bin/sh
# Drop-in validation on Alpine (musl): htslib and samtools built from their release tarballs against Alpine's libbz2,
# their test suites run, bz2-ng installed over Alpine's libbz2 and bzip2 programs, and the same suites run again in the
# same built trees, nothing rebuilt in between. Alpine packages neither, so the sources are upstream's.
# Runs inside a fresh alpine:3.23 container with the bz2-ng source at /src (read-only) and an output directory at /out.
#   env: HTSVER (default 1.24): the htslib and samtools release; HOSTUID, HOSTGID: owner to give the output files
#        BZ2NG_COMMIT: the commit to report, when /src is not a git checkout the container can read
set -u
OUT=/out; mkdir -p "$OUT"
exec > "$OUT/run.log" 2>&1
trap 'chown -R "${HOSTUID:-0}:${HOSTGID:-0}" "$OUT"' EXIT
V=${HTSVER:-1.24}
echo "== $(date -u +%FT%TZ) htslib and samtools $V"
apk add --no-cache build-base cmake git perl bash curl bzip2 bzip2-dev zlib-dev xz-dev ncurses-dev musl-utils > "$OUT/apk.log" 2>&1 \
	|| { echo "apk add failed"; tail -5 "$OUT/apk.log"; exit 1; }
echo "alpine $(cat /etc/alpine-release) | $(gcc --version | head -1) | installed: $(apk list -I musl bzip2 libbz2 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
echo "libbz2: $(ls /usr/lib/libbz2.so* | tr '\n' ' ')"
echo "bz2-ng source: ${BZ2NG_COMMIT:-$(git -c safe.directory=/src -C /src rev-parse --short HEAD 2>/dev/null || echo 'commit not known')}"

# bz2-ng with Alpine's SONAME, built now and installed later
cmake -S /src/c -B /bz2ng -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DBZ2NG_SONAME=1 \
	-DBZ2NG_BUILD_TESTS=OFF -DBZ2NG_BUILD_BENCH=OFF > "$OUT/bz2ng-configure.log" 2>&1 && cmake --build /bz2ng -j"$(nproc)" > "$OUT/bz2ng-build.log" 2>&1 \
	|| { echo "bz2-ng build failed"; tail -5 "$OUT/bz2ng-build.log"; exit 1; }
echo "bz2-ng built: $(ls /bz2ng/libbz2.so* | tr '\n' ' ')"

mkdir -p /w && cd /w || exit 1
for p in htslib samtools; do
	curl -fsSL -o "$p-$V.tar.bz2" "https://github.com/samtools/$p/releases/download/$V/$p-$V.tar.bz2" || { echo "[$p] download failed"; exit 1; }
	echo "[$p] $p-$V.tar.bz2 sha256 $(sha256sum "$p-$V.tar.bz2" | cut -d' ' -f1)"
	tar xjf "$p-$V.tar.bz2"
done
# no libcurl: the suites' remote-file tests are not what this checks
( cd "htslib-$V" && ./configure --disable-libcurl && make -j"$(nproc)" ) > "$OUT/htslib-build.log" 2>&1 || { echo "[htslib] BUILD FAILED"; tail -5 "$OUT/htslib-build.log"; exit 1; }
echo "[htslib] built"
( cd "samtools-$V" && ./configure --with-htslib="/w/htslib-$V" && make -j"$(nproc)" ) > "$OUT/samtools-build.log" 2>&1 || { echo "[samtools] BUILD FAILED"; tail -5 "$OUT/samtools-build.log"; exit 1; }
echo "[samtools] built"

libs() {
	for b in "/w/htslib-$V/htsfile" "/w/samtools-$V/samtools" /usr/bin/bzip2; do
		echo "  $b -> $(ldd "$b" 2>/dev/null | grep libbz2 | sed 's/^\s*//; s/ (0x.*//')"
	done
}
phase() {  # before | after
	local ph=$1 t0
	# htslib's check adds CRAM steps when an earlier run's files exist, so start each pass from a clean tree
	t0=$(date +%s); ( cd "/w/htslib-$V" && make testclean > /dev/null 2>&1; make check ) > "$OUT/$ph-htslib.log" 2>&1
	echo "rc=$? secs=$(( $(date +%s) - t0 ))" >> "$OUT/$ph-htslib.log"; echo "[$ph] htslib: $(tail -1 "$OUT/$ph-htslib.log")"
	t0=$(date +%s); ( cd "/w/samtools-$V" && make test ) > "$OUT/$ph-samtools.log" 2>&1
	echo "rc=$? secs=$(( $(date +%s) - t0 ))" >> "$OUT/$ph-samtools.log"; echo "[$ph] samtools: $(tail -1 "$OUT/$ph-samtools.log")"
	t0=$(date +%s); sh /src/c/test/make_test.sh "$(command -v bzip2)" /tmp/make_test > "$OUT/$ph-bzip2.log" 2>&1
	echo "rc=$?" >> "$OUT/$ph-bzip2.log"; echo "[$ph] bzip2 (its own make test, through $(command -v bzip2)): $(tail -1 "$OUT/$ph-bzip2.log")"
}
echo "== BEFORE: Alpine's own libbz2 and bzip2"
echo "bzip2 says: $(bzip2 --version 2>&1 < /dev/null | head -1)"
libs
phase before
echo "== INSTALL bz2-ng over the distribution's files"
cmake --install /bz2ng > "$OUT/install.log" 2>&1 || { echo "install failed"; tail -5 "$OUT/install.log"; exit 1; }
echo "bzip2 says: $(bzip2 --version 2>&1 < /dev/null | head -1)"
echo "libbz2.so.1 -> $(readlink -f /usr/lib/libbz2.so.1), SONAME $(readelf -d /usr/lib/libbz2.so.1 | grep SONAME | sed 's/.*\[//; s/\]//')"
libs
echo "== AFTER"
phase after

echo "== SUMMARY (before | after)"
for p in htslib samtools; do
	for ph in before after; do
		echo "$p $ph: $(grep -A5 '^Number of tests' "$OUT/$ph-$p.log" | grep -E '^\s+(total|passed|failed|expected failure|unexpected pass)' | sed 's/^\s*//; s/ *\.\. */ /' | tr '\n' ',') $(tail -1 "$OUT/$ph-$p.log")"
	done
done
for ph in before after; do echo "bzip2 $ph: $(tail -1 "$OUT/$ph-bzip2.log")"; done
echo "== done $(date -u +%FT%TZ)"
