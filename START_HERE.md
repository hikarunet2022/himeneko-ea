# 再開手順

1. ZIPを展開し、フォルダをCodexの作業対象にする。チャット添付で読ませるだけの場合は、先にEA本体と CODEX_FIRST_PROMPT.md と HANDOFF.md を添付する。
2. CODEX_FIRST_PROMPT.mdの本文を最初の依頼として送る。
3. Codexでコード修正・差分確認・コンパイル診断を進め、MT5でバックテストする。
4. Workにはバックテスト集計、実際に使った.set、操作ログを戻し、同条件で比較する。

EA本体はこのセットでは未改変のV1.10。旧仕様への復元は次の作業。
Restore_D1_SL_DailyLimits.setは5入力だけを変更する暫定設定。完全な旧版D1判定を復元したコードではない。
OpenAI APIの接続は、このEAのファイル修正やMT5バックテストの前提ではない。Codex環境にMetaEditor/MT5があるかは未確認。
