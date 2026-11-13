#!/bin/sh
# Build the iPhone app and get it ready for TestFlight. See BuildOSX.txt.
#
#   tools/build_ios.sh TEAM_ID [BUNDLE_ID]
#
# TEAM_ID    10-character Apple Team ID (developer.apple.com/account ->
#            Membership details).
# BUNDLE_ID  App ID to publish under (default edu.stanford.reil.mountainRoads).
#            Must match the app created in App Store Connect.
#
# Optional automatic upload: set ASC_KEY_ID and ASC_ISSUER_ID (App Store
# Connect API key, with AuthKey_<ASC_KEY_ID>.p8 in ~/.appstoreconnect/private_keys/).
# Without them, Xcode's Organizer opens on the build: click Distribute App.
set -e

TEAM=${1:?usage: tools/build_ios.sh TEAM_ID [BUNDLE_ID]}
BUNDLE=${2:-edu.stanford.reil.mountainRoads}
cd "$(dirname "$0")/.."

# Use the full Xcode even if the command line tools are selected.
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
for tool in flutter pod xcodebuild; do
  command -v $tool >/dev/null || { echo "Missing $tool: see BuildOSX.txt step 1"; exit 1; }
done
xcodebuild -license check >/dev/null 2>&1 || {
  echo "Xcode is not ready. Run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept"
  echo "then open Xcode once."
  exit 1
}
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || {
  echo "Xcode needs its first-launch setup. Run: sudo xcodebuild -runFirstLaunch"
  exit 1
}

case "$(pwd -P)" in
  */Library/CloudStorage/*|*/Mobile\ Documents/*|*/Dropbox/*)
    echo "This folder is cloud-synced; code signing fails there. Clone the project to e.g. ~/mountainroads."
    exit 1 ;;
esac

# Team and bundle ID for this developer only (ignored by git).
cat > ios/Flutter/Signing.xcconfig <<EOF
DEVELOPMENT_TEAM = $TEAM
MR_BUNDLE_ID = $BUNDLE
CODE_SIGN_STYLE = Automatic
EOF

# Each upload needs a new build number: use the date and time.
BUILD_NUMBER=$(date +%Y%m%d%H%M)
flutter pub get
flutter build ipa --release --build-number="$BUILD_NUMBER"

IPA=$(ls build/ios/ipa/*.ipa | head -1)
echo
echo "Built $IPA (build $BUILD_NUMBER, bundle $BUNDLE)"

if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ]; then
  echo "Uploading to App Store Connect..."
  xcrun altool --upload-app --type ios --file "$IPA" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "Uploaded. It appears in App Store Connect -> TestFlight in 5-30 minutes."
else
  echo "Opening Xcode Organizer: choose Distribute App -> App Store Connect -> Upload."
  open build/ios/archive/Runner.xcarchive
fi
