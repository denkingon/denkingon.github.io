#!/usr/bin/env bash
# macOS 用の初回セットアップ。何度流しても安全（既存の Secrets.xcconfig は上書きしない）。
#   bash scripts/bootstrap.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: このスクリプトは macOS 専用です（Xcode が要るため）。" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: Xcode が見つかりません。App Store から Xcode を入れて、一度起動してライセンスに同意してください。" >&2
  echo "       入っているのにこのエラーなら: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
xcodebuild -version

if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: xcodegen も Homebrew もありません。https://brew.sh を入れてから再実行してください。" >&2
    exit 1
  fi
  echo "xcodegen を brew で入れます..."
  brew install xcodegen
fi

if [[ ! -f Config/Secrets.xcconfig ]]; then
  cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
  echo "Config/Secrets.xcconfig を作りました（git には入りません）。"
else
  echo "Config/Secrets.xcconfig は既にあるのでそのままにします。"
fi

xcodegen generate

cat <<'EOF'

プロジェクトを生成しました: EkiTsuuchi.xcodeproj

あとは手作業です:
  1. Config/Secrets.xcconfig を開き、DEVELOPMENT_TEAM に署名の Team ID（10桁）を書く
     （Xcode > Settings > Accounts のチーム。無料の Personal Team でも実機に入ります。7日で失効）。
     ここに書けば `xcodegen generate` をやり直しても消えません（Xcode の画面で選んだ Team は再生成で消えます）。
     PLACES_API_KEY は M2（店・営業時間）から要ります。M1（駅→通知の実測）の間は空のままで構いません。
     M2 で鍵を作るときは Google Cloud で「iOS アプリ: dev.denkingon.ekitsuuchi」と「Places API (New) のみ」に制限する。
     鍵を変えたら `xcodegen generate` は不要、Xcode で再ビルドすれば反映されます。
  2. open EkiTsuuchi.xcodeproj → iPhone をつなぎ、実機を選んで Run。
     初回は iPhone の 設定 > 一般 > VPNとデバイス管理 で開発元を信頼。
  3. M1 の始め方（鍵もタスクも要りません）:
       「駅」タブ →「駅を追加」で使う駅を足す（位置情報は「Appの使用中は許可」。そのあと iPhone の
       設定アプリ > 駅通知todo > 位置情報 で「常に」と「正確な位置情報」オン）
       →「設定」タブで「実測モード」をオン（通知を許可）
       → 登録した駅の中にいる状態では入域は出ないので、一度外に出て入り直す
       → 1週間普段どおり移動して、「履歴」タブで発火の位置と時刻を見る。
     ジオフェンスは実機でしか確認できません（シミュレータでは駅入域の実測ができない）。
  詳しくは README.md の「段階ごとの使い方」。
EOF
