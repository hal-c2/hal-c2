package io.github.halc2.mobile;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

// The activity card was swiped away or its dismiss action tapped: the inbox
// keeps it away until a run starts again.
public final class DismissReceiver extends BroadcastReceiver {
    private static native String dismiss(String dataDir);

    @Override
    public void onReceive(Context context, Intent intent) {
        Push.load(context);
        Push.show(context, dismiss(Push.dataDir(context)));
    }
}
