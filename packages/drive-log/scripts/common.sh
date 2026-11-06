#!/system/bin/sh
# Helpers for the opt-in USB-only structured drive logger.
DL_SEGMENT_BYTES=1048576
DL_SEGMENTS=32
DL_MIN_FREE_KB=65536
if [ "${DL_TESTING:-0}" = 1 ]; then
    DL_SEGMENT_BYTES=${DL_SEGMENT_BYTES_OVERRIDE:-$DL_SEGMENT_BYTES}
    DL_SEGMENTS=${DL_SEGMENTS_OVERRIDE:-$DL_SEGMENTS}
    DL_MIN_FREE_KB=${DL_MIN_FREE_KB_OVERRIDE:-$DL_MIN_FREE_KB}
fi

dl_number() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    return 0
}

# One /proc/mounts entry for a mount point: "source|fstype", or a reason word.
dl_mount_entry() {
    _dl_point=$1 _dl_mounts=$2
    _dl_count=0 _dl_source= _dl_fs=
    while IFS=' ' read -r _dl_s _dl_m _dl_t _dl_opts _dl_rest; do
        [ "$_dl_m" = "$_dl_point" ] || continue
        _dl_count=$((_dl_count + 1))
        _dl_source=$_dl_s _dl_fs=$_dl_t
    done < "$_dl_mounts"
    [ "$_dl_count" != 0 ] || { print -r -- unmounted; return 1; }
    [ "$_dl_count" = 1 ] || { print -r -- multiple-mounts; return 1; }
    print -r -- "$_dl_source|$_dl_fs"
}

# Prints "source|fstype|major:minor|directory" for the removable USB filesystem
# behind $1. The directory is $1 itself when vold mounts the USB there, or the
# vold mount under /mnt/media_rw when $1 is the Android 4.4 FUSE view of it.
# On failure prints "!reason" (one fixed word) and returns 1.
dl_mount_info() {
    _dl_usb=$1 _dl_mounts=$2 _dl_sys=$3 _dl_media=${4:-${DL_MEDIA_RW:-/mnt/media_rw}}
    [ -d "$_dl_usb" ] && [ ! -L "$_dl_usb" ] || { print -r -- '!no-usb-directory'; return 1; }
    [ -f "$_dl_mounts" ] && [ ! -L "$_dl_mounts" ] || { print -r -- '!no-mount-table'; return 1; }
    _dl_entry=$(dl_mount_entry "$_dl_usb" "$_dl_mounts") || { print -r -- "!$_dl_entry"; return 1; }
    _dl_path=$_dl_usb
    case "$_dl_entry" in
        *'|fuse')
            _dl_path=$_dl_media/${_dl_usb##*/}
            [ -d "$_dl_path" ] && [ ! -L "$_dl_path" ] || { print -r -- '!fuse-without-media-rw'; return 1; }
            _dl_entry=$(dl_mount_entry "$_dl_path" "$_dl_mounts") || { print -r -- "!fuse-$_dl_entry"; return 1; }
            ;;
    esac
    _dl_source=${_dl_entry%%\|*} _dl_fs=${_dl_entry#*\|}
    case "$_dl_fs" in vfat|exfat|texfat|sdfat) ;; *) print -r -- '!unsupported-filesystem'; return 1;; esac
    case "$_dl_source" in
        /dev/block/vold/*) _dl_dev=${_dl_source##*/};;
        /dev/block/*)
            _dl_name=${_dl_source##*/} _dl_dev=
            [ -f "$_dl_sys/class/block/$_dl_name/dev" ] && [ ! -L "$_dl_sys/class/block/$_dl_name/dev" ] || { print -r -- '!unknown-block-device'; return 1; }
            IFS= read -r _dl_dev < "$_dl_sys/class/block/$_dl_name/dev" || [ -n "$_dl_dev" ] || { print -r -- '!unknown-block-device'; return 1; }
            ;;
        *) print -r -- '!not-a-block-device'; return 1;;
    esac
    case "$_dl_dev" in *:*) ;; *) print -r -- '!unknown-block-device'; return 1;; esac
    _dl_major=${_dl_dev%%:*} _dl_minor=${_dl_dev#*:}
    dl_number "$_dl_major" && dl_number "$_dl_minor" || { print -r -- '!unknown-block-device'; return 1; }
    _dl_sysdev=$_dl_sys/dev/block/$_dl_dev
    [ -L "$_dl_sysdev" ] || { print -r -- '!no-sysfs-device'; return 1; }
    _dl_real=$( (CDPATH= cd -P "$_dl_sysdev" 2>/dev/null && pwd -P) ) || { print -r -- '!no-sysfs-device'; return 1; }
    case "$_dl_real" in */devices/*/usb[0-9]/*) ;; *) print -r -- '!not-usb-storage'; return 1;; esac
    _dl_uevent=$_dl_sysdev/uevent
    [ -f "$_dl_uevent" ] || { print -r -- '!no-sysfs-device'; return 1; }
    _dl_seen_major= _dl_seen_minor=
    while IFS= read -r _dl_line || [ -n "$_dl_line" ]; do
        case "$_dl_line" in
            MAJOR=*) _dl_seen_major=${_dl_line#MAJOR=};;
            MINOR=*) _dl_seen_minor=${_dl_line#MINOR=};;
        esac
    done < "$_dl_uevent"
    [ "$_dl_seen_major" = "$_dl_major" ] && [ "$_dl_seen_minor" = "$_dl_minor" ] || { print -r -- '!device-number-mismatch'; return 1; }
    print -r -- "$_dl_source|$_dl_fs|$_dl_dev|$_dl_path"
}

dl_opt_in() {
    _dl_usb=$1
    [ -d "$_dl_usb" ] && [ ! -L "$_dl_usb" ] || return 1
    [ -f "$_dl_usb/GEN5W-DEBUG-ON" ] && [ ! -L "$_dl_usb/GEN5W-DEBUG-ON" ] || return 1
    [ ! -e "$_dl_usb/GEN5W-DEBUG-OFF" ] && [ ! -L "$_dl_usb/GEN5W-DEBUG-OFF" ] || return 1
    return 0
}

dl_validate_record() {
    _dl_record=$1
    [ "${#_dl_record}" -le 128 ] || return 1
    _dl_old_ifs=$IFS; IFS='|'; set -- $_dl_record; IFS=$_dl_old_ifs
    [ "$#" = 10 ] && [ "$1" = D1 ] || return 1
    case "$3" in 1|2) ;; *) return 1;; esac
    case "$4" in 1|2|20|21|22|24|25|26|27) ;; *) return 1;; esac
    shift
    _dl_pos=2
    for _dl_field in "$@"; do
        case "$_dl_field" in -*) _dl_digits=${_dl_field#-};; *) _dl_digits=$_dl_field;; esac
        if [ "$_dl_pos" = 2 ]; then [ "${#_dl_digits}" -le 13 ] || return 1
        else [ "${#_dl_digits}" -le 10 ] || return 1; fi
        dl_number "$_dl_digits" || return 1
        _dl_pos=$((_dl_pos + 1))
    done
    return 0
}

dl_uptime_ms() {
    _dl_uptime_file=${DL_PROC_UPTIME:-/proc/uptime}
    [ -f "$_dl_uptime_file" ] && [ ! -L "$_dl_uptime_file" ] || return 1
    IFS=' ' read -r _dl_value _dl_rest < "$_dl_uptime_file" || return 1
    case "$_dl_value" in *.*) _dl_seconds=${_dl_value%%.*}; _dl_fraction=${_dl_value#*.};;
        *) _dl_seconds=$_dl_value; _dl_fraction=0;; esac
    dl_number "$_dl_seconds" || return 1
    case "$_dl_fraction" in ''|*[!0-9]*) return 1;; esac
    _dl_fraction=${_dl_fraction}000
    _dl_fraction=${_dl_fraction%${_dl_fraction#???}}
    # Keep uptime as decimal text: mksh R43 on the 32-bit head unit can
    # overflow shell arithmetic after roughly 24.8 days when expressed in ms.
    print -r -- "${_dl_seconds}${_dl_fraction}"
}

dl_record_uptime() {
    _dl_old_ifs=$IFS; IFS='|'; set -- $1; IFS=$_dl_old_ifs
    [ "$#" = 10 ] && [ "$1" = D1 ] || return 1
    print -r -- "$2"
}

dl_record_after() {
    _dl_start=$1 _dl_record=$2
    dl_number "$_dl_start" || return 1
    _dl_record_time=$(dl_record_uptime "$_dl_record") || return 1
    dl_decimal_ge "$_dl_record_time" "$_dl_start"
}

dl_decimal_ge() {
    dl_number "$1" && dl_number "$2" || return 1
    _dl_decimal_left=$1 _dl_decimal_right=$2
    while [ "${#_dl_decimal_left}" -gt 1 ]; do
        case "$_dl_decimal_left" in 0*) _dl_decimal_left=${_dl_decimal_left#0};; *) break;; esac
    done
    while [ "${#_dl_decimal_right}" -gt 1 ]; do
        case "$_dl_decimal_right" in 0*) _dl_decimal_right=${_dl_decimal_right#0};; *) break;; esac
    done
    [ "${#_dl_decimal_left}" -gt "${#_dl_decimal_right}" ] && return 0
    [ "${#_dl_decimal_left}" -lt "${#_dl_decimal_right}" ] && return 1
    [[ "$_dl_decimal_left" = "$_dl_decimal_right" || "$_dl_decimal_left" > "$_dl_decimal_right" ]]
}

dl_increment_decimal() {
    _dl_increment_input=$1
    dl_number "$_dl_increment_input" || return 1
    _dl_increment_output= _dl_increment_carry=1
    while [ -n "$_dl_increment_input" ]; do
        _dl_increment_digit=${_dl_increment_input#${_dl_increment_input%?}}
        _dl_increment_input=${_dl_increment_input%?}
        if [ "$_dl_increment_carry" = 1 ]; then
            case "$_dl_increment_digit" in
                0) _dl_increment_digit=1; _dl_increment_carry=;;
                1) _dl_increment_digit=2; _dl_increment_carry=;;
                2) _dl_increment_digit=3; _dl_increment_carry=;;
                3) _dl_increment_digit=4; _dl_increment_carry=;;
                4) _dl_increment_digit=5; _dl_increment_carry=;;
                5) _dl_increment_digit=6; _dl_increment_carry=;;
                6) _dl_increment_digit=7; _dl_increment_carry=;;
                7) _dl_increment_digit=8; _dl_increment_carry=;;
                8) _dl_increment_digit=9; _dl_increment_carry=;;
                9) _dl_increment_digit=0;;
            esac
        fi
        _dl_increment_output=${_dl_increment_digit}${_dl_increment_output}
    done
    [ -z "$_dl_increment_carry" ] || _dl_increment_output=1$_dl_increment_output
    print -r -- "$_dl_increment_output"
}

dl_read_timeout() {
    dl_number "$1" && dl_number "$2" || return 1
    dl_decimal_ge "$2" "$1" || return 1
    [ "${#1}" -ge 4 ] || return 1
    _dl_timeout_seconds=${1%???}
    _dl_timeout_len=${#1}
    _dl_timeout_millis=${1:$((_dl_timeout_len - 3)):3}
    _dl_timeout_next=$(dl_increment_decimal "$_dl_timeout_seconds") || return 1
    _dl_timeout_target=${_dl_timeout_next}${_dl_timeout_millis}
    dl_decimal_ge "$2" "$_dl_timeout_target"
}

dl_empty_directory() {
    _dl_dir=$1
    for _dl_entry in "$_dl_dir"/* "$_dl_dir"/.[!.]* "$_dl_dir"/..?*; do
        [ -e "$_dl_entry" ] || [ -L "$_dl_entry" ] || continue
        return 1
    done
    return 0
}

dl_size_from_ls() {
    # GNU ls includes a link-count column; Android toolbox ls does not.
    # In either layout the byte size is field 5 or 4 respectively.
    _dl_ls_line=$1
    set -- $_dl_ls_line
    _dl_size=${5:-}
    case "$_dl_size" in ''|*[!0-9]*) _dl_size=${4:-};; esac
    dl_number "$_dl_size" || return 1
    print -r -- "$_dl_size"
}

dl_prepare_ring() {
    _dl_dir=$1
    [ ! -L "$_dl_dir" ] || return 1
    if [ ! -e "$_dl_dir" ]; then
        mkdir "$_dl_dir" 2>/dev/null || return 1
        print -r -- 'gen5w-drive-log-v1' > "$_dl_dir/.owner" || return 1
        print -r -- 0 > "$_dl_dir/.cursor" || return 1
        return 0
    fi
    [ -d "$_dl_dir" ] || return 1
    if [ ! -e "$_dl_dir/.owner" ]; then
        dl_empty_directory "$_dl_dir" || return 1
        print -r -- 'gen5w-drive-log-v1' > "$_dl_dir/.owner" || return 1
    fi
    [ -f "$_dl_dir/.owner" ] && [ ! -L "$_dl_dir/.owner" ] || return 1
    [ "$(cat "$_dl_dir/.owner" 2>/dev/null)" = gen5w-drive-log-v1 ] || return 1
    if [ ! -e "$_dl_dir/.cursor" ]; then
        print -r -- 0 > "$_dl_dir/.cursor" || return 1
    fi
    [ -f "$_dl_dir/.cursor" ] && [ ! -L "$_dl_dir/.cursor" ] || return 1
    _dl_cursor=$(cat "$_dl_dir/.cursor" 2>/dev/null)
    dl_number "$_dl_cursor" || return 1
    [ "$_dl_cursor" -lt "$DL_SEGMENTS" ] || return 1
    # A crash during the cursor rename is ambiguous. Preserve it and stop rather
    # than deleting/truncating state whose ownership may no longer be certain.
    [ ! -e "$_dl_dir/.cursor.tmp" ] && [ ! -L "$_dl_dir/.cursor.tmp" ] || return 1
    return 0
}

dl_write_record() {
    _dl_dir=$1 _dl_record=$2 _dl_free_kb=$3
    dl_validate_record "$_dl_record" || return 1
    dl_number "$_dl_free_kb" && [ "$_dl_free_kb" -ge "$DL_MIN_FREE_KB" ] || return 1
    dl_prepare_ring "$_dl_dir" || return 1
    _dl_cursor=$(cat "$_dl_dir/.cursor" 2>/dev/null) || return 1
    _dl_name=$_dl_cursor
    case "$_dl_name" in [0-9]) _dl_name=0$_dl_name;; esac
    _dl_file=$_dl_dir/segment-$_dl_name.log
    [ ! -L "$_dl_file" ] || return 1
    if [ -e "$_dl_file" ]; then [ -f "$_dl_file" ] || return 1; fi
    _dl_size=0
    if [ -f "$_dl_file" ]; then
        _dl_ls=$(LC_ALL=C ls -ln "$_dl_file" 2>/dev/null) || return 1
        _dl_size=$(dl_size_from_ls "$_dl_ls") || return 1
        dl_number "$_dl_size" || return 1
    fi
    _dl_record_size=$((${#_dl_record} + 1))
    [ "$_dl_record_size" -le "$DL_SEGMENT_BYTES" ] || return 1
    if [ $((_dl_size + _dl_record_size)) -gt "$DL_SEGMENT_BYTES" ]; then
        _dl_next=$(((_dl_cursor + 1) % DL_SEGMENTS))
        _dl_next_name=$_dl_next
        case "$_dl_next_name" in [0-9]) _dl_next_name=0$_dl_next_name;; esac
        _dl_next_file=$_dl_dir/segment-$_dl_next_name.log
        [ ! -L "$_dl_next_file" ] || return 1
        if [ -e "$_dl_next_file" ]; then [ -f "$_dl_next_file" ] || return 1; fi
        [ ! -e "$_dl_dir/.cursor.tmp" ] && [ ! -L "$_dl_dir/.cursor.tmp" ] || return 1
        print -r -- "$_dl_next" > "$_dl_dir/.cursor.tmp" || return 1
        mv "$_dl_dir/.cursor.tmp" "$_dl_dir/.cursor" || return 1
        : > "$_dl_next_file" || return 1
        _dl_file=$_dl_next_file
    elif [ ! -e "$_dl_file" ]; then
        : > "$_dl_file" || return 1
    fi
    print -r -- "$_dl_record" >> "$_dl_file" || return 1
    return 0
}

# Toolbox df prints sizes such as "14G", "512M" or "14.9G"; GNU df prints
# 1K blocks. Both become kilobytes, capped below the 32-bit shell limit.
dl_size_kb() {
    _dl_size_value=$1 _dl_size_unit=K
    case "$_dl_size_value" in
        *[KMGT]) _dl_size_unit=${_dl_size_value#${_dl_size_value%?}}; _dl_size_value=${_dl_size_value%?};;
    esac
    _dl_size_int=${_dl_size_value%%.*} _dl_size_tenth=0
    case "$_dl_size_value" in *.*) _dl_size_tenth=${_dl_size_value#*.}; _dl_size_tenth=${_dl_size_tenth:0:1};; esac
    dl_number "$_dl_size_int" && dl_number "$_dl_size_tenth" || return 1
    [ "${#_dl_size_int}" -le 9 ] || _dl_size_int=999999999
    case "$_dl_size_unit" in
        K) print -r -- "$_dl_size_int";;
        M) [ "$_dl_size_int" -lt 200000 ] || { print -r -- 2000000000; return 0; }
           print -r -- $((_dl_size_int * 1024 + _dl_size_tenth * 102));;
        G) [ "$_dl_size_int" -lt 200 ] || { print -r -- 2000000000; return 0; }
           print -r -- $((_dl_size_int * 1048576 + _dl_size_tenth * 104857));;
        *) print -r -- 2000000000;;
    esac
}

dl_free_kb() {
    _dl_usb=$1 _dl_source=$2 _dl_df=${DL_DF:-df}
    # Toolbox df takes no options (it would treat -k as a path) and names the
    # row after the path given; GNU df names it after the source device.
    _dl_output=$("$_dl_df" "$_dl_usb" 2>/dev/null)
    while IFS= read -r _dl_line; do
        set -- $_dl_line
        [ "$#" -ge 4 ] || continue
        [ "$1" = "$_dl_source" ] || [ "$1" = "$_dl_usb" ] || continue
        dl_size_kb "$4"
        return
    done <<DLEOF
$_dl_output
DLEOF
    return 1
}
