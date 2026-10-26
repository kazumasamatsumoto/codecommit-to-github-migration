# CodeCommit → GitHub ミラー移行

`migrate.sh` は AWS CodeCommit のリポジトリを履歴・全ブランチ・タグごと GitHub へミラー移行します。

## 前提

- `aws` CLI が CodeCommit を読める認証情報で設定済み
- `gh` CLI が GitHub にログイン済み（`repo` スコープ）
- Git LFS を使うリポジトリがある場合は `brew install git-lfs`

CodeCommit への接続は `aws codecommit credential-helper` を使うので、IAM の Git 認証情報を別途作る必要はありません。

## 使い方

```bash
# まず dry-run で確認
./migrate.sh --dry-run --all

# 個別に指定
./migrate.sh --region ap-northeast-1 --owner <github-owner> my-repo other-repo

# 全リポジトリを一括 (GitHub 側は private で作成)
./migrate.sh --region ap-northeast-1 --owner <github-owner> --all
```

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
