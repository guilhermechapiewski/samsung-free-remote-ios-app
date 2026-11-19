#!/bin/sh
# Build phase: fails the build unless FREE_REMOTE_MULTICAST is YES or NO and the entitlements file
# being signed in is the one that value selects (see Config/Base.xcconfig). Set only
# FREE_REMOTE_MULTICAST in Config/Local.xcconfig, never FREE_REMOTE_ENTITLEMENTS.
case "$FREE_REMOTE_MULTICAST" in
    YES) want="App/FreeRemote/FreeRemote+Multicast.entitlements" ;;
    NO) want="App/FreeRemote/FreeRemote.entitlements" ;;
    *)
        echo "error: FREE_REMOTE_MULTICAST must be YES or NO (got '$FREE_REMOTE_MULTICAST')."
        exit 1
        ;;
esac
if [ "$CODE_SIGN_ENTITLEMENTS" != "$want" ]; then
    echo "error: CODE_SIGN_ENTITLEMENTS is '$CODE_SIGN_ENTITLEMENTS' but FREE_REMOTE_MULTICAST=$FREE_REMOTE_MULTICAST needs '$want'. Set only FREE_REMOTE_MULTICAST in Config/Local.xcconfig."
    exit 1
fi
