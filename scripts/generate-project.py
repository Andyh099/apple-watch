#!/usr/bin/env python3
"""Regenerate the small native Xcode project with no third-party tooling."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}

def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def add(key_name, isa, **fields):
    key = ident(key_name)
    objects[key] = {"isa": isa, **fields}
    return key

def quote(value):
    if isinstance(value, dict):
        return "{ " + " ".join(f"{quote(k)} = {quote(v)};" for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "( " + ", ".join(quote(v) for v in value) + (", " if value else "") + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)

def file_ref(path, file_type):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="<group>")

core = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/InterpreterCore").glob("*.swift"))
shared = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "apps/Shared").glob("*.swift"))
watch = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "apps/Watch").glob("*.swift"))
phone = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "apps/iPhone").glob("*.swift"))
refs = {p: file_ref(p, "sourcecode.swift") for p in core + shared + watch + phone}
resources = {"iOS": [], "watchOS": []}
for platform, directory in [("iOS", "iPhone"), ("watchOS", "Watch")]:
    path = f"apps/{directory}/Info.plist"
    refs[path] = file_ref(path, "text.plist.xml")
products = {}
for name in ["WristInterpreter", "WristInterpreterWatch"]:
    products[name] = add("product:" + name, "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path=name + ".app", sourceTree="BUILT_PRODUCTS_DIR")
product_group = add("products", "PBXGroup", children=list(products.values()), name="Products", sourceTree="<group>")
main_group = add("main", "PBXGroup", children=list(refs.values()) + [product_group], sourceTree="<group>")

project_configs = []
for config in ["Debug", "Release"]:
    project_configs.append(add("project:" + config, "XCBuildConfiguration", name=config, buildSettings={
        "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "targeted",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)" if config == "Debug" else "$(inherited)",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym",
        "ENABLE_TESTABILITY": "YES" if config == "Debug" else "NO",
    }))
project_config_list = add("project:configs", "XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

watch_target = ident("target:WristInterpreterWatch")
proxy = add("watch:proxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType=1, remoteGlobalIDString=watch_target, remoteInfo="WristInterpreterWatch")
dependency = add("watch:dependency", "PBXTargetDependency", target=watch_target, targetProxy=proxy)
embed_file = add("watch:embed-file", "PBXBuildFile", fileRef=products["WristInterpreterWatch"], settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed_phase = add("watch:embed-phase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16, files=[embed_file], name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0)

target_ids = []
for name, platform, paths in [("WristInterpreter", "iOS", phone + shared + core), ("WristInterpreterWatch", "watchOS", watch + shared + core)]:
    build_files = [add(name + ":build:" + p, "PBXBuildFile", fileRef=refs[p]) for p in paths]
    phases = [
        add(name + ":sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=build_files, runOnlyForDeploymentPostprocessing=0),
        add(name + ":frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0),
        add(name + ":resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0),
    ]
    is_watch = platform == "watchOS"
    if not is_watch:
        phases.append(embed_phase)
    configs = []
    for config in ["Debug", "Release"]:
        settings = {
            "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "",
            "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
            "PRODUCT_NAME": "$(TARGET_NAME)", "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "apps/Watch/Info.plist" if is_watch else "apps/iPhone/Info.plist",
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.wristinterpreter.prototype.watchkitapp" if is_watch else "dev.wristinterpreter.prototype",
            "SDKROOT": "watchos" if is_watch else "iphoneos",
            "SUPPORTED_PLATFORMS": "watchos watchsimulator" if is_watch else "iphoneos iphonesimulator",
            "TARGETED_DEVICE_FAMILY": "4" if is_watch else "1",
            "SKIP_INSTALL": "YES" if is_watch else "NO",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
            "SWIFT_EMIT_LOC_STRINGS": "YES",
        }
        settings["WATCHOS_DEPLOYMENT_TARGET" if is_watch else "IPHONEOS_DEPLOYMENT_TARGET"] = "11.0" if is_watch else "18.0"
        configs.append(add(name + ":" + config, "XCBuildConfiguration", name=config, buildSettings=settings))
    config_list = add(name + ":configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target_ids.append(add("target:" + name, "PBXNativeTarget", buildConfigurationList=config_list, buildPhases=phases, buildRules=[], dependencies=[] if is_watch else [dependency], name=name, productName=name, productReference=products[name], productType="com.apple.product-type.application"))

project_id = add("project", "PBXProject", attributes={"LastUpgradeCheck": "2600", "BuildIndependentTargetsInParallel": "YES", "TargetAttributes": {i: {"CreatedOnToolsVersion": "26.0"} for i in target_ids}}, buildConfigurationList=project_config_list, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=target_ids)
project_dir = ROOT / "WristInterpreter.xcodeproj"
project_dir.mkdir(exist_ok=True)
content = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
for key, value in objects.items():
    content += "\t\t" + key + " = " + quote(value) + ";\n"
content += f"\t}};\n\trootObject = {project_id};\n}}\n"
(project_dir / "project.pbxproj").write_text(content)

scheme_dir = project_dir / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
for name in ["WristInterpreter", "WristInterpreterWatch"]:
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + name)}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:WristInterpreter.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (scheme_dir / (name + ".xcscheme")).write_text(scheme)
print(f"Generated {project_dir} with iPhone and single-target watchOS apps.")
