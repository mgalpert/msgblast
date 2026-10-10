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
        s.update({'SWIFT_OPTIMIZATION_LEVEL': '"-Onone"' if mode == 'Debug' else '"-O"', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '"DEBUG"' if mode == 'Debug' else '""'})
        if name == 'msgblast' and mode == 'Debug': s['CODE_SIGN_ENTITLEMENTS'] = 'msgblast/msgblastDebug.entitlements'
        ids.append(obj(name+mode, '{isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {' + ''.join(f'{k} = {v};' for k,v in s.items()) + '};}'))
    return obj(name+'configs', '{isa = XCConfigurationList; buildConfigurations = '+seq(ids)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;}')
files = {}
for p in sorted(list(root.glob('msgblast/**/*.swift')) + list(root.glob('msgblastTests/*.swift')) + list(root.glob('msgblastUITests/*.swift'))):
    rel = str(p.relative_to(root)); files[rel] = obj(rel, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "'+rel+'"; sourceTree = SOURCE_ROOT;}')
icon = obj('msgblast/AppIcon.icon', '{isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = "msgblast/AppIcon.icon"; sourceTree = SOURCE_ROOT;}')
demo_icon = obj('msgblast/AppIconDemo.icon', '{isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = "msgblast/AppIconDemo.icon"; sourceTree = SOURCE_ROOT;}')
notice = obj('msgblast/ThirdPartyNotices.txt', '{isa = PBXFileReference; lastKnownFileType = text; path = "msgblast/ThirdPartyNotices.txt"; sourceTree = SOURCE_ROOT;}')
discover = obj('msgblast/Resources/Discover', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblast/Resources/Discover"; sourceTree = SOURCE_ROOT;}')
muse_avatar = obj('msgblast/Resources/MuseAvatar.jpg', '{isa = PBXFileReference; lastKnownFileType = image.jpeg; path = "msgblast/Resources/MuseAvatar.jpg"; sourceTree = SOURCE_ROOT;}')
web_agent_icons = obj('msgblast/Resources/WebAgentIcons', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblast/Resources/WebAgentIcons"; sourceTree = SOURCE_ROOT;}')
onboarding = obj('msgblast/Resources/Onboarding', '{isa = PBXFileReference; lastKnownFileType = folder; path = "msgblast/Resources/Onboarding"; sourceTree = SOURCE_ROOT;}')
release_notes = obj('release-notes', '{isa = PBXFileReference; lastKnownFileType = folder; path = "release-notes"; sourceTree = SOURCE_ROOT;}')
cloudflared_manifest = obj('scripts/cloudflared.json', '{isa = PBXFileReference; lastKnownFileType = text.json; path = "scripts/cloudflared.json"; sourceTree = SOURCE_ROOT;}')
cloudflared_notices = obj('msgblast/Resources/CloudflaredNotices.txt', '{isa = PBXFileReference; lastKnownFileType = text; path = "msgblast/Resources/CloudflaredNotices.txt"; sourceTree = SOURCE_ROOT;}')
products = {}
for name, kind, ext in [('msgblastCore','wrapper.framework','.framework'),('msgblast','wrapper.application','.app'),('msgblastTests','wrapper.cfbundle','.xctest'),('msgblastUITests','wrapper.cfbundle','.xctest')]:
    products[name] = obj(name+'product', '{isa = PBXFileReference; explicitFileType = '+kind+'; path = '+name+ext+'; sourceTree = BUILT_PRODUCTS_DIR;}')
product_group = obj('products', '{isa = PBXGroup; name = Products; sourceTree = "<group>"; children = '+seq(list(products.values()))+';}')
main_group = obj('mainGroup', '{isa = PBXGroup; sourceTree = "<group>"; children = '+seq(list(files.values())+[icon, demo_icon, notice, discover, muse_avatar, web_agent_icons, onboarding, release_notes, cloudflared_manifest, cloudflared_notices, product_group])+';}')
sparkle_package = obj('SparklePackage', '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = {kind = exactVersion; version = 2.10.0;};}')
sparkle_product = obj('SparkleProduct', '{isa = XCSwiftPackageProductDependency; package = '+sparkle_package+'; productName = Sparkle;}')
cookie_package = obj('SweetCookieKitPackage', '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/steipete/SweetCookieKit"; requirement = {kind = revision; revision = 29e7af6bb71f1b624380ab556330e8be8f7ddd65;};}')
cookie_product = obj('SweetCookieKitProduct', '{isa = XCSwiftPackageProductDependency; package = '+cookie_package+'; productName = SweetCookieKit;}')
targets = {}
for name in products:
    own = [p for p in files if (p.startswith('msgblast/Core/') if name == 'msgblastCore' else p.startswith('msgblastTests/') if name == 'msgblastTests' else p.startswith('msgblastUITests/') if name == 'msgblastUITests' else p.startswith('msgblast/') and not p.startswith('msgblast/Core/'))]
    if name == 'msgblastTests': own.append('msgblast/Permissions/MessagesAccessGuide.swift')
    builds = [obj(name+p+'build', '{isa = PBXBuildFile; fileRef = '+files[p]+';}') for p in own]
    sources = obj(name+'sources', '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+seq(builds)+'; runOnlyForDeploymentPostprocessing = 0;}')
    framework_builds = []
    dependencies = []
    if name not in ('msgblastCore','msgblastUITests'):
        framework_builds.append(obj(name+'linkCore', '{isa = PBXBuildFile; fileRef = '+products['msgblastCore']+';}'))
        dependencies.append(obj(name+'dep', '{isa = PBXTargetDependency; target = '+ident('msgblastCoretarget')+';}'))
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
    if name == 'msgblast':
        settings.update({'GENERATE_INFOPLIST_FILE':'NO', 'INFOPLIST_FILE':'msgblast/Info.plist', 'CODE_SIGN_ENTITLEMENTS':'msgblast/msgblast.entitlements', 'MSGBLAST_APP_BUNDLE_IDENTIFIER':'com.msgblast.mac', 'PRODUCT_BUNDLE_IDENTIFIER':'"$(MSGBLAST_APP_BUNDLE_IDENTIFIER)"', 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'MARKETING_VERSION':'0.4.3', 'CURRENT_PROJECT_VERSION':'1', 'SPARKLE_FEED_URL':'""', 'SPARKLE_PUBLIC_ED_KEY':'""'})
        icon_build = obj('appIconBuild', '{isa = PBXBuildFile; fileRef = '+icon+';}')
        demo_icon_build = obj('demoAppIconBuild', '{isa = PBXBuildFile; fileRef = '+demo_icon+';}')
        notice_build = obj('thirdPartyNoticeBuild', '{isa = PBXBuildFile; fileRef = '+notice+';}')
        discover_build = obj('discoverResourcesBuild', '{isa = PBXBuildFile; fileRef = '+discover+';}')
        muse_avatar_build = obj('museAvatarBuild', '{isa = PBXBuildFile; fileRef = '+muse_avatar+';}')
        web_agent_icons_build = obj('webAgentIconsBuild', '{isa = PBXBuildFile; fileRef = '+web_agent_icons+';}')
        onboarding_build = obj('onboardingResourcesBuild', '{isa = PBXBuildFile; fileRef = '+onboarding+';}')
        release_notes_build = obj('releaseNotesBuild', '{isa = PBXBuildFile; fileRef = '+release_notes+';}')
        cloudflared_manifest_build = obj('cloudflaredManifestBuild', '{isa = PBXBuildFile; fileRef = '+cloudflared_manifest+';}')
        cloudflared_notices_build = obj('cloudflaredNoticesBuild', '{isa = PBXBuildFile; fileRef = '+cloudflared_notices+';}')
        phases.append(obj('appResources', '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+seq([icon_build, demo_icon_build, notice_build, discover_build, muse_avatar_build, web_agent_icons_build, onboarding_build, release_notes_build, cloudflared_manifest_build, cloudflared_notices_build])+'; runOnlyForDeploymentPostprocessing = 0;}'))
        helper_command = '/usr/bin/env python3 "${SRCROOT}/scripts/bundle_cloudflared.py" --archs "${ARCHS}" --destination "${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/cloudflared" --cache "${PROJECT_TEMP_DIR}/cloudflared"'
        phases.append(obj('bundleCloudflared', '{isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = '+seq(['"$(SRCROOT)/scripts/bundle_cloudflared.py"', '"$(SRCROOT)/scripts/cloudflared.json"'])+'; name = "Bundle pinned cloudflared"; outputPaths = '+seq(['"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/cloudflared"'])+'; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = '+json.dumps(helper_command)+';}'))
        embed = obj('embedCoreBuild','{isa = PBXBuildFile; fileRef = '+products['msgblastCore']+'; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,);};}')
        phases.append(obj('embedCore','{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = '+seq([embed])+'; name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0;}'))
    config = configs(name, settings)
    type_ = 'framework' if name == 'msgblastCore' else 'application' if name == 'msgblast' else 'bundle.ui-testing' if name == 'msgblastUITests' else 'bundle.unit-test'
    targets[name] = obj(name+'target', '{isa = PBXNativeTarget; name = '+name+'; productName = '+name+'; productReference = '+products[name]+'; productType = "com.apple.product-type.'+type_+'"; buildConfigurationList = '+config+'; buildPhases = '+seq(phases)+'; buildRules = (); dependencies = '+seq(dependencies)+'; packageProductDependencies = '+seq([sparkle_product] if name == 'msgblast' else [cookie_product] if name == 'msgblastCore' else [])+';}')
project_config = configs('project', {'SDKROOT':'macosx', 'CLANG_ENABLE_MODULES':'YES', 'SWIFT_VERSION':'6.0', 'MACOSX_DEPLOYMENT_TARGET':'15.0'})
project = obj('project', '{isa = PBXProject; attributes = {LastUpgradeCheck = 2700;}; buildConfigurationList = '+project_config+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = '+main_group+'; productRefGroup = '+product_group+'; projectDirPath = ""; projectRoot = ""; packageReferences = '+seq([sparkle_package, cookie_package])+'; targets = '+seq(list(targets.values()))+';}')
dest = root / 'msgblast.xcodeproj'; dest.mkdir(exist_ok=True)
(dest/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{k} = {v};' for k,v in objects.items())+'\n}; rootObject = '+project+';}\n')
schemes = dest/'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
def ref(name, suffix): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets[name]}" BuildableName="{name}{suffix}" BlueprintName="{name}" ReferencedContainer="container:msgblast.xcodeproj"/>'
(schemes/'msgblast.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('msgblast','.app')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastTests','.xctest')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('msgblastUITests','.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('msgblastTests','.xctest')}</TestableReference><TestableReference skipped="NO">{ref('msgblastUITests','.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('msgblast','.app')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('msgblast','.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(dest)
