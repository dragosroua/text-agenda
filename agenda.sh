#!/bin/bash
# Text agenda. Bash 3.2, tput, and the weekday-DD-MM-YYYY files beside this script.
# Run: ./agenda.sh     Check: ./agenda.sh --check

DIR=$(cd "$(dirname "$0")" && pwd)

WDAYS=(sunday monday tuesday wednesday thursday friday saturday)
WCAPS=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
MONTHS=("" January February March April May June July August September October November December)

cur_y=2026
cur_m=9
cur_d=21
ty=2026
tm=9
td=21

label_names=()
task_label=()
task_indent=()
task_mark=()
task_text=()
task_id=()
next_id=1
vis=()

cur_label=0
cur_task=0
task_scroll=0
label_scroll=0
focus=grid
left_focus=grid
mode=normal
dirty=0
saved_once=0
status_msg=""
query=""
cur_hit=0
hit_scroll=0
small=0
rows=24
cols=80
WINCHED=0
STTY_ORIG=""
started=0

hit_y=()
hit_m=()
hit_d=()
hit_lab=()
hit_ind=()
hit_text=()

undo_stack=()
undo_pos=0

FILE_MARKS=" "

C_RESET=""
C_DIM=""
C_REV=""
C_UL=""
C_UL0=""
C_ACC=""
C_YEL=""
C_GRN=""
C_BOLD=""
C_ITAL=""

LWC=23
BAR=23
RC=24
OX=0
OY=0
RW=56
STATUS_ROW=23

# --- terminal -----------------------------------------------------------

S_EL=""
S_CLEAR=""
S_CIVIS=""
S_CNORM=""
S_ED=""
ANSI_CUP=0

cache_caps() {
  S_EL=$(tput el 2>/dev/null || printf '\033[K')
  S_CLEAR=$(tput clear 2>/dev/null || true)
  S_CIVIS=$(tput civis 2>/dev/null || true)
  S_CNORM=$(tput cnorm 2>/dev/null || true)
  S_ED=$(tput ed 2>/dev/null || true)
  local probe
  probe=$(tput cup 2 3 2>/dev/null || true)
  if [[ "$probe" == $'\033[3;4H' ]]; then
    ANSI_CUP=1
  else
    ANSI_CUP=0
  fi
}

cup() {
  if (( ANSI_CUP )); then
    printf '\033[%d;%dH' $(($1 + 1)) $(($2 + 1))
  else
    tput cup "$1" "$2"
  fi
}

el() {
  printf '%s' "$S_EL"
}

init_colors() {
  local n
  n=$(tput colors 2>/dev/null || echo 0)
  C_RESET=""
  C_DIM=""
  C_REV=""
  C_UL=""
  C_UL0=""
  C_ACC=""
  C_YEL=""
  C_GRN=""
  C_BOLD=$(tput bold 2>/dev/null || true)
  C_ITAL=$(tput sitm 2>/dev/null || true)
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 8 )); then
    C_RESET=$(tput sgr0 2>/dev/null || true)
    C_DIM=$(tput dim 2>/dev/null || true)
    C_REV=$(tput rev 2>/dev/null || true)
    C_UL=$(tput smul 2>/dev/null || true)
    C_UL0=$(tput rmul 2>/dev/null || true)
    C_ACC=$(tput setaf 6 2>/dev/null || true)
    C_YEL=$(tput setaf 3 2>/dev/null || true)
    C_GRN=$(tput setaf 2 2>/dev/null || true)
  fi
}

cleanup() {
  [[ $started -eq 1 ]] || return 0
  if (( dirty )); then
    save_day || true
  fi
  started=0
  printf '%s' "$C_RESET"
  stty "$STTY_ORIG" 2>/dev/null || true
  printf '%s' "$S_CNORM"
  tput rmcup 2>/dev/null || true
}

init_term() {
  STTY_ORIG=$(stty -g)
  cache_caps
  tput smcup 2>/dev/null || true
  printf '%s' "$S_CIVIS"
  stty -echo -icanon -ixon min 1 time 0
  init_colors
  started=1
  trap 'cleanup' EXIT
  trap 'WINCHED=1; cleanup; exit 130' INT TERM
  trap 'WINCHED=1' WINCH
}

ord_byte() {
  local h
  h=$(printf '%s' "$1" | od -An -tu1)
  h=${h//[[:space:]]/}
  printf '%s' "${h:-0}"
}

read_key() {
  local b more seq o need i
  WINCHED=0
  IFS= read -rsn1 b
  local rc=$?
  if (( WINCHED )); then
    return 2
  fi
  if (( rc != 0 )); then
    return 1
  fi
  if [[ -z "$b" ]]; then
    KEY=""
    return 0
  fi
  if [[ "$b" == $'\r' || "$b" == $'\n' ]]; then
    KEY=""
    return 0
  fi
  if [[ "$b" == $'\e' ]]; then
    stty -echo -icanon min 0 time 2
    IFS= read -rsn1 more
    if (( WINCHED )); then
      stty -echo -icanon min 1 time 0
      return 2
    fi
    if [[ -z "$more" ]]; then
      stty -echo -icanon min 1 time 0
      KEY=$'\e'
      return 0
    fi
    seq=$more
    if [[ "$more" == "[" ]]; then
      while true; do
        IFS= read -rsn1 more || more=""
        [[ -z "$more" ]] && break
        seq+="$more"
        o=$(ord_byte "$more")
        if (( o >= 64 && o <= 126 )); then
          break
        fi
        (( ${#seq} >= 16 )) && break
      done
    elif [[ "$more" == "O" ]]; then
      IFS= read -rsn1 more || more=""
      seq="O${more}"
    fi
    stty -echo -icanon min 1 time 0
    KEY=$'\e'"$seq"
    return 0
  fi
  if [[ "$b" == [!-~] || "$b" == " " ]]; then
    KEY=$b
    return 0
  fi
  o=$(ord_byte "$b")
  if (( o < 32 || o == 127 )); then
    KEY=$b
    return 0
  fi
  need=0
  if (( o >= 192 && o <= 223 )); then need=1
  elif (( o >= 224 && o <= 239 )); then need=2
  elif (( o >= 240 && o <= 247 )); then need=3
  fi
  seq=$b
  if (( need > 0 )); then
    stty -echo -icanon min 0 time 2
    for ((i=0; i<need; i++)); do
      IFS= read -rsn1 more || more=""
      [[ -z "$more" ]] && break
      seq+="$more"
    done
    stty -echo -icanon min 1 time 0
  fi
  KEY=$seq
  return 0
}

screen_size() {
  # tput cols reports 80x24 once the terminal is in raw mode.
  local sz
  sz=$(stty size 2>/dev/null || true)
  rows=${sz%% *}
  cols=${sz#* }
  [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
}

# --- calendar -----------------------------------------------------------

is_leap() {
  local y=$1
  (( (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) ))
}

days_in_month() {
  local y=$1 m=$2
  case $m in
    1|3|5|7|8|10|12) printf '31' ;;
    4|6|9|11) printf '30' ;;
    2) if is_leap "$y"; then printf '29'; else printf '28'; fi ;;
    *) printf '0' ;;
  esac
}

# 0 = Sunday. Sakamoto.
weekday_sun0() {
  local y=$1 m=$2 d=$3
  local -a t
  t=(0 3 2 5 0 3 5 1 4 6 2 4)
  if (( m < 3 )); then
    y=$((y - 1))
  fi
  printf '%s' $(( (y + y/4 - y/100 + y/400 + t[m-1] + d) % 7 ))
}

ymd_to_jdn() {
  local y=$1 m=$2 d=$3
  local a yy mm
  a=$(( (14 - m) / 12 ))
  yy=$(( y + 4800 - a ))
  mm=$(( m + 12 * a - 3 ))
  printf '%s' $(( d + (153 * mm + 2) / 5 + 365 * yy + yy/4 - yy/100 + yy/400 - 32045 ))
}

jdn_to_ymd() {
  local j=$1
  local a b c d e m
  a=$(( j + 32044 ))
  b=$(( (4 * a + 3) / 146097 ))
  c=$(( a - (146097 * b) / 4 ))
  d=$(( (4 * c + 3) / 1461 ))
  e=$(( c - (1461 * d) / 4 ))
  m=$(( (5 * e + 2) / 153 ))
  RD=$(( e - (153 * m + 2) / 5 + 1 ))
  RM=$(( m + 3 - 12 * (m / 10) ))
  RY=$(( 100 * b + d - 4800 + m / 10 ))
}

weekday_name() {
  local w
  w=$(weekday_sun0 "$1" "$2" "$3")
  printf '%s' "${WDAYS[$w]}"
}

day_path_for() {
  local y=$1 m=$2 d=$3 w
  w=$(weekday_name "$y" "$m" "$d")
  printf '%s/%s-%02d-%02d-%04d' "$DIR" "$w" "$d" "$m" "$y"
}

parse_date() {
  local s="$1" re dim
  re='^([0-9]{1,2})-([0-9]{1,2})-([0-9]{4})$'
  if [[ ! $s =~ $re ]]; then
    return 1
  fi
  PD=$((10#${BASH_REMATCH[1]}))
  PM=$((10#${BASH_REMATCH[2]}))
  PY=$((10#${BASH_REMATCH[3]}))
  if (( PM < 1 || PM > 12 || PY < 1 || PY > 9999 || PD < 1 )); then
    return 1
  fi
  dim=$(days_in_month "$PY" "$PM")
  if (( PD > dim )); then
    return 1
  fi
  return 0
}

parse_filename() {
  local base="$1" re
  re='^(monday|tuesday|wednesday|thursday|friday|saturday|sunday)-([0-9]{2})-([0-9]{2})-([0-9]{4})$'
  if [[ ! $base =~ $re ]]; then
    return 1
  fi
  FN_WD=${BASH_REMATCH[1]}
  FN_D=$((10#${BASH_REMATCH[2]}))
  FN_M=$((10#${BASH_REMATCH[3]}))
  FN_Y=$((10#${BASH_REMATCH[4]}))
  return 0
}

# --- model --------------------------------------------------------------

tasks_clear() {
  task_label=()
  task_indent=()
  task_mark=()
  task_text=()
  task_id=()
}

tasks_commit() {
  if (( ${#A_lab[@]} == 0 )); then
    tasks_clear
  else
    task_label=("${A_lab[@]}")
    task_indent=("${A_ind[@]}")
    task_mark=("${A_mark[@]}")
    task_text=("${A_text[@]}")
    task_id=("${A_id[@]}")
  fi
}

rebuild_vis() {
  vis=()
  local i n
  n=${#task_label[@]}
  for ((i=0; i<n; i++)); do
    if (( task_label[i] == cur_label )); then
      vis+=("$i")
    fi
  done
}

clamp_label() {
  local n=${#label_names[@]}
  if (( n < 1 )); then
    label_names=("day")
    n=1
  fi
  if (( cur_label < 0 )); then cur_label=0; fi
  if (( cur_label >= n )); then cur_label=$((n - 1)); fi
}

clamp_task() {
  clamp_label
  rebuild_vis
  local n=${#vis[@]}
  if (( n == 0 )); then
    cur_task=-1
  elif (( cur_task < 0 )); then
    cur_task=0
  elif (( cur_task >= n )); then
    cur_task=$((n - 1))
  fi
}

open_count() {
  local L=$1 i c=0
  for ((i=0; i<${#task_label[@]}; i++)); do
    if (( task_label[i] == L )) && [[ ${task_mark[$i]} == "-" ]]; then
      c=$((c + 1))
    fi
  done
  printf '%s' "$c"
}

block_end() {
  local i=$1 ind lab j n
  ind=${task_indent[$i]}
  lab=${task_label[$i]}
  j=$((i + 1))
  n=${#task_label[@]}
  while (( j < n )); do
    if (( task_label[j] != lab || task_indent[j] <= ind )); then
      break
    fi
    j=$((j + 1))
  done
  printf '%s' $((j - 1))
}

insert_point() {
  local L=$1 i n at
  n=${#task_label[@]}
  at=-1
  for ((i=0; i<n; i++)); do
    if (( task_label[i] == L )); then
      at=$i
    fi
  done
  if (( at >= 0 )); then
    printf '%s' $((at + 1))
    return
  fi
  for ((i=0; i<n; i++)); do
    if (( task_label[i] > L )); then
      printf '%s' "$i"
      return
    fi
  done
  printf '%s' "$n"
}

task_insert() {
  local at=$1 lab=$2 ind=$3 mark=$4 text=$5 id=$6
  local i n
  A_lab=()
  A_ind=()
  A_mark=()
  A_text=()
  A_id=()
  n=${#task_label[@]}
  if (( at > n )); then at=$n; fi
  if (( at < 0 )); then at=0; fi
  for ((i=0; i<n; i++)); do
    if (( i == at )); then
      A_lab+=("$lab")
      A_ind+=("$ind")
      A_mark+=("$mark")
      A_text+=("$text")
      A_id+=("$id")
    fi
    A_lab+=("${task_label[$i]}")
    A_ind+=("${task_indent[$i]}")
    A_mark+=("${task_mark[$i]}")
    A_text+=("${task_text[$i]}")
    A_id+=("${task_id[$i]}")
  done
  if (( at == n )); then
    A_lab+=("$lab")
    A_ind+=("$ind")
    A_mark+=("$mark")
    A_text+=("$text")
    A_id+=("$id")
  fi
  tasks_commit
}

task_delete_range() {
  local a=$1 b=$2 i n
  A_lab=()
  A_ind=()
  A_mark=()
  A_text=()
  A_id=()
  n=${#task_label[@]}
  for ((i=0; i<n; i++)); do
    if (( i >= a && i <= b )); then
      continue
    fi
    A_lab+=("${task_label[$i]}")
    A_ind+=("${task_indent[$i]}")
    A_mark+=("${task_mark[$i]}")
    A_text+=("${task_text[$i]}")
    A_id+=("${task_id[$i]}")
  done
  tasks_commit
}

# Replace [a,b] + [c,d] (c == b+1) with [c,d] then [a,b].
task_swap_adjacent() {
  local a=$1 b=$2 c=$3 d=$4 i n
  A_lab=()
  A_ind=()
  A_mark=()
  A_text=()
  A_id=()
  n=${#task_label[@]}
  for ((i=0; i<a; i++)); do
    A_lab+=("${task_label[$i]}")
    A_ind+=("${task_indent[$i]}")
    A_mark+=("${task_mark[$i]}")
    A_text+=("${task_text[$i]}")
    A_id+=("${task_id[$i]}")
  done
  for ((i=c; i<=d; i++)); do
    A_lab+=("${task_label[$i]}")
    A_ind+=("${task_indent[$i]}")
    A_mark+=("${task_mark[$i]}")
    A_text+=("${task_text[$i]}")
    A_id+=("${task_id[$i]}")
  done
  for ((i=a; i<=b; i++)); do
    A_lab+=("${task_label[$i]}")
    A_ind+=("${task_indent[$i]}")
    A_mark+=("${task_mark[$i]}")
    A_text+=("${task_text[$i]}")
    A_id+=("${task_id[$i]}")
  done
  for ((i=d+1; i<n; i++)); do
    A_lab+=("${task_label[$i]}")
    A_ind+=("${task_indent[$i]}")
    A_mark+=("${task_mark[$i]}")
    A_text+=("${task_text[$i]}")
    A_id+=("${task_id[$i]}")
  done
  tasks_commit
}

regroup() {
  local li i n nl
  A_lab=()
  A_ind=()
  A_mark=()
  A_text=()
  A_id=()
  n=${#task_label[@]}
  nl=${#label_names[@]}
  for ((li=0; li<nl; li++)); do
    for ((i=0; i<n; i++)); do
      if (( task_label[i] == li )); then
        A_lab+=("${task_label[$i]}")
        A_ind+=("${task_indent[$i]}")
        A_mark+=("${task_mark[$i]}")
        A_text+=("${task_text[$i]}")
        A_id+=("${task_id[$i]}")
      fi
    done
  done
  tasks_commit
}

find_vis_id() {
  local id=$1 i g
  rebuild_vis
  cur_task=-1
  for ((i=0; i<${#vis[@]}; i++)); do
    g=${vis[$i]}
    if (( task_id[g] == id )); then
      cur_task=$i
      return 0
    fi
  done
  clamp_task
}

alloc_id() {
  local id=$next_id
  next_id=$((next_id + 1))
  printf '%s' "$id"
}

load_day_file() {
  local path="$1"
  local -a lines
  local line rest tabs mark text i j n next current
  label_names=("day")
  tasks_clear
  next_id=1
  current=0
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    lines+=("$line")
  done < "$path"
  n=${#lines[@]}
  for ((i=0; i<n; i++)); do
    line=${lines[$i]}
    [[ -z "$line" ]] && continue
    rest=$line
    tabs=0
    while [[ $rest == $'\t'* ]]; do
      rest=${rest#$'\t'}
      tabs=$((tabs + 1))
    done
    [[ -z "$rest" ]] && continue
    mark=""
    text=""
    if [[ $rest == x\ * || $rest == x ]]; then
      mark=x
      text=${rest#x}
      text=${text# }
    elif [[ $rest == -\ * || $rest == - ]]; then
      mark=-
      text=${rest#-}
      text=${text# }
    elif (( tabs > 0 )); then
      mark=""
      text=$rest
    else
      j=$((i + 1))
      next=""
      while (( j < n )); do
        next=${lines[$j]}
        [[ -n "$next" ]] && break
        j=$((j + 1))
      done
      if [[ $next == $'\t'* ]]; then
        mark=""
        text=$rest
        tabs=0
      else
        label_names+=("$rest")
        current=$((${#label_names[@]} - 1))
        continue
      fi
    fi
    task_label+=("$current")
    task_indent+=("$tabs")
    task_mark+=("$mark")
    task_text+=("$text")
    task_id+=("$next_id")
    next_id=$((next_id + 1))
  done
}

write_day_to() {
  local path="$1"
  local tmp="${path}.tmp.$$"
  local li i k ind prefix line any=0 nlabels ntasks
  nlabels=${#label_names[@]}
  ntasks=${#task_label[@]}
  if (( ntasks == 0 && nlabels <= 1 )); then
    rm -f "$path" "$tmp"
    return 0
  fi
  : > "$tmp" || return 1
  for ((li=0; li<nlabels; li++)); do
    if (( li > 0 )); then
      if (( any )); then
        printf '\n' >> "$tmp" || return 1
      fi
      printf '%s\n' "${label_names[$li]}" >> "$tmp" || return 1
      any=1
    fi
    for ((i=0; i<ntasks; i++)); do
      if (( task_label[i] != li )); then
        continue
      fi
      prefix=""
      ind=${task_indent[$i]}
      for ((k=0; k<ind; k++)); do
        prefix+=$'\t'
      done
      if [[ -n ${task_mark[$i]} ]]; then
        line="${prefix}${task_mark[$i]} ${task_text[$i]}"
      else
        line="${prefix}${task_text[$i]}"
      fi
      printf '%s\n' "$line" >> "$tmp" || return 1
      any=1
    done
  done
  mv -f "$tmp" "$path" || return 1
  return 0
}

scan_files() {
  local f base rest line open
  FILE_MARKS=" "
  for f in "$DIR"/*; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    parse_filename "$base" || continue
    open=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      rest=$line
      while [[ $rest == $'\t'* ]]; do
        rest=${rest#$'\t'}
      done
      if [[ $rest == -\ * || $rest == - ]]; then
        open=1
        break
      fi
    done < "$f"
    if (( open )); then
      FILE_MARKS+=$(printf '%04d%02d%02d:o ' "$FN_Y" "$FN_M" "$FN_D")
    else
      FILE_MARKS+=$(printf '%04d%02d%02d:d ' "$FN_Y" "$FN_M" "$FN_D")
    fi
  done
}

day_mark() {
  local y=$1 m=$2 d=$3 i open=0 any=0 key
  if (( y == cur_y && m == cur_m && d == cur_d )); then
    for ((i=0; i<${#task_mark[@]}; i++)); do
      any=1
      if [[ ${task_mark[$i]} == "-" ]]; then
        open=1
      fi
    done
    if (( open )); then
      printf 'o'
      return
    fi
    if (( any || ${#label_names[@]} > 1 )); then
      printf 'd'
      return
    fi
    printf ''
    return
  fi
  printf -v key '%04d%02d%02d' "$y" "$m" "$d"
  case "$FILE_MARKS" in
    *" ${key}:o "*) printf 'o' ;;
    *" ${key}:d "*) printf 'd' ;;
    *) printf '' ;;
  esac
}

capture_state() {
  local i
  printf 'label_names=('
  for ((i=0; i<${#label_names[@]}; i++)); do
    printf '%q ' "${label_names[$i]}"
  done
  printf ')\n'
  printf 'task_label=('
  for ((i=0; i<${#task_label[@]}; i++)); do
    printf '%s ' "${task_label[$i]}"
  done
  printf ')\n'
  printf 'task_indent=('
  for ((i=0; i<${#task_indent[@]}; i++)); do
    printf '%s ' "${task_indent[$i]}"
  done
  printf ')\n'
  printf 'task_mark=('
  for ((i=0; i<${#task_mark[@]}; i++)); do
    printf '%q ' "${task_mark[$i]}"
  done
  printf ')\n'
  printf 'task_text=('
  for ((i=0; i<${#task_text[@]}; i++)); do
    printf '%q ' "${task_text[$i]}"
  done
  printf ')\n'
  printf 'task_id=('
  for ((i=0; i<${#task_id[@]}; i++)); do
    printf '%s ' "${task_id[$i]}"
  done
  printf ')\n'
  printf 'cur_label=%s\n' "$cur_label"
  printf 'cur_task=%s\n' "$cur_task"
  printf 'next_id=%s\n' "$next_id"
}

canonical() {
  local i
  for ((i=0; i<${#label_names[@]}; i++)); do
    printf 'L\037%s\n' "${label_names[$i]}"
  done
  for ((i=0; i<${#task_label[@]}; i++)); do
    printf 'T\037%s\037%s\037%s\037%s\n' \
      "${task_label[$i]}" "${task_indent[$i]}" "${task_mark[$i]}" "${task_text[$i]}"
  done
}

undo_reset() {
  undo_stack=("$(capture_state)")
  undo_pos=0
  saved_once=0
  dirty=0
}

push_undo() {
  local -a ns
  local i
  if (( undo_pos < ${#undo_stack[@]} - 1 )); then
    ns=()
    for ((i=0; i<=undo_pos; i++)); do
      ns+=("${undo_stack[$i]}")
    done
    undo_stack=("${ns[@]}")
  fi
  undo_stack+=("$(capture_state)")
  undo_pos=$((${#undo_stack[@]} - 1))
  while (( ${#undo_stack[@]} > 30 )); do
    ns=()
    for ((i=1; i<${#undo_stack[@]}; i++)); do
      ns+=("${undo_stack[$i]}")
    done
    undo_stack=("${ns[@]}")
    undo_pos=$((undo_pos - 1))
  done
  dirty=1
  save_day || status_msg="Save failed"
}

apply_undo_pos() {
  eval "${undo_stack[$undo_pos]}"
  dirty=1
  clamp_task
  save_day || status_msg="Save failed"
}

load_current() {
  load_day_file "$(day_path_for "$cur_y" "$cur_m" "$cur_d")"
  cur_label=0
  cur_task=0
  task_scroll=0
  label_scroll=0
  clamp_task
  undo_reset
}

save_day() {
  local path
  path=$(day_path_for "$cur_y" "$cur_m" "$cur_d")
  write_day_to "$path" || return 1
  dirty=0
  saved_once=1
  scan_files
  return 0
}

change_day() {
  local y=$1 m=$2 d=$3
  if (( y == cur_y && m == cur_m && d == cur_d )); then
    return 0
  fi
  if (( dirty )); then
    save_day || {
      status_msg="Save failed"
      return 1
    }
  fi
  cur_y=$y
  cur_m=$m
  cur_d=$d
  load_current
  return 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

valid_label_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  [[ "$n" != *$'\t'* ]] || return 1
  [[ "$n" != *$'\n'* ]] || return 1
  [[ "$n" != x && "$n" != x\ * && "$n" != - && "$n" != -\ * ]] || return 1
  return 0
}

label_index() {
  local name="$1" i
  for ((i=0; i<${#label_names[@]}; i++)); do
    if [[ ${label_names[$i]} == "$name" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

# --- edits --------------------------------------------------------------

cmd_toggle() {
  local g id
  (( cur_task < 0 )) && return 0
  g=${vis[$cur_task]}
  id=${task_id[$g]}
  case ${task_mark[$g]} in
    x) task_mark[$g]="-" ;;
    -) task_mark[$g]=x ;;
    *) task_mark[$g]="-" ;;
  esac
  find_vis_id "$id"
  push_undo
}

cmd_mark_all() {
  local i g changed=0 id
  (( cur_task < 0 )) && return 0
  id=${task_id[${vis[$cur_task]}]}
  for ((i=0; i<${#vis[@]}; i++)); do
    g=${vis[$i]}
    if [[ ${task_mark[$g]} != x ]]; then
      task_mark[$g]=x
      changed=1
    fi
  done
  if (( changed )); then
    find_vis_id "$id"
    push_undo
  else
    status_msg="Already done"
  fi
}

cmd_add() {
  local text ind at g end id
  edit_line "New task: " "" || return 0
  text=$(trim "$REPLY")
  [[ -z "$text" ]] && return 0
  ind=0
  if (( cur_task >= 0 )); then
    g=${vis[$cur_task]}
    ind=${task_indent[$g]}
    end=$(block_end "$g")
    at=$((end + 1))
  else
    at=$(insert_point "$cur_label")
  fi
  id=$(alloc_id)
  task_insert "$at" "$cur_label" "$ind" "-" "$text" "$id"
  find_vis_id "$id"
  push_undo
}

cmd_edit() {
  local g id text
  if (( cur_task < 0 )); then
    status_msg="No task to edit"
    return 0
  fi
  g=${vis[$cur_task]}
  id=${task_id[$g]}
  edit_line "Edit: " "${task_text[$g]}" || return 0
  text=$(trim "$REPLY")
  [[ -z "$text" ]] && return 0
  g=${vis[$cur_task]}
  task_text[$g]=$text
  find_vis_id "$id"
  push_undo
}

cmd_delete_task() {
  local g end id
  (( cur_task < 0 )) && return 0
  confirm_yn "Delete this task and its subtasks? [y/n] " || return 0
  g=${vis[$cur_task]}
  end=$(block_end "$g")
  task_delete_range "$g" "$end"
  clamp_task
  push_undo
}

cmd_indent() {
  local g ind end i id dir=$1
  (( cur_task < 0 )) && return 0
  g=${vis[$cur_task]}
  ind=${task_indent[$g]}
  id=${task_id[$g]}
  if (( dir > 0 )); then
    if (( g == 0 || task_label[g-1] != task_label[g] || task_indent[g-1] < ind )); then
      status_msg="Nothing above to nest under"
      return 0
    fi
    end=$(block_end "$g")
    for ((i=g; i<=end; i++)); do
      task_indent[$i]=$((task_indent[i] + 1))
    done
    if [[ -z ${task_mark[$g]} ]]; then
      task_mark[$g]="-"
    fi
  else
    if (( ind == 0 )); then
      status_msg="Already at the top level"
      return 0
    fi
    end=$(block_end "$g")
    for ((i=g; i<=end; i++)); do
      task_indent[$i]=$((task_indent[i] - 1))
    done
  fi
  find_vis_id "$id"
  push_undo
}

cmd_move_task() {
  local dir=$1 g ind lab end sib send id
  (( cur_task < 0 )) && return 0
  g=${vis[$cur_task]}
  ind=${task_indent[$g]}
  lab=${task_label[$g]}
  id=${task_id[$g]}
  end=$(block_end "$g")
  if (( dir > 0 )); then
    sib=$((end + 1))
    if (( sib >= ${#task_label[@]} || task_label[sib] != lab || task_indent[sib] != ind )); then
      return 0
    fi
    send=$(block_end "$sib")
    task_swap_adjacent "$g" "$end" "$sib" "$send"
  else
    local p=$((g - 1))
    while (( p >= 0 && task_label[p] == lab && task_indent[p] > ind )); do
      p=$((p - 1))
    done
    if (( p < 0 || task_label[p] != lab || task_indent[p] != ind )); then
      return 0
    fi
    task_swap_adjacent "$p" "$((g - 1))" "$g" "$end"
  fi
  find_vis_id "$id"
  push_undo
}

cmd_move_label_of_task() {
  local name li g end at i id
  local -a b_ind b_mark b_text b_id
  (( cur_task < 0 )) && return 0
  edit_line "Move to label: " "" || return 0
  name=$(trim "$REPLY")
  [[ -z "$name" ]] && return 0
  if ! valid_label_name "$name"; then
    status_msg="That name would not read back as a label"
    return 0
  fi
  if li=$(label_index "$name"); then
    :
  else
    label_names+=("$name")
    li=$((${#label_names[@]} - 1))
  fi
  if (( li == cur_label )); then
    status_msg="Already in ${name}"
    return 0
  fi
  g=${vis[$cur_task]}
  end=$(block_end "$g")
  id=${task_id[$g]}
  for ((i=g; i<=end; i++)); do
    b_ind+=("${task_indent[$i]}")
    b_mark+=("${task_mark[$i]}")
    b_text+=("${task_text[$i]}")
    b_id+=("${task_id[$i]}")
  done
  task_delete_range "$g" "$end"
  at=$(insert_point "$li")
  for ((i=0; i<${#b_ind[@]}; i++)); do
    task_insert "$((at + i))" "$li" "${b_ind[$i]}" "${b_mark[$i]}" "${b_text[$i]}" "${b_id[$i]}"
  done
  cur_label=$li
  find_vis_id "$id"
  push_undo
}

cmd_label_add() {
  local name
  edit_line "New label: " "" || return 0
  name=$(trim "$REPLY")
  [[ -z "$name" ]] && return 0
  if ! valid_label_name "$name"; then
    status_msg="That name would not read back as a label"
    return 0
  fi
  if label_index "$name" >/dev/null; then
    status_msg="Label already exists"
    return 0
  fi
  label_names+=("$name")
  cur_label=$((${#label_names[@]} - 1))
  cur_task=-1
  task_scroll=0
  clamp_task
  push_undo
}

cmd_label_rename() {
  local name
  if (( cur_label == 0 )); then
    status_msg="The day section keeps its name"
    return 0
  fi
  edit_line "Rename label: " "${label_names[$cur_label]}" || return 0
  name=$(trim "$REPLY")
  [[ -z "$name" ]] && return 0
  if ! valid_label_name "$name"; then
    status_msg="That name would not read back as a label"
    return 0
  fi
  if [[ $name == "${label_names[$cur_label]}" ]]; then
    return 0
  fi
  if label_index "$name" >/dev/null; then
    status_msg="Label already exists"
    return 0
  fi
  label_names[$cur_label]=$name
  push_undo
}

cmd_label_delete() {
  local L=$cur_label i
  local -a nn
  if (( L == 0 )); then
    status_msg="The day section stays"
    return 0
  fi
  confirm_yn "Delete this label and move its tasks into day? [y/n] " || return 0
  for ((i=0; i<${#task_label[@]}; i++)); do
    if (( task_label[i] == L )); then
      task_label[$i]=0
    fi
  done
  for ((i=0; i<${#label_names[@]}; i++)); do
    if (( i == L )); then
      continue
    fi
    nn+=("${label_names[$i]}")
  done
  label_names=("${nn[@]}")
  for ((i=0; i<${#task_label[@]}; i++)); do
    if (( task_label[i] > L )); then
      task_label[$i]=$((task_label[i] - 1))
    fi
  done
  regroup
  cur_label=0
  cur_task=0
  clamp_task
  push_undo
}

cmd_label_reorder() {
  local dir=$1 a b tmp i
  a=$cur_label
  b=$((cur_label + dir))
  if (( a < 1 || b < 1 || b >= ${#label_names[@]} )); then
    return 0
  fi
  tmp=${label_names[$a]}
  label_names[$a]=${label_names[$b]}
  label_names[$b]=$tmp
  for ((i=0; i<${#task_label[@]}; i++)); do
    if (( task_label[i] == a )); then
      task_label[$i]=$b
    elif (( task_label[i] == b )); then
      task_label[$i]=$a
    fi
  done
  regroup
  cur_label=$b
  clamp_task
  push_undo
}

cmd_undo() {
  if (( undo_pos <= 0 )); then
    status_msg="Nothing to undo"
    return 0
  fi
  undo_pos=$((undo_pos - 1))
  apply_undo_pos
}

cmd_redo() {
  if (( undo_pos >= ${#undo_stack[@]} - 1 )); then
    status_msg="Nothing to redo"
    return 0
  fi
  undo_pos=$((undo_pos + 1))
  apply_undo_pos
}

cmd_carry() {
  local -a ci ct
  local i g def spec added k li sy sm sd slab at name
  rebuild_vis
  for ((i=0; i<${#vis[@]}; i++)); do
    g=${vis[$i]}
    if [[ ${task_mark[$g]} == "-" ]]; then
      ci+=("${task_indent[$g]}")
      ct+=("${task_text[$g]}")
    fi
  done
  if (( ${#ct[@]} == 0 )); then
    status_msg="No open tasks in this label"
    return 0
  fi
  local j
  j=$(ymd_to_jdn "$cur_y" "$cur_m" "$cur_d")
  jdn_to_ymd $((j + 1))
  printf -v def '%02d-%02d-%04d' "$RD" "$RM" "$RY"
  edit_line "Carry to [$def]: " "" || return 0
  spec=$(trim "$REPLY")
  [[ -z "$spec" ]] && spec=$def
  if ! parse_date "$spec"; then
    status_msg="Use DD-MM-YYYY"
    return 0
  fi
  sy=$cur_y
  sm=$cur_m
  sd=$cur_d
  slab=${label_names[$cur_label]}
  if (( dirty )); then
    save_day || {
      status_msg="Save failed"
      return 0
    }
  fi
  cur_y=$PY
  cur_m=$PM
  cur_d=$PD
  load_day_file "$(day_path_for "$cur_y" "$cur_m" "$cur_d")"
  if li=$(label_index "$slab"); then
    :
  else
    label_names+=("$slab")
    li=$((${#label_names[@]} - 1))
  fi
  added=0
  local found t
  for ((k=0; k<${#ct[@]}; k++)); do
    found=0
    for ((t=0; t<${#task_label[@]}; t++)); do
      if (( task_label[t] == li && task_indent[t] == ci[k] )) && [[ ${task_text[$t]} == "${ct[$k]}" ]]; then
        found=1
        break
      fi
    done
    if (( found )); then
      continue
    fi
    at=$(insert_point "$li")
    task_insert "$at" "$li" "${ci[$k]}" "-" "${ct[$k]}" "$(alloc_id)"
    added=$((added + 1))
  done
  if (( added > 0 )); then
    if ! write_day_to "$(day_path_for "$cur_y" "$cur_m" "$cur_d")"; then
      cur_y=$sy
      cur_m=$sm
      cur_d=$sd
      load_current
      status_msg="Save failed"
      return 0
    fi
  fi
  cur_y=$sy
  cur_m=$sm
  cur_d=$sd
  scan_files
  load_current
  # restore the label we carried from
  if li=$(label_index "$slab"); then
    cur_label=$li
    clamp_task
  fi
  undo_reset
  if (( added > 0 )); then
    status_msg="Carried ${added} to ${spec}"
  else
    status_msg="Nothing new to carry"
  fi
}

cmd_search() {
  local saved q f base i hay fy fm fd
  edit_line "Search: " "" || return 0
  q=$(trim "$REPLY")
  [[ -z "$q" ]] && return 0
  query=$q
  q=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
  saved=$(capture_state)
  hit_y=()
  hit_m=()
  hit_d=()
  hit_lab=()
  hit_ind=()
  hit_text=()
  for f in "$DIR"/*; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    parse_filename "$base" || continue
    fy=$FN_Y
    fm=$FN_M
    fd=$FN_D
    load_day_file "$f"
    for ((i=0; i<${#task_text[@]}; i++)); do
      hay=$(printf '%s' "${task_text[$i]}" | tr '[:upper:]' '[:lower:]')
      if [[ $hay == *"$q"* ]]; then
        hit_y+=("$fy")
        hit_m+=("$fm")
        hit_d+=("$fd")
        hit_lab+=("${label_names[${task_label[$i]}]}")
        hit_ind+=("${task_indent[$i]}")
        hit_text+=("${task_text[$i]}")
        if (( ${#hit_text[@]} >= 300 )); then
          break
        fi
      fi
    done
    if (( ${#hit_text[@]} >= 300 )); then
      break
    fi
  done
  eval "$saved"
  clamp_task
  if (( ${#hit_text[@]} == 0 )); then
    status_msg="No matches"
    return 0
  fi
  mode=search
  cur_hit=0
  hit_scroll=0
}

cmd_open_hit() {
  local i y m d lab ind text li g vi
  (( ${#hit_text[@]} == 0 )) && return 0
  i=$cur_hit
  y=${hit_y[$i]}
  m=${hit_m[$i]}
  d=${hit_d[$i]}
  lab=${hit_lab[$i]}
  ind=${hit_ind[$i]}
  text=${hit_text[$i]}
  mode=normal
  change_day "$y" "$m" "$d" || return 0
  if li=$(label_index "$lab"); then
    cur_label=$li
  else
    cur_label=0
  fi
  rebuild_vis
  cur_task=0
  for ((vi=0; vi<${#vis[@]}; vi++)); do
    g=${vis[$vi]}
    if (( task_indent[g] == ind )) && [[ ${task_text[$g]} == "$text" ]]; then
      cur_task=$vi
      break
    fi
  done
  clamp_task
  focus=tasks
}

cmd_goto() {
  local spec
  edit_line "Go to DD-MM-YYYY: " "" || return 0
  spec=$(trim "$REPLY")
  [[ -z "$spec" ]] && return 0
  if ! parse_date "$spec"; then
    status_msg="Use DD-MM-YYYY"
    return 0
  fi
  change_day "$PY" "$PM" "$PD"
}

cmd_today() {
  change_day "$ty" "$tm" "$td"
}

cmd_save() {
  if (( dirty == 0 )); then
    status_msg="Saved"
    return 0
  fi
  if save_day; then
    status_msg="Saved"
  else
    status_msg="Save failed"
  fi
}

cmd_quit() {
  if (( dirty )); then
    if ! save_day; then
      status_msg="Save failed"
      return 0
    fi
  fi
  exit 0
}

shift_month() {
  local dir=$1 y m d dim
  y=$cur_y
  m=$((cur_m + dir))
  d=$cur_d
  if (( m < 1 )); then
    m=12
    y=$((y - 1))
  elif (( m > 12 )); then
    m=1
    y=$((y + 1))
  fi
  if (( y < 1 )); then y=1; fi
  if (( y > 9999 )); then y=9999; fi
  dim=$(days_in_month "$y" "$m")
  if (( d > dim )); then d=$dim; fi
  change_day "$y" "$m" "$d"
}

shift_year() {
  local y d dim
  y=$((cur_y + $1))
  if (( y < 1 )); then y=1; fi
  if (( y > 9999 )); then y=9999; fi
  d=$cur_d
  dim=$(days_in_month "$y" "$cur_m")
  if (( d > dim )); then d=$dim; fi
  change_day "$y" "$cur_m" "$d"
}

shift_days() {
  local j
  j=$(ymd_to_jdn "$cur_y" "$cur_m" "$cur_d")
  jdn_to_ymd $((j + $1))
  change_day "$RY" "$RM" "$RD"
}

set_focus() {
  focus=$1
  if [[ $focus != tasks ]]; then
    left_focus=$focus
  fi
}

move_task_cursor() {
  local n=${#vis[@]}
  (( n == 0 )) && return 0
  cur_task=$((cur_task + $1))
  if (( cur_task < 0 )); then cur_task=0; fi
  if (( cur_task >= n )); then cur_task=$((n - 1)); fi
}

# --- drawing ------------------------------------------------------------

pad_width() {
  local s="$1" w=$2
  if (( ${#s} > w )); then
    if (( w > 1 )); then
      s="${s:0:w-1}>"
    else
      s=${s:0:w}
    fi
  fi
  while (( ${#s} < w )); do
    s+=" "
  done
  PAD=$s
}

paint() {
  local row=$1 col=$2 text=$3 attr=$4
  cup "$row" "$col"
  case $attr in
    rev) printf '%s%s%s' "$C_REV" "$text" "$C_RESET" ;;
    dim) printf '%s%s%s' "$C_DIM" "$text" "$C_RESET" ;;
    acc) printf '%s%s%s' "$C_ACC" "$text" "$C_RESET" ;;
    yel) printf '%s%s%s' "$C_YEL" "$text" "$C_RESET" ;;
    bold) printf '%s%s%s' "$C_BOLD" "$text" "$C_RESET" ;;
    *) printf '%s' "$text" ;;
  esac
}

blank_at() {
  local row=$1 col=$2 w=$3
  cup "$row" "$col"
  pad_width "" "$w"
  printf '%s' "$PAD"
}

# Calendar stays narrow. The rest of a centered block goes to the tasks.
layout_frame() {
  local room=190
  local want=$((LWC + 1 + room))
  local cw=$cols
  if (( cw > want )); then
    cw=$want
  fi
  OX=$(( (cols - cw) / 2 ))
  BAR=$((OX + LWC))
  RC=$((BAR + 1))
  RW=$((cw - LWC - 1))
  (( RW < 1 )) && RW=1
}

build_wrap() {
  local ind=$1 mk=$2 text=$3
  local k prefix="" lead hang n room chunk cut i rest first
  WRAP=()
  prefix=""
  for ((k=0; k<ind * 2; k++)); do
    prefix+=" "
  done
  [[ -z $mk ]] && mk=" "
  lead="${prefix}${mk}  "
  hang=""
  n=${#lead}
  for ((k=0; k<n; k++)); do
    hang+=" "
  done
  rest=$text
  first=1
  while true; do
    if (( first )); then
      room=$((RW - ${#lead}))
    else
      room=$((RW - ${#hang}))
    fi
    (( room < 1 )) && room=1
    if [[ -z $rest ]]; then
      if (( first )); then
        WRAP+=("$lead")
      fi
      break
    fi
    if (( ${#rest} <= room )); then
      if (( first )); then
        WRAP+=("${lead}${rest}")
      else
        WRAP+=("${hang}${rest}")
      fi
      break
    fi
    chunk=${rest:0:room}
    cut=$room
    for ((i=room - 1; i >= room / 3; i--)); do
      if [[ ${chunk:i:1} == " " ]]; then
        cut=$i
        break
      fi
    done
    (( cut < 1 )) && cut=1
    if (( first )); then
      WRAP+=("${lead}${rest:0:cut}")
    else
      WRAP+=("${hang}${rest:0:cut}")
    fi
    rest=${rest:cut}
    rest=${rest#" "}
    first=0
  done
}

measure_tasks() {
  local i g mk
  TASK_LINES=0
  rebuild_vis
  if [[ $mode == search ]]; then
    TASK_LINES=${#hit_text[@]}
    (( TASK_LINES < 1 )) && TASK_LINES=1
    return
  fi
  for ((i=0; i<${#vis[@]}; i++)); do
    g=${vis[$i]}
    mk=${task_mark[$g]}
    build_wrap "${task_indent[$g]}" "$mk" "${task_text[$g]}"
    TASK_LINES=$((TASK_LINES + ${#WRAP[@]}))
  done
  (( TASK_LINES < 1 )) && TASK_LINES=1
}

place_block() {
  local nlabels=${#label_names[@]}
  local left_block=$((10 + nlabels))
  local task_block=$((2 + TASK_LINES))
  local need=$left_block
  (( task_block > need )) && need=$task_block
  if (( need < rows - 1 )); then
    OY=$(( (rows - 1 - need) / 2 ))
  else
    OY=0
  fi
  (( OY < 0 )) && OY=0
  STATUS_ROW=$((OY + need))
  if (( STATUS_ROW > rows - 1 || STATUS_ROW < 1 )); then
    STATUS_ROW=$((rows - 1))
  fi
}

draw_left() {
  local line mid name col r i li oc nm space k nw attr
  local first dim pos dow row num mk mark sel today
  local goff=$(( (LWC - 21) / 2 ))
  (( goff < 0 )) && goff=0
  mid=" ${cur_y} "
  local total=$((1 + ${#mid} + 1))
  local left=$(( (LWC - total) / 2 ))
  (( left < 0 )) && left=0
  cup "$OY" $((OX + left))
  printf '<'
  if [[ $focus == year ]]; then
    printf '%s%s%s' "$C_REV" "$mid" "$C_RESET"
  else
    printf '%s%s%s' "$C_BOLD" "$mid" "$C_RESET"
  fi
  printf '>'

  name=${MONTHS[$cur_m]}
  mid=" ${name} "
  total=$((1 + ${#mid} + 1))
  left=$(( (LWC - total) / 2 ))
  (( left < 0 )) && left=0
  cup $((OY + 1)) $((OX + left))
  printf '<'
  if [[ $focus == month ]]; then
    printf '%s%s%s' "$C_REV" "$mid" "$C_RESET"
  else
    printf '%s%s%s' "$C_BOLD" "$mid" "$C_RESET"
  fi
  printf '>'

  local hdr="Mo Tu We Th Fr Sa Su"
  local hoff=$(( (LWC - ${#hdr}) / 2 ))
  (( hoff < 0 )) && hoff=0
  cup $((OY + 2)) $((OX + hoff))
  if [[ $focus == grid ]]; then
    printf '%s%s%s%s' "$C_BOLD" "$C_ACC" "$hdr" "$C_RESET"
  else
    printf '%s' "$hdr"
  fi

  line=""
  for ((k=0; k<LWC; k++)); do
    line+="─"
  done
  cup $((OY + 3)) "$OX"
  printf '%s%s%s' "$C_DIM" "$line" "$C_RESET"

  first=$(weekday_sun0 "$cur_y" "$cur_m" 1)
  first=$(( (first + 6) % 7 ))
  dim=$(days_in_month "$cur_y" "$cur_m")
  for ((i=1; i<=dim; i++)); do
    pos=$((first + i - 1))
    dow=$((pos % 7))
    row=$((OY + 4 + pos / 7))
    col=$((OX + goff + dow * 3))
    printf -v num '%2d' "$i"
    mark=$(day_mark "$cur_y" "$cur_m" "$i")
    mk=" "
    [[ $mark == o ]] && mk="*"
    [[ $mark == d ]] && mk="."
    sel=0
    today=0
    (( i == cur_d )) && sel=1
    (( cur_y == ty && cur_m == tm && i == td )) && today=1
    cup "$row" "$col"
    if (( sel && today )); then
      printf '%s%s%s%s' "$C_REV" "$C_UL" "$num" "$C_RESET"
    elif (( sel )); then
      printf '%s%s%s' "$C_REV" "$num" "$C_RESET"
    elif (( today )); then
      printf '%s%s%s' "$C_UL" "$num" "$C_UL0"
    else
      printf '%s' "$num"
    fi
    cup "$row" $((col + 2))
    if [[ $mk == "*" ]]; then
      printf '%s%s%s' "$C_YEL" "*" "$C_RESET"
    elif [[ $mk == "." ]]; then
      printf '%s%s%s' "$C_GRN" "." "$C_RESET"
    else
      printf ' '
    fi
  done

  local lab_top=$((OY + 10))
  local lab_h=$((rows - 1 - lab_top))
  (( lab_h < 1 )) && lab_h=1
  local nlabels=${#label_names[@]}
  if (( cur_label < label_scroll )); then
    label_scroll=$cur_label
  fi
  if (( cur_label >= label_scroll + lab_h )); then
    label_scroll=$((cur_label - lab_h + 1))
  fi
  for ((i=0; i<lab_h; i++)); do
    li=$((label_scroll + i))
    cup $((lab_top + i)) "$OX"
    if (( li >= nlabels )); then
      pad_width "" "$LWC"
      printf '%s' "$PAD"
      continue
    fi
    oc=$(open_count "$li")
    nm=${label_names[$li]}
    local rightc="${oc} open"
    space=$((LWC - ${#nm} - ${#rightc}))
    if (( space < 1 )); then
      nw=$((LWC - ${#rightc} - 1))
      (( nw < 1 )) && nw=1
      nm=${nm:0:nw}
      space=$((LWC - ${#nm} - ${#rightc}))
      (( space < 1 )) && space=1
    fi
    line=$nm
    for ((k=0; k<space; k++)); do
      line+=" "
    done
    line+="$rightc"
    pad_width "$line" "$LWC"
    if (( li == cur_label && focus == labels )); then
      printf '%s%s%s' "$C_REV" "$PAD" "$C_RESET"
    else
      if (( li == cur_label )); then
        printf '%s%s%s' "$C_ACC" "$nm" "$C_RESET"
      else
        printf '%s' "$nm"
      fi
      printf '%*s' "$space" ""
      if (( oc > 0 )); then
        printf '%s%s%s' "$C_YEL" "$rightc" "$C_RESET"
      else
        printf '%s%s%s' "$C_DIM" "$rightc" "$C_RESET"
      fi
    fi
  done
}

draw_bar() {
  local r bottom=$((STATUS_ROW - 1))
  (( bottom < OY )) && bottom=$OY
  for ((r=OY; r<=bottom; r++)); do
    cup "$r" "$BAR"
    printf '%s│%s' "$C_DIM" "$C_RESET"
  done
}

pretty_date() {
  local w
  w=$(weekday_sun0 "$cur_y" "$cur_m" "$cur_d")
  printf '%s %d %s %d' "${WCAPS[$w]}" "$cur_d" "${MONTHS[$cur_m]}" "$cur_y"
}

paint_wrapped() {
  local sel=$1 mk=$2 ind=$3 first=$4 line=$5
  local pad="$line" prelen markch tail
  while (( ${#pad} < RW )); do
    pad+=" "
  done
  if (( ${#pad} > RW )); then
    pad=${pad:0:RW}
  fi
  if (( sel )); then
    printf '%s%s%s' "$C_REV" "$pad" "$C_RESET"
    return
  fi
  if (( first )); then
    prelen=$((ind * 2))
    if (( prelen >= ${#pad} )); then
      printf '%s' "$pad"
      return
    fi
    printf '%s' "${pad:0:prelen}"
    markch=${pad:prelen:1}
    tail=${pad:prelen+1}
    case $markch in
      x) printf '%s%s%s' "$C_GRN" "$markch" "$C_RESET" ;;
      -) printf '%s%s%s' "$C_YEL" "$markch" "$C_RESET" ;;
      *) printf '%s' "$markch" ;;
    esac
    if [[ $mk == x ]]; then
      printf '%s%s%s' "$C_DIM" "$tail" "$C_RESET"
    else
      printf '%s' "$tail"
    fi
    return
  fi
  if [[ $mk == x ]]; then
    printf '%s%s%s' "$C_DIM" "$pad" "$C_RESET"
  else
    printf '%s' "$pad"
  fi
}

draw_tasks() {
  local title oc i vi g ind mk h w t off seen
  local -a v_off v_h
  title=$(pretty_date)
  cup "$OY" "$RC"
  printf '%s%s%s' "$C_BOLD" "$title" "$C_RESET"
  if (( dirty )); then
    printf ' %s%s*%s' "$C_BOLD" "$C_YEL" "$C_RESET"
  fi
  oc=$(open_count "$cur_label")
  local lname="${label_names[$cur_label]}"
  local count="  ${oc} open"
  cup $((OY + 1)) "$RC"
  if [[ -n $C_ITAL ]]; then
    printf '%s%s%s%s%s' "$C_BOLD" "$C_ITAL" "$C_ACC" "$lname" "$C_RESET"
  else
    printf '%s%s%s%s' "$C_BOLD" "$C_ACC" "$lname" "$C_RESET"
  fi
  if (( oc > 0 )); then
    printf '%s%s%s' "$C_YEL" "$count" "$C_RESET"
  else
    printf '%s%s%s' "$C_DIM" "$count" "$C_RESET"
  fi
  h=$((rows - 1 - OY - 2))
  (( h < 1 )) && h=1
  off=0
  for ((vi=0; vi<${#vis[@]}; vi++)); do
    g=${vis[$vi]}
    mk=${task_mark[$g]}
    build_wrap "${task_indent[$g]}" "$mk" "${task_text[$g]}"
    v_off[$vi]=$off
    v_h[$vi]=${#WRAP[@]}
    off=$((off + ${#WRAP[@]}))
  done
  if (( cur_task < 0 )); then
    task_scroll=0
  else
    local start=${v_off[$cur_task]}
    local th=${v_h[$cur_task]}
    if (( start < task_scroll )); then
      task_scroll=$start
    fi
    if (( start + th > task_scroll + h )); then
      task_scroll=$((start + th - h))
    fi
    (( task_scroll < 0 )) && task_scroll=0
  fi
  seen=0
  w=0
  for ((vi=0; vi<${#vis[@]}; vi++)); do
    g=${vis[$vi]}
    ind=${task_indent[$g]}
    mk=${task_mark[$g]}
    [[ -z $mk ]] && mk=" "
    build_wrap "$ind" "$mk" "${task_text[$g]}"
    for ((t=0; t<${#WRAP[@]}; t++)); do
      if (( seen >= task_scroll && w < h )); then
        local sel=0 first=0
        [[ $focus == tasks && $vi == "$cur_task" ]] && sel=1
        [[ $t == 0 ]] && first=1
        cup $((OY + 2 + w)) "$RC"
        paint_wrapped "$sel" "$mk" "$ind" "$first" "${WRAP[$t]}"
        w=$((w + 1))
      fi
      seen=$((seen + 1))
    done
  done
  if (( ${#vis[@]} == 0 )); then
    cup $((OY + 2)) "$RC"
    pad_width "  (no tasks — a to add)" "$RW"
    if [[ $focus == tasks ]]; then
      printf '%s%s%s' "$C_REV" "$PAD" "$C_RESET"
    else
      printf '%s%s%s' "$C_DIM" "$PAD" "$C_RESET"
    fi
  fi
}

draw_search() {
  local h i vi line title
  title="Search: ${query}  $((cur_hit + 1))/${#hit_text[@]}"
  pad_width "$title" "$RW"
  cup "$OY" "$RC"
  printf '%s%s%s%s' "$C_BOLD" "$C_ACC" "$PAD" "$C_RESET"
  pad_width "enter open   esc back" "$RW"
  cup $((OY + 1)) "$RC"
  printf '%s%s%s' "$C_DIM" "$PAD" "$C_RESET"
  h=$((rows - 1 - OY - 2))
  (( h < 1 )) && h=1
  if (( cur_hit < hit_scroll )); then
    hit_scroll=$cur_hit
  fi
  if (( cur_hit >= hit_scroll + h )); then
    hit_scroll=$((cur_hit - h + 1))
  fi
  for ((i=0; i<h; i++)); do
    vi=$((hit_scroll + i))
    cup $((OY + 2 + i)) "$RC"
    if (( vi >= ${#hit_text[@]} )); then
      continue
    fi
    printf -v line '%02d-%02d-%04d  %s  %s' \
      "${hit_d[$vi]}" "${hit_m[$vi]}" "${hit_y[$vi]}" \
      "${hit_lab[$vi]}" "${hit_text[$vi]}"
    pad_width "$line" "$RW"
    if (( vi == cur_hit )); then
      printf '%s%s%s' "$C_REV" "$PAD" "$C_RESET"
    else
      printf '%s' "$PAD"
    fi
  done
}

emphasize() {
  local pre="$1" key="$2" post="$3" all
  all="${pre}${key}${post}"
  if (( ${#all} > cols )); then
    all=${all:0:cols}
  fi
  if (( ${#all} <= ${#pre} )); then
    printf '%s%s%s' "$C_DIM" "$all" "$C_RESET"
    return
  fi
  printf '%s%s%s' "$C_DIM" "${all:0:${#pre}}" "$C_RESET"
  if (( ${#pre} + ${#key} >= ${#all} )); then
    printf '%s%s%s' "$C_BOLD" "${all:${#pre}}" "$C_RESET"
    return
  fi
  printf '%s%s%s' "$C_BOLD" "${all:${#pre}:${#key}}" "$C_RESET"
  printf '%s%s%s' "$C_DIM" "${all:${#pre}+${#key}}" "$C_RESET"
}

draw_status() {
  local hint key=""
  local pre="" post=""
  if [[ -n $status_msg ]]; then
    hint=$status_msg
  elif [[ $mode == help ]]; then
    key="esc"
    post=" closes help"
  elif [[ $mode == search ]]; then
    key="j/k"
    post=" move   enter open   n/N next   esc back   q quit"
  else
    case $focus in
      year|month)
        key="left/right"
        post=" change   down days   t today   g date   / find   ? help   q quit"
        ;;
      grid)
        key="left/right"
        post=" day   a add   e edit   down labels   t today   ? help"
        ;;
      labels)
        pre="j/k select   "
        key="l"
        post=" new   r rename   d delete   J/K order   tab tasks"
        ;;
      tasks)
        key="a"
        post=" add  e edit  x toggle  > in  < out  d del  J/K move  c carry  u undo"
        ;;
      *)
        key="?"
        post=" help   q quit"
        ;;
    esac
  fi
  cup "$STATUS_ROW" 0
  el
  cup "$STATUS_ROW" "$OX"
  if [[ -n $status_msg ]]; then
    if (( ${#hint} > cols )); then
      hint=${hint:0:cols}
    fi
    printf '%s%s%s' "$C_YEL" "$hint" "$C_RESET"
  else
    emphasize "$pre" "$key" "$post"
  fi
}

draw_help() {
  local -a H
  local i r
  H=(
    " Agenda"
    ""
    " Left column"
    "   left/right   change the year or the month"
    "   up/down      year, month, days, then labels"
    "   on days      left/right move one day, across months"
    "                J/K jump a week. Down opens the labels"
    "   t            today          g   go to DD-MM-YYYY"
    "   tab          switch between the calendar and the tasks"
    ""
    " Labels"
    "   l new    r rename    d delete (tasks move into day)"
    "   J/K      reorder"
    ""
    " Tasks"
    "   a add    e edit    x toggle done    X mark the label done"
    "   > indent < outdent    d delete the task and its subtasks"
    "   J/K move    m move to a label    c carry open tasks"
    "   u undo   ctrl-r redo    s save    / search    q quit"
    ""
    " A leading tab in the file is a subtask. x done, - open."
    " esc closes this list"
  )
  r=1
  for ((i=0; i<${#H[@]}; i++)); do
    cup $((r + i)) 0
    pad_width "${H[$i]}" "$cols"
    printf '%s%s%s' "$C_REV" "$PAD" "$C_RESET"
  done
  for ((i=${#H[@]}; r + i < rows - 1; i++)); do
    cup $((r + i)) 0
    pad_width "" "$cols"
    printf '%s' "$PAD"
  done
}

draw() {
  local r
  screen_size
  if (( rows < 24 || cols < 80 )); then
    small=1
    cup 0 0
    printf '%s' "$S_ED"
    printf 'Agenda needs at least 80 columns by 24 rows.'
    return
  fi
  if (( small == 1 )); then
    small=0
  fi
  layout_frame
  measure_tasks
  place_block
  for ((r=0; r<rows; r++)); do
    cup "$r" 0
    el
  done
  draw_left
  draw_bar
  if [[ $mode == search ]]; then
    draw_search
  else
    draw_tasks
  fi
  if [[ $mode == help ]]; then
    draw_help
  fi
  draw_status
}

# --- line editor and confirm --------------------------------------------

edit_line() {
  local prompt="$1"
  local s="$2"
  local -a chars
  local cur ch k
  local -a nc
  chars=()
  while [[ -n "$s" ]]; do
    chars+=("${s:0:1}")
    s=${s:1}
  done
  cur=${#chars[@]}
  printf '%s' "$S_CNORM"
  while true; do
    screen_size
    local out="" i
    for ((i=0; i<${#chars[@]}; i++)); do
      out+="${chars[$i]}"
    done
    local plen=${#prompt}
    local avail=$((cols - plen - 1))
    (( avail < 1 )) && avail=1
    local view=$out
    local cpos=$cur
    if (( ${#view} > avail )); then
      local start=0
      if (( cpos >= avail )); then
        start=$((cpos - avail + 1))
      fi
      view=${view:start:avail}
      cpos=$((cpos - start))
    fi
    cup $((rows - 1)) 0
    el
    printf '%s%s' "$prompt" "$view"
    local pos=$((plen + cpos))
    if (( pos >= cols )); then pos=$((cols - 1)); fi
    cup $((rows - 1)) "$pos"
    read_key
    local rc=$?
    if (( rc == 2 )); then
      draw
      continue
    fi
    if (( rc != 0 )); then
      printf '%s' "$S_CIVIS"
      REPLY=""
      KEY=$'\a'
      return 1
    fi
    case "$KEY" in
      $'\e')
        printf '%s' "$S_CIVIS"
        REPLY=""
        KEY=$'\a'
        return 1
        ;;
      ""|$'\r'|$'\n')
        printf '%s' "$S_CIVIS"
        REPLY=$out
        KEY=$'\a'
        return 0
        ;;
      $'\x7f'|$'\b')
        if (( cur > 0 )); then
          nc=()
          for ((k=0; k<cur-1; k++)); do nc+=("${chars[$k]}"); done
          for ((k=cur; k<${#chars[@]}; k++)); do nc+=("${chars[$k]}"); done
          chars=("${nc[@]}")
          cur=$((cur - 1))
        fi
        ;;
      $'\x15')
        chars=()
        cur=0
        ;;
      $'\x01'|$'\e[H'|$'\e[1~'|$'\e[7~'|$'\eOH')
        cur=0
        ;;
      $'\x05'|$'\e[F'|$'\e[4~'|$'\e[8~'|$'\eOF')
        cur=${#chars[@]}
        ;;
      $'\e[D'|$'\eOD')
        if (( cur > 0 )); then cur=$((cur - 1)); fi
        ;;
      $'\e[C'|$'\eOC')
        if (( cur < ${#chars[@]} )); then cur=$((cur + 1)); fi
        ;;
      $'\e[3~')
        if (( cur < ${#chars[@]} )); then
          nc=()
          for ((k=0; k<cur; k++)); do nc+=("${chars[$k]}"); done
          for ((k=cur+1; k<${#chars[@]}; k++)); do nc+=("${chars[$k]}"); done
          chars=("${nc[@]}")
        fi
        ;;
      $'\e'*)
        ;;
      *)
        if [[ ${#KEY} -eq 0 ]]; then
          continue
        fi
        if [[ "$KEY" == [[:cntrl:]] ]]; then
          continue
        fi
        nc=()
        for ((k=0; k<cur; k++)); do nc+=("${chars[$k]}"); done
        nc+=("$KEY")
        for ((k=cur; k<${#chars[@]}; k++)); do nc+=("${chars[$k]}"); done
        chars=("${nc[@]}")
        cur=$((cur + 1))
        ;;
    esac
  done
}

confirm_yn() {
  local prompt="$1"
  while true; do
    screen_size
    cup $((rows - 1)) 0
    el
    printf '%s' "$prompt"
    read_key
    local rc=$?
    if (( rc == 2 )); then
      draw
      continue
    fi
    case "$KEY" in
      y|Y) KEY=$'\a'; return 0 ;;
      n|N|$'\e'|"") KEY=$'\a'; return 1 ;;
    esac
  done
}

# --- keys ---------------------------------------------------------------

handle_key() {
  status_msg=""
  if (( small )); then
    [[ $KEY == q ]] && cmd_quit
    return 0
  fi
  if [[ $mode == help ]]; then
    case "$KEY" in
      $'\e'|"?") mode=normal ;;
      q) cmd_quit ;;
    esac
    return 0
  fi
  if [[ $mode == search ]]; then
    case "$KEY" in
      $'\e') mode=normal ;;
      q) cmd_quit ;;
      j|n|$'\e[B'|$'\eOB')
        if (( cur_hit < ${#hit_text[@]} - 1 )); then
          cur_hit=$((cur_hit + 1))
        fi
        ;;
      k|N|$'\e[A'|$'\eOA')
        if (( cur_hit > 0 )); then
          cur_hit=$((cur_hit - 1))
        fi
        ;;
      "")
        cmd_open_hit
        ;;
    esac
    return 0
  fi

  case "$KEY" in
    q) cmd_quit ;;
    "?") mode=help; return 0 ;;
    t) cmd_today ;;
    g) cmd_goto ;;
    /) cmd_search ;;
    s) cmd_save ;;
    u) cmd_undo ;;
    $'\x12') cmd_redo ;;
    a)
      focus=tasks
      cmd_add
      return 0
      ;;
    e)
      focus=tasks
      cmd_edit
      return 0
      ;;
    $'\t')
      if [[ $focus == tasks ]]; then
        focus=$left_focus
      else
        focus=tasks
      fi
      ;;
  esac

  case "$focus" in
    year)
      case "$KEY" in
        h|$'\e[D'|$'\eOD') shift_year -1 ;;
        l|$'\e[C'|$'\eOC') shift_year 1 ;;
        j|$'\e[B'|$'\eOB') set_focus month ;;
        "") focus=tasks ;;
      esac
      ;;
    month)
      case "$KEY" in
        h|$'\e[D'|$'\eOD') shift_month -1 ;;
        l|$'\e[C'|$'\eOC') shift_month 1 ;;
        k|$'\e[A'|$'\eOA') set_focus year ;;
        j|$'\e[B'|$'\eOB') set_focus grid ;;
        "") focus=tasks ;;
      esac
      ;;
    grid)
      case "$KEY" in
        h|$'\e[D'|$'\eOD') shift_days -1 ;;
        l|$'\e[C'|$'\eOC') shift_days 1 ;;
        K) shift_days -7 ;;
        J) shift_days 7 ;;
        k|$'\e[A'|$'\eOA') set_focus month ;;
        j|$'\e[B'|$'\eOB') set_focus labels ;;
        "") focus=tasks ;;
      esac
      ;;
    labels)
      case "$KEY" in
        k|$'\e[A'|$'\eOA')
          if (( cur_label == 0 )); then
            set_focus grid
          else
            cur_label=$((cur_label - 1))
            cur_task=0
            task_scroll=0
            clamp_task
          fi
          ;;
        j|$'\e[B'|$'\eOB')
          if (( cur_label < ${#label_names[@]} - 1 )); then
            cur_label=$((cur_label + 1))
            cur_task=0
            task_scroll=0
            clamp_task
          fi
          ;;
        l) cmd_label_add ;;
        r) cmd_label_rename ;;
        d) cmd_label_delete ;;
        J) cmd_label_reorder 1 ;;
        K) cmd_label_reorder -1 ;;
        "") focus=tasks ;;
      esac
      ;;
    tasks)
      case "$KEY" in
        k|$'\e[A'|$'\eOA') move_task_cursor -1 ;;
        j|$'\e[B'|$'\eOB') move_task_cursor 1 ;;
        x) cmd_toggle ;;
        X) cmd_mark_all ;;
        ">") cmd_indent 1 ;;
        "<") cmd_indent -1 ;;
        d) cmd_delete_task ;;
        J) cmd_move_task 1 ;;
        K) cmd_move_task -1 ;;
        m) cmd_move_label_of_task ;;
        c) cmd_carry ;;
      esac
      ;;
  esac
}

# --- self check ---------------------------------------------------------

CHECK_FAIL=0

check_fail() {
  CHECK_FAIL=$((CHECK_FAIL + 1))
  printf 'FAIL %s\n' "$1"
}

check_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    check_fail "${msg}: got [${got}] want [${want}]"
  fi
}

do_check() {
  local w dim j y m d f base nb path tmp a b
  local save_dir=$DIR

  w=$(weekday_sun0 2026 9 1)
  check_eq "$w" 2 "2026-09-01 Tuesday"
  check_eq "$(weekday_name 2026 9 1)" tuesday "2026-09-01 name"
  w=$(weekday_sun0 2026 9 21)
  check_eq "$w" 1 "2026-09-21 Monday"
  check_eq "$(weekday_name 2026 9 21)" monday "2026-09-21 name"
  check_eq "$(days_in_month 2024 2)" 29 "2024 leap February"
  check_eq "$(days_in_month 2023 2)" 28 "2023 February"
  check_eq "$(weekday_name 2024 2 1)" thursday "2024-02-01"
  check_eq "$(weekday_name 2024 2 29)" thursday "2024-02-29"
  check_eq "$(weekday_name 2024 3 1)" friday "2024-03-01"
  check_eq "$(weekday_name 2023 2 28)" tuesday "2023-02-28"
  check_eq "$(weekday_name 2023 3 1)" wednesday "2023-03-01"

  for y in 2023 2024 2026; do
    for m in 1 2 3 9 12; do
      dim=$(days_in_month "$y" "$m")
      for d in 1 "$dim"; do
        j=$(ymd_to_jdn "$y" "$m" "$d")
        jdn_to_ymd "$j"
        if (( RY != y || RM != m || RD != d )); then
          check_fail "jdn roundtrip ${y}-${m}-${d} -> ${RY}-${RM}-${RD}"
        fi
      done
    done
  done

  local s
  s=$(printf 'a\303\251b')
  check_eq "${#s}" 3 "utf-8 length"
  check_eq "${s:1:1}" "$(printf '\303\251')" "utf-8 slice"

  for f in "$save_dir"/*; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    [[ "$base" == *.sh ]] && continue
    parse_filename "$base" || continue
    w=$(weekday_name "$FN_Y" "$FN_M" "$FN_D")
    if [[ "$w" != "$FN_WD" ]]; then
      check_fail "${base} weekday is ${w}"
    fi
    nb=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%$'\r'}
      [[ -n "$line" ]] && nb=$((nb + 1))
    done < "$f"
    load_day_file "$f"
    local items=$((${#task_label[@]} + ${#label_names[@]} - 1))
    check_eq "$items" "$nb" "${base} line count"
    a=$(canonical)
    tmp=$(mktemp "${TMPDIR:-/tmp}/agenda.XXXXXX")
    write_day_to "$tmp" || check_fail "${base} write"
    load_day_file "$tmp"
    b=$(canonical)
    rm -f "$tmp"
    if [[ "$a" != "$b" ]]; then
      check_fail "${base} round trip"
    fi
  done

  load_day_file "$save_dir/saturday-12-09-2026"
  check_eq "${#label_names[@]}" 1 "saturday labels"
  local unmarked=0 i
  for ((i=0; i<${#task_mark[@]}; i++)); do
    if [[ -z ${task_mark[$i]} ]]; then
      unmarked=$((unmarked + 1))
      check_eq "${task_indent[$i]}" 0 "unmarked indent"
      check_eq "${task_indent[$((i+1))]}" 1 "child indent"
    fi
  done
  check_eq "$unmarked" 1 "one unmarked parent"

  load_day_file "$save_dir/monday-21-09-2026"
  check_eq "${label_names[0]}" day "day label"
  check_eq "${label_names[1]}" leftovers "leftovers"
  check_eq "${label_names[2]}" "to assess" "to assess"

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/agenda-work.XXXXXX")
  DIR=$work
  cat > "$work/thursday-17-09-2026" << 'EOF'
x alpha
	- beta
- gamma

leftovers
- delta
EOF
  # 17 Sep 2026 is Thursday. If the name is wrong the later path math still
  # uses the calendar. This fixture is loaded by path, not by scan.
  load_day_file "$work/thursday-17-09-2026"
  check_eq "${#task_label[@]}" 4 "fixture tasks"
  check_eq "${task_indent[1]}" 1 "beta nested"
  check_eq "${label_names[1]}" leftovers "fixture label"
  cur_y=2026
  cur_m=9
  cur_d=17
  cur_label=0
  cur_task=2
  clamp_task
  undo_reset
  # indent gamma under the block above
  cmd_indent 1
  check_eq "${task_indent[2]}" 1 "gamma indented"
  cmd_undo
  check_eq "${task_indent[2]}" 0 "undo indent"
  cmd_redo
  check_eq "${task_indent[2]}" 1 "redo indent"
  cmd_undo

  cur_task=0
  clamp_task
  g=${vis[0]}
  end=$(block_end "$g")
  check_eq "$end" 1 "alpha block includes beta"
  task_delete_range "$g" "$end"
  clamp_task
  check_eq "${#task_label[@]}" 2 "deleted parent and child"
  check_eq "${task_text[0]}" gamma "gamma remains"

  # carry delta onto the next day
  load_day_file "$work/thursday-17-09-2026"
  cur_label=1
  cur_task=0
  clamp_task
  undo_reset
  # replicate carry onto 18 Sep without the prompt
  local -a ci ct
  ci=("${task_indent[${vis[0]}]}")
  ct=("${task_text[${vis[0]}]}")
  slab=${label_names[$cur_label]}
  cur_y=2026
  cur_m=9
  cur_d=18
  load_day_file "$(day_path_for 2026 9 18)"
  label_names+=("$slab")
  li=$((${#label_names[@]} - 1))
  at=$(insert_point "$li")
  task_insert "$at" "$li" "${ci[0]}" "-" "${ct[0]}" "$(alloc_id)"
  write_day_to "$(day_path_for 2026 9 18)" || check_fail "carry write"
  check_eq "$(weekday_name 2026 9 18)" friday "18 Sep Friday"
  [[ -f "$work/friday-18-09-2026" ]] || check_fail "carry filename"
  load_day_file "$work/friday-18-09-2026"
  check_eq "${label_names[1]}" leftovers "carried label"
  check_eq "${task_text[0]}" delta "carried task"
  # second copy skipped
  local found=0 t
  for ((t=0; t<${#task_label[@]}; t++)); do
    if (( task_label[t] == 1 && task_indent[t] == 0 )) && [[ ${task_text[$t]} == delta ]]; then
      found=$((found + 1))
    fi
  done
  check_eq "$found" 1 "one delta"

  # empty day removes the file
  load_day_file "$work/friday-18-09-2026"
  tasks_clear
  label_names=("day")
  write_day_to "$work/friday-18-09-2026" || check_fail "remove write"
  [[ -f "$work/friday-18-09-2026" ]] && check_fail "empty file removed"

  DIR=$save_dir
  rm -rf "$work"

  if (( CHECK_FAIL == 0 )); then
    printf 'ok\n'
    return 0
  fi
  printf '%s failed\n' "$CHECK_FAIL"
  return 1
}

usage() {
  printf '%s\n' "Usage: agenda.sh [--check]"
  printf '%s\n' "Open the agenda for the day files in this folder. ? lists the keys."
}

main() {
  local today rest
  case "${1:-}" in
    --check) do_check; exit $? ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage; exit 1 ;;
  esac
  today=$(date +%Y-%m-%d)
  cur_y=${today%%-*}
  rest=${today#*-}
  cur_m=$((10#${rest%%-*}))
  cur_d=$((10#${rest#*-}))
  ty=$cur_y
  tm=$cur_m
  td=$cur_d
  init_term
  screen_size
  if (( rows < 24 || cols < 80 )); then
    cleanup
    printf 'Agenda needs a terminal at least 80 columns by 24 rows.\n'
    exit 1
  fi
  scan_files
  load_current
  set_focus grid
  printf '%s' "$S_CLEAR"
  while true; do
    if (( WINCHED )); then
      WINCHED=0
      printf '%s' "$S_CLEAR"
    fi
    draw
    read_key
    local rc=$?
    if (( rc == 2 )); then
      continue
    fi
    if (( rc != 0 )); then
      break
    fi
    handle_key
  done
}

main "$@"
