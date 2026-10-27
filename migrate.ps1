<#
.SYNOPSIS
  CodeCommit -> GitHub ミラー移行スクリプト (PowerShell 版)

.DESCRIPTION
  AWS CodeCommit のリポジトリを履歴・全ブランチ・タグごと GitHub へミラー移行します。
  Windows PowerShell 5.1 / PowerShell 7 の両方で動作します。

.PARAMETER Repos
  移行するリポジトリ名 (複数可)。-All を指定した場合は不要。
.PARAMETER All
  CodeCommit の全リポジトリを対象にする。
.PARAMETER Region
  CodeCommit のリージョン。既定は $env:AWS_REGION、なければ aws configure の値。
.PARAMETER Owner
  GitHub の owner (user または org)。既定は gh の認証ユーザー。
.PARAMETER Visibility
  private | public | internal。既定は private。
.PARAMETER Prefix
  GitHub 側リポジトリ名に付ける接頭辞。
.PARAMETER WorkDir
  ミラークローンの置き場。既定は .\work。
.PARAMETER DryRun
  実際には作成・push せず、何をするかだけ表示する。

.EXAMPLE
  .\migrate.ps1 -DryRun -All
.EXAMPLE
  .\migrate.ps1 -Region ap-northeast-1 -Owner my-org my-repo other-repo
.EXAMPLE
  .\migrate.ps1 -Region ap-northeast-1 -Owner my-org -All
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Repos = @(),
  [switch]$All,
  [string]$Region = $env:AWS_REGION,
  [string]$Owner = "",
  [ValidateSet("private", "public", "internal")]
  [string]$Visibility = "private",
  [string]$Prefix = "",
  [string]$WorkDir = (Join-Path (Get-Location) "work"),
  [switch]$DryRun
)

# Windows PowerShell 5.1 では "Stop" にすると外部コマンドの stderr リダイレクトで例外になるため、
# 外部コマンドの成否は $LASTEXITCODE で判定する
$ErrorActionPreference = "Continue"

function Log($msg)  { Write-Host "[$(Get-Date -Format HH:mm:ss)] $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "[error] $msg" -ForegroundColor Red; exit 1 }

# 外部コマンドを実行し、失敗したら例外を投げる
function Invoke-Cmd {
  param([string]$Exe, [string[]]$Args)
  if ($DryRun) { Write-Host "  (dry-run) $Exe $($Args -join ' ')"; return }
  & $Exe @Args
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($Args -join ' ') failed (exit $LASTEXITCODE)" }
}

# CodeCommit へは aws CLI の認証情報をそのまま使う credential helper で接続する
# 先頭の空指定で Git Credential Manager などの既存 helper を無効化してから aws の helper を使う
$GitCC = @("-c", "credential.helper=", "-c", "credential.helper=!aws codecommit credential-helper `$@", "-c", "credential.UseHttpPath=true")

# ---- 事前チェック -----------------------------------------------------------
foreach ($tool in "aws", "gh", "git") {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Die "$tool が見つかりません" }
}
if (-not $Region) { $Region = (aws configure get region 2>$null) }
if (-not $Region) { Die "リージョンが未指定です (-Region か AWS_REGION)" }
aws sts get-caller-identity *> $null
if ($LASTEXITCODE -ne 0) { Die "AWS 認証情報が無効です" }
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Die "gh にログインしていません (gh auth login)" }
if (-not $Owner) { $Owner = (gh api user --jq .login) }

if ($All) {
  $Repos = @(aws codecommit list-repositories --region $Region `
    --query 'repositories[].repositoryName' --output json | ConvertFrom-Json)
}
if ($Repos.Count -eq 0) { Die "対象リポジトリがありません (引数で指定するか -All)" }

$HasLfs = [bool](Get-Command git-lfs -ErrorAction SilentlyContinue)
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Log "region=$Region owner=$Owner visibility=$Visibility repos=$($Repos.Count) dry-run=$($DryRun.IsPresent)"

# ---- 1 リポジトリ分の移行 ----------------------------------------------------
function Migrate-One([string]$Src) {
  $Dst    = "$Prefix$Src"
  $SrcUrl = "https://git-codecommit.$Region.amazonaws.com/v1/repos/$Src"
  $DstUrl = "https://github.com/$Owner/$Dst.git"
  $Mirror = Join-Path $WorkDir "$Src.git"

  Log "=== $Src -> $Owner/$Dst ==="

  # CodeCommit 側の存在確認とデフォルトブランチ取得
  $metaJson = aws codecommit get-repository --region $Region --repository-name $Src 2>$null
  if ($LASTEXITCODE -ne 0) { Warn "CodeCommit に $Src が見つかりません"; return $false }
  $DefaultBranch = ($metaJson | ConvertFrom-Json).repositoryMetadata.defaultBranch

  # GitHub 側リポジトリ作成 (既存なら流用)
  gh repo view "$Owner/$Dst" *> $null
  if ($LASTEXITCODE -eq 0) {
    Log "GitHub に $Owner/$Dst は既に存在します (流用)"
  } else {
    Log "GitHub に $Owner/$Dst を作成 ($Visibility)"
    Invoke-Cmd gh @("repo", "create", "$Owner/$Dst", "--$Visibility",
      "--description", "Migrated from AWS CodeCommit ($Region/$Src)")
  }

  # ミラークローン (2 回目以降は fetch で更新)
  if (Test-Path $Mirror) {
    Log "既存ミラーを更新: $Mirror"
    Invoke-Cmd git ($GitCC + @("-C", $Mirror, "fetch", "--prune", "origin"))
  } else {
    Log "ミラークローン: $SrcUrl"
    Invoke-Cmd git ($GitCC + @("clone", "--mirror", $SrcUrl, $Mirror))
  }
  if ($DryRun) { return $true }

  # Git LFS
  git -C $Mirror cat-file -e "HEAD:.gitattributes" 2>$null
  if ($LASTEXITCODE -eq 0) {
    $attrs = git -C $Mirror show "HEAD:.gitattributes"
    if ($attrs -match "filter=lfs") {
      if ($HasLfs) {
        Log "Git LFS オブジェクトを取得"
        Invoke-Cmd git ($GitCC + @("-C", $Mirror, "lfs", "fetch", "--all", "origin"))
      } else {
        Warn "$Src は Git LFS を使っていますが git-lfs が未インストールです (winget install GitHub.GitLFS)"
      }
    }
  }

  # GitHub へ push --mirror
  Log "push --mirror -> $DstUrl"
  Invoke-Cmd git @("-C", $Mirror, "push", "--mirror", $DstUrl)
  if ($HasLfs) {
    $lfsFiles = git -C $Mirror lfs ls-files --all 2>$null
    if ($lfsFiles) {
      Log "Git LFS オブジェクトを push"
      Invoke-Cmd git @("-C", $Mirror, "lfs", "push", "--all", $DstUrl)
    }
  }

  # デフォルトブランチを合わせる
  if ($DefaultBranch) {
    gh repo edit "$Owner/$Dst" --default-branch $DefaultBranch *> $null
    if ($LASTEXITCODE -ne 0) { Warn "デフォルトブランチの設定に失敗: $DefaultBranch" }
  }

  # 検証: 両側の refs (branches + tags) を比較
  $srcRefs = @(git -C $Mirror show-ref | Where-Object { $_ -match "refs/(heads|tags)/" } | Sort-Object)
  $dstRefs = @(git ls-remote --heads --tags $DstUrl |
    Where-Object { $_ -notmatch "\^\{\}" } |
    ForEach-Object { ($_ -split "\s+")[0..1] -join " " } | Sort-Object)
  if (($srcRefs -join "`n") -eq ($dstRefs -join "`n")) {
    Log "検証 OK: $($srcRefs.Count) refs が一致"
    return $true
  }
  Warn "refs に差分があります:"
  Compare-Object $srcRefs $dstRefs | Format-Table -AutoSize | Out-String | Write-Host
  return $false
}

$Ok = @(); $Ng = @()
foreach ($r in $Repos) {
  try {
    if (Migrate-One $r) { $Ok += $r } else { $Ng += $r }
  } catch {
    Warn "$r : $($_.Exception.Message)"
    $Ng += $r
  }
}

Write-Host ""
Log "完了: 成功 $($Ok.Count) / 失敗 $($Ng.Count)"
if ($Ok.Count -gt 0) { $Ok | ForEach-Object { Write-Host "  OK: $_" } }
if ($Ng.Count -gt 0) { $Ng | ForEach-Object { Write-Host "  NG: $_" }; exit 1 }
exit 0
