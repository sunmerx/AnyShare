package io.anyshare.e2spike

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 96, 48, 48)
        }

        layout.addView(
            TextView(this).apply {
                text = "E2 spike harness\n\n1. Enable the accessibility service\n2. Grant the overlay permission\nThen drive it with adb broadcasts (see docs)."
                textSize = 18f
            },
        )

        layout.addView(
            EditText(this).apply {
                hint = "focus me for set-text injection test"
                id = android.R.id.edit
            },
        )

        layout.addView(
            Button(this).apply {
                text = "Open accessibility settings"
                setOnClickListener {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                }
            },
        )

        layout.addView(
            Button(this).apply {
                text = "Request overlay permission"
                setOnClickListener {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                }
            },
        )

        setContentView(layout)
    }
}
