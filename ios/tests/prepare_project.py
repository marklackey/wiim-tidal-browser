"""Create an isolated Xcode project with unit/UI tests and no live account or WiiM traffic."""
from pathlib import Path
import shutil
import sys

source = Path(__file__).resolve().parents[1]
root = Path(sys.argv[1]).resolve()
project = root / 'ios'
shutil.copytree(source / 'WiiMTIDAL', project / 'WiiMTIDAL', dirs_exist_ok=True)
shutil.copytree(source / 'WiiMWidget', project / 'WiiMWidget', dirs_exist_ok=True)
shutil.copytree(source / 'WiiMTIDAL.xcodeproj', project / 'WiiMTIDAL.xcodeproj', ignore=shutil.ignore_patterns('xcuserdata'), dirs_exist_ok=True)
for name in ['catalog_bridge.py', 'bundle-python.sh']:
    shutil.copy(source / name, project / name)
if not (project / '.python').exists(): (project / '.python').symlink_to(source / '.python')
if not (root / 'src').exists(): (root / 'src').symlink_to(source.parent / 'src')
for name in ['PlayerTests.swift', 'PlayerUITests.swift']:
    shutil.copy(source / 'tests' / name, project / name)
shutil.copy(source / 'tests' / 'UITestFixtures.swift', project / 'WiiMTIDAL' / 'UITestFixtures.swift')

app = project / 'WiiMTIDAL' / 'WiiMTIDALApp.swift'
s = app.read_text().replace('struct WiiMTIDALApp: App {', 'struct WiiMTIDALApp: App {\n    init() { UITestFixtures.configure() }')
s = s.replace('WindowGroup { ContentView() }', 'WindowGroup { ContentView().preferredColorScheme(UITestFixtures.mode == "appearance" || UITestFixtures.mode.hasSuffix("Large") ? .dark : nil).environment(\\.dynamicTypeSize, UITestFixtures.mode == "appearance" || UITestFixtures.mode.hasSuffix("Large") ? .accessibility3 : .large) }')
app.write_text(s)
client = project / 'WiiMTIDAL' / 'WiiMClient.swift'
s = client.read_text().replace('self.address = address\n        configuration.', 'self.address = address\n        if UITestFixtures.enabled { configuration.protocolClasses = [UITestHTTP.self] }\n        configuration.')
client.write_text(s)
catalog = project / 'WiiMTIDAL' / 'Catalog.swift'
s = catalog.read_text().replace('        let request = try JSONSerialization.data(withJSONObject: parameters)', '        if UITestFixtures.enabled {\n            return try JSONDecoder().decode(resultType, from: UITestFixtures.catalog(action, parameters))\n        }\n        let request = try JSONSerialization.data(withJSONObject: parameters)')
catalog.write_text(s)
view = project / 'WiiMTIDAL' / 'CatalogView.swift'
s = view.read_text().replace('openURL(login.url)', 'if !UITestFixtures.enabled { openURL(login.url) }').replace('openURL(url)', 'if !UITestFixtures.enabled { openURL(url) }')
view.write_text(s)

pbx = project / 'WiiMTIDAL.xcodeproj' / 'project.pbxproj'
s = pbx.read_text()
objects = [
    'C00000000000000000000F01 = {isa = PBXContainerItemProxy; containerPortal = A0000000000000000000000C; proxyType = 1; remoteGlobalIDString = A0000000000000000000000B; remoteInfo = WiiMTIDAL; };',
    'C00000000000000000000F02 = {isa = PBXTargetDependency; target = A0000000000000000000000B; targetProxy = C00000000000000000000F01; };'
]
ref = 'C00000000000000000000001'; build = 'C00000000000000000000002'
objects += [f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITestFixtures.swift; sourceTree = "<group>"; }};', f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};']
s = s.replace('A00000000000000000000003 /* WiiMTIDALApp.swift */,', f'A00000000000000000000003 /* WiiMTIDALApp.swift */, {ref},')
s = s.replace('A00000000000000000000001 /* WiiMTIDALApp.swift in Sources */,', f'A00000000000000000000001 /* WiiMTIDALApp.swift in Sources */, {build},')
entries = []
testables = []
for i, name in enumerate(['PlayerTests', 'PlayerUITests']):
    ids = [f'C00000000000000000000{i+1}{j:02X}' for j in range(1, 8)]
    ref, build, product, phase, target, config, configlist = ids
    settings = '' if i else 'BUNDLE_LOADER = "$(TEST_HOST)"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/WiiMTIDAL.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/WiiMTIDAL";'
    kind = 'ui-testing' if i else 'unit-test'
    objects += [
        f'{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}.swift; sourceTree = "<group>"; }};',
        f'{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};',
        f'{product} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = {name}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};',
        f'{phase} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({build}); runOnlyForDeploymentPostprocessing = 0; }};',
        f'{target} = {{isa = PBXNativeTarget; buildConfigurationList = {configlist}; buildPhases = ({phase}); buildRules = (); dependencies = (C00000000000000000000F02); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.bundle.{kind}"; }};',
        f'{config} = {{isa = XCBuildConfiguration; buildSettings = {{GENERATE_INFOPLIST_FILE = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = org.wiimtidal.{name.lower()}; PRODUCT_NAME = {name}; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; TEST_TARGET_NAME = WiiMTIDAL; {settings} }}; name = Debug; }};',
        f'{configlist} = {{isa = XCConfigurationList; buildConfigurations = ({config}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};'
    ]
    s = s.replace('A00000000000000000000009 /* WiiMTIDAL */,', f'A00000000000000000000009 /* WiiMTIDAL */, {ref},')
    s = s.replace('A0000000000000000000000B /* WiiMTIDAL */,', f'A0000000000000000000000B /* WiiMTIDAL */, {target},')
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.xctest" BlueprintName="{name}" ReferencedContainer="container:WiiMTIDAL.xcodeproj"/>'
    entries.append(f'<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{reference}</BuildActionEntry>')
    testables.append(f'<TestableReference skipped="NO">{reference}</TestableReference>')
s = s.replace('objects = {', 'objects = {\n' + '\n'.join(objects), 1)
pbx.write_text(s)
appref = '<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A0000000000000000000000B" BuildableName="WiiMTIDAL.app" BlueprintName="WiiMTIDAL" ReferencedContainer="container:WiiMTIDAL.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.7"><BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{appref}</BuildActionEntry>
{''.join(entries)}</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO"><MacroExpansion>{appref}</MacroExpansion><Testables>{''.join(testables)}</Testables></TestAction></Scheme>'''
folder = project / 'WiiMTIDAL.xcodeproj/xcshareddata/xcschemes'
folder.mkdir(parents=True, exist_ok=True)
(folder / 'PlayerTests.xcscheme').write_text(scheme)
print(root)
