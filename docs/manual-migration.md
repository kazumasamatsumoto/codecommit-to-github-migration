# 手作業で 1 リポジトリを移管する (PowerShell)

`migrate.ps1` が内部でやっていることを、1 リポジトリ分、手作業で順に実行する手順です。
まずこの手順で 1 つ移管して仕組みを把握し、残りはスクリプトでまとめて実行する、という使い方を想定しています。

この文書では例として次の値を使います。自分の環境に読み替えてください。

| 項目 | 例 |
|---|---|
| CodeCommit のリージョン | `ap-northeast-1` |
| CodeCommit のリポジトリ名 | `my-app` |
| GitHub の owner (user or org) | `my-org` |
| GitHub のリポジトリ名 | `my-app` |

先に変数に入れておくと、以降のコマンドをそのまま貼り付けられます。

```powershell
$Region = "ap-northeast-1"
$Repo   = "my-app"
$Owner  = "my-org"
```

## 全体像

```
CodeCommit (my-app)
   │  1. 情報確認 (aws codecommit get-repository)
   │  2. ミラークローン (git clone --mirror)  ──→  .\work\my-app.git  (手元の完全なコピー)
   │                                                     │
   │                                                     │  4. ミラー push (git push --mirror)
   │                                                     ▼
   └────────────────────────────────────────────→  GitHub (my-org/my-app)   ← 3. 空リポジトリ作成 (gh repo create)
                                                        5. デフォルトブランチ設定 (gh repo edit)
                                                        6. 検証 (git ls-remote で両側の SHA を比較)
```

ポイントは「CodeCommit から GitHub へ直接送る」のではなく、**手元に完全なコピー(ミラー)を作ってから GitHub へ送る**ことです。この手元のコピーが、万一のときのバックアップにもなります。

## 前提

[migration-steps.md](migration-steps.md) の「0. 準備」が済んでいること。具体的には次の 3 つが通ることです。

```powershell
aws sts get-caller-identity     # AWS の認証が通る
gh auth status                  # GitHub の認証が通る
git --version                   # git が使える
```

## 手順 1. CodeCommit 側の情報を確認する

リポジトリが存在すること、デフォルトブランチが何かを確認します。デフォルトブランチは手順 5 で GitHub 側に合わせるのに使います。

```powershell
aws codecommit get-repository --region $Region --repository-name $Repo
```

出力例(抜粋)。

```json
{
  "repositoryMetadata": {
    "repositoryName": "my-app",
    "defaultBranch": "main",
    "cloneUrlHttp": "https://git-codecommit.ap-northeast-1.amazonaws.com/v1/repos/my-app",
    ...
  }
}
```

`defaultBranch` と `cloneUrlHttp` を控えます。変数にも入れておきます。

```powershell
$meta = (aws codecommit get-repository --region $Region --repository-name $Repo | ConvertFrom-Json).repositoryMetadata
$DefaultBranch = $meta.defaultBranch
$SrcUrl        = $meta.cloneUrlHttp
$DefaultBranch
$SrcUrl
```

ブランチとタグの一覧も見ておくと、あとの検証で数が合っているか確認しやすくなります。

```powershell
aws codecommit list-branches --region $Region --repository-name $Repo
```

## 手順 2. CodeCommit からミラークローンする

通常の `git clone` ではなく `--mirror` を使います。違いは次のとおりです。

| | `git clone` | `git clone --mirror` |
|---|---|---|
| 取得するもの | デフォルトブランチの作業ツリー + 他ブランチは remote-tracking として | **全ブランチ・全タグ・全 refs** をそのまま |
| 作業ツリー | あり | なし(bare リポジトリ) |
| 用途 | 開発 | 複製・バックアップ・移管 |

CodeCommit への認証には `aws codecommit credential-helper` を使います。これは git が認証を求めたときに aws CLI の認証情報からその場でパスワードを生成する仕組みで、IAM の Git 認証情報を別途発行する必要がありません。

Windows では Git Credential Manager が先に応答して失敗することがあるため、`-c credential.helper=`(空)でいったん既存の helper を無効化してから、aws の helper を指定します。

```powershell
New-Item -ItemType Directory -Force -Path .\work | Out-Null

git -c credential.helper= `
    -c 'credential.helper=!aws codecommit credential-helper $@' `
    -c credential.UseHttpPath=true `
    clone --mirror $SrcUrl ".\work\$Repo.git"
```

成功すると `.\work\my-app.git` ができます。中身を確認します。

```powershell
# 全 refs (ブランチとタグ) が入っているか
git -C ".\work\$Repo.git" show-ref

# ブランチ数とタグ数
git -C ".\work\$Repo.git" branch | Measure-Object | Select-Object -ExpandProperty Count
git -C ".\work\$Repo.git" tag    | Measure-Object | Select-Object -ExpandProperty Count
```

手順 1 の `list-branches` の数と一致していれば OK です。

### Git LFS を使っている場合

`.gitattributes` に `filter=lfs` があるリポジトリは、LFS の実体ファイルが別管理なので追加で取得します。

```powershell
# LFS を使っているか確認 (何も出なければ使っていない)
git -C ".\work\$Repo.git" show "HEAD:.gitattributes" 2>$null | Select-String "filter=lfs"

# 使っていれば LFS オブジェクトを全て取得
git -c credential.helper= `
    -c 'credential.helper=!aws codecommit credential-helper $@' `
    -c credential.UseHttpPath=true `
    -C ".\work\$Repo.git" lfs fetch --all origin
```

## 手順 3. GitHub に空のリポジトリを作る

```powershell
gh repo create "$Owner/$Repo" --private --description "Migrated from AWS CodeCommit ($Region/$Repo)"
```

`--private` を `--public` や `--internal`(Organization のみ)に変えられます。
README や .gitignore は**付けない**でください。付けるとコミットが 1 つ入ってしまい、手順 4 のミラー push で上書きすることになります。

作成できたか確認します。

```powershell
gh repo view "$Owner/$Repo" --json url,visibility,isEmpty
```

`isEmpty` が `true` であることを確認します。既に作ってあるリポジトリを使う場合も、空であることをここで確認してください。

## 手順 4. GitHub へミラー push する

手元のミラーにある全 refs を、そのまま GitHub へ送ります。

```powershell
$DstUrl = "https://github.com/$Owner/$Repo.git"

git -C ".\work\$Repo.git" push --mirror $DstUrl
```

初回は Git Credential Manager がブラウザを開いて GitHub のサインインを求めます。サインインすれば push が続行されます。

`push --mirror` は「送り先を手元のミラーと完全に同じ状態にする」操作です。送り先にしかない refs は削除されるので、必ず空のリポジトリ(または同じリポジトリの以前のミラー)に対して使ってください。

LFS を使っている場合は実体も送ります。

```powershell
git -C ".\work\$Repo.git" lfs push --all $DstUrl
```

## 手順 5. デフォルトブランチを合わせる

GitHub は新規リポジトリのデフォルトブランチを `main` にします。CodeCommit 側が `master` や `develop` だった場合、ここで揃えます。

```powershell
gh repo edit "$Owner/$Repo" --default-branch $DefaultBranch
```

## 手順 6. 検証する

CodeCommit と GitHub の両方について、ブランチとタグの名前と SHA を取り出して比べます。

```powershell
# 手元のミラー (= CodeCommit と同じ内容) の branches / tags
$src = git -C ".\work\$Repo.git" show-ref |
  Where-Object { $_ -match "refs/(heads|tags)/" } | Sort-Object

# GitHub 側の branches / tags  (^{} が付く行は注釈付きタグの被参照なので除く)
$dst = git ls-remote --heads --tags $DstUrl |
  Where-Object { $_ -notmatch "\^\{\}" } |
  ForEach-Object { ($_ -split "\s+")[0..1] -join " " } | Sort-Object

# 比較
if (($src -join "`n") -eq ($dst -join "`n")) {
  "検証 OK: $($src.Count) refs が一致"
} else {
  "差分あり"
  Compare-Object $src $dst
}
```

`検証 OK` が出れば、履歴・全ブランチ・全タグが完全に GitHub へ移っています。

目視でも確認しておきます。

```powershell
# GitHub をブラウザで開く
gh repo view "$Owner/$Repo" --web

# 最新コミットが CodeCommit 側と同じか
git -C ".\work\$Repo.git" log -1 --format="%H %s" $DefaultBranch
gh api "repos/$Owner/$Repo/commits/$DefaultBranch" --jq '.sha + " " + .commit.message'
```

## 手順 7. (あとから差分を取り込む場合)

リハーサルのあとに CodeCommit 側へ push があった場合、ミラーを更新して再 push すれば差分だけ反映されます。クローンし直す必要はありません。

```powershell
git -c credential.helper= `
    -c 'credential.helper=!aws codecommit credential-helper $@' `
    -c credential.UseHttpPath=true `
    -C ".\work\$Repo.git" fetch --prune origin

git -C ".\work\$Repo.git" push --mirror $DstUrl
```

そのあと手順 6 の検証をもう一度行います。

## 手順と migrate.ps1 の対応

| この文書の手順 | `migrate.ps1` の中の処理 |
|---|---|
| 1. 情報確認 | `aws codecommit get-repository` で存在確認と `defaultBranch` 取得 |
| 2. ミラークローン | `git clone --mirror`(2 回目以降は `fetch --prune`)、LFS 検出時は `lfs fetch --all` |
| 3. GitHub に作成 | `gh repo view` で存在確認、なければ `gh repo create` |
| 4. ミラー push | `git push --mirror`、LFS があれば `lfs push --all` |
| 5. デフォルトブランチ | `gh repo edit --default-branch` |
| 6. 検証 | `show-ref` と `ls-remote` の比較、差分があれば失敗扱い |
| 7. 差分取り込み | ミラーが既にあれば自動で `fetch` に切り替わる |

スクリプトは、これを `-All` で全リポジトリに繰り返し、最後に成功・失敗の一覧を出すだけです。
手作業で 1 つ通したあとは、次のように残りをまとめて実行できます。

```powershell
.\migrate.ps1 -Region ap-northeast-1 -Owner my-org -DryRun -All   # 対象の確認
.\migrate.ps1 -Region ap-northeast-1 -Owner my-org -All           # 実行
```

手作業で移管済みのリポジトリが含まれていても、GitHub 側は流用、ミラーは差分 fetch になるので、二重に作られることはありません。

## 作業後の片付け

`.\work\` のミラーは、CodeCommit を削除するまで残しておくことを推奨します。検証や差分取り込みに使えるうえ、そのままバックアップになります。不要になったら削除してかまいません。

```powershell
Remove-Item -Recurse -Force .\work
```
