"""Generate the checked-in Xcode project without third-party build dependencies."""
from pathlib import Path
import hashlib
import plistlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
def uid(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def quoted(value): return '"' + value.replace('"', '\\"') + '"'
# Preserve the user's signing choices if Xcode has configured an existing project.
previous_configs = {}
project_file = ROOT / 'MotionLink.xcodeproj/project.pbxproj'
if project_file.exists():
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(project_file)], capture_output=True, text=True, check=True)
    previous_configs = json.loads(result.stdout).get('objects', {})
objects = []
def obj(key, body):
    ident = uid(key)
    objects.append(f'{ident} = {{ {body} }};')
    return ident

def settings(values):
    return '{ ' + ' '.join(f'{k} = {v};' for k, v in values.items()) + ' }'

products = []
targets = []
source_groups = []
for platform, name, bundle, sdk, deployment in [
    ('iOS', 'MotionLinkPhone', 'com.motionlink.phone', 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET = 17.0;'),
    ('macOS', 'MotionLinkMac', 'com.motionlink.mac', 'macosx', 'MACOSX_DEPLOYMENT_TARGET = 14.0;')]:
    paths = sorted((ROOT / 'Shared').glob('*.swift')) + sorted((ROOT / platform).glob('*.swift'))
    refs, builds = [], []
    for path in paths:
        rel = str(path.relative_to(ROOT))
        ref = obj(f'{name}-{rel}-ref', f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(rel)}; sourceTree = SOURCE_ROOT;')
        refs.append(ref)
        builds.append(obj(f'{name}-{rel}-build', f'isa = PBXBuildFile; fileRef = {ref};'))
    source_groups.append(obj(name+'-group', f'isa = PBXGroup; children = ({",".join(refs)},); name = {name}; sourceTree = "<group>";'))
    product = obj(name+'-product', f'isa = PBXFileReference; explicitFileType = wrapper.application; path = {name}.app; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    sources = obj(name+'-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
    assets = obj(name+'-assets', f'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {platform}/Assets.xcassets; sourceTree = SOURCE_ROOT;')
    asset_build = obj(name+'-asset-build', f'isa = PBXBuildFile; fileRef = {assets};')
    resources = obj(name+'-resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({asset_build},); runOnlyForDeploymentPostprocessing = 0;')
    configurations = []
    for mode in ['Debug', 'Release']:
        values = {
            'PRODUCT_NAME': '"$(TARGET_NAME)"', 'PRODUCT_BUNDLE_IDENTIFIER': bundle,
            'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
            'SDKROOT': sdk, 'SWIFT_VERSION': '6.0', 'SWIFT_STRICT_CONCURRENCY': 'complete',
            'CODE_SIGN_STYLE': 'Automatic', 'INFOPLIST_FILE': quoted(platform+'/Info.plist'),
            'GENERATE_INFOPLIST_FILE': 'NO', 'MARKETING_VERSION': '1.0', 'CURRENT_PROJECT_VERSION': '1',
            'SWIFT_OPTIMIZATION_LEVEL': quoted('-Onone' if mode == 'Debug' else '-O'),
            'ENABLE_HARDENED_RUNTIME': 'YES', 'LD_RUNPATH_SEARCH_PATHS': quoted('$(inherited) @executable_path/../Frameworks' if platform == 'macOS' else '$(inherited) @executable_path/Frameworks'),
        }
        if platform == 'macOS': values['CODE_SIGN_ENTITLEMENTS'] = 'macOS/MotionLink.entitlements'
        else:
            values['TARGETED_DEVICE_FAMILY'] = '1'
            values['SUPPORTED_PLATFORMS'] = '"iphoneos iphonesimulator"'
            values['SUPPORTS_MACCATALYST'] = 'NO'
        previous = previous_configs.get(uid(name+mode), {}).get('buildSettings', {})
        for key in ['DEVELOPMENT_TEAM', 'PRODUCT_BUNDLE_IDENTIFIER', 'PROVISIONING_PROFILE_SPECIFIER', 'CODE_SIGN_IDENTITY', 'CODE_SIGN_STYLE']:
            if key in previous: values[key] = quoted(str(previous[key]))
        configurations.append(obj(name+mode, f'isa = XCBuildConfiguration; buildSettings = {settings(values)}; {deployment} name = {mode};'.replace(f'; {deployment}', ';')))
        # Deployment belongs inside buildSettings.
        objects[-1] = objects[-1].replace('buildSettings = { ', 'buildSettings = { '+deployment+' ')
    config_list = obj(name+'-configlist', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configurations)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    target = obj(name, f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = ({sources},{resources},); buildRules = (); dependencies = (); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.application";')
    targets.append(target)
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:MotionLink.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:MotionLink.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:MotionLink.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    (ROOT / 'MotionLink.xcodeproj/xcshareddata/xcschemes' / (name+'.xcscheme')).write_text(scheme)
    info = {
        'CFBundleDevelopmentRegion': 'en', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'MotionLink', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
        'NSLocalNetworkUsageDescription': 'MotionLink connects your iPhone and Mac to share live motion on your local network.',
        'NSBonjourServices': ['_motionlink._tcp'],
    }
    if platform == 'iOS':
        info.update({'NSMotionUsageDescription': 'MotionLink uses your gyroscope and accelerometer to mirror your iPhone orientation on your Mac.',
                     'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
                     'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}})
    else: info['LSMinimumSystemVersion'] = '$(MACOSX_DEPLOYMENT_TARGET)'
    with (ROOT / platform / 'Info.plist').open('wb') as f: plistlib.dump(info, f)

product_group = obj('products', f'isa = PBXGroup; children = ({",".join(products)},); name = Products; sourceTree = "<group>";')
main_group = obj('main-group', f'isa = PBXGroup; children = ({",".join(source_groups)},{product_group},); sourceTree = "<group>";')
project_configs = []
for mode in ['Debug', 'Release']:
    project_configs.append(obj('project'+mode, f'isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_MODULES = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = {"DEBUG" if mode == "Debug" else quoted("")}; }}; name = {mode};'))
project_config = obj('project-config', f'isa = XCConfigurationList; buildConfigurations = ({",".join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project = obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660; }}; buildConfigurationList = {project_config}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(targets)},);')
(ROOT / 'MotionLink.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+project+'; }\n')
