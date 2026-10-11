#!/usr/bin/env bash
# =============================================================================
#  port_apps.sh - ganti app tertentu di ROM port dengan APK dari URL (default saat build)
#  (di-source oleh port.sh; hanya berisi fungsi)
#
#  Default:
#    GALLERY_APK     -> com.miui.gallery     (Gallery 4.3.1.16)       product/priv-app/MiuiGallery
#    MEDIAEDITOR_APK -> com.miui.mediaeditor (Editor Galeri 2.11.10)  product/app/MiMediaEditor
#    CAMERA_APK      -> com.android.camera   (Camera 6.7.000070.0)    product/priv-app/MiuiCamera
#
#  APPS_FROM_URL=false mematikan semua. URL dikosongkan (GALLERY_APK="") = lewati app itu saja.
#  Boleh .apk atau bundle (.apkm/.xapk/.apks, hanya base.apk yang dipakai).
#
#  Cara kerja per app:
#    - folder app yang paketnya sama di ROM port dicari lewat nama package (bukan nama folder),
#      lalu DIGANTI UTUH (APK lama + lib lama + oat dibuang). Tidak ada -> dibuat di lokasi default.
#    - lib native diekstrak ke <folder>/lib/arm64 (+ arm), seperti Gboard/Chrome
#    - priv-app: dibuat allowlist privapp-permissions dari <uses-permission> APK, supaya izin
#      privileged versi baru tidak membuat system_server crash saat boot (enforce)
#  Dipanggil SETELAH debloat dan setelah file devices/, jadi mengalahkan keduanya
#  (termasuk MiMediaEditor yang dihapus debloat dan MiuiCamera dari base).
# =============================================================================

GALLERY_APK=${GALLERY_APK-https://github.com/Yudharmdn/boot-melt-rebase/releases/download/boot-melt-rebase/Gallery-4.3.1.16.apk}
MEDIAEDITOR_APK=${MEDIAEDITOR_APK-https://github.com/Yudharmdn/boot-melt-rebase/releases/download/boot-melt-rebase/Editor.Galeri_2.11.10.0.3.apk}
CAMERA_APK=${CAMERA_APK-https://github.com/Yudharmdn/boot-melt-rebase/releases/download/boot-melt-rebase/Camera_6.7.000070.0.apk}
APPS_FROM_URL=${APPS_FROM_URL:-true}

# cek URL lebih awal (dipanggil dari tahap 0 di port.sh), supaya 404 ketahuan sebelum build 20 menit
apps_check_urls() {
    is_true "$APPS_FROM_URL" || return 0
    if [[ -n $GALLERY_APK ]]; then check_url GALLERY_APK "$GALLERY_APK"; fi
    if [[ -n $MEDIAEDITOR_APK ]]; then check_url MEDIAEDITOR_APK "$MEDIAEDITOR_APK"; fi
    if [[ -n $CAMERA_APK ]]; then check_url CAMERA_APK "$CAMERA_APK"; fi
    return 0
}

# apps_extract_libs <apk> <dir> : lib native -> <dir>/lib/arm64 (+ arm); cetak jumlah file
apps_extract_libs() {
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

# apps_privapp_allowlist <apk> <pkg> <rel dir app> : allowlist dari uses-permission APK
apps_privapp_allowlist() {
    local apk=$1 pkg=$2 dir=$3 etc out n=0 perm
    case $dir in
        system/*) etc="$P_FS/system/system/etc/permissions" ;;
        *)        etc="$P_FS/${dir%%/*}/etc/permissions" ;;
    esac
    mkdir -p "$etc"
    out="$etc/privapp-permissions-${TARGET_DEVICE}-apk-${pkg//./_}.xml"
    {
        printf '<?xml version="1.0" encoding="utf-8"?>\n<!-- dibuat port.sh dari <uses-permission> APK (port_apps.sh) -->\n<permissions>\n'
        printf '    <privapp-permissions package="%s">\n' "$pkg"
        while IFS= read -r perm; do
            [[ $perm =~ ^[A-Za-z0-9_.]+$ ]] || continue
            printf '        <permission name="%s"/>\n' "$perm"
        done < <(python3 "$SCRIPT_DIR/apk_perms.py" "$apk")
        printf '    </privapp-permissions>\n</permissions>\n'
    } > "$out"
    chmod 0644 "$out"
    n=$(grep -c '<permission name=' "$out" || true)
    if [[ ${n:-0} -gt 0 ]]; then
        ok "Apps: allowlist privapp $pkg: $n izin -> ${out#"$P_FS"/}"
    else
        warn "Apps: $pkg tidak meminta izin apa pun? allowlist kosong dibuat (${out#"$P_FS"/})"
    fi
}

# apps_install <label> <package yang diharapkan> <url/path> <folder default>
apps_install() {
    local label=$1 want=$2 url=$3 def=$4
    local src tmp kind apk pkg idx="$WORK/apps/port_index.tsv" dir name old=0 new nlib d
    local -a dirs=()

    src=$(fetch "$url" "$WORK/dl" "app_$label")
    tmp="$WORK/apps/$label"; rm -rf "$tmp"; mkdir -p "$tmp"
    kind=$(python3 - "$src" "$tmp/app.apk" <<'PY'
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
        bundle) log "Apps: $label berupa bundle, hanya base.apk yang dipakai (tanpa split bahasa/dpi)" ;;
        *)      warn "Apps: $label bukan APK/bundle valid ($url), dilewati"; rm -rf "$tmp"; return 0 ;;
    esac
    apk="$tmp/app.apk"
    pkg=$(python3 "$SCRIPT_DIR/apk_index.py" --apk "$apk")
    if [[ -z $pkg ]]; then warn "Apps: package $label tidak terbaca dari AndroidManifest, dilewati"; rm -rf "$tmp"; return 0; fi
    if [[ $pkg != "$want" ]]; then
        if is_true "${APPS_FORCE:-false}"; then
            warn "Apps: $label berpackage '$pkg', bukan $want (APPS_FORCE=true, tetap dipasang)"
        else
            warn "Apps: $label berpackage '$pkg', bukan $want -> kemungkinan URL salah, app donor dibiarkan. APPS_FORCE=true untuk memaksa"
            rm -rf "$tmp"; return 0
        fi
    fi

    # folder yang sudah memakai package ini di ROM port (lewat nama package, apa pun nama foldernya)
    python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" > "$idx"
    mapfile -t dirs < <(awk -F'\t' -v p="$pkg" '$1 == p {print $2}' "$idx")
    if [[ ${#dirs[@]} -gt 0 ]]; then
        dir=${dirs[0]}
        for d in "${dirs[@]}"; do
            if [[ $d == "$def" ]]; then dir=$d; break; fi
        done
    else
        dir=$def
    fi
    if [[ ! -d $P_FS/${dir%%/*} ]]; then
        warn "Apps: partisi ${dir%%/*} tidak ada di ROM port, $label dilewati"; rm -rf "$tmp"; return 0
    fi
    # package yang sama di folder lain = duplikat -> dibuang, supaya tidak bentrok
    for d in "${dirs[@]}"; do
        [[ $d == "$dir" ]] && continue
        rm -rf "${P_FS:?}/$d"; warn "Apps: duplikat $pkg di $d dibuang"
    done

    if [[ -d $P_FS/$dir ]]; then old=$(du -sb "$P_FS/$dir" | cut -f1); fi
    rm -rf "${P_FS:?}/$dir"
    mkdir -p "$P_FS/$dir"
    name=${dir##*/}
    cp -f "$apk" "$P_FS/$dir/$name.apk"; chmod 0644 "$P_FS/$dir/$name.apk"
    nlib=$(apps_extract_libs "$apk" "$P_FS/$dir")
    new=$(du -sb "$P_FS/$dir" | cut -f1)
    ok "Apps: $label ($pkg) -> $dir  [lama $(( old / 1048576 )) MB -> baru $(( new / 1048576 )) MB, $nlib lib native]"
    if [[ $dir == */priv-app/* ]]; then apps_privapp_allowlist "$apk" "$pkg" "$dir"; fi
    rm -rf "$tmp"
}

apps_from_url() {
    if ! is_true "$APPS_FROM_URL"; then log "Apps: penggantian app dari URL dimatikan (APPS_FROM_URL=false)"; return 0; fi
    mkdir -p "$WORK/apps"
    if [[ -n $GALLERY_APK ]]; then apps_install gallery com.miui.gallery "$GALLERY_APK" product/priv-app/MiuiGallery
    else log "Apps: GALLERY_APK kosong, Galeri donor dipakai"; fi
    if [[ -n $MEDIAEDITOR_APK ]]; then apps_install mediaeditor com.miui.mediaeditor "$MEDIAEDITOR_APK" product/app/MiMediaEditor
    else log "Apps: MEDIAEDITOR_APK kosong, MiMediaEditor tidak dipasang"; fi
    if [[ -n $CAMERA_APK ]]; then apps_install camera com.android.camera "$CAMERA_APK" product/priv-app/MiuiCamera
    else log "Apps: CAMERA_APK kosong, kamera dari base/donor dipakai"; fi
    return 0
}
