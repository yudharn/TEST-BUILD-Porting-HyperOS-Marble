#!/usr/bin/env bash
# =============================================================================
#  port_gms.sh - salin GMS / Play Store dari ROM base kalau donor tidak punya
#  (di-source oleh port.sh; hanya berisi fungsi)
#
#  ROM donor China biasanya tanpa Google Play Services (com.google.android.gms),
#  Google Services Framework (com.google.android.gsf) dan Play Store (com.android.vending).
#
#  GMS_FROM_BASE : auto  = jalan hanya kalau salah satu dari gms/gsf/vending tidak ada di donor (default)
#                  true  = selalu, isi paket Google yang belum ada di donor
#                  false = mati
#  GMS_SCOPE     : core  = gms + gsf + vending + pendukungnya (ext services, partner setup, sync adapter, ...) (default)
#                  all   = semua com.google.android.* di base (kecuali WebView/Chrome/keyboard)
#  GMS_EXCLUDE   : regex tambahan (nama package / path) yang tidak ikut disalin
#
#  Yang disalin dari partisi product base (system/system_ext base tidak diekstrak):
#    - folder app Google (app/, priv-app/, data-app/), beserta allowlist privapp dari base
#    - etc/{permissions,default-permissions,sysconfig,preferred-apps}/*google|gms|gsf|vending|phonesky*
#    - overlay *Gms*/*Google*  dan  framework/*google*.jar
#  Tidak ada file donor yang ditimpa (cp -n / folder yang sudah ada dilewati).
# =============================================================================

GMS_CORE_PKGS="com.google.android.gms com.google.android.gsf com.android.vending"
GMS_CORE_RE='^(com\.google\.android\.gms(\..*)?|com\.google\.android\.gsf(\..*)?|com\.android\.vending|com\.google\.android\.(ext\.services|ext\.shared|partnersetup|onetimeinitializer|backuptransport|configupdater|syncadapters\.contacts|syncadapters\.calendar))$'
GMS_ALL_RE='^(com\.google\.android\..*|com\.android\.vending)$'
GMS_EXCLUDE_DEFAULT='webview|trichrome|chrome|inputmethod|keyboard'

# pkg_in_index <pkg> <file tsv pkg\tdir>
gms_pkg_in_index() { awk -F'\t' -v p="$1" '$1 == p {f = 1} END {exit !f}' "$2"; }

gms_from_base() {
    local mode=${GMS_FROM_BASE:-auto} scope=${GMS_SCOPE:-core}
    local excl="${GMS_EXCLUDE_DEFAULT}${GMS_EXCLUDE:+|$GMS_EXCLUDE}"
    local pidx="$WORK/gms_port.tsv" bidx="$WORK/gms_base.tsv"
    local re core miss="" base_miss="" pkg dir sz bytes=0 napp=0 ncfg=0 nextra=0 f rel d sub dre
    local -A seen=() seenpkg=()

    if [[ $mode == false ]]; then log "GMS: dimatikan (GMS_FROM_BASE=false)"; return 0; fi
    case $scope in
        core) re=$GMS_CORE_RE ;;
        all)  re=$GMS_ALL_RE ;;
        *)    warn "GMS: GMS_SCOPE '$scope' tidak dikenal (core|all), pakai core"; re=$GMS_CORE_RE ;;
    esac

    python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" > "$pidx"
    for core in $GMS_CORE_PKGS; do
        if ! gms_pkg_in_index "$core" "$pidx"; then miss+=" $core"; fi
    done

    if [[ $mode == auto && -z $miss ]]; then
        ok "GMS: donor sudah punya gms, gsf, dan Play Store -> tidak perlu salin dari base"
        return 0
    fi
    if [[ -n $miss ]]; then
        log "GMS: donor tidak punya:$miss -> salin dari ROM base (scope: $scope)"
    else
        log "GMS: GMS_FROM_BASE=true, melengkapi paket Google yang belum ada di donor (scope: $scope)"
    fi

    python3 "$SCRIPT_DIR/apk_index.py" "$B_FS" > "$bidx"
    for core in $miss; do
        if ! gms_pkg_in_index "$core" "$bidx"; then base_miss+=" $core"; fi
    done
    if [[ -n $base_miss ]]; then
        warn "GMS: ROM base juga tidak punya:$base_miss (hanya partisi product base yang dicek) -> tidak bisa disalin"
    fi

    # ---- folder app
    dre='/(app|priv-app|data-app)/[^/]+$'
    while IFS=$'\t' read -r -u 3 pkg dir; do
        [[ -n $pkg && -n $dir ]] || continue
        [[ $dir == product/* ]] || continue
        [[ $dir =~ $dre ]] || continue
        grep -qE "$re" <<< "$pkg" || continue
        if grep -qiE "$excl" <<< "$pkg $dir"; then continue; fi
        if gms_pkg_in_index "$pkg" "$pidx"; then continue; fi          # donor sudah punya package ini
        if [[ -n ${seen[$dir]:-} || -n ${seenpkg[$pkg]:-} ]]; then continue; fi
        seen[$dir]=1; seenpkg[$pkg]=1
        if [[ -e $P_FS/$dir ]]; then
            warn "GMS: $dir sudah ada di donor dengan package lain, $pkg dilewati"; continue
        fi
        mkdir -p "$P_FS/$(dirname "$dir")"
        cp -a "$B_FS/$dir" "$P_FS/$dir"
        rm -rf "${P_FS:?}/$dir/oat"   # odex/vdex dari base tidak cocok dengan Android donor
        sz=$(du -sb "$P_FS/$dir" | cut -f1); bytes=$(( bytes + sz )); napp=$((napp + 1))
        ok "GMS: $pkg -> $dir ($(( sz / 1048576 )) MB)"
        base_privapp_perms "$dir"
    done 3< "$bidx"

    # ---- konfigurasi: permissions / default-permissions / sysconfig / preferred-apps
    for sub in permissions default-permissions sysconfig preferred-apps; do
        d="$B_FS/product/etc/$sub"
        [[ -d $d ]] || continue
        while IFS= read -r -d '' f; do
            rel=${f#"$B_FS"/}
            if [[ -e $P_FS/$rel ]]; then continue; fi
            mkdir -p "$P_FS/$(dirname "$rel")"
            cp -a "$f" "$P_FS/$rel"; ncfg=$((ncfg + 1))
        done < <(find "$d" -type f \( -iname '*google*' -o -iname '*gms*' -o -iname '*gsf*' -o -iname '*vending*' -o -iname '*phonesky*' \) -print0)
    done

    # ---- overlay Gms/Google + framework jar Google
    for sub in overlay framework; do
        d="$B_FS/product/$sub"
        [[ -d $d ]] || continue
        while IFS= read -r -d '' f; do
            rel=${f#"$B_FS"/}
            if [[ -e $P_FS/$rel ]]; then continue; fi
            mkdir -p "$P_FS/$(dirname "$rel")"
            cp -a "$f" "$P_FS/$rel"; nextra=$((nextra + 1))
        done < <(
            if [[ $sub == overlay ]]; then
                find "$d" -type f \( -iname '*gms*.apk' -o -iname '*google*.apk' \) -print0
            else
                find "$d" -type f -iname '*google*.jar' -print0
            fi)
    done

    ok "GMS: $napp app ($(( bytes / 1048576 )) MB), $ncfg file konfigurasi, $nextra overlay/framework disalin dari base"

    # ---- cek ulang
    python3 "$SCRIPT_DIR/apk_index.py" "$P_FS" > "$pidx"
    miss=""
    for core in $GMS_CORE_PKGS; do
        if ! gms_pkg_in_index "$core" "$pidx"; then miss+=" $core"; fi
    done
    if [[ -n $miss ]]; then
        warn "GMS: setelah disalin masih tidak ada:$miss -> login Google / Play Store tidak akan jalan"
    else
        ok "GMS: gms, gsf, dan Play Store sekarang ada di ROM port"
    fi
}
