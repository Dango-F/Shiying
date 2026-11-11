#!/usr/bin/env python3
"""Deterministically write the dependency-free Xcode project; no generator required by users."""
from pathlib import Path
import hashlib
import plistlib
import json

root = Path(__file__).resolve().parent.parent

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

objects = []
def obj(name, text):
    objects.append(f'{ident(name)} = {{ {text} }};')
    return ident(name)

def refs(names): return ', '.join(ident(n) for n in names) + (', ' if names else '')

def ref(path, kind):
    obj(path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{path}"; name = "{Path(path).name}"; sourceTree = SOURCE_ROOT;')

sources = sorted(str(p.relative_to(root)) for p in (root/'Shiying').rglob('*.swift'))
tests = sorted(str(p.relative_to(root)) for p in (root/'Tests').glob('*.swift'))
resources = ['Shiying/Resources/Localizable.xcstrings', 'Shiying/Resources/AppIcon.icon', 'Shiying/Resources/InfoPlist.xcstrings']
for path in sources + tests: ref(path, 'sourcecode.swift')
ref(resources[0], 'text.json.xcstrings'); ref(resources[1], 'folder.iconcomposer'); ref(resources[2], 'text.json.xcstrings')
for name, kind, path in [('appProduct','wrapper.application','Shiying.app'),('testProduct','wrapper.cfbundle','ShiyingTests.xctest')]:
    obj(name, f'isa = PBXFileReference; explicitFileType = {kind}; path = {path}; includeInIndex = 0; sourceTree = BUILT_PRODUCTS_DIR;')
obj('sourceGroup', f'isa = PBXGroup; name = Shiying; children = ({refs(sources + resources)}); sourceTree = "<group>";')
obj('testGroup', f'isa = PBXGroup; name = Tests; children = ({refs(tests)}); sourceTree = "<group>";')
obj('products', f'isa = PBXGroup; name = Products; children = ({refs(["appProduct", "testProduct"])}); sourceTree = "<group>";')
obj('root', f'isa = PBXGroup; children = ({refs(["sourceGroup", "testGroup", "products"])}); sourceTree = "<group>";')

common = '''SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 26.0; ARCHS = arm64; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; ENABLE_HARDENED_RUNTIME = YES; DEAD_CODE_STRIPPING = YES; SWIFT_EMIT_LOC_STRINGS = NO; LOCALIZATION_PREFERS_STRING_CATALOGS = YES; CURRENT_PROJECT_VERSION = 20; MARKETING_VERSION = 0.1.18; CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; ENABLE_APP_SANDBOX = NO; ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = NO;'''
for target in ['project', 'app', 'test']:
    for config in ['Debug', 'Release']:
        settings = common
        if config == 'Debug': settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
        else: settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Osize"; SWIFT_COMPILATION_MODE = wholemodule; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; STRIP_INSTALLED_PRODUCT = YES; COPY_PHASE_STRIP = YES;'
        if target == 'app': settings += ' CODE_SIGN_IDENTITY = "Apple Development"; DEVELOPMENT_TEAM = RQ92LHY5KA; PRODUCT_NAME = Shiying; PRODUCT_MODULE_NAME = Shiying; PRODUCT_BUNDLE_IDENTIFIER = com.shiying.mac; INFOPLIST_FILE = Config/Info.plist; GENERATE_INFOPLIST_FILE = NO; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; OTHER_LDFLAGS = "$(inherited) -lsqlite3";'
        if target == 'app' and config == 'Debug': settings += ' PRODUCT_NAME = "Shiying Dev"; PRODUCT_BUNDLE_IDENTIFIER = com.shiying.mac.dev; EXCLUDED_SOURCE_FILE_NAMES = InfoPlist.xcstrings;'
        if target == 'test': settings += ' PRODUCT_NAME = ShiyingTests; PRODUCT_BUNDLE_IDENTIFIER = com.shiying.mac.tests; GENERATE_INFOPLIST_FILE = YES; OTHER_LDFLAGS = "$(inherited) -lsqlite3"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/../Frameworks";'
        obj(target+config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {settings} }};')
    obj(target+'configs', f'isa = XCConfigurationList; buildConfigurations = ({refs([target+"Debug", target+"Release"])}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

test_sources = [p for p in sources if p != 'Shiying/AppDelegate.swift'] + tests
for target, files in [('app', sources), ('test', test_sources)]:
    for path in files: obj(target+path, f'isa = PBXBuildFile; fileRef = {ident(path)};')
    obj(target+'sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({refs([target+p for p in files])}); runOnlyForDeploymentPostprocessing = 0;')
    res = resources if target == 'app' else [resources[0]]
    for path in res: obj(target+path, f'isa = PBXBuildFile; fileRef = {ident(path)};')
    obj(target+'resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({refs([target+p for p in res]) if res else ""}); runOnlyForDeploymentPostprocessing = 0;')
    obj(target+'frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    product = 'appProduct' if target == 'app' else 'testProduct'
    product_type = 'application' if target == 'app' else 'bundle.unit-test'
    name = 'Shiying' if target == 'app' else 'ShiyingTests'
    obj(target+'target', f'isa = PBXNativeTarget; name = {name}; productName = {name}; productType = "com.apple.product-type.{product_type}"; productReference = {ident(product)}; buildConfigurationList = {ident(target+"configs")}; buildPhases = ({refs([target+"sources", target+"frameworks", target+"resources"])}); buildRules = (); dependencies = ();')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2720; BuildIndependentTargetsInParallel = YES; }}; buildConfigurationList = {ident("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, "zh-Hans", Base,); mainGroup = {ident("root")}; productRefGroup = {ident("products")}; projectDirPath = ""; projectRoot = ""; targets = ({refs(["apptarget", "testtarget"])});')
(root/'Shiying.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {ident("project")}; }}\n')
app_id, test_id = ident('apptarget'), ident('testtarget')
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Shiying Dev.app" BlueprintName="Shiying" ReferencedContainer="container:Shiying.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="ShiyingTests.xctest" BlueprintName="ShiyingTests" ReferencedContainer="container:Shiying.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Shiying Dev.app" BlueprintName="Shiying" ReferencedContainer="container:Shiying.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Shiying Dev.app" BlueprintName="Shiying" ReferencedContainer="container:Shiying.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(root/'Shiying.xcodeproj/xcshareddata/xcschemes/Shiying.xcscheme').write_text(scheme)
info = {'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleName':'$(PRODUCT_NAME)','CFBundleDisplayName':'$(PRODUCT_NAME)','LSHasLocalizedDisplayName':True,'CFBundlePackageType':'APPL','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','LSMinimumSystemVersion':'$(MACOSX_DEPLOYMENT_TARGET)','LSUIElement':True,'LSMultipleInstancesProhibited':True,'ShiyingHandlesTerminationSignal':True,'NSHighResolutionCapable':True,'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans'],'NSPrincipalClass':'NSApplication','NSPasteboardUsageDescription':'Shiying keeps clipboard fragments on this Mac so you can find and reuse them.'}
(root/'Config/Info.plist').write_bytes(plistlib.dumps(info))
print('Wrote Xcode project and shared Shiying scheme.')
