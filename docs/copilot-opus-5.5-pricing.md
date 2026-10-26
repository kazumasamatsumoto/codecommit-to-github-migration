# GitHub Copilot: Claude Opus 5.5 の利用料金まとめ

GitHub Copilot のモデル別単価のうち、Claude Opus 5.5 についてのまとめです。
Copilot はトークン量に応じてクレジットを消費します。1 クレジットは 0.01 ドルです。

2026-10-26 時点で、単価・プランの枠・補足の各項目を GitHub Docs と Anthropic の料金ページに照合済みです。

## Opus 5.5 の単価とクレジットへの換算

Claude Opus 5.5 は、100 万トークンあたり入力 4 ドル、キャッシュ入力 0.20 ドル、キャッシュ書き込み 5 ドル、出力 20 ドルです。長文脈による割増ティアはなく、一律料金です。

| 種別 | 100万トークンあたり | 1,000トークンあたり |
|---|---|---|
| 入力(通常) | 400クレジット | 0.4クレジット |
| キャッシュ入力(再利用分) | 20クレジット | 0.02クレジット |
| キャッシュ書き込み | 500クレジット | 0.5クレジット |
| 出力 | 2,000クレジット | 2クレジット |

## 利用量の目安(試算)

- 入力 10 万トークン(キャッシュなし)で 40 クレジットです。
- 出力 1 万トークンで 20 クレジットです。
- 一般的なエージェント作業の 1 リクエスト(入力 5 万トークン、うち 4 万がキャッシュ、出力 3,000 トークン)なら、約 11 クレジット(約 0.11 ドル)です。内訳は、通常入力 1 万で 4、キャッシュ入力 4 万で 0.8、出力 3,000 で 6 です。
- キャッシュが効かず、毎回コンテキストを丸ごと入力し直す使い方だと、同じ 5 万トークンの入力でも約 20 クレジットになります。
- エージェントは 1 回の指示で複数回のリクエストを内部で行うため、1 タスクで数十〜数百クレジットになることもあります。

## 各プランの枠との比較

| プラン | 含まれるクレジット | 通常入力のみの場合の目安 | 出力のみの場合の目安 |
|---|---|---|---|
| Pro+ | 7,000 | 約1,750万トークン | 約350万トークン |
| Business | 1,900/人 | 約475万トークン | 約95万トークン |
| Enterprise | 3,900/人 | 約975万トークン | 約195万トークン |

通常の入力と出力が混ざる実際の使い方では、これより少なくなります。たとえば、Business(1,900 クレジット)で「1 回あたり約 11 クレジット」のリクエストなら、1 人あたり約 170 回分です。

## 補足

- 前世代の Opus 5 は入力 5 ドル、出力 25 ドルなので、Opus 5.5 は約 2 割安いことになります。
- Opus 5.5 は、Pro+、Max、Business、Enterprise で使えます。Pro は対象外です。Free と Student は自動モデル選択経由のみです。
- 補完(コード補完や次の編集提案)はクレジットを消費せず、有料プランでは使い放題です。
- code review では、使用モデルが自動選択で非公開のため、レビューごとのトークン単価は変わり得ます。
- Business と Enterprise では、各ライセンスのクレジットが課金単位(組織・Enterprise)のプールに集約され、消費はそのプールから引かれます。

## 出典

- [Models and pricing for GitHub Copilot (GitHub Docs)](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing) : モデル別単価、クレジット単価、補完・code review の扱い
- [Plans for GitHub Copilot (GitHub Docs)](https://docs.github.com/en/copilot/get-started/plans) : 各プランの月額と含まれるクレジット
- [Supported AI models in Copilot (GitHub Docs)](https://docs.github.com/en/copilot/reference/ai-models/supported-models) : プラン別のモデル提供状況
- [Billing for organizations and enterprises (GitHub Docs)](https://docs.github.com/en/copilot/concepts/billing/organizations-and-enterprises) : Business / Enterprise のクレジットプール
- [Anthropic Pricing (Claude Platform Docs)](https://platform.claude.com/docs/en/about-claude/pricing) : Opus 5.5 と Opus 5 の API 単価

## 検証メモ (2026-10-26)

| 項目 | 結果 |
|---|---|
| 1 クレジット = 0.01 ドル | GitHub Docs に明記 |
| Opus 5.5 単価 4 / 0.20 / 5 / 20 ドル、長文脈ティアなし | GitHub Docs の表と一致。Anthropic の API 単価とも同額 |
| Opus 5 単価 5 / 0.50 / 6.25 / 25 ドル | GitHub Docs と Anthropic の両方で一致。Opus 5.5 は入出力とも 2 割安 |
| プランの枠 Pro+ 7,000 / Business 1,900 / Enterprise 3,900 | GitHub Docs と一致。参考: Pro 1,500、Max 20,000 |
| プラン別の提供状況 | GitHub Docs の表で Pro+、Max、Business、Enterprise が対象。Pro は対象外 |
| 補完はクレジット消費なし、有料プランで無制限 | GitHub Docs に明記 |
| code review のモデルは自動選択で非公開 | GitHub Docs に明記 |
| Business / Enterprise はプール課金 | GitHub Docs に明記 |
| 試算の計算 | 単価から再計算して一致 (1 リクエスト 10.8 クレジット、Business で約 172 回) |

元の下書きが参照していた TechJack Solutions の記事は取得できなかった(HTTP 403)ため、Anthropic の公式料金ページに差し替えました。

料金は変更される可能性があるため、最新の情報は GitHub Docs を確認してください。
