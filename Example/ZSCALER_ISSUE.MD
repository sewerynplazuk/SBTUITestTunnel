# zscaler issue

Local traffic appears to be intercepted and thus severely delayed, severely slowing down HTTP-based client-server communication.

## Preconditoins

- XBTUITestTunnel must be configured to use HTTP protocol instead of IPC.

## Repro steps

### Install:
- Xcode 15.4 or higher
- iOS 17.5 SDK
- Create `iPhone 15 Pro` simulator

Alternatively adjust values in the `zscaler_test.sh` script to match the local environment.

### Run
`./zscaler_test.sh` - script will execute a test that attempts to make 200 HTTP calls on client launch.

### Expected result
Test passes with zscaler enabled

### Actual result
Test failes with zscaler enabled<br>
Test succceds with zscaler disabled
