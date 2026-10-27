# CodeCommit → GitHub リポジトリ移管手順 (PowerShell)

Windows の PowerShell から、このリポジトリの `migrate.ps1` を使って CodeCommit のリポジトリを GitHub へ移管する手順書です。
Windows PowerShell 5.1 と PowerShell 7 のどちらでも動きます。1 リポジトリでも複数でも流れは同じです。

## 全体の流れ

| フェーズ | やること | 所要の目安 |
|---|---|---|
| 0. 準備 | ツール導入、認証、棚卸し、GitHub 側の受け皿 | 半日 |
| 1. リハーサル | ミラー移行を一度実行し、差分なく転送できることを確認 | 1〜2 時間 |
| 2. 凍結 | CodeCommit を読み取り専用にする | 数分 |
| 3. 本移行 | 再度ミラー移行(差分のみ)、検証 | 数十分 |
| 4. 周辺の切り替え | 保護ルール、CI/CD、通知、権限 | 半日〜 |
| 5. 利用者の切り替え | remote URL の変更、案内 | 当日 |
| 6. 後片付け | 並走期間後に CodeCommit を削除 | 2〜4 週間後 |

## 0. 準備

### 0-1. ツールの導入

管理者権限は不要です。winget で入れます。

```powershell
winget install Amazon.AWSCLI GitHub.cli Git.Git
# Git LFS を使っているリポジトリがある場合のみ
winget install GitHub.GitLFS
```

インストール後は PowerShell を開き直し、PATH に通っていることを確認します。

```powershell
aws --version
gh --version
git --version
```

### 0-2. スクリプトの取得と実行許可

```powershell
git clone https://github.com/kazumasamatsumoto/codecommit-to-github-migration.git
cd codecommit-to-github-migration

# 初回のみ。現在のユーザーに限り、ローカルの未署名スクリプトを許可する
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# zip でダウンロードした場合は「インターネットから取得」マークを外す
Unblock-File .\migrate.ps1
```

### 0-3. AWS の認証

CodeCommit を読める IAM ユーザーまたはロールで設定します。必要な権限は `codecommit:GitPull`、`codecommit:GetRepository`、`codecommit:ListRepositories` です。

```powershell
aws configure
# AWS Access Key ID / Secret Access Key / region (例: ap-northeast-1) / output (json)

aws sts get-caller-identity
```

SSO を使っている場合は `aws configure sso` と `aws sso login` で、環境変数 `AWS_PROFILE` にプロファイル名を入れておけばスクリプトはそのまま動きます。

```powershell
$env:AWS_PROFILE = "my-profile"
```

CodeCommit への Git 接続は `aws codecommit credential-helper` を使うので、IAM の「Git 認証情報(HTTPS)」を別途発行する必要はありません。

### 0-4. GitHub の認証

```powershell
gh auth login
# GitHub.com → HTTPS → Login with a web browser
gh auth status
```

Organization へ移管する場合は、そのアカウントが Organization でリポジトリを作成できる権限(Owner、または Member でリポジトリ作成が許可されている)を持っていることを確認します。

### 0-5. 棚卸し

```powershell
$Region = "ap-northeast-1"

# リポジトリ一覧
aws codecommit list-repositories --region $Region --output table

# 各リポジトリの詳細(デフォルトブランチなど)
aws codecommit get-repository --region $Region --repository-name <repo>

# 承認ルールテンプレート(GitHub では Rulesets で作り直す)
aws codecommit list-approval-rule-templates --region $Region

# トリガー(Lambda / SNS 連携)
aws codecommit get-repository-triggers --region $Region --repository-name <repo>

# オープン中の PR(移行できないので事前にマージするか閉じる)
aws codecommit list-pull-requests --region $Region --repository-name <repo> --pull-request-status OPEN
```

全リポジトリの詳細をまとめて一覧にするには次のようにします。

```powershell
$repos = aws codecommit list-repositories --region $Region --query 'repositories[].repositoryName' --output json | ConvertFrom-Json
$repos | ForEach-Object {
  $m = (aws codecommit get-repository --region $Region --repository-name $_ | ConvertFrom-Json).repositoryMetadata
  [pscustomobject]@{ Name = $_; DefaultBranch = $m.defaultBranch; LastModified = $m.lastModifiedDate }
} | Format-Table -AutoSize
```

あわせて次も確認します。

- Git LFS を使っているか(リポジトリの `.gitattributes` に `filter=lfs` があるか)
- CodePipeline / CodeBuild のソースに CodeCommit を使っているか
- EventBridge や CodeStar Notifications で CodeCommit のイベントを拾っているか
- IAM ポリシーで誰が push / マージできるようになっているか(GitHub の権限設計の元ネタになる)

### 0-6. GitHub 側の受け皿

- Organization へ移管するか個人アカウントかを決めます。チーム開発なら Organization です。
- Organization なら Team を作り、メンバーを招待しておきます。
- 2 要素認証を必須にする場合は、メンバーに事前に設定してもらいます。
- リポジトリは `migrate.ps1` が自動作成するので、手で作る必要はありません。既に作ってある場合はそのまま流用されます。

## 1. リハーサル(事前移行)

切り替え前に一度まるごと移行し、問題を洗い出します。まず dry-run で対象と動作を確認します。

```powershell
.\migrate.ps1 -Region ap-northeast-1 -Owner <github-owner> -DryRun -All
```

問題なければ実行します。GitHub 側リポジトリは private で作成されます。

```powershell
.\migrate.ps1 -Region ap-northeast-1 -Owner <github-owner> -All
```

一部だけ移行する場合はリポジトリ名を並べます。名前に接頭辞を付けたい場合は `-Prefix` を使います。

```powershell
.\migrate.ps1 -Region ap-northeast-1 -Owner <github-owner> repo-a repo-b
.\migrate.ps1 -Region ap-northeast-1 -Owner <github-owner> -Prefix legacy- repo-a
```

スクリプトはリポジトリごとに次を行い、最後に両側の branches / tags の SHA を比較します。

1. GitHub に同名リポジトリを作成(既存なら流用)
2. `git clone --mirror` でミラーを `.\work\<repo>.git` に取得
3. Git LFS を検出したら LFS オブジェクトも取得
4. `git push --mirror` で GitHub へ転送
5. デフォルトブランチを CodeCommit と同じに設定
6. 両側の refs を比較して「検証 OK」を出す

「検証 OK」が全リポジトリで出れば、履歴・全ブランチ・タグが完全に一致しています。差分が出た場合は、ほとんどが「リハーサル後に CodeCommit 側へ push があった」ケースなので、本移行で再実行すれば解消します。

この時点で GitHub 上のリポジトリを使って、保護ルールや CI の設定を先に作り込んでおけます(フェーズ 4 を前倒しできます)。

## 2. 凍結(CodeCommit を読み取り専用に)

切り替え日に、CodeCommit への push を止めます。IAM で Deny を付けるのが確実です。clone と pull は引き続きできます。

```powershell
@'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "FreezeCodeCommit",
    "Effect": "Deny",
    "Action": [
      "codecommit:GitPush",
      "codecommit:CreateBranch",
      "codecommit:DeleteBranch",
      "codecommit:PutFile",
      "codecommit:MergePullRequestByFastForward",
      "codecommit:MergePullRequestBySquash",
      "codecommit:MergePullRequestByThreeWay",
      "codecommit:MergeBranchesByFastForward",
      "codecommit:MergeBranchesBySquash",
      "codecommit:MergeBranchesByThreeWay"
    ],
    "Resource": "*"
  }]
}
'@ | Set-Content -Encoding ascii freeze-codecommit.json

# 管理ポリシーとして作成
aws iam create-policy --policy-name FreezeCodeCommit --policy-document file://freeze-codecommit.json

# 開発者が所属する IAM グループにアタッチ(ユーザー単位なら attach-user-policy)
$AccountId = (aws sts get-caller-identity --query Account --output text)
aws iam attach-group-policy --group-name <developers-group> --policy-arn "arn:aws:iam::${AccountId}:policy/FreezeCodeCommit"
```

Deny は Allow より優先されるため、既存の権限を触らずに書き込みだけ止められます。

## 3. 本移行

リハーサルで作ったミラー(`.\work\`)が残っていれば、差分だけ fetch して push されるので短時間で終わります。

```powershell
.\migrate.ps1 -Region ap-northeast-1 -Owner <github-owner> -All
```

「検証 OK」を全リポジトリで確認したら、履歴の移行は完了です。結果は最後に「成功 n / 失敗 m」で出ます。失敗したリポジトリ名を指定して再実行できます。

## 4. 周辺の切り替え

Git で運べないものを GitHub 側に作り直します。

| 項目 | GitHub での対応 | 参考 |
|---|---|---|
| 承認ルール、マージ権限 | Rulesets、CODEOWNERS | [github-merge-rules.md](github-merge-rules.md) |
| CodePipeline のソース | CodeStar Connections(GitHub App 経由)で GitHub を指定 | AWS Console → Developer Tools → Settings → Connections |
| CodeBuild のソース | 同上、または GitHub Actions に移行 | |
| GitHub Actions から AWS へデプロイ | OIDC 連携の IAM ロールを作る(アクセスキー不要) | `aws-actions/configure-aws-credentials` |
| トリガー(Lambda / SNS) | Webhook、または GitHub Actions の `on: push` | |
| 通知(Slack / Chatbot) | GitHub の Slack App、または Actions から通知 | |
| 権限 | Organization の Team と Repository role(Read / Write / Maintain / Admin) | |
| Issue 管理 | CodeCommit には Issue がないので移行対象なし。外部ツール連携はそのまま | |

CodeStar Connections を使う場合、接続を作成したあと GitHub 側で GitHub App のインストール承認が必要です。AWS Console の Connections 画面で「Pending」になっている接続を「Update pending connection」で完了させます。

## 5. 利用者の切り替え

各開発者のローカルで remote を切り替えます。

```powershell
git remote set-url origin https://github.com/<github-owner>/<repo>.git
git fetch --prune origin
git branch -u origin/<branch>
```

Windows では Git Credential Manager が GitHub の認証をブラウザ経由で行うので、初回の push 時にサインインすれば以後は自動です。

案内文に含めるべきこと。

- 新しいリポジトリ URL の一覧
- CodeCommit が読み取り専用になった旨と、削除予定日
- GitHub の認証方法(初回 push 時にブラウザでサインイン、または `gh auth login`)
- 承認ルールとマージ手順の変更点
- CI の起動方法が変わる場合はその説明

## 6. 後片付け

2〜4 週間の並走期間を置き、CodeCommit への参照が残っていないことを確認してから削除します。

```powershell
# 参照が残っていないかの確認例
aws codepipeline list-pipelines --region ap-northeast-1
aws codebuild list-projects --region ap-northeast-1
Select-String -Path "$HOME\.gitconfig", "$HOME\.ssh\config" -Pattern "git-codecommit" -ErrorAction SilentlyContinue

# 削除前にミラーを別の場所へ退避
Copy-Item -Recurse .\work\<repo>.git D:\backup\codecommit\

# 削除
aws codecommit delete-repository --region ap-northeast-1 --repository-name <repo>
```

CodeCommit は新規受付を終了しているため、一度削除すると同じ名前で作り直せない可能性があります。削除前に必ずミラーを退避してください。

## トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `.\migrate.ps1 : このシステムではスクリプトの実行が無効になっている` | 実行ポリシー。`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` を実行 |
| `aws` や `gh` が見つからない | winget 後に PowerShell を開き直していない。または PATH 未反映 |
| `fatal: unable to access ... 403` (CodeCommit) | IAM に `codecommit:GitPull` がない。または Git Credential Manager が先に応答している。スクリプトは既存 helper を無効化してから aws の helper を使うが、`git config --global --get-all credential.helper` で設定を確認 |
| 認証ダイアログが繰り返し出る (CodeCommit) | 上と同じ。`git config --global credential.useHttpPath true` と、CodeCommit のホストに限定した helper 設定を追加する(下記) |
| `remote: error: GH013: Repository rule violations` (GitHub) | 先に Rulesets を作ってしまった。ミラー push の間だけ Rulesets を Disabled にするか、実行者を Bypass list に入れる |
| LFS 関連で `error: failed to push some refs` | `git-lfs` 未インストール。`winget install GitHub.GitLFS` 後に再実行 |
| 検証で refs に差分 | リハーサル後に CodeCommit 側へ push があった。凍結してから再実行 |
| GitHub 側のデフォルトブランチが違う | `gh repo edit <owner>/<repo> --default-branch <name>` |
| 日本語が文字化けする | `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` を実行してから再実行 |

CodeCommit のホストだけ aws の helper を使う恒久設定(スクリプトを使わず手動で git 操作する場合)。

```powershell
git config --global credential.https://git-codecommit.ap-northeast-1.amazonaws.com.helper '!aws codecommit credential-helper $@'
git config --global credential.https://git-codecommit.ap-northeast-1.amazonaws.com.UseHttpPath true
```
