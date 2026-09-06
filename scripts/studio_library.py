#!/usr/bin/env python3
"""Personal studio recipes, deliberately outside the Git checkout."""
import json
import os
from pathlib import Path
import sys
import uuid
import fcntl

def main():
    directory = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'quickshell/studio'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'collection.json'
    with (directory / 'collection.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = json.loads(path.read_text()) if path.exists() else []
        if sys.argv[1] == 'save':
            entry = json.loads(sys.argv[2])
            if not entry.get('name', '').strip() or not entry.get('themePath'):
                raise ValueError('Choose a wallpaper and enter a name first.')
            entry['id'] = str(uuid.uuid4())
            entries.insert(0, entry)
            temporary = path.with_suffix('.tmp')
            temporary.write_text(json.dumps(entries, indent=2))
            temporary.replace(path)
        print(json.dumps(entries))

if __name__ == '__main__':
    main()
