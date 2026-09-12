// Q1（2026-09-06）：国内网络 dl.google.com / repo.maven.apache.org 不可达——
// 阿里云镜像前置（同一制品源，仅加速）。子项目（如 file_picker）buildscript
// 自带 google() 会在其后追加，按顺序解析先命中镜像即停，不触官方源。
allprojects {
    repositories {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        maven("https://storage.flutter-io.cn/download.flutter.io")
    }
}

subprojects {
    buildscript {
        repositories {
            maven("https://maven.aliyun.com/repository/google")
            maven("https://maven.aliyun.com/repository/public")
        }
    }
    // Q1（2026-09-06）：统一抬升插件子项目 compileSdk 到 flutter.compileSdkVersion
    // （file_picker 等硬编码 34，而 flutter_plugin_android_lifecycle 要求 ≥36，
    // AAR metadata 校验失败）。反射调用兼容 AGP 新旧 DSL。
    afterEvaluate {
        extensions.findByName("android")?.let { androidExt ->
            val setter = androidExt.javaClass.methods.firstOrNull {
                (it.name == "setCompileSdk" || it.name == "setCompileSdkVersion") &&
                    (it.parameterTypes[0] == Integer.TYPE || it.parameterTypes[0] == Int::class.java)
            } ?: return@afterEvaluate
            try {
                setter.invoke(androidExt, 36)
            } catch (ignored: Exception) {}
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
