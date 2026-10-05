#!/usr/bin/env bash
# Builds the app with the JDK and SDK it needs, whatever the shell's
# environment says: mobile/build.sh [gradle arguments, default assembleDebug]
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [ -z "${JAVA_HOME:-}" ] || ! "$JAVA_HOME/bin/java" -version 2>&1 | grep -qE '"(17|21)\.'; then
	for candidate in /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-17-openjdk; do
		[ -x "$candidate/bin/java" ] && export JAVA_HOME="$candidate" && break
	done
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
[ -f local.properties ] || printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties
exec ./gradlew "${@:-assembleDebug}"
