"""Bundle Portal; optionally sign for distribution with PORTAL_SIGNING_IDENTITY."""
import pathlib, subprocess, shutil, plistlib, sys, re, os
root = pathlib.Path(__file__).resolve().parent.parent
identity = os.environ.get('PORTAL_SIGNING_IDENTITY', '-')
if identity != '-' and not identity.startswith('Developer ID Application:'):
    raise SystemExit('Use the full Developer ID Application certificate name for distribution.')
app = root / 'dist' / 'Portal.app'
if app.exists(): shutil.rmtree(app)
contents = app / 'Contents'
for name in ['MacOS', 'Frameworks', 'Resources']:
    (contents / name).mkdir(parents=True, exist_ok=True)
source = pathlib.Path(sys.argv[1]).resolve()
executable = contents / 'MacOS' / 'Portal'
shutil.copy2(source, executable)
shutil.copytree(source.parent/'Portal_Portal.bundle', contents/'Resources/Portal_Portal.bundle')
shutil.copy2(root / 'scripts' / 'ssh-askpass.sh', contents / 'Resources' / 'ssh-askpass.sh')
info = {
    'CFBundleExecutable':'Portal', 'CFBundleIdentifier':'app.portal.vnc',
    'CFBundleIconFile':'Portal', 'CFBundleName':'Portal', 'CFBundleDisplayName':'Portal', 'CFBundlePackageType':'APPL',
    'CFBundleShortVersionString':'0.1.0', 'CFBundleVersion':'1', 'LSMinimumSystemVersion':'26.0',
    'NSHighResolutionCapable':True, 'NSPrincipalClass':'NSApplication',
    'NSLocalNetworkUsageDescription':'Portal discovers and connects to VNC computers on your local network.',
    'NSBonjourServices':['_rfb._tcp'],
    'CFBundleURLTypes':[{'CFBundleURLName':'VNC connection','CFBundleURLSchemes':['vnc']}],
    'NSHumanReadableCopyright':'Free software · GPL-2.0-or-later',
}
iconset = root/'.build/Portal.iconset'
iconset.mkdir(exist_ok=True)
master = root/'.build/portal-icon.png'
subprocess.run(['swift',str(root/'scripts/prepare-icon.swift'),str(root/'assets/branding/portal-round-tube-ring-thinner-alt.png'),str(master)],check=True)
for size in [16,32,128,256,512]:
    for scale in [1,2]:
        name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        subprocess.run(['sips','-z',str(size*scale),str(size*scale),str(master),'--out',str(iconset/name)],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(contents/'Resources/Portal.icns')],check=True)
with (contents/'Info.plist').open('wb') as file: plistlib.dump(info,file)
seen = set()
def bundle(binary, original):
    dependencies = subprocess.check_output(['otool','-L',str(original)],text=True).splitlines()[1:]
    for line in dependencies:
        dependency = line.strip().split(' (')[0]
        if dependency.startswith(('/System/Library/', '/usr/lib/')): continue
        if dependency == str(original): continue
        path = pathlib.Path(dependency)
        if dependency.startswith('@rpath/'):
            path = root / '.build/native/lib' / pathlib.Path(dependency).name
        elif dependency.startswith('@loader_path/'):
            path = original.parent / dependency.removeprefix('@loader_path/')
        if not path.exists(): raise RuntimeError(f'Cannot resolve {dependency} in {original}')
        path = path.resolve()
        target = contents/'Frameworks'/path.name
        if path not in seen:
            seen.add(path); shutil.copy2(path,target)
            subprocess.run(['chmod','u+w',str(target)],check=True)
            bundle(target,path)
            subprocess.run(['install_name_tool','-id','@rpath/'+target.name,str(target)],check=True)
        subprocess.run(['install_name_tool','-change',dependency,'@rpath/'+target.name,str(binary)],check=True)
bundle(executable,source)
# DES VNC authentication uses OpenSSL's legacy provider loaded at runtime.
for library in tuple(seen):
    if library.name.startswith('libcrypto.'):
        provider = library.parent/'ossl-modules/legacy.dylib'
        if not provider.exists(): raise RuntimeError('Missing OpenSSL legacy provider for VNC authentication')
        target = contents/'Frameworks/legacy.dylib'
        shutil.copy2(provider,target)
        subprocess.run(['chmod','u+w',str(target)],check=True)
        bundle(target,provider)
        subprocess.run(['install_name_tool','-add_rpath','@loader_path',str(target)],check=True)
versions = [(26,0)]
for binary in [executable, *(contents/'Frameworks').iterdir()]:
    load_commands = subprocess.check_output(['otool','-l',str(binary)],text=True)
    versions += [tuple(map(int,version.split('.'))) for version in re.findall(r'\bminos\s+(\d+(?:\.\d+)+)',load_commands)]
info['LSMinimumSystemVersion'] = '.'.join(map(str,max(versions)))
with (contents/'Info.plist').open('wb') as file: plistlib.dump(info,file)
licenses = contents/'Resources/Licenses'
licenses.mkdir(exist_ok=True)
shutil.copy2(root/'LICENSE',licenses/'Portal-GPL.txt')
shutil.copy2(root/'THIRD_PARTY.md',licenses/'THIRD_PARTY.md')
for library in seen:
    prefix = library.parent.parent
    for license_file in prefix.iterdir():
        if license_file.is_file() and license_file.name.upper().startswith(('LICENSE','COPYING')):
            shutil.copy2(license_file,licenses/(prefix.parent.name+'-'+license_file.name))
commands = subprocess.check_output(['otool','-l',str(executable)],text=True)
for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',commands):
    if path.startswith('/') and not path.startswith('/usr/lib/'):
        subprocess.run(['install_name_tool','-delete_rpath',path,str(executable)],check=True)
subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(executable)],check=True)
sign = ['codesign','--force','--sign',identity]
if identity != '-': sign += ['--options','runtime','--timestamp']
for library in (contents/'Frameworks').iterdir(): subprocess.run(sign+[str(library)],check=True)
subprocess.run(sign+[str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print(app)
