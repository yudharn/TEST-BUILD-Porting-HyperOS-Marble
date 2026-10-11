#!/usr/bin/env bash
# =============================================================================
#  port_chrome.sh - pasang Chrome kalau ROM donor tidak punya browser
#  (di-source oleh port.sh; hanya berisi fungsi)
#
#  Dipanggil SETELAH debloat, jadi browser yang baru saja dihapus debloat
#  (mis. Mi Browser = com.mi.globalbrowser) ikut dihitung "tidak ada".
#
#  BROWSER_FALLBACK : auto  = pasang Chrome hanya kalau donor tidak punya browser apa pun (default)
#                     true  = selalu pasang Chrome (kalau belum ada)
#                     false = mati
#  CHROME_APK       : URL / path APK Chrome (com.android.chrome). Boleh juga bundle .apkm/.xapk/.apks
#                     (hanya base.apk yang dipakai). Kosong = coba ambil dari ROM base
#  CHROME_FROM_BASE : true (default) = kalau CHROME_APK kosong, salin Chrome dari product base
#  CHROME_DIR       : lokasi di ROM port (default product/app/Chrome)
#  CHROME_FORCE     : true = tetap dipasang walau versi TrichromeLibrary tidak cocok (Chrome tidak akan jalan)
#  BROWSER_PACKAGES : regex tambahan nama package yang dianggap browser (mis. "org\.example\..*")
#
#  Chrome stable memakai static shared library com.google.android.trichromelibrary dengan
#  versi TEPAT sama dengan TrichromeLibrary di ROM (yang dipasangkan dengan WebView donor).
#  Kalau versinya beda, Android menolak paket Chrome. Fungsi ini mengeceknya dan tidak
#  memasang Chrome yang pasti gagal (kecuali CHROME_FORCE=true).
# =============================================================================

BROWSER_RE_DEFAULT='^(com\.android\.chrome|com\.android\.browser|com\.mi\.globalbrowser(\.mini)?|com\.miui\.browser|com\.google\.android\.apps\.chrome|com\.microsoft\.emmx|com\.brave\.browser(_[a-z]+)?|com\.opera\.(browser|mini\.native)(\..*)?|org\.mozilla\.(firefox|fenix|focus)(_[a-z]+)?|com\.duckduckgo\.mobile\.android|com\.sec\.android\.app\.sbrowser|com\.vivaldi\.browser|com\.kiwibrowser\.browser|com\.heytap\.browser|com\.UCMobile(\..*)?)$'

# chrome_static_lib_ok <apk>  -> 0 = cocok / tidak butuh library, 1 = tidak cocok
chrome_static_lib_ok() {
    local apk=$1 uses name ver dir f provided found ok_all=0 idx="$WORK/chrome_port.tsv"
    uses=$(python3 "$SCRIPT_DIR/apk_static_lib.py" "$apk" | awk '$1 == "uses" {print $2 " " $3}')
    if [[ -z $uses ]]; then log "Chrome: APK tidak memakai static library (standalone), cek versi dilewati"; return 0; fi
    python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" > "$idx"
    while read -r name ver; do
        [[ -n $name ]] || continue
        provided=""; found=0
        # semua APK di ROM port yang package-nya mirip nama library (mis. TrichromeLibrary64)
        while IFS=$'\t' read -r _pkg dir; do
            for f in "$P_FS/$dir"/*.apk; do
                [[ -f $f ]] || continue
                while read -r kind lname lver; do
                    [[ $kind == provides && $lname == "$name" ]] || continue
                    provided+=" $lver"
                    if [[ $lver == "$ver" ]]; then found=1; fi
                done < <(python3 "$SCRIPT_DIR/apk_static_lib.py" "$f")
            done
        done < <(awk -F'\t' -v n="$name" 'index($1, n) == 1 {print}' "$idx")
        if [[ $found == 1 ]]; then
            ok "Chrome: library $name versi $ver tersedia di ROM donor"
        else
            warn "Chrome: butuh library $name versi $ver, ROM donor menyediakan:${provided:- (tidak ada)} -> Chrome TIDAK akan ter-install. Pakai Chrome dengan versi Trichrome yang sama dengan WebView donor"
            ok_all=1
        fi
    done <<< "$uses"
    return $ok_all
}

# chrome_extract_libs <apk> <dir>  : lib native (kalau ada) -> <dir>/lib/arm64 (+ arm)
chrome_extract_libs() {
    python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
abis = {"arm64-v8a": "arm64", "armeabi-v7a": "arm"}
n = 0
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        parts = info.filename.split("/")
        if len(parts) == 3 and parts[0] == "lib" and parts[1] in abis and parts[2].endswith(".so"):
            out = os.path.join(dst, "lib", abis[parts[1]])
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, parts[2]), "wb") as f:
                f.write(z.read(info))
            os.chmod(os.path.join(out, parts[2]), 0o644)
            n += 1
print(n)
PY
}

# chrome_log_donor_lib: tampilkan versi TrichromeLibrary di ROM donor (acuan memilih APK Chrome)
chrome_log_donor_lib() {
    local idx=$1 dir f line n=0
    while IFS=$'\t' read -r _pkg dir; do
        for f in "$P_FS/$dir"/*.apk; do
            [[ -f $f ]] || continue
            while IFS= read -r line; do log "$line"; n=$((n + 1)); done < <(
                python3 "$SCRIPT_DIR/apk_static_lib.py" "$f" \
                    | awk -v d="$dir" '$1 == "provides" {print "Browser: ROM donor menyediakan library " $2 " versi " $3 " (" d ")"}')
        done
    done < <(awk -F'\t' 'index($1, "com.google.android.trichromelibrary") == 1' "$idx")
    if [[ $n -eq 0 ]]; then log "Browser: ROM donor tidak punya TrichromeLibrary (Chrome stable tidak bisa jalan tanpa ini)"; fi
}

browser_fallback() {
    local mode=${BROWSER_FALLBACK:-auto} idx="$WORK/browser_port.tsv" re list pkg dir
    local dst_rel=${CHROME_DIR:-product/app/Chrome} dst name src tmp kind apk sz n
    if [[ $mode == false ]]; then log "Browser: dimatikan (BROWSER_FALLBACK=false)"; return 0; fi

    re=$BROWSER_RE_DEFAULT
    if [[ -n ${BROWSER_PACKAGES:-} ]]; then re="${re%\)\$}|${BROWSER_PACKAGES})\$"; fi

    python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" > "$idx"
    list=$(cut -f1 "$idx" | grep -E "$re" | sort -u | tr '\n' ' ' || true)
    if grep -q "^com\.android\.chrome"$'\t' "$idx"; then ok "Browser: Chrome sudah ada di ROM port"; return 0; fi
    if [[ $mode == auto && -n ${list// /} ]]; then
        ok "Browser: donor sudah punya browser ($list) -> Chrome tidak ditambahkan"
        return 0
    fi
    if [[ $mode == auto ]]; then
        log "Browser: ROM donor tidak punya browser (setelah debloat) -> pasang Chrome"
    else
        log "Browser: BROWSER_FALLBACK=true, memasang Chrome (browser yang ada: ${list:-tidak ada})"
    fi

    chrome_log_donor_lib "$idx"
    dst="$P_FS/$dst_rel"
    if [[ ! -d $P_FS/${dst_rel%%/*} ]]; then warn "Browser: partisi ${dst_rel%%/*} tidak ada di ROM port, Chrome tidak dipasang"; return 0; fi
    if [[ -e $dst ]]; then warn "Browser: $dst_rel sudah ada (bukan Chrome), Chrome tidak dipasang. Ganti CHROME_DIR"; return 0; fi

    # ---- sumber 1: CHROME_APK (URL/path)
    if [[ -n ${CHROME_APK:-} ]]; then
        src=$(fetch "$CHROME_APK" "$WORK/dl" chrome_src)
        tmp="$WORK/chrome_tmp"; rm -rf "$tmp"; mkdir -p "$tmp"
        kind=$(python3 - "$src" "$tmp/Chrome.apk" <<'PY'
import sys, zipfile
src, out = sys.argv[1], sys.argv[2]
try:
    z = zipfile.ZipFile(src)
except Exception:
    print("invalid"); raise SystemExit
names = z.namelist()
if "AndroidManifest.xml" in names:
    open(out, "wb").write(open(src, "rb").read()); print("apk")
elif "base.apk" in names:
    open(out, "wb").write(z.read("base.apk")); print("bundle")
else:
    print("invalid")
PY
)
        case $kind in
            apk)    ;;
            bundle) log "Browser: CHROME_APK berupa bundle, hanya base.apk yang dipakai (tanpa split bahasa/dpi)" ;;
            *)      warn "Browser: CHROME_APK bukan APK/bundle valid, Chrome tidak dipasang"; rm -rf "$tmp"; return 0 ;;
        esac
        apk="$tmp/Chrome.apk"
        name=$(python3 "$SCRIPT_DIR/apk_index.py" --apk "$apk")
        if [[ -z $name ]]; then warn "Browser: package CHROME_APK tidak terbaca, Chrome tidak dipasang"; rm -rf "$tmp"; return 0; fi
        if [[ $name != com.android.chrome ]]; then warn "Browser: package CHROME_APK '$name' (bukan com.android.chrome), tetap dipasang"; fi
        if ! chrome_static_lib_ok "$apk" && ! is_true "${CHROME_FORCE:-false}"; then
            warn "Browser: Chrome TIDAK dipasang (versi library tidak cocok). CHROME_FORCE=true untuk memaksa"
            rm -rf "$tmp"; return 0
        fi
        mkdir -p "$dst"
        cp -f "$apk" "$dst/${dst_rel##*/}.apk"; chmod 0644 "$dst/${dst_rel##*/}.apk"
        n=$(chrome_extract_libs "$apk" "$dst")
        if [[ ${n:-0} -gt 0 ]]; then log "Browser: $n library native diekstrak ke $dst_rel/lib"; fi
        sz=$(du -sb "$dst" | cut -f1)
        ok "Browser: $name -> $dst_rel ($(( sz / 1048576 )) MB, dari CHROME_APK)"
        rm -rf "$tmp"
        return 0
    fi

    # ---- sumber 2: Chrome di product ROM base
    if is_true "${CHROME_FROM_BASE:-true}"; then
        python3 "$SCRIPT_DIR/apk_index.py" "$B_FS" > "$WORK/browser_base.tsv"
        dir=$(awk -F'\t' '$1 == "com.android.chrome" && $2 ~ /^product\// {print $2; exit}' "$WORK/browser_base.tsv")
        if [[ -n $dir ]]; then
            apk=$(find "$B_FS/$dir" -maxdepth 1 -name '*.apk' | head -n1)
            if ! chrome_static_lib_ok "$apk" && ! is_true "${CHROME_FORCE:-false}"; then
                warn "Browser: Chrome dari base TIDAK dipasang (versi library tidak cocok dengan donor). Isi CHROME_APK dengan Chrome yang cocok, atau CHROME_FORCE=true"
                return 0
            fi
            dst="$P_FS/$dir"
            if [[ -e $dst ]]; then warn "Browser: $dir sudah ada di ROM port, Chrome dari base dilewati"; return 0; fi
            mkdir -p "$(dirname "$dst")"
            cp -a "$B_FS/$dir" "$dst"
            rm -rf "${dst:?}/oat"   # odex/vdex dari base tidak cocok dengan Android donor
            sz=$(du -sb "$dst" | cut -f1)
            ok "Browser: com.android.chrome -> $dir ($(( sz / 1048576 )) MB, dari ROM base)"
            return 0
        fi
        log "Browser: ROM base juga tidak punya Chrome di product"
    fi
    warn "Browser: tidak ada sumber Chrome (CHROME_APK kosong dan base tanpa Chrome) -> ROM tanpa browser. Isi CHROME_APK dengan URL APK Chrome"
    return 0
}
