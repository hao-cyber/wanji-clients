# Third-party notices

Wanji source is licensed under [MIT](LICENSE). The following build tools and
test dependencies keep their upstream licenses; Wanji's license does not
relicense them.

- **Gradle wrapper and launch scripts** (`app/android-watch/gradlew`,
  `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar`): Gradle contributors,
  Apache-2.0. The upstream license is included in
  [third_party/GRADLE-LICENSE](third_party/GRADLE-LICENSE).
  [Upstream](https://github.com/gradle/gradle).
- **Android Gradle Plugin** is downloaded as a build dependency, rather than
  vendored application code. [Android tools source](https://android.googlesource.com/platform/tools/base/).
- **JUnit 4** and **org.json** are Android unit-test dependencies, not bundled
  Wanji application libraries. Their licenses and copyright notices accompany
  their Maven artifacts. [JUnit](https://github.com/junit-team/junit4),
  [JSON-java](https://github.com/stleary/JSON-java).
- **pytest** and its locked dependencies are development tooling, not bundled
  client code. [pytest](https://github.com/pytest-dev/pytest).

Apple and Huawei platform SDKs are installed separately and remain subject to
their own terms. No platform SDK, signing certificate, model weights or audio
backend implementation is redistributed in this repository.
