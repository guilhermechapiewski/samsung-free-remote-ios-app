#!/bin/sh
# Build phase: fails the build unless SAMSUNG_REMOTE_MULTICAST is YES or NO and the entitlements file
# being signed in is the one that value selects (see Config/Base.xcconfig). Set only
# SAMSUNG_REMOTE_MULTICAST in Config/Local.xcconfig, never SAMSUNG_REMOTE_ENTITLEMENTS.
case "$SAMSUNG_REMOTE_MULTICAST" in
    YES) want="App/SamsungRemote/SamsungRemote+Multicast.entitlements" ;;
    NO) want="App/SamsungRemote/SamsungRemote.entitlements" ;;
    *)
        echo "error: SAMSUNG_REMOTE_MULTICAST must be YES or NO (got '$SAMSUNG_REMOTE_MULTICAST')."
        exit 1
        ;;
esac
if [ "$CODE_SIGN_ENTITLEMENTS" != "$want" ]; then
    echo "error: CODE_SIGN_ENTITLEMENTS is '$CODE_SIGN_ENTITLEMENTS' but SAMSUNG_REMOTE_MULTICAST=$SAMSUNG_REMOTE_MULTICAST needs '$want'. Set only SAMSUNG_REMOTE_MULTICAST in Config/Local.xcconfig."
    exit 1
fi
