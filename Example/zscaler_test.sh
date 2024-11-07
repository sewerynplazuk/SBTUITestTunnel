readonly SIM_NAME="iPhone 15 Pro"
readonly OS_VERSION="17.5"

xcodebuild -workspace SBTUITestTunnel.xcworkspace -scheme SBTUITestTunnel_Tests -only-testing:SBTUITestTunnel_Tests/MiscellaneousTests/testLaunchTimeWithUserDefaults -destination "platform=iOS Simulator,name=${SIM_NAME},OS=${OS_VERSION}" test