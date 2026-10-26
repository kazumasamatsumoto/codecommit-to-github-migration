# CodeCommit → GitHub ミラー移行

AWS CodeCommit のリポジトリを履歴・全ブランチ・タグごと GitHub へミラー移行します。

- `migrate.sh` : macOS / Linux (bash 4 以上)
- `migrate.ps1` : Windows (PowerShell 5.1 / 7)、macOS / Linux の pwsh

## 前提

- `aws` CLI が CodeCommit を読める認証情報で設定済み
- `gh` CLI が GitHub にログイン済み（`repo` スコープ）
- Git LFS を使うリポジトリがある場合は git-lfs
  - macOS: `brew install git-lfs`
  - Windows: `winget install GitHub.GitLFS`

CodeCommit への接続は `aws codecommit credential-helper` を使うので、IAM の Git 認証情報を別途作る必要はありません。

## 使い方 (macOS / Linux)

```bash
# まず dry-run で確認
./migrate.sh --dry-run --all

# 個別に指定
./migrate.sh --region ap-northeast-1 --owner <github-owner> my-repo other-repo

# 全リポジトリを一括 (GitHub 側は private で作成)
./migrate.sh --region ap-northeast-1 --owner <github-owner> --all
```

## 使い方 (Windows / PowerShell)

必要なツールは winget で入ります。

```powershell
winget install Amazon.AWSCLI GitHub.cli Git.Git
aws configure
gh auth login
```

初回のみスクリプト実行を許可します（現在のユーザーのみ、署名なしローカルスクリプトを許可）。

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

実行方法は bash 版と同じ構成です。

```powershell
# まず dry-run で確認
.\migrate.ps1 -DryRun -All

# 個別に指定
.\migrate.ps1 -Region ap-northeast-1 -Owner <github-owner> my-repo other-repo

# 全リポジトリを一括 (GitHub 側は private で作成)
.\migrate.ps1 -Region ap-northeast-1 -Owner <github-owner> -All

# public で作る / 名前に接頭辞を付ける
.\migrate.ps1 -Owner <github-owner> -Visibility public -Prefix legacy- my-repo
```

Windows では git の credential helper が Git Credential Manager になっていると CodeCommit への接続で止まることがあります。スクリプトは `aws codecommit credential-helper` を明示的に指定しているので通常は問題ありませんが、認証で失敗する場合は次を確認してください。

```powershell
git config --global --get-all credential.helper
```

## 処理内容

各リポジトリについて次を行います。

1. GitHub に同名リポジトリを作成（既存なら流用）
2. `git clone --mirror` → `git push --mirror`
3. Git LFS を検出したら LFS オブジェクトも転送
4. デフォルトブランチを CodeCommit と同じに設定
5. 両側の branches/tags の SHA を比較して検証

ミラークローンは `./work/` に残るので、再実行すると差分 fetch で再同期できます。

## Git では運べないもの

- プルリクエストとコメント履歴
- 承認ルール → GitHub のブランチ保護 / Rulesets / CODEOWNERS で再現
- CodePipeline / CodeBuild のソース設定 → CodeStar Connections か GitHub Actions へ
- トリガー・通知 → Webhook / Actions へ
- IAM によるアクセス制御 → GitHub の Team / 権限へ

## 切り替え後

- 各自 `git remote set-url origin https://github.com/<owner>/<repo>.git`
- CodeCommit 側は IAM で `codecommit:GitPush` を Deny して読み取り専用にし、並走期間後に削除
