#!/usr/bin/env python3
"""Generates iCam.xcodeproj.

The project is committed, so you normally don't need this. Re-run it after
adding or removing source files:   python3 tools/gen_xcodeproj.py

Targets
  iCam (iOS)          – iPhone app             Shared/ + iOS/
  iCam (macOS)        – menu bar app           Shared/ + macOS/Shared + macOS/App
  iCamCameraExtension – CoreMediaIO extension  macOS/Shared + macOS/CameraExtension
"""
import hashlib
import os
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "iCam.xcodeproj")


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(value):
    """Quote a pbxproj string when needed (same rules Xcode uses)."""
    if value and all(c.isalnum() or c in "_./" for c in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".entitlements": "text.plist.entitlements",
    ".xcassets": "folder.assetcatalog",
    ".xcstrings": "text.json.xcstrings",
    ".xcconfig": "text.xcconfig",
    ".md": "net.daringfireball.markdown",
}


def files(pattern):
    return sorted(os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, pattern)))


# ----------------------------------------------------------------------------
# Inputs

SHARED = files("Shared/*.swift")
MAC_SHARED = files("macOS/Shared/*.swift")
IOS_SOURCES = SHARED + files("iOS/Sources/*.swift")
MAC_SOURCES = SHARED + MAC_SHARED + files("macOS/App/Sources/*.swift")
EXT_SOURCES = MAC_SHARED + files("macOS/CameraExtension/Sources/*.swift")
IOS_RESOURCES = ["iOS/Resources/Assets.xcassets"] + files("iOS/Resources/*.xcstrings")
MAC_RESOURCES = ["macOS/App/Resources/Assets.xcassets"] + files("macOS/App/Resources/*.xcstrings")
OTHER_FILES = [
    "README.md",
    "Config/Signing.xcconfig",
    "iOS/Resources/Info.plist",
    "macOS/App/Resources/Info.plist",
    "macOS/App/Resources/iCam.entitlements",
    "macOS/CameraExtension/Resources/Info.plist",
    "macOS/CameraExtension/Resources/CameraExtension.entitlements",
]

ALL_FILES = sorted(set(IOS_SOURCES + MAC_SOURCES + EXT_SOURCES + IOS_RESOURCES + MAC_RESOURCES + OTHER_FILES))

objects = {}  # id -> (isa, dict-as-list-of-lines)


def add(obj_id, isa, fields, comment=None):
    objects[obj_id] = (isa, fields, comment)


# ----------------------------------------------------------------------------
# File references and groups

file_ref = {}
for path in ALL_FILES:
    ext = os.path.splitext(path)[1]
    ref = oid("fileref", path)
    file_ref[path] = ref
    add(ref, "PBXFileReference", [
        ("lastKnownFileType", FILE_TYPES.get(ext, "text")),
        ("path", os.path.basename(path)),
        ("sourceTree", "<group>"),
    ], os.path.basename(path))

products = {
    "ios": ("iCam.app", "wrapper.application"),
    "mac": ("iCam.app", "wrapper.application"),
    "ext": ("com.example.icam.mac.CameraExtension.systemextension", "wrapper.system-extension"),
}
product_ref = {}
for key, (name, ftype) in products.items():
    ref = oid("product", key)
    product_ref[key] = ref
    add(ref, "PBXFileReference", [
        ("explicitFileType", ftype),
        ("includeInIndex", "0"),
        ("path", name),
        ("sourceTree", "BUILT_PRODUCTS_DIR"),
    ], name)

# Group tree from directories.
group_children = {"": []}
for path in ALL_FILES:
    parts = path.split("/")
    for i in range(len(parts) - 1):
        parent = "/".join(parts[:i])
        current = "/".join(parts[: i + 1])
        if current not in group_children:
            group_children[current] = []
            group_children[parent].append(("group", current))
    group_children["/".join(parts[:-1])].append(("file", path))

GROUP_ORDER = ["README.md", "Config", "Shared", "iOS", "macOS"]


def sort_key(item):
    kind, path = item
    name = os.path.basename(path)
    if path in GROUP_ORDER:
        return (0, GROUP_ORDER.index(path), name)
    return (1, 0 if kind == "group" else 1, name.lower())


group_id = {}
for group in group_children:
    group_id[group] = oid("group", group) if group else oid("maingroup")
products_group = oid("group", "Products")

for group, children in group_children.items():
    child_ids = []
    for kind, path in sorted(children, key=sort_key):
        child_ids.append(group_id[path] if kind == "group" else file_ref[path])
    fields = [("children", child_ids)]
    if group:
        fields.append(("path", os.path.basename(group)))
    else:
        child_ids.append(products_group)
    fields.append(("sourceTree", "<group>"))
    add(group_id[group], "PBXGroup", fields, os.path.basename(group) if group else None)

add(products_group, "PBXGroup", [
    ("children", [product_ref["ios"], product_ref["mac"], product_ref["ext"]]),
    ("name", "Products"),
    ("sourceTree", "<group>"),
], "Products")


# ----------------------------------------------------------------------------
# Targets

def build_files(target, paths, phase):
    ids = []
    for path in paths:
        bid = oid("buildfile", target, phase, path)
        add(bid, "PBXBuildFile", [("fileRef", file_ref[path])], f"{os.path.basename(path)} in {phase}")
        ids.append(bid)
    return ids


def phase(target, isa, name, file_ids, extra=None):
    pid = oid("phase", target, name)
    fields = [("buildActionMask", "2147483647")]
    fields += extra or []
    fields += [("files", file_ids), ("runOnlyForDeploymentPostprocessing", "0")]
    add(pid, isa, fields, name)
    return pid


COMMON_TARGET = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "$(CURRENT_PROJECT_VERSION)",
    "MARKETING_VERSION": "$(MARKETING_VERSION)",
    "SWIFT_VERSION": "5.0",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}

TARGETS = {
    "ios": {
        "name": "iCam (iOS)",
        "product_name": "iCam",
        "type": "com.apple.product-type.application",
        "sources": IOS_SOURCES,
        "resources": IOS_RESOURCES,
        "settings": {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "INFOPLIST_FILE": "iOS/Resources/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX)",
            "PRODUCT_NAME": "iCam",
            "SDKROOT": "iphoneos",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO",
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "TARGETED_DEVICE_FAMILY": "1",
            "ENABLE_PREVIEWS": "YES",
        },
    },
    "mac": {
        "name": "iCam (macOS)",
        "product_name": "iCam",
        "type": "com.apple.product-type.application",
        "sources": MAC_SOURCES,
        "resources": MAC_RESOURCES,
        "settings": {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "CODE_SIGN_ENTITLEMENTS": "macOS/App/Resources/iCam.entitlements",
            "COMBINE_HIDPI_IMAGES": "YES",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "INFOPLIST_FILE": "macOS/App/Resources/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).mac",
            "PRODUCT_NAME": "iCam",
            "SDKROOT": "macosx",
            "ENABLE_PREVIEWS": "YES",
        },
    },
    "ext": {
        "name": "iCamCameraExtension",
        "product_name": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "type": "com.apple.product-type.system-extension",
        "sources": EXT_SOURCES,
        "resources": [],
        "settings": {
            "CODE_SIGN_ENTITLEMENTS": "macOS/CameraExtension/Resources/CameraExtension.entitlements",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "INFOPLIST_FILE": "macOS/CameraExtension/Resources/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks",
                                        "@executable_path/../../../../Frameworks"],
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_PREFIX).mac.CameraExtension",
            "PRODUCT_MODULE_NAME": "CameraExtension",
            "PRODUCT_NAME": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "SDKROOT": "macosx",
            "SKIP_INSTALL": "YES",
        },
    },
}

PROJECT_ID = oid("project")
config_ref = file_ref["Config/Signing.xcconfig"]


def config_list(owner, settings_debug, settings_release, base_ref=None):
    ids = []
    for name, settings in (("Debug", settings_debug), ("Release", settings_release)):
        cid = oid("config", owner, name)
        fields = []
        if base_ref:
            fields.append(("baseConfigurationReference", base_ref))
        fields.append(("buildSettings", settings))
        fields.append(("name", name))
        add(cid, "XCBuildConfiguration", fields, name)
        ids.append(cid)
    lid = oid("configlist", owner)
    add(lid, "XCConfigurationList", [
        ("buildConfigurations", ids),
        ("defaultConfigurationIsVisible", "0"),
        ("defaultConfigurationName", "Release"),
    ], f"Build configuration list for {owner}")
    return lid


target_ids = {}
for key in ("ext", "ios", "mac"):
    t = TARGETS[key]
    tid = oid("target", key)
    target_ids[key] = tid
    phases = [
        phase(key, "PBXSourcesBuildPhase", "Sources", build_files(key, t["sources"], "Sources")),
        phase(key, "PBXFrameworksBuildPhase", "Frameworks", []),
        phase(key, "PBXResourcesBuildPhase", "Resources", build_files(key, t["resources"], "Resources")),
    ]
    dependencies = []
    if key == "mac":
        embed_id = oid("buildfile", "mac", "embed-ext")
        add(embed_id, "PBXBuildFile", [
            ("fileRef", product_ref["ext"]),
            ("settings", {"ATTRIBUTES": ["RemoveHeadersOnCopy"]}),
        ], "CameraExtension in Embed System Extensions")
        phases.append(phase(key, "PBXCopyFilesBuildPhase", "Embed System Extensions", [embed_id], [
            ("dstPath", "$(SYSTEM_EXTENSIONS_FOLDER_PATH)"),
            ("dstSubfolderSpec", "16"),
            ("name", "Embed System Extensions"),
        ]))
        proxy = oid("proxy", "mac-ext")
        add(proxy, "PBXContainerItemProxy", [
            ("containerPortal", PROJECT_ID),
            ("proxyType", "1"),
            ("remoteGlobalIDString", oid("target", "ext")),
            ("remoteInfo", "iCamCameraExtension"),
        ], "PBXContainerItemProxy")
        dep = oid("dependency", "mac-ext")
        add(dep, "PBXTargetDependency", [
            ("target", oid("target", "ext")),
            ("targetProxy", proxy),
        ], "PBXTargetDependency")
        dependencies.append(dep)

    settings = dict(COMMON_TARGET)
    settings.update(t["settings"])
    debug = dict(settings)
    release = dict(settings)
    clist = config_list(t["name"], debug, release)
    add(tid, "PBXNativeTarget", [
        ("buildConfigurationList", clist),
        ("buildPhases", phases),
        ("buildRules", []),
        ("dependencies", dependencies),
        ("name", t["name"]),
        ("productName", t["name"]),
        ("productReference", product_ref[key]),
        ("productType", t["type"]),
    ], t["name"])

PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_FAST_MATH": "YES",
}
project_debug = dict(PROJECT_COMMON)
project_debug.update({
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
project_release = dict(PROJECT_COMMON)
project_release.update({
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
})
project_config_list = config_list("iCam", project_debug, project_release, config_ref)

add(PROJECT_ID, "PBXProject", [
    ("attributes", {
        "BuildIndependentTargetsInParallel": "1",
        "LastSwiftUpdateCheck": "1600",
        "LastUpgradeCheck": "1600",
        "TargetAttributes": {
            target_ids["ext"]: {"CreatedOnToolsVersion": "16.0"},
            target_ids["ios"]: {"CreatedOnToolsVersion": "16.0"},
            target_ids["mac"]: {"CreatedOnToolsVersion": "16.0"},
        },
    }),
    ("buildConfigurationList", project_config_list),
    ("compatibilityVersion", "Xcode 14.0"),
    ("developmentRegion", "en"),
    ("hasScannedForEncodings", "0"),
    ("knownRegions", ["en", "tr", "Base"]),
    ("mainGroup", group_id[""]),
    ("productRefGroup", products_group),
    ("projectDirPath", ""),
    ("projectRoot", ""),
    ("targets", [target_ids["ios"], target_ids["mac"], target_ids["ext"]]),
], "Project object")


# ----------------------------------------------------------------------------
# Serialization

def comment_for(value):
    if value in objects and objects[value][2]:
        return f" /* {objects[value][2]} */"
    return ""


def render(value, indent):
    pad = "\t" * indent
    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        inner = "".join(f"{pad}\t{render(v, indent + 1)}{comment_for(v) if isinstance(v, str) else ''},\n"
                        for v in value)
        return "(\n" + inner + pad + ")"
    if isinstance(value, dict):
        inner = "".join(f"{pad}\t{q(k)} = {render(v, indent + 1)}{comment_for(v) if isinstance(v, str) else ''};\n"
                        for k, v in sorted(value.items()))
        return "{\n" + inner + pad + "}"
    return q(value)


def render_object(obj_id, isa, fields):
    lines = [f"\t\t{obj_id}{comment_for(obj_id)} = {{"]
    lines.append(f"\t\t\tisa = {isa};")
    for key, value in fields:
        rendered = render(value, 3)
        trailer = comment_for(value) if isinstance(value, str) else ""
        lines.append(f"\t\t\t{key} = {rendered}{trailer};")
    lines.append("\t\t};")
    return "\n".join(lines)


def write_project():
    out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;",
           "\tobjects = {"]
    by_isa = {}
    for obj_id, (isa, fields, _) in objects.items():
        by_isa.setdefault(isa, []).append((obj_id, fields))
    for isa in sorted(by_isa):
        out.append("")
        out.append(f"/* Begin {isa} section */")
        for obj_id, fields in sorted(by_isa[isa]):
            out.append(render_object(obj_id, isa, fields))
        out.append(f"/* End {isa} section */")
    out.append("\t};")
    out.append(f"\trootObject = {PROJECT_ID} /* Project object */;")
    out.append("}")
    os.makedirs(PROJECT, exist_ok=True)
    with open(os.path.join(PROJECT, "project.pbxproj"), "w") as f:
        f.write("\n".join(out) + "\n")

    ws = os.path.join(PROJECT, "project.xcworkspace")
    os.makedirs(ws, exist_ok=True)
    with open(os.path.join(ws, "contents.xcworkspacedata"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
                '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def write_schemes():
    scheme_dir = os.path.join(PROJECT, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    for key in ("ios", "mac"):
        name = TARGETS[key]["name"]
        ref = ('<BuildableReference\n'
               '               BuildableIdentifier = "primary"\n'
               f'               BlueprintIdentifier = "{target_ids[key]}"\n'
               '               BuildableName = "iCam.app"\n'
               f'               BlueprintName = "{name}"\n'
               '               ReferencedContainer = "container:iCam.xcodeproj">\n'
               '            </BuildableReference>')
        with open(os.path.join(scheme_dir, f"{name}.xcscheme"), "w") as f:
            f.write(SCHEME.replace("{ref}", ref))


if __name__ == "__main__":
    write_project()
    write_schemes()
    print(f"Wrote {os.path.relpath(PROJECT, ROOT)} with {len(objects)} objects")
