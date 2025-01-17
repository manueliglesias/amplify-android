/*
 *  Copyright 2016-2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License").
 *  You may not use this file except in compliance with the License.
 *  A copy of the License is located at
 *
 *  http://aws.amazon.com/apache2.0
 *
 *  or in the "license" file accompanying this file. This file is distributed
 *  on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 *  express or implied. See the License for the specific language governing
 *  permissions and limitations under the License.
 *
 */

package com.amplifyframework.analytics.pinpoint.internal.core.util

import android.content.SharedPreferences
import com.amplifyframework.core.Amplify

private val LOG = Amplify.Logging.forNamespace("amplify:aws-analytics-pinpoint")
internal fun SharedPreferences.putString(key: String, value: String) {
    try {
        val editor = this.edit()
        editor.putString(key, value)
        editor.apply()
    } catch (ex: Exception) {
        // Do not log ex due to potentially sensitive information
        LOG.error("There was an exception when trying to store the unique id into the Preferences.")
    }
}
