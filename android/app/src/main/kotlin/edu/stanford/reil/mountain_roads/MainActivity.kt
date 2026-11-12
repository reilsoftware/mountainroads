package edu.stanford.reil.mountain_roads

import android.content.ActivityNotFoundException
import android.content.Intent
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.google.android.gms.common.api.ResolvableApiException
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.LocationSettingsRequest
import com.google.android.gms.location.Priority
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Settings-screen helpers the Flutter plugins don't cover:
 * - googleAccuracy: is Google Location Accuracy on (high-accuracy fused location allowed)?
 * - enableGoogleAccuracy: show Google's own "turn on Location Accuracy" dialog.
 * - openSettings(page): open a specific Android settings page.
 */
class MainActivity : FlutterActivity() {
    private val accuracyRequestCode = 4101
    private var pendingEnable: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mountain_roads/settings")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "googleAccuracy" -> checkAccuracy { ok, _ -> result.success(ok) }
                    "enableGoogleAccuracy" -> enableAccuracy(result)
                    "openSettings" -> result.success(openSettings(call.argument<String>("page") ?: "app"))
                    else -> result.notImplemented()
                }
            }
    }

    private fun locationSettingsRequest() = LocationSettingsRequest.Builder()
        .addLocationRequest(LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000).build())
        .setAlwaysShow(true)
        .build()

    /** Calls back (ok, resolvable exception if Google can fix it with a dialog). */
    private fun checkAccuracy(done: (Boolean, ResolvableApiException?) -> Unit) {
        LocationServices.getSettingsClient(this).checkLocationSettings(locationSettingsRequest())
            .addOnSuccessListener { done(networkLocationOn(), null) }
            .addOnFailureListener { e -> done(false, e as? ResolvableApiException) }
    }

    /** When Google Location Accuracy is off, the network provider is off too. */
    private fun networkLocationOn(): Boolean {
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        return try {
            lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (e: Exception) {
            false
        }
    }

    private fun enableAccuracy(result: MethodChannel.Result) {
        checkAccuracy { ok, resolvable ->
            when {
                ok -> result.success(true)
                resolvable != null -> try {
                    pendingEnable = result
                    resolvable.startResolutionForResult(this, accuracyRequestCode)
                } catch (e: Exception) {
                    pendingEnable = null
                    result.success(openSettings("googleAccuracy"))
                }
                // Google can't show its dialog: send the user to the page instead.
                else -> {
                    openSettings("googleAccuracy")
                    result.success(false)
                }
            }
        }
    }

    @Deprecated("Needed for startResolutionForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == accuracyRequestCode) {
            pendingEnable?.success(resultCode == RESULT_OK)
            pendingEnable = null
        }
    }

    private fun openSettings(page: String): Boolean {
        val pkg = Uri.fromParts("package", packageName, null)
        val intents = when (page) {
            "notifications" -> listOf(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            )
            "battery" -> listOf(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            "allFiles" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                listOf(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, pkg))
            } else {
                emptyList()
            }
            "location" -> listOf(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
            // Google's own page first; the main Location page lists it otherwise.
            "googleAccuracy" -> listOf(
                Intent("com.google.android.gms.location.settings.LOCATION_ACCURACY"),
                Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS),
            )
            else -> emptyList()
        } + Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg) // fallback: app info
        for (intent in intents) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: ActivityNotFoundException) {
                // try the next one
            }
        }
        return false
    }
}
