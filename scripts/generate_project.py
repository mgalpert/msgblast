#!/usr/bin/env python3
"""Create the Xcode project from the committed Swift sources."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(name, body):
    key = ident(name); objects[key] = body; return key
def seq(values): return '(' + ', '.join(values) + (',)' if values else ')')
def configs(name, settings):
    ids = []
    for mode in ['Debug', 'Release']:
        s = dict(settings)
        s.update({'SWIFT_OPTIMIZATION_LEVEL': '"-Onone"' if mode == 'Debug' else '"-O"', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '"DEBUG"' if mode == 'Debug' else '""', 'ONLY_ACTIVE_ARCH': 'YES' if mode == 'Debug' else 'NO'})
        if mode == 'Release' and name in ('msgblast', 'msgblastCore'): s['DEBUG_INFORMATION_FORMAT'] = '"dwarf-with-dsym"'
        if name == 'msgblast' and mode == 'Debug': s['CODE_SIGN_ENTITLEMENTS'] = 'msgblast/msgblastDebug.entitlements'
        ids.append(obj(name+mode, '{isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {' + ''.join(f'{k} = {v};' for k,v in s.items()) + '};}'))
    return obj(name+'configs', '{isa = XCConfigurationList; buildConfigurations = '+seq(ids)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;}')
files = {}
for p in sorted(list(root.glob('msgblast/**/*.swift')) + list(root.glob('msgblastTests/*.swift')) + list(root.glob('msgblastUITests/*.swift')) + list(root.glob('msgblastRemoteProtocolTests/*.swift')) + list(root.glob('msgblastMobile/**/*.swift')) + list(root.glob('msgblastMobileTests/*.swift'))):
    rel = str(p.relative_to(root)); files[rel] = obj(rel, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "'+rel+'"; sourceTree = SOURCE_ROOT;}')
icon = obj('msgblast/AppIcon.icon', '{isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = "msgblast/AppIcon.icon"; sourceTree = SOURCE_ROOT;}')
demo_icon = obj('msgblast/AppIconDemo.icon', '{isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = "msgblast/AppIconDemo.icon"; sourceTree = SOURCE_ROOT;}')
notice = obj('msgblast/ThirdPartyNotices.txt', '{isa = PBXFileReference; lastKnownFileType = text; path = "msgblast/ThirdPartyNotices.txt"; sourceTree = SOURCE_ROOT;}')
discover = obj('msgblast/Resources/Discover', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblast/Resources/Discover"; sourceTree = SOURCE_ROOT;}')
muse_avatar = obj('msgblast/Resources/MuseAvatar.jpg', '{isa = PBXFileReference; lastKnownFileType = image.jpeg; path = "msgblast/Resources/MuseAvatar.jpg"; sourceTree = SOURCE_ROOT;}')
web_agent_icons = obj('msgblast/Resources/WebAgentIcons', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblast/Resources/WebAgentIcons"; sourceTree = SOURCE_ROOT;}')
quick_access = obj('msgblast/Resources/QuickAccess', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblast/Resources/QuickAccess"; sourceTree = SOURCE_ROOT;}')
onboarding = obj('msgblast/Resources/Onboarding', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblast/Resources/Onboarding"; sourceTree = SOURCE_ROOT;}')
release_notes = obj('release-notes', '{isa = PBXFileReference; lastKnownFileType = folder; path = "release-notes"; sourceTree = SOURCE_ROOT;}')
cloudflared_manifest = obj('scripts/cloudflared.json', '{isa = PBXFileReference; lastKnownFileType = text.json; path = "scripts/cloudflared.json"; sourceTree = SOURCE_ROOT;}')
cloudflared_notices = obj('msgblast/Resources/CloudflaredNotices.txt', '{isa = PBXFileReference; lastKnownFileType = text; path = "msgblast/Resources/CloudflaredNotices.txt"; sourceTree = SOURCE_ROOT;}')
cua_manifest = obj('scripts/cua-driver.json', '{isa = PBXFileReference; lastKnownFileType = text.json; path = "scripts/cua-driver.json"; sourceTree = SOURCE_ROOT;}')
mobile_plist = obj('msgblastMobile/Info.plist', '{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "msgblastMobile/Info.plist"; sourceTree = SOURCE_ROOT;}')
mobile_assets = obj('msgblastMobile/Assets.xcassets', '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "msgblastMobile/Assets.xcassets"; sourceTree = SOURCE_ROOT;}')
mobile_fixtures = obj('msgblastMobileTests/Fixtures', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblastMobileTests/Fixtures"; sourceTree = SOURCE_ROOT;}')
cua_notices = obj('msgblast/Resources/CuaDriverNotices.txt', '{isa = PBXFileReference; lastKnownFileType = text; path = "msgblast/Resources/CuaDriverNotices.txt"; sourceTree = SOURCE_ROOT;}')
products = {}
# msgblastRemoteProtocol is the pure-Foundation wire contract shared with the future iOS controller.
for name, kind, ext in [('msgblastRemoteProtocol','wrapper.framework','.framework'),('msgblastCore','wrapper.framework','.framework'),('msgblast','wrapper.application','.app'),('msgblastTests','wrapper.cfbundle','.xctest'),('msgblastUITests','wrapper.cfbundle','.xctest'),('msgblastRemoteProtocolTests','wrapper.cfbundle','.xctest'),('msgblastMobileKit','wrapper.framework','.framework'),('msgblastMobile','wrapper.application','.app'),('msgblastMobileTests','wrapper.cfbundle','.xctest')]:
    products[name] = obj(name+'product', '{isa = PBXFileReference; explicitFileType = '+kind+'; path = '+name+ext+'; sourceTree = BUILT_PRODUCTS_DIR;}')
product_group = obj('products', '{isa = PBXGroup; name = Products; sourceTree = "<group>"; children = '+seq(list(products.values()))+';}')
main_group = obj('mainGroup', '{isa = PBXGroup; sourceTree = "<group>"; children = '+seq(list(files.values())+[icon, demo_icon, notice, discover, muse_avatar, web_agent_icons, onboarding, release_notes, cloudflared_manifest, cloudflared_notices, cua_manifest, cua_notices, mobile_plist, mobile_assets, mobile_fixtures, product_group])+';}')
sparkle_package = obj('SparklePackage', '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = {kind = exactVersion; version = 2.10.0;};}')
sparkle_product = obj('SparkleProduct', '{isa = XCSwiftPackageProductDependency; package = '+sparkle_package+'; productName = Sparkle;}')
cookie_package = obj('SweetCookieKitPackage', '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/steipete/SweetCookieKit"; requirement = {kind = revision; revision = 29e7af6bb71f1b624380ab556330e8be8f7ddd65;};}')
cookie_product = obj('SweetCookieKitProduct', '{isa = XCSwiftPackageProductDependency; package = '+cookie_package+'; productName = SweetCookieKit;}')
targets = {}
for name in products:
    prefixes = {'msgblastCore': 'msgblast/Core/', 'msgblastRemoteProtocol': 'msgblast/RemoteProtocol/', 'msgblastTests': 'msgblastTests/', 'msgblastUITests': 'msgblastUITests/', 'msgblastRemoteProtocolTests': 'msgblastRemoteProtocolTests/', 'msgblastMobileKit': 'msgblastMobile/Kit/', 'msgblastMobileTests': 'msgblastMobileTests/'}
    if name == 'msgblastMobile': own = [p for p in files if p.startswith('msgblastMobile/') and not p.startswith('msgblastMobile/Kit/')]
    else: own = [p for p in files if (p.startswith(prefixes[name]) if name in prefixes else p.startswith('msgblast/') and not p.startswith('msgblast/Core/') and not p.startswith('msgblast/RemoteProtocol/'))]
    if name == 'msgblastTests': own.append('msgblast/Permissions/MessagesAccessGuide.swift')
    builds = [obj(name+p+'build', '{isa = PBXBuildFile; fileRef = '+files[p]+';}') for p in own]
    sources = obj(name+'sources', '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+seq(builds)+'; runOnlyForDeploymentPostprocessing = 0;}')
    framework_builds = []
    dependencies = []
    if name not in ('msgblastCore','msgblastUITests','msgblastRemoteProtocol','msgblastRemoteProtocolTests','msgblastMobile','msgblastMobileTests','msgblastMobileKit'):
        framework_builds.append(obj(name+'linkCore', '{isa = PBXBuildFile; fileRef = '+products['msgblastCore']+';}'))
        dependencies.append(obj(name+'dep', '{isa = PBXTargetDependency; target = '+ident('msgblastCoretarget')+';}'))
    if name in ('msgblast','msgblastCore','msgblastTests','msgblastRemoteProtocolTests','msgblastMobile','msgblastMobileTests','msgblastMobileKit'):
        framework_builds.append(obj(name+'linkRemoteProtocol', '{isa = PBXBuildFile; fileRef = '+products['msgblastRemoteProtocol']+';}'))
        dependencies.append(obj(name+'remoteProtocolDep', '{isa = PBXTargetDependency; target = '+ident('msgblastRemoteProtocoltarget')+';}'))
    if name == 'msgblast':
        framework_builds.append(obj('linkSparkle', '{isa = PBXBuildFile; productRef = '+sparkle_product+';}'))
    if name == 'msgblastCore':
        framework_builds.append(obj('linkSweetCookieKit', '{isa = PBXBuildFile; productRef = '+cookie_product+';}'))
    framework_phase = obj(name+'frameworks', '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = '+seq(framework_builds)+'; runOnlyForDeploymentPostprocessing = 0;}')
    phases = [sources, framework_phase]
    settings = {'PRODUCT_NAME': '"$(TARGET_NAME)"', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.msgblast.'+name, 'MACOSX_DEPLOYMENT_TARGET': '15.0', 'SWIFT_VERSION': '6.0', 'CODE_SIGN_STYLE': 'Automatic', 'CODE_SIGN_IDENTITY': '"-"', 'ENABLE_HARDENED_RUNTIME': 'YES' if name == 'msgblast' else 'NO', 'ENABLE_TESTABILITY': 'YES', 'GENERATE_INFOPLIST_FILE': 'YES', 'LD_RUNPATH_SEARCH_PATHS': '"$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks"'}
    if name == 'msgblastUITests':
        settings['TEST_TARGET_NAME'] = 'msgblast'
        dependencies.append(obj(name+'dep', '{isa = PBXTargetDependency; target = '+ident('msgblasttarget')+';}'))
    if name == 'msgblastCore':
        settings.update({'DEFINES_MODULE':'YES', 'DYLIB_INSTALL_NAME_BASE':'"@rpath"', 'SKIP_INSTALL':'YES', 'OTHER_LDFLAGS':'"$(inherited) -lsqlite3"'})
    if name in ('msgblastRemoteProtocol', 'msgblastRemoteProtocolTests'):
        # Foundation and CryptoKit only, so the iOS controller can link the same framework.
        settings.update({'SDKROOT':'auto', 'SUPPORTED_PLATFORMS':'"macosx iphoneos iphonesimulator"', 'IPHONEOS_DEPLOYMENT_TARGET':'26.0', 'TARGETED_DEVICE_FAMILY':'"1,2"', 'SUPPORTS_MACCATALYST':'NO'})
    if name in ('msgblastMobile', 'msgblastMobileTests'):
        framework_builds.append(obj(name+'linkMobileKit', '{isa = PBXBuildFile; fileRef = '+products['msgblastMobileKit']+';}'))
        dependencies.append(obj(name+'mobileKitDep', '{isa = PBXTargetDependency; target = '+ident('msgblastMobileKittarget')+';}'))
    if name in ('msgblastMobileKit', 'msgblastMobileTests'):
        # Controller logic without UIKit: builds and tests on macOS and in the iOS simulator.
        settings.update({'SDKROOT':'auto', 'SUPPORTED_PLATFORMS':'"macosx iphoneos iphonesimulator"', 'IPHONEOS_DEPLOYMENT_TARGET':'26.0', 'TARGETED_DEVICE_FAMILY':'"1,2"', 'SUPPORTS_MACCATALYST':'NO',
                         'LD_RUNPATH_SEARCH_PATHS':'"$(inherited) @executable_path/Frameworks @loader_path/Frameworks @executable_path/../Frameworks @loader_path/../Frameworks"'})
    if name == 'msgblastMobileKit':
        settings.update({'DEFINES_MODULE':'YES', 'DYLIB_INSTALL_NAME_BASE':'"@rpath"', 'SKIP_INSTALL':'YES', 'OTHER_LDFLAGS':'"$(inherited) -lsqlite3"', 'PRODUCT_BUNDLE_IDENTIFIER':'com.msgblast.ios.kit'})
    if name == 'msgblastMobile':
        # The iOS controller (phase 2). No team is committed; contributors sign locally.
        settings.update({'SDKROOT':'iphoneos', 'SUPPORTED_PLATFORMS':'"iphoneos iphonesimulator"', 'IPHONEOS_DEPLOYMENT_TARGET':'26.0', 'TARGETED_DEVICE_FAMILY':'"1,2"',
                         'LD_RUNPATH_SEARCH_PATHS':'"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"', 'SUPPORTS_MACCATALYST':'NO'})
        del settings['CODE_SIGN_IDENTITY']
    if name == 'msgblastMobile':
        settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.msgblast.ios', 'PRODUCT_NAME':'msgblastMobile', 'INFOPLIST_FILE':'msgblastMobile/Info.plist', 'MARKETING_VERSION':'0.1.0', 'CURRENT_PROJECT_VERSION':'1',
                         'INFOPLIST_KEY_CFBundleDisplayName':'msgblast', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES',
                         'INFOPLIST_KEY_UISupportedInterfaceOrientations':'"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
                         'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
                         'INFOPLIST_KEY_NSCameraUsageDescription':'"msgblast uses the camera to scan the pairing code shown on your Mac and to take photos you send from your Mac."',
                         'INFOPLIST_KEY_NSLocalNetworkUsageDescription':'"msgblast connects to msgblast on your Mac over your local network or Tailscale."',
                         'INFOPLIST_KEY_NSPhotoLibraryUsageDescription':'"msgblast sends the photos you choose to your Messages agents through your Mac."',
                         # The phone uses the canonical green live icon bundle, unmodified; the interface keeps the system blue tint, as Messages does.
                         'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'})
    if name == 'msgblastMobileTests':
        settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.msgblast.ios.tests'})
        fixture_build = obj('mobileFixturesBuild', '{isa = PBXBuildFile; fileRef = '+mobile_fixtures+';}')
        phases.append(obj('mobileTestResources', '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+seq([fixture_build])+'; runOnlyForDeploymentPostprocessing = 0;}'))
    if name == 'msgblastMobile':
        embed_mobile = obj('embedMobileRemoteProtocolBuild','{isa = PBXBuildFile; fileRef = '+products['msgblastRemoteProtocol']+'; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,);};}')
        embed_kit = obj('embedMobileKitBuild','{isa = PBXBuildFile; fileRef = '+products['msgblastMobileKit']+'; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,);};}')
        mobile_icon_build = obj('mobileAppIconBuild', '{isa = PBXBuildFile; fileRef = '+icon+';}')
        mobile_assets_build = obj('mobileAssetsBuild', '{isa = PBXBuildFile; fileRef = '+mobile_assets+';}')
        phases.append(obj('mobileResources', '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+seq([mobile_icon_build, mobile_assets_build])+'; runOnlyForDeploymentPostprocessing = 0;}'))
        phases.append(obj('embedMobileFrameworks','{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = '+seq([embed_mobile, embed_kit])+'; name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0;}'))
    if name == 'msgblastRemoteProtocol':
        settings.update({'DEFINES_MODULE':'YES', 'DYLIB_INSTALL_NAME_BASE':'"@rpath"', 'SKIP_INSTALL':'YES', 'LD_RUNPATH_SEARCH_PATHS':'"$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks @executable_path/Frameworks @loader_path/Frameworks"'})
    if name == 'msgblast':
        settings.update({'GENERATE_INFOPLIST_FILE':'NO', 'INFOPLIST_FILE':'msgblast/Info.plist', 'CODE_SIGN_ENTITLEMENTS':'msgblast/msgblast.entitlements', 'MSGBLAST_APP_BUNDLE_IDENTIFIER':'com.msgblast.mac', 'PRODUCT_BUNDLE_IDENTIFIER':'"$(MSGBLAST_APP_BUNDLE_IDENTIFIER)"', 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'MARKETING_VERSION':'0.9.0', 'CURRENT_PROJECT_VERSION':'1', 'MSGBLAST_TELEMETRY_ENDPOINT':'""', 'SPARKLE_FEED_URL':'""', 'SPARKLE_PUBLIC_ED_KEY':'""'})
        icon_build = obj('appIconBuild', '{isa = PBXBuildFile; fileRef = '+icon+';}')
        demo_icon_build = obj('demoAppIconBuild', '{isa = PBXBuildFile; fileRef = '+demo_icon+';}')
        notice_build = obj('thirdPartyNoticeBuild', '{isa = PBXBuildFile; fileRef = '+notice+';}')
        discover_build = obj('discoverResourcesBuild', '{isa = PBXBuildFile; fileRef = '+discover+';}')
        muse_avatar_build = obj('museAvatarBuild', '{isa = PBXBuildFile; fileRef = '+muse_avatar+';}')
        web_agent_icons_build = obj('webAgentIconsBuild', '{isa = PBXBuildFile; fileRef = '+web_agent_icons+';}')
        quick_access_build = obj('quickAccessResourcesBuild', '{isa = PBXBuildFile; fileRef = '+quick_access+';}')
        onboarding_build = obj('onboardingResourcesBuild', '{isa = PBXBuildFile; fileRef = '+onboarding+';}')
        release_notes_build = obj('releaseNotesBuild', '{isa = PBXBuildFile; fileRef = '+release_notes+';}')
        cloudflared_manifest_build = obj('cloudflaredManifestBuild', '{isa = PBXBuildFile; fileRef = '+cloudflared_manifest+';}')
        cloudflared_notices_build = obj('cloudflaredNoticesBuild', '{isa = PBXBuildFile; fileRef = '+cloudflared_notices+';}')
        cua_manifest_build = obj('cuaManifestBuild', '{isa = PBXBuildFile; fileRef = '+cua_manifest+';}')
        cua_notices_build = obj('cuaNoticesBuild', '{isa = PBXBuildFile; fileRef = '+cua_notices+';}')
        phases.append(obj('appResources', '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+seq([icon_build, demo_icon_build, notice_build, discover_build, muse_avatar_build, web_agent_icons_build, quick_access_build, onboarding_build, release_notes_build, cloudflared_manifest_build, cloudflared_notices_build, cua_manifest_build, cua_notices_build])+'; runOnlyForDeploymentPostprocessing = 0;}'))
        helper_command = '/usr/bin/env python3 "${SRCROOT}/scripts/bundle_cloudflared.py" --archs "${ARCHS}" --destination "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/cloudflared" --cache "${PROJECT_TEMP_DIR}/cloudflared"'
        phases.append(obj('bundleCloudflared', '{isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = '+seq(['"$(SRCROOT)/scripts/bundle_cloudflared.py"', '"$(SRCROOT)/scripts/cloudflared.json"'])+'; name = "Bundle pinned cloudflared"; outputPaths = '+seq(['"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/cloudflared"'])+'; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = '+json.dumps(helper_command)+';}'))
        cua_command = '/usr/bin/env python3 "${SRCROOT}/scripts/bundle_cua_driver.py" --archs "${ARCHS}" --destination "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/cua-driver" --cache "${PROJECT_TEMP_DIR}/cua-driver"'
        phases.append(obj('bundleCuaDriver', '{isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = '+seq(['"$(SRCROOT)/scripts/bundle_cua_driver.py"', '"$(SRCROOT)/scripts/cua-driver.json"'])+'; name = "Bundle pinned CuaDriver"; outputPaths = '+seq(['"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/cua-driver"'])+'; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = '+json.dumps(cua_command)+';}'))
        embed = obj('embedCoreBuild','{isa = PBXBuildFile; fileRef = '+products['msgblastCore']+'; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,);};}')
        embed_protocol = obj('embedRemoteProtocolBuild','{isa = PBXBuildFile; fileRef = '+products['msgblastRemoteProtocol']+'; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,);};}')
        phases.append(obj('embedCore','{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = '+seq([embed, embed_protocol])+'; name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0;}'))
    config = configs(name, settings)
    type_ = 'framework' if name in ('msgblastCore', 'msgblastRemoteProtocol', 'msgblastMobileKit') else 'application' if name in ('msgblast', 'msgblastMobile') else 'bundle.ui-testing' if name == 'msgblastUITests' else 'bundle.unit-test'
    targets[name] = obj(name+'target', '{isa = PBXNativeTarget; name = '+name+'; productName = '+name+'; productReference = '+products[name]+'; productType = "com.apple.product-type.'+type_+'"; buildConfigurationList = '+config+'; buildPhases = '+seq(phases)+'; buildRules = (); dependencies = '+seq(dependencies)+'; packageProductDependencies = '+seq([sparkle_product] if name == 'msgblast' else [cookie_product] if name == 'msgblastCore' else [])+';}')
project_config = configs('project', {'SDKROOT':'macosx', 'CLANG_ENABLE_MODULES':'YES', 'SWIFT_VERSION':'6.0', 'MACOSX_DEPLOYMENT_TARGET':'15.0'})
project = obj('project', '{isa = PBXProject; attributes = {LastUpgradeCheck = 2700;}; buildConfigurationList = '+project_config+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = '+main_group+'; productRefGroup = '+product_group+'; projectDirPath = ""; projectRoot = ""; packageReferences = '+seq([sparkle_package, cookie_package])+'; targets = '+seq(list(targets.values()))+';}')
dest = root / 'msgblast.xcodeproj'; dest.mkdir(exist_ok=True)
(dest/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{k} = {v};' for k,v in objects.items())+'\n}; rootObject = '+project+';}\n')
schemes = dest/'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
def ref(name, suffix): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets[name]}" BuildableName="{name}{suffix}" BlueprintName="{name}" ReferencedContainer="container:msgblast.xcodeproj"/>'
(schemes/'msgblast.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('msgblast','.app')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastTests','.xctest')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastUITests','.xctest')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastRemoteProtocolTests','.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('msgblastTests','.xctest')}</TestableReference><TestableReference skipped="NO">{ref('msgblastUITests','.xctest')}</TestableReference><TestableReference skipped="NO">{ref('msgblastRemoteProtocolTests','.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('msgblast','.app')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('msgblast','.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
(schemes/'msgblastMobile.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('msgblastMobile','.app')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastMobileTests','.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('msgblastMobileTests','.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('msgblastMobile','.app')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('msgblastMobile','.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
# The controller logic and its tests also run on macOS, where no simulator is needed.
(schemes/'msgblastMobileKit.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastMobileKit','.framework')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastMobileTests','.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('msgblastMobileTests','.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(dest)
