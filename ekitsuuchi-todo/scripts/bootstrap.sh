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
  1. Config/Secrets.xcconfig を開き、PLACES_API_KEY に Google Places API (New) の鍵を入れる
     （鍵は Google Cloud で「iOS アプリ: dev.denkingon.ekitsuuchi」と「Places API (New) のみ」に制限する）。
     鍵を変えたら `xcodegen generate` は不要、Xcode で再ビルドすれば反映されます。
  2. open EkiTsuuchi.xcodeproj
     → EkiTsuuchi ターゲット > Signing & Capabilities > Team に自分の Apple ID（Personal Team）を選ぶ
     （project.yml の DEVELOPMENT_TEAM は個人情報を避けて空のままです）。
  3. iPhone をつなぎ、実機を選んで Run。初回は 設定 > 一般 > VPNとデバイス管理 で開発元を信頼。
  4. アプリの初回起動で、位置情報「常に」と通知を許可する。
     ジオフェンスは実機でしか確認できません（シミュレータでは駅入域の実測ができない）。
EOF
