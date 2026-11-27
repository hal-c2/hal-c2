package io.github.halc2.mobile;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;

// UnifiedPush's broadcasts from the distributor: an endpoint for this phone,
// which the app registers with its MC, and the MC's encrypted messages, which
// the push inbox opens and decides on. The system may start the process for
// this alone, without the app.
public final class PushReceiver extends BroadcastReceiver {
    private static native String receive(String dataDir, byte[] body, boolean permitted, int sdk);
    private static native void endpoint(String dataDir, String endpoint);

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (action == null) return;
        SharedPreferences preferences = Push.preferences(context);
        String token = preferences.getString("token", null);
        // Another registration's, or one this phone let go of.
        if (token == null || !token.equals(intent.getStringExtra("token"))) return;
        Push.load(context);
        String dataDir = Push.dataDir(context);
        switch (action) {
            case "org.unifiedpush.android.connector.NEW_ENDPOINT": {
                String url = intent.getStringExtra("endpoint");
                if (url != null) endpoint(dataDir, url);
                break;
            }
            case "org.unifiedpush.android.connector.UNREGISTERED":
            case "org.unifiedpush.android.connector.REGISTRATION_FAILED":
                preferences.edit().remove("token").apply();
                endpoint(dataDir, "");
                break;
            case "org.unifiedpush.android.connector.MESSAGE": {
                byte[] body = intent.getByteArrayExtra("bytesMessage");
                if (body != null) {
                    Push.show(context, receive(dataDir, body, Push.enabled(context), Build.VERSION.SDK_INT));
                }
                String id = intent.getStringExtra("id");
                String distributor = preferences.getString("distributor", null);
                if (id != null && distributor != null) {
                    context.sendBroadcast(new Intent(Push.MESSAGE_ACK).setPackage(distributor).putExtra("token", token).putExtra("id", id));
                }
                break;
            }
            default:
                break;
        }
    }
}
