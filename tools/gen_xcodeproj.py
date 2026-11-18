#!/usr/bin/env python3
"""Regenerates Orpheon.xcodeproj from the files under Orpheon/ (run it after adding or removing Swift files).

    python3 tools/gen_xcodeproj.py
"""
import hashlib, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
APP_DIR = "Orpheon"
TARGET = "Orpheon"
BUNDLE_ID = "app.orpheon.ios"
DEPLOYMENT = "15.0"


def uid(*parts):
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


def q(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"') if any(c in s for c in ' -+$()<>"=,;@') or s == "" else s


swift_files = []
for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, APP_DIR)):
    dirnames.sort()
    for f in sorted(filenames):
        if f.endswith(".swift"):
            swift_files.append(os.path.relpath(os.path.join(dirpath, f), os.path.join(ROOT, APP_DIR)))
swift_files.sort()

resources = ["Resources/gql-ops.json", "Resources/Assets.xcassets"]
for r in resources:
    assert os.path.exists(os.path.join(ROOT, APP_DIR, r)), r

# --- ids
project_id = uid("project")
target_id = uid("target")
product_id = uid("product")
main_group = uid("group", "main")
products_group = uid("group", "products")
app_group = uid("group", APP_DIR)
sources_phase = uid("phase", "sources")
frameworks_phase = uid("phase", "frameworks")
resources_phase = uid("phase", "resources")
proj_cfg_list = uid("cfglist", "project")
tgt_cfg_list = uid("cfglist", "target")
proj_debug, proj_release = uid("cfg", "project", "debug"), uid("cfg", "project", "release")
tgt_debug, tgt_release = uid("cfg", "target", "debug"), uid("cfg", "target", "release")
plist_ref = uid("file", "Info.plist")

# directory groups (relative path -> id)
dirs = set()
for f in swift_files + resources:
    d = os.path.dirname(f)
    while d:
        dirs.add(d)
        d = os.path.dirname(d)
group_ids = {d: uid("group", APP_DIR, d) for d in dirs}
file_ids = {f: uid("file", f) for f in swift_files + resources}
build_ids = {f: uid("build", f) for f in swift_files + resources}


def ftype(path):
    if path.endswith(".swift"): return "sourcecode.swift"
    if path.endswith(".json"): return "text.json"
    if path.endswith(".xcassets"): return "folder.assetcatalog"
    if path.endswith(".plist"): return "text.plist.xml"
    return "file"


L = []
w = L.append
w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {\n\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {\n")

w("/* Begin PBXBuildFile section */")
for f in swift_files:
    w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };" % (build_ids[f], os.path.basename(f), file_ids[f], os.path.basename(f)))
for f in resources:
    w("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };" % (build_ids[f], os.path.basename(f), file_ids[f], os.path.basename(f)))
w("/* End PBXBuildFile section */\n")

w("/* Begin PBXFileReference section */")
w("\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };" % (product_id, TARGET, TARGET))
w("\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };" % plist_ref)
for f in swift_files + resources:
    w("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = \"<group>\"; };" % (file_ids[f], os.path.basename(f), ftype(f), q(os.path.basename(f))))
w("/* End PBXFileReference section */\n")

w("/* Begin PBXFrameworksBuildPhase section */")
w("\t\t%s /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};" % frameworks_phase)
w("/* End PBXFrameworksBuildPhase section */\n")

w("/* Begin PBXGroup section */")
w("\t\t%s = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t%s /* %s */,\n\t\t\t\t%s /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t};" % (main_group, app_group, APP_DIR, products_group))
w("\t\t%s /* Products */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t%s /* %s.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t};" % (products_group, product_id, TARGET))


def children_of(d):
    kids = []
    for sub in sorted(x for x in dirs if os.path.dirname(x) == d):
        kids.append((os.path.basename(sub), group_ids[sub]))
    for f in sorted(swift_files + resources):
        if os.path.dirname(f) == d:
            kids.append((os.path.basename(f), file_ids[f]))
    return kids


top = children_of("")
w("\t\t%s /* %s */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (" % (app_group, APP_DIR))
for name, i in top:
    w("\t\t\t\t%s /* %s */," % (i, name))
w("\t\t\t\t%s /* Info.plist */," % plist_ref)
w("\t\t\t);\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t};" % APP_DIR)
for d in sorted(dirs):
    w("\t\t%s /* %s */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (" % (group_ids[d], os.path.basename(d)))
    for name, i in children_of(d):
        w("\t\t\t\t%s /* %s */," % (i, name))
    w("\t\t\t);\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t};" % os.path.basename(d))
w("/* End PBXGroup section */\n")

w("/* Begin PBXNativeTarget section */")
w("\t\t%s /* %s */ = {\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;\n\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t\t%s /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = %s;\n\t\t\tproductName = %s;\n\t\t\tproductReference = %s /* %s.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t};" % (target_id, TARGET, tgt_cfg_list, TARGET, sources_phase, frameworks_phase, resources_phase, TARGET, TARGET, product_id, TARGET))
w("/* End PBXNativeTarget section */\n")

w("/* Begin PBXProject section */")
w("\t\t%s /* Project object */ = {\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1500;\n\t\t\t\tLastUpgradeCheck = 1500;\n\t\t\t\tTargetAttributes = {\n\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\t};\n\t\t\t\t};\n\t\t\t};\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"%s\" */;\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = %s;\n\t\t\tproductRefGroup = %s /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t%s /* %s */,\n\t\t\t);\n\t\t};" % (project_id, target_id, proj_cfg_list, TARGET, main_group, products_group, target_id, TARGET))
w("/* End PBXProject section */\n")

w("/* Begin PBXResourcesBuildPhase section */")
w("\t\t%s /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (" % resources_phase)
for f in resources:
    w("\t\t\t\t%s /* %s in Resources */," % (build_ids[f], os.path.basename(f)))
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
w("/* End PBXResourcesBuildPhase section */\n")

w("/* Begin PBXSourcesBuildPhase section */")
w("\t\t%s /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (" % sources_phase)
for f in swift_files:
    w("\t\t\t\t%s /* %s in Sources */," % (build_ids[f], os.path.basename(f)))
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
w("/* End PBXSourcesBuildPhase section */\n")


def settings(d):
    return "".join("\t\t\t\t%s = %s;\n" % (k, v) for k, v in d)


proj_common = [
    ("ALWAYS_SEARCH_USER_PATHS", "NO"),
    ("CLANG_ANALYZER_NONNULL", "YES"),
    ("CLANG_ENABLE_MODULES", "YES"),
    ("CLANG_ENABLE_OBJC_ARC", "YES"),
    ("COPY_PHASE_STRIP", "NO"),
    ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
    ("GCC_C_LANGUAGE_STANDARD", "gnu11"),
    ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT),
    ("SDKROOT", "iphoneos"),
    ("SWIFT_VERSION", "5.0"),
]
proj_debug_s = proj_common + [
    ("DEBUG_INFORMATION_FORMAT", "dwarf"),
    ("ENABLE_TESTABILITY", "YES"),
    ("GCC_OPTIMIZATION_LEVEL", "0"),
    ("GCC_PREPROCESSOR_DEFINITIONS", '("DEBUG=1", "$(inherited)")'),
    ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
    ("ONLY_ACTIVE_ARCH", "YES"),
    ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
    ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"'),
]
proj_release_s = proj_common + [
    ("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
    ("ENABLE_NS_ASSERTIONS", "NO"),
    ("MTL_ENABLE_DEBUG_INFO", "NO"),
    ("SWIFT_COMPILATION_MODE", "wholemodule"),
    ("SWIFT_OPTIMIZATION_LEVEL", '"-O"'),
    ("VALIDATE_PRODUCT", "YES"),
]
tgt_common = [
    ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
    ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
    ("CODE_SIGN_IDENTITY", '""'),
    ("CODE_SIGN_STYLE", "Manual"),
    ("CODE_SIGNING_ALLOWED", "NO"),
    ("CODE_SIGNING_REQUIRED", "NO"),
    ("CURRENT_PROJECT_VERSION", "1"),
    ("GENERATE_INFOPLIST_FILE", "NO"),
    ("INFOPLIST_FILE", "%s/Info.plist" % APP_DIR),
    ("LD_RUNPATH_SEARCH_PATHS", '("$(inherited)", "@executable_path/Frameworks")'),
    ("MARKETING_VERSION", "1.0"),
    ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID),
    ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
    ("SWIFT_STRICT_CONCURRENCY", "minimal"),
    ("SWIFT_VERSION", "5.0"),
    ("TARGETED_DEVICE_FAMILY", '"1,2"'),
]

w("/* Begin XCBuildConfiguration section */")
for cid, name, s in [(proj_debug, "Debug", proj_debug_s), (proj_release, "Release", proj_release_s)]:
    w("\t\t%s /* %s */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n%s\t\t\t};\n\t\t\tname = %s;\n\t\t};" % (cid, name, settings(s), name))
for cid, name in [(tgt_debug, "Debug"), (tgt_release, "Release")]:
    w("\t\t%s /* %s */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n%s\t\t\t};\n\t\t\tname = %s;\n\t\t};" % (cid, name, settings(tgt_common), name))
w("/* End XCBuildConfiguration section */\n")

w("/* Begin XCConfigurationList section */")
w("\t\t%s /* Build configuration list for PBXProject \"%s\" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};" % (proj_cfg_list, TARGET, proj_debug, proj_release))
w("\t\t%s /* Build configuration list for PBXNativeTarget \"%s\" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};" % (tgt_cfg_list, TARGET, tgt_debug, tgt_release))
w("/* End XCConfigurationList section */")
w("\t};")
w("\trootObject = %s /* Project object */;" % project_id)
w("}")

proj_dir = os.path.join(ROOT, "%s.xcodeproj" % TARGET)
os.makedirs(proj_dir, exist_ok=True)
with open(os.path.join(proj_dir, "project.pbxproj"), "w") as fh:
    fh.write("\n".join(L) + "\n")

# shared scheme so `xcodebuild -scheme Orpheon` works
scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
ref = '<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "%s" BuildableName = "%s.app" BlueprintName = "%s" ReferencedContainer = "container:%s.xcodeproj"></BuildableReference>' % (target_id, TARGET, TARGET, TARGET)
scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            %(ref)s
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         %(ref)s
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         %(ref)s
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""" % {"ref": ref}
with open(os.path.join(scheme_dir, "%s.xcscheme" % TARGET), "w") as fh:
    fh.write(scheme)
print("wrote", proj_dir, "with", len(swift_files), "swift files")
