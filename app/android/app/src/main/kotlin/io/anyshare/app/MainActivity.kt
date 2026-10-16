package io.anyshare.app

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone


private const val CHANNEL = "org.localsend.localsend_app/localsend"
private const val REQUEST_CODE_PICK_DIRECTORY = 1
private const val REQUEST_CODE_PICK_DIRECTORY_PATH = 2
private const val REQUEST_CODE_PICK_FILE = 3
private const val REQUEST_CODE_LOCAL_NETWORK = 4

// AnyShare modification (2026-10-15): transfer-complete notification.
private const val NOTIFICATION_CHANNEL_TRANSFER_COMPLETE = "transfer_complete"
private const val NOTIFICATION_ID_TRANSFER_COMPLETE = 2
private const val EXTRA_NOTIFICATION_FOLDER = "io.anyshare.app.extra.notificationFolderPath"
private const val EXTRA_NOTIFICATION_FILE = "io.anyshare.app.extra.notificationFileName"

// Not available as a constant in compileSdk 36.
private const val PERMISSION_ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
private const val API_LEVEL_ANDROID_17 = 37

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// share_handler drops share intents arriving via onNewIntent while the Dart side
    /// is not subscribed to its media stream yet, which happens when this singleTask
    /// activity is relaunched into an existing task while the app is still starting.
    /// Hold such intents back until Dart reports readiness ("shareIntentReady"), then
    /// replay them through the regular plugin path.
    private val pendingShareIntents = mutableListOf<Intent>()
    private var shareIntentReady = false

    /// AnyShare modification (2026-10-15): the MethodChannel is kept around so that a
    /// transfer-complete notification tap can be forwarded to the Dart side.
    private var methodChannel: MethodChannel? = null

    /// A notification tap that arrived before the Dart side registered its handler
    /// (e.g. when the tap started the app). Replayed once Dart reports readiness.
    private var pendingNotificationTap: Map<String, String?>? = null
    private var transferNotificationReady = false

    override fun onNewIntent(intent: Intent) {
        captureNotificationTap(intent)
        if (!shareIntentReady && (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE)) {
            pendingShareIntents.add(intent)
            return
        }
        super.onNewIntent(intent)
    }

    /// Reads a transfer-complete notification tap out of [intent] (if any) and holds
    /// it until the Dart side is listening.
    private fun captureNotificationTap(intent: Intent?) {
        val folderPath = intent?.getStringExtra(EXTRA_NOTIFICATION_FOLDER) ?: return
        pendingNotificationTap = mapOf(
            "folderPath" to folderPath,
            "fileName" to intent.getStringExtra(EXTRA_NOTIFICATION_FILE),
        )
        // The intent instance can be redelivered; a tap must not be replayed twice.
        intent.removeExtra(EXTRA_NOTIFICATION_FOLDER)
        intent.removeExtra(EXTRA_NOTIFICATION_FILE)
        flushPendingNotificationTap()
    }

    private fun flushPendingNotificationTap() {
        if (!transferNotificationReady) {
            return
        }
        val tap = pendingNotificationTap ?: return
        pendingNotificationTap = null
        methodChannel?.invokeMethod("transferCompleteNotificationTapped", tap)
    }

    private fun onShareIntentReady() {
        shareIntentReady = true
        val pending = pendingShareIntents.toList()
        pendingShareIntents.clear()
        for (intent in pending) {
            super.onNewIntent(intent)
        }
    }

    // Overriding the static methods we need from the Java class, as described
    // in the documentation of `FlutterActivity.NewEngineIntentBuilder`
    companion object {
        fun withNewEngine(): NewEngineIntentBuilder {
            return NewEngineIntentBuilder(MainActivity::class.java)
        }

        fun createDefaultIntent(launchContext: Context): Intent {
            return withNewEngine().build(launchContext)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        methodChannel = channel
        // The tap that launched the app (if any) is handled like a tap arriving later on:
        // held back until the Dart side reports readiness.
        captureNotificationTap(intent)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = false)
                }

                "pickFiles" -> {
                    pendingResult = result
                    openFilePicker()
                }

                "pickDirectoryPath" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = true)
                }

                "createDirectory" -> handleCreateDirectory(call, result)

                "getFileDescriptor" -> handleGetFileDescriptor(call, result)

                "createFile" -> handleCreateFile(call, result)

                "openFileForWriting" -> handleOpenFileForWriting(call, result)

                "openContentUri" -> {
                    openUri(context, call.argument<String>("uri")!!)
                    result.success(null)
                }

                "openGallery" -> {
                    openGallery()
                    result.success(null)
                }

                "shareIntentReady" -> {
                    onShareIntentReady()
                    result.success(null)
                }

                "showTransferCompleteNotification" -> handleShowTransferCompleteNotification(call, result)

                "transferNotificationReady" -> {
                    transferNotificationReady = true
                    flushPendingNotificationTap()
                    result.success(null)
                }

                "isAnimationsEnabled" -> {
                    result.success(isAnimationsEnabled())
                }

                "getDownloadsDirectory" -> {
                    result.success(getDownloadsDirectory())
                }

                "requestLocalNetworkPermission" -> {
                    if (hasLocalNetworkPermission()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestPermissions(arrayOf(PERMISSION_ACCESS_LOCAL_NETWORK), REQUEST_CODE_LOCAL_NETWORK)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /// Android 17+ gates local network access behind a runtime permission; older versions grant it implicitly.
    private fun hasLocalNetworkPermission(): Boolean {
        if (Build.VERSION.SDK_INT < API_LEVEL_ANDROID_17) {
            return true
        }
        return checkSelfPermission(PERMISSION_ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_LOCAL_NETWORK) {
            pendingPermissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermissionResult = null
        }
    }

    /// Absolute path of the shared "Download" directory (usually /storage/emulated/0/Download).
    @Suppress("DEPRECATION")
    private fun getDownloadsDirectory(): String {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
    }

    private fun isAnimationsEnabled() : Boolean {
        return Settings.Global.getFloat(this.getContentResolver(),
            Settings.Global.ANIMATOR_DURATION_SCALE, 1.0f) != 0.0f;
    }

    private fun handleGetFileDescriptor(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "r")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            // Ownership of the detached descriptor is transferred to the caller. It must be
            // closed by Rust (or whichever native consumer receives it) after use.
            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    /// Creates a new file inside a SAF directory and opens it for writing.
    ///
    /// Returns the URI of the created document (Android may rename the file on
    /// collisions) and an owned writable file descriptor. The descriptor must be
    /// closed by the native consumer it is passed to.
    private fun handleCreateFile(call: MethodCall, result: MethodChannel.Result) {
        val parentUriString = call.argument<String>("parentUri")
        val fileName = call.argument<String>("fileName")
        if (parentUriString == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Missing parentUri or fileName", null)
            return
        }

        try {
            val parentUri = Uri.parse(parentUriString)

            // A pure tree URI (content://…/tree/X) must be converted to its
            // document form before it can be used as a parent document.
            val segments = parentUri.pathSegments
            val parentDocumentUri = if (segments.size == 2 && segments[0] == "tree") {
                DocumentsContract.buildDocumentUriUsingTree(
                    parentUri,
                    DocumentsContract.getTreeDocumentId(parentUri)
                )
            } else {
                parentUri
            }

            // Providers append an extension when the MIME type does not match the one Android maps the
            // file's extension to (e.g. "test.conf" as text/plain becomes "test.conf.txt"), so derive it
            // from the same map. application/octet-stream keeps the name as-is for unknown extensions.
            val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
            val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: "application/octet-stream"

            val documentUri =
                DocumentsContract.createDocument(contentResolver, parentDocumentUri, mimeType, fileName)
            if (documentUri == null) {
                result.error("CREATE_FAILED", "Could not create $fileName in $parentUriString", null)
                return
            }

            // "wt" is write + truncate: the document is new, unless the provider
            // handed out an existing one instead of creating a second document.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(documentUri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(
                    mapOf(
                        "uri" to documentUri.toString(),
                        "fd" to it.detachFd(),
                    )
                )
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("CREATE_FAILED", e.message ?: "Failed to create file", null)
        }
    }

    /// Opens an existing document created by [handleCreateFile] for writing,
    /// discarding its current content.
    ///
    /// Used to write a file again after a failed attempt, so that it keeps its
    /// name instead of being created a second time under a numbered one.
    ///
    /// Returns an owned writable file descriptor. It stays open after this call
    /// and must be closed by the native consumer it is passed to.
    private fun handleOpenFileForWriting(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            // "wt" is write + truncate. A document provider may ignore the
            // truncation, so the writer additionally shortens the file itself.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    private fun openDirectoryPicker(onlyPath: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        startActivityForResult(
            intent,
            if (onlyPath) REQUEST_CODE_PICK_DIRECTORY_PATH else REQUEST_CODE_PICK_DIRECTORY
        )
    }

    private fun openFilePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra("multi-pick", true)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_CODE_PICK_FILE)
    }

    @SuppressLint("WrongConstant")
    @Override
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == Activity.RESULT_CANCELED) {
            pendingResult?.error("CANCELED", "Canceled", null)
            pendingResult = null
            return
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult?.error("Error $resultCode", "Failed to access directory or file", null)
            pendingResult = null
            return
        }

        when (requestCode) {
            REQUEST_CODE_PICK_DIRECTORY -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)

                    val files = mutableListOf<FileInfo>()
                    listFiles(uri, files)
                    val resultData = PickDirectoryResult(uri.toString(), files)
                    pendingResult?.success(resultData.toMap())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_DIRECTORY_PATH -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    pendingResult?.success(uri.toString())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_FILE -> {
                val uriList: List<Uri> = when {
                    data.clipData != null -> {
                        val clipData = data.clipData
                        val uris = mutableListOf<Uri>()
                        for (i in 0 until clipData!!.itemCount) {
                            uris.add(clipData.getItemAt(i).uri)
                        }
                        uris
                    }

                    data.data != null -> listOf(data.data!!)
                    else -> {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                }

                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

                val resultList = mutableListOf<FileInfo>()
                for (uri in uriList) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    val documentFile = FastDocumentFile.fromDocumentUri(this, uri)
                    if (documentFile == null) {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                    resultList.add(
                        FileInfo(
                            name = documentFile.name,
                            size = documentFile.size,
                            uri = uri.toString(),
                            lastModified = documentFile.lastModified?.toRfc3339(),
                        )
                    )
                }

                pendingResult?.success(resultList.map { it.toMap() })
                pendingResult = null
            }
        }
    }

    private fun listFiles(uri: Uri, files: MutableList<FileInfo>) {
        val pickedDir: FastDocumentFile = FastDocumentFile.fromTreeUri(this, uri)

        for (file in pickedDir.listFiles()) {
            if (file.isDirectory) {
                // Recursive call
                listFiles(file.uri, files)
            } else if (file.isFile) {
                files.add(
                    FileInfo(
                        name = file.name,
                        size = file.size,
                        uri = file.uri.toString(),
                        lastModified = file.lastModified?.toRfc3339(),
                    ),
                )
            }
        }
    }

    @SuppressLint("WrongConstant")
    private fun handleCreateDirectory(call: MethodCall, result: MethodChannel.Result) {
        val documentUri = Uri.parse(call.argument<String>("documentUri")!!)
        val directoryName = call.argument<String>("directoryName")!!

        if (folderExists(documentUri, directoryName)) {
            result.success(null)
            return
        }

        DocumentsContract.createDocument(
            context.contentResolver, documentUri, DocumentsContract.Document.MIME_TYPE_DIR,
            directoryName
        )

        result.success(null)
    }

    private fun folderExists(documentUri: Uri, folderName: String): Boolean {
        var cursor: Cursor? = null
        try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(documentUri, DocumentsContract.getDocumentId(documentUri))
            cursor = contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null,
                null,
                null,
            )

            if (cursor != null) {
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0)
                    val mimeType = cursor.getString(1)

                    if (folderName == displayName && DocumentsContract.Document.MIME_TYPE_DIR == mimeType) {
                        return true
                    }
                }
            }
        } finally {
            cursor?.close()
        }
        return false
    }

    private fun openGallery() {
        val intent = Intent()
        intent.action = Intent.ACTION_VIEW
        intent.type = "image/*"
        startActivity(intent)
    }

    /// AnyShare modification (2026-10-15): shows the "transfer complete" notification.
    /// Tapping it opens [folderPath] (and selects [fileName]) through the Dart side.
    ///
    /// Silently does nothing when the POST_NOTIFICATIONS permission (Android 13+) was
    /// denied: the foreground service asks for it when a transfer starts, and a transfer
    /// must never fail over a missing notification.
    private fun handleShowTransferCompleteNotification(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        if (title == null || body == null) {
            result.error("INVALID_ARGUMENT", "Missing title or body", null)
            return
        }

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(null)
            return
        }

        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Only the first creation defines the channel; later name changes are ignored by Android.
                val channelName = call.argument<String>("channelName") ?: title
                manager.createNotificationChannel(
                    NotificationChannel(NOTIFICATION_CHANNEL_TRANSFER_COMPLETE, channelName, NotificationManager.IMPORTANCE_DEFAULT)
                )
            }

            val tapIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_NOTIFICATION_FOLDER, call.argument<String>("folderPath"))
                putExtra(EXTRA_NOTIFICATION_FILE, call.argument<String>("fileName"))
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, NOTIFICATION_CHANNEL_TRANSFER_COMPLETE)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }

            val notification = builder
                .setSmallIcon(R.drawable.ic_stat_transfer)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()

            manager.notify(NOTIFICATION_ID_TRANSFER_COMPLETE, notification)
            result.success(null)
        } catch (e: Exception) {
            result.error("NOTIFICATION_FAILED", e.message ?: "Failed to show the notification", null)
        }
    }
}

data class PickDirectoryResult(
    val directoryUri: String,
    val files: List<FileInfo>,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "directoryUri" to directoryUri,
            "files" to files.map { it.toMap() }
        )
    }
}

data class FileInfo(
    val name: String,
    val size: Long,
    val uri: String,
    val lastModified: String?
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "name" to name,
            "size" to size,
            "uri" to uri,
            "lastModified" to lastModified
        )
    }
}

/// Formats milliseconds since epoch as an RFC 3339 string in UTC.
private fun Long.toRfc3339(): String {
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    format.timeZone = TimeZone.getTimeZone("UTC")
    return format.format(Date(this))
}
