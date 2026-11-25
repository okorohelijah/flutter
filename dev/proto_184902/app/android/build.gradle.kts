allprojects {
    repositories {
        // PROTOTYPE: take Flutter's Android embedding (the Java half of the engine) from the jar
        // that ../../build_embedding.sh compiles out of this branch's Java sources, instead of the
        // prebuilt jar that Flutter would download. Everything else, including the native engine
        // library, is still the stock download.
        exclusiveContent {
            forRepository { maven { url = uri(rootProject.file("../../embedding_repo")) } }
            filter { includeModuleByRegex("io\\.flutter", "flutter_embedding_.*") }
        }
        google()
        mavenCentral()
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
