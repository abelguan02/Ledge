"""Read-only migration audit. Reports counts/hashes, never material names or text."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import sys


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def path_key(relative):
    return hashlib.sha256(relative.encode('utf-8')).hexdigest()


def inventory(root, exclude=()):
    if root.is_symlink():
        raise ValueError('symbolic root')
    result = {}
    def walk(directory):
        for entry in os.scandir(directory):
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if relative in exclude:
                continue
            mode = entry.stat(follow_symlinks=False).st_mode
            if stat.S_ISDIR(mode):
                result[path_key(relative)] = 'directory'
                walk(path)
            elif stat.S_ISREG(mode):
                result[path_key(relative)] = digest(path)
            else:
                raise ValueError('unsupported file type')
    walk(root)
    return result


def preferences(path):
    if not path.exists():
        return {}
    with path.open('rb') as stream:
        return plistlib.load(stream)


def snapshot(source, old_preferences):
    index = json.loads((source / 'library.json').read_bytes())
    entries = inventory(source)
    return {'entries': entries, 'collections': len(index['collections']),
            'materials': len(index['items']),
            'files': sum(value != 'directory' for value in entries.values()),
            'indexSHA256': digest(source / 'library.json'),
            'oldPreferencesSHA256': digest(old_preferences) if old_preferences.exists() else None}


def main():
    mode, *values = sys.argv[1:]
    if mode == 'snapshot' and len(values) == 3:
        source, old_preferences, output = map(Path, values)
        report = snapshot(source, old_preferences)
        with output.open('x') as stream:
            json.dump(report, stream, indent=2)
        print(json.dumps({key: value for key, value in report.items() if key != 'entries'}))
    elif mode == 'verify' and len(values) == 6:
        source, destination, old_preferences, new_preferences, baseline_path, output = map(Path, values)
        baseline = json.loads(baseline_path.read_bytes())
        current = snapshot(source, old_preferences)
        original_index = json.loads((source / 'library.json').read_bytes())
        copied_index = json.loads((destination / 'library.json').read_bytes())
        migrated = json.loads((destination / 'migration-report.json').read_bytes())
        expected_files = dict(baseline['entries'])
        copied_files = inventory(destination, ('migration-report.json', 'migration-preferences.plist'))
        expected_files.pop(path_key('library.json'))
        copied_files.pop(path_key('library.json'))
        old_values = preferences(old_preferences)
        new_values = preferences(new_preferences)
        checks = {
            'sourceUnchanged': baseline == current,
            'materialFilesAndDirectoriesMatch': expected_files == copied_files,
            'indexContentMatches': original_index == copied_index,
            'migrationReportMatches': all(migrated[key] == baseline[key] for key in ('collections', 'materials', 'files', 'indexSHA256')),
            'preferenceBackupMatches': preferences(destination / 'migration-preferences.plist') == old_values,
            'newPreferencesPreserved': all(key in new_values and new_values[key] == value for key, value in old_values.items()),
        }
        report = {'checks': checks, 'collections': len(copied_index['collections']),
                  'materials': len(copied_index['items']), 'sourceFiles': baseline['files'],
                  'oldPreferenceKeys': len(old_values),
                  'indexBytesMatch': digest(destination / 'library.json') == baseline['indexSHA256']}
        with output.open('x') as stream:
            json.dump(report, stream, indent=2)
        print(json.dumps(report))
        if not all(checks.values()):
            raise SystemExit(1)
    else:
        raise ValueError('expected snapshot SOURCE OLD_PREFS OUT or verify SOURCE DEST OLD_PREFS NEW_PREFS BASELINE OUT')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Do not echo file paths or material content from exception messages.
        print('Migration audit failed: ' + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
