# GitHub でマージを制御する: 承認数・マージできる人・Copilot の扱い

CodeCommit の承認ルールテンプレートに相当するものは、GitHub では **Rulesets**(推奨)または **Branch protection rules**(旧方式)で設定します。この文書は Rulesets を前提に、よく使う 3 つの要件の設定方法と、GitHub Copilot を併用するときの注意点をまとめます。

場所: リポジトリの **Settings → Rules → Rulesets → New ruleset → New branch ruleset**。
Organization 単位で複数リポジトリにまとめて適用する場合は **Organization settings → Repository → Rulesets**。

## 1. 承認数を設定する

ルールセットで **Require a pull request before merging** を有効にし、次を設定します。

| 設定 | 意味 | 推奨 |
|---|---|---|
| Required approvals | マージに必要な承認レビュー数 | 1〜2 |
| Dismiss stale pull request approvals when new commits are pushed | 承認後に push があったら承認を取り消す | ON |
| Require review from Code Owners | CODEOWNERS に書かれた担当者の承認を必須にする | 担当領域が分かれているなら ON |
| Require approval of the most recent reviewable push | 最後に push した人以外の承認を必須にする(自分の変更を自分で承認させない) | ON |
| Require conversation resolution before merging | レビューコメントをすべて解決しないとマージ不可 | ON |
| Allowed merge methods | merge / squash / rebase のどれを許すか | チーム方針に合わせる |

補足として、PR の作者は自分の PR を承認できません。これは GitHub 側の仕様で、設定不要です。

### CODEOWNERS の例

リポジトリ直下、`.github/`、`docs/` のいずれかに `CODEOWNERS` を置きます。

```
# パス            担当(ユーザー or チーム)
*                 @my-org/dev-team
/infra/           @my-org/sre-team
/docs/            @my-org/docs-team
```

**Require review from Code Owners** を ON にすると、変更されたパスの担当者の承認が必須になります。

### Required reviewers(パス単位で特定チームの承認を必須にする)

ルールセットの **Required reviewers** を使うと、「このパスを触る PR は必ずこのチームが承認する」を最大 15 チームまで設定できます。CODEOWNERS と似ていますが、ルールセット側で一元管理できる点が違います。

## 2. 特定のユーザーしかマージできないようにする

GitHub では「マージ」は「保護ブランチへの書き込み」です。したがって、マージできる人を限定するには **ブランチへの更新を制限し、許可する人だけをバイパス対象にする** のが正解です。

1. ルールセットの **Restrict updates** を有効にする。これでそのブランチへの直接 push と PR マージの両方が止まります。
2. **Bypass list** に、マージを許可するユーザー、チーム、ロール(例: Maintain 以上)を追加する。
3. バイパスの種類は **Always allow** ではなく **Allow for pull requests only** にしておくと、許可された人でも直接 push はできず、PR 経由のマージだけが可能になります。

これにより「承認は誰でもできるが、マージボタンを押せるのはリリース担当だけ」という運用が作れます。

旧方式の Branch protection rules でも **Restrict who can push to matching branches** で同じことができますが、Rulesets の方がバイパスの粒度が細かく、Organization でまとめて適用できるので、新規に設定するなら Rulesets を使ってください。

### CodeCommit の承認ルールからの対応表

| CodeCommit | GitHub Rulesets |
|---|---|
| 承認ルールテンプレートの「必要な承認数」 | Required approvals |
| 承認プールメンバー(承認できる人の限定) | Required reviewers / CODEOWNERS + Require review from Code Owners |
| IAM で `codecommit:MergePullRequest...` を許可した人だけマージ可 | Restrict updates + Bypass list |
| 承認の無効化(新しいコミットで承認をリセット) | Dismiss stale pull request approvals |

## 3. GitHub Copilot を使うときの注意点

### Copilot のレビューは既定では承認数に数えられない

Copilot code review は既定では **Required approvals にカウントされません**。人間の承認が必要なままです。
「Copilot approvals」を有効にすると Copilot の承認が人間の承認と同じ扱いになりますが、これは public preview の機能で、リポジトリ・Organization・Enterprise の設定でそれぞれ有効化が必要です。Copilot 承認後に新しいコミットが push されると承認は取り消されます。

監査要件がある場合は、Copilot approvals は無効のままにし、人間の承認のみをカウントする運用を推奨します。

### Copilot が作った PR には追加承認が要求される

ルールセットの **Require an additional approval for unattributed Copilot pull requests** が既定で有効です。人に紐づかない Copilot の PR には、通常の承認数に加えてもう 1 つ承認が必要になります。Copilot coding agent を多用する場合、承認数を 1 に設定していても実質 2 名の承認が必要になることを把握しておいてください。

### Copilot coding agent がルールに弾かれる場合

ルールセットが Copilot と互換性がないと、Copilot coding agent 自体が使えなくなります。たとえばコミット作者を特定ユーザーに限定するルールがあると、Copilot が PR を作成・更新できません。その場合はルールセットの Bypass list に Copilot を追加します。

ただし Copilot をバイパスに入れるのは「PR の作成と更新」を許すためであって、Copilot にマージ権限を与えるものではありません。マージは引き続き人間が行い、承認数のルールも適用されます。

### Copilot の PR で GitHub Actions を動かすとき

Copilot coding agent が開いた PR では、ワークフローは自動実行されず、人が **Approve and run** を押す必要があります。CI を必須チェックにしている場合、この承認を忘れるとマージできない状態が続くので、レビュー手順に組み込んでください。

## 4. 推奨構成(例)

main ブランチ向けのルールセット。

- Require a pull request before merging: ON
  - Required approvals: 1
  - Dismiss stale approvals: ON
  - Require review from Code Owners: ON
  - Require approval of the most recent reviewable push: ON
  - Require conversation resolution: ON
- Require status checks to pass: ON(CI のジョブ名を指定)
- Block force pushes: ON(既定)
- Restrict deletions: ON
- Restrict updates: ON
  - Bypass list: release チーム(Allow for pull requests only)
- Require an additional approval for unattributed Copilot pull requests: ON(既定)

### API / CLI で作る場合

```bash
gh api -X POST repos/<owner>/<repo>/rulesets --input - <<'JSON'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": <team-id>, "actor_type": "Team", "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "update" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "ci" } ]
      }
    }
  ]
}
JSON
```

チーム ID は `gh api orgs/<org>/teams/<slug> --jq .id` で取得できます。

## 参考

- [Available rules for rulesets (GitHub Docs)](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- [About code review with Copilot (GitHub Docs)](https://docs.github.com/en/copilot/concepts/code-review/code-review)
- [About Copilot coding agent (GitHub Docs)](https://docs.github.com/en/copilot/concepts/agents/coding-agent/about-coding-agent)
- [About code owners (GitHub Docs)](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
