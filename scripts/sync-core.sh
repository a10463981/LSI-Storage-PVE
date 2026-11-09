#!/usr/bin/env bash
# sync-core.sh — 从上游 fpk 仓库同步共享内核到 vendor/core/
#
# 用法：
#   scripts/sync-core.sh                     # 默认从 ../LSI-Storage-Fnos 同步
#   scripts/sync-core.sh --from /path/to/LSI-Storage-Fnos
#   scripts/sync-core.sh --check             # 只比对，不写任何文件（CI 门禁用）
#   scripts/sync-core.sh --verbose
#
# 退出码：0 = 一致 / 成功；1 = --check 发现差异；2 = 用法或上游不合法
#
# 设计要点：
#   * 单向同步，core 的真源永远在上游 fpk 仓库，本仓库只保留快照
#   * 平台专有内容一律不进 core：pkg/cmd/（fnOS 生命周期）、pkg/app/ui/（图标）、
#     build/80-pack.sh（fnpack 打包）
#   * CORE_SHA256 记录每个文件的哈希 + 上游 commit，--check 拿它和上游双向比对

set -euo pipefail
IFS=$'\n\t'

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(cd "$SELF_DIR/.." && pwd)
DEST="$PROJ/vendor/core"

FROM=""
MODE="sync"          # sync | check
VERBOSE=0
UPSTREAM_SLUG="a10463981/LSI-Storage-Fnos"

# 平台专有、不进 core
EXCLUDE_BUILD_NAMES=("80-pack.sh")
EXCLUDE_BUILD_DIRS=("./work" "./dist" "./vendor" "./logo-src" "./.git")
EXCLUDE_ANY_DIRS=("__pycache__" ".git")

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_info=$'\033[1;34m'; c_off=$'\033[0m'
say()  { printf '%s[sync]%s %s\n' "$c_info" "$c_off" "$*"; }
vlog() { [ "$VERBOSE" = 1 ] && printf '        %s\n' "$*" || true; }
die()  { printf '%s[错误]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 2; }

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from)    FROM="${2:-}"; shift 2 ;;
    --check)   MODE="check"; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help) usage ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

[ -n "$FROM" ] || FROM="$PROJ/../LSI-Storage-Fnos"
FROM=$(cd "$FROM" 2>/dev/null && pwd) || die "上游目录不存在：$FROM"

# ---------- 上游合法性 ----------
[ -f "$FROM/build/lib.sh" ]        || die "不像 fpk 仓库（缺 build/lib.sh）：$FROM"
[ -d "$FROM/pkg/app/runtime" ]     || die "不像 fpk 仓库（缺 pkg/app/runtime）：$FROM"
[ -d "$FROM/aiagent" ]             || die "不像 fpk 仓库（缺 aiagent/）：$FROM"

UP_COMMIT_FULL=""
UP_COMMIT=""
if git -C "$FROM" rev-parse --git-dir >/dev/null 2>&1; then
  UP_COMMIT_FULL=$(git -C "$FROM" rev-parse HEAD)
  UP_COMMIT=$(git -C "$FROM" rev-parse --short=7 HEAD)
  DIRTY=$(git -C "$FROM" status --porcelain | wc -l)
  [ "$DIRTY" -eq 0 ] || say "注意：上游工作区有 $DIRTY 处未提交改动，快照将包含这些改动"
else
  say "注意：上游不是 git 仓库，UPSTREAM 将只记录路径"
  UP_COMMIT_FULL="unknown"
  UP_COMMIT="nogit"
fi

CORE_VER=$( [ -f "$FROM/CORE_VERSION" ] && cat "$FROM/CORE_VERSION" || echo "0.1.03" )

# ---------- 生成清单（路径 → 源文件） ----------
# 清单格式与 CORE_SHA256 正文一致：<sha256>  <相对路径>
emit_manifest() {
  # build/（排除平台专有与构建产物）
  local ex_args=() d n
  for d in "${EXCLUDE_BUILD_DIRS[@]}";    do ex_args+=(-path "$d" -prune -o); done
  for n in "${EXCLUDE_BUILD_NAMES[@]}";   do ex_args+=(-name "$n" -prune -o); done
  (
    cd "$FROM/build"
    find . -type f \
         -path './work'    -prune -o \
         -path './dist'    -prune -o \
         -path './vendor'  -prune -o \
         -path './logo-src' -prune -o \
         -name '80-pack.sh' -prune -o \
         -name '__pycache__' -prune -o \
         -name '*.pyc' -prune -o \
         -type f -print0 |
    while IFS= read -r -d '' f; do printf '%s\0' "build/${f#./}"; done
  )
  # runtime/
  (
    cd "$FROM/pkg/app/runtime"
    find . -type f -name '__pycache__' -prune -o -name '*.pyc' -prune -o -type f -print0 |
    while IFS= read -r -d '' f; do printf '%s\0' "runtime/${f#./}"; done
  )
  # aiagent/
  (
    cd "$FROM/aiagent"
    find . -type f -name '__pycache__' -prune -o -type f -print0 |
    while IFS= read -r -d '' f; do printf '%s\0' "aiagent/${f#./}"; done
  )
  # LICENSE
  [ -f "$FROM/LICENSE" ] && printf '%s\0' "LICENSE"
}

map_src() {   # 相对路径 → 上游绝对路径
  case "$1" in
    build/*)   printf '%s\n' "$FROM/$1" ;;
    runtime/*) printf '%s\n' "$FROM/pkg/app/${1}" ;;
    aiagent/*) printf '%s\n' "$FROM/$1" ;;
    LICENSE)   printf '%s\n' "$FROM/LICENSE" ;;
    *)         printf '%s\n' "" ;;
  esac
}

build_hashes() {   # 输出排序后的 "<sha256>  <path>"
  local rel sha
  emit_manifest | sort -z | while IFS= read -r -d '' rel; do
    local src; src=$(map_src "$rel")
    [ -n "$src" ] && [ -f "$src" ] || continue
    sha=$(sha256sum "$src" | cut -d' ' -f1)
    printf '%s  %s\n' "$sha" "$rel"
  done
}

# ---------- --check ----------
if [ "$MODE" = "check" ]; then
  [ -d "$DEST" ] || die "vendor/core 不存在，先跑一次不带 --check 的同步"
  [ -f "$DEST/CORE_SHA256" ] || die "vendor/core/CORE_SHA256 不存在，先同步一次"

  tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
  build_hashes > "$tmpd/expected.txt"

  # 现有快照的实际哈希（排除清单文件本身）
  (
    cd "$DEST"
    find . -type f ! -name 'CORE_SHA256' -print0 | sort -z |
    while IFS= read -r -d '' f; do
      printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f#./}"
    done
  ) | sort > "$tmpd/actual.txt"

  sort "$tmpd/expected.txt" > "$tmpd/exp.sorted"
  grep -v '^#' "$DEST/CORE_SHA256" | grep -v '^[[:space:]]*$' | sort > "$tmpd/rec.sorted" || true

  rc=0
  if diff -q "$tmpd/exp.sorted" "$tmpd/actual.txt" >/dev/null; then
    say "${c_ok}vendor/core 与上游一致（$(wc -l < "$tmpd/exp.sorted") 个文件）${c_off}"
  else
    rc=1
    say "${c_err}vendor/core 与上游不一致${c_off}"
    # 文件级差异：+ 多出 / - 缺失 / M 内容被改
    # 注意：awk 里不能用 exp 当数组名（exp() 是内建函数），这里用 e/a
    awk '
      FNR==NR { e[$2]=$1; next }
      { a[$2]=$1 }
      END {
        for (q in a) {
          if (!(q in e))          printf "  + %s  （vendor 中多出，上游没有）\n", q
          else if (a[q] != e[q])  printf "  M %s  （内容与上游不同）\n", q
        }
        for (q in e) if (!(q in a)) printf "  - %s  （缺少）\n", q
      }' "$tmpd/exp.sorted" "$tmpd/actual.txt" | sort || true
    echo
    say "修复：scripts/sync-core.sh --from <上游路径>"
  fi

  # 记录本身是否过期
  if ! diff -q "$tmpd/exp.sorted" "$tmpd/rec.sorted" >/dev/null; then
    say "${c_err}CORE_SHA256 记录与上游不符（清单过期或文件被改但未重算）${c_off}"
    rc=1
  fi

  exit $rc
fi

# ---------- 同步 ----------
say "上游：$FROM（${UP_COMMIT}）"
mkdir -p "$DEST"

tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
build_hashes > "$tmpd/expected.txt"
total=$(wc -l < "$tmpd/expected.txt")
say "待同步文件：$total 个"

# 复制（逐文件，保证与清单一一对应）
while IFS= read -r line; do
  rel=${line#*  }
  src=$(map_src "$rel")
  [ -n "$src" ] || die "无法映射源路径：$rel"
  mkdir -p "$DEST/$(dirname "$rel")"
  cp -p "$src" "$DEST/$rel"
  vlog "复制 $rel"
done < "$tmpd/expected.txt"

# 删除快照中多余的文件（保证幂等且与上游严格一致）
find "$DEST" -type f ! -name 'CORE_SHA256' -print0 |
while IFS= read -r -d '' f; do
  rel=${f#"$DEST"/}
  if ! awk -v p="$rel" '{q=$0; sub(/^[^ ]+  /,"",q); if (q==p) found=1} END{exit !found}' "$tmpd/expected.txt"; then
    rm -f "$f"
    vlog "删除多余文件 $rel"
  fi
done
find "$DEST" -type d -empty -delete 2>/dev/null || true

# 写 CORE_SHA256
{
  echo "# core snapshot — 由 scripts/sync-core.sh 生成，请勿手改"
  echo "# upstream: $UPSTREAM_SLUG"
  echo "# commit: $UP_COMMIT_FULL"
  echo "# core-version: $CORE_VER"
  cat "$tmpd/expected.txt"
} > "$DEST/CORE_SHA256"

printf '%s\n' "$CORE_VER" > "$PROJ/CORE_VERSION"
printf '%s@%s\n' "$UPSTREAM_SLUG" "$UP_COMMIT" > "$PROJ/UPSTREAM"

say "${c_ok}同步完成${c_off}：$total 个文件 → vendor/core/"
say "  CORE_VERSION = $CORE_VER"
say "  UPSTREAM     = $UPSTREAM_SLUG@$UP_COMMIT"
say "  文件清单见 vendor/core/CORE_SHA256"
