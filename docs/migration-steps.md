# CodeCommit → GitHub リポジトリ引っ越し手順

このリポジトリの `migrate.sh` / `migrate.ps1` を使った、実務向けの手順書です。
1 リポジトリでも複数でも流れは同じです。

## 全体の流れ

| フェーズ | やること | 所要の目安 |
|---|---|---|
| 0. 準備 | 棚卸し、GitHub 側の受け皿、ツールと認証 | 半日 |
| 1. 事前移行 | ミラー移行を一度実行し、差分なく転送できることを確認 | 1〜2 時間 |
| 2. 凍結 | CodeCommit を読み取り専用にする | 数分 |
| 3. 本移行 | 再度ミラー移行(差分 fetch)、検証 | 数十分 |
| 4. 周辺の切り替え | 保護ルール、CI/CD、通知、権限 | 半日〜 |
| 5. 利用者の切り替え | remote URL の変更、案内 | 当日 |
| 6. 後片付け | 並走期間後に CodeCommit を削除 | 2〜4 週間後 |

## 0. 準備

### 棚卸し

```bash
# リポジトリ一覧
aws codecommit list-repositories --region ap-northeast-1 --output table

# 各リポジトリの詳細(デフォルトブランチなど)
aws codecommit get-repository --region ap-northeast-1 --repository-name <repo>

# 承認ルールテンプレート(GitHub では手で作り直す)
aws codecommit list-approval-rule-templates --region ap-northeast-1

# トリガー(Lambda / SNS 連携)
aws codecommit get-repository-triggers --region ap-northeast-1 --repository-name <repo>

# オープン中の PR(移行できないので事前に片付ける)
aws codecommit list-pull-requests --region ap-northeast-1 --repository-name <repo> --pull-request-status OPEN
```

次も確認しておきます。

- Git LFS を使っているか(`.gitattributes` に `filter=lfs` があるか)
- CodePipeline / CodeBuild のソースに CodeCommit を使っているか
- EventBridge や CodeStar Notifications で CodeCommit のイベントを拾っているか
- IAM ポリシーで誰が push / マージできるようになっているか(GitHub の権限設計の元ネタになる)

### GitHub 側の受け皿

- Organization を使うか個人アカウントかを決める。チーム開発なら Organization。
- Organization なら Team を作り、メンバーを招待しておく。
- 2 要素認証を必須にする場合は、メンバーに事前に設定してもらう。
- リポジトリは `migrate.sh` が自動作成するので、手で作る必要はない。既に作ってある場合はそのまま流用される。

### ツールと認証

```bash
# macOS
brew install awscli gh git-lfs
aws configure            # CodeCommit を読める IAM ユーザー / ロール
gh auth login            # repo スコープ

# Windows (PowerShell)
winget install Amazon.AWSCLI GitHub.cli Git.Git GitHub.GitLFS
aws configure
gh auth login
```

## 1. 事前移行(リハーサル)

本番の切り替え前に一度まるごと移行し、問題を洗い出します。

```bash
# 何をするかだけ表示
./migrate.sh --region ap-northeast-1 --owner <org> --dry-run --all

# 実行(GitHub 側は private で作成)
./migrate.sh --region ap-northeast-1 --owner <org> --all
```

スクリプトは最後に両側の branches / tags の SHA を比較します。「検証 OK」が出れば履歴は完全に一致しています。
差分が出た場合は、ほとんどが「リハーサル後に CodeCommit 側へ push があった」ケースなので、本移行で再実行すれば解消します。

この時点で GitHub 上のリポジトリを使って、保護ルールや CI の設定を先に作り込んでおけます(フェーズ 4 を前倒しできる)。

## 2. 凍結(CodeCommit を読み取り専用に)

切り替え日に、CodeCommit への push を止めます。IAM で Deny を付けるのが確実です。

```json
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
```

このポリシーを、開発者が使う IAM ユーザー / ロール / グループにアタッチします。clone と pull は引き続きできます。

## 3. 本移行

リハーサルで作ったミラー(`./work/`)が残っていれば、差分だけ fetch して push されるので短時間で終わります。

```bash
./migrate.sh --region ap-northeast-1 --owner <org> --all
```

「検証 OK」を全リポジトリで確認したら、履歴の移行は完了です。

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

CodeStar Connections を使う場合、接続を作成したあと GitHub 側で「Pending」の承認(GitHub App のインストール)が必要です。AWS Console から「Update pending connection」で完了させます。

## 5. 利用者の切り替え

各開発者のローカルで remote を切り替えます。

```bash
git remote set-url origin https://github.com/<org>/<repo>.git
git fetch --prune origin
git branch -u origin/<branch>
```

案内文に含めるべきこと。

- 新しいリポジトリ URL の一覧
- CodeCommit が読み取り専用になった旨と、削除予定日
- GitHub の認証方法(Personal Access Token または SSH 鍵、`gh auth login`)
- 承認ルールとマージ手順の変更点
- CI の起動方法が変わる場合はその説明

## 6. 後片付け

2〜4 週間の並走期間を置き、CodeCommit への参照が残っていないことを確認してから削除します。

```bash
# 参照が残っていないかの確認例
aws codepipeline list-pipelines --region ap-northeast-1
aws codebuild list-projects --region ap-northeast-1
grep -r "git-codecommit" ~/.gitconfig ~/.ssh/config 2>/dev/null

# 削除
aws codecommit delete-repository --region ap-northeast-1 --repository-name <repo>
```

CodeCommit は新規受付を終了しているため、一度削除すると同じ名前で作り直せない可能性があります。削除前に `./work/<repo>.git` のミラーを別の場所に保管しておくと安心です。

## トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `fatal: unable to access ... 403` (CodeCommit) | IAM に `codecommit:GitPull` がない。または credential helper が効いていない。`git config --global --get-all credential.helper` で Git Credential Manager などが先に効いていないか確認 |
| `remote: error: GH013: Repository rule violations` (GitHub) | 先に Rulesets を作ってしまった。ミラー push の間だけ Rulesets を Disabled にするか、実行者を Bypass list に入れる |
| `error: failed to push some refs` で LFS 関連 | `git-lfs` 未インストール。インストールして再実行 |
| 検証で refs に差分 | リハーサル後に CodeCommit 側へ push があった。凍結してから再実行 |
| GitHub 側のデフォルトブランチが違う | `gh repo edit <owner>/<repo> --default-branch <name>` |
