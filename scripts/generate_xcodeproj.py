#!/usr/bin/env python3
"""
Deterministic Xcode project generator for Kadmos (macOS 26/27).
Zero external dependencies; generates Kadmos.xcodeproj with:
  - KadmosCore (static library)
  - KadmosFinderSync (Finder Sync .appex)
  - Kadmos (macOS .app embedding KadmosFinderSync.appex)
Enforces SECURITY.md §2.2 & §9 (Hardened Runtime, App Sandbox, User Script Sandboxing).
"""

import hashlib
import os
from pathlib import Path

ROOT = Path("/Users/stormtrooper/.gemini/antigravity/scratch/Kadmos")
PROJ_DIR = ROOT / "Kadmos.xcodeproj"
SCHEME_DIR = PROJ_DIR / "xcshareddata" / "xcschemes"


def uid(tag: str) -> str:
    return hashlib.sha256(tag.encode("utf-8")).hexdigest()[:24].upper()


def collect_swift_files(rel_dir: str) -> list[str]:
    base = ROOT / rel_dir
    files = sorted(p.relative_to(ROOT).as_posix() for p in base.rglob("*.swift"))
    if not files:
        raise RuntimeError(f"No .swift files found in {base}")
    return files


def pbx_str(val: str) -> str:
    safe = val.replace("\\", "\\\\").replace('"', '\\"')
    if all(c.isalnum() or c in "._/" for c in val) and val:
        return val
    return f'"{safe}"'


def main() -> None:
    core_files = collect_swift_files("Sources/KadmosCore")
    app_files = collect_swift_files("Sources/KadmosApp")
    finder_files = collect_swift_files("Sources/KadmosFinderSync")

    resource_files = [
        "Assets/AppIcon.icns",
        "Assets/kadmos-icon-1024.png",
    ]
    config_files = [
        "Config/Kadmos.entitlements",
        "Config/KadmosFinderSync.entitlements",
        "Config/Kadmos-Info.plist",
        "Config/KadmosFinderSync-Info.plist",
        "SECURITY.md",
    ]

    # Precompute stable IDs
    project_id = uid("project")
    main_group_id = uid("group:main")
    sources_group_id = uid("group:Sources")
    core_group_id = uid("group:Sources/KadmosCore")
    app_group_id = uid("group:Sources/KadmosApp")
    finder_group_id = uid("group:Sources/KadmosFinderSync")
    assets_group_id = uid("group:Assets")
    config_group_id = uid("group:Config")
    frameworks_group_id = uid("group:Frameworks")
    products_group_id = uid("group:Products")

    proj_cfg_list_id = uid("cfglist:project")
    proj_dbg_id = uid("cfg:project:Debug")
    proj_rel_id = uid("cfg:project:Release")

    core_target_id = uid("target:KadmosCore")
    core_cfg_list_id = uid("cfglist:KadmosCore")
    core_dbg_id = uid("cfg:KadmosCore:Debug")
    core_rel_id = uid("cfg:KadmosCore:Release")
    core_sources_phase_id = uid("phase:KadmosCore:sources")
    core_product_id = uid("product:libKadmosCore.a")

    finder_target_id = uid("target:KadmosFinderSync")
    finder_cfg_list_id = uid("cfglist:KadmosFinderSync")
    finder_dbg_id = uid("cfg:KadmosFinderSync:Debug")
    finder_rel_id = uid("cfg:KadmosFinderSync:Release")
    finder_sources_phase_id = uid("phase:KadmosFinderSync:sources")
    finder_frameworks_phase_id = uid("phase:KadmosFinderSync:frameworks")
    finder_resources_phase_id = uid("phase:KadmosFinderSync:resources")
    finder_product_id = uid("product:KadmosFinderSync.appex")

    app_target_id = uid("target:Kadmos")
    app_cfg_list_id = uid("cfglist:Kadmos")
    app_dbg_id = uid("cfg:Kadmos:Debug")
    app_rel_id = uid("cfg:Kadmos:Release")
    app_sources_phase_id = uid("phase:Kadmos:sources")
    app_frameworks_phase_id = uid("phase:Kadmos:frameworks")
    app_resources_phase_id = uid("phase:Kadmos:resources")
    app_embed_phase_id = uid("phase:Kadmos:embed_appex")
    app_product_id = uid("product:Kadmos.app")

    dep_core_id = uid("dep:KadmosCore")
    dep_core_proxy_id = uid("proxy:KadmosCore")
    dep_finder_core_id = uid("dep:finder:KadmosCore")
    dep_finder_core_proxy_id = uid("proxy:finder:KadmosCore")
    dep_finder_id = uid("dep:KadmosFinderSync")
    dep_finder_proxy_id = uid("proxy:KadmosFinderSync")

    # System frameworks
    sys_frameworks = [
        ("FinderSync.framework", "System/Library/Frameworks/FinderSync.framework"),
        ("Cocoa.framework", "System/Library/Frameworks/Cocoa.framework"),
        ("AppKit.framework", "System/Library/Frameworks/AppKit.framework"),
        ("SwiftUI.framework", "System/Library/Frameworks/SwiftUI.framework"),
        ("UniformTypeIdentifiers.framework", "System/Library/Frameworks/UniformTypeIdentifiers.framework"),
    ]
    fw_file_refs = {name: uid(f"fileref:fw:{name}") for name, _ in sys_frameworks}

    file_refs: dict[str, str] = {}
    build_files: list[tuple[str, str, str, str]] = []  # (bf_id, fileref_id, comment, settings_str)

    def register_file(rel_path: str, file_type: str) -> str:
        fid = uid(f"fileref:{rel_path}")
        file_refs[rel_path] = fid
        return fid

    core_bf_ids = []
    for rel in core_files:
        fid = register_file(rel, "sourcecode.swift")
        bfid = uid(f"bf:core:{rel}")
        core_bf_ids.append((bfid, fid, os.path.basename(rel)))
        build_files.append((bfid, fid, f"{os.path.basename(rel)} in Sources", ""))

    app_bf_ids = []
    for rel in app_files:
        fid = register_file(rel, "sourcecode.swift")
        bfid = uid(f"bf:app:{rel}")
        app_bf_ids.append((bfid, fid, os.path.basename(rel)))
        build_files.append((bfid, fid, f"{os.path.basename(rel)} in Sources", ""))

    finder_bf_ids = []
    for rel in finder_files:
        fid = register_file(rel, "sourcecode.swift")
        bfid = uid(f"bf:finder:{rel}")
        finder_bf_ids.append((bfid, fid, os.path.basename(rel)))
        build_files.append((bfid, fid, f"{os.path.basename(rel)} in Sources", ""))

    app_res_bf_ids = []
    for rel in resource_files:
        fid = register_file(rel, "file")
        bfid = uid(f"bf:res:{rel}")
        app_res_bf_ids.append((bfid, fid, os.path.basename(rel)))
        build_files.append((bfid, fid, f"{os.path.basename(rel)} in Resources", ""))

    for rel in config_files:
        register_file(rel, "text.xml")

    # Framework & link build files
    bf_finder_fw_core = uid("bf:fw:finder:KadmosCore")
    bf_finder_fw_findersync = uid("bf:fw:finder:FinderSync")
    bf_finder_fw_cocoa = uid("bf:fw:finder:Cocoa")
    build_files.append((bf_finder_fw_core, core_product_id, "libKadmosCore.a in Frameworks", ""))
    build_files.append((bf_finder_fw_findersync, fw_file_refs["FinderSync.framework"], "FinderSync.framework in Frameworks", ""))
    build_files.append((bf_finder_fw_cocoa, fw_file_refs["Cocoa.framework"], "Cocoa.framework in Frameworks", ""))

    bf_app_fw_core = uid("bf:fw:app:KadmosCore")
    bf_app_fw_appkit = uid("bf:fw:app:AppKit")
    bf_app_fw_swiftui = uid("bf:fw:app:SwiftUI")
    bf_app_fw_uttype = uid("bf:fw:app:UniformTypeIdentifiers")
    build_files.append((bf_app_fw_core, core_product_id, "libKadmosCore.a in Frameworks", ""))
    build_files.append((bf_app_fw_appkit, fw_file_refs["AppKit.framework"], "AppKit.framework in Frameworks", ""))
    build_files.append((bf_app_fw_swiftui, fw_file_refs["SwiftUI.framework"], "SwiftUI.framework in Frameworks", ""))
    build_files.append((bf_app_fw_uttype, fw_file_refs["UniformTypeIdentifiers.framework"], "UniformTypeIdentifiers.framework in Frameworks", ""))

    bf_embed_finder = uid("bf:embed:KadmosFinderSync.appex")
    build_files.append((
        bf_embed_finder,
        finder_product_id,
        "KadmosFinderSync.appex in Embed App Extensions",
        "settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; "
    ))

    # Build app sub-groups cleanly
    app_subgroups: dict[str, list[str]] = {}
    for rel in app_files:
        sub = str(Path(rel).parent.relative_to("Sources/KadmosApp"))
        app_subgroups.setdefault(sub, []).append(rel)

    lines: list[str] = [
        "// !$*UTF8*$!",
        "{",
        "\tarchiveVersion = 1;",
        "\tclasses = {};",
        "\tobjectVersion = 56;",
        "\tobjects = {",
        "",
        "/* Begin PBXBuildFile section */",
    ]

    for bfid, fid, comment, settings in build_files:
        lines.append(f"\t\t{bfid} /* {comment} */ = {{isa = PBXBuildFile; fileRef = {fid}; {settings}}};")
    lines.append("/* End PBXBuildFile section */")
    lines.append("")

    # ContainerItemProxy
    lines.extend([
        "/* Begin PBXContainerItemProxy section */",
        f"\t\t{dep_core_proxy_id} /* PBXContainerItemProxy */ = {{",
        "\t\t\tisa = PBXContainerItemProxy;",
        f"\t\t\tcontainerPortal = {project_id} /* Project object */;",
        "\t\t\tproxyType = 1;",
        f"\t\t\tremoteGlobalIDString = {core_target_id};",
        "\t\t\tremoteInfo = KadmosCore;",
        "\t\t};",
        f"\t\t{dep_finder_core_proxy_id} /* PBXContainerItemProxy */ = {{",
        "\t\t\tisa = PBXContainerItemProxy;",
        f"\t\t\tcontainerPortal = {project_id} /* Project object */;",
        "\t\t\tproxyType = 1;",
        f"\t\t\tremoteGlobalIDString = {core_target_id};",
        "\t\t\tremoteInfo = KadmosCore;",
        "\t\t};",
        f"\t\t{dep_finder_proxy_id} /* PBXContainerItemProxy */ = {{",
        "\t\t\tisa = PBXContainerItemProxy;",
        f"\t\t\tcontainerPortal = {project_id} /* Project object */;",
        "\t\t\tproxyType = 1;",
        f"\t\t\tremoteGlobalIDString = {finder_target_id};",
        "\t\t\tremoteInfo = KadmosFinderSync;",
        "\t\t};",
        "/* End PBXContainerItemProxy section */",
        "",
    ])

    # CopyFilesBuildPhase (Embed App Extensions into Contents/PlugIns)
    lines.extend([
        "/* Begin PBXCopyFilesBuildPhase section */",
        f"\t\t{app_embed_phase_id} /* Embed App Extensions */ = {{",
        "\t\t\tisa = PBXCopyFilesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        '\t\t\tdstPath = "";',
        "\t\t\tdstSubfolderSpec = 13;",
        "\t\t\tfiles = (",
        f"\t\t\t\t{bf_embed_finder} /* KadmosFinderSync.appex in Embed App Extensions */,",
        "\t\t\t);",
        '\t\t\tname = "Embed App Extensions";',
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXCopyFilesBuildPhase section */",
        "",
    ])

    # FileReference section
    lines.append("/* Begin PBXFileReference section */")
    lines.append(f'\t\t{core_product_id} /* libKadmosCore.a */ = {{isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libKadmosCore.a; sourceTree = BUILT_PRODUCTS_DIR; }};')
    lines.append(f'\t\t{finder_product_id} /* KadmosFinderSync.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = KadmosFinderSync.appex; sourceTree = BUILT_PRODUCTS_DIR; }};')
    lines.append(f'\t\t{app_product_id} /* Kadmos.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Kadmos.app; sourceTree = BUILT_PRODUCTS_DIR; }};')

    for name, sdk_path in sys_frameworks:
        fid = fw_file_refs[name]
        lines.append(f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {pbx_str(name)}; path = {pbx_str(sdk_path)}; sourceTree = SDKROOT; }};')

    for rel, fid in sorted(file_refs.items()):
        name = os.path.basename(rel)
        if rel.endswith(".swift"):
            ft = "sourcecode.swift"
        elif rel.endswith(".icns"):
            ft = "image.icns"
        elif rel.endswith(".png"):
            ft = "image.png"
        elif rel.endswith(".plist"):
            ft = "text.plist.xml"
        elif rel.endswith(".entitlements"):
            ft = "text.plist.entitlements"
        else:
            ft = "net.daringfireball.markdown"
        lines.append(f'\t\t{fid} /* {rel} */ = {{isa = PBXFileReference; lastKnownFileType = {ft}; name = {pbx_str(name)}; path = {pbx_str(rel)}; sourceTree = SOURCE_ROOT; }};')
    lines.append("/* End PBXFileReference section */")
    lines.append("")

    # FrameworksBuildPhase
    lines.extend([
        "/* Begin PBXFrameworksBuildPhase section */",
        f"\t\t{finder_frameworks_phase_id} /* Frameworks */ = {{",
        "\t\t\tisa = PBXFrameworksBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        f"\t\t\t\t{bf_finder_fw_core} /* libKadmosCore.a in Frameworks */,",
        f"\t\t\t\t{bf_finder_fw_findersync} /* FinderSync.framework in Frameworks */,",
        f"\t\t\t\t{bf_finder_fw_cocoa} /* Cocoa.framework in Frameworks */,",
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        f"\t\t{app_frameworks_phase_id} /* Frameworks */ = {{",
        "\t\t\tisa = PBXFrameworksBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        f"\t\t\t\t{bf_app_fw_core} /* libKadmosCore.a in Frameworks */,",
        f"\t\t\t\t{bf_app_fw_appkit} /* AppKit.framework in Frameworks */,",
        f"\t\t\t\t{bf_app_fw_swiftui} /* SwiftUI.framework in Frameworks */,",
        f"\t\t\t\t{bf_app_fw_uttype} /* UniformTypeIdentifiers.framework in Frameworks */,",
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXFrameworksBuildPhase section */",
        "",
    ])

    # PBXGroup section
    lines.append("/* Begin PBXGroup section */")
    lines.extend([
        f"\t\t{main_group_id} = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        f"\t\t\t\t{sources_group_id} /* Sources */,",
        f"\t\t\t\t{assets_group_id} /* Assets */,",
        f"\t\t\t\t{config_group_id} /* Config */,",
        f"\t\t\t\t{frameworks_group_id} /* Frameworks */,",
        f"\t\t\t\t{products_group_id} /* Products */,",
        "\t\t\t);",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        f"\t\t{sources_group_id} /* Sources */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        f"\t\t\t\t{core_group_id} /* KadmosCore */,",
        f"\t\t\t\t{app_group_id} /* KadmosApp */,",
        f"\t\t\t\t{finder_group_id} /* KadmosFinderSync */,",
        "\t\t\t);",
        "\t\t\tname = Sources;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        f"\t\t{core_group_id} /* KadmosCore */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        *[f"\t\t\t\t{file_refs[r]} /* {os.path.basename(r)} */," for r in core_files],
        "\t\t\t);",
        "\t\t\tname = KadmosCore;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
    ])

    app_subgroup_ids = []
    for sub in sorted(app_subgroups.keys()):
        if sub == ".":
            continue
        sgid = uid(f"group:Sources/KadmosApp/{sub}")
        app_subgroup_ids.append((sub, sgid))

    lines.extend([
        f"\t\t{app_group_id} /* KadmosApp */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        *[f"\t\t\t\t{sgid} /* {sub} */," for sub, sgid in app_subgroup_ids],
        *[f"\t\t\t\t{file_refs[r]} /* {os.path.basename(r)} */," for r in app_subgroups.get(".", [])],
        "\t\t\t);",
        "\t\t\tname = KadmosApp;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
    ])
    for sub, sgid in app_subgroup_ids:
        lines.extend([
            f"\t\t{sgid} /* {sub} */ = {{",
            "\t\t\tisa = PBXGroup;",
            "\t\t\tchildren = (",
            *[f"\t\t\t\t{file_refs[r]} /* {os.path.basename(r)} */," for r in app_subgroups[sub]],
            "\t\t\t);",
            f"\t\t\tname = {pbx_str(sub)};",
            '\t\t\tsourceTree = "<group>";',
            "\t\t};",
        ])

    lines.extend([
        f"\t\t{finder_group_id} /* KadmosFinderSync */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        *[f"\t\t\t\t{file_refs[r]} /* {os.path.basename(r)} */," for r in finder_files],
        "\t\t\t);",
        "\t\t\tname = KadmosFinderSync;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        f"\t\t{assets_group_id} /* Assets */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        *[f"\t\t\t\t{file_refs[r]} /* {os.path.basename(r)} */," for r in resource_files],
        "\t\t\t);",
        "\t\t\tname = Assets;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        f"\t\t{config_group_id} /* Config */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        *[f"\t\t\t\t{file_refs[r]} /* {os.path.basename(r)} */," for r in config_files],
        "\t\t\t);",
        "\t\t\tname = Config;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        f"\t\t{frameworks_group_id} /* Frameworks */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        *[f"\t\t\t\t{fw_file_refs[name]} /* {name} */," for name, _ in sys_frameworks],
        "\t\t\t);",
        "\t\t\tname = Frameworks;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        f"\t\t{products_group_id} /* Products */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        f"\t\t\t\t{core_product_id} /* libKadmosCore.a */,",
        f"\t\t\t\t{finder_product_id} /* KadmosFinderSync.appex */,",
        f"\t\t\t\t{app_product_id} /* Kadmos.app */,",
        "\t\t\t);",
        "\t\t\tname = Products;",
        '\t\t\tsourceTree = "<group>";',
        "\t\t};",
        "/* End PBXGroup section */",
        "",
    ])

    # NativeTarget section
    lines.extend([
        "/* Begin PBXNativeTarget section */",
        f"\t\t{core_target_id} /* KadmosCore */ = {{",
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {core_cfg_list_id} /* Build configuration list for PBXNativeTarget \"KadmosCore\" */;",
        "\t\t\tbuildPhases = (",
        f"\t\t\t\t{core_sources_phase_id} /* Sources */,",
        "\t\t\t);",
        "\t\t\tbuildRules = ();",
        "\t\t\tdependencies = ();",
        "\t\t\tname = KadmosCore;",
        "\t\t\tproductName = KadmosCore;",
        f"\t\t\tproductReference = {core_product_id} /* libKadmosCore.a */;",
        '\t\t\tproductType = "com.apple.product-type.library.static";',
        "\t\t};",
        f"\t\t{finder_target_id} /* KadmosFinderSync */ = {{",
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {finder_cfg_list_id} /* Build configuration list for PBXNativeTarget \"KadmosFinderSync\" */;",
        "\t\t\tbuildPhases = (",
        f"\t\t\t\t{finder_sources_phase_id} /* Sources */,",
        f"\t\t\t\t{finder_frameworks_phase_id} /* Frameworks */,",
        f"\t\t\t\t{finder_resources_phase_id} /* Resources */,",
        "\t\t\t);",
        "\t\t\tbuildRules = ();",
        "\t\t\tdependencies = (",
        f"\t\t\t\t{dep_finder_core_id} /* PBXTargetDependency */,",
        "\t\t\t);",
        "\t\t\tname = KadmosFinderSync;",
        "\t\t\tproductName = KadmosFinderSync;",
        f"\t\t\tproductReference = {finder_product_id} /* KadmosFinderSync.appex */;",
        '\t\t\tproductType = "com.apple.product-type.app-extension";',
        "\t\t};",
        f"\t\t{app_target_id} /* Kadmos */ = {{",
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {app_cfg_list_id} /* Build configuration list for PBXNativeTarget \"Kadmos\" */;",
        "\t\t\tbuildPhases = (",
        f"\t\t\t\t{app_sources_phase_id} /* Sources */,",
        f"\t\t\t\t{app_frameworks_phase_id} /* Frameworks */,",
        f"\t\t\t\t{app_resources_phase_id} /* Resources */,",
        f"\t\t\t\t{app_embed_phase_id} /* Embed App Extensions */,",
        "\t\t\t);",
        "\t\t\tbuildRules = ();",
        "\t\t\tdependencies = (",
        f"\t\t\t\t{dep_core_id} /* PBXTargetDependency */,",
        f"\t\t\t\t{dep_finder_id} /* PBXTargetDependency */,",
        "\t\t\t);",
        "\t\t\tname = Kadmos;",
        "\t\t\tproductName = Kadmos;",
        f"\t\t\tproductReference = {app_product_id} /* Kadmos.app */;",
        '\t\t\tproductType = "com.apple.product-type.application";',
        "\t\t};",
        "/* End PBXNativeTarget section */",
        "",
    ])

    # PBXProject section
    lines.extend([
        "/* Begin PBXProject section */",
        f"\t\t{project_id} /* Project object */ = {{",
        "\t\t\tisa = PBXProject;",
        "\t\t\tattributes = {",
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
        "\t\t\t\tLastSwiftUpdateCheck = 2700;",
        "\t\t\t\tLastUpgradeCheck = 2700;",
        "\t\t\t\tTargetAttributes = {",
        f"\t\t\t\t\t{core_target_id} = {{ CreatedOnToolsVersion = 27.2; }};",
        f"\t\t\t\t\t{finder_target_id} = {{ CreatedOnToolsVersion = 27.2; }};",
        f"\t\t\t\t\t{app_target_id} = {{ CreatedOnToolsVersion = 27.2; }};",
        "\t\t\t\t};",
        "\t\t\t};",
        f"\t\t\tbuildConfigurationList = {proj_cfg_list_id} /* Build configuration list for PBXProject \"Kadmos\" */;",
        '\t\t\tcompatibilityVersion = "Xcode 14.0";',
        "\t\t\tdevelopmentRegion = tr;",
        "\t\t\thasScannedForEncodings = 0;",
        "\t\t\tknownRegions = (tr, en, Base);",
        f"\t\t\tmainGroup = {main_group_id};",
        f"\t\t\tproductRefGroup = {products_group_id} /* Products */;",
        '\t\t\tprojectDirPath = "";',
        '\t\t\tprojectRoot = "";',
        "\t\t\ttargets = (",
        f"\t\t\t\t{core_target_id} /* KadmosCore */,",
        f"\t\t\t\t{finder_target_id} /* KadmosFinderSync */,",
        f"\t\t\t\t{app_target_id} /* Kadmos */,",
        "\t\t\t);",
        "\t\t};",
        "/* End PBXProject section */",
        "",
    ])

    # ResourcesBuildPhase
    lines.extend([
        "/* Begin PBXResourcesBuildPhase section */",
        f"\t\t{finder_resources_phase_id} /* Resources */ = {{",
        "\t\t\tisa = PBXResourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = ();",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        f"\t\t{app_resources_phase_id} /* Resources */ = {{",
        "\t\t\tisa = PBXResourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        *[f"\t\t\t\t{bfid} /* {name} in Resources */," for bfid, _, name in app_res_bf_ids],
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXResourcesBuildPhase section */",
        "",
    ])

    # SourcesBuildPhase
    lines.extend([
        "/* Begin PBXSourcesBuildPhase section */",
        f"\t\t{core_sources_phase_id} /* Sources */ = {{",
        "\t\t\tisa = PBXSourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        *[f"\t\t\t\t{bfid} /* {name} in Sources */," for bfid, _, name in core_bf_ids],
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        f"\t\t{finder_sources_phase_id} /* Sources */ = {{",
        "\t\t\tisa = PBXSourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        *[f"\t\t\t\t{bfid} /* {name} in Sources */," for bfid, _, name in finder_bf_ids],
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        f"\t\t{app_sources_phase_id} /* Sources */ = {{",
        "\t\t\tisa = PBXSourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
        *[f"\t\t\t\t{bfid} /* {name} in Sources */," for bfid, _, name in app_bf_ids],
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXSourcesBuildPhase section */",
        "",
    ])

    # TargetDependency
    lines.extend([
        "/* Begin PBXTargetDependency section */",
        f"\t\t{dep_core_id} /* PBXTargetDependency */ = {{",
        "\t\t\tisa = PBXTargetDependency;",
        f"\t\t\ttarget = {core_target_id} /* KadmosCore */;",
        f"\t\t\ttargetProxy = {dep_core_proxy_id} /* PBXContainerItemProxy */;",
        "\t\t};",
        f"\t\t{dep_finder_core_id} /* PBXTargetDependency */ = {{",
        "\t\t\tisa = PBXTargetDependency;",
        f"\t\t\ttarget = {core_target_id} /* KadmosCore */;",
        f"\t\t\ttargetProxy = {dep_finder_core_proxy_id} /* PBXContainerItemProxy */;",
        "\t\t};",
        f"\t\t{dep_finder_id} /* PBXTargetDependency */ = {{",
        "\t\t\tisa = PBXTargetDependency;",
        f"\t\t\ttarget = {finder_target_id} /* KadmosFinderSync */;",
        f"\t\t\ttargetProxy = {dep_finder_proxy_id} /* PBXContainerItemProxy */;",
        "\t\t};",
        "/* End PBXTargetDependency section */",
        "",
    ])

    # BuildConfiguration helpers
    def format_cfg(cfg_id: str, name: str, settings: dict[str, str]) -> list[str]:
        out = [
            f"\t\t{cfg_id} /* {name} */ = {{",
            "\t\t\tisa = XCBuildConfiguration;",
            "\t\t\tbuildSettings = {",
        ]
        for k in sorted(settings.keys()):
            v = settings[k]
            out.append(f"\t\t\t\t{k} = {v};")
        out.extend([
            "\t\t\t};",
            f"\t\t\tname = {name};",
            "\t\t};",
        ])
        return out

    common_project_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CODE_SIGN_IDENTITY": '""',
        "CODE_SIGN_STYLE": "Manual",
        "COMBINE_HIDPI_IMAGES": "YES",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        "SDKROOT": "macosx",
        "SUPPORTED_PLATFORMS": "macosx",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_VERSION": "6.0",
    }
    proj_dbg_settings = {
        **common_project_settings,
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    }
    proj_rel_settings = {
        **common_project_settings,
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
    }

    core_settings = {
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "DEFINES_MODULE": "YES",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SKIP_INSTALL": "YES",
    }

    finder_settings = {
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "CODE_SIGN_ENTITLEMENTS": '"Config/KadmosFinderSync.entitlements"',
        "COMBINE_HIDPI_IMAGES": "YES",
        "INFOPLIST_FILE": '"Config/KadmosFinderSync-Info.plist"',
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks"',
        "LIBRARY_SEARCH_PATHS": '"$(inherited) $(BUILT_PRODUCTS_DIR)"',
        "PRODUCT_BUNDLE_IDENTIFIER": "com.kadmos.macos.FinderSync",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SKIP_INSTALL": "YES",
        "SWIFT_INCLUDE_PATHS": '"$(inherited) $(BUILT_PRODUCTS_DIR)"',
    }

    app_settings = {
        "CODE_SIGN_ENTITLEMENTS": '"Config/Kadmos.entitlements"',
        "COMBINE_HIDPI_IMAGES": "YES",
        "INFOPLIST_FILE": '"Config/Kadmos-Info.plist"',
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks"',
        "LIBRARY_SEARCH_PATHS": '"$(inherited) $(BUILT_PRODUCTS_DIR)"',
        "PRODUCT_BUNDLE_IDENTIFIER": "com.kadmos.macos",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_INCLUDE_PATHS": '"$(inherited) $(BUILT_PRODUCTS_DIR)"',
    }

    lines.append("/* Begin XCBuildConfiguration section */")
    lines.extend(format_cfg(proj_dbg_id, "Debug", proj_dbg_settings))
    lines.extend(format_cfg(proj_rel_id, "Release", proj_rel_settings))
    lines.extend(format_cfg(core_dbg_id, "Debug", core_settings))
    lines.extend(format_cfg(core_rel_id, "Release", core_settings))
    lines.extend(format_cfg(finder_dbg_id, "Debug", finder_settings))
    lines.extend(format_cfg(finder_rel_id, "Release", finder_settings))
    lines.extend(format_cfg(app_dbg_id, "Debug", app_settings))
    lines.extend(format_cfg(app_rel_id, "Release", app_settings))
    lines.append("/* End XCBuildConfiguration section */")
    lines.append("")

    # XCConfigurationList
    def format_cfg_list(list_id: str, comment: str, dbg: str, rel: str) -> list[str]:
        return [
            f"\t\t{list_id} /* {comment} */ = {{",
            "\t\t\tisa = XCConfigurationList;",
            "\t\t\tbuildConfigurations = (",
            f"\t\t\t\t{dbg} /* Debug */,",
            f"\t\t\t\t{rel} /* Release */,",
            "\t\t\t);",
            "\t\t\tdefaultConfigurationIsVisible = 0;",
            "\t\t\tdefaultConfigurationName = Release;",
            "\t\t};",
        ]

    lines.append("/* Begin XCConfigurationList section */")
    lines.extend(format_cfg_list(proj_cfg_list_id, 'Build configuration list for PBXProject "Kadmos"', proj_dbg_id, proj_rel_id))
    lines.extend(format_cfg_list(core_cfg_list_id, 'Build configuration list for PBXNativeTarget "KadmosCore"', core_dbg_id, core_rel_id))
    lines.extend(format_cfg_list(finder_cfg_list_id, 'Build configuration list for PBXNativeTarget "KadmosFinderSync"', finder_dbg_id, finder_rel_id))
    lines.extend(format_cfg_list(app_cfg_list_id, 'Build configuration list for PBXNativeTarget "Kadmos"', app_dbg_id, app_rel_id))
    lines.append("/* End XCConfigurationList section */")
    lines.extend([
        "",
        "\t};",
        f"\trootObject = {project_id} /* Project object */;",
        "}",
        "",
    ])

    PROJ_DIR.mkdir(parents=True, exist_ok=True)
    SCHEME_DIR.mkdir(parents=True, exist_ok=True)
    (PROJ_DIR / "project.pbxproj").write_text("\n".join(lines), encoding="utf-8")

    scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2720"
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
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target_id}"
               BuildableName = "Kadmos.app"
               BlueprintName = "Kadmos"
               ReferencedContainer = "container:Kadmos.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
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
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target_id}"
            BuildableName = "Kadmos.app"
            BlueprintName = "Kadmos"
            ReferencedContainer = "container:Kadmos.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (SCHEME_DIR / "Kadmos.xcscheme").write_text(scheme_xml, encoding="utf-8")
    print(f"Generated {PROJ_DIR} ({len(core_files)} core, {len(app_files)} app, {len(finder_files)} finder files)")


if __name__ == "__main__":
    main()
