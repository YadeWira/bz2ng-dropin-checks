#!/bin/sh
# Private-symbol reverse-dependency scan on Alpine: every package that depends on so:libbz2.so.1, every ELF file in it,
# and every BZ2_* symbol it references that bz2-ng does not export.
# Runs inside a fresh alpine:3.23 container with the bz2-ng source at /src (read-only) and an output directory at /out.
#   env: LIMIT=N to scan the first N packages only; HOSTUID, HOSTGID: owner to give the output files at the end
#        BZ2NG_COMMIT: the commit to report, when /src is not a git checkout the container can read
set -u
OUT=/out; mkdir -p "$OUT"
exec > "$OUT/run.log" 2>&1
apk add --no-cache binutils python3 bzip2 build-base cmake git > /dev/null 2>&1 || { echo "apk add failed"; exit 1; }
apk update > /dev/null 2>&1
echo "== $(date -u +%FT%TZ)"
echo "alpine $(cat /etc/alpine-release), $(apk --version | head -1), $(uname -m)"
echo "libbz2 in Alpine: SONAME $(readelf -d /usr/lib/libbz2.so.1 2>/dev/null | grep SONAME | sed 's/.*\[//; s/\]//'), file $(ls /usr/lib/libbz2.so.1.* 2>/dev/null | tr '\n' ' ')"
# what Alpine's libbz2 exports, to see which names a consumer can resolve against it today
nm -D --defined-only /usr/lib/libbz2.so.1 | awk '{print $3}' | sort > "$OUT/alpine-libbz2-exports.txt"
echo "Alpine's libbz2 exports $(wc -l < "$OUT/alpine-libbz2-exports.txt") dynamic symbols"

# what bz2-ng exports, from a build of it here
echo "bz2-ng source: ${BZ2NG_COMMIT:-$(git -c safe.directory=/src -C /src rev-parse --short HEAD 2>/dev/null || echo 'commit not known')}"
cmake -S /src/c -B /bz2ng -DCMAKE_BUILD_TYPE=Release -DBZ2NG_BUILD_TESTS=OFF -DBZ2NG_BUILD_BENCH=OFF > /bz2ng.log 2>&1 \
	&& cmake --build /bz2ng -j"$(nproc)" >> /bz2ng.log 2>&1 || { echo "bz2-ng build failed"; tail -5 /bz2ng.log; exit 1; }
nm -D --defined-only "$(ls /bz2ng/libbz2.so.1.0.* | head -1)" | awk '$3 ~ /^BZ2_/ {print $3}' | sed 's/@.*//' | sort -u > "$OUT/bz2ng-exports.txt"
echo "bz2-ng exports $(wc -l < "$OUT/bz2ng-exports.txt") BZ2_ symbols"

apk list --depends so:libbz2.so.1 > "$OUT/rdeps.txt" 2>/dev/null
# each line starts with name-version-rN
awk '{print $1}' "$OUT/rdeps.txt" | sed -n 's/^\(.*\)-\([0-9][^-]*-r[0-9][0-9]*\)$/\1=\2/p' > /pkgs.txt
[ -n "${LIMIT:-}" ] && { head -n "$LIMIT" /pkgs.txt > /p2.txt && mv /p2.txt /pkgs.txt; }
echo "packages that depend on so:libbz2.so.1: $(wc -l < /pkgs.txt)"
cp /pkgs.txt "$OUT/packages.txt"
mkdir -p /pk /x
cat > /scan.py <<'PY'
import os, subprocess, sys, json
pub = set(open('/out/bz2ng-exports.txt').read().split())
root = sys.argv[1]
res = {'elf': 0, 'links_libbz2': 0, 'refs_public': set(), 'refs_private': set(), 'defines_bz2': set(), 'strings_private': set()}
# libbz2's internals that leak from its shared library; a static copy of libbz2 inside a binary would carry these names
PRIV = (b'BZ2_blockSort', b'BZ2_decompress', b'BZ2_crc32Table', b'BZ2_hbCreateDecodeTables', b'BZ2_hbMakeCodeLengths',
        b'BZ2_hbAssignCodes', b'BZ2_compressBlock', b'BZ2_rNums', b'BZ2_indexIntoF', b'BZ2_bz__AssertH__fail',
        b'BZ2_bsInitWrite')
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        try:
            with open(p, 'rb') as fh:
                if fh.read(4) != b'\x7fELF':
                    continue
                fh.seek(0); data = fh.read()
        except OSError:
            continue
        res['elf'] += 1
        for s in PRIV:
            if s in data:
                res['strings_private'].add(s.decode())
        if 'libbz2.so' in subprocess.run(['readelf', '-d', p], capture_output=True, text=True).stdout:
            res['links_libbz2'] += 1
        for line in subprocess.run(['nm', '-D', '--undefined-only', p], capture_output=True, text=True).stdout.split('\n'):
            parts = line.split()
            if parts and parts[-1].startswith('BZ2_'):
                name = parts[-1].split('@')[0]
                (res['refs_public'] if name in pub else res['refs_private']).add(name)
        for line in subprocess.run(['nm', '-D', '--defined-only', p], capture_output=True, text=True).stdout.split('\n'):
            parts = line.split()
            if parts and parts[-1].startswith('BZ2_'):
                res['defines_bz2'].add(parts[-1].split('@')[0])
print(json.dumps({k: (sorted(v) if isinstance(v, set) else v) for k, v in res.items()}))
PY
: > "$OUT/scan.jsonl"
n=0
while read -r spec; do
	n=$((n+1)); name=${spec%%=*}
	rm -rf /pk/* /x/*
	if ! apk fetch --no-cache --output /pk "$spec" > /pk.log 2>&1 && ! apk fetch --no-cache --output /pk "$name" > /pk.log 2>&1; then
		echo "{\"pkg\": \"$spec\", \"error\": \"fetch failed\"}" >> "$OUT/scan.jsonl"; continue
	fi
	f=$(ls /pk/*.apk 2>/dev/null | head -1)
	if [ -z "$f" ] || ! apk extract --no-chown --destination /x "$f" > /ex.log 2>&1; then
		echo "{\"pkg\": \"$spec\", \"error\": \"extract failed: $(tail -1 /ex.log | tr '"' "'")\"}" >> "$OUT/scan.jsonl"; continue
	fi
	r=$(python3 /scan.py /x 2>&1 | tail -1)
	echo "{\"pkg\": \"$spec\", \"scan\": $r}" >> "$OUT/scan.jsonl"
	[ $((n % 20)) -eq 0 ] && echo "  scanned $n packages"
done < /pkgs.txt
echo "scanned $n packages; per-package results in scan.jsonl"

python3 - <<'PY'
import json
rows = [json.loads(l) for l in open('/out/scan.jsonl')]
ok = [r for r in rows if 'scan' in r]
err = [r for r in rows if 'error' in r]
pub, priv, strs = set(), {}, {}
for r in ok:
    s = r['scan']; pub.update(s['refs_public'])
    if s['refs_private']: priv[r['pkg']] = s['refs_private']
    if s['strings_private']: strs[r['pkg']] = s['strings_private']
print('== SUMMARY')
print('packages scanned: %d, failed to fetch or extract: %d' % (len(ok), len(err)))
print('ELF files: %d, of which link libbz2: %d' % (sum(r['scan']['elf'] for r in ok), sum(r['scan']['links_libbz2'] for r in ok)))
print('packages with an ELF file that links libbz2: %d' % sum(1 for r in ok if r['scan']['links_libbz2']))
print('distinct BZ2_ symbols referenced that bz2-ng exports: %d: %s' % (len(pub), ' '.join(sorted(pub))))
print('packages referencing a BZ2_ symbol bz2-ng does not export: %d %s' % (len(priv), json.dumps(priv) if priv else ''))
print('packages carrying a private libbz2 name in their bytes (a bundled copy, not a reference): %d %s' % (len(strs), json.dumps(strs) if strs else ''))
for r in err: print('  error:', r['pkg'], r['error'])
PY
echo "== done $(date -u +%FT%TZ)"
chown -R "${HOSTUID:-0}:${HOSTGID:-0}" "$OUT"
