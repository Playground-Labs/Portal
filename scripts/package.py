"""Bundle the executable and its non-system dynamic libraries for local use."""
import pathlib, subprocess, shutil, plistlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'dist' / 'Portal.app'
contents = app / 'Contents'
for name in ['MacOS', 'Frameworks', 'Resources']:
    (contents / name).mkdir(parents=True, exist_ok=True)
source = pathlib.Path(sys.argv[1]).resolve()
executable = contents / 'MacOS' / 'Portal'
shutil.copy2(source, executable)
shutil.copy2(root / 'scripts' / 'ssh-askpass.sh', contents / 'Resources' / 'ssh-askpass.sh')
info = {
    'CFBundleExecutable':'Portal', 'CFBundleIdentifier':'app.portal.vnc',
    'CFBundleIconFile':'Portal', 'CFBundleName':'Portal', 'CFBundleDisplayName':'Portal', 'CFBundlePackageType':'APPL',
    'CFBundleShortVersionString':'0.1.0', 'CFBundleVersion':'1', 'LSMinimumSystemVersion':'14.0',
    'NSHighResolutionCapable':True, 'NSPrincipalClass':'NSApplication',
    'NSLocalNetworkUsageDescription':'Portal discovers and connects to VNC computers on your local network.',
    'NSBonjourServices':['_rfb._tcp'],
    'CFBundleURLTypes':[{'CFBundleURLName':'VNC connection','CFBundleURLSchemes':['vnc']}],
    'NSHumanReadableCopyright':'Free software · GPL-2.0-or-later',
}
iconset = root/'.build/Portal.iconset'
iconset.mkdir(exist_ok=True)
master = root/'.build/portal-icon.png'
subprocess.run(['swift',str(root/'scripts/create-icon.swift'),str(master)],check=True)
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
subprocess.run(['install_name_tool','-delete_rpath',str(root/'.build/native/lib'),str(executable)],check=True)
subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(executable)],check=True)
for library in (contents/'Frameworks').iterdir(): subprocess.run(['codesign','--force','--sign','-',str(library)],check=True)
subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
print(app)
