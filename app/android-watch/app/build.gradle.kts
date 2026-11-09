plugins {
    id("com.android.application")
}

android {
    namespace = "com.haowang.wristnote"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.haowang.wristnote"
        minSdk = 23
        targetSdk = 31
        versionCode = 1000010
        versionName = "0.1.10"

        buildConfigField("String", "PHONE_BASE", "\"ble://wanji\"")
    }

    buildFeatures {
        buildConfig = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    buildTypes {
        release {
            isDebuggable = false
            isMinifyEnabled = false
        }
    }

    lint {
        checkReleaseBuilds = false
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}
