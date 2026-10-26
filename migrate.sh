#!/usr/bin/env bash
# CodeCommit -> GitHub ミラー移行スクリプト
#
# 使い方:
#   ./migrate.sh [options] <repo> [<repo> ...]
#   ./migrate.sh [options] --all          # CodeCommit の全リポジトリを対象にする
#
# オプション:
#   --region <r>      CodeCommit のリージョン (default: $AWS_REGION / aws configure の値)
#   --owner <o>       GitHub の owner (user or org) (default: gh の認証ユーザー)
#   --visibility <v>  private | public | internal (default: private)
#   --prefix <p>      GitHub 側リポジトリ名に付ける接頭辞 (default: なし)
#   --dry-run         実際には作成・push せず、何をするかだけ表示する
#   --work-dir <d>    ミラークローンの置き場 (default: ./work)
#
# 前提:
#   - aws CLI が CodeCommit を読める認証情報で設定済み
#   - gh CLI が GitHub にログイン済み (repo スコープ)
#   - git-lfs を使っているリポジトリがある場合は git-lfs をインストール済み
set -euo pipefail

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
OWNER=""
VISIBILITY="private"
PREFIX=""
DRY_RUN=0
ALL=0
WORK_DIR="$(pwd)/work"
REPOS=()

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then echo "  (dry-run) $*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --region)     REGION="$2"; shift 2 ;;
    --owner)      OWNER="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    --prefix)     PREFIX="$2"; shift 2 ;;
    --work-dir)   WORK_DIR="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --all)        ALL=1; shift ;;
    -h|--help)    sed -n '2,24p' "$0"; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            REPOS+=("$1"); shift ;;
  esac
done

# ---- 事前チェック -----------------------------------------------------------
command -v aws >/dev/null || die "aws CLI が見つかりません"
command -v gh  >/dev/null || die "gh CLI が見つかりません"
command -v git >/dev/null || die "git が見つかりません"
[ -n "$REGION" ] || die "リージョンが未指定です (--region か AWS_REGION)"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS 認証情報が無効です"
gh auth status >/dev/null 2>&1 || die "gh にログインしていません (gh auth login)"

if [ -z "$OWNER" ]; then
  OWNER="$(gh api user --jq .login)"
fi

if [ "$ALL" = 1 ]; then
  mapfile -t REPOS < <(aws codecommit list-repositories --region "$REGION" \
    --query 'repositories[].repositoryName' --output text | tr '\t' '\n' | sed '/^$/d')
fi
[ ${#REPOS[@]} -gt 0 ] || die "対象リポジトリがありません (引数で指定するか --all)"

# CodeCommit へは aws CLI の認証情報をそのまま使う credential helper で接続する
GIT_CC=(git -c "credential.helper=!aws codecommit credential-helper \$@" -c credential.UseHttpPath=true)
HAS_LFS=0; command -v git-lfs >/dev/null && HAS_LFS=1

mkdir -p "$WORK_DIR"
log "region=$REGION owner=$OWNER visibility=$VISIBILITY repos=${#REPOS[@]} dry-run=$DRY_RUN"

declare -a RESULT_OK=() RESULT_NG=()

# ---- 1 リポジトリ分の移行 ----------------------------------------------------
migrate_one() {
  local src="$1"
  local dst="${PREFIX}${src}"
  local src_url="https://git-codecommit.${REGION}.amazonaws.com/v1/repos/${src}"
  local dst_url="https://github.com/${OWNER}/${dst}.git"
  local mirror="${WORK_DIR}/${src}.git"

  log "=== ${src} -> ${OWNER}/${dst} ==="

  # CodeCommit 側の存在確認とデフォルトブランチ取得
  local meta default_branch
  meta="$(aws codecommit get-repository --region "$REGION" --repository-name "$src" 2>/dev/null)" \
    || { warn "CodeCommit に ${src} が見つかりません"; return 1; }
  default_branch="$(echo "$meta" | python3 -c 'import sys,json; print(json.load(sys.stdin)["repositoryMetadata"].get("defaultBranch",""))')"

  # GitHub 側リポジトリ作成 (既存なら流用)
  if gh repo view "${OWNER}/${dst}" >/dev/null 2>&1; then
    log "GitHub に ${OWNER}/${dst} は既に存在します (流用)"
  else
    log "GitHub に ${OWNER}/${dst} を作成 (${VISIBILITY})"
    run gh repo create "${OWNER}/${dst}" "--${VISIBILITY}" \
      --description "Migrated from AWS CodeCommit (${REGION}/${src})"
  fi

  # ミラークローン (2 回目以降は fetch で更新)
  if [ -d "$mirror" ]; then
    log "既存ミラーを更新: $mirror"
    run "${GIT_CC[@]}" -C "$mirror" fetch --prune origin
  else
    log "ミラークローン: $src_url"
    run "${GIT_CC[@]}" clone --mirror "$src_url" "$mirror"
  fi
  [ "$DRY_RUN" = 1 ] && return 0

  # Git LFS
  if git -C "$mirror" cat-file -e HEAD:.gitattributes 2>/dev/null \
     && git -C "$mirror" show HEAD:.gitattributes | grep -q 'filter=lfs'; then
    if [ "$HAS_LFS" = 1 ]; then
      log "Git LFS オブジェクトを取得"
      "${GIT_CC[@]}" -C "$mirror" lfs fetch --all origin
    else
      warn "${src} は Git LFS を使っていますが git-lfs が未インストールです (brew install git-lfs)"
    fi
  fi

  # GitHub へ push --mirror
  log "push --mirror -> $dst_url"
  git -C "$mirror" push --mirror "$dst_url"
  if [ "$HAS_LFS" = 1 ] && git -C "$mirror" lfs ls-files --all >/dev/null 2>&1 \
     && [ -n "$(git -C "$mirror" lfs ls-files --all 2>/dev/null)" ]; then
    log "Git LFS オブジェクトを push"
    git -C "$mirror" lfs push --all "$dst_url"
  fi

  # デフォルトブランチを合わせる
  if [ -n "$default_branch" ]; then
    gh repo edit "${OWNER}/${dst}" --default-branch "$default_branch" >/dev/null \
      || warn "デフォルトブランチの設定に失敗: $default_branch"
  fi

  # 検証: 両側の refs (branches + tags) を比較
  local src_refs dst_refs
  src_refs="$(git -C "$mirror" show-ref | grep -E 'refs/(heads|tags)/' | sort)"
  dst_refs="$(git ls-remote --heads --tags "$dst_url" | awk '{print $1, $2}' | grep -v '\^{}' | sort)"
  if [ "$src_refs" = "$dst_refs" ]; then
    log "検証 OK: $(echo "$src_refs" | wc -l | tr -d ' ') refs が一致"
  else
    warn "refs に差分があります:"
    diff <(echo "$src_refs") <(echo "$dst_refs") || true
    return 1
  fi
}

for r in "${REPOS[@]}"; do
  if migrate_one "$r"; then RESULT_OK+=("$r"); else RESULT_NG+=("$r"); fi
done

echo
log "完了: 成功 ${#RESULT_OK[@]} / 失敗 ${#RESULT_NG[@]}"
[ ${#RESULT_OK[@]} -gt 0 ] && printf '  OK: %s\n' "${RESULT_OK[@]}"
[ ${#RESULT_NG[@]} -gt 0 ] && printf '  NG: %s\n' "${RESULT_NG[@]}" && exit 1
exit 0
