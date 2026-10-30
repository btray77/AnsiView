#!/bin/bash
# Interoperability tests for the AnsiCore transfer engines against independent implementations:
# lrzsz (lsz/lrz, lsb/lrb, lsx/lrx) and C-Kermit. Every test compares SHA-256 of what arrived
# with the original.
#
#   brew install lrzsz c-kermit
#   swift build -c release --product ansixfer      (in Packages/AnsiCore)
#   Scripts/transfer-interop.sh <work-dir> [test ...]
#
# Tests: files xmodem ymodem zmodem zresume kermit telnet throughput (default: all)
set -u
WORK=${1:?work directory}
shift
TESTS=${*:-files xmodem ymodem zmodem zresume kermit telnet throughput}
HERE=$(cd "$(dirname "$0")/.." && pwd)
X=${ANSIXFER:-$HERE/.build/release/ansixfer}
F=$WORK/files
PASS=0
FAIL=0
mkdir -p "$WORK"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

check() { # label original received
    local want got
    want=$(sha "$2")
    if [ -f "$3" ]; then got=$(sha "$3"); else got=missing; fi
    if [ "$want" = "$got" ]; then
        echo "PASS $1 $(basename "$2") $(wc -c < "$2" | tr -d ' ') bytes sha256=$got"
        PASS=$((PASS + 1))
    else
        echo "FAIL $1 $(basename "$2") want=$want got=$got"
        FAIL=$((FAIL + 1))
    fi
}

# Plain XMODEM pads to 128: the received copy must be the original plus SUB (0x1A) padding.
check_padded() { # label original received
    local size padded
    size=$(wc -c < "$2" | tr -d ' ')
    if [ ! -f "$3" ]; then echo "FAIL $1 $(basename "$2") missing"; FAIL=$((FAIL + 1)); return; fi
    if python3 -I -c "
import sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
ok = b[:len(a)] == a and set(b[len(a):]) <= {0x1a} and len(b) % 128 == 0 and len(b) - len(a) < 128
sys.exit(0 if ok else 1)" "$2" "$3"; then
        echo "PASS $1 $(basename "$2") $size bytes, received $(wc -c < "$3" | tr -d ' ') = original + SUB padding (no length in XMODEM)"
        PASS=$((PASS + 1))
    else
        echo "FAIL $1 $(basename "$2") content differs"
        FAIL=$((FAIL + 1))
    fi
}

fresh() { rm -rf "$1"; mkdir -p "$1"; }

SIZES="r0.bin r1.bin r127.bin r128.bin r129.bin r1023.bin r1024.bin r1025.bin r1048576.bin everybyte.bin"

t_files() {
    mkdir -p "$F"
    python3 -I - "$F" <<'EOF'
import os, random, sys
out = sys.argv[1]
r = random.Random(42)
for n in [0, 1, 127, 128, 129, 1023, 1024, 1025, 1048576]:
    data = bytes(r.getrandbits(8) for _ in range(n))
    if data and data[-1] == 0x1a:
        data = data[:-1] + b'\x1b'
    open(os.path.join(out, 'r%d.bin' % n), 'wb').write(data)
eb = bytes(range(256)) + bytes([0x18] * 7 + [0x11, 0x13, 0x91, 0x93, 0xff, 0xff, 0xff, 0x0d, 0x0a, 0x40, 0x0d])
eb += b'**\x18B00000000000000\r\n' + bytes([1, 0x23, 0x20, 0x53, 0x7e, 0x7e, 0x26, 0x23, 0x10, 0x90]) + bytes(range(255, -1, -1))
open(os.path.join(out, 'everybyte.bin'), 'wb').write(eb)
r2 = random.Random(7)
open(os.path.join(out, 'big10m.bin'), 'wb').write(bytes(r2.getrandbits(8) for _ in range(10 * 1024 * 1024)))
EOF
    ls -l "$F"
}

t_xmodem() {
    local out=$WORK/x f
    # Our sender to lrx (lrzsz rx): checksum (lrx default), CRC (lrx -c), 1K blocks (our xmodem-1k, lrx -c).
    for mode in "xmodem:" "xmodem-crc:-c" "xmodem-1k:-c"; do
        proto=${mode%%:*}; flag=${mode#*:}
        for f in $SIZES; do
            fresh "$out"
            echo "+ ansixfer send $proto $f --exec \"lrx $flag $f\""
            (cd "$F" && "$X" send "$proto" "$f" --exec "cd '$out' && lrx $flag -q '$f' 2>>'$WORK/lrx.log'") 2>&1 | grep -E "negotiated|^result|^elapsed"
            if [ "$f" = r0.bin ]; then check "$proto ours->lrx" "$F/$f" "$out/$f"; else check_padded "$proto ours->lrx" "$F/$f" "$out/$f"; fi
        done
    done
    # lsx (lrzsz sx) to our receiver: checksum (our xmodem), CRC (our xmodem-crc), 1K (lsx -k, our xmodem-1k).
    for mode in "xmodem:" "xmodem-crc:" "xmodem-1k:-k"; do
        proto=${mode%%:*}; flag=${mode#*:}
        for f in $SIZES; do
            fresh "$out"
            echo "+ ansixfer receive $proto --padding keep --exec \"lsx $flag $f\""
            "$X" receive "$proto" --padding keep --name "$f" --dir "$out" --exec "cd '$F' && lsx $flag -q '$f' 2>>'$WORK/lsx.log'" 2>&1 | grep -E "negotiated|blocks of|^result|^elapsed"
            if [ "$f" = r0.bin ]; then check "$proto lsx->ours" "$F/$f" "$out/$f"; else check_padded "$proto lsx->ours" "$F/$f" "$out/$f"; fi
        done
    done
}

t_ymodem() {
    local out=$WORK/y f
    fresh "$out"
    echo "+ ansixfer send ymodem <all sizes> --exec \"lrb -y\""
    (cd "$F" && "$X" send ymodem --quiet $SIZES --exec "cd '$out' && lrb -y -q 2>>'$WORK/lrb.log'") | tail -2
    for f in $SIZES; do check "ymodem ours->lrb" "$F/$f" "$out/$f"; done
    fresh "$out"
    echo "+ ansixfer receive ymodem --exec \"lsb <all sizes>\""
    "$X" receive ymodem --quiet --dir "$out" --exec "cd '$F' && lsb -q $SIZES 2>>'$WORK/lsb.log'" | tail -2
    for f in $SIZES; do check "ymodem lsb->ours" "$F/$f" "$out/$f"; done
    fresh "$out"
    echo "+ ansixfer receive ymodem-g --exec \"lsb <all sizes>\"   (lsb streams when it sees G)"
    "$X" receive ymodem-g --quiet --dir "$out" --exec "cd '$F' && lsb -q $SIZES 2>>'$WORK/lsb.log'" | tail -2
    for f in $SIZES; do check "ymodem-g lsb->ours" "$F/$f" "$out/$f"; done
}

t_zmodem() {
    local out=$WORK/z f opts
    for opts in "" "--escctl" "--crc16" "--block 8192" "--escape-telnet"; do
        fresh "$out"
        echo "+ ansixfer send zmodem $opts <all sizes> --exec \"lrz -y\""
        (cd "$F" && "$X" send zmodem --quiet $opts $SIZES --exec "cd '$out' && lrz -y -q 2>>'$WORK/lrz.log'") | tail -2
        for f in $SIZES; do check "zmodem ours->lrz $opts" "$F/$f" "$out/$f"; done
    done
    for opts in "" "-e" "-o" "-8" "-w 4096"; do
        fresh "$out"
        echo "+ ansixfer receive zmodem --exec \"lsz $opts <all sizes>\""
        "$X" receive zmodem --quiet --dir "$out" --exec "cd '$F' && lsz -q $opts $SIZES 2>>'$WORK/lsz.log'" | tail -2
        for f in $SIZES; do check "zmodem lsz $opts->ours" "$F/$f" "$out/$f"; done
    done
    for opts in "--window 4096" "--escctl"; do
        fresh "$out"
        echo "+ ansixfer receive zmodem $opts --exec \"lsz r1048576.bin\""
        "$X" receive zmodem --quiet $opts --dir "$out" --exec "cd '$F' && lsz -q r1048576.bin 2>>'$WORK/lsz.log'" | tail -2
        check "zmodem lsz->ours $opts" "$F/r1048576.bin" "$out/r1048576.bin"
    done
}

t_zresume() {
    local out=$WORK/zr
    # 1. Our receiver, lsz -r sender: kill our side mid file, keep the .part, then run again.
    fresh "$out"
    echo "+ ansixfer receive zmodem --keep-partial --abort-after 300000 --exec \"lsz r1048576.bin\""
    "$X" receive zmodem --quiet --keep-partial --abort-after 300000 --dir "$out" --exec "cd '$F' && lsz -q r1048576.bin 2>>'$WORK/lsz.log'" | tail -2
    ls -l "$out"
    echo "+ ansixfer receive zmodem --resume --exec \"lsz -r r1048576.bin\""
    "$X" receive zmodem --resume --dir "$out" --exec "cd '$F' && lsz -q -r r1048576.bin 2>>'$WORK/lsz.log'" 2>&1 | grep -E "resum|result|elapsed|file:"
    check "zmodem resume lsz->ours" "$F/r1048576.bin" "$out/r1048576.bin"
    # 2. Our sender, lrz receiver: lrz keeps the partial (--keep-incomplete), our sender resumes (ZCRESUM).
    fresh "$out"
    echo "+ ansixfer send zmodem --abort-after 300000 r1048576.bin --exec \"lrz --keep-incomplete\""
    (cd "$F" && "$X" send zmodem --quiet --abort-after 300000 r1048576.bin --exec "cd '$out' && lrz -q --keep-incomplete 2>>'$WORK/lrz.log'") | tail -2
    ls -l "$out"
    echo "+ ansixfer send zmodem --resume r1048576.bin --exec \"lrz -r\""
    (cd "$F" && "$X" send zmodem --resume r1048576.bin --exec "cd '$out' && lrz -r -q 2>>'$WORK/lrz.log'") 2>&1 | grep -E "resum|result|elapsed|file:|offset"
    check "zmodem resume ours->lrz" "$F/r1048576.bin" "$out/r1048576.bin"
}

KERMIT="kermit -Y -q -B"

t_kermit() {
    local out=$WORK/k f opts
    for opts in "" "--check 1" "--check 2" "--packet 94" "--eighth-bit" "--kermit-window 8"; do
        fresh "$out"
        echo "+ ansixfer send kermit $opts <all sizes> --pty \"kermit -i -r\""
        (cd "$F" && "$X" send kermit --quiet $opts $SIZES --pty "cd '$out' && $KERMIT -i -r 2>>'$WORK/kermit.log'") | tail -2
        for f in $SIZES; do check "kermit ours->ckermit $opts" "$F/$f" "$out/$f"; done
        fresh "$out"
        echo "+ ansixfer receive kermit $opts --pty \"kermit -i -s <all sizes>\""
        "$X" receive kermit --quiet $opts --dir "$out" --pty "cd '$F' && $KERMIT -i -s $SIZES 2>>'$WORK/kermit.log'" | tail -2
        for f in $SIZES; do check "kermit ckermit->ours $opts" "$F/$f" "$out/$f"; done
    done
}

t_telnet() {
    local out=$WORK/tn port=23571 kind
    for kind in xmodem-1k ymodem zmodem kermit; do
        fresh "$out"
        port=$((port + 1))
        echo "+ ansixfer receive $kind --telnet --listen $port  |  ansixfer send $kind --telnet --connect 127.0.0.1:$port everybyte.bin r1048576.bin"
        "$X" receive "$kind" --quiet --telnet --name everybyte.bin --padding keep --dir "$out" --listen $port > "$WORK/tn-recv.txt" 2>&1 &
        sleep 0.5
        if [ "$kind" = xmodem-1k ]; then files=everybyte.bin; else files="everybyte.bin r1048576.bin"; fi
        (cd "$F" && "$X" send "$kind" --quiet --telnet $files --connect 127.0.0.1:$port) | tail -2
        wait
        tail -2 "$WORK/tn-recv.txt"
        if [ "$kind" = xmodem-1k ]; then check_padded "$kind over telnet" "$F/everybyte.bin" "$out/everybyte.bin"; else
            check "$kind over telnet" "$F/everybyte.bin" "$out/everybyte.bin"
            check "$kind over telnet" "$F/r1048576.bin" "$out/r1048576.bin"
        fi
    done
}

t_throughput() {
    local out=$WORK/tp port=23600 kind
    for kind in xmodem xmodem-crc xmodem-1k ymodem ymodem-g zmodem kermit; do
        fresh "$out"
        port=$((port + 1))
        "$X" receive "$kind" --quiet --name big10m.bin --dir "$out" --listen $port > "$WORK/tp-recv.txt" 2>&1 &
        sleep 0.5
        echo "+ $kind 10 MiB over 127.0.0.1:$port (ansixfer to ansixfer)"
        (cd "$F" && "$X" send "$kind" --quiet big10m.bin --connect 127.0.0.1:$port) | grep elapsed
        wait
        if [ "${kind#xmodem}" != "$kind" ]; then check_padded "$kind throughput" "$F/big10m.bin" "$out/big10m.bin"; else check "$kind throughput" "$F/big10m.bin" "$out/big10m.bin"; fi
    done
}

for t in $TESTS; do
    echo "=== $t"
    "t_$t"
done
echo "=== passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
