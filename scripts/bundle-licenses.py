"""Include license texts from the build environment in the application bundle."""
from importlib.metadata import distributions
from pathlib import Path
import shutil
import sys
import sysconfig

destination = Path(sys.argv[1])
destination.mkdir(parents=True)
shutil.copyfile('LICENSE', destination / 'WiiM TIDAL.txt')
for distribution in distributions():
    for file in distribution.files or ():
        if not any(part.lower().startswith(('license', 'copying', 'notice')) for part in file.parts):
            continue
        source = distribution.locate_file(file)
        if source.is_file():
            name = distribution.metadata['Name']
            target = destination / name / file.name
            target.parent.mkdir(exist_ok=True)
            shutil.copyfile(source, target)
for parent in Path(sysconfig.get_path('stdlib')).resolve().parents:
    for name in ('LICENSE.txt', 'LICENSE'):
        license_file = parent / name
        if license_file.is_file():
            shutil.copyfile(license_file, destination / 'Python.txt')
            break
    else:
        continue
    break
