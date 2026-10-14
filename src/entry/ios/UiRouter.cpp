#include "entry/ios/UiRouter.h"
#include "platform/ios/native/IPadUiPreferences.h"

UiRoute UiRouter::route(bool isIPad,
                        int availableShortSide,
                        const QStringList& arguments,
                        const QByteArray& nativeUiEnv,
                        const QByteArray& layoutEnv,
                        bool nativeUiPreference)
{
    const bool useNative = IPadUiPreferences::shouldUseNative(
        isIPad, arguments, nativeUiEnv, nativeUiPreference);

    if (useNative) {
        return UiRoute::Native;
    }

    if (layoutEnv == "companion") {
        return UiRoute::QmlCompanion;
    }
    if (layoutEnv == "full") {
        return UiRoute::QmlFull;
    }

    if (availableShortSide <= 0) {
        return UiRoute::QmlFull;
    }

    if (availableShortSide < 600) {
        return UiRoute::QmlCompanion;
    }

    return UiRoute::QmlFull;
}
